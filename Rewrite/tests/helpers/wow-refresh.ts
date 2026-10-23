import { createHash } from "node:crypto";
import { deflateSync, inflateSync } from "node:zlib";
import { WowCapturedFrame } from "@thumble/domain/wow-capture-receipt";
import { wowLiveChecksum } from "@thumble/domain/wow-live";
export const digest = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");
export const snapshot = (name = "Synthetic") => ({
  schema: "thumble.wow-live",
  version: 1,
  client: { flavor: "classic-era", interface: 11509 },
  character: {
    id: "Player-Synthetic",
    name,
    realm: "Fixture",
    classTag: "MAGE",
  },
  actions: [],
  icons: [],
  devices: [],
  consolePortVersion: "absent",
});
function crc(bytes: Uint8Array) {
  let c = 0xffffffff;
  for (const b of bytes) {
    c ^= b;
    for (let n = 0; n < 8; n++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
  }
  return (c ^ 0xffffffff) >>> 0;
}
function chunk(type: string, data: Uint8Array) {
  const b = Buffer.alloc(data.length + 12);
  b.writeUInt32BE(data.length);
  b.write(type, 4);
  b.set(data, 8);
  b.writeUInt32BE(crc(b.subarray(4, -4)), b.length - 4);
  return b;
}
export function atlas(fill = 0) {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(256);
  header.writeUInt32BE(256, 4);
  header[8] = 8;
  header[9] = 6;
  const raw = Buffer.alloc(262400, fill);
  for (let y = 0; y < 256; y++) raw[y * 1025] = 0;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(raw)),
    chunk("IEND", new Uint8Array()),
  ]);
}
export function captured(
  tick: number,
  now = 0,
  fill = 0,
  name = "Synthetic",
): WowCapturedFrame {
  const payload = Buffer.from(JSON.stringify(snapshot(name))),
    bytes = Buffer.alloc(512);
  if (payload.length > 487) throw Error("fixture_too_large");
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  bytes.set([84, 72, 87, 76, 1]);
  view.setUint32(5, tick, true);
  view.setUint32(9, wowLiveChecksum(payload), true);
  view.setUint16(15, 1, true);
  view.setUint16(17, payload.length, true);
  view.setUint16(19, payload.length, true);
  bytes.set(payload, 25);
  view.setUint32(
    21,
    wowLiveChecksum(Buffer.concat([bytes.subarray(0, 21), payload])),
    true,
  );
  return new WowCapturedFrame(
    {
      kind: "frame",
      source: 42,
      generation: "1",
      receipt: String(tick),
      frame: bytes,
      atlasPNG: atlas(fill),
    },
    now,
    (png, limits) => {
      const b = Buffer.from(png),
        parts: Uint8Array[] = [];
      for (let at = 8; at < b.length; ) {
        const n = b.readUInt32BE(at);
        if (b.toString("ascii", at + 4, at + 8) === "IDAT")
          parts.push(b.subarray(at + 8, at + 8 + n));
        at += n + 12;
      }
      const raw = inflateSync(Buffer.concat(parts), {
        maxOutputLength: limits.maxInflatedBytes,
      });
      if (raw.length !== 262400) throw Error("fixture_raster_invalid");
      const rgba = new Uint8Array(262144);
      for (let y = 0; y < 256; y++) {
        if (raw[y * 1025] !== 0) throw Error("fixture_filter_invalid");
        rgba.set(raw.subarray(y * 1025 + 1, (y + 1) * 1025), y * 1024);
      }
      return { width: 256, height: 256, rgba };
    },
  );
}
