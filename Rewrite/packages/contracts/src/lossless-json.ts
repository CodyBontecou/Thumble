/** Configuration-source JSON. Never use this codec for runtime commands or credentials. */
export const LOSSLESS_JSON_LIMITS = Object.freeze({
  bytes: 8 * 1024 * 1024,
  depth: 64,
  nodes: 131072,
});
export const LOSSLESS_JSON_CANONICALIZATION = "thumble-lossless-json-v1";
type Body =
  | { kind: "null" }
  | { kind: "boolean"; value: boolean }
  | { kind: "string"; value: string }
  | { kind: "number"; token: string }
  | { kind: "array"; items: readonly Node[] }
  | { kind: "object"; entries: readonly (readonly [string, Node])[] };
type Node = Readonly<
  Body & { span: Readonly<{ source: string; start: number; end: number }> }
>;
const invalid = (): never => {
  throw new Error("invalid_configuration_json");
};
function utf8Size(text: string, limit: number): number {
  let bytes = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c >= 0xd800 && c <= 0xdbff) {
      const low = text.charCodeAt(++i);
      if (!(low >= 0xdc00 && low <= 0xdfff)) invalid();
      bytes += 4;
    } else if (c >= 0xdc00 && c <= 0xdfff) invalid();
    else bytes += c < 128 ? 1 : c < 2048 ? 2 : 3;
    if (bytes > limit) throw new Error("configuration_json_too_large");
  }
  return bytes;
}
function parse(text: string): Node {
  if (typeof text !== "string" || text.length > LOSSLESS_JSON_LIMITS.bytes)
    invalid();
  utf8Size(text, LOSSLESS_JSON_LIMITS.bytes);
  let at = 0,
    nodes = 0;
  const space = () => {
    while (at < text.length && /[\x20\t\r\n]/.test(text[at]!)) at++;
  };
  function string(): string {
    const start = at;
    if (text[at++] !== '"') return invalid();
    while (at < text.length) {
      const c = text.charCodeAt(at++);
      if (c < 32) return invalid();
      if (c === 34) {
        const decoded: unknown = JSON.parse(text.slice(start, at));
        if (typeof decoded !== "string") return invalid();
        utf8Size(decoded, LOSSLESS_JSON_LIMITS.bytes);
        return decoded;
      }
      if (c === 92) {
        const escape = text[at++];
        if (escape === "u") {
          if (!/^[0-9a-fA-F]{4}$/.test(text.slice(at, at + 4)))
            return invalid();
          at += 4;
        } else if (!escape || !'"\\/bfnrt'.includes(escape)) return invalid();
      }
    }
    return invalid();
  }
  function value(depth: number): Node {
    if (
      depth > LOSSLESS_JSON_LIMITS.depth ||
      ++nodes > LOSSLESS_JSON_LIMITS.nodes
    )
      invalid();
    space();
    const start = at;
    let body: Body;
    if (text[at] === "{") {
      at++;
      space();
      const keys = new Set<string>(),
        entries: Array<readonly [string, Node]> = [];
      if (text[at] !== "}")
        for (;;) {
          space();
          const key = string();
          if (keys.has(key)) invalid();
          keys.add(key);
          space();
          if (text[at++] !== ":") invalid();
          entries.push(Object.freeze([key, value(depth + 1)] as const));
          space();
          if (text[at] !== ",") break;
          at++;
        }
      if (text[at++] !== "}") invalid();
      body = { kind: "object", entries: Object.freeze(entries) };
    } else if (text[at] === "[") {
      at++;
      space();
      const items: Node[] = [];
      if (text[at] !== "]")
        for (;;) {
          items.push(value(depth + 1));
          space();
          if (text[at] !== ",") break;
          at++;
        }
      if (text[at++] !== "]") invalid();
      body = { kind: "array", items: Object.freeze(items) };
    } else if (text[at] === '"') body = { kind: "string", value: string() };
    else {
      const expression =
        /(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/y;
      expression.lastIndex = at;
      const token = expression.exec(text)?.[0];
      if (token === undefined) return invalid();
      at += token.length;
      body =
        token === "null"
          ? { kind: "null" }
          : token === "true" || token === "false"
            ? { kind: "boolean", value: token === "true" }
            : { kind: "number", token };
    }
    return Object.freeze({
      ...body,
      span: Object.freeze({ source: text, start, end: at }),
    });
  }
  const root = value(0);
  space();
  if (at !== text.length) invalid();
  return root;
}
function render(node: Node, canonical: boolean): string {
  if (!canonical) return node.span.source.slice(node.span.start, node.span.end);
  const pieces: string[] = [];
  function emit(value: Node): void {
    switch (value.kind) {
      case "null":
        pieces.push("null");
        return;
      case "boolean":
        pieces.push(value.value ? "true" : "false");
        return;
      case "number":
        pieces.push(value.token);
        return;
      case "string":
        pieces.push(JSON.stringify(value.value));
        return;
      case "array":
        pieces.push("[");
        value.items.forEach((item, i) => {
          if (i) pieces.push(",");
          emit(item);
        });
        pieces.push("]");
        return;
      case "object":
        pieces.push("{");
        [...value.entries]
          .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0))
          .forEach(([key, child], i) => {
            if (i) pieces.push(",");
            pieces.push(JSON.stringify(key), ":");
            emit(child);
          });
        pieces.push("}");
    }
  }
  emit(node);
  return pieces.join("");
}
function pointer(text: string): readonly string[] {
  if (typeof text !== "string" || text.length > 4096)
    throw new Error("invalid_json_pointer");
  utf8Size(text, 4096);
  if (text === "") return [];
  if (!text.startsWith("/")) throw new Error("invalid_json_pointer");
  const path = text
    .slice(1)
    .split("/")
    .map((part) => {
      if (/~(?:[^01]|$)/.test(part)) throw new Error("invalid_json_pointer");
      return part.replaceAll("~1", "/").replaceAll("~0", "~");
    });
  if (path.length > LOSSLESS_JSON_LIMITS.depth)
    throw new Error("invalid_json_pointer");
  return path;
}
function index(part: string, length: number, append: boolean): number {
  if (append && part === "-") return length;
  if (!/^(?:0|[1-9][0-9]*)$/.test(part) || part.length > 10)
    throw new Error("json_path_missing");
  const value = Number(part);
  if (value >= length) throw new Error("json_path_missing");
  return value;
}
function child(node: Node, part: string): Node | undefined {
  if (node.kind === "object")
    return node.entries.find(([key]) => key === part)?.[1];
  if (node.kind === "array")
    return node.items[index(part, node.items.length, false)];
  return undefined;
}
/** Exact mathematical view; never round a fractional decimal through IEEE-754 first. */
function safeInteger(token: string): number | undefined {
  const match = /^(-?)(\d+)(?:\.(\d+))?(?:[eE]([+-]?\d+))?$/.exec(token)!;
  let digits = (match[2]! + (match[3] ?? "")).replace(/^0+/, "");
  if (digits === "") return 0;
  const rawExponent = match[4] ?? "0";
  const exponentDigits = rawExponent.replace(/^[+-]/, "").replace(/^0+/, "");
  if (exponentDigits.length > 6) return undefined;
  const exponent =
    (rawExponent.startsWith("-") ? -1 : 1) * Number(exponentDigits || "0");
  const shift = exponent - (match[3]?.length ?? 0);
  if (shift >= 0) {
    if (digits.length + shift > 16) return undefined;
    digits += "0".repeat(shift);
  } else {
    if (-shift >= digits.length || !/^0+$/.test(digits.slice(shift)))
      return undefined;
    digits = digits.slice(0, shift);
  }
  if (digits.length > 16) return undefined;
  const integer = BigInt((match[1] ?? "") + digits);
  return integer >= -9007199254740991n && integer <= 9007199254740991n
    ? Number(integer)
    : undefined;
}
export class LosslessJson {
  static readonly canonicalization = LOSSLESS_JSON_CANONICALIZATION;
  readonly #node: Node;
  readonly #text: string;
  private constructor(node: Node, text: string) {
    this.#node = node;
    this.#text = text;
    Object.freeze(this);
  }
  static parse(text: string): LosslessJson {
    return new LosslessJson(parse(text), text);
  }
  get kind(): Node["kind"] {
    return this.#node.kind;
  }
  get stringValue(): string | undefined {
    return this.#node.kind === "string" ? this.#node.value : undefined;
  }
  get booleanValue(): boolean | undefined {
    return this.#node.kind === "boolean" ? this.#node.value : undefined;
  }
  get numberToken(): string | undefined {
    return this.#node.kind === "number" ? this.#node.token : undefined;
  }
  get integerValue(): number | undefined {
    return this.#node.kind === "number"
      ? safeInteger(this.#node.token)
      : undefined;
  }
  get keys(): readonly string[] {
    return Object.freeze(
      this.#node.kind === "object"
        ? this.#node.entries.map(([key]) => key)
        : [],
    );
  }
  get length(): number | undefined {
    return this.#node.kind === "array" ? this.#node.items.length : undefined;
  }
  text(): string {
    return this.#text;
  }
  get byteLength(): number {
    return utf8Size(this.#text, LOSSLESS_JSON_LIMITS.bytes);
  }
  /** UTF-16 key ordering and unchanged number lexemes: deliberately not RFC 8785. */
  canonicalText(): string {
    return render(this.#node, true);
  }
  get(path: string): LosslessJson | undefined {
    let node: Node | undefined = this.#node;
    try {
      for (const part of pointer(path)) {
        if (!node) return undefined;
        node = child(node, part);
      }
    } catch (error) {
      if (error instanceof Error && error.message === "json_path_missing")
        return undefined;
      throw error;
    }
    return node ? new LosslessJson(node, render(node, false)) : undefined;
  }
  /** Atomically replace nonoverlapping existing values in one traversal. No
   * insertion/removal/index shifting; untouched source spans stay exact. */
  replaceValues(replacements: ReadonlyMap<string, LosslessJson>): LosslessJson {
    if (
      !(replacements instanceof Map) ||
      Object.getOwnPropertyDescriptor(Map.prototype, "size")!.get!.call(
        replacements,
      ) > 8192
    )
      throw new Error("json_replacements_invalid");
    type Edit = { replacement?: Node; children: Map<string, Edit> };
    const root: Edit = { children: new Map() };
    for (const [path, value] of Map.prototype.entries.call(replacements)) {
      if (typeof path !== "string" || !(value instanceof LosslessJson))
        throw new Error("json_replacements_invalid");
      let edit = root;
      for (const part of pointer(path)) {
        if (edit.replacement) throw new Error("json_replacements_overlap");
        let next = edit.children.get(part);
        if (!next) {
          next = { children: new Map() };
          edit.children.set(part, next);
        }
        edit = next;
      }
      if (edit.replacement || edit.children.size)
        throw new Error("json_replacements_overlap");
      edit.replacement = value.#node;
    }
    if (root.children.size === 0 && !root.replacement) return this;
    const pieces: string[] = [];
    let length = 0;
    const append = (...values: string[]) => {
      for (const value of values) {
        length += value.length;
        if (length > LOSSLESS_JSON_LIMITS.bytes)
          throw new Error("configuration_json_too_large");
        pieces.push(value);
      }
    };
    function change(node: Node, edit: Edit): void {
      if (edit.replacement) {
        append(render(edit.replacement, false));
        return;
      }
      if (edit.children.size === 0) {
        append(render(node, false));
        return;
      }
      const found = new Set<string>();
      if (node.kind === "object") {
        append("{");
        node.entries.forEach(([key, value], i) => {
          if (i) append(",");
          append(JSON.stringify(key), ":");
          const child = edit.children.get(key);
          if (child) {
            found.add(key);
            change(value, child);
          } else append(render(value, false));
        });
        append("}");
      } else if (node.kind === "array") {
        append("[");
        node.items.forEach((value, i) => {
          if (i) append(",");
          const key = String(i),
            child = edit.children.get(key);
          if (child) {
            found.add(key);
            change(value, child);
          } else append(render(value, false));
        });
        append("]");
      }
      if (found.size !== edit.children.size)
        throw new Error("json_path_missing");
    }
    change(this.#node, root);
    return LosslessJson.parse(pieces.join(""));
  }
  set(path: string, replacement: string): LosslessJson {
    return this.edit(pointer(path), parse(replacement));
  }
  remove(path: string): LosslessJson {
    const parts = pointer(path);
    if (parts.length === 0) throw new Error("json_root_removal_forbidden");
    return this.edit(parts, undefined);
  }
  private edit(
    parts: readonly string[],
    replacement: Node | undefined,
  ): LosslessJson {
    const pieces: string[] = [];
    function change(node: Node, depth: number): void {
      if (depth === parts.length) {
        if (!replacement) throw new Error("json_path_missing");
        pieces.push(render(replacement, false));
        return;
      }
      const part = parts[depth]!,
        last = depth === parts.length - 1;
      if (node.kind === "object") {
        const exists = node.entries.some(([key]) => key === part);
        if (!exists && (!last || !replacement))
          throw new Error("json_path_missing");
        pieces.push("{");
        let count = 0;
        for (const [key, value] of node.entries) {
          if (key === part && last && !replacement) continue;
          if (count++) pieces.push(",");
          pieces.push(JSON.stringify(key), ":");
          if (key === part) change(value, depth + 1);
          else pieces.push(render(value, false));
        }
        if (!exists && replacement) {
          if (count) pieces.push(",");
          pieces.push(JSON.stringify(part), ":", render(replacement, false));
        }
        pieces.push("}");
        return;
      }
      if (node.kind === "array") {
        const selected = index(
          part,
          node.items.length,
          last && replacement !== undefined,
        );
        pieces.push("[");
        let count = 0;
        node.items.forEach((value, at) => {
          if (at === selected && last && !replacement) return;
          if (count++) pieces.push(",");
          if (at === selected) change(value, depth + 1);
          else pieces.push(render(value, false));
        });
        if (selected === node.items.length && replacement) {
          if (count) pieces.push(",");
          pieces.push(render(replacement, false));
        }
        pieces.push("]");
        return;
      }
      throw new Error("json_path_missing");
    }
    change(this.#node, 0);
    return LosslessJson.parse(pieces.join(""));
  }
}
Object.freeze(LosslessJson.prototype);
