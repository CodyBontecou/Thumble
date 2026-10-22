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
