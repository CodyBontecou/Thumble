import { expect, test } from "bun:test";
import { deflateSync } from "node:zlib";
import { atlasPNGFixture as png, chunk } from "./fixtures/wow-atlas-fixture.ts";
import { decodeWowAtlas } from "../apps/service/src/wow-atlas-decoder.ts";
const limits = {
  width: 256,
  height: 256,
  maxDecodedBytes: 262144,
  maxInflatedBytes: 262400,
} as const;
test("bounded production atlas decoder reconstructs every pixel for all filters and RGB/RGBA", () => {
  for (const channels of [3, 4])
    for (let filter = 0; filter <= 4; filter++) {
      const stride = 256 * channels,
        raw = Buffer.alloc(256 * (stride + 1)),
        colors = [10, 20, 30, 40];
      for (let y = 0; y < 256; y++) {
        raw[y * (stride + 1)] = filter;
        for (let x = 0; x < stride; x++) {
          const value = colors[x % channels]!,
            left = x >= channels ? value : 0,
            up = y ? value : 0;
          const predictor =
            filter === 0
              ? 0
              : filter === 1
                ? left
                : filter === 2
                  ? up
                  : filter === 3
                    ? Math.floor((left + up) / 2)
                    : left || up;
          raw[y * (stride + 1) + 1 + x] = (value - predictor) & 255;
        }
      }
      const result = decodeWowAtlas(
        png(channels, filter, deflateSync(raw)),
        limits,
      );
      expect(result.width).toBe(256);
      expect(result.rgba.length).toBe(262144);
      expect(
        result.rgba.every(
          (value, index) =>
            value ===
            (index % 4 === 3 && channels === 3 ? 255 : colors[index % 4]),
        ),
      ).toBe(true);
    }
});
test("atlas decoder rejects decompression bombs, truncation, invalid filters and trailing zlib input", () => {
  for (const bytes of [
    png(4, 5),
    png(4, 0, deflateSync(Buffer.alloc(262401))),
    png(4, 0, deflateSync(Buffer.alloc(1))),
    png(4, 0, Buffer.from([1, 2, 3])),
    png(
      4,
      0,
      Buffer.concat([deflateSync(Buffer.alloc(262400)), Buffer.from([0])]),
    ),
    png().subarray(0, -1),
  ])
    expect(() => decodeWowAtlas(bytes, limits)).toThrow();
});

test("RGB transparency is reconstructed and malformed/animated PNG metadata is rejected", () => {
  const insert = (bytes: Buffer, type: string, data: Uint8Array) =>
    Buffer.concat([
      bytes.subarray(0, 33),
      chunk(type, data),
      bytes.subarray(33),
    ]);
  const decoded = decodeWowAtlas(
    insert(png(3), "tRNS", Buffer.from([0, 1, 0, 2, 0, 3])),
    limits,
  );
  expect(decoded.rgba[3]).toBe(0);
  expect(decoded.rgba[7]).toBe(255);
  for (const bytes of [
    insert(png(), "tRNS", Buffer.alloc(6)),
    insert(png(3), "tRNS", Buffer.alloc(5)),
    insert(png(), "acTL", Buffer.alloc(8)),
    insert(png(), "PLTE", Buffer.alloc(2)),
    insert(png(), "texT", Buffer.alloc(0)),
  ])
    expect(() => decodeWowAtlas(bytes, limits)).toThrow();
});
