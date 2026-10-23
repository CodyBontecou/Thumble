import { inflateSync } from "node:zlib";
/** Only a bounded32-square still PNG can cross the phone presentation boundary.
 * Container, CRC, compression, scan filters and decoded pixel count are checked
 * in the sole configuration child; no native image process or OS API is needed. */
export function verifyPresentationIcon(png: Uint8Array): void {
  const invalid = (): never => {
    throw new Error("presentation_icon_invalid");
  };
  if (!(png instanceof Uint8Array) || png.length < 57 || png.length > 8192)
    invalid();
  if ([137, 80, 78, 71, 13, 10, 26, 10].some((v, i) => png[i] !== v)) invalid();
  const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
  let header = false,
    data = false,
    dataEnded = false,
    end = false,
    channels = 0,
    count = 0,
    palette = false,
    transparency = false;
  const compressed: Buffer[] = [];
  for (let at = 8; at < png.length; ) {
    if (++count > 64 || at + 12 > png.length) invalid();
    const n = view.getUint32(at),
      next = at + n + 12;
    if (next > png.length) invalid();
    const type = String.fromCharCode(...png.subarray(at + 4, at + 8));
    if (!/^[A-Za-z]{2}[A-Z][A-Za-z]$/.test(type)) invalid();
    let crc = 0xffffffff;
    for (let i = at + 4; i < at + 8 + n; i++) {
      crc ^= png[i]!;
      for (let bit = 0; bit < 8; bit++)
        crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
    if ((crc ^ 0xffffffff) >>> 0 !== view.getUint32(at + 8 + n)) invalid();
    if (!header) {
      if (
        type !== "IHDR" ||
        n !== 13 ||
        view.getUint32(at + 8) !== 32 ||
        view.getUint32(at + 12) !== 32 ||
        png[at + 16] !== 8 ||
        ![2, 6].includes(png[at + 17]!) ||
        png[at + 18] !== 0 ||
        png[at + 19] !== 0 ||
        png[at + 20] !== 0
      )
        invalid();
      channels = png[at + 17] === 6 ? 4 : 3;
      header = true;
    } else if (
      type === "IHDR" ||
      ["acTL", "fcTL", "fdAT", "iCCP", "zTXt", "iTXt"].includes(type)
    )
      invalid();
    else if (type === "IDAT") {
      if (dataEnded) invalid();
      data = true;
      compressed.push(Buffer.from(png.subarray(at + 8, at + 8 + n)));
    } else if (type === "IEND") {
      if (n !== 0 || !data || next !== png.length) invalid();
      end = true;
    } else {
      if (data) dataEnded = true;
      if (type === "PLTE") {
        if (data || palette || !n || n > 768 || n % 3) invalid();
        palette = true;
      } else if (type === "tRNS") {
        if (
          data ||
          transparency ||
          channels !== 3 ||
          n !== 6 ||
          [0, 2, 4].some((offset) => png[at + 8 + offset] !== 0)
        )
          invalid();
        transparency = true;
      } else if (type[0] === type[0]!.toUpperCase()) invalid();
    }
    at = next;
  }
  if (!end) invalid();
  const stride = 32 * channels,
    expected = 32 * (stride + 1),
    input = Buffer.concat(compressed);
  const result: unknown = inflateSync(input, {
    maxOutputLength: expected,
    info: true,
  });
  if (
    typeof result !== "object" ||
    result === null ||
    !("buffer" in result) ||
    !Buffer.isBuffer(result.buffer) ||
    !("engine" in result) ||
    typeof result.engine !== "object" ||
    result.engine === null ||
    !("bytesWritten" in result.engine) ||
    result.engine.bytesWritten !== input.length ||
    result.buffer.length !== expected
  )
    return invalid();
  const scan = result.buffer,
    pixels = new Uint8Array(32 * stride);
  const paeth = (a: number, b: number, c: number) => {
    const p = a + b - c,
      x = Math.abs(p - a),
      y = Math.abs(p - b),
      z = Math.abs(p - c);
    return x <= y && x <= z ? a : y <= z ? b : c;
  };
  for (let y = 0; y < 32; y++) {
    const filter = scan[y * (stride + 1)]!;
    if (filter > 4) invalid();
    for (let x = 0; x < stride; x++) {
      const at = y * stride + x,
        a = x >= channels ? pixels[at - channels]! : 0,
        b = y ? pixels[at - stride]! : 0,
        c = y && x >= channels ? pixels[at - stride - channels]! : 0;
      pixels[at] =
        scan[y * (stride + 1) + x + 1]! +
        (filter === 0
          ? 0
          : filter === 1
            ? a
            : filter === 2
              ? b
              : filter === 3
                ? Math.floor((a + b) / 2)
                : paeth(a, b, c));
    }
  }
}
