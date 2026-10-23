import { WowCapturedFrame } from "@thumble/domain/wow-capture-receipt";
import { WowLiveObserver } from "./wow-live-observer.ts";
import {
  WowRefreshObservation,
  WowRefreshCancellation,
  type WowProfileRefresh,
  type WowProfileRefreshOutcome,
} from "./wow-profile-refresh.ts";

export type WowSyncOutcome =
  | WowProfileRefreshOutcome
  | Readonly<{ kind: "observing" | "busy" | "stopped" }>;
/** One capture/prepare/commit pipeline. Caller must not issue a replacement capture
 * while busy: the completing frame's supervisor receipt stays the admission fence.
 * Capture and native input lifecycles remain independent owner responsibilities. */
export class WowSyncSession {
  readonly #observer = new WowLiveObserver();
  readonly #abort = new WowRefreshCancellation();
  #pending: WowRefreshObservation | undefined;
  #busy = false;
  #token = 0;
  #clock: number | undefined;
  #stopped = false;
  constructor(
    private readonly ports: Readonly<{
      clock: () => number;
      currentCapture: (frame: WowCapturedFrame) => boolean;
      refresh: Pick<WowProfileRefresh, "execute">;
    }>,
  ) {}
  get busy(): boolean {
    return this.#busy;
  }
  #now(): number | undefined {
    let now: number;
    try {
      now = this.ports.clock();
    } catch {
      this.stop();
      return;
    }
    if (
      !Number.isSafeInteger(now) ||
      now < 0 ||
      (this.#clock !== undefined && now < this.#clock)
    ) {
      this.stop();
      return;
    }
    this.#clock = now;
    return now;
  }
  /** Terminal cancellation is immediate, including across an awaited helper reply. */
  stop(): void {
    if (this.#stopped) return;
    this.#stopped = true;
    this.#token++;
    this.#pending = undefined;
    this.#abort.abort();
  }
  async observe(frame: WowCapturedFrame): Promise<WowSyncOutcome> {
    if (this.#stopped) return Object.freeze({ kind: "stopped" });
    if (this.#busy) return Object.freeze({ kind: "busy" });
    const now = this.#now();
    if (now === undefined) return Object.freeze({ kind: "stopped" });
    if (
      !(frame instanceof WowCapturedFrame) ||
      now < frame.observedAtMs ||
      now - frame.observedAtMs >= 2000 ||
      !this.ports.currentCapture(frame)
    )
      return Object.freeze({ kind: "stale" });
    try {
      const observation = WowRefreshObservation.observe(
        this.#observer,
        frame,
        now,
      );
      if (observation) this.#pending = observation;
      else if (this.#pending && !this.#pending.isCurrent(now))
        this.#pending = undefined;
      if (!observation) return Object.freeze({ kind: "observing" });
      return await this.retry();
    } catch {
      this.#pending = undefined;
      return Object.freeze({ kind: "failed" });
    }
  }
  /** Explicit bounded retry of the same immutable intent; never capture a new atlas
   * and attach it to a previous message, nor silently retry against newer storage. */
  async retry(): Promise<WowSyncOutcome> {
    if (this.#stopped) return Object.freeze({ kind: "stopped" });
    if (this.#busy) return Object.freeze({ kind: "busy" });
    const observation = this.#pending,
      now = this.#now();
    if (now === undefined) return Object.freeze({ kind: "stopped" });
    if (
      !observation ||
      !observation.isCurrent(now) ||
      !this.ports.currentCapture(observation.frame())
    ) {
      this.#pending = undefined;
      return Object.freeze({ kind: "stale" });
    }
    const token = ++this.#token;
    this.#busy = true;
    try {
      const outcome = await this.ports.refresh.execute(
        observation,
        this.#abort.signal,
        () => !this.#stopped && this.#token === token,
      );
      if (outcome.kind === "committed" || outcome.kind === "stale")
        this.#pending = undefined;
      return outcome;
    } catch {
      return Object.freeze({ kind: this.#stopped ? "stopped" : "failed" });
    } finally {
      this.#busy = false;
    }
  }
}
