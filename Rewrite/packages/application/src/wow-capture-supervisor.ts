import {
  encodeWowCaptureRequest,
  parseWowCaptureReply,
  wowCaptureCounter,
  type WowCaptureIdentity,
  type WowCaptureStatus,
} from "@thumble/contracts/wow-capture";
import {
  WowCapturedFrame,
  type WowAtlasDecoder,
} from "@thumble/domain/wow-capture-receipt";
export const WOW_CAPTURE_TIMING = Object.freeze({
  captureMs: 2000,
  stopMs: 500,
  receiptMs: 2000,
});
export interface WowCaptureProvider {
  /** Adapter enforces framed reply limits before allocation and uses a fresh child
   * connection. It never resolves with whole-window pixels or arbitrary files. */
  capture(request: string): Promise<string>;
  /** Resolves only after confirmed termination and removal of all child listeners. */
  stop(): Promise<void>;
}
export type WowCaptureResult =
  | WowCapturedFrame
  | Readonly<
      WowCaptureIdentity & {
        kind: "status";
        status: WowCaptureStatus;
        observedAtMs: number;
      }
    >;
export type WowCaptureStop = "stopped" | "unavailable";
type Context = Readonly<{ source: number; generation: string }>;
type Attempt = {
  identity: WowCaptureIdentity;
  deadline: number;
  cancel: () => void;
};
type Slot = {
  provider: WowCaptureProvider;
  context: Context;
  attempt: Attempt | undefined;
  retiring: boolean;
  stopReply: Promise<WowCaptureStop> | undefined;
  finishStop: ((outcome: WowCaptureStop) => void) | undefined;
  cancelStop: (() => void) | undefined;
};
/** Dedicated capture owner. No observer/authority/input calls and no real child
 * composition. Injected timers must run asynchronously on their owner queue. */
