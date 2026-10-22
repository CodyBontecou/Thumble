import { createHash } from "node:crypto";
import { WowCaptureSupervisor } from "@thumble/application/wow-capture-supervisor";
import type { WowAtlasDecoder } from "@thumble/domain/wow-capture-receipt";
import { WowCapturedFrame } from "@thumble/domain/wow-capture-receipt";
import {
  decodeWowCaptureCommand,
  type WowCaptureCommand,
  type WowCaptureControlStatus,
  type WowCaptureReceiptMetadata,
} from "@thumble/contracts/wow-capture-control";
import type { WowCaptureProvider } from "@thumble/application/wow-capture-supervisor";
/** Explicit single-frame requests; no game freshness, observer ACK or authority effects. */
export class WowCaptureSession {
  private readonly supervisor: WowCaptureSupervisor;
  private source = 0;
  private failed = false;
  constructor(
    ports: Readonly<{
      clock: () => number;
      schedule: (delay: number, callback: () => void) => () => void;
      create: () => WowCaptureProvider;
      decodeAtlas: WowAtlasDecoder;
    }>,
  ) {
    this.supervisor = new WowCaptureSupervisor(ports);
  }
  async execute(input: WowCaptureCommand): Promise<WowCaptureControlStatus> {
    const command = decodeWowCaptureCommand(input);
    if (command.command === "wow-capture-start") {
      this.failed = false;
      if (this.source === 4294967295)
        throw new Error("wow_capture_source_exhausted");
      this.supervisor.start(++this.source);
      this.supervisor.request();
    } else if (command.command === "wow-capture-request")
      this.supervisor.request();
    else if (command.command === "wow-capture-stop") {
      this.failed = false;
      await this.supervisor.stop();
    }
    return this.status();
  }
  private latest: WowCaptureReceiptMetadata | undefined;
  status(): WowCaptureControlStatus {
    const result = this.supervisor.take();
    if (result) {
      this.latest =
        result instanceof WowCapturedFrame
          ? {
              source: result.source,
              generation: result.generation,
              receipt: result.receipt,
              observedAtMs: result.observedAtMs,
              kind: "frame",
              frameSha256: createHash("sha256")
                .update(result.frame())
                .digest("hex"),
              atlasSha256: createHash("sha256")
                .update(result.atlasPNG())
                .digest("hex"),
              atlasBytes: result.atlasPNG().length,
            }
          : { ...result };
    }
    if (this.latest && !this.supervisor.isCurrent(this.latest))
      this.latest = undefined;
    const status = this.supervisor.status();
    return {
      kind: "wow-capture",
      enabled: true,
      state: this.failed ? "unavailable" : this.latest ? "ready" : status.state,
      permission: "not-inspected",
      source: status.source ?? null,
      generation: status.generation ?? null,
      receipt: this.latest ?? null,
    };
  }
  providerUnavailable(): void {
    this.failed = true;
    this.latest = undefined;
    void this.supervisor.stop();
  }
  async stop(): Promise<void> {
    await this.supervisor.stop();
  }
}
