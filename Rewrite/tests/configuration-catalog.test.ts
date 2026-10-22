import { expect, test } from "bun:test";
import { LosslessJson } from "@thumble/contracts/json";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
const a = "AAAAAAAA-0000-0000-0000-000000000001";
const b = "bbbbbbbb-0000-0000-0000-000000000002";
function source(): LosslessJson {
  return LosslessJson.parse(`{
    "schema":"com.codybontecou.pocketpad.keypad-configuration","version":5,
    "activeProfileID":"${b}","defaultProfileID":null,
    "opaque": { "huge": 99999999999999999999999999999, "exponent": 1e9999 },
    "profiles":[
      {"id":"${a}","profileFormatVersion":5,"name":"First","updatedAt":9223372036854775806,"customization":{"opaque":true},"extension":{"number":-0.0000}},
      {"id":"${b}","profileFormatVersion":5,"name":"Second","updatedAt":0}
    ]
  }`);
}
test("catalog projects case-insensitive stable IDs and exact Int64 timestamps without replacing source", () => {
  const input = source(),
    catalog = ConfigurationCatalog.read(input);
  expect(catalog.source).toBe(input);
  expect(catalog.profiles[0]).toEqual({
    id: a.toLowerCase(),
    name: "First",
    updatedAt: "9223372036854775806",
  });
  expect(catalog.activeProfileID).toBe(b);
  expect(catalog.defaultProfileID).toBeNull();
  expect(Object.isFrozen(catalog.profiles)).toBe(true);
  expect(Object.isFrozen(catalog.profiles[0])).toBe(true);
});
test("rename targets the explicit profile even when another profile is active and preserves opaque subtrees", () => {
  const input = source(),
    catalog = ConfigurationCatalog.read(input);
  const changed = catalog.renameProfile(
    a.toLowerCase(),
    "Renamed 🦊",
    "9223372036854775807",
  );
  expect(changed.profiles[0]?.name).toBe("Renamed 🦊");
  expect(changed.profiles[1]).toEqual(catalog.profiles[1]!);
  for (const path of [
    "/opaque",
    "/profiles/0/customization",
    "/profiles/0/extension",
    "/profiles/1",
    "/activeProfileID",
    "/defaultProfileID",
  ])
    expect(changed.source.get(path)?.text()).toBe(input.get(path)?.text());
  expect(catalog.profiles[0]?.name).toBe("First");
  expect(changed.profiles[0]?.updatedAt).toBe("9223372036854775807");
  expect(catalog.renameProfile(a, "First", "9223372036854775807")).toBe(
    catalog,
  );
});
test("catalog refuses missing, duplicate and dangling profile identities and selection aliases", () => {
  const input = source();
  for (const bad of [
    input.remove("/defaultProfileID"),
    input.set("/activeProfileID", JSON.stringify(a.slice(1))),
    input.set(
      "/defaultProfileID",
      JSON.stringify("cccccccc-0000-0000-0000-000000000003"),
    ),
    input.set("/profiles/1/id", JSON.stringify(a.toLowerCase())),
    input.set("/profiles", "[]"),
    input.set("/Active_Profile_ID", JSON.stringify(a)),
    input.set("/profiles/0/Name", '"alias"'),
  ])
    expect(() => ConfigurationCatalog.read(bad)).toThrow(
      "invalid_configuration_catalog",
    );
});
test("catalog blocks credentials, server authority fields and retired profile aliases", () => {
  for (const key of [
    "serverID",
    "TRUSTED_clients",
    "auth-token",
    "artifactVersion",
    "contentHash",
    "catalogRevision",
  ])
    expect(() =>
      ConfigurationCatalog.read(source().set(`/${key}`, "null")),
    ).toThrow();
  for (const key of [
    "skinReference",
    "Skin_Baseline_Customization",
    "orientationPreference",
    "portraitCustomization",
  ])
    expect(() =>
      ConfigurationCatalog.read(source().set(`/profiles/0/${key}`, "null")),
    ).toThrow();
});
test("catalog timestamps reject rounded fractions and overflow while accepting exact integer spellings", () => {
  for (const token of [
    "9223372036854775808",
    "9007199254740992.1",
    "-1",
    "1e9999",
    "0.01",
    "true",
    "null",
    '"12"',
  ])
    expect(() =>
      ConfigurationCatalog.read(source().set("/profiles/0/updatedAt", token)),
    ).toThrow();
  for (const [token, expected] of [
    ["92233720368547758070e-1", "9223372036854775807"],
    ["12.000e2", "1200"],
    ["-0e9999999", "0"],
    ["1e+0000000000000000001", "10"],
  ])
    expect(
      ConfigurationCatalog.read(source().set("/profiles/0/updatedAt", token!))
        .profiles[0]?.updatedAt,
    ).toBe(expected!);
});
test("rename rejects unknown identity, blank/oversized names, timestamp regression and noncanonical clocks", () => {
  const catalog = ConfigurationCatalog.read(source());
  expect(() =>
    catalog.renameProfile(
      "cccccccc-0000-0000-0000-000000000003",
      "Changed",
      "0",
    ),
  ).toThrow("profile_not_found");
  expect(() => catalog.renameProfile(a, "Changed", "0")).toThrow(
    "profile_timestamp_regression",
  );
  for (const value of ["", " \n\t", "🦊".repeat(257), "\ud800"])
    expect(() =>
      catalog.renameProfile(a, value, "9223372036854775807"),
    ).toThrow();
  for (const value of ["01", "1e3", "1.0", "9223372036854775808", "-0"])
    expect(() => catalog.renameProfile(a, "Changed", value)).toThrow();
  expect(
    catalog.renameProfile(a, "🦊".repeat(256), "9223372036854775807")
      .profiles[0]?.name,
  ).toBe("🦊".repeat(256));
});
