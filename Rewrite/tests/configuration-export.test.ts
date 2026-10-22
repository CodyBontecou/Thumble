import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { once } from "node:events";
import { join, resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationExportCommand,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";
import { ConfigurationExportOperations } from "@thumble/application/configuration-export";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import {
  SqliteConfigurationRepository,
  configurationSourceHash,
} from "@thumble/storage";
import { FileAssetStore } from "@thumble/storage/asset-files";
import { publishConfigurationFile } from "../apps/service/src/configuration-export-files.ts";
import { ConfigurationOwner } from "../apps/service/src/configuration-owner.ts";
import { expectError } from "./helpers/rejection.ts";
const root = resolve(import.meta.dir, ".."),
  cli = join(root, "apps/cli/src/main.ts"),
  executable = join(
    root,
    `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
  );
const digest = (bytes: string | Uint8Array) =>
  createHash("sha256").update(bytes).digest("hex");
const source = () =>
  LosslessJson.parse(
    readFileSync(
      join(root, "packages/fixtures/owned-configuration-v1/document.json"),
      "utf8",
    ),
  )
    .set("/futureRootMetadata/exportNumber", "9007199254740993.0000")
    .set("/futureRootMetadata/padding", JSON.stringify("x".repeat(131072)));
const access = { read: true, write: true };
async function fixture(
  run: (parent: string, directory: string) => void | Promise<void>,
) {
  const parent = realpathSync(mkdtempSync(join(tmpdir(), "thumble-export-")));
  try {
    await run(parent, join(parent, "runtime"));
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}
async function close(owner: ConfigurationOwner) {
  const exited =
    owner.child.exitCode !== null || owner.child.signalCode !== null
      ? Promise.resolve()
      : once(owner.child, "exit");
  owner.disconnect();
  const timer = setTimeout(() => owner.child.kill("SIGKILL"), 3000);
  try {
    await exited;
  } finally {
    clearTimeout(timer);
  }
}
const status = (
  command: ConfigurationExportCommand,
): ConfigurationExportCommand => ({
  ...command,
  command: "configuration-export-status",
});
async function completed(
  owner: ConfigurationOwner,
  command: ConfigurationExportCommand,
): Promise<ConfigurationReply> {
  const deadline = performance.now() + 10000;
  for (;;) {
    const result = await owner.request(status(command));
    if (result.kind !== "export-pending") return result;
    if (performance.now() > deadline) throw new Error("test_export_timeout");
    await Bun.sleep(20);
  }
}
function seed(repository: SqliteConfigurationRepository, input = source()) {
  const prepared = OwnedAuthorityDocument.prepare(input, digest);
  return repository.commit({
    operationId: "seed-export",
    expectedRevision: "0",
    payloadHash: digest(input.text()),
    source: prepared.document.source,
    assets: prepared.assets(),
    affectedEntities: ["configuration"],
  }).receipt;
}

test("export pins saved authority, materializes every verified asset and preserves opaque numbers without mutating authority", async () =>
  fixture((parent, directory) => {
    const repository = new SqliteConfigurationRepository(directory, executable),
      original = source(),
      receipt = seed(repository, original),
      assets = new FileAssetStore(directory, executable),
      path = join(parent, "saved.json");
    const command: ConfigurationExportCommand = {
      command: "configuration-export-file",
      operationId: "export-all",
      expectedRevision: receipt.resultingRevision,
      expectedSourceHash: receipt.contentHash,
      path,
    };
    let reads = 0,
      writes = 0;
    const exports = new ConfigurationExportOperations(repository, {
      encode: (text) => Buffer.from(text, "utf8"),
      readAsset: (hash) => {
        reads++;
        return assets.read(hash);
      },
      sourceHash: configurationSourceHash,
      resourceHash: digest,
      publish: (path, bytes) => {
        writes++;
        return publishConfigurationFile(executable, path, bytes);
      },
    });
    try {
      for (const access of [
        { read: false, write: true },
        { read: true, write: false },
      ])
        expect(() => exports.execute(command, access)).toThrow(
          "configuration_access_denied",
        );
      expect(
        exports.execute({ ...command, expectedRevision: "0" }, access),
      ).toEqual({ version: 1, kind: "conflict", currentRevision: "1" });
      expect(() =>
        exports.execute(
          { ...command, expectedSourceHash: "f".repeat(64) },
          access,
        ),
      ).toThrow("configuration_source_changed");
      expect(reads).toBe(0);
      expect(writes).toBe(0);
      const result = exports.execute(command, access);
      expect(result.kind).toBe("exported");
      if (result.kind !== "exported") throw new Error("test_export_missing");
      expect(decodeConfigurationReply(result, command)).toEqual(result);
      expect(result.replayed).toBe(false);
      expect(result.revision).toBe("1");
      expect(result.sourceHash).toBe(receipt.contentHash);
      const bytes = readFileSync(path),
        restored = LosslessJson.parse(bytes.toString("utf8"));
      expect(result.artifactHash).toBe(digest(bytes));
      expect(result.byteCount).toBe(bytes.length);
      expect(restored.canonicalText()).toBe(original.canonicalText());
      expect(restored.text()).toContain("9007199254740993.0000");
      expect(reads).toBeGreaterThan(1);
      expect(JSON.stringify(result)).not.toContain(path);
      expect(JSON.stringify(result)).not.toContain("profiles");
      expect(exports.execute(command, access)).toEqual({
        ...result,
        replayed: true,
      });
      writeFileSync(path, "unrelated user file");
      expect(() => exports.execute(command, access)).toThrow(
        "configuration_export_exists",
      );
      expect(readFileSync(path, "utf8")).toBe("unrelated user file");
      expect(repository.current()?.revision).toBe("1");
      expect(repository.current()?.contentHash).toBe(receipt.contentHash);
    } finally {
      repository.close();
    }
  }));

test("export fails closed on missing or corrupted stored assets before publishing output", async () =>
  fixture((parent, directory) => {
    const repository = new SqliteConfigurationRepository(directory, executable),
      receipt = seed(repository);
    let writes = 0;
    const command: ConfigurationExportCommand = {
      command: "configuration-export-file",
      operationId: "bad-asset",
      expectedRevision: "1",
      expectedSourceHash: receipt.contentHash,
      path: join(parent, "saved.json"),
    };
    try {
      for (const readAsset of [
        () => {
          throw new Error("asset_file_unavailable");
        },
        () => new Uint8Array(4),
      ]) {
        const exports = new ConfigurationExportOperations(repository, {
          encode: (text) => Buffer.from(text, "utf8"),
          readAsset,
          resourceHash: digest,
          sourceHash: configurationSourceHash,
          publish: () => {
            writes++;
            throw new Error("test_unexpected_publish");
          },
        });
        expect(() => exports.execute(command, access)).toThrow();
      }
      expect(writes).toBe(0);
      expect(repository.current()?.revision).toBe("1");
    } finally {
      repository.close();
    }
  }));

test(
  "export jobs share bounded owner exclusion and verify file replay after restart; changed authority conflicts",
  async () =>
    fixture(async (parent, directory) => {
      let repository = new SqliteConfigurationRepository(directory, executable);
      const receipt = seed(repository);
      repository.close();
      let owner = new ConfigurationOwner(executable, directory, [
        process.execPath,
        cli,
      ]);
      const command: ConfigurationExportCommand = {
        command: "configuration-export-file",
        operationId: "export-job",
        expectedRevision: "1",
        expectedSourceHash: receipt.contentHash,
        path: join(parent, "saved.json"),
      };
      try {
        await owner.ready;
        expect((await owner.request(command)).kind).toBe("export-pending");
        await expectError(
          owner.request({ ...command, path: join(parent, "other.json") }),
          "operation_id_reused",
        );
        await expectError(
          owner.request({
            command: "configuration-import-file",
            operationId: "import-during-export",
            expectedRevision: "1",
            expectedSourceHash: digest("other"),
            path: join(parent, "input.json"),
          }),
          "configuration_owner_busy",
        );
        const result = await completed(owner, command);
        expect(result.kind).toBe("exported");
        if (result.kind !== "exported") throw new Error("test_export_missing");
        await close(owner);
        owner = new ConfigurationOwner(executable, directory, [
          process.execPath,
          cli,
        ]);
        await owner.ready;
        await expectError(
          owner.request(status(command)),
          "configuration_export_unknown",
        );
        await owner.request(command);
        expect(await completed(owner, command)).toEqual({
          ...result,
          replayed: true,
        });
        writeFileSync(command.path, "other output");
        await owner.request(command);
        expect(await completed(owner, command)).toEqual({
          version: 1,
          kind: "export-failed",
          operationId: command.operationId,
          error: "configuration_export_exists",
        });
        expect(readFileSync(command.path, "utf8")).toBe("other output");
        rmSync(command.path);
        await owner.request(command);
        const restored = await completed(owner, command);
        expect(restored.kind).toBe("exported");
        if (restored.kind === "exported") expect(restored.replayed).toBe(false);
        const catalog = await owner.request({
          command: "configuration-list",
          expectedRevision: null,
          offset: 0,
        });
        if (catalog.kind !== "catalog") throw new Error("test_catalog_missing");
        await owner.request({
          command: "configuration-rename-profile",
          operationId: "rename-after-export",
          expectedRevision: "1",
          profileId: catalog.profiles[0]!.id,
          name: "Changed",
        });
        await owner.request(command);
        expect(await completed(owner, command)).toEqual({
          version: 1,
          kind: "conflict",
          currentRevision: "2",
        });
        expect(
          LosslessJson.parse(
            readFileSync(command.path, "utf8"),
          ).canonicalText(),
        ).toBe(source().canonicalText());
      } finally {
        await close(owner);
      }
    }),
  15000,
);

test("export contracts reject leaked paths, unbound results and malformed artifacts", () => {
  const command: ConfigurationExportCommand = {
    command: "configuration-export-file",
    operationId: "export",
    expectedRevision: "1",
    expectedSourceHash: "a".repeat(64),
    path: "/explicit/saved.json",
  };
  const result = {
    version: 1,
    kind: "exported",
    operationId: "export",
    revision: "1",
    sourceHash: "a".repeat(64),
    artifactHash: "b".repeat(64),
    byteCount: 123,
    replayed: false,
  } as const;
  expect(decodeConfigurationReply(result, command)).toEqual(result);
  for (const bad of [
    { ...result, path: command.path },
    { ...result, revision: "2" },
    { ...result, sourceHash: "b".repeat(64) },
    { ...result, operationId: "other" },
    { ...result, byteCount: 8 * 1024 * 1024 + 1 },
    {
      version: 1,
      kind: "export-failed",
      operationId: "export",
      error: command.path,
    },
  ])
    expect(() => decodeConfigurationReply(bad, command)).toThrow();
  for (const bad of [
    { ...command, path: "x\0" },
    { ...command, expectedSourceHash: "raw" },
    { ...command, source: "raw" },
  ])
    expect(() => decodeConfigurationCommand(bad)).toThrow();
});

test.skipIf(process.platform === "win32")(
  "export start/status remain responsive beyond the ordinary child request deadline",
  async () =>
    fixture(async (parent, directory) => {
      const repository = new SqliteConfigurationRepository(
          directory,
          executable,
        ),
        receipt = seed(repository);
      repository.close();
      const owner = new ConfigurationOwner(executable, directory, [
        process.execPath,
        cli,
      ]);
      const command: ConfigurationExportCommand = {
        command: "configuration-export-file",
        operationId: "slow-export",
        expectedRevision: "1",
        expectedSourceHash: receipt.contentHash,
        path: join(parent, "saved.json"),
      };
      let stopped = false;
      try {
        await owner.ready;
        expect(owner.child.kill("SIGSTOP")).toBe(true);
        stopped = true;
        const started = performance.now();
        expect((await owner.request(command)).kind).toBe("export-pending");
        expect(performance.now() - started).toBeLessThan(500);
        expect((await owner.request(command)).kind).toBe("export-pending");
        await expectError(
          owner.request({
            command: "configuration-list",
            expectedRevision: null,
            offset: 0,
          }),
          "configuration_owner_busy",
        );
        do {
          const poll = performance.now();
          expect((await owner.request(status(command))).kind).toBe(
            "export-pending",
          );
          expect(performance.now() - poll).toBeLessThan(100);
          await Bun.sleep(100);
        } while (performance.now() - started < 2300);
        expect(owner.child.kill("SIGCONT")).toBe(true);
        stopped = false;
        expect((await completed(owner, command)).kind).toBe("exported");
      } finally {
        if (stopped) owner.child.kill("SIGCONT");
        await close(owner);
      }
    }),
  15000,
);

test("legacy inline saved configuration exports without discarding any source spans", async () =>
  fixture((parent, directory) => {
    const repository = new SqliteConfigurationRepository(directory, executable),
      input = source();
    const receipt = repository.commit({
      operationId: "legacy-seed",
      payloadHash: digest(input.text()),
      expectedRevision: "0",
      source: input,
      affectedEntities: ["configuration"],
    }).receipt;
    const command: ConfigurationExportCommand = {
      command: "configuration-export-file",
      operationId: "inline-export",
      expectedRevision: "1",
      expectedSourceHash: receipt.contentHash,
      path: join(parent, "inline.json"),
    };
    const exports = new ConfigurationExportOperations(repository, {
      encode: (text) => Buffer.from(text, "utf8"),
      readAsset: () => {
        throw new Error("test_unexpected_asset_read");
      },
      resourceHash: digest,
      sourceHash: configurationSourceHash,
      publish: (path, bytes) =>
        publishConfigurationFile(executable, path, bytes),
    });
    try {
      expect(exports.execute(command, access).kind).toBe("exported");
      expect(readFileSync(command.path, "utf8")).toBe(input.text());
      expect(repository.current()?.revision).toBe("1");
    } finally {
      repository.close();
    }
  }));
