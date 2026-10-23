import { uuidPairs } from "../packages/domain/src/owned-json.ts";
import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { LosslessJson } from "@thumble/contracts/json";
import { setOwnedControlLabel } from "@thumble/domain/owned-control-label";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
import { projectSavedController } from "@thumble/domain/saved-controller-map";
import { projectSavedPresentation } from "@thumble/domain/saved-presentation";
const profileId = "aaaaaaaa-0000-0000-0000-000000000001",
  controlId = "ce000000-0000-0000-0000-00000000000a";
const other = "bbbbbbbb-0000-0000-0000-000000000002";
const digest = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");
const change = (label: string | null) => ({ profileId, controlId, label });
function source() {
  return starterConfiguration(profileId, "Controller", "10");
}
function projection(source: LosslessJson) {
  const document = OwnedConfigurationDocument.read(source, digest);
  const projected = projectSavedController(
    { document, authorityRevision: "1" },
    { profileId, authorityRevision: "1", sourceSha256: digest(source.text()) },
    { generation: "1", revision: "1" },
    { width: 874, height: 393 },
    digest,
  );
  return {
    map: projected.map,
    label: projectSavedPresentation(
      document,
      profileId,
      "light",
      projected.map,
      digest,
    ).controls.find((c) => c.id === controlId)!.label,
  };
}
test("set, explicit blank and clear only change presentation; installed input map stays identical", () => {
  const original = source(),
    baseline = projection(original);
  const named = setOwnedControlLabel(original, change("My spell"), "11");
  const blank = setOwnedControlLabel(named, change(""), "12"),
    cleared = setOwnedControlLabel(blank, change(null), "13");
  expect(projection(named).label).toBe("My spell");
  expect(projection(blank).label).toBe("");
  expect(projection(cleared).label).toBe(baseline.label);
  for (const candidate of [named, blank, cleared]) {
    expect(JSON.stringify(projection(candidate).map)).toBe(
      JSON.stringify(baseline.map),
    );
    expect(candidate.get("/profiles/0/customization/elements")?.text()).toBe(
      original.get("/profiles/0/customization/elements")?.text(),
    );
    for (const key of original.keys)
      if (key !== "profiles")
        expect(candidate.get("/" + key)?.text()).toBe(
          original.get("/" + key)?.text(),
        );
  }
  expect(setOwnedControlLabel(named, change("My spell"), "1")).toBe(named);
  expect(setOwnedControlLabel(original, change(null), "11")).toBe(original);
});
test("lossless opaque subtrees, numeric lexemes and unrelated control/profile values survive", () => {
  const opaque =
    ' { "huge":9007199254740993, "fraction":1.2300e+04, "negativeZero":-0, "escaped":"\\u0061" } ';
  const original = source()
    .set("/opaqueRoot", opaque)
    .set("/profiles/0/opaqueProfile", opaque)
    .set("/profiles/0/customization/opaqueLayout", opaque);
  const changed = setOwnedControlLabel(original, change("🧙\nSpell"), "11");
  for (const path of [
    "/opaqueRoot",
    "/profiles/0/opaqueProfile",
    "/profiles/0/customization/opaqueLayout",
    "/profiles/0/customization/elements",
    "/profiles/0/customization/customButtons",
    "/profiles/0/appearanceBank",
  ])
    expect(changed.get(path)?.text()).toBe(original.get(path)?.text());
  expect(changed.get("/profiles/0/updatedAt")?.text()).toBe("11");
  expect(
    original.get("/profiles/0/customization/labelOverrides"),
  ).toBeUndefined();
});
for (const representation of ["object", "pairs"] as const)
  test(`case-folded UUID targeting preserves ${representation} override representation and unrelated exact values`, () => {
    const unrelated = "ce000000-0000-0000-0000-00000000000b";
    const dictionary =
      representation === "object"
        ? `{"${controlId.toUpperCase()}":"old","${unrelated}":"\\u0058"}`
        : `["${controlId.toUpperCase()}","old","${unrelated}","\\u0058"]`;
    const original = source().set(
      "/profiles/0/customization/labelOverrides",
      dictionary,
    );
    const changed = setOwnedControlLabel(
      original,
      {
        ...change("new"),
        profileId: profileId.toUpperCase(),
        controlId: controlId.toUpperCase(),
      },
      "11",
    );
    const labels = changed.get("/profiles/0/customization/labelOverrides")!;
    expect(labels.kind).toBe(representation === "object" ? "object" : "array");
    expect(labels.text()).toContain(controlId.toUpperCase());
    expect(labels.text()).toContain('"\\u0058"');
    const cleared = setOwnedControlLabel(changed, change(null), "12").get(
      "/profiles/0/customization/labelOverrides",
    )!;
    expect(cleared.kind).toBe(labels.kind);
    expect(cleared.text()).not.toContain(controlId.toUpperCase());
    expect(cleared.text()).toContain('"\\u0058"');
  });
