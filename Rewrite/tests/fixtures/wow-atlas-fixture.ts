import { deflateSync } from "node:zlib";
export function chunk(type: string, bytes: Uint8Array): Buffer {
  const b = Buffer.alloc(bytes.length + 12);
  b.writeUInt32BE(bytes.length);
  b.write(type, 4);
  b.set(bytes, 8);
  let crc = 0xffffffff;
  for (let i = 4; i < bytes.length + 8; i++) {
    crc ^= b[i]!;
    for (let n = 0; n < 8; n++) crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
  }
  b.writeUInt32BE((crc ^ 0xffffffff) >>> 0, bytes.length + 8);
  return b;
}
export function atlasPNGFixture(
  channels = 4,
  filter = 0,
  compressed?: Buffer,
): Buffer {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(256);
  header.writeUInt32BE(256, 4);
  header[8] = 8;
  header[9] = channels === 4 ? 6 : 2;
  const rows = Buffer.alloc(256 * (256 * channels + 1));
  for (let y = 0; y < 256; y++) {
    rows[y * (256 * channels + 1)] = filter;
    for (let x = 1; x <= 256 * channels; x++)
      rows[y * (256 * channels + 1) + x] = (x + y) % 251;
  }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", compressed ?? deflateSync(rows)),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}
