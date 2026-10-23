import { exact, record } from "./receiver.ts";
/** Public identity metadata only. Native private key bytes never enter JavaScript. */
export type HostIdentity = Readonly<{
  version: 1;
  certificatePin: string;
  serverName: "thumble-rewrite.local";
  networkEnabled: false;
  inputEnabled: false;
}>;
export function decodeHostIdentity(value: unknown): HostIdentity {
  const data = record(value);
  if (
    ![Object.prototype, null].includes(Object.getPrototypeOf(data)) ||
    Reflect.ownKeys(data).length !== 5 ||
    Object.values(Object.getOwnPropertyDescriptors(data)).some(
      (descriptor) => !("value" in descriptor),
    )
  )
    throw new Error("invalid_host_identity");
  exact(data, [
    "version",
    "certificatePin",
    "serverName",
    "networkEnabled",
    "inputEnabled",
  ]);
  if (
    data.version !== 1 ||
    typeof data.certificatePin !== "string" ||
    !/^[0-9a-f]{64}$/.test(data.certificatePin) ||
    data.serverName !== "thumble-rewrite.local" ||
    data.networkEnabled !== false ||
    data.inputEnabled !== false
  )
    throw new Error("invalid_host_identity");
  return Object.freeze({
    version: 1,
    certificatePin: data.certificatePin,
    serverName: "thumble-rewrite.local",
    networkEnabled: false,
    inputEnabled: false,
  });
}
