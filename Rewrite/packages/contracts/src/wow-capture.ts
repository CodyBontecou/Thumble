/** Dedicated optical child boundary. No window handles, paths or permission prompts. */
export const WOW_CAPTURE_LIMITS = Object.freeze({
  requestBytes: 256,
  atlasBytes: 2 * 1024 * 1024,
  replyBytes: 4 * Math.ceil((2 * 1024 * 1024) / 3) + 1024,
  pngChunks: 256,
  rgbaBytes: 256 * 256 * 4,
});
const MAX = 18446744073709551615n;
export type WowCaptureIdentity = Readonly<{
  source: number;
  generation: string;
  receipt: string;
}>;
export type WowCaptureRequest = WowCaptureIdentity &
  Readonly<{ version: 1; command: "wow-capture" }>;
export const WOW_CAPTURE_STATUSES = [
  "permission-required",
  "game-not-visible",
  "multiple-game-windows",
  "panel-not-visible",
  "unavailable",
] as const;
export type WowCaptureStatus = (typeof WOW_CAPTURE_STATUSES)[number];
export type WowCaptureReply = WowCaptureIdentity &
  (
    | Readonly<{ kind: "frame"; frame: Uint8Array; atlasPNG: Uint8Array }>
    | Readonly<{ kind: "status"; status: WowCaptureStatus }>
  );
function invalid(): never {
  throw new Error("invalid_wow_capture_message");
}
export function wowCaptureCounter(value: unknown, zero = false): string {
  if (typeof value !== "string" || !/^(0|[1-9][0-9]{0,19})$/.test(value))
    return invalid();
  const n = BigInt(value);
  if (n > MAX || (!zero && n === 0n)) return invalid();
  return value;
}
function object(
  value: unknown,
  keys: readonly string[],
): Record<string, unknown> {
  if (
    value === null ||
    typeof value !== "object" ||
    ![Object.prototype, null].includes(Object.getPrototypeOf(value)) ||
    Reflect.ownKeys(value).length !== keys.length
  )
    return invalid();
  const result: Record<string, unknown> = {};
  for (const key of keys) {
    const d = Object.getOwnPropertyDescriptor(value, key);
    if (!d || !("value" in d)) return invalid();
    result[key] = d.value;
  }
  return result;
}
function identity(value: Record<string, unknown>): WowCaptureIdentity {
  const source = value.source;
  if (
    typeof source !== "number" ||
    !Number.isInteger(source) ||
    source < 1 ||
    source > 4294967295
  )
    return invalid();
  return Object.freeze({
    source,
    generation: wowCaptureCounter(value.generation),
    receipt: wowCaptureCounter(value.receipt),
  });
}
/** Flat scalar JSON only, with duplicate-key rejection before conversion. ASCII
 * bounds apply before parsing; binary payloads must use canonical base64. */
