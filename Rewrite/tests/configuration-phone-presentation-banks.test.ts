import { expect, test } from "bun:test";
import fixture from "../packages/fixtures/saved-controller-presentation-control-v11.json";
import type {
  AnyPhonePresentationCommand,
  PresentationBank,
} from "@thumble/contracts/phone-presentation";
import type {
  ConfigurationRepository,
  ConfigurationSource,
} from "@thumble/application/configuration-store";
import { ConfigurationPhoneControlsOperations } from "@thumble/application/configuration-phone-controls";
import { ConfigurationPhonePresentationOperations } from "@thumble/application/configuration-phone-presentation";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { configurationSourceHash } from "@thumble/storage";
import { verifyPresentationIcon } from "../apps/service/src/presentation-icon.ts";
import {
  withBankPresentation,
  bankSouthId,
} from "./helpers/bank-presentation-source.ts";
import { digest } from "./helpers/wow-refresh.ts";
const profileId = "aaaaaaaa-0000-0000-0000-000000000001";
function setup() {
  let current: ConfigurationSource = {
    revision: "3",
    source: withBankPresentation(
      starterConfiguration(profileId, "Bank profile", "1"),
    ),
    contentHash: "",
  };
  current = {
    ...current,
    contentHash: configurationSourceHash(current.source),
  };
  let writes = 0;
  const repo: ConfigurationRepository = {
    current: () => current,
    receipt: () => undefined,
    commit: () => {
      writes++;
      throw Error("unexpected_write");
    },
  };
  const ops = new ConfigurationPhonePresentationOperations(repo, {
    sourceHash: configurationSourceHash,
    documentHash: digest,
    resourceHash: digest,
    readAsset: () => {
      throw Error("unexpected_asset");
    },
    verifyIcon: verifyPresentationIcon,
    freshness: () => "observed",
  });
  const controls = new ConfigurationPhoneControlsOperations(repo, {
    sourceHash: configurationSourceHash,
    documentHash: digest,
    resourceHash: digest,
    readAsset: () => {
      throw Error("unexpected_asset");
    },
    served: (q, h, m) => ops.remember(q, h, m),
  });
  const q = {
    authorityInstanceId: "authority",
    expectedConfigurationRevision: current.revision,
    expectedSourceHash: current.contentHash,
    profileId,
    generation: "7",
    revision: "2",
    viewportWidth: "874",
    viewportHeight: "393",
  };
  const map = controls.execute({
    command: "configuration-phone-controls",
    ...q,
  });
  if (map.kind !== "controls") throw Error("fixture_map");
  const command = (
    bank: PresentationBank = "base",
    colorScheme: "light" | "dark" = "light",
  ): AnyPhonePresentationCommand => ({
    command: "configuration-phone-presentation",
    kind: "metadata",
    ...q,
    configurationSha256: String(map.configurationSha256),
    presentationProtocol: 2,
    bank,
    colorScheme,
  });
  return {
    ops,
    command,
    get current() {
      return current;
    },
    get writes() {
      return writes;
    },
    set(source: ConfigurationSource["source"]) {
      current = {
        revision: String(BigInt(current.revision) + 1n),
        source,
        contentHash: configurationSourceHash(source),
      };
    },
  };
}
test("all eight saved presentation states retain original input pin and exact bank/theme PNG identity", () => {
  const f = setup(),
    before = f.current.source.text();
  for (const v of fixture.variants) {
    const bank = v.request.bank as PresentationBank,
      theme = v.request.colorScheme as "light" | "dark",
      q = f.command(bank, theme),
      meta = f.ops.execute(q);
    expect(meta.kind).toBe("presentation");
    if (meta.kind !== "presentation") throw Error("missing_metadata");
    expect(meta.bank).toBe(bank);
    expect(meta.colorScheme).toBe(theme);
    expect(meta.control9IconSHA256).toBe(v.iconReply.iconSHA256);
    expect(meta.controlCount).toBe(18);
    expect(meta.generation).toBe("7");
    expect(meta.revision).toBe("2");
    const icon = f.ops.execute({
      ...q,
      kind: "icon",
      presentationRevision: String(meta.presentationRevision),
      presentationSourceHash: String(meta.presentationSourceHash),
      controlId: bankSouthId,
      iconSHA256: String(meta.control9IconSHA256),
    });
    expect(icon.kind).toBe("icon");
    if (icon.kind !== "icon") throw Error("missing_icon");
    expect(icon.bank).toBe(bank);
    expect(icon.pngBase64).toBe(v.iconReply.pngBase64);
  }
  expect(f.current.source.text()).toBe(before);
  expect(f.writes).toBe(0);
});
test("bank/theme cache scope rejects a stale icon after another state read without affecting input proof", () => {
  const f = setup(),
    q = f.command(),
    first = f.ops.execute(q);
  if (first.kind !== "presentation") throw Error("fixture");
  const icon = {
    ...q,
    kind: "icon" as const,
    presentationRevision: String(first.presentationRevision),
    presentationSourceHash: String(first.presentationSourceHash),
    controlId: bankSouthId,
    iconSHA256: String(first.control9IconSHA256),
  };
  expect(f.ops.execute(f.command("left-trigger")).kind).toBe("presentation");
  expect(f.ops.execute(icon)).toEqual({
    kind: "error",
    error: "presentation_stale",
  });
  expect(f.ops.execute(f.command()).kind).toBe("presentation");
  expect(f.ops.execute(icon).kind).toBe("icon");
  expect(
    f.ops.execute({ ...icon, bank: "both-triggers", presentationProtocol: 2 }),
  ).toEqual({ kind: "error", error: "presentation_stale" });
});
test("canonical user icon replacement/removal and library edits survive every bank without source normalization", () => {
  const f = setup();
  f.set(
    f.current.source
      .set("/profiles/0/customization/elements/9/layout/icon", "null")
      .set("/opaque", '{"number":1e+03}'),
  );
  for (const bank of [
    "base",
    "left-trigger",
    "right-trigger",
    "both-triggers",
  ] as const) {
    const reply = f.ops.execute(f.command(bank));
    expect(reply.kind).toBe("presentation");
    if (reply.kind === "presentation")
      expect(reply.control9IconSHA256).toBeUndefined();
  }
  const target = fixture.variants[7]!;
  const asset = {
    id: "user-icon",
    name: "My icon",
    role: "icon",
    contentType: "image/png",
    byteCount: target.iconReply.byteCount,
    data: target.iconReply.pngBase64,
  };
  f.set(
    f.current.source
      .set(
        "/profiles/0/customization/elements/9/layout/icon",
        JSON.stringify({
          source: "asset",
          value: "user-icon",
          placement: "top",
          renderingMode: "original",
          scale: 1,
        }),
      )
      .set(
        "/profiles/0/customization/assetLibrary/assets",
        JSON.stringify([asset]),
      )
      .set(
        "/profiles/0/customization/labelOverrides",
        JSON.stringify([bankSouthId, "My action"]),
      ),
  );
  const before = f.current.source.text();
  for (const bank of [
    "base",
    "left-trigger",
    "right-trigger",
    "both-triggers",
  ] as const) {
    const reply = f.ops.execute(f.command(bank, "dark"));
    expect(reply.kind).toBe("presentation");
    if (reply.kind === "presentation") {
      expect(reply.control9IconSHA256).toBe(target.iconReply.iconSHA256);
      expect(reply.control9Label).toBe("My action");
    }
  }
  expect(f.current.source.text()).toBe(before);
  expect(before).toContain("1e+03");
  expect(f.writes).toBe(0);
});
test("input edits remain reactivation-required and missing or malformed requested banks never fall back to base", () => {
  const f = setup();
  f.set(
    f.current.source.set(
      "/profiles/0/customization/elements/9/layout/centerX",
      "0.1",
    ),
  );
  expect(f.ops.execute(f.command("right-trigger"))).toEqual({
    kind: "error",
    error: "presentation_reactivation_required",
  });
  const g = setup();
  g.set(g.current.source.remove("/profiles/0/appearanceBank/variants/2"));
  expect(g.ops.execute(g.command("right-trigger")).kind).toBe("error");
});

test("equivalent numeric icon fields do not pin light/base, and removed referenced assets fail closed", () => {
  const f = setup();
  f.set(
    f.current.source
      .set("/profiles/0/customization/elements/9/layout/icon/scale", "1.0")
      .set(
        "/profiles/0/customization/elements/9/layout/icon/tintColor",
        "null",
      ),
  );
  const q = f.command("right-trigger", "dark"),
    reply = f.ops.execute(q);
  expect(reply.kind).toBe("presentation");
  if (reply.kind === "presentation")
    expect(reply.control9IconSHA256).toBe(
      fixture.variants[6]!.iconReply.iconSHA256,
    );
  f.set(
    f.current.source.set("/profiles/0/customization/assetLibrary/assets", "[]"),
  );
  expect(f.ops.execute(q)).toEqual({
    kind: "error",
    error: "presentation_unavailable",
  });
  expect(f.writes).toBe(0);
});
