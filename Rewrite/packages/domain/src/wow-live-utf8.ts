const invalid = (): never => {
  throw new Error("invalid_wow_live_utf8");
};

/** Fatal UTF-8 decoding without platform APIs, usable by headless and phone cores. */
export function decodeWowLiveUtf8(bytes: Uint8Array): string {
  const characters: string[] = [];
  for (let at = 0; at < bytes.length; ) {
    const first = bytes[at++]!;
    let code: number, remaining: number, minimum: number;
    if (first < 0x80) {
      code = first;
      remaining = 0;
      minimum = 0;
    } else if (first >= 0xc2 && first <= 0xdf) {
      code = first & 31;
      remaining = 1;
      minimum = 0x80;
    } else if (first >= 0xe0 && first <= 0xef) {
      code = first & 15;
      remaining = 2;
      minimum = 0x800;
    } else if (first >= 0xf0 && first <= 0xf4) {
      code = first & 7;
      remaining = 3;
      minimum = 0x10000;
    } else return invalid();
    for (let index = 0; index < remaining; index++) {
      const next = bytes[at++];
      if (next === undefined || (next & 0xc0) !== 0x80) return invalid();
      code = code * 64 + (next & 63);
    }
    if (code < minimum || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff))
      return invalid();
    characters.push(String.fromCodePoint(code));
  }
  return characters.join("");
}
export function wowLiveUtf8Size(value: string): number {
  let bytes = 0;
  for (const character of value) {
    const code = character.codePointAt(0)!;
    if (code >= 0xd800 && code <= 0xdfff) return invalid();
    bytes += code < 0x80 ? 1 : code < 0x800 ? 2 : code < 0x10000 ? 3 : 4;
  }
  return bytes;
}
