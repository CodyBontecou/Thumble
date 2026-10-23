import { LosslessJson, LOSSLESS_JSON_LIMITS } from "@thumble/contracts/json";

function fail(code = "owned_projection_opaque_conflict"): never {
  throw new Error(code);
}
const pointer = (key: string) =>
  "/" + key.replaceAll("~", "~0").replaceAll("/", "~1");
function normalizedUUID(value: string): string | undefined {
  let text = value.toLowerCase().replace(/^urn:uuid:/, "");
  if (text.startsWith("{") && text.endsWith("}")) text = text.slice(1, -1);
  if (/^[0-9a-f]{32}$/.test(text))
    text = `${text.slice(0, 8)}-${text.slice(8, 12)}-${text.slice(12, 16)}-${text.slice(16, 20)}-${text.slice(20)}`;
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(
    text,
  )
    ? text
    : undefined;
}
export const OWNED_PROJECTION_MERGE_LIMITS = Object.freeze({
  objectFields: 512,
});
type Field = Readonly<{ key: string; value: LosslessJson }>;
function fields(value: LosslessJson): Map<string, Field> {
  const result = new Map<string, Field>();
  if (value.keys.length > OWNED_PROJECTION_MERGE_LIMITS.objectFields)
    fail("owned_projection_too_complex");
  for (const key of value.keys) {
    const normalized = key.normalize("NFC");
    if (result.has(normalized)) fail("owned_projection_invalid");
    result.set(normalized, { key, value: value.get(pointer(key))! });
  }
  return result;
}
function items(value: LosslessJson): readonly LosslessJson[] {
  return Array.from({ length: value.length! }, (_, i) => value.get("/" + i)!);
}
function identities(
  values: readonly LosslessJson[],
): Map<string, number> | undefined {
  const result = new Map<string, number>();
  for (const [index, value] of values.entries()) {
    const raw =
      value.kind === "object" ? value.get("/id")?.stringValue : undefined;
    if (raw === undefined) return;
    const id = normalizedUUID(raw) ?? raw;
    if (result.has(id)) fail("owned_projection_invalid");
    result.set(id, index);
  }
  return result;
}
/** Strict parsing has already established member boundaries. Preserve original key
 * tokens, colon trivia and opaque value spelling while editing all members once. */
function rewriteObject(
  original: LosslessJson,
  edits: ReadonlyMap<string, LosslessJson | undefined>,
): LosslessJson {
  const raw = original.text();
  let cursor = 1;
  const members: string[] = [];
  const keys = new Set(original.keys);
  const skip = () => {
    while (/[ \t\r\n]/.test(raw[cursor] ?? "!")) cursor++;
  };
  for (const key of original.keys) {
    skip();
    const start = cursor++;
    while (cursor < raw.length) {
      const character = raw[cursor++];
      if (character === "\\") cursor++;
      else if (character === '"') break;
    }
    skip();
    cursor++;
    skip();
    const valueStart = cursor;
    cursor += original.get(pointer(key))!.text().length;
    const replacement = edits.has(key)
      ? edits.get(key)
      : original.get(pointer(key));
    if (replacement)
      members.push(raw.slice(start, valueStart) + replacement.text());
    skip();
    if (raw[cursor] === ",") cursor++;
  }
  for (const [key, value] of edits)
    if (!keys.has(key) && value)
      members.push(JSON.stringify(key) + ":" + value.text());
  return LosslessJson.parse("{" + members.join(",") + "}");
}
/** Same-codec before/after projections only. Applies changed known fields while
 * retaining opaque source values and number spellings; never validates authority,
 * chooses a profile, persists bytes or authorizes input. */
