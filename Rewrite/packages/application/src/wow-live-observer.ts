import {
  validateWowLiveFrame,
  WowLiveAssembler,
  WOW_LIVE_TIMEOUT_MS,
  type WowLiveSnapshot,
} from "@thumble/domain/wow-live";

const MAX = 18446744073709551615n;
function decimal(value: string, zero: boolean): bigint {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]{0,19})$/.test(value))
    throw new Error("invalid_wow_observer_identity");
  const result = BigInt(value);
  if (result > MAX || (!zero && result === 0n))
    throw new Error("invalid_wow_observer_identity");
  return result;
}
function time(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0)
    throw new Error("invalid_wow_observer_time");
}
export interface WowObservationIdentity {
  readonly receipt: string;
  readonly source: number;
  readonly generation: string;
}
export interface PendingWowObservation extends WowObservationIdentity {
  readonly tick: number;
  readonly digest: number;
  readonly messageBytes: number;
  readonly pageCount: number;
  readonly observedAtMs: number;
  readonly character: Readonly<{
    flavor: WowLiveSnapshot["client"]["flavor"];
    id: string;
  }>;
  /** Intent only: true when this differs from the last successfully acknowledged character. */
  readonly select: boolean;
  readonly snapshot: WowLiveSnapshot;
}
export type WowObservationCommitOutcome =
  | Readonly<{ kind: "committed" }>
  | Readonly<{ kind: "conflict" }>
  | Readonly<{ kind: "failed" }>;

/** One bounded untrusted observation intent; no persistence, mapping, capture or input effects. */
export class WowLiveObserver {
  #decoder = new WowLiveAssembler();
  #source: number | undefined;
  #generation = 0n;
  #clock: number | undefined;
  #tick: number | undefined;
  #received: number | undefined;
  #message: string | undefined;
  #pending: PendingWowObservation | undefined;
  #acknowledged: string | undefined;
  #receipt: bigint;
  /** Counter seed only, not persisted authority or pending receipt restoration. */
  constructor(lastReceipt = "0") {
    this.#receipt = decimal(lastReceipt, true);
  }
  #current(nowMs: number): boolean {
    time(nowMs);
    if (this.#clock !== undefined && nowMs < this.#clock) {
      this.#pending = undefined;
      return false;
    }
    this.#clock = nowMs;
    const live = this.#decoder.isLive(nowMs);
    if (!live) this.#pending = undefined;
    return live;
  }
  /** Same advancing transport meaning as WowLiveAssembler, not accepted game state. */
  isLive(nowMs: number): boolean {
    return this.#current(nowMs);
  }
  /** A read-only transport correlation, never a storage ACK or game authenticity claim. */
  matchesAppliedMessage(
    identity: Readonly<{
      source: number;
      generation: string;
      digest: number;
      messageBytes: number;
      pageCount: number;
    }>,
    nowMs: number,
  ): boolean {
    return (
      this.#current(nowMs) &&
      identity.source === this.#source &&
      identity.generation === this.#generation.toString() &&
      this.#message ===
        `${identity.digest}/${identity.messageBytes}/${identity.pageCount}`
    );
  }
  pending(nowMs: number): PendingWowObservation | undefined {
    return this.#current(nowMs) ? this.#pending : undefined;
  }
  observe(
    source: number,
    generation: string,
    bytes: Uint8Array,
    nowMs: number,
  ): PendingWowObservation | undefined {
    time(nowMs);
    const nextGeneration = decimal(generation, false);
    if (!Number.isInteger(source) || source < 1 || source > 4294967295)
      throw new Error("invalid_wow_observer_identity");
    if (
      nextGeneration < this.#generation ||
      (nextGeneration === this.#generation && source !== this.#source)
    )
      throw new Error("wow_observer_context_mismatch");
    if (this.#clock !== undefined && nowMs < this.#clock) {
      this.#pending = undefined;
      // Preserve decoder high-water behavior: backward observations discard assembly.
      this.#decoder = new WowLiveAssembler();
      this.#tick = this.#received = this.#message = undefined;
      throw new Error("invalid_wow_observer_time");
    }
    this.#current(nowMs);
    if (nextGeneration > this.#generation) {
      this.#source = source;
      this.#generation = nextGeneration;
      this.#pending = undefined;
      this.#decoder = new WowLiveAssembler();
      this.#tick = this.#received = this.#message = undefined;
    }
    try {
      validateWowLiveFrame(bytes);
      const view = new DataView(
        bytes.buffer,
        bytes.byteOffset,
        bytes.byteLength,
      );
      const tick = view.getUint32(5, true),
        digest = view.getUint32(9, true),
        pageCount = view.getUint16(15, true),
        messageBytes = view.getUint16(19, true);
      if (
        this.#received !== undefined &&
        nowMs - this.#received >= WOW_LIVE_TIMEOUT_MS
      ) {
        this.#tick = this.#received = this.#message = undefined;
      }
      const delta =
        this.#tick === undefined ? undefined : (tick - this.#tick) >>> 0;
      const advancing =
        delta === undefined || (delta > 0 && delta < 2147483648);
      if (advancing) {
        const message = `${digest}/${messageBytes}/${pageCount}`;
        if (message !== this.#message) this.#pending = undefined;
        this.#message = message;
        this.#tick = tick;
        this.#received = nowMs;
      }
      const snapshot = this.#decoder.observe(source, bytes, nowMs);
      if (!snapshot) return this.#pending;
      this.#pending = undefined;
      if (this.#receipt === MAX)
        throw new Error("wow_observer_receipt_exhausted");
      const character = Object.freeze({
        flavor: snapshot.client.flavor,
        id: snapshot.character.id,
      });
      this.#pending = Object.freeze({
        receipt: (++this.#receipt).toString(),
        source,
        generation,
        tick,
        digest,
        messageBytes,
        pageCount,
        observedAtMs: nowMs,
        character,
        select:
          this.#acknowledged !==
          JSON.stringify([character.flavor, character.id]),
        snapshot,
      });
      return this.#pending;
    } catch (error) {
      this.#pending = undefined;
      throw error;
    }
  }
  /** Caller must report committed only after its revision-checked authority transaction succeeds. */
  acknowledge(
    identity: WowObservationIdentity,
    outcome: WowObservationCommitOutcome,
    nowMs: number,
  ): boolean {
    if (!this.#current(nowMs)) return false;
    const pending = this.#pending;
    if (
      !pending ||
      pending.receipt !== identity.receipt ||
      pending.source !== identity.source ||
      pending.generation !== identity.generation
    )
      return false;
    if (outcome.kind !== "committed") {
      if (outcome.kind !== "conflict" && outcome.kind !== "failed")
        throw new Error("invalid_wow_observer_commit_outcome");
      return false;
    }
    this.#acknowledged = JSON.stringify([
      pending.character.flavor,
      pending.character.id,
    ]);
    this.#pending = undefined;
    return true;
  }
}
