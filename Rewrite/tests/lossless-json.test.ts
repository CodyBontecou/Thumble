import { expect, test } from "bun:test";
import { LosslessJson, LOSSLESS_JSON_LIMITS } from "@thumble/contracts/json";

test("scoped source edits preserve raw full-width numbers, escaped strings and opaque subtrees", () => {
  const opaque =
    '{ "unsigned":18446744073709551615, "exponent":1.2300e+9999, "minusZero":-0, "escaped":"\\u0061" }';
  const text = ` \n{"profiles":[{"id":"profile-a","name":"Before","unknown":${opaque}}],"extension":${opaque}}\t`;
  const source = LosslessJson.parse(text);
  const changed = source.set("/profiles/0/name", '"After"');
  expect(source.text()).toBe(text);
  expect(changed.get("/profiles/0/name")?.stringValue).toBe("After");
  expect(changed.get("/profiles/0/unknown")?.text()).toBe(opaque);
  expect(changed.get("/extension")?.text()).toBe(opaque);
  expect(changed.get("/extension/unsigned")?.numberToken).toBe(
    "18446744073709551615",
  );
  expect(changed.get("/extension/unsigned")?.integerValue).toBeUndefined();
  expect(changed.get("/extension/escaped")?.stringValue).toBe("a");
});

test("safe integer projections use decimal mathematics instead of rounded doubles", () => {
  for (const [raw, expected] of [
    ["1.000", 1],
    ["100e-2", 1],
    ["0.0000001e7", 1],
    ["1e000000000001", 10],
    ["9.007199254740991e15", Number.MAX_SAFE_INTEGER],
    ["-9007199254740991", Number.MIN_SAFE_INTEGER],
    ["-0", 0],
    ["0e999999999999999999", 0],
  ] as const)
    expect(LosslessJson.parse(raw).integerValue).toBe(expected);
  for (const raw of [
    "9007199254740991.1",
    "9007199254740992",
    "-9007199254740992",
    "1e9999999999999",
    "1e-9999999",
    "1.01",
    "0.0001",
  ])
    expect(LosslessJson.parse(raw).integerValue).toBeUndefined();
});

test("canonical source hashing representation is stable without claiming RFC 8785", () => {
  const a = LosslessJson.parse(
    '{"z":18446744073709551615,"\\u0061":[1.00,{"b":false,"a":null}]}',
  );
  const b = LosslessJson.parse(
    ' { "a" : [1.00, { "a":null, "b":false }], "z":18446744073709551615 } ',
  );
  expect(a.canonicalText()).toBe(
    '{"a":[1.00,{"a":null,"b":false}],"z":18446744073709551615}',
  );
  expect(b.canonicalText()).toBe(a.canonicalText());
  expect(a.canonicalText()).not.toBe(a.set("/a/0", "1").canonicalText());
  expect(LosslessJson.canonicalization).toBe("thumble-lossless-json-v1");
});

test("JSON pointers edit object data and arrays without prototype mutation or profile redirection", () => {
  const source = LosslessJson.parse(
    '{"profiles":[{"id":"a"},{"id":"b"}],"a/b":{"~key":1},"__proto__":{"safe":true}}',
  );
  const changed = source
    .set("/a~1b/~0key", "2")
    .set("/profiles/-", '{"id":"c"}')
    .remove("/profiles/0");
  expect(changed.get("/profiles/0/id")?.stringValue).toBe("b");
  expect(changed.get("/profiles/1/id")?.stringValue).toBe("c");
  expect(changed.get("/a~1b/~0key")?.integerValue).toBe(2);
  expect(changed.get("/__proto__/safe")?.booleanValue).toBe(true);
  expect(changed.get("/profiles/9999")).toBeUndefined();
  expect(changed.get("/profiles/01")).toBeUndefined();
  expect(() => changed.set("/missing/child", "0")).toThrow("json_path_missing");
  expect(() => changed.set("/profiles/2", "0")).toThrow("json_path_missing");
  expect(() => changed.remove("")).toThrow("json_root_removal_forbidden");
  expect(() => changed.get("/bad~2")).toThrow("invalid_json_pointer");
  expect(() => changed.get("profiles")).toThrow("invalid_json_pointer");
  expect(Object.isFrozen(changed)).toBe(true);
  expect(Object.isFrozen(changed.keys)).toBe(true);
});

test("duplicate decoded keys, malformed grammar, non-JSON whitespace and invalid Unicode fail", () => {
  for (const text of [
    '{"a":1,"\\u0061":2}',
    '{"outer":{"a":1,"a":2}}',
    "[1,]",
    '{"a":1,}',
    "01",
    "1.",
    "1e",
    "+1",
    "NaN",
    "Infinity",
    "true false",
    "\ufeff{}",
    "\u00a0{}",
    '"\\ud800"',
    '"\\udc00"',
    '"\ud800"',
    '"\\x00"',
    '"\\u012"',
  ])
    expect(() => LosslessJson.parse(text)).toThrow();
  expect(LosslessJson.parse('"\\ud83d\\ude00"').stringValue).toBe("😀");
  expect(LosslessJson.parse('"😀"').stringValue).toBe("😀");
  for (let code = 0; code < 256; code++) {
    const value = String.fromCharCode(code) + '"\\/😀';
    const encoded = JSON.stringify(value);
    expect(LosslessJson.parse(encoded).stringValue).toBe(value);
    expect(LosslessJson.parse(encoded).canonicalText()).toBe(encoded);
  }
  let accessed = false;
  const hostile = {
    get length() {
      accessed = true;
      throw new Error("getter_executed");
    },
  };
  expect(() => Reflect.apply(LosslessJson.parse, null, [hostile])).toThrow();
  expect(accessed).toBe(false);
});

