import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { decodeResourceBase64 } from "@thumble/domain/owned-resources";
const root = resolve(
  import.meta.dir,
  "../packages/fixtures/owned-configuration-v1",
);
const text = readFileSync(resolve(root, "document.json"), "utf8");
const digest = (bytes: Uint8Array) =>
  createHash("sha256").update(bytes).digest("hex");
const read = (source = LosslessJson.parse(text)) =>
  OwnedConfigurationDocument.read(source, digest);
const pointer = (parts: readonly (string | number)[]) =>
  parts
    .map(
      (part) => "/" + String(part).replaceAll("~", "~0").replaceAll("/", "~1"),
    )
    .join("");

test("owned v5 reader agrees with the retained cross-language admission matrix", () => {
  const matrix = LosslessJson.parse(
    readFileSync(resolve(root, "cases.json"), "utf8"),
  );
  const cases = matrix.get("/cases")!;
  for (let i = 0; i < cases.length!; i++) {
    const row = cases.get("/" + i)!,
      path = row.get("/path")!;
    const parts = Array.from({ length: path.length! }, (_, j) => {
      const node = path.get("/" + j)!;
      return node.stringValue ?? node.integerValue!;
    });
    let source = LosslessJson.parse(text);
    if (parts.length)
      source =
        row.get("/action")!.stringValue === "remove"
          ? source.remove(pointer(parts))
          : source.set(pointer(parts), row.get("/value")!.text());
    let accepted = true;
    try {
      read(source);
    } catch {
      accepted = false;
    }
    expect({ name: row.get("/name")!.stringValue, accepted }).toEqual({
      name: row.get("/name")!.stringValue,
      accepted: row.get("/allowed")!.booleanValue!,
    });
  }
});

test("owned source, all eight states, explicit identities and pooled aliases remain immutable", () => {
  const input = LosslessJson.parse(text),
    document = read(input);
  expect(document.source).toBe(input);
  expect(document.profiles.length).toBe(2);
  const profile = document.profile(
    document.catalog.profiles[0]!.id.toUpperCase(),
  );
  expect(profile.source.text()).toBe(input.get("/profiles/0")!.text());
  expect(profile.appearanceStates).toEqual([
    "dark/base",
    "dark/both-triggers",
    "dark/left-trigger",
    "dark/right-trigger",
    "light/base",
    "light/both-triggers",
    "light/left-trigger",
    "light/right-trigger",
  ]);
  expect(profile.elements[0]!.id).toBe("00000000-0000-0000-0000-000000000109");
  expect(profile.resources!.count).toBe(2);
  const reference = profile.source.get(
    "/appearanceBank/variants/0/appearance/assetLibrary/assets/0/data",
  )!;
  const first = profile.resources!.data(reference),
    expected = first.slice();
  first.fill(0);
  expect(profile.resources!.data(reference)).toEqual(expected);
  expect(Object.isFrozen(document)).toBe(true);
  expect(Object.isFrozen(profile)).toBe(true);
  expect(Object.isFrozen(profile.elements)).toBe(true);
  expect(Object.isFrozen(profile.elements[0])).toBe(true);
  expect(Object.isFrozen(profile.appearanceStates)).toBe(true);
  const huge = input
    .set("/futureRootMetadata/largeInteger", "18446744073709551616")
    .set("/futureRootMetadata/fraction", "1.0000000000000000000001");
  expect(read(huge).source.text()).toBe(huge.text());
  expect(() =>
    document.profile("ffffffff-0000-0000-0000-000000000000"),
  ).toThrow("profile_not_found");
});

