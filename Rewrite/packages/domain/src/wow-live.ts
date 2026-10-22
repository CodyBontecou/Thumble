import {
  decodeWowLiveSnapshot,
  WOW_LIVE_MAX_BYTES,
  type WowLiveSnapshot,
} from "./wow-live-snapshot.ts";
export {
  decodeWowLiveSnapshot,
  WOW_LIVE_MAX_BYTES,
  type WowLiveSnapshot,
} from "./wow-live-snapshot.ts";
export const WOW_LIVE_FRAME_BYTES = 512;
export const WOW_LIVE_TIMEOUT_MS = 2000;
const HEADER = 25,
  PAYLOAD = WOW_LIVE_FRAME_BYTES - HEADER;
const invalid = (): never => {
  throw new Error("invalid_wow_live_frame");
};

/** Adler-32, matching the retained Lua optical producer, not authentication. */
export function wowLiveChecksum(bytes: Uint8Array): number {
  let a = 1,
    b = 0;
  for (const value of bytes) {
    a = (a + value) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
}
interface Frame {
  tick: number;
  digest: number;
  page: number;
  count: number;
  total: number;
  payload: Uint8Array;
}
function frame(bytes: Uint8Array): Frame {
  if (
    !(bytes instanceof Uint8Array) ||
    bytes.length !== WOW_LIVE_FRAME_BYTES ||
    [84, 72, 87, 76, 1].some((value, index) => bytes[index] !== value)
  )
    return invalid();
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const page = view.getUint16(13, true),
    count = view.getUint16(15, true),
    length = view.getUint16(17, true),
    total = view.getUint16(19, true);
  if (
    total === 0 ||
    total > WOW_LIVE_MAX_BYTES ||
    count !== Math.ceil(total / PAYLOAD) ||
    page >= count ||
    length !== Math.min(PAYLOAD, total - page * PAYLOAD) ||
    bytes.subarray(HEADER + length).some((value) => value !== 0)
  )
    return invalid();
  const sealed = new Uint8Array(21 + length);
  sealed.set(bytes.subarray(0, 21));
  sealed.set(bytes.subarray(HEADER, HEADER + length), 21);
  if (wowLiveChecksum(sealed) !== view.getUint32(21, true)) return invalid();
  return {
    tick: view.getUint32(5, true),
    digest: view.getUint32(9, true),
    page,
    count,
    total,
    payload: bytes.slice(HEADER, HEADER + length),
  };
}
/** Header/page checksum admission only; does not establish message or source trust. */
export function validateWowLiveFrame(bytes: Uint8Array): void {
  frame(bytes);
}

function time(value: number): void {
  if (!Number.isSafeInteger(value) || value < 0) invalid();
}

/** Bounded optical observation state. No capture, persistence, or input side effects.
 * Source is the independently identified capture window, never an in-frame identity.
 * A new source or expired transport requires two advancing ticks before delivery.
 */
export class WowLiveAssembler {
  #source: number | undefined;
  #clock: number | undefined;
  #tick: number | undefined;
  #received: number | undefined;
  #advanced: number | undefined;
  #digest: number | undefined;
  #total = 0;
  #count = 0;
  #pages = new Map<number, Uint8Array>();
  #delivered: number | undefined;
  #reset(): void {
    this.#tick =
      this.#received =
      this.#advanced =
      this.#digest =
      this.#delivered =
        undefined;
    this.#total = this.#count = 0;
    this.#pages.clear();
  }
  /** Advancing transport freshness, not capture permission or profile acceptance. */
  isLive(nowMs: number): boolean {
    time(nowMs);
    if (this.#clock !== undefined && nowMs < this.#clock) return false;
    this.#clock = nowMs;
    return (
      this.#advanced !== undefined &&
      nowMs - this.#advanced < WOW_LIVE_TIMEOUT_MS
    );
  }
  observe(
    source: number,
    bytes: Uint8Array,
    nowMs: number,
  ): WowLiveSnapshot | undefined {
    time(nowMs);
    if (!Number.isInteger(source) || source <= 0 || source > 4294967295)
      return invalid();
    const next = frame(bytes);
    if (this.#clock !== undefined && nowMs < this.#clock) {
      this.#reset();
      return invalid();
    }
    this.#clock = nowMs;
    if (
      source !== this.#source ||
      (this.#received !== undefined &&
        nowMs - this.#received >= WOW_LIVE_TIMEOUT_MS)
    ) {
      this.#reset();
      this.#source = source;
    }
    if (this.#tick !== undefined) {
      const delta = (next.tick - this.#tick) >>> 0;
      if (delta === 0 || delta >= 2147483648) return;
      this.#advanced = nowMs;
    }
    this.#tick = next.tick;
    this.#received = nowMs;
    if (
      this.#digest !== next.digest ||
      this.#total !== next.total ||
      this.#count !== next.count
    ) {
      this.#pages.clear();
      this.#digest = next.digest;
      this.#total = next.total;
      this.#count = next.count;
    }
    if (this.#delivered === next.digest) return;
    const prior = this.#pages.get(next.page);
    if (
      prior &&
      (prior.length !== next.payload.length ||
        prior.some((value, index) => value !== next.payload[index]))
    ) {
      this.#pages.clear();
      return invalid();
    }
    this.#pages.set(next.page, next.payload);
    if (this.#pages.size !== next.count || !this.isLive(nowMs)) return;
    const message = new Uint8Array(next.total);
    for (const [page, payload] of this.#pages)
      message.set(payload, page * PAYLOAD);
    this.#pages.clear();
    if (wowLiveChecksum(message) !== next.digest) return invalid();
    const snapshot = decodeWowLiveSnapshot(message);
    this.#delivered = next.digest;
    return snapshot;
  }
}
