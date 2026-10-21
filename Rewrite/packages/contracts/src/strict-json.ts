/** Bounded value parser for the local runtime seam, not a lossless profile codec. */
export function parseStrictJson(text: string): unknown {
  let index = 0;
  let nodes = 0;
  const error = (): never => {
    throw new Error("invalid_json_frame");
  };
  const space = (): void => {
    while (/\s/.test(text[index] ?? "") && index < text.length) index++;
  };
  const string = (): string => {
    const match =
      /"(?:[^"\\\u0000-\u001f]|\\(?:["\\/bfnrt]|u[0-9a-fA-F]{4}))*"/y;
    match.lastIndex = index;
    const value = match.exec(text)?.[0];
    if (!value) return error();
    index += value.length;
    return JSON.parse(value) as string;
  };
  const value = (depth: number): void => {
    if (depth > 16 || ++nodes > 4096) error();
    space();
    if (text[index] === "{") {
      index++;
      space();
      const keys = new Set<string>();
      if (text[index] !== "}")
        for (;;) {
          space();
          const key = string();
          if (keys.has(key)) error();
          keys.add(key);
          space();
          if (text[index++] !== ":") error();
          value(depth + 1);
          space();
          if (text[index] !== ",") break;
          index++;
        }
      if (text[index++] !== "}") error();
    } else if (text[index] === "[") {
      index++;
      space();
      if (text[index] !== "]")
        for (;;) {
          value(depth + 1);
          space();
          if (text[index] !== ",") break;
          index++;
        }
      if (text[index++] !== "]") error();
    } else if (text[index] === '"') {
      string();
    } else {
      const match =
        /(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/y;
      match.lastIndex = index;
      const token = match.exec(text)?.[0];
      if (!token) error();
      else index += token.length;
    }
  };
  value(0);
  space();
  if (index !== text.length) error();
  return JSON.parse(text) as unknown;
}
