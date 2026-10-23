import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { ConfigurationCatalogOperations } from "@thumble/application/configuration-catalog";
import { ConfigurationExportOperations } from "@thumble/application/configuration-export";
import { ConfigurationImportOperations } from "@thumble/application/configuration-import";
import {
  SqliteConfigurationRepository,
  configurationSourceHash,
} from "@thumble/storage";
import { readConfigurationFile } from "@thumble/client/local";
import { publishConfigurationFile } from "../apps/service/src/configuration-export-files.ts";
import {
  a,
  b,
  firstControl,
  secondControl,
  selectionFixtureSource,
} from "./helpers/selection-fixture.ts";
const digest = (value: string | Uint8Array) =>
    createHash("sha256").update(value).digest("hex"),
  executable = resolve(
    import.meta.dir,
    `../native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
  );
const access = { read: true, write: true };
function fixture(run: (runtime: string) => void) {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-selection-mirrors-")),
  );
  try {
    run(join(parent, "runtime"));
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}
function selected(source: LosslessJson): LosslessJson {
  return ConfigurationCatalog.read(source).selectProfiles(b, null).source;
}

test("same-active selection repairs stale mirrors from independent exact stored maps and canonicalizes only selected profile aliases", () => {
  const original = selectionFixtureSource()
    .set("/profiles/1/id", JSON.stringify(b.toUpperCase()))
    .set("/keyBindings", "{}")
    .set("/outputBindings", "{}");
  OwnedConfigurationDocument.read(original, digest);
  const changed = selected(original);
  expect(changed.get("/keyBindings")?.text()).toBe(
    original.get(`/profileKeyBindings/${b}`)?.text(),
  );
  expect(changed.get("/outputBindings")?.text()).toBe(
    original.get(`/profileOutputBindings/${b}`)?.text(),
  );
  expect(changed.get(`/profileKeyBindings/${b}`)).toBeUndefined();
  expect(changed.get(`/profileOutputBindings/${b}`)).toBeUndefined();
  expect(changed.get(`/profileKeyBindings/${b.toUpperCase()}`)?.text()).toBe(
    original.get(`/profileKeyBindings/${b}`)?.text(),
  );
  expect(changed.get(`/profileOutputBindings/${b.toUpperCase()}`)?.text()).toBe(
    original.get(`/profileOutputBindings/${b}`)?.text(),
  );
  for (const path of [
    "/profiles",
    "/opaque",
    `/profileKeyBindings/${a}`,
    `/profileOutputBindings/${a}`,
  ])
    expect(changed.get(path)?.text()).toBe(original.get(path)?.text());
  OwnedConfigurationDocument.read(changed, digest);
  expect(
    ConfigurationCatalog.read(changed).selectProfiles(b, null).source,
  ).toBe(changed);
});

test("present empty/sparse binding maps win independently; absent maps use only selected-control initial primary outputs", () => {
  const original = selectionFixtureSource(),
    upper = secondControl.toUpperCase();
  for (const [missing, present, mirror, expected] of [
    [
      "profileOutputBindings",
      "profileKeyBindings",
      "outputBindings",
      {
        [upper]: {
          keyboard: { keyCode: 20, modifiers: 2 },
          gamepadButtons: ["south"],
        },
      },
    ],
    [
      "profileKeyBindings",
      "profileOutputBindings",
      "keyBindings",
      { [upper]: { keyCode: 20, modifiers: 2 } },
    ],
  ] as const) {
    const input = original
      .remove(`/${missing}/${b}`)
      .set(`/${present}/${b}`, "{}");
    const changed = selected(input);
    expect(JSON.parse(changed.get("/" + mirror)!.text())).toEqual(expected);
    expect(
      changed
        .get(
          present === "profileKeyBindings" ? "/keyBindings" : "/outputBindings",
        )
        ?.text(),
    ).toBe("{}");
    expect(changed.get(`/${missing}/${b}`)?.text()).toBe(
      changed.get("/" + mirror)?.text(),
    );
    expect(changed.get(`/${present}/${b}`)?.text()).toBe("{}");
    OwnedConfigurationDocument.read(changed, digest);
  }
  const empty = selected(
    original
      .set(`/profileKeyBindings/${b}`, "{}")
      .set(`/profileOutputBindings/${b}`, "{}"),
  );
  expect(empty.get("/keyBindings")?.text()).toBe("{}");
  expect(empty.get("/outputBindings")?.text()).toBe("{}");
});

test("fallback preserves explicit empty configured outputs, defaults/sequences and primary scope without mode filtering or part merging", () => {
  const defaultOnly = "de000000-0000-0000-0000-000000000003",
    partOnly = "df000000-0000-0000-0000-000000000004";
  const input = selectionFixtureSource()
    .remove(`/profileKeyBindings/${b}`)
    .remove(`/profileOutputBindings/${b}`)
    .set("/profiles/1/customization/elements/0/output", '{"gamepadButtons":[]}')
    .set(
      "/profiles/1/customization/elements/-",
      JSON.stringify({
        id: defaultOnly,
        kind: "button",
        defaultOutput: {
          keyboard: {
            keyCode: 99,
            modifiersRawValue: 0,
            sequence: [
              { keyCode: 13, modifiersRawValue: 4 },
              { keyCode: 0, modifiersRawValue: 2 },
            ],
          },
          gamepadButtons: ["north"],
        },
      }),
    )
    .set(
      "/profiles/1/customization/elements/-",
      JSON.stringify({
        id: partOnly,
        kind: "button",
        partOutputs: [
          "primary",
          {
            keyboard: { keyCode: 42, modifiersRawValue: 0 },
            gamepadButtons: ["home"],
          },
        ],
      }),
    );
  OwnedConfigurationDocument.read(input, digest);
  const changed = selected(input),
    keyboard = {
      keyCode: 13,
      modifiers: 4,
      sequence: [
        { keyCode: 13, modifiers: 4 },
        { keyCode: 0, modifiers: 2 },
      ],
    };
  expect(JSON.parse(changed.get("/keyBindings")!.text())).toEqual({
    [defaultOnly.toUpperCase()]: keyboard,
  });
  expect(JSON.parse(changed.get("/outputBindings")!.text())).toEqual({
    [secondControl.toUpperCase()]: { gamepadButtons: [] },
    [defaultOnly.toUpperCase()]: { keyboard, gamepadButtons: ["north"] },
  });
  expect(changed.get("/profiles")?.text()).toBe(input.get("/profiles")?.text());
  OwnedConfigurationDocument.read(changed, digest);
});

test("selection cannot commit metadata-only/ambiguous/dangling control maps or borrow previous root bindings", () =>
  fixture((runtime) => {
    const repository = new SqliteConfigurationRepository(runtime, executable),
      source = selectionFixtureSource().remove(
        "/profiles/1/customization/elements",
      );
    repository.commit({
      operationId: "seed",
      expectedRevision: "0",
      payloadHash: digest("seed"),
      source,
      affectedEntities: ["configuration"],
    });
    const operations = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => {
        throw new Error("test_no_clock");
      },
    );
    try {
      expect(() =>
        operations.execute(
          {
            command: "configuration-select-profiles",
            operationId: "unsupported",
            expectedRevision: "1",
            activeProfileId: b,
            defaultProfileId: null,
          },
          access,
        ),
      ).toThrow("invalid_owned_configuration");
      expect(repository.current()?.revision).toBe("1");
    } finally {
      repository.close();
    }
    for (const malformed of [
      selectionFixtureSource().set(
        `/profileKeyBindings/${b.toUpperCase()}`,
        "{}",
      ),
      selectionFixtureSource().set(
        `/profileOutputBindings/${b}/${firstControl}`,
        "{}",
      ),
    ])
      expect(() => selected(malformed)).toThrow("invalid_owned_configuration");
  }));

test("disjoint control selection repairs failed owned read/materialization/export and survives verified export/reimport", () =>
  fixture((runtime) => {
    const original = selectionFixtureSource(),
      prepared = OwnedAuthorityDocument.prepare(original, digest),
      broken = prepared.document.source.set(
        "/document/activeProfileID",
        JSON.stringify(a),
      );
    const selectorOnly = original.set("/activeProfileID", JSON.stringify(a));
    expect(() => OwnedConfigurationDocument.read(selectorOnly, digest)).toThrow(
      "invalid_owned_configuration",
    );
    expect(() =>
      OwnedAuthorityDocument.read(broken).materialize(() => {
        throw new Error("test_no_resource_io");
      }, digest),
    ).toThrow("invalid_owned_configuration");
    const repository = new SqliteConfigurationRepository(runtime, executable),
      receipt = repository.commit({
        operationId: "seed-broken",
        expectedRevision: "0",
        payloadHash: digest("broken"),
        source: broken,
        affectedEntities: ["configuration"],
      }).receipt;
    const path = join(dirname(runtime), "selected.json");
    let published = 0;
    const exports = new ConfigurationExportOperations(repository, {
      encode: (text) => Buffer.from(text, "utf8"),
      readAsset: () => {
        throw new Error("test_no_resource_io");
      },
      resourceHash: digest,
      sourceHash: configurationSourceHash,
      publish: (path, bytes) => {
        published++;
        return publishConfigurationFile(executable, path, bytes);
      },
    });
    try {
      expect(() =>
        exports.execute(
          {
            command: "configuration-export-file",
            operationId: "before-fix",
            expectedRevision: "1",
            expectedSourceHash: receipt.contentHash,
            path,
          },
          access,
        ),
      ).toThrow("invalid_owned_configuration");
      expect(published).toBe(0);
      const operations = new ConfigurationCatalogOperations(
          repository,
          digest,
          () => {
            throw new Error("test_no_clock");
          },
        ),
        result = operations.execute(
          {
            command: "configuration-select-profiles",
            operationId: "repair-active",
            expectedRevision: "1",
            activeProfileId: a,
            defaultProfileId: null,
          },
          access,
        );
      expect(result.kind).toBe("committed");
      if (result.kind !== "committed") throw new Error("test_receipt_missing");
      expect(
        exports.execute(
          {
            command: "configuration-export-file",
            operationId: "after-fix",
            expectedRevision: "2",
            expectedSourceHash: result.receipt.contentHash,
            path,
          },
          access,
        ).kind,
      ).toBe("exported");
      const exported = readConfigurationFile(path);
      OwnedConfigurationDocument.read(exported, digest);
      expect(exported.get("/profiles")?.text()).toBe(
        original.get("/profiles")?.text(),
      );
      expect(exported.get("/keyBindings")?.text()).toBe(
        original.get(`/profileKeyBindings/${a}`)?.text(),
      );
      const imported = new SqliteConfigurationRepository(
        join(dirname(runtime), "imported"),
        executable,
      );
      try {
        const imports = new ConfigurationImportOperations(imported, {
          readFile: readConfigurationFile,
          digest,
          sourceHash: configurationSourceHash,
          resourceHash: digest,
        });
        expect(
          imports.execute(
            {
              command: "configuration-import-file",
              operationId: "import-selected",
              expectedRevision: "0",
              expectedSourceHash: configurationSourceHash(exported),
              path,
            },
            access,
          ).kind,
        ).toBe("import-committed");
        expect(
          OwnedAuthorityDocument.read(imported.current()!.source)
            .materialize(() => {
              throw new Error("test_no_resource_io");
            }, digest)
            .source.canonicalText(),
        ).toBe(exported.canonicalText());
      } finally {
        imported.close();
      }
      expect(readFileSync(path, "utf8")).toBe(exported.text());
    } finally {
      repository.close();
    }
  }));

test("canonical v5 saved selection rejects retired secondary layout fields before any commit", () => {
  for (const field of [
    "landscapeCustomization",
    "portraitCustomization",
  ] as const)
    fixture((runtime) => {
      const original = selectionFixtureSource(),
        customization = original.get("/profiles/1/customization")!,
        source = original.set(`/profiles/1/${field}`, customization.text());
      const repository = new SqliteConfigurationRepository(runtime, executable);
      repository.commit({
        operationId: "legacy-seed",
        expectedRevision: "0",
        payloadHash: digest(field),
        source,
        affectedEntities: ["configuration"],
      });
      const operations = new ConfigurationCatalogOperations(
        repository,
        digest,
        () => {
          throw new Error("test_no_clock");
        },
      );
      try {
        expect(() =>
          operations.execute(
            {
              command: "configuration-select-profiles",
              operationId: "reject-retired-layout",
              expectedRevision: "1",
              activeProfileId: b,
              defaultProfileId: null,
            },
            access,
          ),
        ).toThrow("invalid_configuration_catalog");
        expect(repository.current()?.revision).toBe("1");
        expect(repository.current()?.source.text()).toBe(source.text());
        expect(() =>
          ConfigurationCatalog.read(
            original.set(`/profiles/1/${field}`, "null"),
          ),
        ).toThrow("invalid_configuration_catalog");
      } finally {
        repository.close();
      }
    });
});
