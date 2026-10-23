import { expect, test } from "bun:test";
import { LosslessJson } from "@thumble/contracts/json";
import { mergeOwnedProjection } from "../packages/domain/src/owned-projection-merge.ts";
const json = LosslessJson.parse;
const merge = (source: string, before: string, after: string) =>
  mergeOwnedProjection(json(source), json(before), json(after)).text();

test("changed known values preserve opaque numeric, string and escaped-key tokens", () => {
  const source =
    ' \n{"known":1,"\\u0078":1e+03,"opaque":{"s":"\\u0061","n":9007199254740993}}\t';
  const next = merge(source, '{"known":1}', '{"known":2}');
  expect(next).toBe(
    ' \n{"known":2,"\\u0078":1e+03,"opaque":{"s":"\\u0061","n":9007199254740993}}\t',
  );
  expect(merge(source, '{"known":1}', '{"known":1}')).toBe(source);
});
test("stable identity arrays reorder known entries while retaining each entry opaque edits", () => {
  const source =
    '{"profiles":[{"id":"aaaaaaaa-0000-0000-0000-000000000001","name":"A","custom":{"v":1e2}},{"id":"bbbbbbbb-0000-0000-0000-000000000002","name":"B"}]}';
  const before =
    '{"profiles":[{"id":"aaaaaaaa-0000-0000-0000-000000000001","name":"A"},{"id":"bbbbbbbb-0000-0000-0000-000000000002","name":"B"}]}';
  const after =
    '{"profiles":[{"id":"bbbbbbbb-0000-0000-0000-000000000002","name":"B2"},{"id":"aaaaaaaa-0000-0000-0000-000000000001","name":"A"}]}';
  const result = json(merge(source, before, after));
  expect(result.get("/profiles/0/name")?.stringValue).toBe("B2");
  expect(result.get("/profiles/1/custom")?.text()).toBe('{"v":1e2}');
});
test("removing or replacing opaque contents and ambiguous UUID aliases fails closed", () => {
  expect(() =>
    merge('{"x":{"known":1,"private":2}}', '{"x":{"known":1}}', "{}"),
  ).toThrow("owned_projection_opaque_conflict");
  expect(() =>
    merge('{"x":[{"unknown":1}]}', '{"x":[{}]}', '{"x":[]}'),
  ).toThrow("owned_projection_opaque_conflict");
  expect(() =>
    merge(
      '{"AAAAAAAA-0000-0000-0000-000000000001":{}}',
      "{}",
      '{"aaaaaaaa-0000-0000-0000-000000000001":{}}',
    ),
  ).toThrow("owned_projection_opaque_conflict");
});
test("explicit empty maps remain empty and do not inherit projected defaults", () => {
  expect(
    merge(
      '{"bindings":{},"name":"old"}',
      '{"bindings":{},"name":"old"}',
      '{"bindings":{},"name":"new"}',
    ),
  ).toBe('{"bindings":{},"name":"new"}');
});
test("NFC key collisions are rejected even for a no-change projection", () => {
  expect(() => merge('{"é":1,"e\\u0301":2}', "{}", "{}")).toThrow(
    "owned_projection_invalid",
  );
});

test("wide opaque objects fail before quadratic member lookup or any edit", () => {
  const source = JSON.stringify(
    Object.fromEntries(Array.from({ length: 513 }, (_, i) => [String(i), i])),
  );
  expect(() => merge(source, "{}", "{}")).toThrow(
    "owned_projection_too_complex",
  );
});
