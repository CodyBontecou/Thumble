import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import {
  decodeConfigurationCommand,
  decodeConfigurationReply,
  type ConfigurationCommand,
  type ConfigurationReply,
} from "@thumble/contracts/configuration";
import { ConfigurationCatalogOperations } from "@thumble/application/configuration-catalog";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { BoundedStdioTransport } from "../apps/cli/src/mcp-transport.ts";
import { PassThrough } from "node:stream";
const executable = resolve(
  import.meta.dir,
  `../native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
import {
  a,
  b,
  catalogFixtureSource as source,
} from "./helpers/configuration-fixture.ts";
const access = { read: true, write: true };
const digest = (payload: string) =>
  createHash("sha256").update(payload).digest("hex");
function fixture(run: (root: string) => void) {
  const parent = realpathSync(mkdtempSync(join(tmpdir(), "thumble-catalog-")));
  try {
    run(join(parent, "runtime"));
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}
const rename = (
  name = "New",
  operationId = "rename-a",
  expectedRevision = "1",
): ConfigurationCommand => ({
  command: "configuration-rename-profile",
  profileId: a.toUpperCase(),
  operationId,
  expectedRevision,
  name,
});
const list = (
  expectedRevision: string | null = null,
  offset = 0,
): ConfigurationCommand => ({
  command: "configuration-list",
  expectedRevision,
  offset,
});
function seed(repository: SqliteConfigurationRepository, next = source()) {
  repository.commit({
    operationId: "fixture-seed",
    payloadHash: "a".repeat(64),
    expectedRevision: "0",
    source: next,
    affectedEntities: [a, b],
  });
}

test("scoped metadata commits preserve opaque exact source, inactive profile identity and durable retries", () =>
  fixture((root) => {
    let repository = new SqliteConfigurationRepository(root, executable);
    const initial = source();
    seed(repository, initial);
    let clocks = 0;
    const ops = new ConfigurationCatalogOperations(repository, digest, () => {
      clocks++;
      return "100";
    });
    try {
      const changed = ops.execute(rename(), access);
      expect(changed.kind).toBe("committed");
      if (changed.kind !== "committed") throw new Error("test_result_invalid");
      expect(changed.receipt.resultingRevision).toBe("2");
      expect(changed.receipt.affectedEntities).toEqual([a]);
      expect(changed.replayed).toBe(false);
      const current = repository.current()!.source;
      expect(current.get("/profiles/0/name")?.stringValue).toBe("New");
      expect(current.get("/profiles/0/updatedAt")?.numberToken).toBe(
        "9223372036854775806",
      );
      for (const path of [
        "/opaque",
        "/profiles/0/customization",
        "/profiles/1",
        "/activeProfileID",
        "/defaultProfileID",
      ])
        expect(current.get(path)?.text()).toBe(initial.get(path)?.text());
      const later = ops.execute(rename("Later", "later", "2"), access);
      expect(later.kind).toBe("committed");
      repository.close();
      repository = new SqliteConfigurationRepository(root, executable);
      const reopened = new ConfigurationCatalogOperations(
        repository,
        digest,
        () => {
          throw new Error("clock_must_not_run");
        },
      );
      expect(reopened.execute(rename(), access)).toEqual({
        ...changed,
        replayed: true,
      });
      expect(repository.current()?.revision).toBe("3");
      expect(
        repository.current()?.source.get("/profiles/0/name")?.stringValue,
      ).toBe("Later");
      expect(clocks).toBe(2);
      expect(() => reopened.execute(rename("Changed payload"), access)).toThrow(
        "operation_id_reused",
      );
      expect(() =>
        reopened.execute(rename("New", "rename-a", "2"), access),
      ).toThrow("operation_id_reused");
    } finally {
      repository.close();
    }
  }));

test("capability denial precedes storage and replay; stale edits return a typed revision conflict", () =>
  fixture((root) => {
    const repository = new SqliteConfigurationRepository(root, executable);
    seed(repository);
    const ops = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => "100",
    );
    try {
      const conflict = ops.execute(rename("New", "stale", "0"), access);
      expect(conflict).toEqual({
        version: 1,
        kind: "conflict",
        currentRevision: "1",
      });
      expect(
        decodeConfigurationReply(
          conflict,
          decodeConfigurationCommand(rename("New", "stale", "0")),
        ),
      ).toEqual(conflict);
      expect(repository.receipt("stale", "b".repeat(64))).toBeUndefined();
      ops.execute(rename(), access);
      for (const command of [list(), rename()])
        expect(() =>
          ops.execute(command, { read: false, write: true }),
        ).toThrow("configuration_access_denied");
      expect(() => ops.execute(rename(), { read: true, write: false })).toThrow(
        "configuration_access_denied",
      );
      expect(ops.execute(list(), { read: true, write: false }).kind).toBe(
        "catalog",
      );
      expect(repository.current()?.revision).toBe("2");
    } finally {
      repository.close();
    }
  }));

test("catalog paging pins the source revision and bounds repeated MCP JSON encoding", async () => {
  let reply: ReturnType<ConfigurationCatalogOperations["execute"]> | undefined;
  fixture((root) => {
    const repository = new SqliteConfigurationRepository(root, executable);
    let next = source(33);
    for (let i = 0; i < 33; i++)
      next = next.set(
        `/profiles/${i}/name`,
        JSON.stringify("\u0000".repeat(256)),
      );
    seed(repository, next);
    const ops = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => "100",
    );
    try {
      reply = ops.execute(list(), access);
      expect(reply.kind).toBe("catalog");
      if (reply.kind !== "catalog") throw new Error("test_result_invalid");
      expect(reply.profiles.length).toBe(16);
      expect(reply.nextOffset).toBe(16);
      expect(decodeConfigurationReply(reply, list())).toEqual(reply);
      const second = ops.execute(list("1", 16), access);
      expect(second.kind === "catalog" && second.nextOffset).toBe(32);
      const third = ops.execute(list("1", 32), access);
      expect(third.kind === "catalog" && third.profiles.length).toBe(1);
      ops.execute(rename(), access);
      expect(ops.execute(list("1", 16), access)).toEqual({
        version: 1,
        kind: "conflict",
        currentRevision: "2",
      });
      expect(() => ops.execute(list("2", 33), access)).toThrow(
        "configuration_offset_invalid",
      );
    } finally {
      repository.close();
    }
  });
  const input = new PassThrough(),
    output = new PassThrough();
  const transport = new BoundedStdioTransport(input, output);
  let bytes = 0;
  output.on("data", (chunk) => (bytes += chunk.length));
  await transport.start();
  try {
    await transport.send({
      jsonrpc: "2.0",
      id: 1,
      result: {
        content: [{ type: "text", text: JSON.stringify(reply) }],
        structuredContent: { version: 1, ok: true, result: reply },
      },
    });
    expect(bytes).toBeGreaterThan(50000);
    expect(bytes).toBeLessThan(65536);
  } finally {
    await transport.close();
  }
});

test("empty ledger is readable, but rename cannot seed or overwrite arbitrary configuration", () =>
  fixture((root) => {
    const repository = new SqliteConfigurationRepository(root, executable);
    const ops = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => "100",
    );
    try {
      const reply = ops.execute(list(), access);
      expect(reply).toEqual({
        version: 1,
        kind: "catalog",
        revision: "0",
        contentHash: null,
        profiles: [],
        activeProfileId: null,
        defaultProfileId: null,
        nextOffset: null,
      });
      expect(decodeConfigurationReply(reply, list())).toEqual(reply);
      expect(() => ops.execute(rename("New", "new", "0"), access)).toThrow(
        "configuration_not_initialized",
      );
      seed(repository, LosslessJson.parse('{"not":"a configuration"}'));
      expect(() => ops.execute(list(), access)).toThrow(
        "invalid_configuration_catalog",
      );
      expect(() => ops.execute(rename(), access)).toThrow(
        "invalid_configuration_catalog",
      );
      expect(repository.current()?.revision).toBe("1");
    } finally {
      repository.close();
    }
  }));

test("same-name writes keep exact source and still persist an idempotent receipt", () =>
  fixture((root) => {
    const repository = new SqliteConfigurationRepository(root, executable);
    const initial = source();
    seed(repository, initial);
    const ops = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => "100",
    );
    try {
      const result = ops.execute(rename("First"), access);
      if (result.kind !== "committed") throw new Error("test_result_invalid");
      expect(
        result.kind === "committed" && result.receipt.resultingRevision,
      ).toBe("2");
      expect(repository.current()?.source.text()).toBe(initial.text());
      expect(ops.execute(rename("First"), access)).toEqual({
        ...result,
        replayed: true,
      });
    } finally {
      repository.close();
    }
  }));

test("command decoding rejects ambiguous accessors, extra capabilities, malformed IDs and invalid Unicode", () => {
  let invoked = false;
  const getter = {
    ...rename(),
    get name() {
      invoked = true;
      return "bad";
    },
  };
  for (const bad of [
    getter,
    { ...rename(), capability: "write" },
    { ...rename(), name: "\ud800" },
    { ...rename(), name: " " },
    { ...rename(), name: "🦊".repeat(257) },
    { ...rename(), expectedRevision: "01" },
    { ...rename(), profileId: "bad" },
    { ...list(), offset: NaN },
    { ...list(), offset: 256 },
  ])
    expect(() => decodeConfigurationCommand(bad)).toThrow();
  expect(invoked).toBe(false);
  const command = decodeConfigurationCommand(rename("🦊".repeat(256)));
  expect(
    command.command === "configuration-rename-profile" && command.profileId,
  ).toBe(a);
  expect(Object.isFrozen(command)).toBe(true);
});

test("response validation rejects mismatched receipts, stale pages and unsolicited source data", () => {
  const command = decodeConfigurationCommand(rename());
  const good = {
    version: 1,
    kind: "committed",
    replayed: false,
    receipt: {
      version: 1,
      operationId: "rename-a",
      resultingRevision: "2",
      contentHash: "a".repeat(64),
      affectedEntities: [a],
    },
  } satisfies ConfigurationReply;
  expect(decodeConfigurationReply(good, command)).toEqual(good);
  for (const receipt of [
    { ...good.receipt, operationId: "different" },
    { ...good.receipt, resultingRevision: "3" },
    { ...good.receipt, affectedEntities: [b] },
    { ...good.receipt, contentHash: "bad" },
    { ...good.receipt, source: "private" },
  ])
    expect(() =>
      decodeConfigurationReply({ ...good, receipt }, command),
    ).toThrow();
  expect(() => decodeConfigurationReply(good, list())).toThrow();
  expect(() =>
    decodeConfigurationReply(
      { version: 1, kind: "conflict", currentRevision: "1" },
      command,
    ),
  ).toThrow();
  expect(() => decodeConfigurationCommand(list(null, 16))).toThrow();
});
