import { expect, test } from "bun:test";
import {
  decodeWowOpticalPanel,
  type WowOpticalImage,
} from "../packages/domain/src/wow-optical-panel.ts";
import { wowLiveChecksum } from "../packages/domain/src/wow-live.ts";

// Synthetic pixel rectangles match retained WoWOpticalPanelTests.makeImage.
// Payload is fabricated locally; no game capture, account export or artwork.
function frame(): Uint8Array {
  const message = new TextEncoder().encode('{"synthetic":"optical test only"}'),
    bytes = new Uint8Array(512),
    view = new DataView(bytes.buffer);
  bytes.set([84, 72, 87, 76, 1]);
  view.setUint32(5, 123, true);
  view.setUint32(9, wowLiveChecksum(message), true);
  view.setUint16(15, 1, true);
  view.setUint16(17, message.length, true);
  view.setUint16(19, message.length, true);
  bytes.set(message, 25);
  const sealed = new Uint8Array(21 + message.length);
  sealed.set(bytes.subarray(0, 21));
  sealed.set(message, 21);
  view.setUint32(21, wowLiveChecksum(sealed), true);
  return bytes;
}
function image(
  bytes = frame(),
  scale = 1,
  padding = 0,
  x0 = 17,
  y0 = 23,
): WowOpticalImage {
  const width = 1024,
    height = 1100,
    stride = width * 4 + padding,
    pixels = new Uint8Array(stride * height);
  function rect(x: number, y: number, w: number, h: number, color: number[]) {
    for (
      let py = y0 + Math.floor(y * scale);
      py < y0 + Math.floor((y + h) * scale);
      py++
    )
      for (
        let px = x0 + Math.floor(x * scale);
        px < x0 + Math.floor((x + w) * scale);
        px++
      ) {
        if (px < 0 || py < 0 || px >= width || py >= height) continue;
        const offset = py * stride + px * 4;
        pixels.set([...color, 255], offset);
      }
  }
  for (let i = 0; i < 4; i++)
    rect(i * 6, 0, 6, 6, i % 2 === 0 ? [0, 255, 255] : [255, 0, 255]);
  for (let i = 0; i < 4; i++)
    rect(240 + i * 4, 0, 4, 6, i % 2 === 0 ? [0, 255, 255] : [255, 0, 255]);
  for (let i = 0; i < 16; i++)
    rect(24 + i * 6, 0, 6, 6, [i * 17, i * 17, i * 17]);
  for (let i = 0; i < 1024; i++) {
    const n =
      (i % 2 === 0
        ? bytes[Math.floor(i / 2)]! >> 4
        : bytes[Math.floor(i / 2)]! & 15) * 17;
    rect((i % 64) * 3, 8 + Math.floor(i / 64) * 3, 3, 3, [n, n, n]);
  }
  for (let i = 0; i < 64; i++)
    rect((i % 8) * 32, 64 + Math.floor(i / 8) * 32, 32, 32, [i, 120, 240]);
  return { format: "rgba8", width, height, stride, pixels };
}

