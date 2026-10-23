import { expect, test } from "bun:test";
import { Database } from "bun:sqlite";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  realpathSync,
  rmSync,
  readFileSync,
  statSync,
  linkSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import {
  SqliteConfigurationRepository,
  configurationSourceHash,
} from "@thumble/storage";
import { LosslessJson } from "@thumble/contracts/json";
import { ConfigurationRevisionConflict } from "@thumble/application/configuration-store";
const executable = resolve(
  import.meta.dir,
  `../native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
const source = LosslessJson.parse(
  ' {"profile":"a", "opaque":18446744073709551615} ',
);
function fixture(run: (root: string, path: string) => void) {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-configuration-")),
    ),
    root = join(parent, "runtime");
  try {
    run(root, join(root, "configuration-v1.sqlite3"));
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}
const command = (
  id: string,
  revision: string,
  next = source,
  hash = "a".repeat(64),
) => ({
  operationId: id,
  expectedRevision: revision,
  payloadHash: hash,
  source: next,
  affectedEntities: ["profile-a"],
});

test("SQLite commits exact configuration source and receipts durably in a native-private directory", () =>
  fixture((root, path) => {
    let repository = new SqliteConfigurationRepository(root, executable);
    try {
      expect(repository.current()).toBeUndefined();
      const result = repository.commit(command("first", "0"));
      expect(result.replayed).toBe(false);
      expect(result.receipt.resultingRevision).toBe("1");
      expect(result.receipt.contentHash).toBe(
        createHash("sha256")
          .update("thumble-lossless-json-v1\0")
          .update(source.canonicalText())
          .digest("hex"),
      );
      repository.close();
      repository = new SqliteConfigurationRepository(root, executable);
      expect(repository.current()?.source.text()).toBe(source.text());
      expect(repository.current()?.contentHash).toBe(
        configurationSourceHash(source),
      );
      expect(repository.receipt("first", "a".repeat(64))).toEqual(
        result.receipt,
      );
      if (process.platform !== "win32") {
        expect(statSync(root).mode & 0o777).toBe(0o700);
        expect(statSync(path).mode & 0o777).toBe(0o600);
      }
    } finally {
      repository.close();
    }
  }));

test("retries return the original receipt after later writes; changed operation payloads cannot write", () =>
  fixture((root) => {
    const repository = new SqliteConfigurationRepository(root, executable);
    try {
      const first = repository.commit(command("first", "0")).receipt;
      repository.commit(command("second", "1", source.set("/profile", '"b"')));
      const replay = repository.commit(
        command(
          "first",
          "0",
          source.set("/profile", '"ignored-retry-projection"'),
        ),
      );
      expect(replay).toEqual({ receipt: first, replayed: true });
      expect(repository.current()?.revision).toBe("2");
      expect(repository.current()?.source.get("/profile")?.stringValue).toBe(
        "b",
      );
      expect(() =>
        repository.commit(command("first", "2", source, "b".repeat(64))),
      ).toThrow("operation_id_reused");
      expect(repository.current()?.revision).toBe("2");
      expect(Object.isFrozen(first.affectedEntities)).toBe(true);
      expect(() =>
        repository.commit({
          ...command("sparse", "2"),
          affectedEntities: new Array<string>(1),
        }),
      ).toThrow("configuration_entities_invalid");
      let executed = false;
      const accessor = ["profile-a"];
      Object.defineProperty(accessor, "0", {
        get() {
          executed = true;
          return "profile-a";
        },
      });
      expect(() =>
        repository.commit({
          ...command("accessor", "2"),
          affectedEntities: accessor,
        }),
      ).toThrow("configuration_entities_invalid");
      expect(executed).toBe(false);
      expect(repository.current()?.revision).toBe("2");
    } finally {
      repository.close();
    }
  }));

test("revision conflicts do not reserve operation IDs or mutate the current source", () =>
  fixture((root) => {
    const repository = new SqliteConfigurationRepository(root, executable);
    try {
      repository.commit(command("first", "0"));
      try {
        repository.commit(command("stale", "0"));
        throw new Error("missing conflict");
      } catch (error) {
        expect(error).toBeInstanceOf(ConfigurationRevisionConflict);
        if (!(error instanceof ConfigurationRevisionConflict)) throw error;
        expect(error.currentRevision).toBe("1");
      }
      expect(repository.receipt("stale", "a".repeat(64))).toBeUndefined();
      expect(
        repository.commit(command("stale", "1")).receipt.resultingRevision,
      ).toBe("2");
    } finally {
      repository.close();
    }
  }));

test("an idle reopened authority owns an exclusive SQLite writer lease until close", () =>
  fixture((root) => {
    let repository = new SqliteConfigurationRepository(root, executable);
    repository.commit(command("first", "0"));
    repository.close();
    repository = new SqliteConfigurationRepository(root, executable);
    try {
      expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
        "configuration_owner_exists",
      );
    } finally {
      repository.close();
    }
    const replacement = new SqliteConfigurationRepository(root, executable);
    try {
      expect(replacement.current()?.revision).toBe("1");
      replacement.close();
      expect(() => replacement.current()).toThrow("configuration_store_closed");
    } finally {
      replacement.close();
    }
  }));

test("SQLite full after a source update rolls back both source and receipt, surviving reopen", () =>
  fixture((root, path) => {
    let repository = new SqliteConfigurationRepository(root, executable);
    const first = repository.commit(command("first", "0")).receipt;
    repository.close();
    const inspector = new Database(path, { readonly: true });
    const pages = inspector
      .query<{ page_count: number }, []>("PRAGMA page_count")
      .get()!.page_count;
    inspector.close();
    repository = new SqliteConfigurationRepository(root, executable, {
      maximumPages: pages,
    });
    try {
      const affectedEntities = Array.from(
        { length: 128 },
        (_, i) => "entity-" + String(i).padStart(3, "0") + "x".repeat(54),
      );
      expect(() =>
        repository.commit({
          ...command("full", "1", source.set("/profile", '"changed"')),
          affectedEntities,
        }),
      ).toThrow("configuration_storage_full");
      expect(repository.current()?.contentHash).toBe(first.contentHash);
      expect(repository.current()?.revision).toBe("1");
      expect(repository.receipt("full", "a".repeat(64))).toBeUndefined();
    } finally {
      repository.close();
    }
    repository = new SqliteConfigurationRepository(root, executable);
    try {
      expect(repository.current()?.revision).toBe("1");
      expect(repository.current()?.source.text()).toBe(source.text());
    } finally {
      repository.close();
    }
  }));

test("foreign schemas and corrupt source hashes are refused without repair or overwrite", () =>
  fixture((root, path) => {
    const repository = new SqliteConfigurationRepository(root, executable);
    repository.commit(command("first", "0"));
    repository.close();
    let corrupt = new Database(path);
    corrupt
      .query("UPDATE configuration_state SET source=?")
      .run('{"changed":true}');
    corrupt.close();
    const bytes = readFileSync(path);
    expect(() => new SqliteConfigurationRepository(root, executable)).toThrow();
    expect(readFileSync(path)).toEqual(bytes);
    rmSync(path);
    corrupt = new Database(path);
    corrupt.exec(
      "CREATE TABLE unrelated(secret TEXT); PRAGMA application_id=42; PRAGMA user_version=99",
    );
    corrupt.close();
    const foreign = readFileSync(path);
    expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
      "configuration_database_invalid",
    );
    expect(readFileSync(path)).toEqual(foreign);
    rmSync(path);
    const anonymous = new Database(path);
    anonymous.exec("VACUUM");
    anonymous.close();
    const anonymousBytes = readFileSync(path);
    expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
      "configuration_database_invalid",
    );
    expect(readFileSync(path)).toEqual(anonymousBytes);
    rmSync(path);
    const spoofed = new Database(path);
    spoofed.exec(`PRAGMA application_id=${0x54484346}; PRAGMA user_version=1;
      CREATE TABLE configuration_state(singleton INTEGER PRIMARY KEY,revision TEXT,source TEXT,content_hash TEXT);
      CREATE TABLE operation_receipts(operation_id TEXT PRIMARY KEY,payload_hash TEXT,revision TEXT,receipt_json TEXT);`);
    spoofed.close();
    const spoofedBytes = readFileSync(path);
    expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
      "configuration_database_invalid",
    );
    expect(readFileSync(path)).toEqual(spoofedBytes);
  }));

test("unsafe state links cannot alter another file and native preparation accepts no extra path", () =>
  fixture((root, path) => {
    const repository = new SqliteConfigurationRepository(root, executable);
    repository.close();
    rmSync(path);
    const outside = join(root, "..", "unrelated.txt");
    writeFileSync(outside, "keep-exactly", { mode: 0o600 });
    linkSync(outside, path);
    expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
      "configuration_file_unsafe",
    );
    expect(readFileSync(outside, "utf8")).toBe("keep-exactly");
    rmSync(path);
    if (process.platform !== "win32") {
      symlinkSync(outside, path);
      expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
        "configuration_file_unsafe",
      );
      rmSync(path);
    }
    expect(
      Bun.spawnSync([executable, "secure-configuration", root]).exitCode,
    ).toBe(0);
    for (const suffix of ["-journal", "-wal", "-shm"]) {
      linkSync(outside, path + suffix);
      expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
        "configuration_file_unsafe",
      );
      expect(readFileSync(outside, "utf8")).toBe("keep-exactly");
      rmSync(path + suffix);
    }
    // The native helper protects a real interrupted transaction journal too.
    writeFileSync(path + "-journal", "owned-test-journal", { mode: 0o644 });
    expect(
      Bun.spawnSync([executable, "secure-configuration", root]).exitCode,
    ).toBe(0);
    if (process.platform !== "win32")
      expect(statSync(path + "-journal").mode & 0o777).toBe(0o600);
    rmSync(path + "-journal");
    const rejected = Bun.spawnSync([
      executable,
      "secure-configuration",
      root,
      outside,
    ]);
    expect(rejected.exitCode).toBe(1);
    expect(readFileSync(outside, "utf8")).toBe("keep-exactly");
  }));

test("revision counters remain exact beyond safe integers and refuse uint64 exhaustion", () =>
  fixture((root, path) => {
    let repository = new SqliteConfigurationRepository(root, executable);
    const first = repository.commit(command("first", "0")).receipt;
    repository.close();
    function seed(revision: string) {
      const db = new Database(path);
      db.query("UPDATE configuration_state SET revision=?").run(revision);
      db.query(
        "UPDATE operation_receipts SET revision=?,receipt_json=? WHERE operation_id='first'",
      ).run(
        revision,
        JSON.stringify({ ...first, resultingRevision: revision }),
      );
      db.close();
    }
    seed("9007199254740993");
    repository = new SqliteConfigurationRepository(root, executable);
    try {
      expect(
        repository.commit(command("large", "9007199254740993")).receipt
          .resultingRevision,
      ).toBe("9007199254740994");
    } finally {
      repository.close();
    }
    const db = new Database(path);
    db.query("DELETE FROM operation_receipts WHERE operation_id='large'").run();
    db.close();
    seed("18446744073709551615");
    repository = new SqliteConfigurationRepository(root, executable);
    try {
      expect(() =>
        repository.commit(command("exhausted", "18446744073709551615")),
      ).toThrow("configuration_revision_exhausted");
      expect(repository.receipt("exhausted", "a".repeat(64))).toBeUndefined();
    } finally {
      repository.close();
    }
  }));

test("a committed receipt survives abrupt process death and ownership transfers only after exit", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-configuration-process-")),
    ),
    root = join(parent, "runtime");
  const child = Bun.spawn(
    [
      process.execPath,
      resolve(import.meta.dir, "helpers/configuration-process.ts"),
      root,
      executable,
      "commit-hold",
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const reader = child.stdout.getReader();
  let timer: ReturnType<typeof setTimeout> | undefined;
  try {
    const first = await Promise.race([
      reader.read(),
      new Promise<never>((_, reject) => {
        timer = setTimeout(
          () => reject(new Error("process_start_timeout")),
          5000,
        );
      }),
    ]);
    if (timer) clearTimeout(timer);
    expect(first.done).toBe(false);
    expect(JSON.parse(new TextDecoder().decode(first.value)).ready).toBe(true);
    expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
      "configuration_owner_exists",
    );
    child.kill("SIGKILL");
    await child.exited;
    const repository = new SqliteConfigurationRepository(root, executable);
    try {
      expect(repository.current()?.source.get("/opaque")?.numberToken).toBe(
        "18446744073709551615",
      );
      expect(
        repository.receipt("process-operation", "c".repeat(64))
          ?.resultingRevision,
      ).toBe("1");
    } finally {
      repository.close();
    }
  } finally {
    if (timer) clearTimeout(timer);
    child.kill("SIGKILL");
    await child.exited;
    reader.releaseLock();
    rmSync(parent, { recursive: true, force: true });
  }
}, 15000);