function flat(text: string, limit: number): Record<string, unknown> {
  if (typeof text !== "string" || text.length > limit) return invalid();
  for (let i = 0; i < text.length; i++)
    if (text.charCodeAt(i) > 127) return invalid();
  let at = 0;
  const result: Record<string, unknown> = Object.create(null);
  let fields = 0;
  const space = () => {
    while (at < text.length && /[\x20\t\r\n]/.test(text[at]!)) at++;
  };
  const string = (): string => {
    const start = at;
    if (text[at++] !== '"') return invalid();
    while (at < text.length) {
      const c = text.charCodeAt(at++);
      if (c < 32) return invalid();
      if (c === 34) {
        try {
          const value: unknown = JSON.parse(text.slice(start, at));
          if (typeof value !== "string") return invalid();
          return value;
        } catch {
          return invalid();
        }
      }
      if (c === 92) {
        if (text[at] === "u") at += 5;
        else at++;
      }
    }
    return invalid();
  };
  space();
  if (text[at++] !== "{") return invalid();
  space();
  if (text[at] !== "}")
    for (;;) {
      space();
      const key = string();
      if (key.length > 64 || Object.hasOwn(result, key) || ++fields > 9)
        return invalid();
      space();
      if (text[at++] !== ":") return invalid();
      space();
      if (text[at] === '"') result[key] = string();
      else {
        const token =
          /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?/.exec(
            text.slice(at),
          );
        if (!token || token[0].length > 32) return invalid();
        at += token[0].length;
        result[key] = Number(token[0]);
      }
      space();
      if (text[at] !== ",") break;
      at++;
    }
  if (text[at++] !== "}") return invalid();
  space();
  if (at !== text.length) return invalid();
  return result;
}
export function decodeWowCaptureRequest(value: unknown): WowCaptureRequest {
  const v = object(value, [
    "version",
    "command",
    "source",
    "generation",
    "receipt",
  ]);
  if (v.version !== 1 || v.command !== "wow-capture") return invalid();
  return Object.freeze({ version: 1, command: "wow-capture", ...identity(v) });
}
export function encodeWowCaptureRequest(value: WowCaptureRequest): string {
  const text = JSON.stringify(decodeWowCaptureRequest(value));
  if (text.length > WOW_CAPTURE_LIMITS.requestBytes) return invalid();
  return text;
}
export function parseWowCaptureRequest(text: string): WowCaptureRequest {
  return decodeWowCaptureRequest(flat(text, WOW_CAPTURE_LIMITS.requestBytes));
}
function base64(text: unknown, maximum: number, exact?: number): Uint8Array {
  if (
    typeof text !== "string" ||
    text.length === 0 ||
    text.length > 4 * Math.ceil(maximum / 3) ||
    text.length % 4 !== 0 ||
    !/^[A-Za-z0-9+/]*={0,2}$/.test(text)
  )
    return invalid();
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  const length = (text.length / 4) * 3 - padding;
  if (length > maximum || (exact !== undefined && length !== exact))
    return invalid();
  const alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
    bytes = new Uint8Array(length);
  let out = 0;
  for (let i = 0; i < text.length; i += 4) {
    const a = alphabet.indexOf(text[i]!),
      b = alphabet.indexOf(text[i + 1]!),
      c = text[i + 2] === "=" ? 0 : alphabet.indexOf(text[i + 2]!),
      d = text[i + 3] === "=" ? 0 : alphabet.indexOf(text[i + 3]!);
    if (a < 0 || b < 0 || c < 0 || d < 0) return invalid();
    if (
      i + 4 === text.length &&
      ((padding === 2 && (b & 15) !== 0) || (padding === 1 && (c & 3) !== 0))
    )
      return invalid();
    if (out < length) bytes[out++] = (a << 2) | (b >> 4);
    if (out < length) bytes[out++] = (b << 4) | (c >> 2);
    if (out < length) bytes[out++] = (c << 6) | d;
  }
  return bytes;
}
export function parseWowCaptureReply(
  text: string,
  expected: WowCaptureIdentity,
): WowCaptureReply {
  const v = flat(text, WOW_CAPTURE_LIMITS.replyBytes),
    kind = v.kind;
  const keys = [
    "version",
    "command",
    "source",
    "generation",
    "receipt",
    "kind",
    ...(kind === "frame" ? ["frameBase64", "atlasPNGBase64"] : ["status"]),
  ];
  const value = object(v, keys),
    id = identity(value);
  if (
    value.version !== 1 ||
    value.command !== "wow-capture-result" ||
    id.source !== expected.source ||
    id.generation !== expected.generation ||
    id.receipt !== expected.receipt
  )
    return invalid();
  if (kind === "frame")
    return Object.freeze({
      ...id,
      kind,
      frame: base64(value.frameBase64, 512, 512),
      atlasPNG: base64(value.atlasPNGBase64, WOW_CAPTURE_LIMITS.atlasBytes),
    });
  if (
    kind !== "status" ||
    typeof value.status !== "string" ||
    !(WOW_CAPTURE_STATUSES as readonly string[]).includes(value.status)
  )
    return invalid();
  return Object.freeze({
    ...id,
    kind,
    status: value.status as WowCaptureStatus,
  });
}
