import { counter } from "@thumble/contracts/receiver";
import {
  editorEnvelopeFields,
  editorLifetimeId,
  decodeEditorLabelCommit,
  decodeEditorOwnerResponse,
  decodeEditorReadEnvelope,
  decodeEditorOwnerReadResponse,
  type EditorLabelCommit,
  type EditorReadEnvelope,
} from "./editor-owner-envelope.ts";
import type { ConfigurationOwner } from "./configuration-owner.ts";

type Owner = Pick<
  ConfigurationOwner,
  | "editorOwnerLifetime"
  | "commitEditorLabel"
  | "readEditor"
  | "closeEditorDispatch"
  | "retireEditorOwner"
>;
export type PhoneEditorEvent =
  | Readonly<{
      version: 1;
      event: "phone-editor-write";
      envelope: EditorLabelCommit;
    }>
  | Readonly<{
      version: 1;
      event: "phone-editor-read";
      envelope: EditorReadEnvelope;
    }>;
export function decodePhoneEditorEvent(value: unknown): PhoneEditorEvent {
  const v = editorEnvelopeFields(value, ["version", "event", "envelope"]);
  if (v.version !== 1) throw new Error("editor_event_invalid");
  if (v.event === "phone-editor-write")
    return Object.freeze({
      version: 1,
      event: v.event,
      envelope: decodeEditorLabelCommit(v.envelope),
    });
  if (v.event === "phone-editor-read")
    return Object.freeze({
      version: 1,
      event: v.event,
      envelope: decodeEditorReadEnvelope(v.envelope),
    });
  throw new Error("editor_event_invalid");
}
function fixedError(value: unknown): string {
  return typeof value === "string" &&
    [
      "configuration_owner_busy",
      "editor_owner_unavailable",
      "editor_owner_lifetime_mismatch",
      "configuration_source_changed",
      "configuration_access_denied",
      "operation_id_reused",
      "configuration_profile_not_found",
      "configuration_control_not_found",
      "invalid_editor_read",
      "unsupported_editor_profile",
    ].includes(value)
    ? value
    : "editor_unavailable";
}
/** Private stdio bridge. One immutable actual owner, no replacement
 * lookup, write timeout race, raw source or public caller-selected lifetime. */
export class PhoneEditorBridge {
  private lastEvent = 0n;
  private closed = false;
  private retirement: Promise<void> | undefined;
  private writeBusy = false;
  private readBusy = false;
  private constructor(
    private readonly owner: Owner,
    readonly ownerLifetimeId: string,
  ) {}
  static async capture(owner: Owner): Promise<PhoneEditorBridge> {
    const lifetime = editorLifetimeId(await owner.editorOwnerLifetime());
    return new PhoneEditorBridge(owner, lifetime);
  }
  enableCommand() {
    if (this.closed) throw new Error("editor_bridge_closed");
    return Object.freeze({
      command: "phone-editor-enable" as const,
      ownerLifetimeId: this.ownerLifetimeId,
    });
  }
  close(): void {
    this.closed = true;
    this.owner.closeEditorDispatch();
  }
  /** Pairing pipe loss also retires an idle actual writer. No replacement is
   * looked up; native orphan proof still independently verifies SQLite drain. */
  retireWriter(): Promise<void> {
    if (!this.retirement) {
      this.close();
      this.retirement = this.owner.retireEditorOwner();
    }
    return this.retirement;
  }
  async execute(input: unknown): Promise<unknown> {
    const event = decodePhoneEditorEvent(input),
      envelope = event.envelope;
    const id = BigInt(counter(envelope.eventId));
    if (
      id === 0n ||
      id <= this.lastEvent ||
      envelope.ownerLifetimeId !== this.ownerLifetimeId ||
      this.closed
    )
      throw new Error("editor_event_invalid");
    this.lastEvent = id;
    if (event.event === "phone-editor-write") {
      const envelope = event.envelope;
      const reply = (result: unknown) =>
        Object.freeze({
          version: 1,
          event: "phone-editor-write-reply",
          envelope,
          result,
        });
      if (this.writeBusy)
        return reply({
          kind: "not-dispatched",
          error: "configuration_owner_busy",
        });
      this.writeBusy = true;
      try {
        // Keep this slot until the actual owner settles, including confirmed exit.
        const result = await this.owner.commitEditorLabel(envelope);
        if (result.kind === "owner-response")
          return reply({
            kind: result.kind,
            response: decodeEditorOwnerResponse(result.response, envelope),
          });
        if (result.kind === "writer-exited")
          return reply({ kind: result.kind, disposition: "unknown" });
        return reply({ kind: result.kind, error: fixedError(result.error) });
      } catch {
        // No acknowledgement of completion: native must retain/drain its ticket.
        this.close();
        return reply({ kind: "transport-uncertain", disposition: "unknown" });
      } finally {
        this.writeBusy = false;
      }
    }
    const envelopeRead = event.envelope;
    const reply = (result: unknown) =>
      Object.freeze({
        version: 1,
        event: "phone-editor-read-reply",
        envelope: envelopeRead,
        result,
      });
    if (this.readBusy)
      return reply({ kind: "read-error", error: "configuration_owner_busy" });
    this.readBusy = true;
    try {
      const response = decodeEditorOwnerReadResponse(
        await this.owner.readEditor(envelopeRead),
        envelopeRead,
      );
      return reply({ kind: "read-response", response });
    } catch (error) {
      return reply({
        kind: "read-error",
        error: fixedError(error instanceof Error ? error.message : undefined),
      });
    } finally {
      this.readBusy = false;
    }
  }
}
