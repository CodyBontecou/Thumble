import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  exact,
  FRAME_BYTES,
  parseStrictJson,
  record,
} from "@thumble/contracts/receiver";

/** Bounded private stdio transport; codecs retain each native owner's domain boundary. */
export class NativePipe<Ready, Reply> {
  readonly child: ChildProcessWithoutNullStreams;
  readonly ready: Promise<Ready>;
  private pending = new Map<
    string,
    {
      resolve: (value: Reply) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  private buffer = Buffer.alloc(0);
  // [DEBUG-config-pipe] Temporary fixed phase/count evidence; never packet data.
  private diagnosticBytes = 0;
  private diagnosticFrames = 0;
  private diagnosticPhase:
    | "ready"
    | "parse"
    | "envelope"
    | "correlation"
    | "codec"
    | "delivery"
    | "waiting" = "ready";
  private diagnosticFailure:
    | "open"
    | "spawn"
    | "exit"
    | "stdin"
    | "startup"
    | "deadline"
    | "frame"
    | "disconnect" = "open";
  get diagnostics() {
    return Object.freeze({
      bytes: this.diagnosticBytes,
      frames: this.diagnosticFrames,
      phase: this.diagnosticPhase,
      failure: this.diagnosticFailure,
    });
  }
  private failed = false;
  private readySeen = false;
  private readyResolve!: (value: Ready) => void;
  private readyReject!: (error: Error) => void;
  constructor(
    executable: string,
    args: string[],
    private readonly codec: {
      ready: (value: Record<string, unknown>, pid: number | undefined) => Ready;
      reply: (value: Record<string, unknown>) => Reply;
    },
    private readonly unavailable: string,
  ) {
    this.ready = new Promise((resolve, reject) => {
      this.readyResolve = resolve;
      this.readyReject = reject;
    });
    this.child = spawn(executable, args, {
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      detached: process.platform === "win32",
    });
    this.child.stderr.resume();
    this.child.on("error", () => this.fail("spawn"));
    this.child.on("exit", () => this.fail("exit"));
    this.child.stdin.on("error", () => this.fail("stdin"));
    const startup = setTimeout(() => this.fail("startup"), 3000);
    void this.ready.finally(() => clearTimeout(startup)).catch(() => {});
    this.child.stdout.on("data", (chunk: Buffer) => {
      this.diagnosticBytes = Math.min(
        1048576,
        this.diagnosticBytes + chunk.byteLength,
      );
      this.buffer = Buffer.concat([this.buffer, chunk]);
      for (let newline; (newline = this.buffer.indexOf(10)) >= 0; ) {
        if (newline + 1 > FRAME_BYTES) return this.fail("frame");
        const frame = this.buffer.subarray(0, newline);
        this.buffer = this.buffer.subarray(newline + 1);
        try {
          this.diagnosticPhase = "parse";
          this.diagnosticFrames = Math.min(65536, this.diagnosticFrames + 1);
          this.receive(
            record(
              parseStrictJson(
                new TextDecoder("utf-8", { fatal: true }).decode(frame),
              ),
            ),
          );
        } catch {
          this.fail("frame");
          return;
        }
      }
      if (this.buffer.length > FRAME_BYTES) this.fail("frame");
    });
  }
  private receive(value: Record<string, unknown>): void {
    if (!this.readySeen) {
      const ready = this.codec.ready(value, this.child.pid);
      this.readySeen = true;
      this.readyResolve(ready);
      return;
    }
    this.diagnosticPhase = "envelope";
    if (
      value.version !== 1 ||
      typeof value.requestId !== "string" ||
      typeof value.ok !== "boolean"
    )
      throw new Error("invalid_native_response");
    this.diagnosticPhase = "correlation";
    const pending = this.pending.get(value.requestId);
    if (!pending) throw new Error("unexpected_native_response");
    if (value.ok) {
      this.diagnosticPhase = "codec";
      const reply = this.codec.reply(value);
      this.pending.delete(value.requestId);
      clearTimeout(pending.timer);
      this.diagnosticPhase = "delivery";
      pending.resolve(reply);
    } else {
      exact(value, ["version", "requestId", "ok", "error"]);
      if (typeof value.error !== "string" || !/^[a-z_]+$/.test(value.error))
        throw new Error("invalid_native_response");
      this.pending.delete(value.requestId);
      clearTimeout(pending.timer);
      pending.reject(new Error(value.error));
    }
  }
  private fail(reason: typeof this.diagnosticFailure): void {
    if (this.failed) return;
    this.diagnosticFailure = reason;
    this.failed = true;
    this.child.stdin.destroy();
    this.readyReject(new Error(this.unavailable));
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(new Error(this.unavailable));
    }
    this.pending.clear();
  }
  async request(body: unknown): Promise<Reply> {
    await this.ready;
    if (this.failed) throw new Error(this.unavailable);
    if (this.pending.size >= 16) throw new Error("native_owner_busy");
    const requestId = randomUUID(),
      line = JSON.stringify({ version: 1, requestId, body }) + "\n";
    if (Buffer.byteLength(line) > FRAME_BYTES)
      throw new Error("native_request_too_large");
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail("deadline"), 2000);
      this.pending.set(requestId, { resolve, reject, timer });
      this.diagnosticPhase = "waiting";
      this.child.stdin.write(line);
    });
  }
  disconnect(): void {
    this.fail("disconnect");
  }
}
