import {
  deserializeMessage,
  type JSONRPCMessage,
  type Transport,
} from "@modelcontextprotocol/server";
import { FRAME_BYTES, parseStrictJson } from "@thumble/contracts/receiver";
import type { Readable, Writable } from "node:stream";

/** One bounded stdio connection. Never logs message bodies or service credentials. */
export class BoundedStdioTransport implements Transport {
  onclose: Transport["onclose"];
  onerror: Transport["onerror"];
  onmessage: Transport["onmessage"];
  private started = false;
  private closed = false;
  private buffer = Buffer.alloc(0);
  private pending = new Set<string | number>();
  private outputBytes = 0;
  private writes = new Set<(error?: Error) => void>();
  constructor(
    private input: Readable,
    private output: Writable,
  ) {}
  async start(): Promise<void> {
    if (this.started || this.closed)
      throw new Error("mcp_transport_unavailable");
    this.started = true;
    this.input.on("data", this.data);
    this.input.on("end", this.end);
    this.input.on("close", this.end);
    if (this.input.readableEnded || this.input.destroyed)
      queueMicrotask(this.end);
    this.input.on("error", this.error);
    this.output.on("error", this.error);
  }
  private end = (): void => {
    void this.close();
  };
  private error = (): void => {
    if (this.closed) return;
    this.onerror?.(new Error("mcp_transport_unavailable"));
    void this.close();
  };
  private data = (chunk: Buffer): void => {
    if (this.closed) return;
    try {
      // Scan incrementally so a chunk containing several valid frames is allowed,
      // but an unterminated frame never accumulates beyond the byte budget.
      let start = 0;
      while (start < chunk.length && !this.closed) {
        const newline = chunk.indexOf(10, start);
        const end = newline < 0 ? chunk.length : newline;
        if (this.buffer.length + end - start > FRAME_BYTES) throw new Error();
        this.buffer = Buffer.concat([this.buffer, chunk.subarray(start, end)]);
        if (newline < 0) break;
        const text = new TextDecoder("utf-8", { fatal: true }).decode(
          this.buffer,
        );
        this.buffer = Buffer.alloc(0);
        parseStrictJson(text);
        const message = deserializeMessage(text);
        if ("method" in message && "id" in message) {
          if (
            (typeof message.id === "string" && message.id.length > 128) ||
            (typeof message.id === "number" &&
              !Number.isSafeInteger(message.id)) ||
            this.pending.size >= 16 ||
            this.pending.has(message.id)
          )
            throw new Error();
          this.pending.add(message.id);
        }
        this.onmessage?.(message);
        start = end + 1;
      }
    } catch {
      this.onerror?.(new Error("mcp_invalid_or_excessive_message"));
      void this.close();
    }
  };
  async send(message: JSONRPCMessage): Promise<void> {
    if (this.closed) throw new Error("mcp_transport_closed");
    const line = Buffer.from(JSON.stringify(message) + "\n");
    if (line.length > FRAME_BYTES || this.outputBytes + line.length > 262144) {
      await this.close();
      throw new Error("mcp_output_limit");
    }
    this.outputBytes += line.length;
    await new Promise<void>((resolve, reject) => {
      const done = (error?: Error): void => {
        if (!this.writes.delete(done)) return;
        clearTimeout(timer);
        this.outputBytes -= line.length;
        if (error) reject(new Error("mcp_output_unavailable"));
        else {
          if (
            !("method" in message) &&
            "id" in message &&
            message.id !== null &&
            message.id !== undefined
          )
            this.pending.delete(message.id);
          resolve();
        }
      };
      const timer = setTimeout(() => {
        done(new Error());
        void this.close();
      }, 3000);
      this.writes.add(done);
      this.output.write(line, (error) => done(error ?? undefined));
    });
  }
  async close(): Promise<void> {
    if (this.closed) return;
    this.closed = true;
    this.input.off("data", this.data);
    this.input.off("end", this.end);
    this.input.off("close", this.end);
    this.input.off("error", this.error);
    // Keep the bounded error listener to absorb a late EPIPE after cancellation.
    this.input.pause();
    this.buffer = Buffer.alloc(0);
    this.pending.clear();
    for (const done of this.writes) done(new Error());
    this.onclose?.();
  }
}
