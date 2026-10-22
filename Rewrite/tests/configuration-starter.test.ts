import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { OwnedConfigurationDocument } from "@thumble/domain/owned-configuration";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { projectSavedController } from "@thumble/domain/saved-controller-map";
import { ConfigurationCatalogOperations } from "@thumble/application/configuration-catalog";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationInitializeStarterCommand,
} from "@thumble/contracts/configuration";
import { SqliteConfigurationRepository } from "@thumble/storage";
const digest = (v: string | Uint8Array) =>
  createHash("sha256").update(v).digest("hex");
const id = "e1000000-0000-0000-0000-000000000001";
const command: ConfigurationInitializeStarterCommand = {
  command: "configuration-initialize-starter",
  operationId: "starter-one",
  expectedRevision: "0",
  profileId: id,
  name: "My controller",
};
const access = { read: true, write: true };
const executable = resolve(
  import.meta.dir,
  "../native/receiver/target/debug/thumble-rewrite-receiver" +
    (process.platform === "win32" ? ".exe" : ""),
);

test("production starter v1 projects all18 controls across bounded landscape sizes without overlap", () => {
  const source = starterConfiguration(id, "Starter", "9007199254740993");
  expect(source.get("/profiles/0/updatedAt")?.numberToken).toBe(
    "9007199254740993",
  );
  const document = OwnedConfigurationDocument.read(source, digest);
  const pin = {
    profileId: id,
    authorityRevision: "1",
    sourceSha256: digest(source.text()),
  };
  const widths = [240, 320, 393, 432, 768, 1024, 4096];
  for (const height of widths)
    for (const ratio of [1, 1.1, 1.333, 1.775, 2.224, 3]) {
      const width = Math.min(4096, height * ratio);
      const result = projectSavedController(
        { document, authorityRevision: "1" },
        pin,
        { generation: "1", revision: "1" },
        { width, height },
        digest,
      );
      expect(result.map.controls.length).toBe(18);
      expect(new Set(result.map.controls.map((c) => c.action)).size).toBe(18);
      expect(
        result.map.controls.filter((c) => c.action.includes("StandardStick"))
          .length,
      ).toBe(2);
      expect(
        result.map.controls.filter((c) => c.action.includes("VerticalTrigger"))
          .length,
      ).toBe(2);
    }
  const preparation = OwnedAuthorityDocument.prepare(source, digest);
  expect(preparation.document.resources).toEqual([]);
  expect(preparation.assets()).toEqual([]);
  expect(preparation.document.catalog.activeProfileID).toBe(id);
  expect(preparation.document.catalog.defaultProfileID).toBe(id);
});

test("starter strict intent accepts only empty-revision, fixed shape and valid ids/names", () => {
  expect(
    decodeConfigurationCommand({ ...command, profileId: id.toUpperCase() }),
  ).toEqual(command);
  for (const invalid of [
    { expectedRevision: "1" },
    { expectedRevision: null },
    { extra: true },
    { profileId: "bad" },
    { name: " " },
    { name: "\ud800" },
  ])
    expect(() =>
      decodeConfigurationCommand({ ...command, ...invalid }),
    ).toThrow("invalid_configuration_request");
  expect(() => starterConfiguration(id, "test", "9223372036854775808")).toThrow(
    "configuration_clock_invalid",
  );
});

