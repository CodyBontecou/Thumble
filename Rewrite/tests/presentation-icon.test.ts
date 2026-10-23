import { expect, test } from "bun:test";
import { deflateSync } from "node:zlib";
import { chunk, atlasPNGFixture } from "./fixtures/wow-atlas-fixture.ts";
import { verifyPresentationIcon } from "../apps/service/src/presentation-icon.ts";
function png(channels = 4, filter = 0, compressed?: Uint8Array) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(32);
  header.writeUInt32BE(32, 4);
  header[8] = 8;
  header[9] = channels === 4 ? 6 : 2;
  const rows = Buffer.alloc(32 * (32 * channels + 1));
  for (let y = 0; y < 32; y++) rows[y * (32 * channels + 1)] = filter;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", compressed ?? deflateSync(rows)),
    chunk("IEND", new Uint8Array()),
  ]);
}
test("phone icons require bounded actual32px RGB/RGBA scan decoding for every PNG filter", () => {
  for (const channels of [3, 4])
    for (let filter = 0; filter < 5; filter++)
      expect(() => verifyPresentationIcon(png(channels, filter))).not.toThrow();
});
test("phone icon parser rejects atlas, oversized/invalid decompression, truncation, bad CRC and trailing compressed input", () => {
  const damaged = png();
  damaged[damaged.length - 1]! ^= 1;
  for (const bytes of [
    atlasPNGFixture(),
    png(4, 5),
    png(4, 0, deflateSync(Buffer.alloc(4129))),
    png(4, 0, deflateSync(Buffer.alloc(1))),
    png(4, 0, Buffer.from([1, 2, 3])),
    png(
      4,
      0,
      Buffer.concat([deflateSync(Buffer.alloc(4128)), Buffer.from([0])]),
    ),
    png().subarray(0, -1),
    damaged,
    new Uint8Array(8193),
  ])
    expect(() => verifyPresentationIcon(bytes)).toThrow();
});
test("phone icons reject excessive chunk work, animated PNG and unknown critical features", () => {
  const valid = png(),
    header = valid.subarray(0, 33),
    rest = valid.subarray(33);
  for (const middle of [
    Buffer.concat(
      Array.from({ length: 64 }, () => chunk("tEXt", new Uint8Array())),
    ),
    chunk("acTL", new Uint8Array(8)),
    chunk("iCCP", new Uint8Array(8)),
    chunk("zTXt", new Uint8Array(8)),
    chunk("iTXt", new Uint8Array(8)),
    chunk("ABCD", new Uint8Array()),
  ])
    expect(() =>
      verifyPresentationIcon(Buffer.concat([header, middle, rest])),
    ).toThrow();
});