test("synthetic frame and RGBA atlas decode at all ten retained scales without flipping", () => {
  const bytes = frame();
  for (const scale of [0.75, 0.853, 1, 1.1, 1.28, 1.5, 1.6, 2, 2.557, 3]) {
    const result = decodeWowOpticalPanel(image(bytes, scale));
    expect(result).toBeDefined();
    expect(result!.frame).toEqual(bytes);
    expect([
      result!.atlas.width,
      result!.atlas.height,
      result!.atlas.stride,
    ]).toEqual([256, 256, 1024]);
    expect(result!.atlas.pixels.length).toBe(262144);
    expect(Array.from(result!.atlas.pixels.subarray(0, 4))).toEqual([
      0, 120, 240, 255,
    ]);
    const topRight = 255 * 4,
      bottomLeft = 255 * 256 * 4;
    expect(
      Array.from(result!.atlas.pixels.subarray(topRight, topRight + 4)),
    ).toEqual([7, 120, 240, 255]);
    expect(
      Array.from(result!.atlas.pixels.subarray(bottomLeft, bottomLeft + 4)),
    ).toEqual([56, 120, 240, 255]);
    const corner = (255 * 256 + 255) * 4;
    expect(
      Array.from(result!.atlas.pixels.subarray(corner, corner + 4)),
    ).toEqual([63, 120, 240, 255]);
    expect(Object.isFrozen(result)).toBe(true);
    expect(Object.isFrozen(result!.atlas)).toBe(true);
  }
});
test("padded rows and offset typed-array views preserve exact data and copy outputs", () => {
  const original = image(frame(), 1.28, 64),
    storage = new Uint8Array(original.pixels.length + 20);
  storage.set(original.pixels, 10);
  const view = {
      ...original,
      pixels: storage.subarray(10, 10 + original.pixels.length),
    },
    result = decodeWowOpticalPanel(view)!;
  expect(result.frame).toEqual(frame());
  expect(result.atlas.pixels[0]).toBe(0);
  view.pixels.fill(7);
  expect(result.frame).toEqual(frame());
  expect(Array.from(result.atlas.pixels.subarray(0, 4))).toEqual([
    0, 120, 240, 255,
  ]);
});
test("corrupt telemetry is rejected by core checksum before atlas publication", () => {
  const corrupt = frame();
  corrupt[100] = corrupt[100]! ^ 1;
  expect(decodeWowOpticalPanel(image(corrupt))).toBeUndefined();
  const blank = image();
  blank.pixels.fill(0);
  expect(decodeWowOpticalPanel(blank)).toBeUndefined();
});
test("missing fiducials, non-gray or ambiguous palette and chromatic payload samples fail closed", () => {
  // Replace only the tested synthetic point; no externally captured pixels.
  for (const [x, y, r, g, b] of [
    [20, 26, 0, 0, 0],
    [44, 26, 100, 100, 100],
    [50, 26, 0, 0, 0],
    [18, 32, 100, 200, 0],
  ]) {
    const source = image();
    const at = y! * source.stride + x! * 4;
    source.pixels.set([r!, g!, b!, 255], at);
    expect(decodeWowOpticalPanel(source)).toBeUndefined();
  }
});
test("discovery stays in the bounded top-left region and clipped panels cannot escape image limits", () => {
  expect(decodeWowOpticalPanel(image(frame(), 1, 0, 600, 23))).toBeUndefined();
  expect(decodeWowOpticalPanel(image(frame(), 1, 0, 17, 600))).toBeUndefined();
  expect(decodeWowOpticalPanel(image(frame(), 3, 0, 300, 300))).toBeUndefined();
});
test("image format, stride and allocation bounds reject invalid layouts before scanning", () => {
  const source = image();
  for (const patch of [
    { format: "bgra8" },
    { width: 0 },
    { width: 8193 },
    { height: 8193 },
    { width: 1.5 },
    { height: NaN },
    { width: 8192, height: 8192 },
    { stride: 4095 },
    { stride: 8193 },
    { stride: Infinity },
    { pixels: new Uint8Array(0) },
  ])
    expect(() =>
      decodeWowOpticalPanel({ ...source, ...patch } as WowOpticalImage),
    ).toThrow();
  const tiny = {
    format: "rgba8" as const,
    width: 1,
    height: 1,
    stride: 4,
    pixels: new Uint8Array(4),
  };
  expect(decodeWowOpticalPanel(tiny)).toBeUndefined();
});

test("calibrated non-linear grayscale and bounded sample noise preserve nibbles", () => {
  const source = image();
  const levels = [
    0, 8, 16, 24, 35, 48, 62, 79, 99, 121, 145, 169, 191, 213, 234, 255,
  ];
  for (let y = 23; y < 23 + 56; y++)
    for (let x = 17; x < 17 + 256; x++) {
      const at = y * source.stride + x * 4,
        red = source.pixels[at]!;
      if (
        red === source.pixels[at + 1] &&
        red === source.pixels[at + 2] &&
        red % 17 === 0
      ) {
        const value = levels[red / 17]!;
        source.pixels[at] = value;
        source.pixels[at + 1] = value;
        source.pixels[at + 2] = value;
      }
    }
  expect(decodeWowOpticalPanel(source)?.frame).toEqual(frame());
  // Noise stays below the nearest-palette tolerance at a payload cell center.
  const at = 32 * source.stride + 18 * 4;
  for (let channel = 0; channel < 3; channel++)
    source.pixels[at + channel] = source.pixels[at + channel]! + 2;
  expect(decodeWowOpticalPanel(source)?.frame).toEqual(frame());
});

test("adversarial repeated fiducials exhaust a fixed scan work budget instead of rescanning unbounded rows", () => {
  const width = 8192,
    height = 64,
    stride = width * 4,
    pixels = new Uint8Array(stride * height);
  for (let y = 0; y < height; y += 2) {
    for (let marker = 0; marker < 4; marker++)
      for (let x = 17 + marker * 6; x < 17 + (marker + 1) * 6; x++)
        pixels.set(
          marker % 2 === 0 ? [0, 255, 255, 255] : [255, 0, 255, 255],
          y * stride + x * 4,
        );
    // Each false right-fiducial candidate leads into a long cyan run. The work
    // limit bounds this independently from otherwise valid image allocation.
    for (let x = 200; x < width; x++)
      pixels.set([0, 255, 255, 255], y * stride + x * 4);
  }
  expect(() =>
    decodeWowOpticalPanel({ format: "rgba8", width, height, stride, pixels }),
  ).toThrow("wow_optical_scan_limit");
});
