import {
  counter,
  decodeSnapshot,
  exact,
  record,
  type Snapshot,
} from "./receiver.ts";
export type SavedConfigurationPin = Readonly<{
  configurationRevision: string;
  sourceHash: string;
  profileId: string;
}>;
export type SavedRuntimeBinding = Readonly<
  SavedConfigurationPin & { generation: string; revision: string }
>;
export type SavedActivateCommand = Readonly<{
  command: "activate-saved";
  expectedReceiverRevision: string;
  expectedConfigurationRevision: string;
  expectedSourceHash: string;
  profileId: string;
}>;
export type SavedRuntimeCommand =
  | SavedActivateCommand
  | Readonly<{ command: "saved-binding-status" }>;
export type SavedRuntimeStatus = Readonly<{
  kind: "saved-runtime";
  serviceInstanceId: string;
  servicePid: number;
  receiverPid: number;
  snapshot: Snapshot;
  savedBinding: SavedRuntimeBinding | null;
}>;
export type SavedPinCommand = Readonly<{
  command: "configuration-saved-pin";
  expectedRevision: string;
  expectedSourceHash: string;
  profileId: string;
}>;
const hash = (v: unknown) => {
  if (typeof v !== "string" || !/^[0-9a-f]{64}$/.test(v))
    throw new Error("invalid_saved_source_hash");
  return v;
};
function profile(v: unknown): string {
  if (
    typeof v !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v)
  )
    throw new Error("invalid_saved_profile_id");
  return v.toLowerCase();
}
export function decodeSavedConfigurationPin(
  value: unknown,
): SavedConfigurationPin {
  const v = record(value);
  exact(v, ["configurationRevision", "sourceHash", "profileId"]);
  const revision = counter(v.configurationRevision);
  if (revision === "0") throw new Error("invalid_saved_configuration_revision");
  return Object.freeze({
    configurationRevision: revision,
    sourceHash: hash(v.sourceHash),
    profileId: profile(v.profileId),
  });
}
export function decodeSavedRuntimeCommand(value: unknown): SavedRuntimeCommand {
  const v = record(value);
  if (v.command === "saved-binding-status") {
    exact(v, ["command"]);
    return Object.freeze({ command: "saved-binding-status" });
  }
  exact(v, [
    "command",
    "expectedReceiverRevision",
    "expectedConfigurationRevision",
    "expectedSourceHash",
    "profileId",
  ]);
  if (v.command !== "activate-saved")
    throw new Error("invalid_saved_runtime_command");
  const pin = decodeSavedConfigurationPin({
    configurationRevision: v.expectedConfigurationRevision,
    sourceHash: v.expectedSourceHash,
    profileId: v.profileId,
  });
  return Object.freeze({
    command: "activate-saved",
    expectedReceiverRevision: counter(v.expectedReceiverRevision),
    expectedConfigurationRevision: pin.configurationRevision,
    expectedSourceHash: pin.sourceHash,
    profileId: pin.profileId,
  });
}
export function decodeSavedPinCommand(value: unknown): SavedPinCommand {
  const v = record(value);
  exact(v, ["command", "expectedRevision", "expectedSourceHash", "profileId"]);
  if (v.command !== "configuration-saved-pin")
    throw new Error("invalid_saved_pin_command");
  const pin = decodeSavedConfigurationPin({
    configurationRevision: v.expectedRevision,
    sourceHash: v.expectedSourceHash,
    profileId: v.profileId,
  });
  return Object.freeze({
    command: "configuration-saved-pin",
    expectedRevision: pin.configurationRevision,
    expectedSourceHash: pin.sourceHash,
    profileId: pin.profileId,
  });
}
export function decodeSavedBinding(
  value: unknown,
  snapshot: Snapshot,
): SavedRuntimeBinding | null {
  if (value === null) return null;
  const v = record(value);
  exact(v, [
    "configurationRevision",
    "sourceHash",
    "profileId",
    "generation",
    "revision",
  ]);
  const pin = decodeSavedConfigurationPin({
    configurationRevision: v.configurationRevision,
    sourceHash: v.sourceHash,
    profileId: v.profileId,
  });
  const generation = counter(v.generation),
    revision = counter(v.revision);
  if (
    !snapshot.active ||
    generation === "0" ||
    generation !== snapshot.generation ||
    revision !== snapshot.revision ||
    pin.profileId !== snapshot.profileId
  )
    throw new Error("saved_runtime_binding_mismatch");
  return Object.freeze({ ...pin, generation, revision });
}
export function decodeSavedRuntimeStatus(value: unknown): SavedRuntimeStatus {
  const v = record(value);
  exact(v, [
    "kind",
    "serviceInstanceId",
    "servicePid",
    "receiverPid",
    "snapshot",
    "savedBinding",
  ]);
  if (
    v.kind !== "saved-runtime" ||
    typeof v.serviceInstanceId !== "string" ||
    !/^[A-Za-z0-9-]{1,64}$/.test(v.serviceInstanceId) ||
    ![v.servicePid, v.receiverPid].every(
      (p) => typeof p === "number" && Number.isSafeInteger(p) && p > 0,
    )
  )
    throw new Error("invalid_saved_runtime_status");
  const snapshot = decodeSnapshot(v.snapshot);
  return Object.freeze({
    kind: "saved-runtime",
    serviceInstanceId: v.serviceInstanceId,
    servicePid: v.servicePid as number,
    receiverPid: v.receiverPid as number,
    snapshot,
    savedBinding: decodeSavedBinding(v.savedBinding, snapshot),
  });
}

