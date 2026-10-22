import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationSelectProfilesCommand,
} from "@thumble/contracts/configuration";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { ConfigurationCatalogOperations } from "@thumble/application/configuration-catalog";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { FileAssetStore } from "@thumble/storage/asset-files";
import { a, b, selectionFixtureSource } from "./helpers/selection-fixture.ts";
const root = resolve(import.meta.dir, ".."),
  executable = join(
    root,
    `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
  );
const digest = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");
const unknown = "cccccccc-0000-0000-0000-000000000003";
const selection: ConfigurationSelectProfilesCommand = {
  command: "configuration-select-profiles",
  operationId: "choose-profiles",
  expectedRevision: "1",
  activeProfileId: a,
  defaultProfileId: b,
};
const access = { read: true, write: true };
function fixture(run: (runtime: string) => void) {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-selection-")),
  );
  try {
    run(join(parent, "runtime"));
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}

test("saved profile selection synchronizes selected binding mirrors and preserves opaque profile/timestamp source", () => {
  const original = selectionFixtureSource().set(
      "/profiles/0/id",
      JSON.stringify(a.toUpperCase()),
    ),
    catalog = ConfigurationCatalog.read(original);
  expect(catalog.activeProfileID).toBe(b);
  expect(catalog.defaultProfileID).toBeNull();
  const changed = catalog.selectProfiles(a.toUpperCase(), b.toUpperCase());
  expect(changed.activeProfileID).toBe(a);
  expect(changed.defaultProfileID).toBe(b);
  expect(changed.source.get("/activeProfileID")?.text()).toBe(
    original.get("/profiles/0/id")?.text(),
  );
  expect(changed.source.get("/profiles/0/id")?.text()).toBe(
    original.get("/profiles/0/id")?.text(),
  );
  for (const key of original.keys)
    if (
      ![
        "activeProfileID",
        "defaultProfileID",
        "keyBindings",
        "outputBindings",
        "profileKeyBindings",
        "profileOutputBindings",
      ].includes(key)
    )
      expect(changed.source.get(`/${key}`)?.text()).toBe(
        original.get(`/${key}`)?.text(),
      );
  expect(changed.selectProfiles(a.toUpperCase(), b)).toBe(changed);
  const cleared = changed.selectProfiles(b, null);
  expect(cleared.defaultProfileID).toBeNull();
  expect(cleared.activeProfileID).toBe(b);
  expect(cleared.source.get("/profiles")?.text()).toBe(
    original.get("/profiles")?.text(),
  );
  for (const [active, defaultId] of [
    [unknown, b],
    [a, unknown],
  ] as const)
    expect(() => catalog.selectProfiles(active, defaultId)).toThrow(
      "profile_not_found",
    );
  expect(catalog.source).toBe(original);
});

for (const external of [false, true])
  test(`saved selection commits only through the owner repository and replays durable receipts (${external ? "external resources" : "inline legacy"})`, () =>
    fixture((runtime) => {
      const original = external
        ? LosslessJson.parse(
            readFileSync(
              join(
                root,
                "packages/fixtures/owned-configuration-v1/document.json",
              ),
              "utf8",
            ),
          )
        : selectionFixtureSource();
      const prepared = external
        ? OwnedAuthorityDocument.prepare(original, digest)
        : undefined;
      let repository = new SqliteConfigurationRepository(runtime, executable);
      repository.commit({
        operationId: "fixture",
        payloadHash: digest("seed"),
        expectedRevision: "0",
        source: prepared?.document.source ?? original,
        ...(prepared ? { assets: prepared.assets() } : {}),
        affectedEntities: ["configuration"],
      });
      const catalog = ConfigurationCatalog.read(original),
        command: ConfigurationSelectProfilesCommand = {
          ...selection,
          activeProfileId: catalog.profiles[1]!.id,
          defaultProfileId: catalog.profiles[0]!.id,
        };
      const make = () =>
        new ConfigurationCatalogOperations(repository, digest, () => {
          throw new Error("test_selection_must_not_touch_clock");
        });
      try {
        for (const access of [
          { read: false, write: true },
          { read: true, write: false },
        ])
          expect(() => make().execute(command, access)).toThrow(
            "configuration_access_denied",
          );
        expect(
          make().execute({ ...command, expectedRevision: "0" }, access),
        ).toEqual({ version: 1, kind: "conflict", currentRevision: "1" });
        for (const bad of [
          { ...command, activeProfileId: unknown },
          { ...command, defaultProfileId: unknown },
        ])
          expect(() => make().execute(bad, access)).toThrow(
            "profile_not_found",
          );
        expect(repository.current()?.revision).toBe("1");
        const result = make().execute(command, access);
        expect(result.kind).toBe("committed");
        if (result.kind !== "committed")
          throw new Error("test_receipt_missing");
        expect(decodeConfigurationReply(result, command)).toEqual(result);
        expect(result.receipt.resultingRevision).toBe("2");
        expect(result.receipt.affectedEntities).toEqual(["configuration"]);
        const current = repository.current()!,
          assets = new FileAssetStore(runtime, executable),
          changed = external
            ? OwnedAuthorityDocument.read(current.source).materialize(
                (hash) => assets.read(hash),
                digest,
              ).source
            : current.source;
        for (const key of original.keys)
          if (
            ![
              "activeProfileID",
              "defaultProfileID",
              "keyBindings",
              "outputBindings",
              "profileKeyBindings",
              "profileOutputBindings",
            ].includes(key)
          )
            expect(changed.get(`/${key}`)?.canonicalText()).toBe(
              original.get(`/${key}`)?.canonicalText(),
            );
        if (prepared)
          expect(current.source.get("/resources")?.text()).toBe(
            prepared.document.source.get("/resources")?.text(),
          );
        expect(ConfigurationCatalog.read(changed).activeProfileID).toBe(
          command.activeProfileId,
        );
        expect(ConfigurationCatalog.read(changed).defaultProfileID).toBe(
          command.defaultProfileId,
        );
        const cleared = make().execute(
          {
            ...command,
            operationId: "clear-default",
            expectedRevision: "2",
            defaultProfileId: null,
          },
          access,
        );
        expect(cleared.kind).toBe("committed");
        repository.close();
        repository = new SqliteConfigurationRepository(runtime, executable);
        expect(make().execute(command, access)).toEqual({
          ...result,
          replayed: true,
        });
        expect(repository.current()?.revision).toBe("3");
        for (const changed of [
          { ...command, activeProfileId: command.defaultProfileId! },
          { ...command, defaultProfileId: null },
          { ...command, expectedRevision: "3" },
        ])
          expect(() => make().execute(changed, access)).toThrow(
            "operation_id_reused",
          );
        const beforeNoop = repository.current()!.contentHash,
          noop = make().execute(
            {
              ...command,
              operationId: "same-selectors",
              expectedRevision: "3",
              defaultProfileId: null,
            },
            access,
          );
        expect(noop.kind).toBe("committed");
        if (noop.kind === "committed") {
          expect(noop.receipt.resultingRevision).toBe("4");
          expect(noop.receipt.contentHash).toBe(beforeNoop);
        }
      } finally {
        repository.close();
      }
    }));

test("selection contracts bind both selectors and refuse caller authority/activation or mismatched receipts", () => {
  expect(
    decodeConfigurationCommand({
      ...selection,
      activeProfileId: a.toUpperCase(),
      defaultProfileId: b.toUpperCase(),
    }),
  ).toEqual(selection);
  const receipt = {
    version: 1,
    kind: "committed",
    receipt: {
      version: 1,
      operationId: selection.operationId,
      resultingRevision: "2",
      contentHash: "a".repeat(64),
      affectedEntities: ["configuration"],
    },
    replayed: false,
  } as const;
  expect(decodeConfigurationReply(receipt, selection)).toEqual(receipt);
  for (const bad of [
    { ...selection, activeProfileId: null },
    { ...selection, defaultProfileId: undefined },
    { ...selection, activeProfileId: "bad" },
    { ...selection, enableInput: true },
    { ...selection, payloadHash: "a".repeat(64) },
  ])
    expect(() => decodeConfigurationCommand(bad)).toThrow();
  for (const bad of [
    { ...receipt, active: true },
    { ...receipt, receipt: { ...receipt.receipt, affectedEntities: [a] } },
    { ...receipt, receipt: { ...receipt.receipt, resultingRevision: "3" } },
    { ...receipt, receipt: { ...receipt.receipt, operationId: "other" } },
  ])
    expect(() => decodeConfigurationReply(bad, selection)).toThrow();
});