export function mergeOwnedProjection(
  source: LosslessJson,
  before: LosslessJson,
  after: LosslessJson,
): LosslessJson {
  if (![source, before, after].every((v) => v instanceof LosslessJson))
    fail("owned_projection_invalid");
  // Validate NFC uniqueness even when a projection has no changed known fields.
  for (const document of [source, before, after]) {
    const pending = [document];
    while (pending.length) {
      const value = pending.pop()!;
      if (value.kind === "object")
        for (const item of fields(value).values()) pending.push(item.value);
      else if (value.kind === "array")
        for (const item of items(value)) pending.push(item);
    }
  }
  let budget = LOSSLESS_JSON_LIMITS.nodes * 4;
  function visit(depth: number) {
    if (depth > LOSSLESS_JSON_LIMITS.depth || --budget < 0)
      fail("owned_projection_too_complex");
  }
  function sourceField(
    original: Map<string, Field>,
    key: string,
    depth: number,
  ): Field | undefined {
    const id = normalizedUUID(key);
    if (id)
      for (const candidate of original.keys()) {
        visit(depth);
        if (candidate !== key && normalizedUUID(candidate) === id) fail();
      }
    return original.get(key);
  }
  function opaque(
    original: LosslessJson,
    known: LosslessJson,
    depth: number,
  ): boolean {
    visit(depth);
    if (original.text() === known.text()) return false;
    if (original.kind === "object" && known.kind === "object") {
      const projected = fields(known);
      for (const [key, item] of fields(original)) {
        const prior = projected.get(key);
        if (!prior || opaque(item.value, prior.value, depth + 1)) return true;
      }
    } else if (original.kind === "array" && known.kind === "array") {
      const raw = items(original),
        projection = items(known),
        a = identities(raw),
        b = identities(projection);
      if (a && b) {
        for (const [id, index] of a) {
          const previous = b.get(id);
          if (
            previous === undefined ||
            opaque(raw[index]!, projection[previous]!, depth + 1)
          )
            return true;
        }
      } else {
        if (raw.length > projection.length) return true;
        for (let i = 0; i < raw.length; i++)
          if (opaque(raw[i]!, projection[i]!, depth + 1)) return true;
      }
    } else if (original.kind === "object") return original.keys.length !== 0;
    else if (original.kind === "array") return original.length !== 0;
    return false;
  }
  function merge(
    original: LosslessJson,
    old: LosslessJson,
    next: LosslessJson,
    depth: number,
  ): LosslessJson {
    visit(depth);
    if (old.text() === next.text() || original.text() === next.text())
      return original;
    if (
      original.kind === "object" &&
      old.kind === "object" &&
      next.kind === "object"
    ) {
      const raw = fields(original),
        previous = fields(old),
        future = fields(next);
      const edits = new Map<string, LosslessJson | undefined>();
      for (const [key, item] of previous)
        if (!future.has(key)) {
          const prior = sourceField(raw, key, depth + 1);
          if (prior) {
            if (opaque(prior.value, item.value, depth + 1)) fail();
            edits.set(prior.key, undefined);
          }
        }
      for (const [key, item] of future) {
        visit(depth + 1);
        const prior = previous.get(key);
        if (prior?.value.text() === item.value.text()) continue;
        const current = sourceField(raw, key, depth + 1);
        let replacement: LosslessJson;
        if (current && prior)
          replacement = merge(
            current.value,
            prior.value,
            item.value,
            depth + 1,
          );
        else if (current && current.value.text() === item.value.text())
          continue;
        else if (current && current.value.kind !== "null") fail();
        else replacement = item.value;
        if (replacement.text() !== current?.value.text())
          edits.set(current?.key ?? item.key, replacement);
      }
      return edits.size ? rewriteObject(original, edits) : original;
    }
    if (
      original.kind === "array" &&
      old.kind === "array" &&
      next.kind === "array"
    ) {
      const raw = items(original),
        previous = items(old),
        future = items(next),
        a = identities(raw),
        b = identities(previous),
        c = identities(future);
      let result: readonly LosslessJson[];
      if (a && b && c) {
        for (const [id, index] of a)
          if (!c.has(id)) {
            const prior = b.get(id);
            if (
              prior === undefined ||
              opaque(raw[index]!, previous[prior]!, depth + 1)
            )
              fail();
          }
        result = future.map((item) => {
          const id =
              normalizedUUID(item.get("/id")!.stringValue!) ??
              item.get("/id")!.stringValue!,
            index = a.get(id),
            prior = b.get(id);
          if (index !== undefined && prior !== undefined)
            return merge(raw[index]!, previous[prior]!, item, depth + 1);
          if (index !== undefined) fail();
          return item;
        });
      } else {
        if (opaque(original, old, depth + 1)) fail();
        if (raw.length !== previous.length || previous.length !== future.length)
          return next;
        result = raw.map((item, i) =>
          merge(item, previous[i]!, future[i]!, depth + 1),
        );
      }
      return LosslessJson.parse(
        "[" + result.map((item) => item.text()).join(",") + "]",
      );
    }
    if (opaque(original, old, depth + 1)) fail();
    return next;
  }
  const root = source.get("")!,
    result = merge(root, before.get("")!, after.get("")!, 0);
  if (result === root) return source;
  const framing = source.text(),
    leading = /^[ \t\r\n]*/.exec(framing)![0],
    trailing = /[ \t\r\n]*$/.exec(framing)![0];
  return LosslessJson.parse(leading + result.text() + trailing);
}