test("empty-authority starter commits once, replays after restart/edits and never overwrites existing state", () => {
  const parent = realpathSync(mkdtempSync(join(tmpdir(), "thumble-starter-")));
  let repository = new SqliteConfigurationRepository(
    join(parent, "runtime"),
    executable,
  );
  try {
    const operations = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => "1234",
    );
    for (const denied of [
      { read: false, write: true },
      { read: true, write: false },
    ])
      expect(() => operations.execute(command, denied)).toThrow(
        "configuration_access_denied",
      );
    expect(repository.current()).toBeUndefined();
    const result = operations.execute(command, access);
    expect(result.kind).toBe("committed");
    if (result.kind !== "committed") throw new Error("test_receipt_missing");
    expect(decodeConfigurationReply(result, command)).toEqual(result);
    for (const receipt of [
      { ...result.receipt, resultingRevision: "2" },
      { ...result.receipt, affectedEntities: ["configuration", "wrong"] },
    ])
      expect(() =>
        decodeConfigurationReply({ ...result, receipt }, command),
      ).toThrow("invalid_configuration_request");
    const original = repository.current()!;
    expect(OwnedAuthorityDocument.isAuthority(original.source)).toBe(true);
    expect(original.revision).toBe("1");
    expect(
      operations.execute({ ...command, operationId: "other" }, access),
    ).toEqual({ version: 1, kind: "conflict", currentRevision: "1" });
    expect(repository.current()?.source.text()).toBe(original.source.text());
    operations.execute(
      {
        command: "configuration-rename-profile",
        operationId: "rename",
        expectedRevision: "1",
        profileId: id,
        name: "Keep me",
      },
      access,
    );
    const after = repository.current()!.source.text();
    repository.close();
    repository = new SqliteConfigurationRepository(
      join(parent, "runtime"),
      executable,
    );
    const restarted = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => {
        throw new Error("replay_must_not_read_clock");
      },
    );
    expect(restarted.execute(command, access)).toEqual({
      ...result,
      replayed: true,
    });
    expect(() =>
      restarted.execute({ ...command, name: "Changed" }, access),
    ).toThrow("operation_id_reused");
    expect(
      restarted.execute({ ...command, operationId: "refuse" }, access),
    ).toEqual({ version: 1, kind: "conflict", currentRevision: "2" });
    expect(repository.current()?.source.text()).toBe(after);
  } finally {
    repository.close();
    rmSync(parent, { recursive: true, force: true });
  }
});

test("starter CLI and modern/legacy MCP initialize explicitly, refuse overwrite and replay across service restart", async () => {
  const { promisify } = await import("node:util");
  const { execFile } = await import("node:child_process");
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-starter-service-")),
  );
  try {
    const result = await promisify(execFile)(
      process.env.THUMBLE_REWRITE_NODE ?? "node",
      [
        resolve(
          import.meta.dir,
          "../tooling/test-configuration-starter-node.mjs",
        ),
        process.execPath,
        resolve(import.meta.dir, "../apps/cli/src/main.ts"),
        executable,
        join(parent, "runtime"),
      ],
      { timeout: 20000, maxBuffer: 65536, windowsHide: true },
    );
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toEqual({
      cli: true,
      modernMcp: true,
      legacyMcp: true,
      readonlyDenied: true,
      restartReplay: true,
      existingRefused: true,
      inputActivated: false,
    });
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}, 25000);

test("starter commit CAS preserves an authority appearing after the empty read", () => {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-starter-cas-")),
  );
  const repository = new SqliteConfigurationRepository(
    join(parent, "runtime"),
    executable,
  );
  try {
    const existing = OwnedAuthorityDocument.prepare(
      starterConfiguration(
        "e2000000-0000-0000-0000-000000000002",
        "Other",
        "1234",
      ).set("/opaqueFuture", '{"exact":9007199254740993.000}'),
      digest,
    ).document.source;
    const racing = {
      receipt: repository.receipt.bind(repository),
      commit: repository.commit.bind(repository),
      current: () => {
        const empty = repository.current();
        expect(empty).toBeUndefined();
        repository.commit({
          operationId: "winner",
          payloadHash: digest("winner"),
          expectedRevision: "0",
          source: existing,
          affectedEntities: ["configuration"],
        });
        return empty;
      },
    };
    const result = new ConfigurationCatalogOperations(
      racing,
      digest,
      () => "1235",
    ).execute(command, access);
    expect(result).toEqual({
      version: 1,
      kind: "conflict",
      currentRevision: "1",
    });
    expect(repository.current()?.source.text()).toBe(existing.text());
    expect(
      repository.receipt(command.operationId, digest("unused")),
    ).toBeUndefined();
  } finally {
    repository.close();
    rmSync(parent, { recursive: true, force: true });
  }
});
