import { counter, exact, identity, record } from "./receiver.ts";
export type WowSyncCommand =
  | Readonly<{
      command: "wow-refresh" | "wow-sync-start";
      operationId: string;
      expectedRevision: string;
      expectedSourceHash: string | null;
    }>
  | Readonly<{ command: "wow-sync-stop"; operationId: string }>
  | Readonly<{ command: "wow-sync-status"; operationId: string | null }>;
export type WowSyncStatus = Readonly<{
  kind: "wow-sync";
  enabled: boolean;
  busy: boolean;
  state:
    | "disabled"
    | "stopped"
    | "stopping"
    | "refreshing"
    | "running"
    | "ready"
    | "conflict"
    | "failed";
  operationId: string | null;
  mode: "manual" | "live" | null;
  lastOutcome:
    | "none"
    | "observing"
    | "committed"
    | "stale"
    | "conflict"
    | "failed";
  profileId: string | null;
  revision: string | null;
  contentHash: string | null;
  acknowledged: boolean | null;
  commitCount: number;
  error:
    | "wow_sync_failed"
    | "wow_sync_timeout"
    | "wow_sync_cleanup_unconfirmed"
    | "wow_sync_conflict"
    | null;
}>;
function data(value: unknown): Record<string, unknown> {
  const source = record(value);
  if (![Object.prototype, null].includes(Object.getPrototypeOf(source)))
    throw new Error("invalid_wow_sync_control");
  const result: Record<string, unknown> = Object.create(null);
  for (const key of Reflect.ownKeys(source)) {
    if (typeof key !== "string") throw new Error("invalid_wow_sync_control");
    const descriptor = Object.getOwnPropertyDescriptor(source, key);
    if (!descriptor || !("value" in descriptor) || !descriptor.enumerable)
      throw new Error("invalid_wow_sync_control");
    result[key] = descriptor.value;
  }
  return result;
}
const hash = (v: unknown): string => {
  if (typeof v !== "string" || !/^[a-f0-9]{64}$/.test(v))
    throw new Error("invalid_wow_sync_control");
  return v;
};
export function decodeWowSyncCommand(value: unknown): WowSyncCommand {
  const v = data(value);
  if (v.command === "wow-refresh" || v.command === "wow-sync-start") {
    exact(v, [
      "command",
      "operationId",
      "expectedRevision",
      "expectedSourceHash",
    ]);
    const expectedRevision = counter(v.expectedRevision);
    if ((expectedRevision === "0") !== (v.expectedSourceHash === null))
      throw new Error("invalid_wow_sync_control");
    return Object.freeze({
      command: v.command,
      operationId: identity(v.operationId),
      expectedRevision,
      expectedSourceHash:
        v.expectedSourceHash === null ? null : hash(v.expectedSourceHash),
    });
  }
  exact(v, ["command", "operationId"]);
  if (v.command === "wow-sync-stop")
    return Object.freeze({
      command: v.command,
      operationId: identity(v.operationId),
    });
  if (v.command === "wow-sync-status")
    return Object.freeze({
      command: v.command,
      operationId: v.operationId === null ? null : identity(v.operationId),
    });
  throw new Error("invalid_wow_sync_control");
}
export function disabledWowSyncStatus(enabled = false): WowSyncStatus {
  return Object.freeze({
    kind: "wow-sync",
    enabled,
    busy: false,
    state: enabled ? "stopped" : "disabled",
    operationId: null,
    mode: null,
    lastOutcome: "none",
    profileId: null,
    revision: null,
    contentHash: null,
    acknowledged: null,
    commitCount: 0,
    error: null,
  });
}
export function decodeWowSyncStatus(value: unknown): WowSyncStatus {
  const v = data(value);
  exact(v, [
    "kind",
    "enabled",
    "busy",
    "state",
    "operationId",
    "mode",
    "lastOutcome",
    "profileId",
    "revision",
    "contentHash",
    "acknowledged",
    "commitCount",
    "error",
  ]);
  if (
    v.kind !== "wow-sync" ||
    typeof v.enabled !== "boolean" ||
    typeof v.busy !== "boolean" ||
    typeof v.state !== "string" ||
    ![
      "disabled",
      "stopped",
      "stopping",
      "refreshing",
      "running",
      "ready",
      "conflict",
      "failed",
    ].includes(v.state) ||
    !([null, "manual", "live"] as readonly unknown[]).includes(v.mode) ||
    typeof v.lastOutcome !== "string" ||
    !["none", "observing", "committed", "stale", "conflict", "failed"].includes(
      v.lastOutcome,
    ) ||
    (v.acknowledged !== null && typeof v.acknowledged !== "boolean") ||
    !Number.isSafeInteger(v.commitCount) ||
    Number(v.commitCount) < 0 ||
    !(
      [
        null,
        "wow_sync_failed",
        "wow_sync_timeout",
        "wow_sync_cleanup_unconfirmed",
        "wow_sync_conflict",
      ] as readonly unknown[]
    ).includes(v.error)
  )
    throw new Error("invalid_wow_sync_control");
  if (v.operationId !== null) identity(v.operationId);
  if (
    v.profileId !== null &&
    (typeof v.profileId !== "string" ||
      !/^[a-f0-9]{8}-[a-f0-9]{4}-5[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/.test(
        v.profileId,
      ))
  )
    throw new Error("invalid_wow_sync_control");
  if (v.revision !== null) counter(v.revision);
  if (v.contentHash !== null) hash(v.contentHash);
  if (
    (v.revision === null) !== (v.contentHash === null) ||
    (v.busy && v.operationId === null) ||
    (Number(v.commitCount) > 0 &&
      (v.profileId === null ||
        v.revision === null ||
        v.contentHash === null ||
        v.acknowledged === null)) ||
    (v.commitCount === 0 &&
      (v.profileId !== null ||
        v.revision !== null ||
        v.contentHash !== null ||
        v.acknowledged !== null)) ||
    (!v.enabled && (v.state !== "disabled" || v.operationId !== null)) ||
    (v.enabled && v.state === "disabled") ||
    (v.operationId === null) !== (v.mode === null)
  )
    throw new Error("invalid_wow_sync_control");
  return Object.freeze({ ...v }) as WowSyncStatus;
}
