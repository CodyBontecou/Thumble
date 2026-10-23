import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import type { PhonePresentationCommand } from "@thumble/contracts/phone-presentation";
import type {
  ConfigurationSource,
  ConfigurationRepository,
} from "@thumble/application/configuration-store";
import { ConfigurationPhoneControlsOperations } from "@thumble/application/configuration-phone-controls";
import { ConfigurationPhonePresentationOperations } from "@thumble/application/configuration-phone-presentation";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { configurationSourceHash } from "@thumble/storage";
import { verifyPresentationIcon } from "../apps/service/src/presentation-icon.ts";
import { withPresentation as appearance } from "./helpers/presentation-source.ts";
import { digest } from "./helpers/wow-refresh.ts";
const fixture = JSON.parse(
  readFileSync(
    resolve(
      import.meta.dir,
      "../packages/fixtures/saved-controller-presentation-control-v10.json",
    ),
    "utf8",
  ),
);
const profileId = "aaaaaaaa-0000-0000-0000-000000000001",
  southId = "ce000000-0000-0000-0000-00000000000a";
function setup() {
  let source: ConfigurationSource = {
    revision: "3",
    source: starterConfiguration(profileId, "Saved profile", "1"),
    contentHash: "",
  };
  source = { ...source, contentHash: configurationSourceHash(source.source) };
  let writes = 0;
  const repository: ConfigurationRepository = {
    current: () => source,
    receipt: () => undefined,
    commit: () => {
      writes++;
      throw Error("unexpected_write");
    },
  };
  let fresh: "observed" | "stale" | "not-evaluated" = "not-evaluated";
  const operations = new ConfigurationPhonePresentationOperations(repository, {
    sourceHash: configurationSourceHash,
    documentHash: digest,
    resourceHash: digest,
    readAsset: () => {
      throw Error("unexpected_external_asset");
    },
    verifyIcon: verifyPresentationIcon,
    freshness: () => fresh,
  });
  const controls = new ConfigurationPhoneControlsOperations(repository, {
    sourceHash: configurationSourceHash,
    documentHash: digest,
    resourceHash: digest,
    readAsset: () => {
      throw Error("unexpected_asset");
    },
    served: (query, hash, map) => operations.remember(query, hash, map),
  });
  const query = {
    authorityInstanceId: "authority",
    expectedConfigurationRevision: "3",
    expectedSourceHash: source.contentHash,
    profileId,
    generation: "7",
    revision: "2",
    viewportWidth: "874",
    viewportHeight: "393",
  };
  const result = controls.execute({
    command: "configuration-phone-controls",
    ...query,
  });
  if (result.kind !== "controls") throw Error("fixture_map_missing");
  const command: PhonePresentationCommand = {
    command: "configuration-phone-presentation",
    kind: "metadata",
    ...query,
    configurationSha256: String(result.configurationSha256),
    colorScheme: "light",
  };
  return {
    operations,
    controls,
    command,
    query,
    get source() {
      return source;
    },
    set(next: LosslessJson) {
      source = {
        revision: String(BigInt(source.revision) + 1n),
        contentHash: configurationSourceHash(next),
        source: next,
      };
    },
    get writes() {
      return writes;
    },
    fresh(value: typeof fresh) {
      fresh = value;
    },
  };
}
test("new saved icons/labels are readable under the old installed input pin without a write or reactivation", () => {
  const f = setup(),
    initial = f.operations.execute(f.command);
  expect(initial.kind).toBe("presentation");
  f.set(
    appearance(f.source.source)
      .set("/profiles/0/customization/elements/9/label", '"Jump"')
      .set("/opaque", '{"n":1e+03}'),
  );
  f.fresh("observed");
  const before = f.source.source.text(),
    reply = f.operations.execute(f.command);
  expect(reply.kind).toBe("presentation");
  if (reply.kind !== "presentation") throw Error("expected_presentation");
  expect(reply.expectedConfigurationRevision).toBe("3");
  expect(reply.presentationRevision).toBe("4");
  expect(reply.expectedSourceHash).not.toBe(reply.presentationSourceHash);
  expect(reply.control9Label).toBe("Jump");
  expect(reply.control9IconName).toBe("Observed icon");
  expect(reply.freshness).toBe("observed");
  expect(reply.controlCount).toBe(18);
  expect(JSON.stringify(reply)).not.toContain("Base64");
  const icon = f.operations.execute({
    ...f.command,
    kind: "icon",
    presentationRevision: String(reply.presentationRevision),
    presentationSourceHash: String(reply.presentationSourceHash),
    controlId: southId,
    iconSHA256: String(reply.control9IconSHA256),
  });
  expect(icon.kind).toBe("icon");
  if (icon.kind === "icon")
    expect(icon.pngBase64).toBe(fixture.iconReply.pngBase64);
  expect(f.source.source.text()).toBe(before);
  expect(f.writes).toBe(0);
});
test("changed native/authority/viewport pins or geometry/actions/haptics cannot borrow a newer input baseline", () => {
  for (const patch of [
    { generation: "8" },
    { authorityInstanceId: "other" },
    { viewportWidth: "874.0" },
    { configurationSha256: "a".repeat(64) },
    { expectedConfigurationRevision: "4" },
  ]) {
    const f = setup();
    expect(f.operations.execute({ ...f.command, ...patch })).toEqual({
      kind: "error",
      error: "presentation_reactivation_required",
    });
  }
  for (const change of [
    (s: LosslessJson) =>
      s.set("/profiles/0/customization/elements/9/layout/centerX", "0.6"),
    (s: LosslessJson) =>
      s.set(
        "/profiles/0/customization/elements/9/layout/hapticStyle",
        '"none"',
      ),
    (s: LosslessJson) =>
      s.set(
        "/profileOutputBindings/" + profileId + "/" + southId,
        '{"gamepadButtons":["east"]}',
      ),
    (s: LosslessJson) =>
      s
        .set("/profileOutputBindings/" + profileId, "{}")
        .set("/outputBindings", "{}"),
  ]) {
    const f = setup();
    f.set(change(f.source.source));
    expect(f.operations.execute(f.command)).toEqual({
      kind: "error",
      error: "presentation_reactivation_required",
    });
    expect(f.writes).toBe(0);
  }
});
test("icon reads need exact returned metadata, current source/theme/control and a referenced verified PNG", () => {
  const f = setup();
  f.set(appearance(f.source.source));
  const reply = f.operations.execute(f.command);
  if (reply.kind !== "presentation") throw Error("expected_presentation");
  const icon: PhonePresentationCommand = {
    ...f.command,
    kind: "icon",
    presentationRevision: String(reply.presentationRevision),
    presentationSourceHash: String(reply.presentationSourceHash),
    controlId: southId,
    iconSHA256: String(reply.control9IconSHA256),
  };
  for (const patch of [
    { iconSHA256: "a".repeat(64) },
    { controlId: "missing" },
    { colorScheme: "dark" as const },
  ])
    expect(f.operations.execute({ ...icon, ...patch })).toEqual({
      kind: "error",
      error: "presentation_stale",
    });
  f.set(f.source.source.set("/profiles/0/name", '"New name"'));
  expect(f.operations.execute(icon)).toEqual({
    kind: "error",
    error: "presentation_stale",
  });
});
test("baseline LRU is bounded8 entries and child restart has no historical map proof", () => {
  const f = setup();
  for (let i = 0; i < 8; i++)
    expect(
      f.controls.execute({
        command: "configuration-phone-controls",
        ...f.query,
        authorityInstanceId: "new-" + i,
      }).kind,
    ).toBe("controls");
  expect(f.operations.execute(f.command)).toEqual({
    kind: "error",
    error: "presentation_reactivation_required",
  });
  const fresh = new ConfigurationPhonePresentationOperations(
    {
      current: () => f.source,
      receipt: () => undefined,
      commit: () => {
        throw Error("write");
      },
    },
    {
      sourceHash: configurationSourceHash,
      documentHash: digest,
      resourceHash: digest,
      readAsset: () => new Uint8Array(),
      verifyIcon: verifyPresentationIcon,
      freshness: () => "not-evaluated",
    },
  );
  expect(fresh.execute(f.command)).toEqual({
    kind: "error",
    error: "presentation_reactivation_required",
  });
});

test("presentation rejects unsupported icon pixels and oversized UTF8 labels without truncating or writing", () => {
  const badPixels = Buffer.from(fixture.iconReply.pngBase64, "base64");
  badPixels[badPixels.length - 1]! ^= 1;
  for (const edit of [
    (source: LosslessJson) =>
      appearance(source).set(
        "/profiles/0/customization/elements/9/label",
        JSON.stringify("🙂".repeat(33)),
      ),
    (source: LosslessJson) =>
      appearance(source).set(
        "/profiles/0/appearanceBank/variants/0/appearance/assetLibrary/assets/0/data",
        JSON.stringify(badPixels.toString("base64")),
      ),
    (source: LosslessJson) =>
      appearance(source).set(
        "/profiles/0/appearanceBank/variants/0/appearance/controls/" +
          southId +
          "/icon/renderingMode",
        '"template"',
      ),
  ]) {
    const f = setup();
    f.set(edit(f.source.source));
    const before = f.source.source.text();
    expect(f.operations.execute(f.command)).toEqual({
      kind: "error",
      error: "presentation_unsupported_profile",
    });
    expect(f.source.source.text()).toBe(before);
    expect(f.writes).toBe(0);
  }
});
