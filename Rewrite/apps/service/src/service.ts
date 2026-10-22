import { NativePairingHost } from "./native-pairing.ts";
import {
  decodePairingCommand,
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
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { RuntimeController } from "@thumble/application";
import {
  decodeLocalCommand,
  exact,
  FRAME_BYTES,
  identity,
  parseStrictJson,
  record,
  type ServiceStatus,
} from "@thumble/contracts/receiver";
import { runtimeDirectory, type Endpoint } from "@thumble/client/local";
import { NativeReceiver } from "./native-receiver.ts";

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
export async function serve(
  executable: string,
  path: string,
  identityDirectory?: string,
): Promise<void> {
  const directory = secureDirectory(executable, path),
    instanceId = randomUUID(),
    token = randomBytes(32).toString("hex");
  const recordingLog = join(directory, `receiver-${instanceId}.jsonl`);
  const native = new NativeReceiver(executable, directory, recordingLog);
  await native.ready;
  const controller = new RuntimeController(native, randomUUID);
  const pairing = new NativePairingHost(
    executable,
    directory,
    instanceId,
    identityDirectory,
  );
  await pairing.ready;
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
          let result: ServiceStatus | PairingReply;
          const operation = record(envelope.body).command;
          if (
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
    clearInterval(heartbeat);
    try {
      await controller.execute({ command: "stop" });
    } catch {}
    native.disconnect();
    for (const socket of sockets) socket.destroy();
    server.close();
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
  server.on("error", () => void stop());
  if (
    native.child.exitCode !== null ||
    native.child.signalCode !== null ||
    pairing.child.exitCode !== null ||
    pairing.child.signalCode !== null
  )
    void stop();
}
