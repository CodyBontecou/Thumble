import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  decodeSnapshot,
  exact,
  FRAME_BYTES,
  parseStrictJson,
  record,
  type ReceiverCommand,
  type Snapshot,
} from "@thumble/contracts/receiver";
import type { ReceiverPort } from "@thumble/application";
export class NativeReceiver implements ReceiverPort {
  readonly child: ChildProcessWithoutNullStreams;
  private pending = new Map<
    string,
    {
      resolve: (s: Snapshot) => void;
      reject: (e: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  private buffer = Buffer.alloc(0);
  private failed = false;
  private readyResolve!: (s: Snapshot) => void;
  private readyReject!: (e: Error) => void;
  private readySeen = false;
  readonly ready: Promise<Snapshot>;
  constructor(executable: string, directory: string, recordingLog: string) {
    this.ready = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });
    this.child = spawn(executable, ["run", directory, recordingLog], {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      // The safety owner must survive abrupt Windows service termination.
      // Preserve private pipes with an independent native process lifetime.
      detached: process.platform === "win32",
    });
    this.child.stderr.resume();
    this.child.on("error", () => this.fail());
    this.child.on("exit", () => this.fail());
    this.child.stdin.on("error", () => this.fail());
    const startup = setTimeout(() => this.fail(), 3000);
    void this.ready.finally(() => clearTimeout(startup)).catch(() => {});
    this.child.stdout.on("data", (chunk: Buffer) => {
      this.buffer = Buffer.concat([this.buffer, chunk]);
      if (this.buffer.length > FRAME_BYTES) return this.fail();
      for (let newline; (newline = this.buffer.indexOf(10)) >= 0; ) {
        const frame = this.buffer.subarray(0, newline);
        this.buffer = this.buffer.subarray(newline + 1);
        try {
          this.receive(
            record(
              parseStrictJson(
                new TextDecoder("utf-8", { fatal: true }).decode(frame),
              ),
            ),
          );
        } catch {
          this.fail();
          return;
        }
      }
    });
  }
  private receive(value: Record<string, unknown>): void {
    if (!this.readySeen) {
      exact(value, ["version", "ready", "pid", "snapshot"]);
      if (
        value.version !== 1 ||
        value.ready !== true ||
        value.pid !== this.child.pid
      )
        throw new Error("invalid_ready");
      this.readySeen = true;
      this.readyResolve(decodeSnapshot(value.snapshot));
      return;
    }
    if (
      value.version !== 1 ||
      typeof value.requestId !== "string" ||
      typeof value.ok !== "boolean"
    )
      throw new Error("invalid_response");
    const pending = this.pending.get(value.requestId);
    if (!pending) throw new Error("unexpected_response");
    if (value.ok) {
      exact(value, ["version", "requestId", "ok", "snapshot"]);
      const snapshot = decodeSnapshot(value.snapshot);
      this.pending.delete(value.requestId);
      clearTimeout(pending.timer);
      pending.resolve(snapshot);
    } else {
      exact(value, ["version", "requestId", "ok", "error"]);
      if (typeof value.error !== "string" || !/^[a-z_]+$/.test(value.error))
        throw new Error("invalid_response");
      this.pending.delete(value.requestId);
      clearTimeout(pending.timer);
      pending.reject(new Error(value.error));
    }
  }
  private fail(): void {
    if (this.failed) return;
    this.failed = true;
    this.child.stdin.destroy();
    this.readyReject(new Error("receiver_unavailable"));
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(new Error("receiver_unavailable"));
    }
    this.pending.clear();
  }
  async request(body: ReceiverCommand): Promise<Snapshot> {
    await this.ready;
    if (this.failed) throw new Error("receiver_unavailable");
    if (this.pending.size >= 16) throw new Error("receiver_busy");
    const requestId = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail(), 2000);
      this.pending.set(requestId, { resolve, reject, timer });
      this.child.stdin.write(
        JSON.stringify({ version: 1, requestId, body }) + "\n",
      );
    });
  }
  disconnect(): void {
    this.fail();
  }
}
