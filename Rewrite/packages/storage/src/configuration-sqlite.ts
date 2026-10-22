import { Database, constants } from "bun:sqlite";
import { createHash } from "node:crypto";
import { lstatSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { spawnSync } from "node:child_process";
import { LosslessJson } from "@thumble/contracts/json";
import {
  counter,
  identity,
  exact,
  record,
  parseStrictJson,
} from "@thumble/contracts/receiver";
import {
  ConfigurationRevisionConflict,
  type ConfigurationRepository,
  type ConfigurationSource,
  type ConfigurationReceipt,
  type ConfigurationCommit,
} from "@thumble/application/configuration-store";
const APPLICATION_ID = 0x54484346;
const FILE = "configuration-v1.sqlite3";
const MAX_PAGES = 65536;
const MAX_COUNTER = 18446744073709551615n;
const TABLES = Object.freeze({
  configuration_state:
    "CREATE TABLE configuration_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision TEXT NOT NULL, source TEXT NOT NULL, content_hash TEXT NOT NULL) STRICT",
  operation_receipts:
    "CREATE TABLE operation_receipts(operation_id TEXT PRIMARY KEY, payload_hash TEXT NOT NULL, revision TEXT NOT NULL UNIQUE, receipt_json TEXT NOT NULL) STRICT",
});
const schemaIdentity = (sql: string): string =>
  sql.replace(/;\s*$/, "").trim().replace(/\s+/g, " ").toLowerCase();

const fail = (code: string): never => {
  throw new Error(code);
};
function digest(value: unknown): string {
  if (typeof value !== "string" || !/^[0-9a-f]{64}$/.test(value))
    return fail("configuration_hash_invalid");
  return value;
}
export function configurationSourceHash(source: LosslessJson): string {
  return createHash("sha256")
    .update(LosslessJson.canonicalization)
    .update("\0")
    .update(source.canonicalText(), "utf8")
    .digest("hex");
}
function entities(value: unknown): readonly string[] {
  if (!Array.isArray(value) || value.length > 256)
    return fail("configuration_entities_invalid");
  const result: string[] = [];
  for (let index = 0; index < value.length; index++) {
    const field = Object.getOwnPropertyDescriptor(value, String(index));
    if (!field || !("value" in field))
      return fail("configuration_entities_invalid");
    result.push(identity(field.value));
  }
  if (new Set(result).size !== result.length)
    return fail("configuration_entities_invalid");
  return Object.freeze(result);
}
function decodeReceipt(
  text: string,
  operationId: string,
  revision: string,
): ConfigurationReceipt {
  const value = record(parseStrictJson(text));
  exact(value, [
    "version",
    "operationId",
    "resultingRevision",
    "contentHash",
    "affectedEntities",
  ]);
  if (
    value.version !== 1 ||
    value.operationId !== operationId ||
    value.resultingRevision !== revision ||
    revision === "0"
  )
    return fail("configuration_database_invalid");
  return Object.freeze({
    version: 1,
    operationId: identity(operationId),
    resultingRevision: counter(revision),
    contentHash: digest(value.contentHash),
    affectedEntities: entities(value.affectedEntities),
  });
}
function storageError(error: unknown): Error {
  if (error instanceof ConfigurationRevisionConflict) return error;
  if (
    error instanceof Error &&
    /^(configuration_|operation_id_reused)/.test(error.message)
  )
    return error;
  if (error && typeof error === "object" && "code" in error) {
    if (error.code === "SQLITE_BUSY" || error.code === "SQLITE_LOCKED")
      return new Error("configuration_owner_exists");
    if (error.code === "SQLITE_FULL")
      return new Error("configuration_storage_full");
  }
  return new Error("configuration_storage_failed");
}
type StateRow = { revision: string; source: string; content_hash: string };
type ReceiptRow = {
  operation_id: string;
  payload_hash: string;
  revision: string;
  receipt_json: string;
};
/** Host-only single-writer store. It never grants document validity or input authority. */
export class SqliteConfigurationRepository implements ConfigurationRepository {
  readonly #db: Database;
  #closed = false;
  constructor(
    root: string,
    nativeExecutable: string,
    options: { maximumPages?: number } = {},
  ) {
    if (
      typeof root !== "string" ||
      typeof nativeExecutable !== "string" ||
      root.includes("\0") ||
      nativeExecutable.includes("\0") ||
      !isAbsolute(root) ||
      !isAbsolute(nativeExecutable)
    )
      fail("configuration_path_invalid");
    const maximumPages = options.maximumPages ?? MAX_PAGES;
    if (
      !Number.isSafeInteger(maximumPages) ||
      maximumPages < 4 ||
      maximumPages > MAX_PAGES
    )
      fail("configuration_limit_invalid");
    const path = join(root, FILE);
    let mainExists = false;
    for (const suffix of ["", "-journal", "-wal", "-shm"]) {
      try {
        const metadata = lstatSync(path + suffix);
        if (suffix === "") mainExists = true;
        if (
          !metadata.isFile() ||
          metadata.isSymbolicLink() ||
          metadata.nlink !== 1 ||
          (suffix !== "" && !mainExists) ||
          suffix === "-wal" ||
          suffix === "-shm"
        )
          fail("configuration_file_unsafe");
      } catch (error) {
        if (
          !(
            error &&
            typeof error === "object" &&
            "code" in error &&
            error.code === "ENOENT"
          )
        )
          throw error;
      }
    }
    const protection = spawnSync(
      nativeExecutable,
      ["secure-configuration", root],
      {
        encoding: "utf8",
        timeout: 3000,
        maxBuffer: 4096,
        windowsHide: true,
      },
    );
    if (protection.error || protection.status !== 0)
      fail("configuration_protection_failed");
    const metadata = lstatSync(path);
    if (!metadata.isFile() || metadata.nlink !== 1 || metadata.isSymbolicLink())
      fail("configuration_file_unsafe");
    if (
      process.platform !== "win32" &&
      ((metadata.mode & 0o077) !== 0 || metadata.uid !== process.getuid?.())
    )
      fail("configuration_file_unsafe");
    try {
      this.#db = new Database(
        path,
        constants.SQLITE_OPEN_READWRITE | constants.SQLITE_OPEN_NOFOLLOW,
      );
    } catch (error) {
      throw storageError(error);
    }
    try {
      this.#db.exec(
        "PRAGMA busy_timeout=0; PRAGMA locking_mode=EXCLUSIVE; PRAGMA synchronous=FULL; PRAGMA trusted_schema=OFF",
      );
      const app = this.#db
        .query<{ application_id: number }, []>("PRAGMA application_id")
        .get()!.application_id;
      const version = this.#db
        .query<{ user_version: number }, []>("PRAGMA user_version")
        .get()!.user_version;
      const objects = this.#db
        .query<
          { name: string; type: string },
          []
        >("SELECT name,type FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        .all();
      if (app === 0 && version === 0 && objects.length === 0) {
        // Only a fresh empty file (or a bootstrap rollback to empty) is ours
        // to initialize. An anonymous pre-existing SQLite database is not.
        if (metadata.size !== 0 && lstatSync(path).size !== 0)
          fail("configuration_database_invalid");
        this.#db.exec("PRAGMA page_size=4096");
        this.#db
          .transaction(() => {
            this.#db
              .exec(`PRAGMA application_id=${APPLICATION_ID}; PRAGMA user_version=1;
            ${Object.values(TABLES).join(";")};`);
          })
          .exclusive();
      } else if (
        app !== APPLICATION_ID ||
        version !== 1 ||
        objects.length !== 2 ||
        objects.some(
          (o) =>
            o.type !== "table" ||
            !["configuration_state", "operation_receipts"].includes(o.name),
        )
      )
        fail("configuration_database_invalid");
      const schema = this.#db
        .query<
          { name: string; type: string; sql: string },
          []
        >("SELECT name,type,sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'")
        .all();
      if (
        schema.length !== 2 ||
        Object.entries(TABLES).some(([name, sql]) => {
          const stored = schema.find((row) => row.name === name);
          return (
            !stored ||
            stored.type !== "table" ||
            typeof stored.sql !== "string" ||
            schemaIdentity(stored.sql) !== schemaIdentity(sql)
          );
        })
      )
        fail("configuration_database_invalid");
      if (
        this.#db
          .query<{ quick_check: string }, []>("PRAGMA quick_check(1)")
          .get()?.quick_check !== "ok"
      )
        fail("configuration_database_invalid");
      if (
        this.#db.query<{ page_size: number }, []>("PRAGMA page_size").get()!
          .page_size !== 4096
      )
        fail("configuration_database_invalid");
      if (
        this.#db
          .query<{ journal_mode: string }, []>("PRAGMA journal_mode")
          .get()?.journal_mode !== "delete"
      )
        fail("configuration_database_invalid");
      const actual = this.#db
        .query<
          { max_page_count: number },
          []
        >(`PRAGMA max_page_count=${maximumPages}`)
        .get()!.max_page_count;
      if (actual > maximumPages) fail("configuration_storage_limit_exceeded");
      // Acquire the writer lease even when reopening an existing read-only head.
      const current = this.#db.transaction(() => this.current()).exclusive();
      const latest = this.#db
        .query<
          ReceiptRow,
          []
        >("SELECT * FROM operation_receipts ORDER BY length(revision) DESC, revision DESC LIMIT 1")
        .get();
      if (current) {
        if (
          !latest ||
          latest.revision !== current.revision ||
          decodeReceipt(
            latest.receipt_json,
            latest.operation_id,
            latest.revision,
          ).contentHash !== current.contentHash
        )
          fail("configuration_database_invalid");
      } else if (latest) fail("configuration_database_invalid");
    } catch (error) {
      this.#db.close();
      throw storageError(error);
    }
  }
  private open(): void {
    if (this.#closed) fail("configuration_store_closed");
  }
  current(): ConfigurationSource | undefined {
    this.open();
    try {
      const row = this.#db
        .query<
          StateRow,
          []
        >("SELECT revision,source,content_hash FROM configuration_state WHERE singleton=1")
        .get();
      if (!row) return undefined;
      const source = LosslessJson.parse(row.source),
        revision = counter(row.revision),
        contentHash = digest(row.content_hash);
      if (revision === "0" || configurationSourceHash(source) !== contentHash)
        fail("configuration_database_invalid");
      return Object.freeze({ revision, source, contentHash });
    } catch (error) {
      throw storageError(error);
    }
  }
  receipt(
    operationId: string,
    payloadHash: string,
  ): ConfigurationReceipt | undefined {
    this.open();
    identity(operationId);
    digest(payloadHash);
    try {
      const row = this.#db
        .query<
          ReceiptRow,
          [string]
        >("SELECT * FROM operation_receipts WHERE operation_id=?")
        .get(operationId);
      if (!row) return undefined;
      if (row.payload_hash !== payloadHash) fail("operation_id_reused");
      return decodeReceipt(row.receipt_json, operationId, row.revision);
    } catch (error) {
      throw storageError(error);
    }
  }
  commit(
    command: ConfigurationCommit,
  ): Readonly<{ receipt: ConfigurationReceipt; replayed: boolean }> {
    this.open();
    const operationId = identity(command.operationId),
      payloadHash = digest(command.payloadHash),
      expectedRevision = counter(command.expectedRevision);
    const affectedEntities = entities(command.affectedEntities);
    const source = command.source.text(),
      contentHash = configurationSourceHash(command.source);
    try {
      return this.#db
        .transaction(() => {
          const previous = this.receipt(operationId, payloadHash);
          if (previous)
            return Object.freeze({ receipt: previous, replayed: true });
          const current = this.current(),
            revision = current?.revision ?? "0";
          if (revision !== expectedRevision)
            throw new ConfigurationRevisionConflict(revision);
          if (BigInt(revision) >= MAX_COUNTER)
            fail("configuration_revision_exhausted");
          const next = (BigInt(revision) + 1n).toString();
          const receipt: ConfigurationReceipt = Object.freeze({
            version: 1,
            operationId,
            resultingRevision: next,
            contentHash,
            affectedEntities,
          });
          this.#db
            .query(
              "INSERT INTO configuration_state(singleton,revision,source,content_hash) VALUES(1,?,?,?) ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision,source=excluded.source,content_hash=excluded.content_hash",
            )
            .run(next, source, contentHash);
          this.#db
            .query(
              "INSERT INTO operation_receipts(operation_id,payload_hash,revision,receipt_json) VALUES(?,?,?,?)",
            )
            .run(operationId, payloadHash, next, JSON.stringify(receipt));
          return Object.freeze({ receipt, replayed: false });
        })
        .immediate();
    } catch (error) {
      throw storageError(error);
    }
  }
  close(): void {
    if (!this.#closed) {
      this.#closed = true;
      this.#db.close();
    }
  }
}
