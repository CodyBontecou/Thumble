import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { LosslessJson } from "@thumble/contracts/json";
import { deleteOwnedProfile } from "@thumble/domain/owned-profile-delete";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { projectSavedController } from "@thumble/domain/saved-controller-map";
const a = "aaaaaaaa-0000-0000-0000-000000000001",
  b = "bbbbbbbb-0000-0000-0000-000000000002",
  c = "cccccccc-0000-0000-0000-000000000003",
  missing = "dddddddd-0000-0000-0000-000000000004";
const digest = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");
const change = (
  profileId: string,
  activeProfileId = a,
  defaultProfileId: string | null = a,
) => ({ profileId, activeProfileId, defaultProfileId });
function source() {
  return ConfigurationCatalog.read(starterConfiguration(a, "First", "10"))
    .duplicateProfile(a, b, "Second", "11", false)
    .duplicateProfile(a, c, "Third", "12", false).source;
}
function map(source: LosslessJson, profileId: string) {
  return projectSavedController(
    {
      document: OwnedConfigurationDocument.read(source, digest),
      authorityRevision: "1",
    },
    { profileId, authorityRevision: "1", sourceSha256: digest(source.text()) },
    { generation: "1", revision: "1" },
    { width: 874, height: 393 },
    digest,
  ).map;
}
test("inactive deletion removes only target, its binding maps and preserves installed profile geometry", () => {
  const original = source();
  const result = deleteOwnedProfile(original, change(b));
  expect(ConfigurationCatalog.read(result).profiles.map((p) => p.id)).toEqual([
    a,
    c,
  ]);
  expect(result.get("/profiles/0")?.text()).toBe(
    original.get("/profiles/0")?.text(),
  );
  expect(result.get("/profiles/1")?.text()).toBe(
    original.get("/profiles/2")?.text(),
  );
  for (const name of ["profileKeyBindings", "profileOutputBindings"]) {
    expect(result.get(`/${name}/${b}`)).toBeUndefined();
    expect(result.get(`/${name}/${a}`)?.text()).toBe(
      original.get(`/${name}/${a}`)?.text(),
    );
    expect(result.get(`/${name}/${c}`)?.text()).toBe(
      original.get(`/${name}/${c}`)?.text(),
    );
  }
  for (const name of [
    "keyBindings",
    "outputBindings",
    "activeProfileID",
    "defaultProfileID",
  ])
    expect(result.get("/" + name)?.text()).toBe(
      original.get("/" + name)?.text(),
    );
  expect(map(result, a)).toEqual(map(original, a));
});
test("deleting selected/default profile uses only explicit survivors and retains explicit empty maps", () => {
  const original = source()
    .set(`/profileOutputBindings/${b}`, "{}")
    .set(`/profileKeyBindings/${b}`, "{}");
  const result = deleteOwnedProfile(original, change(a, b, null));
  const catalog = ConfigurationCatalog.read(result);
  expect(catalog.activeProfileID).toBe(b);
  expect(catalog.defaultProfileID).toBeNull();
  expect(result.get("/outputBindings")?.text()).toBe("{}");
  expect(result.get("/keyBindings")?.text()).toBe("{}");
  expect(result.get("/profiles/0")?.text()).toBe(
    original.get("/profiles/1")?.text(),
  );
  expect(() => map(result, a)).toThrow();
});
test("replacement missing maps install initial outputs independently without borrowing old root", () => {
  const original = source()
    .remove(`/profileOutputBindings/${b}`)
    .set(`/profileKeyBindings/${b}`, "{}");
  const result = deleteOwnedProfile(original, change(a, b, c));
  expect(result.get("/keyBindings")?.text()).toBe("{}");
  expect(result.get("/outputBindings")?.text()).not.toBe("{}");
  expect(result.get("/outputBindings")?.text()).toBe(
    result.get(`/profileOutputBindings/${b}`)?.text(),
  );
  expect(ConfigurationCatalog.read(result).defaultProfileID).toBe(c);
});
test("case-folded targets remove case variants without changing surviving opaque or numeric bytes", () => {
  const opaque =
    ' {"huge":9007199254740993,"fraction":1.2300e+04,"negativeZero":-0,"escaped":"\\u0061"} ';
  let original = source()
    .set("/opaqueRoot", opaque)
    .set("/profiles/0/opaqueProfile", opaque)
    .set("/profiles/2/opaqueProfile", opaque)
    .set(
      "/profiles/1/wowLive",
      '{"characterID":"synthetic-character","flavor":"retail"}',
    );
  for (const name of ["profileKeyBindings", "profileOutputBindings"]) {
    const value = original.get(`/${name}/${b}`)!.text();
    original = original
      .remove(`/${name}/${b}`)
      .set(`/${name}/${b.toUpperCase()}`, value);
  }
  const result = deleteOwnedProfile(original, {
    profileId: b.toUpperCase(),
    activeProfileId: a.toUpperCase(),
    defaultProfileId: a.toUpperCase(),
  });
  expect(result.get("/opaqueRoot")?.text()).toBe(
    original.get("/opaqueRoot")?.text(),
  );
  expect(result.get("/profiles/0")?.text()).toBe(
    original.get("/profiles/0")?.text(),
  );
  expect(result.get("/profiles/1")?.text()).toBe(
    original.get("/profiles/2")?.text(),
  );
  for (const name of ["profileKeyBindings", "profileOutputBindings"])
    expect(result.get(`/${name}/${b.toUpperCase()}`)).toBeUndefined();
});
test("last profile, missing targets and deleted/missing replacement selections reject without a candidate", () => {
  expect(() =>
    deleteOwnedProfile(
      starterConfiguration(a, "First", "1"),
      change(a, b, null),
    ),
  ).toThrow("configuration_last_profile");
  const original = source(),
    before = original.text();
  for (const edit of [
    change(missing),
    change(b, missing, null),
    change(b, a, missing),
  ])
    expect(() => deleteOwnedProfile(original, edit)).toThrow(
      "profile_not_found",
    );
  for (const edit of [change(b, b, null), change(b, a, b)])
    expect(() => deleteOwnedProfile(original, edit)).toThrow(
      "invalid_profile_selection",
    );
  expect(original.text()).toBe(before);
});
test("invalid binding ownership and duplicate-case maps cannot be silently removed", () => {
  const original = source();
  const invalid = original.set(
    `/profileOutputBindings/${b}`,
    `{"${missing}":{}}`,
  );
  expect(() => deleteOwnedProfile(invalid, change(b))).toThrow();
  const duplicate = original.set(
    `/profileOutputBindings/${b.toUpperCase()}`,
    "{}",
  );
  expect(() => deleteOwnedProfile(duplicate, change(b))).toThrow();
});
test("stored resource slots drop target and reindex survivors without altering hashes or numeric lexemes", () => {
  const fixture = LosslessJson.parse(
    readFileSync(
      new URL(
        "../packages/fixtures/owned-configuration-v1/document.json",
        import.meta.url,
      ),
      "utf8",
    ),
  );
  const prepared = OwnedAuthorityDocument.prepare(fixture, digest),
    first = prepared.document.catalog.profiles[0]!.id;
  let authority = prepared.document
    .duplicateProfile(first, b, "Second", "2000000000000", false)
    .duplicateProfile(first, c, "Third", "2000000000001", false);
  const row0 = authority.source.get("/resources/0/byteCount")!.integerValue!;
  const original = authority.source.set(
    "/resources/0/byteCount",
    `${row0}.00e+0`,
  );
  const removedIndex = authority.catalog.profiles.findIndex((p) => p.id === b);
  const result = deleteOwnedProfile(original, change(b, first, null));
  const decoded = OwnedAuthorityDocument.read(result);
  expect(decoded.catalog.profiles.map((p) => p.id)).toEqual(
    authority.catalog.profiles.filter((p) => p.id !== b).map((p) => p.id),
  );
  const resources = original.get("/resources")!;
  let deleted = 0,
    kept = 0;
  for (let i = 0; i < resources.length!; i++) {
    const row = resources.get("/" + i)!,
      path = row.get("/path")!.stringValue!;
    const match = /^\/profiles\/(\d+)\//.exec(path)!;
    const at = Number(match[1]);
    if (at === removedIndex) {
      deleted++;
      continue;
    }
    const next =
      at > removedIndex
        ? `/profiles/${at - 1}/` + path.slice(match[0].length)
        : path;
    const found = decoded.resources.find((r) => r.path === next)!;
    expect(found.sha256).toBe(row.get("/sha256")!.stringValue!);
    expect(found.byteCount).toBe(row.get("/byteCount")!.integerValue!);
    const record = Array.from(
      { length: result.get("/resources")!.length! },
      (_, n) => result.get("/resources/" + n)!,
    ).find((r) => r.get("/path")!.stringValue === next)!;
    expect(record.get("/byteCount")?.text()).toBe(
      row.get("/byteCount")?.text(),
    );
    kept++;
  }
  expect(deleted).toBeGreaterThan(0);
  expect(decoded.resources.length).toBe(kept);
  expect(result.get("/document/profiles/0")?.text()).toBe(
    original.get("/document/profiles/0")?.text(),
  );
  expect(result.get(`/document/profiles/${removedIndex}`)?.text()).toBe(
    original.get(`/document/profiles/${removedIndex + 1}`)?.text(),
  );
  const assets = new Map(prepared.assets().map((raw) => [digest(raw), raw]));
  expect(
    decoded.materialize((hash) => assets.get(hash)!, digest).catalog.profiles
      .length,
  ).toBe(authority.catalog.profiles.length - 1);
  const withoutFirst = OwnedAuthorityDocument.read(
    deleteOwnedProfile(original, change(first, b, null)),
  );
  expect(withoutFirst.catalog.activeProfileID).toBe(b);
  expect(withoutFirst.source.get("/document/profiles/0")?.text()).toBe(
    original.get("/document/profiles/1")?.text(),
  );
  expect(
    withoutFirst.materialize((hash) => assets.get(hash)!, digest).catalog
      .profiles.length,
  ).toBe(authority.catalog.profiles.length - 1);
});
