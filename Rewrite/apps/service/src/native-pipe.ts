import { NativeInputErrorForwarder } from "./native-input-error-diagnostic.ts";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import {
  exact,
  FRAME_BYTES,
  parseStrictJson,
  record,
} from "@thumble/contracts/receiver";

export type ParsedOwnerOutcome<Reply> =
  | { kind: "owner-response"; ok: true; result: Reply }
  | { kind: "owner-response"; ok: false; error: string }
  | { kind: "not-dispatched"; error: string };
/** This request may have reached its owner. It is never a no-op receipt. */
export class NativePipeTransportLost extends Error {
  constructor() {
    super("native_owner_transport_lost");
  }
}

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
      ownerError?: (error: string) => void;
    }
  >();
  private buffer = Buffer.alloc(0);
  private failed = false;
  private readySeen = false;
  private diagnosticCount = 0;
  private diagnosticReadCount = 0;
  private readyResolve!: (value: Ready) => void;
  private readyReject!: (error: Error) => void;
  constructor(
    executable: string,
    args: string[],
    private readonly codec: {
      ready: (value: Record<string, unknown>, pid: number | undefined) => Ready;
      reply: (value: Record<string, unknown>) => Reply;
      event?: (value: Record<string, unknown>) => void;
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
    if (process.env.THUMBLE_REWRITE_INPUT_ERROR_PROBE === "1") {
      const errors = new NativeInputErrorForwarder((line) =>
        process.stderr.write(line + "\n", () => {}),
      );
      this.child.stderr.on("data", (chunk: Buffer) => errors.push(chunk));
    } else this.child.stderr.resume();
    this.child.on("error", () => this.fail("child-error"));
    this.child.on("exit", () => this.fail("child-exit"));
    this.child.stdin.on("error", () => this.fail("stdin-error"));
    const startup = setTimeout(() => this.fail("startup-timeout"), 3000);
    void this.ready.finally(() => clearTimeout(startup)).catch(() => {});
    this.child.stdout.on("data", (chunk: Buffer) => {
      if (
        process.env.THUMBLE_REWRITE_PIPE_PROBE === "1" &&
        this.diagnosticReadCount++ < 16
      )
        console.error(
          `[DEBUG-native-pipe-read] chunkBytes=${chunk.length} ready=${this.readySeen} failed=${this.failed} pending=${this.pending.size} flowing=${this.child.stdout.readableFlowing} readableBytes=${this.child.stdout.readableLength}`,
        );
      this.buffer = Buffer.concat([this.buffer, chunk]);
      for (let newline; (newline = this.buffer.indexOf(10)) >= 0; ) {
        if (newline + 1 > FRAME_BYTES) return this.fail("frame-too-large");
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
          this.fail("receive-invalid");
          return;
        }
      }
      if (this.buffer.length > FRAME_BYTES) this.fail("frame-too-large");
    });
  }
  private receive(value: Record<string, unknown>): void {
    if (!this.readySeen) {
      const ready = this.codec.ready(value, this.child.pid);
      this.readySeen = true;
      this.readyResolve(ready);
      return;
    }
    if (Object.hasOwn(value, "event")) {
      if (!this.codec.event) throw new Error("unexpected_native_event");
      this.codec.event(value);
      return;
    }
    if (
      value.version !== 1 ||
      typeof value.requestId !== "string" ||
      typeof value.ok !== "boolean"
    )
      throw new Error("invalid_native_response");
    const pending = this.pending.get(value.requestId);
    if (!pending) throw new Error("unexpected_native_response");
    if (value.ok) {
      const reply = this.codec.reply(value);
      this.pending.delete(value.requestId);
      clearTimeout(pending.timer);
      pending.resolve(reply);
    } else {
      exact(value, ["version", "requestId", "ok", "error"]);
      if (
        typeof value.error !== "string" ||
        !/^[a-z_]+$/.test(value.error) ||
        (pending.ownerError !== undefined && value.error.length > 100)
      )
        throw new Error("invalid_native_response");
      this.pending.delete(value.requestId);
      clearTimeout(pending.timer);
      if (pending.ownerError) pending.ownerError(value.error);
      else pending.reject(new Error(value.error));
    }
  }
  private fail(
    reason:
      | "child-error"
      | "child-exit"
      | "stdin-error"
      | "startup-timeout"
      | "frame-too-large"
      | "receive-invalid"
      | "request-timeout"
      | "disconnect",
  ): void {
    if (
      process.env.THUMBLE_REWRITE_PIPE_PROBE === "1" &&
      this.diagnosticCount++ < 32
    )
      console.error(
        `[DEBUG-native-pipe] reason=${reason} ready=${this.readySeen} failed=${this.failed} pending=${this.pending.size} bufferedBytes=${this.buffer.length} flowing=${this.child.stdout.readableFlowing} readableBytes=${this.child.stdout.readableLength} stdoutDestroyed=${this.child.stdout.destroyed}`,
      );
    if (this.failed) return;
    this.failed = true;
    this.child.stdin.destroy();
    this.readyReject(new Error(this.unavailable));
    for (const request of this.pending.values()) {
      clearTimeout(request.timer);
      request.reject(new Error(this.unavailable));
    }
    this.pending.clear();
  }
  async request(body: unknown, timeoutMs = 2000): Promise<Reply> {
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30000)
      throw new Error("native_request_budget_invalid");
    await this.ready;
    if (this.failed) throw new Error(this.unavailable);
    if (this.pending.size >= 16) throw new Error("native_owner_busy");
    const requestId = randomUUID(),
      line = JSON.stringify({ version: 1, requestId, body }) + "\n";
    if (Buffer.byteLength(line) > FRAME_BYTES)
      throw new Error("native_request_too_large");
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail("request-timeout"), timeoutMs);
      this.pending.set(requestId, { resolve, reject, timer });
      this.child.stdin.write(line);
    });
  }
  /** Private write transport: only parsed replies are definitive owner responses.
   * Caller must retain its fence after transport loss until actual writer exit. */
  async requestParsed(
    body: unknown,
    timeoutMs = 30000,
  ): Promise<ParsedOwnerOutcome<Reply>> {
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 30000)
      return { kind: "not-dispatched", error: "native_request_budget_invalid" };
    try {
      await this.ready;
    } catch {
      return { kind: "not-dispatched", error: this.unavailable };
    }
    if (this.failed) return { kind: "not-dispatched", error: this.unavailable };
    if (this.pending.size >= 16)
      return { kind: "not-dispatched", error: "native_owner_busy" };
    const requestId = randomUUID();
    let line: string;
    try {
      line = JSON.stringify({ version: 1, requestId, body }) + "\n";
    } catch {
      return { kind: "not-dispatched", error: "native_request_invalid" };
    }
    if (Buffer.byteLength(line) > FRAME_BYTES)
      return { kind: "not-dispatched", error: "native_request_too_large" };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail("request-timeout"), timeoutMs);
      this.pending.set(requestId, {
        resolve: (result) =>
          resolve({ kind: "owner-response", ok: true, result }),
        ownerError: (error) =>
          resolve({ kind: "owner-response", ok: false, error }),
        reject: () => reject(new NativePipeTransportLost()),
        timer,
      });
      // Registration precedes the write: synchronous/partial write failures are uncertain too.
      try {
        this.child.stdin.write(line);
      } catch {
        this.fail("stdin-error");
      }
    });
  }
  /** Private, bounded event response; no request timer or pending RPC slot. */
  writeEvent(value: unknown): void {
    if (!this.readySeen || this.failed) throw new Error(this.unavailable);
    const line = JSON.stringify(value) + "\n";
    if (
      Buffer.byteLength(line) > 32768 ||
      this.child.stdin.writableLength > FRAME_BYTES
    )
      throw new Error("native_event_backpressure");
    this.child.stdin.write(line);
  }
  disconnect(): void {
    this.fail("disconnect");
  }
}
