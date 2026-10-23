import type { LosslessJson } from "@thumble/contracts/json";
import {
  entries,
  field,
  invalidOwned,
  object,
  only,
  visit,
} from "./owned-json.ts";
const MAXIMUM_BYTES = 8 * 1024 * 1024;
function base64Value(character: number): number {
  if (character >= 65 && character <= 90) return character - 65;
  if (character >= 97 && character <= 122) return character - 71;
  if (character >= 48 && character <= 57) return character + 4;
  return character === 43 ? 62 : character === 47 ? 63 : -1;
}
/** Resource integrity only; the host supplies an established SHA-256 implementation.
 * This function is never supplied by an imported document or a remote caller. */
export type ResourceDigest = (bytes: Uint8Array) => string;
export function decodeResourceBase64(text: string): Uint8Array {
  if (text.length > Math.ceil(MAXIMUM_BYTES / 3) * 4 || text.length % 4 !== 0)
    invalidOwned();
  const padding = text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0;
  const size = (text.length / 4) * 3 - padding;
  if (size > MAXIMUM_BYTES) invalidOwned();
  const bytes = new Uint8Array(size);
  let at = 0;
  // Constant stack and linear work even for multi-megabyte strings. Repeated
  // regex groups can overflow an engine's regexp stack on valid large resources.
  for (let i = 0; i < text.length; i += 4) {
    const a = base64Value(text.charCodeAt(i)),
      b = base64Value(text.charCodeAt(i + 1));
    const c =
      i + 2 >= text.length - padding ? 0 : base64Value(text.charCodeAt(i + 2));
    const d =
      i + 3 >= text.length - padding ? 0 : base64Value(text.charCodeAt(i + 3));
    if (
      a < 0 ||
      b < 0 ||
      c < 0 ||
      d < 0 ||
      (i + 4 === text.length &&
        ((padding === 2 && (b & 15) !== 0) || (padding === 1 && (c & 3) !== 0)))
    )
      invalidOwned();
    const word = (a << 18) | (b << 12) | (c << 6) | d;
    if (at < size) bytes[at++] = word >>> 16;
    if (at < size) bytes[at++] = word >>> 8;
    if (at < size) bytes[at++] = word;
  }
  return bytes;
}
/** Portable canonical encoder, with bounded work and no spread/call-stack growth. */
export function encodeResourceBase64(bytes: Uint8Array): string {
  if (!(bytes instanceof Uint8Array) || bytes.length > MAXIMUM_BYTES)
    invalidOwned();
  const alphabet =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const parts: string[] = [];
  let chunk = "";
  for (let i = 0; i < bytes.length; i += 3) {
    const a = bytes[i]!,
      b = bytes[i + 1] ?? 0,
      c = bytes[i + 2] ?? 0;
    chunk +=
      alphabet[a >>> 2]! +
      alphabet[((a & 3) << 4) | (b >>> 4)]! +
      (i + 1 < bytes.length ? alphabet[((b & 15) << 2) | (c >>> 6)]! : "=") +
      (i + 2 < bytes.length ? alphabet[c & 63]! : "=");
    if (chunk.length >= 8192) {
      parts.push(chunk);
      chunk = "";
    }
  }
  parts.push(chunk);
  return parts.join("");
}
/** One private byte allocation per digest. Reads return defensive copies. */
export class OwnedResourceTable {
  readonly #entries: ReadonlyMap<string, Uint8Array>;
  readonly byteCount: number;
  get count(): number {
    return this.#entries.size;
  }
  private constructor(
    entries: ReadonlyMap<string, Uint8Array>,
    byteCount: number,
  ) {
    this.#entries = entries;
    this.byteCount = byteCount;
    Object.freeze(this);
  }
  static read(
    profile: LosslessJson,
    digest: ResourceDigest,
  ): OwnedResourceTable | undefined {
    const version = profile.get("/appearanceResourceVersion"),
      raw = profile.get("/appearanceResources");
    if (!version && !raw) {
      // A known resource reference cannot become an opaque dangling reference.
      visit(profile, (node) => {
        if (node.kind === "object" && node.keys.includes("resourceSHA256"))
          invalidOwned();
      });
      return undefined;
    }
    if (
      version?.integerValue !== 1 ||
      field(profile, "appearanceBank")?.kind !== "object"
    )
      invalidOwned();
    const pool = new Map<string, Uint8Array>();
    let bytes = 0;
    for (const [key, value] of entries(raw, 131072)) {
      const encoded = value.stringValue;
      if (!/^[0-9a-f]{64}$/.test(key) || encoded === undefined) invalidOwned();
      const decoded = decodeResourceBase64(encoded);
      bytes += decoded.length;
      if (bytes > MAXIMUM_BYTES || digest(decoded.slice()) !== key)
        invalidOwned();
      pool.set(key, decoded);
    }
    const table = new OwnedResourceTable(pool, bytes);
    for (const [key, value] of entries(profile))
      if (key !== "appearanceResources")
        visit(value, (node) => {
          if (node.kind === "object" && node.keys.includes("resourceSHA256"))
            table.referenceSize(node);
        });
    return table;
  }
  referenceSize(reference: LosslessJson): number {
    only(object(reference), ["resourceSHA256"]);
    const key = reference.get("/resourceSHA256")?.stringValue;
    const bytes = key === undefined ? undefined : this.#entries.get(key);
    if (!bytes) invalidOwned();
    return bytes.length;
  }
  data(reference: LosslessJson): Uint8Array {
    this.referenceSize(reference);
    return this.#entries
      .get(reference.get("/resourceSHA256")!.stringValue!)!
      .slice();
  }
}
Object.freeze(OwnedResourceTable.prototype);
export function hasResourceData(
  value: LosslessJson | undefined,
  table: OwnedResourceTable | undefined,
): boolean {
  if (!value) return false;
  if (value.kind === "string")
    return decodeResourceBase64(value.stringValue!).length > 0;
  if (!table) invalidOwned();
  return table.referenceSize(value) > 0;
}