export class WowCaptureSupervisor {
  #context: Context | undefined;
  #generation = 0n;
  #receipt = 0n;
  #highWater: number | undefined;
  #slot: Slot | undefined;
  #latest: WowCaptureResult | undefined;
  #issued: Readonly<WowCaptureIdentity & { observedAtMs: number }> | undefined;
  #coalesced = false;
  #unavailable = false;
  constructor(
    private readonly ports: Readonly<{
      clock: () => number;
      schedule: (delayMs: number, callback: () => void) => () => void;
      create: () => WowCaptureProvider;
      decodeAtlas: WowAtlasDecoder;
    }>,
    lastGeneration = "0",
    lastReceipt = "0",
  ) {
    this.#generation = BigInt(wowCaptureCounter(lastGeneration, true));
    this.#receipt = BigInt(wowCaptureCounter(lastReceipt, true));
  }
  #now(): number | undefined {
    let now: number;
    try {
      now = this.ports.clock();
    } catch {
      now = NaN;
    }
    if (
      !Number.isSafeInteger(now) ||
      now < 0 ||
      (this.#highWater !== undefined && now < this.#highWater)
    ) {
      this.#context = undefined;
      this.#latest = this.#issued = undefined;
      this.#coalesced = false;
      this.#unavailable = true;
      if (this.#slot) this.#retire(this.#slot);
      return undefined;
    }
    this.#highWater = now;
    return now;
  }
  /** Opaque source comes from an independent game-only selector, never a HWND. */
  start(source: number): void {
    if (!Number.isInteger(source) || source < 1 || source > 4294967295)
      throw new Error("invalid_wow_capture_source");
    if (this.#now() === undefined)
      throw new Error("wow_capture_clock_unavailable");
    if (this.#generation === 18446744073709551615n) {
      this.stop();
      throw new Error("wow_capture_generation_exhausted");
    }
    this.#context = Object.freeze({
      source,
      generation: (++this.#generation).toString(),
    });
    this.#latest = this.#issued = undefined;
    this.#coalesced = false;
    this.#unavailable = false;
    if (this.#slot) this.#retire(this.#slot);
  }
  /** Resize and device reset must call start again, even for the same source. */
  request(): void {
    if (this.#now() === undefined || !this.#context || this.#unavailable)
      return;
    this.#latest = this.#issued = undefined;
    this.#coalesced = true;
    this.#run();
  }
  #run(): void {
    if (!this.#coalesced || !this.#context || this.#unavailable) return;
    const now = this.#now();
    if (now === undefined) return;
    if (
      this.#receipt === 18446744073709551615n ||
      now > Number.MAX_SAFE_INTEGER - WOW_CAPTURE_TIMING.captureMs
    ) {
      this.#fail();
      return;
    }
    let slot = this.#slot;
    if (slot?.retiring || slot?.attempt) return;
    if (!slot) {
      try {
        slot = {
          provider: this.ports.create(),
          context: this.#context,
          attempt: undefined,
          retiring: false,
          stopReply: undefined,
          finishStop: undefined,
          cancelStop: undefined,
        };
        this.#slot = slot;
      } catch {
        this.#fail();
        return;
      }
    }
    if (slot.context !== this.#context) return;
    this.#coalesced = false;
    const identity = Object.freeze({
      ...this.#context,
      receipt: (++this.#receipt).toString(),
    });
    const attempt: Attempt = {
      identity,
      deadline: now + WOW_CAPTURE_TIMING.captureMs,
      cancel: () => {},
    };
    slot.attempt = attempt;
    const owned = slot;
    attempt.cancel = this.ports.schedule(WOW_CAPTURE_TIMING.captureMs, () => {
      if (this.#slot === owned && owned.attempt === attempt && !owned.retiring)
        this.#fail();
    });
    let response: Promise<string>;
    try {
      response = owned.provider.capture(
        encodeWowCaptureRequest({
          version: 1,
          command: "wow-capture",
          ...identity,
        }),
      );
    } catch {
      this.#fail();
      return;
    }
    response.then(
      (text) => {
        if (
          this.#slot !== owned ||
          owned.retiring ||
          owned.attempt !== attempt ||
          this.#context !== owned.context
        )
          return;
        const received = this.#now();
        if (received === undefined) return;
        if (received >= attempt.deadline) {
          this.#fail();
          return;
        }
        try {
          const reply = parseWowCaptureReply(text, identity);
          const result: WowCaptureResult =
            reply.kind === "frame"
              ? new WowCapturedFrame(reply, received, this.ports.decodeAtlas)
              : Object.freeze({
                  ...identity,
                  kind: "status",
                  status: reply.status,
                  observedAtMs: received,
                });
          const verifiedAt = this.#now();
          if (verifiedAt === undefined) return;
          if (
            this.#context !== owned.context ||
            owned.retiring ||
            owned.attempt !== attempt
          )
            return;
          if (verifiedAt >= attempt.deadline) {
            this.#fail();
            return;
          }
          attempt.cancel();
          owned.attempt = undefined;
          this.#latest = result;
          this.#issued = undefined;
          if (this.#coalesced) {
            this.#latest = undefined;
            this.#run();
          }
        } catch {
          this.#fail();
        }
      },
      () => {
        if (
          this.#slot === owned &&
          !owned.retiring &&
          owned.attempt === attempt
        )
          this.#fail();
      },
    );
  }
  #fail(): void {
    this.#context = undefined;
    this.#latest = this.#issued = undefined;
    this.#coalesced = false;
    this.#unavailable = true;
    if (this.#slot) this.#retire(this.#slot);
  }
  #retire(slot: Slot): Promise<WowCaptureStop> {
    if (slot.stopReply) return slot.stopReply;
    slot.retiring = true;
    slot.attempt?.cancel();
    slot.stopReply = new Promise((resolve) => {
      slot.finishStop = resolve;
    });
    slot.cancelStop = this.ports.schedule(WOW_CAPTURE_TIMING.stopMs, () => {
      slot.finishStop?.("unavailable");
      slot.finishStop = undefined;
    });
    let stopped: Promise<void>;
    try {
      stopped = slot.provider.stop();
    } catch {
      slot.finishStop?.("unavailable");
      slot.finishStop = undefined;
      return slot.stopReply;
    }
    stopped.then(
      () => {
        slot.cancelStop?.();
        slot.finishStop?.("stopped");
        slot.finishStop = undefined;
        if (this.#slot === slot) {
          this.#slot = undefined;
          this.#run();
        }
      },
      () => {
        slot.cancelStop?.();
        slot.finishStop?.("unavailable");
        slot.finishStop = undefined;
      },
    );
    return slot.stopReply;
  }
  /** Bounded caller wait; an unconfirmed stop still owns the provider slot. */
  stop(): Promise<WowCaptureStop> {
    this.#context = undefined;
    this.#latest = this.#issued = undefined;
    this.#coalesced = false;
    return this.#slot ? this.#retire(this.#slot) : Promise.resolve("stopped");
  }
  take(): WowCaptureResult | undefined {
    const now = this.#now(),
      result = this.#latest;
    if (
      now === undefined ||
      !result ||
      !this.#context ||
      now - result.observedAtMs >= WOW_CAPTURE_TIMING.receiptMs
    ) {
      this.#latest = undefined;
      return undefined;
    }
    this.#latest = undefined;
    this.#issued = Object.freeze({
      source: result.source,
      generation: result.generation,
      receipt: result.receipt,
      observedAtMs: result.observedAtMs,
    });
    return result;
  }
  /** Consumers recheck at their own boundary; this never acknowledges an observer. */
  isCurrent(identity: WowCaptureIdentity): boolean {
    const now = this.#now(),
      issued = this.#issued;
    if (
      now === undefined ||
      !issued ||
      !this.#context ||
      now - issued.observedAtMs >= WOW_CAPTURE_TIMING.receiptMs
    )
      return false;
    return (
      issued.source === identity.source &&
      issued.generation === identity.generation &&
      issued.receipt === identity.receipt
    );
  }
  status(): Readonly<{
    state:
      | "stopped"
      | "waiting"
      | "capturing"
      | "stopping"
      | "ready"
      | "unavailable";
    source?: number;
    generation?: string;
  }> {
    const now = this.#now();
    if (
      now !== undefined &&
      this.#latest &&
      now - this.#latest.observedAtMs >= WOW_CAPTURE_TIMING.receiptMs
    )
      this.#latest = undefined;
    const state =
      now === undefined
        ? "unavailable"
        : this.#slot?.retiring
          ? "stopping"
          : this.#unavailable
            ? "unavailable"
            : !this.#context
              ? "stopped"
              : this.#slot?.attempt
                ? "capturing"
                : this.#latest
                  ? "ready"
                  : "waiting";
    return Object.freeze({ state, ...this.#context });
  }
}