test("resource admission rejects corrupt digests, noncanonical Base64 and dangling or ambiguous references", () => {
  const source = LosslessJson.parse(text),
    resources = source.get("/profiles/0/appearanceResources")!,
    key = resources.keys[0]!;
  const reference = source.get(
    "/profiles/0/appearanceBank/variants/0/appearance/assetLibrary/assets/0/data",
  )!;
  for (const bad of [
    source.set("/profiles/0/appearanceResources/" + key, '"YQ=="'),
    source.set("/profiles/0/appearanceResources/" + key, '"YR=="'),
    source.set(
      "/profiles/0/futureReference",
      '{"resourceSHA256":"' + "0".repeat(64) + '"}',
    ),
    source.set(
      "/profiles/0/futureReference",
      reference.set("/extra", "true").text(),
    ),
    source.set("/profiles/1/futureReference", reference.text()),
    source
      .set("/profiles/1/appearanceResources", "{}")
      .set("/profiles/1/appearanceResourceVersion", "1"),
  ])
    expect(() => read(bad)).toThrow();
  // An injected implementation cannot retain/mutate the private validated bytes.
  const held: Uint8Array[] = [];
  const document = OwnedConfigurationDocument.read(source, (bytes) => {
    held.push(bytes);
    return digest(bytes);
  });
  held.forEach((bytes) => bytes.fill(0));
  expect(
    document.profiles[0]!.resources!.data(reference).some(
      (value) => value !== 0,
    ),
  ).toBe(true);
});

test("Base64 decoding is exact and remains bounded on large inputs", () => {
  for (const value of ["", "YQ==", "YWI=", "YWJj", "+/8="])
    expect(decodeResourceBase64(value)).toEqual(
      new Uint8Array(Buffer.from(value, "base64")),
    );
  for (const value of [
    "YQ",
    "YQ=",
    "YQ===",
    "YR==",
    "YWJ=",
    "YQ==\n",
    " YQ==",
    "Y-Q=",
    "AA=A",
    "=AAA",
    "====",
  ])
    expect(() => decodeResourceBase64(value)).toThrow(
      "invalid_owned_configuration",
    );
  const bytes = Buffer.alloc(1024 * 1024, 0xa5);
  expect(decodeResourceBase64(bytes.toString("base64"))).toEqual(
    new Uint8Array(bytes),
  );
  expect(() => decodeResourceBase64("A".repeat(12 * 1024 * 1024))).toThrow(
    "invalid_owned_configuration",
  );
});

test("binding and design references must belong to declared controls and canonical profiles", () => {
  const source = LosslessJson.parse(text),
    id = source.get("/profiles/0/id")!.stringValue!,
    element = source.get(
      "/profiles/0/customization/elements/0/id",
    )!.stringValue!;
  const alias = source.get(
    "/profiles/1/customization/elements/6/id",
  )!.stringValue!;
  const binding = source.get("/keyBindings/" + element)!.text();
  for (const bad of [
    source.set("/keyBindings/ffffffff-0000-0000-0000-000000000000", binding),
    source.set(
      "/profileKeyBindings/" + id.toLowerCase(),
      source.get("/profileKeyBindings/" + id)!.text(),
    ),
    source
      .set("/activeProfileID", source.get("/profiles/1/id")!.text())
      .set("/keyBindings/" + alias.toLowerCase(), binding)
      .set("/keyBindings/" + alias.toUpperCase(), binding),
    source.set("/keyBindings/" + element + "/keyCode", "65536"),
    source.set("/keyBindings/" + element + "/modifiers", "1"),
    source.set(
      "/keyBindings/" + element + "/sequence",
      "[" + Array(33).fill(binding).join(",") + "]",
    ),
    source.set(
      "/profiles/1/customization/designMetadata/layerOrder",
      '["custom.ffffffff-0000-0000-0000-000000000000"]',
    ),
    source.set(
      "/profiles/1/customization/designMetadata/groups",
      '[{"id":"' +
        element +
        '","children":["custom.ffffffff-0000-0000-0000-000000000000"]}]',
    ),
    source.set(
      "/profiles/0/customization/elements/0/partOutputs",
      '["primary",{},"primary",{}]',
    ),
    source.set(
      "/profiles/0/customization/elements/0/presentation",
      '{"schemaVersion":1,"groupIDs":["same","same"]}',
    ),
  ])
    expect(() => read(bad)).toThrow();
});

