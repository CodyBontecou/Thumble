import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { LosslessJson } from "@thumble/contracts/json";
import type { ConfigurationCommand } from "@thumble/contracts/configuration";
import { ConfigurationCatalogOperations } from "@thumble/application/configuration-catalog";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
const profileId = "10000000-0000-0000-0000-000000000001";
const controlId = "ce000000-0000-0000-0000-000000000001";
const executable = resolve(
  import.meta.dir,
  "../native/receiver/target/debug/thumble-rewrite-receiver" +
    (process.platform === "win32" ? ".exe" : ""),
);
const access = { read: true, write: true };
const digest = (value: string) =>
  createHash("sha256").update(value).digest("hex");
function intent(
  label: string | null = "Jump",
  operationId = "label-edit",
  expectedRevision = "1",
): Extract<
  ConfigurationCommand,
  { command: "configuration-set-control-label" }
> {
  return {
    command: "configuration-set-control-label",
    operationId,
    expectedRevision,
    profileId,
    controlId,
    label,
  };
}
function fixture(
  run: (repository: SqliteConfigurationRepository, root: string) => void,
) {
  const parent = realpathSync(mkdtempSync(join(tmpdir(), "thumble-label-"))),
    root = join(parent, "runtime");
  const repository = new SqliteConfigurationRepository(root, executable);
  try {
    repository.commit({
      operationId: "seed-label",
      payloadHash: "a".repeat(64),
      expectedRevision: "0",
      source: starterConfiguration(profileId, "Authoring", "100").set(
        "/opaque",
        '{"large":999999999999999999999999999999,"exponent":1e9999,"negativeZero":-0.000}',
      ),
      affectedEntities: [profileId],
    });
    run(repository, root);
  } finally {
    repository.close();
    rmSync(parent, { recursive: true, force: true });
  }
}
test("targeted label commits preserve opaque source and issue distinct blank and clear receipts", () =>
  fixture((repository) => {
    const before = repository.current()!.source;
    const operations = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => "101",
    );
    const first = operations.execute(intent(), access);
    expect(first.kind).toBe("committed");
    if (first.kind !== "committed") throw Error("test_result_invalid");
    expect(first.receipt.resultingRevision).toBe("2");
    expect(first.receipt.affectedEntities).toEqual([profileId, controlId]);
    expect(repository.current()!.source.get("/opaque")?.text()).toBe(
      before.get("/opaque")?.text(),
    );
    expect(
      repository
        .current()!
        .source.get("/profiles/0/customization/elements")
        ?.text(),
    ).toBe(before.get("/profiles/0/customization/elements")?.text());
    const blank = operations.execute(intent("", "label-blank", "2"), access);
    expect(blank.kind === "committed" && blank.receipt.resultingRevision).toBe(
      "3",
    );
    const clear = operations.execute(intent(null, "label-clear", "3"), access);
    expect(clear.kind === "committed" && clear.receipt.resultingRevision).toBe(
      "4",
    );
    expect(repository.current()!.source.get("/opaque")?.text()).toBe(
      before.get("/opaque")?.text(),
    );
  }));
test("label receipts survive restart and replay before later source decoding or clock access", () =>
  fixture((repository, root) => {
    const operations = new ConfigurationCatalogOperations(
        repository,
        digest,
        () => "101",
      ),
      command = intent();
    const first = operations.execute(command, access);
    expect(first.kind).toBe("committed");
    if (first.kind !== "committed") throw Error("test_result_invalid");
    repository.commit({
      operationId: "later-unrelated",
      payloadHash: "b".repeat(64),
      expectedRevision: "2",
      source: LosslessJson.parse('{"later":"not a controller"}'),
      affectedEntities: ["configuration"],
    });
    repository.close();
    const reopened = new SqliteConfigurationRepository(root, executable);
    try {
      const replay = new ConfigurationCatalogOperations(
        reopened,
        digest,
        () => {
          throw Error("clock_must_not_run");
        },
      );
      expect(replay.execute(command, access)).toEqual({
        version: 1,
        kind: "committed",
        receipt: first.receipt,
        replayed: true,
      });
      expect(reopened.current()!.revision).toBe("3");
      expect(() => replay.execute(intent("Changed"), access)).toThrow(
        "operation_id_reused",
      );
    } finally {
      reopened.close();
    }
  }));
test("label writes enforce capabilities, stale revision and target validation without committing", () =>
  fixture((repository) => {
    const operations = new ConfigurationCatalogOperations(
      repository,
      digest,
      () => "99",
    );
    for (const denied of [
      { read: false, write: true },
      { read: true, write: false },
    ])
      expect(() => operations.execute(intent(), denied)).toThrow(
        "configuration_access_denied",
      );
    expect(
      operations.execute(intent("Jump", "stale-label", "0"), access),
    ).toEqual({ version: 1, kind: "conflict", currentRevision: "1" });
    expect(() =>
      operations.execute(
        { ...intent(), controlId: "ffffffff-ffff-ffff-ffff-ffffffffffff" },
        access,
      ),
    ).toThrow();
    expect(repository.current()!.revision).toBe("1");
    const changed = operations.execute(intent(), access);
    expect(changed.kind).toBe("committed");
    expect(
      repository.current()!.source.get("/profiles/0/updatedAt")?.numberToken,
    ).toBe("100");
  }));
test("label final durable CAS rejects an intervening writer without issuing its own receipt", () =>
  fixture((repository) => {
    let raced = false;
    const operations = new ConfigurationCatalogOperations(
      {
        current: () => repository.current(),
        receipt: (id, hash) => repository.receipt(id, hash),
        commit: (command) => {
          if (!raced) {
            raced = true;
            repository.commit({
              operationId: "concurrent-label-writer",
              payloadHash: "c".repeat(64),
              expectedRevision: "1",
              source: repository.current()!.source,
              affectedEntities: [profileId],
            });
          }
          return repository.commit(command);
        },
      },
      digest,
      () => "101",
    );
    expect(operations.execute(intent(), access)).toEqual({
      version: 1,
      kind: "conflict",
      currentRevision: "2",
    });
    expect(repository.current()!.revision).toBe("2");
    expect(repository.receipt("label-edit", "d".repeat(64))).toBeUndefined();
  }));
