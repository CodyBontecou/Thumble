import {
  decodeEditorReadCommand,
  decodeEditorProfilePage,
  type EditorReadCommand,
} from "@thumble/contracts/editor-read";
import type { EditorReadReply } from "@thumble/application/configuration-editor-read";
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
export function editorEnvelopeFields(
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
  const v = editorEnvelopeFields(value, keys);
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
  const v = editorEnvelopeFields(value, ["envelope", "outcome"]),
    envelope = decodeEditorLabelCommit(v.envelope);
  if (JSON.stringify(envelope) !== JSON.stringify(request))
    throw new Error("editor_response_mismatch");
  const outcome = decodeConfigurationReply(v.outcome, request.intent);
  if (outcome.kind !== "committed" && outcome.kind !== "conflict")
    throw new Error("editor_response_invalid");
  return Object.freeze({ envelope, outcome });
}

export type EditorReadEnvelope = Readonly<{
  command: "editor-read";
  ownerLifetimeId: string;
  eventId: string;
  authorityInstanceId: string;
  phoneId: string;
  credentialEpoch: string;
  query: EditorReadCommand;
}>;
export function decodeEditorReadEnvelope(value: unknown): EditorReadEnvelope {
  const v = editorEnvelopeFields(value, [...keys.slice(0, -1), "query"]);
  if (v.command !== "editor-read") throw new Error("editor_envelope_invalid");
  const epoch = counter(v.credentialEpoch);
  if (epoch === "0") throw new Error("editor_envelope_invalid");
  return Object.freeze({
    command: "editor-read",
    ownerLifetimeId: editorLifetimeId(v.ownerLifetimeId),
    eventId: identity(v.eventId),
    authorityInstanceId: editorLifetimeId(v.authorityInstanceId),
    phoneId: identity(v.phoneId),
    credentialEpoch: epoch,
    query: decodeEditorReadCommand(v.query),
  });
}
export type EditorOwnerReadResponse = Readonly<{
  envelope: EditorReadEnvelope;
  outcome: EditorReadReply;
}>;
export function decodeEditorOwnerReadResponse(
  value: unknown,
  request: EditorReadEnvelope,
): EditorOwnerReadResponse {
  const v = editorEnvelopeFields(value, ["envelope", "outcome"]);
  const envelope = decodeEditorReadEnvelope(v.envelope);
  if (JSON.stringify(envelope) !== JSON.stringify(request))
    throw new Error("editor_response_mismatch");
  let outcome: EditorReadReply;
  if (request.query.command === "editor-profile") {
    const page = decodeEditorProfilePage(v.outcome);
    if (
      page.revision !== request.query.expectedRevision ||
      page.contentHash !== request.query.expectedSourceHash ||
      page.profileId !== request.query.profileId ||
      page.offset !== request.query.offset
    )
      throw new Error("editor_response_mismatch");
    outcome = page;
  } else {
    const raw = record(v.outcome);
    const tag = Object.getOwnPropertyDescriptor(raw, "kind");
    if (!tag || !("value" in tag)) throw new Error("editor_response_invalid");
    if (tag.value === "editor-label-pending") {
      const pending = editorEnvelopeFields(raw, [
        "version",
        "kind",
        "operationId",
      ]);
      if (
        pending.version !== 1 ||
        pending.operationId !== request.query.intent.operationId
      )
        throw new Error("editor_response_mismatch");
      outcome = Object.freeze({
        version: 1,
        kind: "editor-label-pending",
        operationId: request.query.intent.operationId,
      });
    } else {
      const received = editorEnvelopeFields(raw, [
        "version",
        "kind",
        "receipt",
      ]);
      if (received.version !== 1 || received.kind !== "editor-label-receipt")
        throw new Error("editor_response_invalid");
      const committed = decodeConfigurationReply(
        {
          version: 1,
          kind: "committed",
          receipt: received.receipt,
          replayed: true,
        },
        request.query.intent,
      );
      if (committed.kind !== "committed")
        throw new Error("editor_response_invalid");
      outcome = Object.freeze({
        version: 1,
        kind: "editor-label-receipt",
        receipt: committed.receipt,
      });
    }
  }
  return Object.freeze({ envelope, outcome });
}
