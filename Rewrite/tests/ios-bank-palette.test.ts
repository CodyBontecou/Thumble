import { expect, test } from "bun:test";
import { inflateSync } from "node:zlib";
import { syntheticBankSource } from "../tooling/presentation-service-probe.ts";

function pixel(base64: string): number[] {
  const bytes = Buffer.from(base64, "base64");
  const chunks: Buffer[] = [];
  for (let at = 8; at < bytes.length; ) {
    const length = bytes.readUInt32BE(at);
    if (bytes.toString("ascii", at + 4, at + 8) === "IDAT")
      chunks.push(bytes.subarray(at + 8, at + 8 + length));
    at += length + 12;
  }
  const scan = inflateSync(Buffer.concat(chunks));
  expect(scan.length).toBe(32 * 129);
  return [...scan.subarray(1, 4)];
}

test("standard Android/SDK bank palette is unchanged and remains the default", () => {
  for (const refreshed of [false, true]) {
    const text = syntheticBankSource(refreshed);
    expect(text).toBe(syntheticBankSource(refreshed, "standard"));
    const variants = JSON.parse(text).profiles[0].appearanceBank.variants;
    for (const [index, variant] of variants.entries()) {
      const red = (refreshed ? 112 : 16) + index * 8;
      expect(pixel(variant.appearance.assetLibrary.assets[0].data)).toEqual([
        red,
        64,
        192 - red,
      ]);
    }
  }
});

test("iOS wide bank fixture has disjoint tolerance-five held pixels for every bank/theme/refresh", () => {
  const expected: number[][] = [];
  const rawPixels: number[][] = [];
  for (const refreshed of [false, true]) {
    const source = JSON.parse(syntheticBankSource(refreshed, "ios-wide"));
    const variants = source.profiles[0].appearanceBank.variants;
    expect(variants.length).toBe(8);
    for (const [index, variant] of variants.entries()) {
      const raw = pixel(variant.appearance.assetLibrary.assets[0].data);
      rawPixels.push(raw);
      const tint = index < 4 ? [0, 122, 255] : [10, 132, 255];
      expected.push(raw.map((v, i) => Math.round(v * 0.7 + tint[i]! * 0.3)));
    }
  }
  let minimum = 255;
  for (let a = 0; a < expected.length; a++)
    for (let b = a + 1; b < expected.length; b++) {
      const distance = Math.max(
        ...expected[a]!.map((v, i) => Math.abs(v - expected[b]![i]!)),
      );
      minimum = Math.min(minimum, distance);
      // Integer RGB tolerance boxes overlap iff every channel distance <= 10.
      expect(distance).toBeGreaterThan(10);
    }
  expect(minimum).toBe(11);
  rawPixels.forEach((raw, index) =>
    expect(raw).toEqual([index * 16, 64, 255 - index * 16]),
  );
});
