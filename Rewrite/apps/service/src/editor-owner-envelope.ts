import { counter, identity, record } from "@thumble/contracts/receiver";
import {
  decodeConfigurationSetControlLabelCommand,
  type ConfigurationSetControlLabelCommand,
} from "@thumble/contracts/control-label";
import {
  decodeConfigurationReply,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";

export type EditorLabelCommit = Readonly<{
  command: "editor-label-commit";
  ownerLifetimeId: string;
  eventId: string;
  authorityInstanceId: string;
  phoneId: string;
  credentialEpoch: string;
  intent: ConfigurationSetControlLabelCommand;
}>;
const keys = [
  "command",
  "ownerLifetimeId",
  "eventId",
  "authorityInstanceId",
  "phoneId",
  "credentialEpoch",
  "intent",
] as const;
function fields(
  value: unknown,
  names: readonly string[],
): Record<string, unknown> {
  const v = record(value);
  if (
    ![Object.prototype, null].includes(Object.getPrototypeOf(v)) ||
    Reflect.ownKeys(v).length !== names.length
  )
    throw new Error("editor_envelope_invalid");
  const copy: Record<string, unknown> = Object.create(null);
  for (const name of names) {
    const p = Object.getOwnPropertyDescriptor(v, name);
    if (!p || !("value" in p)) throw new Error("editor_envelope_invalid");
    copy[name] = p.value;
  }
  return copy;
}
export function editorLifetimeId(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
      value,
    )
  )
    throw new Error("editor_lifetime_invalid");
  return value;
}
export function decodeEditorLabelCommit(value: unknown): EditorLabelCommit {
  const v = fields(value, keys);
  if (v.command !== "editor-label-commit")
    throw new Error("editor_envelope_invalid");
  const epoch = counter(v.credentialEpoch);
  if (epoch === "0") throw new Error("editor_envelope_invalid");
  return Object.freeze({
    command: "editor-label-commit",
    ownerLifetimeId: editorLifetimeId(v.ownerLifetimeId),
    eventId: identity(v.eventId),
    authorityInstanceId: editorLifetimeId(v.authorityInstanceId),
    phoneId: identity(v.phoneId),
    credentialEpoch: epoch,
    intent: decodeConfigurationSetControlLabelCommand(v.intent),
  });
}
export type EditorOwnerResponse = Readonly<{
  envelope: EditorLabelCommit;
  outcome: ConfigurationReply;
}>;
/** Correlation is checked before an actual owner response can release its ticket. */
export function decodeEditorOwnerResponse(
  value: unknown,
  request: EditorLabelCommit,
): EditorOwnerResponse {
  const v = fields(value, ["envelope", "outcome"]),
    envelope = decodeEditorLabelCommit(v.envelope);
  if (JSON.stringify(envelope) !== JSON.stringify(request))
    throw new Error("editor_response_mismatch");
  const outcome = decodeConfigurationReply(v.outcome, request.intent);
  if (outcome.kind !== "committed" && outcome.kind !== "conflict")
    throw new Error("editor_response_invalid");
  return Object.freeze({ envelope, outcome });
}
