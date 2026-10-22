import { decodeWowCaptureCommand } from "@thumble/contracts/wow-capture-control";
import {
  FRAME_BYTES,
  exact,
  identity,
  parseStrictJson,
  record,
} from "@thumble/contracts/receiver";
import {
  NativeWowCaptureProvider,
  captureHelperPath,
} from "./wow-capture-provider.ts";
import { decodeWowAtlas } from "./wow-atlas-decoder.ts";
import { WowCaptureSession } from "./wow-capture-session.ts";
/** All large PNG processing stays in this process, isolated from receiver renewal. */
export async function runWowCaptureOwner(helper: string): Promise<void> {
  const path = captureHelperPath(helper);
  const providers = new Set<NativeWowCaptureProvider>();
  const session = new WowCaptureSession({
    clock: () => Math.floor(performance.now()),
    schedule: (delay, callback) => {
      const timer = setTimeout(callback, delay);
      return () => clearTimeout(timer);
    },
    create: () => {
      const provider = new NativeWowCaptureProvider(
        path,
        "--capture",
        undefined,
        () => session.providerUnavailable(),
      );
      providers.add(provider);
      provider.child.once("close", () => providers.delete(provider));
      return provider;
    },
    decodeAtlas: decodeWowAtlas,
  });
  let buffer = Buffer.alloc(0),
    busy = false,
    ended = false;
  const finish = () => {
    if (ended) return;
    ended = true;
    process.stdin.pause();
    void session
      .stop()
      .then(() => Promise.all([...providers].map((p) => p.stop())))
      .then(() => process.exit(0));
  };
  process.on("SIGTERM", finish);
  process.on("SIGINT", finish);
  process.stdin.on("end", finish);
  process.stdin.on("error", finish);
  process.stdout.on("error", finish);
  const write = (value: unknown) => {
    const line = JSON.stringify(value) + "\n";
    if (
      Buffer.byteLength(line) > FRAME_BYTES ||
      process.stdout.writableLength > FRAME_BYTES * 2
    ) {
      finish();
      return;
    }
    process.stdout.write(line);
  };
  const pump = async () => {
    if (busy || ended) return;
    busy = true;
    try {
      for (let newline; (newline = buffer.indexOf(10)) >= 0 && !ended; ) {
        if (newline + 1 > FRAME_BYTES) throw new Error();
        const line = buffer.subarray(0, newline);
        buffer = buffer.subarray(newline + 1);
        const envelope = record(
          parseStrictJson(
            new TextDecoder("utf-8", { fatal: true }).decode(line),
          ),
        );
        exact(envelope, ["version", "requestId", "body"]);
        if (envelope.version !== 1) throw new Error();
        const requestId = identity(envelope.requestId);
        try {
          const result = await session.execute(
            decodeWowCaptureCommand(envelope.body),
          );
          write({ version: 1, requestId, ok: true, result });
        } catch {
          write({
            version: 1,
            requestId,
            ok: false,
            error: "wow_capture_unavailable",
          });
        }
      }
    } catch {
      finish();
    } finally {
      busy = false;
    }
  };
  process.stdin.on("data", (chunk: Buffer) => {
    if (ended) return;
    if (buffer.length + chunk.length > FRAME_BYTES * 16) {
      finish();
      return;
    }
    buffer = Buffer.concat([buffer, chunk]);
    void pump();
  });
  write({ version: 1, ready: "wow-capture", pid: process.pid });
  await new Promise<void>(() => {});
}
