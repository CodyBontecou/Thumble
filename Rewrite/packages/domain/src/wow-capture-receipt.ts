import {
  WOW_CAPTURE_LIMITS,
  decodeWowCaptureRequest,
  type WowCaptureIdentity,
  type WowCaptureReply,
} from "@thumble/contracts/wow-capture";
import { validateWowLiveFrame } from "./wow-live.ts";
export type WowAtlasDecoder = (
  png: Uint8Array,
  limits: Readonly<{
    width: 256;
    height: 256;
    maxDecodedBytes: 262144;
    maxInflatedBytes: 262400;
  }>,
) => Readonly<{ width: number; height: number; rgba: Uint8Array }>;
function invalid(): never {
  throw new Error("invalid_wow_capture_atlas");
}
function crc(bytes: Uint8Array, start: number, end: number): number {
  let value = 0xffffffff;
  for (let i = start; i < end; i++) {
    value ^= bytes[i]!;
    for (let b = 0; b < 8; b++)
      value = (value >>> 1) ^ (value & 1 ? 0xedb88320 : 0);
  }
  return (value ^ 0xffffffff) >>> 0;
}
/** Container validation only. A required bounded image decoder must also verify
 * compressed pixels before a receipt is admitted. No decompressor lives here. */
export function validateWowAtlasContainer(bytes: Uint8Array): void {
  if (
    !(bytes instanceof Uint8Array) ||
    bytes.byteLength < 57 ||
    bytes.byteLength > WOW_CAPTURE_LIMITS.atlasBytes
  )
    invalid();
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (signature.some((n, i) => bytes[i] !== n)) invalid();
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let at = 8,
    chunks = 0,
    idat = false,
    endedData = false,
    header = false;
  while (at < bytes.length) {
    if (++chunks > WOW_CAPTURE_LIMITS.pngChunks || at + 12 > bytes.length)
      invalid();
    const length = view.getUint32(at),
      end = at + 12 + length;
    if (end > bytes.length) invalid();
    const type = String.fromCharCode(...bytes.subarray(at + 4, at + 8));
    if (
      !/^[A-Za-z]{4}$/.test(type) ||
      crc(bytes, at + 4, at + 8 + length) !== view.getUint32(at + 8 + length)
    )
      invalid();
    if (!header) {
      if (
        type !== "IHDR" ||
        length !== 13 ||
        view.getUint32(at + 8) !== 256 ||
        view.getUint32(at + 12) !== 256 ||
        bytes[at + 16] !== 8 ||
        ![2, 6].includes(bytes[at + 17]!) ||
        bytes[at + 18] !== 0 ||
        bytes[at + 19] !== 0 ||
        bytes[at + 20] !== 0
      )
        invalid();
      header = true;
    } else if (type === "IHDR") invalid();
    else if (type === "IDAT") {
      if (endedData) invalid();
      idat = true;
    } else if (type === "IEND") {
      if (length !== 0 || !idat || end !== bytes.length) invalid();
      return;
    } else {
      if (idat) endedData = true;
      if (type[0] === type[0]!.toUpperCase() && type !== "PLTE") invalid();
    }
    at = end;
  }
  invalid();
}
/** Same-child response bytes, immutable by copy. No transport/game freshness or authority ACK. */
export class WowCapturedFrame implements WowCaptureIdentity {
  readonly source: number;
  readonly generation: string;
  readonly receipt: string;
  readonly observedAtMs: number;
  #frame: Uint8Array;
  #atlas: Uint8Array;
  constructor(
    reply: Extract<WowCaptureReply, { kind: "frame" }>,
    observedAtMs: number,
    decode: WowAtlasDecoder,
  ) {
    if (!Number.isSafeInteger(observedAtMs) || observedAtMs < 0)
      throw new Error("invalid_wow_capture_time");
    decodeWowCaptureRequest({
      version: 1,
      command: "wow-capture",
      source: reply.source,
      generation: reply.generation,
      receipt: reply.receipt,
    });
    if (
      !(reply.frame instanceof Uint8Array) ||
      reply.frame.byteLength !== 512 ||
      !(reply.atlasPNG instanceof Uint8Array) ||
      reply.atlasPNG.byteLength > WOW_CAPTURE_LIMITS.atlasBytes
    )
      invalid();
    const frame = new Uint8Array(reply.frame),
      atlas = new Uint8Array(reply.atlasPNG);
    validateWowLiveFrame(frame);
    validateWowAtlasContainer(atlas);
    let verified: ReturnType<WowAtlasDecoder>;
    try {
      verified = decode(
        new Uint8Array(atlas),
        Object.freeze({
          width: 256,
          height: 256,
          maxDecodedBytes: 262144,
          maxInflatedBytes: 262400,
        }),
      );
    } catch {
      invalid();
    }
    if (
      verified.width !== 256 ||
      verified.height !== 256 ||
      !(verified.rgba instanceof Uint8Array) ||
      verified.rgba.byteLength !== WOW_CAPTURE_LIMITS.rgbaBytes
    )
      invalid();
    this.source = reply.source;
    this.generation = reply.generation;
    this.receipt = reply.receipt;
    this.observedAtMs = observedAtMs;
    this.#frame = frame;
    this.#atlas = atlas;
    Object.freeze(this);
  }
  frame(): Uint8Array {
    return new Uint8Array(this.#frame);
  }
  atlasPNG(): Uint8Array {
    return new Uint8Array(this.#atlas);
  }
}
