import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationDuplicateProfileCommand,
} from "@thumble/contracts/configuration";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { ConfigurationCatalogOperations } from "@thumble/application/configuration-catalog";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { FileAssetStore } from "@thumble/storage/asset-files";
import { a, b, selectionFixtureSource } from "./helpers/selection-fixture.ts";
const root = resolve(import.meta.dir, ".."),
  executable = join(
    root,
    `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
  ),
  copyId = "f0000000-0000-0000-0000-000000000001",
  digest = (value: string | Uint8Array) =>
    createHash("sha256").update(value).digest("hex"),
  access = { read: true, write: true };
const command = (
  profileId = a,
  select = false,
): ConfigurationDuplicateProfileCommand => ({
  command: "configuration-duplicate-profile",
  operationId: "copy-one",
  expectedRevision: "1",
  profileId,
  newProfileId: copyId,
  name: "  Copy 🦊  ",
  select,
});
function fixture(run: (runtime: string) => void) {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-duplicate-")),
  );
  try {
    run(join(parent, "runtime"));
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}
function ownedSource() {
  return LosslessJson.parse(
    readFileSync(
      join(root, "packages/fixtures/owned-configuration-v1/document.json"),
      "utf8",
    ),
  );
}

for (const select of [false, true])
  for (const index of [0, 1])
    test(`duplicate shares verified assets, copies exact profile-scoped state/maps and durable receipt (${select ? "select" : "keep"},source ${index})`, () =>
      fixture((runtime) => {
        const initial = ownedSource(),
          profile = initial.get(`/profiles/${index}`)!,
          sourceId = profile.get("/id")!.stringValue!,
          original = initial
            .set(
              `/profiles/${index}/futureCloneMetadata`,
              JSON.stringify({
                originProfileID: sourceId,
                controlID: "00000000-0000-0000-0000-000000000109",
                path: `/profiles/${index}/opaque`,
              }),
            )
            .set(
              `/profiles/${index}/futureCloneMetadata/huge`,
              "9007199254740993.0000",
            )
            .set("/defaultProfileID", initial.get("/profiles/0/id")!.text());
        const preparation = OwnedAuthorityDocument.prepare(original, digest);
        let authority = preparation.document;
        if (authority.resources.length) {
          const bytes = authority.resources[0]!.byteCount;
          authority = OwnedAuthorityDocument.read(
            authority.source.set("/resources/0/byteCount", `${bytes}.000`),
          );
        }
        let repository = new SqliteConfigurationRepository(runtime, executable);
        repository.commit({
          operationId: "seed",
          expectedRevision: "0",
          payloadHash: digest("seed"),
          source: authority.source,
          assets: preparation.assets(),
          affectedEntities: ["configuration"],
        });
        const files = readdirSync(join(runtime, "assets-v1")).sort(),
          request = {
            ...command(sourceId, select),
            newProfileId: copyId.toUpperCase(),
          },
          operations = new ConfigurationCatalogOperations(
            repository,
            digest,
            () => "1234",
          );
        try {
          const result = operations.execute(request, access);
          expect(result.kind).toBe("committed");
          if (result.kind !== "committed")
            throw new Error("test_receipt_missing");
          expect(
            decodeConfigurationReply(
              result,
              decodeConfigurationCommand(request),
            ),
          ).toEqual(result);
          expect(result.receipt.affectedEntities).toEqual([
            "configuration",
            copyId,
          ]);
          expect(result.receipt.resultingRevision).toBe("2");
          const current = OwnedAuthorityDocument.read(
              repository.current()!.source,
            ),
            copied = current.source.get("/document/profiles/2")!,
            source = authority.source.get(`/document/profiles/${index}`)!;
          expect(copied.get("/id")?.stringValue).toBe(copyId);
          expect(copied.get("/name")?.stringValue).toBe("Copy 🦊");
          expect(copied.get("/updatedAt")?.numberToken).toBe("1234");
          for (const key of source.keys)
            if (!["id", "name", "updatedAt"].includes(key))
              expect(copied.get("/" + key)?.text()).toBe(
                source.get("/" + key)?.text(),
              );
          for (let i = 0; i < authority.catalog.profiles.length; i++)
            expect(current.source.get(`/document/profiles/${i}`)?.text()).toBe(
              authority.source.get(`/document/profiles/${i}`)?.text(),
            );
          const beforeRows = authority.source.get("/resources")!,
            afterRows = current.source.get("/resources")!,
            sourcePrefix = `/profiles/${index}/`;
          for (let i = 0; i < beforeRows.length!; i++) {
            const row = beforeRows.get(`/${i}`)!,
              path = row.get("/path")!.stringValue!,
              at = current.resources.findIndex(
                (resource) => resource.path === path,
              );
            expect(afterRows.get(`/${at}`)?.text()).toBe(row.text());
            if (path.startsWith(sourcePrefix)) {
              const target = "/profiles/2/" + path.slice(sourcePrefix.length),
                duplicate = current.resources.find(
                  (resource) => resource.path === target,
                );
              expect(duplicate?.sha256).toBe(row.get("/sha256")?.stringValue);
              expect(duplicate?.byteCount).toBe(
                row.get("/byteCount")?.integerValue,
              );
            }
          }
          expect(current.resources.length).toBe(
            authority.resources.length +
              authority.resources.filter((resource) =>
                resource.path.startsWith(sourcePrefix),
              ).length,
          );
          expect(readdirSync(join(runtime, "assets-v1")).sort()).toEqual(files);
          for (const map of ["profileKeyBindings", "profileOutputBindings"]) {
            const old = authority.source.get("/document/" + map)!,
              key = old.keys.find(
                (key) => key.toLowerCase() === sourceId.toLowerCase(),
              );
            expect(current.source.get(`/document/${map}/${copyId}`)?.kind).toBe(
              "object",
            );
            if (key)
              expect(
                current.source.get(`/document/${map}/${copyId}`)?.text(),
              ).toBe(old.get("/" + key)?.text());
            for (const key of old.keys)
              expect(
                current.source.get(`/document/${map}/${key}`)?.text(),
              ).toBe(old.get("/" + key)?.text());
          }
          expect(current.source.get("/document/defaultProfileID")?.text()).toBe(
            authority.source.get("/document/defaultProfileID")?.text(),
          );
          if (select) {
            expect(current.catalog.activeProfileID).toBe(copyId);
            for (const [mirror, map] of [
              ["keyBindings", "profileKeyBindings"],
              ["outputBindings", "profileOutputBindings"],
            ])
              expect(current.source.get("/document/" + mirror)?.text()).toBe(
                current.source.get(`/document/${map}/${copyId}`)?.text(),
              );
          } else
            for (const key of [
              "activeProfileID",
              "keyBindings",
              "outputBindings",
            ])
              expect(current.source.get("/document/" + key)?.text()).toBe(
                authority.source.get("/document/" + key)?.text(),
              );
          const assets = new FileAssetStore(runtime, executable),
            restored = current.materialize((hash) => assets.read(hash), digest),
            oldProfile = restored.profile(sourceId),
            newProfile = restored.profile(copyId);
          expect(newProfile.elements.map((control) => control.id)).toEqual(
            oldProfile.elements.map((control) => control.id),
          );
          expect(newProfile.appearanceStates).toEqual(
            oldProfile.appearanceStates,
          );
          expect(
            newProfile.source.get("/futureCloneMetadata/huge")?.numberToken,
          ).toBe("9007199254740993.0000");
          operations.execute(
            {
              command: "configuration-rename-profile",
              operationId: "later",
              expectedRevision: "2",
              profileId: copyId,
              name: "Later",
            },
            access,
          );
          repository.close();
          repository = new SqliteConfigurationRepository(runtime, executable);
          const replay = new ConfigurationCatalogOperations(
            repository,
            digest,
            () => {
              throw new Error("test_replay_clock");
            },
          );
          expect(
            replay.execute(
              {
                ...request,
                profileId: sourceId.toLowerCase(),
                newProfileId: copyId,
                name: "Copy 🦊",
              },
              access,
            ),
          ).toEqual({ ...result, replayed: true });
          expect(repository.current()?.revision).toBe("3");
          expect(
            OwnedAuthorityDocument.read(repository.current()!.source).catalog
              .profiles.length,
          ).toBe(3);
          for (const changed of [
            { ...request, select: !select },
            { ...request, name: "Different" },
            {
              ...request,
              newProfileId: "f0000000-0000-0000-0000-000000000002",
            },
          ])
            expect(() => replay.execute(changed, access)).toThrow(
              "operation_id_reused",
            );
        } finally {
          repository.close();
        }
      }));

test("duplicate capabilities/CAS/collisions/unsupported source fail before commit; inline copies retain exact opaque data", () =>
  fixture((runtime) => {
    const original = selectionFixtureSource(),
      repository = new SqliteConfigurationRepository(runtime, executable);
    repository.commit({
      operationId: "seed",
      expectedRevision: "0",
      payloadHash: digest("seed"),
      source: original,
      affectedEntities: ["configuration"],
    });
    const operations = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => "100",
    );
    try {
      for (const denied of [
        { read: false, write: true },
        { read: true, write: false },
      ])
        expect(() => operations.execute(command(), denied)).toThrow(
          "configuration_access_denied",
        );
      expect(
        operations.execute({ ...command(), expectedRevision: "0" }, access),
      ).toEqual({ version: 1, kind: "conflict", currentRevision: "1" });
      expect(() =>
        operations.execute(
          { ...command(), newProfileId: b.toUpperCase() },
          access,
        ),
      ).toThrow("duplicate_profile_id");
      expect(() =>
        operations.execute({ ...command(), profileId: copyId }, access),
      ).toThrow("profile_not_found");
      expect(repository.current()?.revision).toBe("1");
      expect(operations.execute(command(), access).kind).toBe("committed");
      const copied = repository.current()!.source;
      OwnedConfigurationDocument.read(copied, digest);
      expect(copied.get("/profiles/2/customization")?.text()).toBe(
        original.get("/profiles/0/customization")?.text(),
      );
      expect(copied.get("/profiles/2/updatedAt")?.numberToken).toBe("100");
      for (const path of [
        "/activeProfileID",
        "/defaultProfileID",
        "/keyBindings",
        "/outputBindings",
        "/opaque",
      ])
        expect(copied.get(path)?.text()).toBe(original.get(path)?.text());
      expect(() =>
        operations.execute(
          { ...command(), operationId: "second-copy", expectedRevision: "2" },
          access,
        ),
      ).toThrow("duplicate_profile_id");
      const missing = original.remove("/profiles/0/customization/elements");
      expect(() =>
        ConfigurationCatalog.read(missing).duplicateProfile(
          a,
          copyId,
          "Copy",
          "100",
          false,
        ),
      ).toThrow("invalid_owned_configuration");
      for (const value of ["9223372036854775808", "18446744073709551615"])
        expect(() =>
          new ConfigurationCatalogOperations(
            repository,
            digest,
            () => value,
          ).execute(
            {
              ...command(),
              operationId: "clock-overflow",
              expectedRevision: "2",
              newProfileId: "f0000000-0000-0000-0000-000000000002",
            },
            access,
          ),
        ).toThrow("configuration_clock_invalid");
      expect(repository.current()?.revision).toBe("2");
    } finally {
      repository.close();
    }
  }));

test("duplicate enforces existing profile and document bounds, including materialized shared resource amplification", () => {
  const initial = selectionFixtureSource(),
    first = initial.get("/profiles/0")!,
    profiles = [initial.get("/profiles/0")!, initial.get("/profiles/1")!];
  for (let i = 2; i < 256; i++)
    profiles.push(
      first.set(
        "/id",
        JSON.stringify(
          `aa000000-0000-0000-0000-${String(i).padStart(12, "0")}`,
        ),
      ),
    );
  const full = ConfigurationCatalog.read(
    initial.set(
      "/profiles",
      `[${profiles.map((profile) => profile.text()).join(",")}]`,
    ),
  );
  expect(() => full.duplicateProfile(a, copyId, "Copy", "100", false)).toThrow(
    "configuration_profile_limit",
  );
  const padded = initial.set(
    "/profiles/0/futurePadding",
    JSON.stringify("x".repeat(4200000)),
  );
  expect(() =>
    ConfigurationCatalog.read(padded).duplicateProfile(
      a,
      copyId,
      "Copy",
      "100",
      false,
    ),
  ).toThrow("invalid_configuration_json");
  const raw = ownedSource(),
    profile = raw.get("/profiles/0")!,
    pool = profile.get("/appearanceResources")!,
    oldHash = pool.keys[0]!,
    bytes = new Uint8Array(3 * 1024 * 1024),
    hash = digest(bytes),
    changed = profile.set(
      "/appearanceResources",
      pool
        .remove("/" + oldHash)
        .set("/" + hash, JSON.stringify(Buffer.from(bytes).toString("base64")))
        .text(),
    );
  const large = raw.set(
      "/profiles/0",
      changed.text().replaceAll(oldHash, hash),
    ),
    authority = OwnedAuthorityDocument.prepare(large, digest).document;
  expect(authority.source.byteLength).toBeLessThan(large.byteLength);
  expect(() =>
    authority.duplicateProfile(
      authority.catalog.profiles[0]!.id,
      copyId,
      "Copy",
      "100",
      false,
    ),
  ).toThrow("invalid_owned_authority");
});

test("duplicate wire intent requires explicit selection and binds the fresh ID/name/receipt scope", () => {
  const input = command(),
    decoded = decodeConfigurationCommand(input);
  expect(decoded).toEqual({ ...input, name: "Copy 🦊" });
  for (const bad of [
    { ...input, select: undefined },
    { ...input, select: "false" },
    { ...input, newProfileId: "bad" },
    { ...input, name: "  " },
    { ...input, source: "raw" },
    { ...input, enableInput: true },
  ])
    expect(() => decodeConfigurationCommand(bad)).toThrow();
  const result = {
    version: 1,
    kind: "committed",
    receipt: {
      version: 1,
      operationId: input.operationId,
      resultingRevision: "2",
      contentHash: "a".repeat(64),
      affectedEntities: ["configuration", copyId],
    },
    replayed: false,
  } as const;
  expect(decodeConfigurationReply(result, decoded)).toEqual(result);
  for (const entities of [
    ["configuration"],
    [copyId, "configuration"],
    ["configuration", a],
  ])
    expect(() =>
      decodeConfigurationReply(
        {
          ...result,
          receipt: { ...result.receipt, affectedEntities: entities },
        },
        decoded,
      ),
    ).toThrow();
});

test("authority duplication rebases exact source-profile resource paths across multi-digit indices", () => {
  let authority = OwnedAuthorityDocument.prepare(
    ownedSource(),
    digest,
  ).document;
  const first = authority.catalog.profiles[0]!.id;
  for (let index = 2; index <= 10; index++)
    authority = authority.duplicateProfile(
      first,
      `fc000000-0000-0000-0000-${String(index).padStart(12, "0")}`,
      "Saved copy",
      "100",
      false,
    );
  expect(
    authority.resources.some((resource) =>
      resource.path.startsWith("/profiles/10/"),
    ),
  ).toBe(true);
  const source = authority.catalog.profiles[1]!.id,
    expected = authority.resources.filter((resource) =>
      resource.path.startsWith("/profiles/1/"),
    ),
    duplicated = authority.duplicateProfile(
      source,
      copyId,
      "Copy",
      "100",
      false,
    ),
    actual = duplicated.resources.filter((resource) =>
      resource.path.startsWith("/profiles/11/"),
    );
  expect(actual).toEqual(
    expected.map((resource) => ({
      ...resource,
      path: "/profiles/11/" + resource.path.slice("/profiles/1/".length),
    })),
  );
  expect(duplicated.resources.length).toBe(
    authority.resources.length + expected.length,
  );
  expect(duplicated.resources.map((resource) => resource.path)).toEqual(
    [...duplicated.resources.map((resource) => resource.path)].sort(),
  );
});