export const FIRST_TERMINATION_REASONS = [
  "lease_expired",
  "input_expired",
  "output_failed",
  "clock_failed",
  "clock_rollback",
  "grant_expired",
  "packet_session_released",
  "native_grant_delivery_failed",
  "native_input_released",
  "native_input_owner_failed",
  "owner_disconnected",
  "owner_backpressure",
  "activation_barrier",
  "explicit_release",
  "shutdown",
  "other_terminal",
] as const;
export type FirstTermination = Readonly<{
  reason: (typeof FIRST_TERMINATION_REASONS)[number];
  generation: string;
  revision: string;
}>;
export function decodeFirstTermination(
  value: unknown,
): FirstTermination | null {
  if (value === null) return null;
  const v = record(value);
  exact(v, ["reason", "generation", "revision"]);
  if (!FIRST_TERMINATION_REASONS.some((reason) => reason === v.reason))
    throw new Error("invalid_first_termination");
  const generation = counter(v.generation),
    revision = counter(v.revision);
  if (generation === "0" || revision === "0")
    throw new Error("invalid_first_termination");
  return Object.freeze({
    reason: v.reason as FirstTermination["reason"],
    generation,
    revision,
  });
}

/** Local maintenance proof; never a phone capability or input admission. */
export type SavedRearmStatus = Readonly<{
  snapshot: Snapshot;
  releasedBinding: SavedRuntimeBinding | null;
  cleanupReady: boolean;
  firstTermination: FirstTermination | null;
}>;
export function decodeSavedRearmStatus(value: unknown): SavedRearmStatus {
  const v = record(value);
  exact(v, ["snapshot", "releasedBinding", "cleanupReady", "firstTermination"]);
  const snapshot = decodeSnapshot(v.snapshot);
  if (typeof v.cleanupReady !== "boolean")
    throw new Error("invalid_rearm_status");
  let releasedBinding: SavedRuntimeBinding | null = null;
  if (v.releasedBinding !== null) {
    const pin = record(v.releasedBinding);
    if (
      snapshot.active ||
      snapshot.lastReleaseReason !== "native_input_released" ||
      snapshot.profileId !== pin.profileId
    )
      throw new Error("invalid_rearm_status");
    releasedBinding = decodeSavedBinding(pin, {
      ...snapshot,
      active: true,
      profileId: typeof pin.profileId === "string" ? pin.profileId : null,
    });
  }
  if (
    v.cleanupReady &&
    (snapshot.backend !== "macos-hid" ||
      snapshot.active ||
      snapshot.inputEnabled ||
      snapshot.reportHex !== "0014000000000000000000000000000000000000" ||
      !releasedBinding)
  )
    throw new Error("invalid_rearm_status");
  return Object.freeze({
    snapshot,
    releasedBinding,
    cleanupReady: v.cleanupReady,
    firstTermination: decodeFirstTermination(v.firstTermination),
  });
}

export const SAVED_READY_REASONS = [
  "policy-disabled",
  "explicit-activation-required",
  "explicit-saved-activation",
  "clean-release",
  "catalog-recheck-failed",
  "retirement-unconfirmed",
  "binding-changed",
  "activation-failed",
  "operator-release",
  "unsaved-activation",
  "release-not-clean",
] as const;
export type SavedReadyReason = (typeof SAVED_READY_REASONS)[number];
export type SavedReadyPolicyStatus = Readonly<{
  state:
    | "disabled"
    | "waiting-for-explicit-activation"
    | "armed"
    | "rearming"
    | "latched";
  reason: SavedReadyReason;
}>;
export type SavedReadinessStatus = SavedReadyPolicyStatus &
  Readonly<{
    kind: "saved-readiness";
    firstTermination: FirstTermination | null;
    serviceInstanceId: string;
    servicePid: number;
    receiverPid: number;
  }>;
export function decodeSavedReadinessStatus(
  value: unknown,
): SavedReadinessStatus {
  const v = record(value);
  exact(v, [
    "kind",
    "serviceInstanceId",
    "servicePid",
    "receiverPid",
    "firstTermination",
    "state",
    "reason",
  ]);
  if (
    v.kind !== "saved-readiness" ||
    typeof v.serviceInstanceId !== "string" ||
    !/^[A-Za-z0-9-]{1,64}$/.test(v.serviceInstanceId) ||
    ![v.servicePid, v.receiverPid].every(
      (p) => typeof p === "number" && Number.isSafeInteger(p) && p > 0,
    ) ||
    typeof v.state !== "string" ||
    ![
      "disabled",
      "waiting-for-explicit-activation",
      "armed",
      "rearming",
      "latched",
    ].includes(v.state) ||
    !SAVED_READY_REASONS.some((reason) => reason === v.reason)
  )
    throw new Error("invalid_saved_readiness_status");
  return Object.freeze({
    kind: "saved-readiness",
    firstTermination: decodeFirstTermination(v.firstTermination),
    serviceInstanceId: v.serviceInstanceId,
    servicePid: v.servicePid as number,
    receiverPid: v.receiverPid as number,
    state: v.state as SavedReadyPolicyStatus["state"],
    reason: v.reason as SavedReadyReason,
  });
}
