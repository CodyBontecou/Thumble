import { inflateSync } from "node:zlib";
import {
  validateWowAtlasContainer,
  type WowAtlasDecoder,
} from "@thumble/domain/wow-capture-receipt";
/** Bounded noninterlaced 8-bit RGB/RGBA PNG decoder. Runs only in the capture owner. */
export const decodeWowAtlas: WowAtlasDecoder = (png, limits) => {
  const invalid = (): never => {
    throw new Error("wow_capture_atlas_invalid");
  };
  validateWowAtlasContainer(png);
  if (
    limits.width !== 256 ||
    limits.height !== 256 ||
    limits.maxDecodedBytes !== 262144 ||
    limits.maxInflatedBytes !== 262400
  )
    invalid();
  const channels = png[25] === 6 ? 4 : 3;
  const stride = 256 * channels,
    expected = 256 * (stride + 1);
  const chunks: Buffer[] = [];
  const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
  let transparency: readonly number[] | undefined,
    palette = false,
    data = false;
  for (let at = 8; at < png.length; ) {
    const length = view.getUint32(at),
      type = String.fromCharCode(...png.subarray(at + 4, at + 8));
    if (
      png[at + 6]! < 65 ||
      png[at + 6]! > 90 ||
      ["acTL", "fcTL", "fdAT"].includes(type)
    )
      invalid();
    if (type === "IDAT") {
      data = true;
      chunks.push(Buffer.from(png.subarray(at + 8, at + 8 + length)));
    } else if (type === "PLTE") {
      if (data || palette || !length || length > 768 || length % 3) invalid();
      palette = true;
    } else if (type === "tRNS") {
      if (
        data ||
        transparency ||
        channels !== 3 ||
        length !== 6 ||
        [0, 2, 4].some((offset) => png[at + 8 + offset] !== 0)
      )
        invalid();
      transparency = [png[at + 9]!, png[at + 11]!, png[at + 13]!];
    }
    at += length + 12;
  }
  const compressed = Buffer.concat(chunks);
  const inflated: unknown = inflateSync(compressed, {
    maxOutputLength: expected,
    info: true,
  });
  if (
    typeof inflated !== "object" ||
    inflated === null ||
    !("buffer" in inflated) ||
    !Buffer.isBuffer(inflated.buffer) ||
    !("engine" in inflated) ||
    typeof inflated.engine !== "object" ||
    inflated.engine === null ||
    !("bytesWritten" in inflated.engine) ||
    inflated.buffer.length !== expected ||
    inflated.engine.bytesWritten !== compressed.length
  )
    return invalid();
  const scan = inflated.buffer,
    pixels = new Uint8Array(stride * 256);
  const paeth = (a: number, b: number, c: number) => {
    const p = a + b - c,
      x = Math.abs(p - a),
      y = Math.abs(p - b),
      z = Math.abs(p - c);
    return x <= y && x <= z ? a : y <= z ? b : c;
  };
  for (let y = 0; y < 256; y++) {
    const filter = scan[y * (stride + 1)]!;
    if (filter > 4) invalid();
    for (let x = 0; x < stride; x++) {
      const at = y * stride + x,
        a = x >= channels ? pixels[at - channels]! : 0,
        b = y ? pixels[at - stride]! : 0,
        c = y && x >= channels ? pixels[at - stride - channels]! : 0;
      const predictor =
        filter === 0
          ? 0
          : filter === 1
            ? a
            : filter === 2
              ? b
              : filter === 3
                ? Math.floor((a + b) / 2)
                : paeth(a, b, c);
      pixels[at] = scan[y * (stride + 1) + x + 1]! + predictor;
    }
  }
  const rgba = new Uint8Array(262144);
  for (let i = 0; i < 65536; i++) {
    rgba[i * 4] = pixels[i * channels]!;
    rgba[i * 4 + 1] = pixels[i * channels + 1]!;
    rgba[i * 4 + 2] = pixels[i * channels + 2]!;
    rgba[i * 4 + 3] =
      channels === 4
        ? pixels[i * 4 + 3]!
        : transparency?.every(
              (value, channel) => value === pixels[i * 3 + channel],
            )
          ? 0
          : 255;
  }
  return { width: 256, height: 256, rgba };
};
