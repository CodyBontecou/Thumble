import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { lstatSync, realpathSync } from "node:fs";
import { isAbsolute } from "node:path";
import {
  WOW_CAPTURE_LIMITS,
  parseWowCaptureRequest,
} from "@thumble/contracts/wow-capture";
import type { WowCaptureProvider } from "@thumble/application/wow-capture-supervisor";
/** This path is authorized only by the local service launcher, never an IPC request. */
export function captureHelperPath(path: string): string {
  if (!isAbsolute(path) || path.length > 4096 || path.includes("\0"))
    throw new Error("wow_capture_helper_invalid");
  try {
    const actual = realpathSync(path),
      stat = lstatSync(actual);
    if (
      !stat.isFile() ||
      (process.platform !== "win32" && !(stat.mode & 0o111))
    )
      throw new Error();
    return actual;
  } catch {
    throw new Error("wow_capture_helper_invalid");
  }
}
export type WowCaptureLauncher = (
  helper: string,
  args: readonly string[],
) => ChildProcessWithoutNullStreams;
const launchHelper: WowCaptureLauncher = (helper, args) =>
  spawn(helper, [...args], {
    stdio: ["pipe", "pipe", "pipe"],
    windowsHide: true,
  });
/** One child and one framed response in flight; no stdout/stderr payload is logged. */
export class NativeWowCaptureProvider implements WowCaptureProvider {
  readonly child: ChildProcessWithoutNullStreams;
  private header = Buffer.alloc(4);
  private headerAt = 0;
  private body: Buffer | undefined;
  private bodyAt = 0;
  private stderrBytes = 0;
  private failed = false;
  private stopRequested = false;
  private closed = false;
  private pending:
    | { resolve: (text: string) => void; reject: (error: Error) => void }
    | undefined;
  private readonly stopped: Promise<void>;
  private readonly replyLimit: number;
  constructor(
    helper: string,
    mode: "--capture" | "--status" | "--request-permission" = "--capture",
    launch: WowCaptureLauncher = launchHelper,
    private readonly unexpectedFailure?: () => void,
  ) {
    this.replyLimit =
      mode === "--capture" ? WOW_CAPTURE_LIMITS.replyBytes : 4096;
    this.child = launch(captureHelperPath(helper), [mode]);
    this.stopped = new Promise((resolve) =>
      this.child.once("close", () => {
        this.closed = true;
        this.fail();
        this.child.stdout.removeAllListeners("data");
        this.child.stderr.removeAllListeners("data");
        resolve();
      }),
    );
    this.child.on("error", () => this.fail());
    this.child.stdin.on("error", () => this.fail());
    this.child.stderr.on("data", (chunk: Buffer) => {
      this.stderrBytes += chunk.length;
      if (this.stderrBytes > 4096) this.fail();
    });
    this.child.stdout.on("data", (chunk: Buffer) => this.receive(chunk));
  }
  private fail(): void {
    const first = !this.failed;
    this.failed = true;
    if (first && !this.stopRequested) this.unexpectedFailure?.();
    this.body = undefined;
    this.pending?.reject(new Error("wow_capture_provider_unavailable"));
    this.pending = undefined;
    if (!this.closed) this.child.kill("SIGKILL");
  }
  private receive(chunk: Buffer): void {
    if (this.failed) return;
    let at = 0;
    while (at < chunk.length) {
      if (!this.pending) return this.fail();
      if (!this.body) {
        const count = Math.min(4 - this.headerAt, chunk.length - at);
        chunk.copy(this.header, this.headerAt, at, at + count);
        this.headerAt += count;
        at += count;
        if (this.headerAt !== 4) continue;
        const length = this.header.readUInt32BE();
        if (!length || length > this.replyLimit) return this.fail();
        this.body = Buffer.alloc(length);
        this.bodyAt = 0;
      }
      const count = Math.min(this.body.length - this.bodyAt, chunk.length - at);
      chunk.copy(this.body, this.bodyAt, at, at + count);
      this.bodyAt += count;
      at += count;
      if (this.bodyAt === this.body.length) {
        const body = this.body,
          pending = this.pending;
        this.body = undefined;
        this.headerAt = this.bodyAt = 0;
        this.pending = undefined;
        if (at !== chunk.length || body.some((value) => value > 127)) {
          pending.reject(new Error("wow_capture_provider_unavailable"));
          return this.fail();
        }
        pending.resolve(body.toString("ascii"));
      }
    }
  }
  capture(request: string): Promise<string> {
    parseWowCaptureRequest(request);
    if (this.pending || this.failed || this.closed)
      return Promise.reject(new Error("wow_capture_provider_unavailable"));
    const bytes = Buffer.from(request, "ascii"),
      header = Buffer.alloc(4);
    header.writeUInt32BE(bytes.length);
    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject };
      this.child.stdin.write(Buffer.concat([header, bytes]));
    });
  }
  /** Permission command has no capture request and is separate from receipt parsing. */
  permissionReply(): Promise<string> {
    if (this.pending || this.failed || this.closed)
      return Promise.reject(new Error("wow_capture_provider_unavailable"));
    return new Promise((resolve, reject) => {
      this.pending = { resolve, reject };
    });
  }
  stop(): Promise<void> {
    this.stopRequested = true;
    if (!this.closed) this.child.kill("SIGKILL");
    return this.stopped;
  }
}
