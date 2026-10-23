import {
  decodeLocalCommand,
  decodeSnapshot,
  exact,
  identity,
  record,
  type LocalCommand,
  type ServiceStatus,
} from "@thumble/contracts/receiver";
export interface ControlTransport {
  send(command: LocalCommand): Promise<unknown>;
}
/** Portable typed client. Native/host adapters own transport and credentials. */
export class ControlClient {
  constructor(private readonly transport: ControlTransport) {}
  async request(command: LocalCommand): Promise<ServiceStatus> {
    return decodeServiceStatus(
      await this.transport.send(decodeLocalCommand(command)),
    );
  }
}
export function decodeServiceStatus(value: unknown): ServiceStatus {
  const status = record(value);
  exact(status, [
    "service",
    "receiver",
    "permissions",
    "deviceRecognition",
    "phone",
  ]);
  const service = record(status.service),
    receiver = record(status.receiver);
  exact(service, ["instanceId", "pid", "configuration"]);
  exact(receiver, ["pid", "snapshot"]);
  if (
    service.configuration !== "ephemeral-runtime-only" ||
    ![service.pid, receiver.pid].every(
      (p) => Number.isSafeInteger(p) && Number(p) > 0,
    ) ||
    status.permissions !== "not-evaluated" ||
    status.deviceRecognition !== "not-evaluated" ||
    status.phone !== "not-evaluated"
  )
    throw new Error("invalid_service_response");
  return {
    service: {
      instanceId: identity(service.instanceId),
      pid: Number(service.pid),
      configuration: "ephemeral-runtime-only",
    },
    receiver: {
      pid: Number(receiver.pid),
      snapshot: decodeSnapshot(receiver.snapshot),
    },
    permissions: "not-evaluated",
    deviceRecognition: "not-evaluated",
    phone: "not-evaluated",
  };
}
