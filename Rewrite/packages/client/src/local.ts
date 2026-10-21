import { spawnSync } from "node:child_process";
import { decodeServiceStatus } from "./index.ts";
import { createConnection } from "node:net";
import {
  constants,
  closeSync,
  fstatSync,
  openSync,
  readSync,
  lstatSync,
  realpathSync,
} from "node:fs";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import {
  FRAME_BYTES,
  counter,
  decodeSnapshot,
  decodeLocalCommand,
  exact,
  identity,
  parseStrictJson,
  record,
  type LocalCommand,
  type ServiceStatus,
} from "@thumble/contracts/receiver";

export type Endpoint = {
  version: 1;
  instanceId: string;
  servicePid: number;
  receiverPid: number;
  port: number;
  token: string;
  recordingLog: string;
};
export function runtimeDirectory(path: string): string {
  if (!isAbsolute(path)) throw new Error("runtime_directory_must_be_absolute");
  return join(
    realpathSync(dirname(path)),
    resolve(path).split(/[\\/]/).at(-1)!,
  );
}
function boundedRead(fd: number, maximum: number): string {
  const buffer = Buffer.alloc(maximum + 1);
  let count = 0;
  while (count < buffer.length) {
    const read = readSync(fd, buffer, count, buffer.length - count, null);
    if (read === 0) break;
    count += read;
  }
  if (count > maximum) throw new Error("file_too_large");
  return new TextDecoder("utf-8", { fatal: true }).decode(
    buffer.subarray(0, count),
  );
}
export function readStateFile(path: string): unknown {
  const before = lstatSync(path);
  if (!before.isFile() || before.isSymbolicLink())
    throw new Error("unsafe_state_file");
  const fd = openSync(
    path,
    constants.O_RDONLY |
      (process.platform === "win32" ? 0 : constants.O_NOFOLLOW),
  );
  try {
    const metadata = fstatSync(fd);
    if (!metadata.isFile() || metadata.size > FRAME_BYTES)
      throw new Error("state_too_large");
    const text = boundedRead(fd, FRAME_BYTES);
    const after = fstatSync(fd);
    if (metadata.size !== after.size || metadata.mtimeMs !== after.mtimeMs)
      throw new Error("state_file_changed");
    return parseStrictJson(text);
  } finally {
    closeSync(fd);
  }
}
export function readEndpoint(directory: string, protector?: string): Endpoint {
  if (process.platform === "win32") {
    if (
      !protector ||
      spawnSync(protector, ["secure-directory", directory], {
        stdio: "ignore",
        windowsHide: true,
      }).status !== 0
    ) {
      throw new Error("runtime_directory_protection_failed");
    }
  }
  const fd = openSync(
    join(directory, "endpoint.json"),
    constants.O_RDONLY |
      (process.platform === "win32" ? 0 : constants.O_NOFOLLOW),
  );
  try {
    const stat = fstatSync(fd);
    if (
      !stat.isFile() ||
      stat.nlink !== 1 ||
      stat.size > 8192 ||
      (process.platform !== "win32" &&
        ((stat.mode & 0o077) !== 0 || stat.uid !== process.getuid?.()))
    )
      throw new Error("unsafe_endpoint");
    const value = record(parseStrictJson(boundedRead(fd, 8192)));
    exact(value, [
      "version",
      "instanceId",
      "servicePid",
      "receiverPid",
      "port",
      "token",
      "recordingLog",
    ]);
    if (
      value.version !== 1 ||
      !Number.isInteger(value.port) ||
      Number(value.port) < 1 ||
      Number(value.port) > 65535 ||
      typeof value.token !== "string" ||
      !/^[0-9a-f]{64}$/.test(value.token) ||
      typeof value.recordingLog !== "string" ||
      ![value.servicePid, value.receiverPid].every(
        (p) => Number.isSafeInteger(p) && Number(p) > 0,
      )
    )
      throw new Error("invalid_endpoint");
    return {
      version: 1,
      instanceId: identity(value.instanceId),
      servicePid: Number(value.servicePid),
      receiverPid: Number(value.receiverPid),
      port: Number(value.port),
      token: value.token,
      recordingLog: value.recordingLog,
    };
  } finally {
    closeSync(fd);
  }
}
export function request(
  endpoint: Endpoint,
  body: LocalCommand,
): Promise<ServiceStatus> {
  body = decodeLocalCommand(body);
  const requestId = randomUUID();
  return new Promise((resolve, reject) => {
    const socket = createConnection({ host: "127.0.0.1", port: endpoint.port });
    let buffer = Buffer.alloc(0);
    let settled = false;
    const fail = (code: string): void => {
      if (settled) return;
      settled = true;
      socket.destroy();
      reject(new Error(code));
    };
    socket.setTimeout(3000, () => fail("service_timeout"));
    socket.on("error", () => fail("service_unavailable"));
    socket.on("end", () => {
      if (!settled) fail("service_disconnected");
    });
    socket.on("connect", () =>
      socket.write(
        JSON.stringify({ version: 1, requestId, token: endpoint.token, body }) +
          "\n",
      ),
    );
    socket.on("data", (chunk) => {
      if (settled) return;
      buffer = Buffer.concat([
        buffer,
        typeof chunk === "string" ? Buffer.from(chunk) : chunk,
      ]);
      if (buffer.length > FRAME_BYTES) return fail("response_too_large");
      const newline = buffer.indexOf(10);
      if (newline < 0) return;
      try {
        const response = record(
          parseStrictJson(
            new TextDecoder("utf-8", { fatal: true }).decode(
              buffer.subarray(0, newline),
            ),
          ),
        );
        if (
          response.version !== 1 ||
          response.requestId !== requestId ||
          typeof response.ok !== "boolean"
        )
          throw new Error("invalid_service_response");
        if (response.ok === false) {
          exact(response, ["version", "requestId", "ok", "error"]);
          if (
            typeof response.error !== "string" ||
            !/^[a-z_]+$/.test(response.error)
          )
            throw new Error("invalid_service_response");
          return fail(response.error);
        }
        exact(response, ["version", "requestId", "ok", "result"]);
        const status = decodeServiceStatus(response.result);
        if (
          status.service.instanceId !== endpoint.instanceId ||
          status.service.pid !== endpoint.servicePid ||
          status.receiver.pid !== endpoint.receiverPid
        )
          throw new Error("service_identity_mismatch");
        settled = true;
        socket.destroy();
        resolve(status);
      } catch {
        fail("invalid_service_response");
      }
    });
  });
}
