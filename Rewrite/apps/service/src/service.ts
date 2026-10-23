import { WowCaptureOwner } from "./wow-capture-owner.ts";
import { captureHelperPath } from "./wow-capture-provider.ts";
import {
  decodeWowCaptureCommand,
  disabledWowCaptureStatus,
  type WowCaptureControlStatus,
} from "@thumble/contracts/wow-capture-control";
import { PhoneControlsBridge } from "./phone-controls-bridge.ts";
import {
  decodeSavedRuntimeCommand,
  type SavedRuntimeStatus,
  type SavedReadinessStatus,
} from "@thumble/contracts/saved-runtime";
import { PhoneCatalogBridge } from "./phone-catalog-bridge.ts";
import { ConfigurationOwner } from "./configuration-owner.ts";
import {
  decodeConfigurationCommand,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";
import { NativePairingHost } from "./native-pairing.ts";
import {
  decodePairingCommand,
  decodeAuthorizedListener,
  type AuthorizedListener,
  type PairingReply,
} from "@thumble/contracts/pairing";
import { createServer, type Socket } from "node:net";
import { randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import {
  lstatSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { spawnSync, type ChildProcess } from "node:child_process";
import { join, isAbsolute } from "node:path";
import { RuntimeController } from "@thumble/application";
import {
  decodeLocalCommand,
  type Snapshot,
  exact,
  FRAME_BYTES,
  identity,
  parseStrictJson,
  record,
  type ServiceStatus,
} from "@thumble/contracts/receiver";
import { runtimeDirectory, type Endpoint } from "@thumble/client/local";
import { NativeReceiver, type ReceiverOutput } from "./native-receiver.ts";

export function secureDirectory(executable: string, path: string): string {
  const directory = runtimeDirectory(path);
  const result = spawnSync(executable, ["secure-directory", directory], {
    stdio: "ignore",
    windowsHide: true,
    timeout: 3000,
  });
  if (result.status !== 0)
    throw new Error("runtime_directory_protection_failed");
  return directory;
}
async function waitForOwnerExit(child: ChildProcess): Promise<void> {
  if (child.exitCode !== null || child.signalCode !== null) return;
  await new Promise<void>((resolve, reject) => {
    const finish = () => {
      clearTimeout(terminate);
      clearTimeout(deadline);
      child.removeListener("exit", finish);
      resolve();
    };
    const terminate = setTimeout(() => child.kill("SIGKILL"), 2000);
    const deadline = setTimeout(() => {
      clearTimeout(terminate);
      child.removeListener("exit", finish);
      reject(new Error("native_owner_shutdown_unconfirmed"));
    }, 3000);
    child.once("exit", finish);
    if (child.exitCode !== null || child.signalCode !== null) finish();
  });
}

export async function serve(
  executable: string,
  path: string,
  identityDirectory: string | undefined,
  configurationLauncher: readonly string[],
  wowCaptureHelper?: string,
  output: ReceiverOutput = { backend: "recording" },
  keepSavedControllerReady = false,
  authOnlyListener?: AuthorizedListener,
): Promise<void> {
  if (
    keepSavedControllerReady &&
    (output.backend !== "macos-hid" || !output.allowPhysicalOutput)
  )
    throw new Error("saved_controller_ready_requires_physical_output");
  const listener =
    authOnlyListener === undefined
      ? undefined
      : decodeAuthorizedListener(authOnlyListener);
  if (listener && (!identityDirectory || !isAbsolute(identityDirectory)))
    throw new Error("auth_listener_persistent_identity_required");
  const authorizedCaptureHelper =
    wowCaptureHelper === undefined
      ? undefined
      : captureHelperPath(wowCaptureHelper);
  const directory = secureDirectory(executable, path),
    instanceId = randomUUID(),
    token = randomBytes(32).toString("hex");
  const recordingLog = join(directory, `receiver-${instanceId}.jsonl`);
  const native = new NativeReceiver(
    executable,
    directory,
    recordingLog,
    output,
  );
  await native.ready;
  const configuration = new ConfigurationOwner(
    executable,
    directory,
    configurationLauncher,
  );
  try {
    await configuration.ready;
  } catch (error) {
    configuration.disconnect();
    native.disconnect();
    await Promise.all([
      waitForOwnerExit(native.child),
      waitForOwnerExit(configuration.child),
    ]);
    throw error;
  }
  const controller = new RuntimeController(
    native,
    randomUUID,
    750,
    350,
    keepSavedControllerReady
      ? {
          readPin: (pin) =>
            configuration.readSavedPin({
              command: "configuration-saved-pin",
              expectedRevision: pin.configurationRevision,
              expectedSourceHash: pin.sourceHash,
              profileId: pin.profileId,
            }),
          rearmStatus: () => native.rearmStatus(),
        }
      : undefined,
  );
  const pairing = new NativePairingHost(
    executable,
    directory,
    instanceId,
    identityDirectory,
    new PhoneCatalogBridge((command) =>
      configuration.readCatalogForPhone(command),
    ),
    new PhoneControlsBridge((command) =>
      configuration.readControlsForPhone(command),
    ),
  );
  try {
    await pairing.ready;
    if (listener) {
      const listening = await pairing.request({
        command: "pairing-listen-authorized",
        ...listener,
      });
      if (
        !listening.transport?.listening ||
        !listening.transport.persistentIdentity ||
        listening.transport.advertiseHost !== listener.advertiseHost ||
        listening.transport.port !==
          Number(
            listener.bindAddress.slice(
              listener.bindAddress.lastIndexOf(":") + 1,
            ),
          ) ||
        listening.pairing.state !== "closed" ||
        listening.offer !== null
      )
        throw new Error("auth_listener_start_unconfirmed");
    }
  } catch (error) {
    configuration.disconnect();
    pairing.disconnect();
    native.disconnect();
    await Promise.all([
      waitForOwnerExit(native.child),
      waitForOwnerExit(pairing.child),
      waitForOwnerExit(configuration.child),
    ]);
    throw error;
  }
  const capture = authorizedCaptureHelper
    ? new WowCaptureOwner(authorizedCaptureHelper, configurationLauncher)
    : undefined;
  if (capture) {
    try {
      await capture.ready;
    } catch (error) {
      capture.disconnect();
      configuration.disconnect();
      pairing.disconnect();
      native.disconnect();
      await Promise.all([
        waitForOwnerExit(capture.child),
        waitForOwnerExit(configuration.child),
        waitForOwnerExit(pairing.child),
        waitForOwnerExit(native.child),
      ]);
      throw error;
    }
  }
  const sockets = new Set<Socket>();
  let stopping = false;
  const status = (
    snapshot: Awaited<ReturnType<typeof controller.execute>>,
  ): ServiceStatus => ({
    service: {
      instanceId,
      pid: process.pid,
      configuration: "ephemeral-runtime-only",
    },
    receiver: { pid: native.child.pid!, snapshot },
    permissions: "not-evaluated",
    deviceRecognition: "not-evaluated",
    phone: "not-connected",
  });
  const server = createServer((socket) => {
    if (sockets.size >= 32) {
      socket.destroy();
      return;
    }
    sockets.add(socket);
    socket.setTimeout(2000, () => socket.destroy());
    socket.on("close", () => sockets.delete(socket));
    socket.on("error", () => {});
    let buffer = Buffer.alloc(0),
      consumed = false;
    socket.on("data", (chunk) => {
      if (consumed) return;
      buffer = Buffer.concat([
        buffer,
        typeof chunk === "string" ? Buffer.from(chunk) : chunk,
      ]);
      if (buffer.length > FRAME_BYTES) {
        socket.destroy();
        return;
      }
      const newline = buffer.indexOf(10);
      if (newline < 0) return;
      consumed = true;
      void (async () => {
        let requestId = "invalid";
        try {
          if (stopping) throw new Error("service_stopping");
          if (buffer.subarray(newline + 1).length)
            throw new Error("invalid_request");
          const envelope = record(
            parseStrictJson(
              new TextDecoder("utf-8", { fatal: true }).decode(
                buffer.subarray(0, newline),
              ),
            ),
          );
          exact(envelope, ["version", "requestId", "token", "body"]);
          requestId = identity(envelope.requestId);
          if (
            envelope.version !== 1 ||
            typeof envelope.token !== "string" ||
            !/^[0-9a-f]{64}$/.test(envelope.token) ||
            !timingSafeEqual(
              Buffer.from(token, "hex"),
              Buffer.from(envelope.token, "hex"),
            )
          )
            throw new Error("unauthorized");
          let result:
            | ServiceStatus
            | PairingReply
            | ConfigurationReply
            | SavedRuntimeStatus
            | SavedReadinessStatus
            | WowCaptureControlStatus;
          const operation = record(envelope.body).command;
          if (operation === "saved-readiness-status") {
            exact(record(envelope.body), ["command"]);
            result = {
              kind: "saved-readiness",
              serviceInstanceId: instanceId,
              servicePid: process.pid,
              receiverPid: native.child.pid!,
              ...controller.readiness(),
              firstTermination: (await native.rearmStatus()).firstTermination,
            };
          } else if (
            typeof operation === "string" &&
            operation.startsWith("wow-capture-")
          ) {
            const command = decodeWowCaptureCommand(envelope.body);
            if (!capture) {
              if (command.command !== "wow-capture-status")
                throw new Error("wow_capture_not_enabled");
              result = disabledWowCaptureStatus();
            } else result = await capture.request(command);
          } else if (
            operation === "activate-saved" ||
            operation === "saved-binding-status"
          ) {
            const command = decodeSavedRuntimeCommand(envelope.body);
            let activated: Snapshot | undefined;
            if (command.command === "activate-saved") {
              const pin = await configuration.readSavedPin({
                command: "configuration-saved-pin",
                expectedRevision: command.expectedConfigurationRevision,
                expectedSourceHash: command.expectedSourceHash,
                profileId: command.profileId,
              });
              activated = await controller.activateSaved(command, pin);
            }
            const bound = await native.savedStatus();
            if (
              activated &&
              (!bound.savedBinding ||
                activated.generation !== bound.snapshot.generation ||
                activated.revision !== bound.snapshot.revision)
            )
              throw new Error("saved_activation_unconfirmed");
            result = {
              kind: "saved-runtime",
              serviceInstanceId: instanceId,
              servicePid: process.pid,
              receiverPid: native.child.pid!,
              ...bound,
            };
          } else if (
            typeof operation === "string" &&
            operation.startsWith("configuration-")
          ) {
            result = await configuration.request(
              decodeConfigurationCommand(envelope.body),
            );
          } else if (
            typeof operation === "string" &&
            operation.startsWith("pairing-")
          ) {
            const command = decodePairingCommand(envelope.body);
            if (command.command === "pairing-revoke")
              await controller.execute({ command: "release" });
            result = await pairing.request(command);
          } else {
            const command = decodeLocalCommand(envelope.body);
            const snapshot = await controller.execute(
              command.command === "stop" ? { command: "release" } : command,
            );
            result = status(snapshot);
            if (command.command === "stop")
              socket.once("finish", () => void stop());
          }
          socket.end(
            JSON.stringify({
              version: 1,
              requestId,
              ok: true,
              result,
            }) + "\n",
          );
        } catch (error) {
          const code =
            error instanceof Error && /^[a-z_]+$/.test(error.message)
              ? error.message
              : "invalid_request";
          socket.end(
            JSON.stringify({ version: 1, requestId, ok: false, error: code }) +
              "\n",
          );
        }
      })();
    });
  });
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      server.off("error", reject);
      resolve();
    });
  });
  const endpointPath = join(directory, "endpoint.json");
  try {
    const old = lstatSync(endpointPath);
    if (!old.isFile() || old.nlink !== 1) throw new Error("unsafe_endpoint");
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT"))
      throw error;
  }
  const address = server.address();
  if (!address || typeof address === "string")
    throw new Error("service_bind_failed");
  const endpoint: Endpoint = {
    version: 1,
    instanceId,
    servicePid: process.pid,
    receiverPid: native.child.pid!,
    port: address.port,
    token,
    recordingLog,
  };
  const staged = join(directory, `endpoint-${instanceId}.json`);
  writeFileSync(staged, JSON.stringify(endpoint), { flag: "wx", mode: 0o600 });
  renameSync(staged, endpointPath);
  const heartbeat = setInterval(() => {
    void controller.renew().catch(() => void stop());
  }, 150);
  async function stop(): Promise<void> {
    if (stopping) return;
    stopping = true;
    pairing.disconnect();
    capture?.disconnect();
    clearInterval(heartbeat);
    try {
      await controller.execute({ command: "stop" });
    } catch {}
    native.disconnect();
    try {
      configuration.disconnect();
    } catch {
      process.exit(1);
    }
    for (const socket of sockets) socket.destroy();
    server.close();
    try {
      // Endpoint disappearance is the restart barrier. Wait for native locks.
      await Promise.all([
        waitForOwnerExit(native.child),
        waitForOwnerExit(pairing.child),
        waitForOwnerExit(configuration.child),
        ...(capture ? [waitForOwnerExit(capture.child)] : []),
      ]);
    } catch {
      process.exit(1);
    }
    try {
      const saved = record(parseStrictJson(readFileSync(endpointPath, "utf8")));
      if (saved.instanceId === instanceId) unlinkSync(endpointPath);
    } catch {}
    setTimeout(() => process.exit(0), 50);
  }
  process.on("SIGTERM", () => void stop());
  process.on("SIGINT", () => void stop());
  native.child.once("exit", () => void stop());
  pairing.child.once("exit", () => void stop());
  configuration.child.once("exit", () => void stop());
  server.on("error", () => void stop());
  if (
    native.child.exitCode !== null ||
    native.child.signalCode !== null ||
    pairing.child.exitCode !== null ||
    pairing.child.signalCode !== null ||
    configuration.child.exitCode !== null ||
    configuration.child.signalCode !== null
  )
    void stop();
}
