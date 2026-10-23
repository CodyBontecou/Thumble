import { decodeGamepadState, type GamepadState } from "./index.ts";
export { parseStrictJson } from "./strict-json.ts";
export const FRAME_BYTES = 65536;
export type Snapshot = Readonly<{
  backend: "recording" | "macos-hid";
  inputEnabled: boolean;
  active: boolean;
  generation: string;
  revision: string;
  profileId: string | null;
  sequence: string | null;
  reportHex: string;
  lastReleaseReason: string;
}>;
export type ReceiverCommand =
  | { command: "status" }
  | { command: "release" }
  | { command: "shutdown" }
  | {
      command: "activate";
      generation: string;
      revision: string;
      profileId: string;
      sessionId: string;
      leaseMs: number;
      inputTtlMs: number;
    }
  | {
      command: "activateSaved";
      generation: string;
      revision: string;
      profileId: string;
      sessionId: string;
      leaseMs: number;
      inputTtlMs: number;
      configurationRevision: string;
      sourceHash: string;
    }
  | { command: "renew"; generation: string; sessionId: string }
  | {
      command: "sample";
      generation: string;
      sessionId: string;
      sequence: string;
      state: GamepadState;
    };
export type LocalCommand =
  | { command: "status" }
  | { command: "release" }
  | { command: "stop" }
  | { command: "activate"; expectedRevision: string; profileId: string }
  | {
      command: "sample";
      expectedGeneration: string;
      sequence: string;
      state: GamepadState;
      allowRecordedInput: true;
    };
export type LocalRequest = {
  version: 1;
  requestId: string;
  token: string;
  body: LocalCommand;
};
export type LocalResult =
  | { version: 1; requestId: string; ok: true; result: ServiceStatus }
  | { version: 1; requestId: string; ok: false; error: string };
export type ServiceStatus = {
  service: {
    instanceId: string;
    pid: number;
    configuration: "ephemeral-runtime-only";
  };
  receiver: { pid: number; snapshot: Snapshot };
  permissions: "not-evaluated";
  deviceRecognition: "not-evaluated";
  phone: "not-evaluated";
};

export function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("invalid_request");
  return value as Record<string, unknown>;
}
export function exact(
  value: Record<string, unknown>,
  fields: readonly string[],
): void {
  if (
    Object.keys(value).length !== fields.length ||
    fields.some((key) => !Object.hasOwn(value, key))
  )
    throw new Error("invalid_request");
}
export function counter(value: unknown): string {
  if (
    typeof value !== "string" ||
    !/^(?:0|[1-9][0-9]{0,19})$/.test(value) ||
    BigInt(value) > 18446744073709551615n
  )
    throw new Error("invalid_counter");
  return value;
}
export function identity(value: unknown): string {
  if (typeof value !== "string" || !/^[A-Za-z0-9-]{1,64}$/.test(value))
    throw new Error("invalid_identity");
  return value;
}
export function decodeLocalCommand(value: unknown): LocalCommand {
  const body = record(value);
  switch (body.command) {
    case "status":
    case "release":
    case "stop":
      exact(body, ["command"]);
      return { command: body.command };
    case "activate":
      exact(body, ["command", "expectedRevision", "profileId"]);
      return {
        command: "activate",
        expectedRevision: counter(body.expectedRevision),
        profileId: identity(body.profileId),
      };
    case "sample":
      exact(body, [
        "command",
        "expectedGeneration",
        "sequence",
        "state",
        "allowRecordedInput",
      ]);
      if (body.allowRecordedInput !== true)
        throw new Error("input_opt_in_required");
      return {
        command: "sample",
        expectedGeneration: counter(body.expectedGeneration),
        sequence: counter(body.sequence),
        state: decodeGamepadState(body.state),
        allowRecordedInput: true,
      };
    default:
      throw new Error("unsupported_command");
  }
}
export function decodeSnapshot(value: unknown): Snapshot {
  const s = record(value);
  exact(s, [
    "backend",
    "inputEnabled",
    "active",
    "generation",
    "revision",
    "profileId",
    "sequence",
    "reportHex",
    "lastReleaseReason",
  ]);
  if (
    (s.backend !== "recording" && s.backend !== "macos-hid") ||
    typeof s.inputEnabled !== "boolean" ||
    (s.backend === "recording" && s.inputEnabled !== false) ||
    (s.inputEnabled === true && s.active !== true) ||
    typeof s.active !== "boolean" ||
    typeof s.reportHex !== "string" ||
    !/^[0-9a-f]{40}$/.test(s.reportHex) ||
    typeof s.lastReleaseReason !== "string"
  )
    throw new Error("invalid_receiver_response");
  return Object.freeze({
    backend: s.backend,
    inputEnabled: s.inputEnabled,
    active: s.active,
    generation: counter(s.generation),
    revision: counter(s.revision),
    profileId: s.profileId === null ? null : identity(s.profileId),
    sequence: s.sequence === null ? null : counter(s.sequence),
    reportHex: s.reportHex,
    lastReleaseReason: s.lastReleaseReason,
  });
}