test("paint banks reject mismatched identities, undeclared assets and invalid canonical owner shapes", () => {
  const source = LosslessJson.parse(text),
    p = "/profiles/0/appearanceBank/variants/0/appearance";
  for (const bad of [
    source.set(p + "/controls/ffffffff-0000-0000-0000-000000000000", "{}"),
    source.set(p + "/topBar/unrecognizedGeometry", "1"),
    source
      .set(p + "/assetLibrary/assets", "[]")
      .remove(p + "/backgroundFillStyle/image/data"),
    source.set(p + "/controlBar/not-a-control", "{}"),
    source.set(p + "/accentStyle", '"unsupported"'),
    source.set(p + "/showsButtonLabels", '"true"'),
    source.set(
      "/profiles/0/appearanceBank/variants/0/actionSet",
      '"right-trigger"',
    ),
  ])
    expect(() => read(bad)).toThrow();
});

test("frozen retained document and matrix bytes match their recorded manifest", () => {
  const manifest = JSON.parse(
    readFileSync(resolve(root, "manifest.json"), "utf8"),
  );
  expect(manifest.caseCount).toBe(41);
  for (const [name, expected] of Object.entries(manifest.files))
    expect(digest(readFileSync(resolve(root, name)))).toBe(expected as string);
});

test("typed element projections preserve explicit output semantics and immutable presentation", () => {
  let source = LosslessJson.parse(text).set(
    "/profiles/0/customization/elements/0/presentation",
    '{"schemaVersion":1,"groupIDs":["action-bar"],"accessibilityName":"Coin"}',
  );
  const profile = read(source).profiles[0]!,
    element = profile.elements[0]!;
  expect(element.kind).toBe("button");
  expect(element.output).toEqual({
    keyboard: { keyCode: 48, modifiers: 0, sequence: null },
    gamepadButtons: ["select"],
  });
  expect(element.defaultOutput).toEqual(element.output);
  expect(element.presentation?.accessibilityName).toBe("Coin");
  expect(Object.isFrozen(element.presentation?.groupIDs)).toBe(true);
  expect(Object.isFrozen(element.output)).toBe(true);
  expect(Object.isFrozen(element.output?.keyboard)).toBe(true);
  expect(Object.isFrozen(element.output?.gamepadButtons)).toBe(true);
  source = source.set(
    "/profiles/0/customization/elements/0/output/gamepadButtons",
    '["future-button"]',
  );
  expect(read(source).profiles[0]!.elements[0]!.output?.gamepadButtons).toEqual(
    ["future-button"],
  );
});

test("native mirror settings, kind limits and missing joystick outputs cannot become a conflicting projection", () => {
  const source = LosslessJson.parse(text),
    mirror = "/profiles/1/customization/customButtons/0";
  for (const bad of [
    source.set(mirror + "/joystickOutputSettings/sensitivity", "2"),
    source.set(mirror + "/controlKind", '"button"'),
    source.remove(mirror + "/joystickMapping/up"),
    source.set(mirror + "/joystickMapping/up", "{}"),
    source.set(
      "/profiles/1/customization/elements/6/joystickOutputSettings/snapToCardinal",
      "true",
    ),
  ])
    expect(() => read(bad)).toThrow();
  const elements = source.get("/profiles/1/customization/elements")!;
  const joystick = elements.get("/6")!;
  const two = source.set(
    "/profiles/1/customization/elements/-",
    joystick.set("/id", '"ffffffff-0000-0000-0000-000000000001"').text(),
  );
  expect(
    read(two).profiles[1]!.elements.filter((e) => e.kind === "joystick").length,
  ).toBe(2);
  const three = two.set(
    "/profiles/1/customization/elements/-",
    joystick.set("/id", '"ffffffff-0000-0000-0000-000000000002"').text(),
  );
  expect(() => read(three)).toThrow();
  // Normalized comparison is read-only; raw clamped values retain their spelling.
  const equal = source
    .set(mirror + "/joystickOutputSettings/deadZone", "3")
    .set(
      "/profiles/1/customization/elements/6/joystickOutputSettings/deadZone",
      "5",
    );
  expect(read(equal).source.text()).toBe(equal.text());
});
