import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  readFileSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  readdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import {
  encodeResourceBase64,
  decodeResourceBase64,
} from "@thumble/domain/owned-resources";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { ConfigurationCatalogOperations } from "@thumble/application/configuration-catalog";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { FileAssetStore } from "@thumble/storage/asset-files";
const original = LosslessJson.parse(
  readFileSync(
    resolve(
      import.meta.dir,
      "../packages/fixtures/owned-configuration-v1/document.json",
    ),
    "utf8",
  ),
);
const digest = (bytes: Uint8Array) =>
  createHash("sha256").update(bytes).digest("hex");
const prepare = (source = original) =>
  OwnedAuthorityDocument.prepare(source, digest);
const executable = resolve(
  import.meta.dir,
  `../native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
function materialize(prepared: ReturnType<typeof prepare>) {
  const pool = new Map(
    prepared.assets().map((bytes) => [digest(bytes), bytes]),
  );
  return prepared.document.materialize((key) => pool.get(key)!, digest);
}

test("canonical authority externalizes pooled bytes and round-trips exact opaque data", () => {
  const prepared = prepare();
  expect(prepared.assets().length).toBe(2);
  expect(prepared.document.resources.length).toBe(2);
  expect(materialize(prepared).source.canonicalText()).toBe(
    original.canonicalText(),
  );
  const restored = materialize(prepared);
  expect(restored.source.get("/profiles/1")?.text()).toBe(
    original.get("/profiles/1")?.text(),
  );
  const pool = original.get("/profiles/0/appearanceResources")!;
  for (const key of pool.keys) {
    expect(
      prepared.document.source.get(
        "/document/profiles/0/appearanceResources/" + key + "/assetSHA256",
      )?.stringValue,
    ).toBe(key);
    expect(
      prepared.document.source
        .text()
        .includes(JSON.stringify(pool.get("/" + key)!.stringValue)),
    ).toBe(false);
  }
  expect(Object.isFrozen(prepared.document.resources)).toBe(true);
  const copy = prepared.assets();
  copy[0]!.fill(0);
  expect(materialize(prepared).source.canonicalText()).toBe(
    original.canonicalText(),
  );
  expect(() =>
    OwnedConfigurationDocument.read(prepared.document.source, digest),
  ).toThrow();
});

test("inline and hidden appearance data are externalized without reinterpreting future opaque metadata", () => {
  const profile = OwnedConfigurationDocument.read(original, digest)
    .profiles[0]!;
  const resource = profile.resources!.data(
    original.get(
      "/profiles/0/appearanceBank/variants/0/appearance/assetLibrary/assets/0/data",
    )!,
  );
  const inline = JSON.stringify(encodeResourceBase64(resource));
  const stylesPath =
    "/profiles/0/appearanceBank/variants/0/appearance/styleLibrary/styles";
  const opaquePath =
    stylesPath + "/" + original.get(stylesPath)!.length + "/opaque";
  const source = original
    .set(
      "/profiles/0/customization/futureImage",
      '{ "kind":"image", "image":{"data":"opaque-not-a-resource"}, "huge":18446744073709551615 }',
    )
    .set(
      stylesPath + "/-",
      '{"id":"future-style","opaque":{ "assetLibrary":{"assets":[{"id":"future-asset","data":"opaque-not-base64"}]}, "number":1e9999 }}',
    )
    .set(
      "/profiles/0/appearanceBank/variants/0/appearance/assetLibrary/assets/0/data",
      inline,
    )
    .set(
      "/profiles/0/appearanceBank/variants/0/appearance/backgroundFillStyle/image/data",
      inline,
    )
    .set(
      "/profiles/0/appearanceBank/variants/0/appearance/artworkLayers/0/isHidden",
      "true",
    )
    .set(
      "/profiles/0/appearanceBank/variants/0/appearance/artworkLayers/0/fillStyle/image/data",
      inline,
    );
  const prepared = prepare(source),
    restored = materialize(prepared);
  expect(prepared.assets().length).toBe(2);
  expect(prepared.document.resources.length).toBe(5);
  expect(restored.source.get(opaquePath)?.text()).toBe(
    source.get(opaquePath)?.text(),
  );
  expect(restored.source.canonicalText()).toBe(source.canonicalText());
  expect(
    restored.source.get("/profiles/0/customization/futureImage")?.text(),
  ).toBe(source.get("/profiles/0/customization/futureImage")?.text());
});

test("canonical manifests reject incomplete, unknown, conflicting and byte-amplifying references before IO", () => {
  const prepared = prepare(),
    source = prepared.document.source,
    first = prepared.document.resources[0]!;
  const wrong = "f".repeat(64);
  for (const candidate of [
    source.remove("/resources/0"),
    source.set("/resources/0/path", '"/document"'),
    source.set("/resources/0/byteCount", "-1"),
    source.set("/resources/0/extra", "true"),
    source.set("/resources/0/sha256", JSON.stringify(wrong)),
    source.set("/version", "2"),
    source.set("/extra", "null"),
    source.set("/document" + first.path + "/byteCount", "999"),
    source.set(
      "/document" + first.path + "/assetSHA256",
      JSON.stringify(wrong),
    ),
  ])
    expect(() => OwnedAuthorityDocument.read(candidate)).toThrow();
  const expanded = source.replaceValues(
    new Map(
      source.get("/resources")!.length
        ? prepared.document.resources.flatMap(
            (resource, i) =>
              [
                [
                  "/resources/" + i + "/byteCount",
                  LosslessJson.parse("8388608"),
                ],
                [
                  "/document" + resource.path + "/byteCount",
                  LosslessJson.parse("8388608"),
                ],
              ] as const,
          )
        : [],
    ),
  );
  expect(() => OwnedAuthorityDocument.read(expanded)).toThrow();
  expect(() =>
    prepared.document.materialize(() => new Uint8Array(), digest),
  ).toThrow();
  expect(() =>
    prepared.document.materialize(
      (key) =>
        new Uint8Array(
          prepared.assets().find((bytes) => digest(bytes) === key)!.length,
        ),
      digest,
    ),
  ).toThrow();
});

test("asset materialization verifies each unique resource once and passes copies to trusted hashing", () => {
  const prepared = prepare(),
    pool = new Map(prepared.assets().map((bytes) => [digest(bytes), bytes]));
  const reads: string[] = [];
  const restored = prepared.document.materialize(
    (key) => {
      reads.push(key);
      return pool.get(key)!;
    },
    (bytes) => {
      const hash = digest(bytes);
      bytes.fill(0);
      return hash;
    },
  );
  expect(reads.length).toBe(2);
  expect(restored.source.canonicalText()).toBe(original.canonicalText());
});

test("canonical resource admission caps unique objects and preserves large resource payloads without stack growth", () => {
  let source = original;
  for (let i = 0; i < 257; i++) {
    const bytes = Uint8Array.from([i & 255, i >>> 8]);
    source = source.set(
      "/profiles/0/appearanceResources/" + digest(bytes),
      JSON.stringify(encodeResourceBase64(bytes)),
    );
  }
  expect(() => prepare(source)).toThrow("invalid_owned_authority");
  const bytes = new Uint8Array(1024 * 1024).fill(91),
    key = digest(bytes);
  source = original.set(
    "/profiles/0/appearanceResources/" + key,
    JSON.stringify(encodeResourceBase64(bytes)),
  );
  const prepared = prepare(source);
  expect(
    prepared
      .assets()
      .some((value) => value.length === bytes.length && digest(value) === key),
  ).toBe(true);
  expect(materialize(prepared).source.canonicalText()).toBe(
    source.canonicalText(),
  );
});

test("portable Base64 encoder agrees with an independent host encoder across padding and byte values", () => {
  for (let size = 0; size <= 260; size++) {
    const bytes = Uint8Array.from({ length: size }, (_, i) => i & 255);
    expect(encodeResourceBase64(bytes)).toBe(
      Buffer.from(bytes).toString("base64"),
    );
    expect(decodeResourceBase64(encodeResourceBase64(bytes))).toEqual(bytes);
  }
});

test("SQLite canonical rows contain only external references and catalog edits preserve resources across reopen", () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-owned-authority-")),
    ),
    root = join(parent, "runtime");
  let repository: SqliteConfigurationRepository | undefined;
  try {
    const prepared = prepare(),
      id = prepared.document.catalog.profiles[0]!.id;
    repository = new SqliteConfigurationRepository(root, executable);
    repository.commit({
      operationId: "seed-authority",
      payloadHash: "a".repeat(64),
      expectedRevision: "0",
      source: prepared.document.source,
      affectedEntities: prepared.document.catalog.profiles.map((p) => p.id),
      assets: prepared.assets(),
    });
    expect(
      readdirSync(join(root, "assets-v1")).filter((name) =>
        name.startsWith("obj-"),
      ).length,
    ).toBe(2);
    const ops = new ConfigurationCatalogOperations(
      repository,
      (text) => createHash("sha256").update(text).digest("hex"),
      () => "100",
    );
    const command = {
      command: "configuration-rename-profile",
      operationId: "rename-authority",
      expectedRevision: "1",
      profileId: id,
      name: "Stored external assets",
    } as const;
    const renamed = ops.execute(command, { read: true, write: true });
    expect(renamed.kind).toBe("committed");
    if (renamed.kind !== "committed") throw new Error("test_commit_missing");
    repository.close();
    repository = new SqliteConfigurationRepository(root, executable);
    const reread = OwnedAuthorityDocument.read(repository.current()!.source),
      files = new FileAssetStore(root, executable);
    expect(reread.resources).toEqual(prepared.document.resources);
    const restored = reread.materialize((key) => files.read(key), digest);
    expect(restored.catalog.profiles[0]?.name).toBe(command.name);
    expect(restored.source.get("/profiles/1")?.text()).toBe(
      original.get("/profiles/1")?.text(),
    );
    const reopened = new ConfigurationCatalogOperations(
      repository,
      (text) => createHash("sha256").update(text).digest("hex"),
      () => {
        throw new Error("clock_must_not_run");
      },
    );
    expect(reopened.execute(command, { read: true, write: true })).toEqual({
      ...renamed,
      replayed: true,
    });
    expect(
      reopened.execute(
        { command: "configuration-list", expectedRevision: null, offset: 0 },
        { read: true, write: false },
      ).kind,
    ).toBe("catalog");
  } finally {
    repository?.close();
    rmSync(parent, { recursive: true, force: true });
  }
});

test("shared resources deduplicate across independent profile pools without merging profile identities", () => {
  const source = original
    .set("/profiles/1/appearanceResourceVersion", "1")
    .set(
      "/profiles/1/appearanceResources",
      original.get("/profiles/0/appearanceResources")!.text(),
    )
    .set(
      "/profiles/1/appearanceBank",
      original.get("/profiles/0/appearanceBank")!.text(),
    );
  const prepared = prepare(source);
  expect(prepared.document.catalog.profiles[0]?.id).not.toBe(
    prepared.document.catalog.profiles[1]?.id,
  );
  expect(prepared.document.resources.length).toBe(4);
  expect(prepared.assets().length).toBe(2);
  expect(materialize(prepared).source.canonicalText()).toBe(
    source.canonicalText(),
  );
});

test("reference multiplicity cannot amplify a small manifest into an oversized materialized document", () => {
  const reference = original.get(
    "/profiles/0/appearanceBank/variants/0/appearance/assetLibrary/assets/0/data",
  )!;
  const bytes = OwnedConfigurationDocument.read(
    original,
    digest,
  ).profiles[0]!.resources!.data(reference);
  const key = digest(bytes);
  const prepared = prepare(
    original.set(
      "/profiles/0/appearanceBank/variants/0/appearance/assetLibrary/assets/0/data",
      JSON.stringify(encodeResourceBase64(bytes)),
    ),
  );
  const edits = new Map<string, LosslessJson>();
  prepared.document.resources.forEach((resource, i) => {
    if (resource.sha256 === key) {
      edits.set(
        "/resources/" + i + "/byteCount",
        LosslessJson.parse("4194304"),
      );
      edits.set(
        "/document" + resource.path + "/byteCount",
        LosslessJson.parse("4194304"),
      );
    }
  });
  expect(edits.size).toBe(4);
  expect(() =>
    OwnedAuthorityDocument.read(prepared.document.source.replaceValues(edits)),
  ).toThrow("invalid_owned_authority");
});

test("stored authority agrees with the independently constructed format vector and raw numeric lexemes", () => {
  const vector = LosslessJson.parse(
    readFileSync(
      resolve(
        import.meta.dir,
        "../packages/fixtures/owned-authority-v1/vector.json",
      ),
      "utf8",
    ),
  );
  const source = vector.get("/interchange")!,
    prepared = prepare(source);
  expect(prepared.document.source.text()).toBe(
    vector.get("/authority")!.text(),
  );
  expect(prepared.assets()).toEqual([Uint8Array.from([0, 1, 2])]);
  expect(prepared.document.resources[0]?.sha256).toBe(
    vector.get("/assets/0/sha256")?.stringValue,
  );
  const restored = materialize(prepared);
  expect(restored.source.get("/opaque")?.text()).toBe(
    source.get("/opaque")?.text(),
  );
  expect(restored.source.get("/opaque/ratio")?.numberToken).toBe("1.2300e+99");
  expect(restored.source.canonicalText()).toBe(source.canonicalText());
});
