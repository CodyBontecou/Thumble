import { validateWowLiveFrame } from "./wow-live.ts";

export interface WowOpticalImage {
  /** Normalized top-left row-major RGBA8, matching the retained native buffer. */
  readonly format: "rgba8";
  readonly width: number;
  readonly height: number;
  readonly stride: number;
  readonly pixels: Uint8Array;
}
export interface WowOpticalPanel {
  readonly frame: Uint8Array;
  /** Top-left row-major 256-square RGBA8; no PNG encoder or source-window bytes. */
  readonly atlas: Readonly<{
    width: 256;
    height: 256;
    stride: 1024;
    pixels: Uint8Array;
  }>;
}
const invalid = (): never => {
  throw new Error("invalid_wow_optical_image");
};
const MAX_BYTES = 64 * 1024 * 1024;
const MAX_READS = 4_194_304;

/** Pure bounded pixel observation. No window identity, permission or input authority.
 * The native wrapper must normalize channel order/orientation before calling.
 */
export function decodeWowOpticalPanel(
  image: WowOpticalImage,
): WowOpticalPanel | undefined {
  const { width, height, stride, pixels } = image;
  if (
    image.format !== "rgba8" ||
    !Number.isInteger(width) ||
    !Number.isInteger(height) ||
    width <= 0 ||
    height <= 0 ||
    width > 8192 ||
    height > 8192 ||
    width * height > 16_777_216 ||
    !Number.isInteger(stride) ||
    stride < width * 4 ||
    stride > width * 4 + 4096 ||
    stride * height > MAX_BYTES ||
    !(pixels instanceof Uint8Array) ||
    pixels.byteLength !== stride * height
  )
    return invalid();
  let reads = 0;
  const offset = (x: number, y: number) => {
    if (++reads > MAX_READS) throw new Error("wow_optical_scan_limit");
    return x >= 0 && x < width && y >= 0 && y < height
      ? y * stride + x * 4
      : -1;
  };
  function cyan(x: number, y: number): boolean {
    const at = offset(x, y);
    return (
      at >= 0 &&
      pixels[at]! < 35 &&
      pixels[at + 1]! > 210 &&
      pixels[at + 2]! > 210
    );
  }
  function magenta(x: number, y: number): boolean {
    const at = offset(x, y);
    return (
      at >= 0 &&
      pixels[at]! > 210 &&
      pixels[at + 1]! < 35 &&
      pixels[at + 2]! > 210
    );
  }
  function gray(x: number, y: number): number | undefined {
    const at = offset(x, y);
    if (at < 0) return;
    return Math.abs(pixels[at]! - pixels[at + 1]!) < 8 &&
      Math.abs(pixels[at + 1]! - pixels[at + 2]!) < 8
      ? pixels[at]!
      : undefined;
  }
  for (let y = 0; y < Math.min(height, 512); y++) {
    let x = 0;
    while (x < Math.min(width, 512)) {
      if (!cyan(x, y)) {
        x++;
        continue;
      }
      const originX = x;
      while (x < width && cyan(x, y)) x++;
      const markerWidth = x - originX;
      if (
        markerWidth < 4 ||
        markerWidth > 48 ||
        (y > 0 && cyan(originX + Math.floor(markerWidth / 2), y - 1))
      )
        continue;
      let markerEnd = x;
      for (let marker = 1; marker < 4; marker++) {
        const start = markerEnd;
        while (
          markerEnd < width &&
          (marker % 2 === 0 ? cyan(markerEnd, y) : magenta(markerEnd, y))
        )
          markerEnd++;
        if (Math.abs(markerEnd - start - markerWidth) > 1) break;
      }
      const approximate = (markerEnd - originX) / 24;
      const searchStart = originX + Math.floor(230 * approximate),
        searchEnd = Math.min(width, originX + Math.ceil(270 * approximate));
      if (searchStart >= searchEnd) continue;
      let rightEnd: number | undefined;
      for (let scan = searchStart; scan < searchEnd; scan++) {
        if (!cyan(scan, y)) continue;
        let edge = scan,
          valid = true;
        for (let marker = 0; marker < 4; marker++) {
          const start = edge;
          while (
            edge < width &&
            (marker % 2 === 0 ? cyan(edge, y) : magenta(edge, y))
          )
            edge++;
          if (Math.abs(edge - start - 4 * approximate) > 2) {
            valid = false;
            break;
          }
        }
        if (valid) {
          rightEnd = edge;
          break;
        }
      }
      if (rightEnd === undefined) continue;
      const unit = (rightEnd - originX) / 256;
      const px = (dx: number) => originX + Math.floor(dx * unit),
        py = (dy: number) => y + Math.floor(dy * unit);
      const endX = px(256),
        endY = py(320);
      if (endX > width || endY > height) continue;
      let valid = true;
      for (let marker = 0; marker < 4; marker++) {
        const left = marker * 6 + 3,
          right = 240 + marker * 4 + 2,
          row = py(3);
        if (
          !(marker % 2 === 0
            ? cyan(px(left), row) && cyan(px(right), row)
            : magenta(px(left), row) && magenta(px(right), row))
        ) {
          valid = false;
          break;
        }
      }
      if (!valid) continue;
      const palette: number[] = [];
      for (let index = 0; index < 16; index++) {
        const value = gray(px(24 + index * 6 + 3), py(3));
        if (value === undefined) break;
        palette.push(value);
      }
      if (
        palette.length !== 16 ||
        palette[0]! >= 25 ||
        palette[15]! <= 230 ||
        palette.some(
          (value, index) => index > 0 && value - palette[index - 1]! < 5,
        )
      )
        continue;
      const frame = new Uint8Array(512);
      for (let index = 0; index < 1024; index++) {
        const value = gray(
          px((index % 64) * 3 + 1.5),
          py(8 + Math.floor(index / 64) * 3 + 1.5),
        );
        if (value === undefined) {
          valid = false;
          break;
        }
        let nearest = 0;
        for (let entry = 1; entry < 16; entry++)
          if (
            Math.abs(palette[entry]! - value) <
            Math.abs(palette[nearest]! - value)
          )
            nearest = entry;
        if (Math.abs(palette[nearest]! - value) > 7) {
          valid = false;
          break;
        }
        const byte = Math.floor(index / 2);
        frame[byte] = frame[byte]! | (index % 2 === 0 ? nearest << 4 : nearest);
      }
      if (!valid) continue;
      try {
        validateWowLiveFrame(frame);
      } catch {
        continue;
      }
      const atlasX = px(0),
        atlasY = py(64),
        cropWidth = endX - atlasX,
        cropHeight = endY - atlasY;
      if (cropWidth <= 0 || cropHeight <= 0) continue;
      const atlas = new Uint8Array(256 * 256 * 4);
      // Center nearest-neighbor normalization; source rows stay top-left oriented.
      for (let row = 0; row < 256; row++)
        for (let column = 0; column < 256; column++) {
          const source =
            (atlasY + Math.floor(((row + 0.5) * cropHeight) / 256)) * stride +
            (atlasX + Math.floor(((column + 0.5) * cropWidth) / 256)) * 4;
          const target = (row * 256 + column) * 4;
          for (let channel = 0; channel < 4; channel++)
            atlas[target + channel] = pixels[source + channel]!;
        }
      return Object.freeze({
        frame,
        atlas: Object.freeze({
          width: 256,
          height: 256,
          stride: 1024,
          pixels: atlas,
        }),
      });
    }
  }
  return;
}
