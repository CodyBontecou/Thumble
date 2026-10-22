import { exact, record } from "./receiver.ts";
export type SignedHidClaim =
  | "not-compiled"
  | "not-applicable"
  | "present"
  | "absent"
  | "inspection-failed";
export type OutputCapabilities = Readonly<{
  version: 1;
  kind: "output-capabilities";
  platform: "macos" | "windows" | "linux" | "unsupported";
  backend: "recording";
  physicalOutputEnabled: false;
  runtimeIntegrated: false;
  macos: Readonly<{
    dormantAdapterCompiled: boolean;
    signedClaim: SignedHidClaim;
  }>;
  windows: Readonly<{
    candidate: "hidmaestro";
    candidateVersion: "2.0.3";
    upstreamCommit: "63cc6481f9e82fc8600bda8aaa65cb3271113a19";
    profile: "xbox-360-wired";
    sdkLinked: false;
    backendAvailable: false;
    driver: "not-inspected";
  }>;
  osDeviceAuthorization: "not-inspected";
  gameplayVerified: false;
}>;
function data(
  value: unknown,
  keys: readonly string[],
): Record<string, unknown> {
  const row = record(value);
  if (
    ![Object.prototype, null].includes(Object.getPrototypeOf(row)) ||
    Reflect.ownKeys(row).length !== keys.length
  )
    throw new Error("invalid_output_capabilities");
  exact(row, keys);
  const result: Record<string, unknown> = {};
  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(row, key);
    if (!descriptor || !("value" in descriptor))
      throw new Error("invalid_output_capabilities");
    result[key] = descriptor.value;
  }
  return result;
}
/** Compile/source evidence and signed claims, never OS authorization or activation. */
export function decodeOutputCapabilities(value: unknown): OutputCapabilities {
  const v = data(value, [
    "version",
    "kind",
    "platform",
    "backend",
    "physicalOutputEnabled",
    "runtimeIntegrated",
    "macos",
    "windows",
    "osDeviceAuthorization",
    "gameplayVerified",
  ]);
  const mac = data(v.macos, ["dormantAdapterCompiled", "signedClaim"]);
  const win = data(v.windows, [
    "candidate",
    "candidateVersion",
    "upstreamCommit",
    "profile",
    "sdkLinked",
    "backendAvailable",
    "driver",
  ]);
  if (
    v.version !== 1 ||
    v.kind !== "output-capabilities" ||
    typeof v.platform !== "string" ||
    !["macos", "windows", "linux", "unsupported"].includes(v.platform) ||
    v.backend !== "recording" ||
    v.physicalOutputEnabled !== false ||
    v.runtimeIntegrated !== false ||
    v.osDeviceAuthorization !== "not-inspected" ||
    v.gameplayVerified !== false ||
    typeof mac.dormantAdapterCompiled !== "boolean" ||
    (v.platform === "macos"
      ? mac.dormantAdapterCompiled
        ? typeof mac.signedClaim !== "string" ||
          !["present", "absent", "inspection-failed"].includes(mac.signedClaim)
        : mac.signedClaim !== "not-compiled"
      : mac.dormantAdapterCompiled !== false ||
        mac.signedClaim !== "not-applicable") ||
    win.candidate !== "hidmaestro" ||
    win.candidateVersion !== "2.0.3" ||
    win.upstreamCommit !== "63cc6481f9e82fc8600bda8aaa65cb3271113a19" ||
    win.profile !== "xbox-360-wired" ||
    win.sdkLinked !== false ||
    win.backendAvailable !== false ||
    win.driver !== "not-inspected"
  )
    throw new Error("invalid_output_capabilities");
  return Object.freeze({
    version: 1,
    kind: "output-capabilities",
    platform: v.platform as OutputCapabilities["platform"],
    backend: "recording",
    physicalOutputEnabled: false,
    runtimeIntegrated: false,
    macos: Object.freeze({
      dormantAdapterCompiled: mac.dormantAdapterCompiled,
      signedClaim: mac.signedClaim as SignedHidClaim,
    }),
    windows: Object.freeze({
      candidate: "hidmaestro",
      candidateVersion: "2.0.3",
      upstreamCommit: "63cc6481f9e82fc8600bda8aaa65cb3271113a19",
      profile: "xbox-360-wired",
      sdkLinked: false,
      backendAvailable: false,
      driver: "not-inspected",
    }),
    osDeviceAuthorization: "not-inspected",
    gameplayVerified: false,
  });
}