test("byte, graph and depth limits apply again to composed edits", () => {
  const depth = LOSSLESS_JSON_LIMITS.depth;
  expect(
    LosslessJson.parse("[".repeat(depth) + "0" + "]".repeat(depth)).kind,
  ).toBe("array");
  expect(() =>
    LosslessJson.parse("[".repeat(depth + 1) + "0" + "]".repeat(depth + 1)),
  ).toThrow();
  const nested = LosslessJson.parse(
    '{"a":' + "[".repeat(depth - 1) + "0" + "]".repeat(depth - 1) + "}",
  );
  expect(() =>
    nested.set("/a", "[".repeat(depth) + "0" + "]".repeat(depth)),
  ).toThrow();
  expect(() =>
    LosslessJson.parse(
      "[" + "0,".repeat(LOSSLESS_JSON_LIMITS.nodes - 1) + "0]",
    ),
  ).toThrow();
  const limit = LOSSLESS_JSON_LIMITS.bytes;
  const large = LosslessJson.parse('"' + "a".repeat(limit - 2) + '"');
  expect(large.text().length).toBe(limit);
  expect(large.canonicalText().length).toBe(limit);
  expect(() => LosslessJson.parse('"' + "é".repeat(limit / 2) + '"')).toThrow();
  expect(() => LosslessJson.parse("{}").set("/large", large.text())).toThrow();
});

test("batch replacements are atomic, nonoverlapping and preserve untouched opaque spans", () => {
  const opaque =
    '{ "huge":18446744073709551615,"decimal":-0.00,"key":"\\u0061" }';
  const source = LosslessJson.parse(
    `{"profiles":[{"name":"a","opaque":${opaque}},{"name":"b"}],"a/b":{"~key":0}}`,
  );
  const edits = new Map([
    ["/profiles/0/name", LosslessJson.parse('"A"')],
    ["/profiles/1/name", LosslessJson.parse('"B"')],
    ["/a~1b/~0key", LosslessJson.parse("9")],
  ]);
  const changed = source.replaceValues(edits);
  expect(changed.get("/profiles/0/name")?.stringValue).toBe("A");
  expect(changed.get("/profiles/1/name")?.stringValue).toBe("B");
  expect(changed.get("/a~1b/~0key")?.integerValue).toBe(9);
  expect(changed.get("/profiles/0/opaque")?.text()).toBe(opaque);
  expect(source.get("/profiles/0/name")?.stringValue).toBe("a");
  expect(source.replaceValues(new Map())).toBe(source);
  const protectedMap = new Map([
    ["/profiles/0/name", LosslessJson.parse('"C"')],
  ]);
  Object.defineProperty(protectedMap, "size", {
    get() {
      throw new Error("map_getter_executed");
    },
  });
  Object.defineProperty(protectedMap, "entries", {
    get() {
      throw new Error("map_getter_executed");
    },
  });
  expect(
    source.replaceValues(protectedMap).get("/profiles/0/name")?.stringValue,
  ).toBe("C");
  expect(LosslessJson.parse('{"k":"é🦊"}').byteLength).toBe(14);
  for (const paths of [
    ["/profiles", "/profiles/0"],
    ["/profiles/0", "/profiles"],
    ["", "/profiles"],
    ["/profiles", ""],
  ])
    expect(() =>
      source.replaceValues(
        new Map(paths.map((path) => [path, LosslessJson.parse("null")])),
      ),
    ).toThrow("json_replacements_overlap");
  for (const path of [
    "/missing",
    "/profiles/01",
    "/profiles/-",
    "/profiles/2",
    "/profiles/0/name/child",
  ])
    expect(() =>
      source.replaceValues(new Map([[path, LosslessJson.parse("null")]])),
    ).toThrow("json_path_missing");
  expect(source.get("/profiles/1/name")?.stringValue).toBe("b");
  expect(
    source.replaceValues(new Map([["", LosslessJson.parse("true")]]))
      .booleanValue,
  ).toBe(true);
});

test("batch replacements recheck composed size, graph and depth before returning", () => {
  const source = LosslessJson.parse('{"a":0,"b":0}');
  const huge = LosslessJson.parse(
    JSON.stringify("x".repeat(LOSSLESS_JSON_LIMITS.bytes / 2)),
  );
  expect(() =>
    source.replaceValues(
      new Map([
        ["/a", huge],
        ["/b", huge],
      ]),
    ),
  ).toThrow("configuration_json_too_large");
  const nested = LosslessJson.parse(
    "[".repeat(LOSSLESS_JSON_LIMITS.depth) +
      "0" +
      "]".repeat(LOSSLESS_JSON_LIMITS.depth),
  );
  expect(() => source.replaceValues(new Map([["/a", nested]]))).toThrow();
  const many = LosslessJson.parse("[" + "0,".repeat(70000) + "0]");
  expect(() =>
    source.replaceValues(
      new Map([
        ["/a", many],
        ["/b", many],
      ]),
    ),
  ).toThrow();
  expect(() =>
    source.replaceValues(
      new Map(
        Array.from({ length: 8193 }, (_, i) => [
          "/" + i,
          LosslessJson.parse("0"),
        ]),
      ),
    ),
  ).toThrow("json_replacements_invalid");
});
