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
const a = "10000000-0000-0000-0000-000000000001";
const b = "10000000-0000-0000-0000-000000000002";
const c = "10000000-0000-0000-0000-000000000003";
const executable = resolve(
  import.meta.dir,
  "../native/receiver/target/debug/thumble-rewrite-receiver" +
    (process.platform === "win32" ? ".exe" : ""),
);
const access = { read: true, write: true };
const digest = (value: string) =>
  createHash("sha256").update(value).digest("hex");
function intent(
  operationId = "delete-b",
  expectedRevision = "3",
): Extract<ConfigurationCommand, { command: "configuration-delete-profile" }> {
  return {
    command: "configuration-delete-profile",
    operationId,
    expectedRevision,
    profileId: b,
    activeProfileId: a,
    defaultProfileId: c,
  };
}
function fixture(
  run: (repository: SqliteConfigurationRepository, root: string) => void,
  duplicates = true,
) {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-profile-delete-")),
    ),
    root = join(parent, "runtime");
  const repository = new SqliteConfigurationRepository(root, executable);
  try {
    repository.commit({
      operationId: "delete-seed",
      payloadHash: "a".repeat(64),
      expectedRevision: "0",
      source: starterConfiguration(a, "First", "100").set(
        "/opaque",
        '{"large":999999999999999999999999999999,"exponent":1e9999,"negativeZero":-0.000}',
      ),
      affectedEntities: [a],
    });
    if (duplicates) {
      const operations = new ConfigurationCatalogOperations(
        repository,
        digest,
        () => "101",
      );
      for (const [id, revision] of [
        [b, "1"],
        [c, "2"],
      ] as const) {
        const result = operations.execute(
          {
            command: "configuration-duplicate-profile",
            operationId: "duplicate-" + revision,
            expectedRevision: revision,
            profileId: a,
            newProfileId: id,
            name: "Copy " + revision,
            select: false,
          },
          access,
        );
        expect(result.kind).toBe("committed");
      }
    }
    run(repository, root);
  } finally {
    repository.close();
    rmSync(parent, { recursive: true, force: true });
  }
}
const noClock = () => {
  throw Error("delete_must_not_read_clock");
};
test("profile deletion commits explicit saved selections and preserves exact surviving source without a clock", () =>
  fixture((repository) => {
    const before = repository.current()!.source;
    const result = new ConfigurationCatalogOperations(
      repository,
      digest,
      noClock,
    ).execute(intent(), access);
    expect(result.kind).toBe("committed");
    if (result.kind !== "committed") throw Error("test_result_invalid");
    expect(result.receipt.resultingRevision).toBe("4");
    expect(result.receipt.affectedEntities).toEqual(["configuration", b]);
    const after = repository.current()!.source;
    expect(after.get("/profiles")?.length).toBe(2);
    expect(after.get("/profiles/0")?.text()).toBe(
      before.get("/profiles/0")?.text(),
    );
    expect(after.get("/profiles/1")?.text()).toBe(
      before.get("/profiles/2")?.text(),
    );
    for (const path of ["/opaque", "/keyBindings", "/outputBindings"])
      expect(after.get(path)?.text()).toBe(before.get(path)?.text());
    expect(after.get("/activeProfileID")?.stringValue).toBe(a);
    expect(after.get("/defaultProfileID")?.stringValue).toBe(c);
    for (const name of ["profileKeyBindings", "profileOutputBindings"]) {
      expect(after.get(`/${name}/${b}`)).toBeUndefined();
      expect(after.get(`/${name}/${c}`)?.text()).toBe(
        before.get(`/${name}/${c}`)?.text(),
      );
    }
  }));
test("deletion receipt survives restart and a later invalid source without resurrecting its removed profile", () =>
  fixture((repository, root) => {
    const command = intent(),
      first = new ConfigurationCatalogOperations(
        repository,
        digest,
        noClock,
      ).execute(command, access);
    if (first.kind !== "committed") throw Error("test_result_invalid");
    repository.commit({
      operationId: "later-source",
      payloadHash: "b".repeat(64),
      expectedRevision: "4",
      source: LosslessJson.parse('{"later":"not a controller"}'),
      affectedEntities: ["configuration"],
    });
    repository.close();
    const reopened = new SqliteConfigurationRepository(root, executable);
    try {
      const operations = new ConfigurationCatalogOperations(
        reopened,
        digest,
        noClock,
      );
      expect(operations.execute(command, access)).toEqual({
        version: 1,
        kind: "committed",
        receipt: first.receipt,
        replayed: true,
      });
      expect(reopened.current()!.revision).toBe("5");
      expect(() =>
        operations.execute({ ...command, defaultProfileId: null }, access),
      ).toThrow("operation_id_reused");
    } finally {
      reopened.close();
    }
  }));
test("profile delete denies capabilities, stale revisions and deleted or missing replacements without mutation", () =>
  fixture((repository) => {
    const operations = new ConfigurationCatalogOperations(
      repository,
      digest,
      noClock,
    );
    for (const denied of [
      { read: false, write: true },
      { read: true, write: false },
    ])
      expect(() => operations.execute(intent(), denied)).toThrow(
        "configuration_access_denied",
      );
    expect(operations.execute(intent("stale-delete", "2"), access)).toEqual({
      version: 1,
      kind: "conflict",
      currentRevision: "3",
    });
    for (const changes of [
      { activeProfileId: b },
      { defaultProfileId: b },
      { activeProfileId: "ffffffff-ffff-ffff-ffff-ffffffffffff" },
      { profileId: "ffffffff-ffff-ffff-ffff-ffffffffffff" },
    ])
      expect(() =>
        operations.execute({ ...intent(), ...changes }, access),
      ).toThrow();
    expect(repository.current()!.revision).toBe("3");
  }));
test("last profile remains recoverable and final durable CAS cannot delete after an intervening commit", () => {
  fixture((repository) => {
    const operations = new ConfigurationCatalogOperations(
      repository,
      digest,
      noClock,
    );
    expect(() =>
      operations.execute(
        {
          ...intent("last-delete", "1"),
          profileId: a,
          activeProfileId: a,
          defaultProfileId: null,
        },
        access,
      ),
    ).toThrow("configuration_last_profile");
    expect(repository.current()!.revision).toBe("1");
  }, false);
  fixture((repository) => {
    const operations = new ConfigurationCatalogOperations(
      {
        current: () => repository.current(),
        receipt: (id, hash) => repository.receipt(id, hash),
        commit: (command) => {
          repository.commit({
            operationId: "delete-racer",
            payloadHash: "c".repeat(64),
            expectedRevision: "3",
            source: repository.current()!.source,
            affectedEntities: ["configuration"],
          });
          return repository.commit(command);
        },
      },
      digest,
      noClock,
    );
    expect(operations.execute(intent(), access)).toEqual({
      version: 1,
      kind: "conflict",
      currentRevision: "4",
    });
    expect(repository.current()!.source.get("/profiles")?.length).toBe(3);
    expect(repository.receipt("delete-b", "d".repeat(64))).toBeUndefined();
  });
});