test("append to retained UUID pairs and clear preserve explicit empty containers and null", () => {
  const original = source().set(
    "/profiles/0/customization/labelOverrides",
    "[]",
  );
  const named = setOwnedControlLabel(original, change("new"), "11");
  expect(named.get("/profiles/0/customization/labelOverrides")?.text()).toBe(
    JSON.stringify([controlId, "new"]),
  );
  expect(
    setOwnedControlLabel(named, change(null), "12")
      .get("/profiles/0/customization/labelOverrides")
      ?.text(),
  ).toBe("[]");
  const nullMap = source().set(
    "/profiles/0/customization/labelOverrides",
    "null",
  );
  expect(setOwnedControlLabel(nullMap, change(null), "11")).toBe(nullMap);
});
test("explicit profile identity never redirects an edit through active/default selection", () => {
  const original = ConfigurationCatalog.read(source()).duplicateProfile(
    profileId,
    other,
    "Second",
    "11",
    false,
  ).source;
  const candidate = setOwnedControlLabel(
    original,
    { ...change("Second spell"), profileId: other },
    "12",
  );
  expect(candidate.get("/profiles/0")?.text()).toBe(
    original.get("/profiles/0")?.text(),
  );
  expect(candidate.get("/activeProfileID")?.text()).toBe(
    original.get("/activeProfileID")?.text(),
  );
  expect(
    candidate.get(`/profiles/1/customization/labelOverrides/${controlId}`)
      ?.stringValue,
  ).toBe("Second spell");
});
test("unknown targets, ambiguous overrides and invalid clocks cannot produce candidates", () => {
  const original = source();
  expect(() =>
    setOwnedControlLabel(original, { ...change("x"), profileId: other }, "11"),
  ).toThrow("profile_not_found");
  expect(() =>
    setOwnedControlLabel(original, { ...change("x"), controlId: other }, "11"),
  ).toThrow("control_not_found");
  for (const at of ["01", "-1", "1e2", "9223372036854775808", "", "9"])
    expect(() => setOwnedControlLabel(original, change("x"), at)).toThrow();
  const duplicate = original.set(
    "/profiles/0/customization/labelOverrides",
    JSON.stringify([controlId, "x", controlId.toUpperCase(), "y"]),
  );
  expect(() => setOwnedControlLabel(duplicate, change("z"), "11")).toThrow();
});
test("externalized authority edits preserve all resources and materialize without new asset reads or descriptors", () => {
  const raw = LosslessJson.parse(
    readFileSync(
      new URL(
        "../packages/fixtures/owned-configuration-v1/document.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const prepared = OwnedAuthorityDocument.prepare(raw, digest),
    assets = new Map(prepared.assets().map((bytes) => [digest(bytes), bytes]));
  const profileId = prepared.document.catalog.profiles[0]!.id;
  const controlId = raw.get(
    "/profiles/0/customization/elements/0/id",
  )!.stringValue!;
  const candidate = setOwnedControlLabel(
    prepared.document.source,
    { profileId, controlId, label: "New label" },
    "9999999999999",
  );
  expect(candidate.get("/resources")?.text()).toBe(
    prepared.document.source.get("/resources")?.text(),
  );
  const materialized = OwnedAuthorityDocument.read(candidate).materialize(
    (hash) => assets.get(hash)!,
    digest,
  );
  expect(
    uuidPairs(
      materialized.source.get("/profiles/0/customization/labelOverrides"),
    ).get(controlId.toLowerCase())?.stringValue,
  ).toBe("New label");
  expect(
    uuidPairs(
      prepared.document.source.get(
        "/document/profiles/0/customization/labelOverrides",
      ),
    ).get(controlId.toLowerCase())?.stringValue,
  ).not.toBe("New label");
});
