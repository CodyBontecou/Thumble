import { Database } from "bun:sqlite";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { LosslessJson } from "@thumble/contracts/json";
import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  mkdtempSync,
  realpathSync,
  rmSync,
  readFileSync,
  writeFileSync,
  statSync,
  existsSync,
  linkSync,
  symlinkSync,
  readdirSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { FileAssetStore } from "@thumble/storage/asset-files";
const executable = resolve(
  import.meta.dir,
  `../native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
const digest = (bytes: Uint8Array) =>
  createHash("sha256").update(bytes).digest("hex");
const first = new TextEncoder().encode("synthetic asset one"),
  second = new TextEncoder().encode("synthetic asset two");
function fixture(run: (root: string, parent: string) => void) {
  const parent = realpathSync(mkdtempSync(join(tmpdir(), "thumble-assets-")));
  try {
    run(join(parent, "runtime"), parent);
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}

test("content-addressed files deduplicate across stages, verify reads and preserve durable records across reopen", () =>
  fixture((root) => {
    let store = new FileAssetStore(root, executable);
    expect(store.pending()).toEqual([]);
    const a = store.prepare("first", "a".repeat(64), [first, second, first]);
    expect(a.assets.length).toBe(2);
    expect(a.totalBytes).toBe(first.length + second.length);
    expect(store.manifest(a.stageId)).toEqual(a);
    const b = store.prepare("second", "b".repeat(64), [first]);
    expect(
      readdirSync(join(root, "assets-v1")).filter((s) => s.startsWith("obj-"))
        .length,
    ).toBe(2);
    store = new FileAssetStore(root, executable);
    expect(
      store
        .pending()
        .map((p) => p.stageId)
        .sort(),
    ).toEqual([a.stageId, b.stageId].sort());
    expect(store.prepare("first", "a".repeat(64), [second, first])).toEqual(a);
    expect(store.read(digest(first))).toEqual(first);
    const copy = store.read(digest(first));
    copy.fill(0);
    expect(store.read(digest(first))).toEqual(first);
    expect(Object.isFrozen(a)).toBe(true);
    expect(Object.isFrozen(a.assets)).toBe(true);
    expect(Object.isFrozen(a.assets[0])).toBe(true);
    expect(() => store.prepare("first", "a".repeat(64), [first])).toThrow(
      "asset_stage_conflict",
    );
    store.retire(a.stageId);
    store.retire(a.stageId);
    expect(store.pending().length).toBe(1);
    expect(store.read(digest(first))).toEqual(first);
    if (process.platform !== "win32") {
      expect(statSync(join(root, "assets-v1")).mode & 0o777).toBe(0o700);
      for (const name of readdirSync(join(root, "assets-v1")))
        expect(statSync(join(root, "assets-v1", name)).mode & 0o777).toBe(
          0o600,
        );
    }
  }));

test("interrupted private staging can resume, while completed corrupt objects are never replaced", () =>
  fixture((root) => {
    const store = new FileAssetStore(root, executable),
      prepared = store.prepare("recover", "c".repeat(64), [first, second]);
    const object = join(root, "assets-v1", `obj-${digest(first)}.bin`),
      pending = join(root, "assets-v1", `tmp-${digest(first)}.bin`);
    rmSync(object);
    writeFileSync(pending, "partial", { mode: 0o600 });
    expect(() => store.manifest(prepared.stageId)).toThrow();
    expect(store.pending()[0]!.stageId).toBe(prepared.stageId);
    expect(store.prepare("recover", "c".repeat(64), [first, second])).toEqual(
      prepared,
    );
    expect(store.read(digest(first))).toEqual(first);
    expect(existsSync(pending)).toBe(false);
    writeFileSync(object, "corrupt");
    expect(() => store.read(digest(first))).toThrow("asset_integrity_failed");
    expect(() =>
      store.prepare("recover", "c".repeat(64), [first, second]),
    ).toThrow("asset_integrity_failed");
    expect(readFileSync(object, "utf8")).toBe("corrupt");
    expect(store.pending().length).toBe(1);
  }));

test("crash between Unix publication link and cleanup recovers only the exact private link pair", () =>
  fixture((root) => {
    const store = new FileAssetStore(root, executable),
      a = store.prepare("links", "d".repeat(64), [first]);
    const object = join(root, "assets-v1", `obj-${digest(first)}.bin`),
      pending = join(root, "assets-v1", `tmp-${digest(first)}.bin`);
    if (process.platform !== "win32") {
      linkSync(object, pending);
      expect(statSync(object).nlink).toBe(2);
      expect(store.prepare("links", "d".repeat(64), [first])).toEqual(a);
      expect(existsSync(pending)).toBe(false);
      expect(statSync(object).nlink).toBe(1);
    }
  }));

test("unsafe links, invalid input and corrupt journals cannot change neighboring files", () =>
  fixture((root, parent) => {
    const store = new FileAssetStore(root, executable),
      a = store.prepare("safe", "e".repeat(64), [first]);
    const object = join(root, "assets-v1", `obj-${digest(first)}.bin`),
      outside = join(parent, "outside");
    writeFileSync(outside, "do not modify");
    rmSync(object);
    linkSync(outside, object);
    expect(() => store.prepare("safe", "e".repeat(64), [first])).toThrow(
      "asset_file_unsafe",
    );
    expect(readFileSync(outside, "utf8")).toBe("do not modify");
    rmSync(object);
    if (process.platform !== "win32") {
      symlinkSync(outside, object);
      expect(() => store.read(digest(first))).toThrow("asset_file_unsafe");
      rmSync(object);
    }
    writeFileSync(join(root, "assets-v1", `stage-${a.stageId}.json`), "{}");
    expect(() => store.pending()).toThrow("asset_stage_invalid");
    for (const key of ["../escape", "F".repeat(64), "0".repeat(63)])
      expect(() => store.read(key)).toThrow();
    expect(() =>
      store.prepare("bad", "a".repeat(64), new Array<Uint8Array>(1)),
    ).toThrow("asset_request_invalid");
    expect(() =>
      store.prepare("big", "a".repeat(64), [
        new Uint8Array(8 * 1024 * 1024 + 1),
      ]),
    ).toThrow("asset_batch_too_large");
  }));

test("SQLite publishes only after assets are prepared and rollback leaves a recoverable uncommitted stage", () =>
  fixture((root) => {
    let repository = new SqliteConfigurationRepository(root, executable);
    repository.close();
    const inspector = new Database(join(root, "configuration-v1.sqlite3"), {
      readonly: true,
    });
    const pages = inspector
      .query<{ page_count: number }, []>("PRAGMA page_count")
      .get()!.page_count;
    inspector.close();
    repository = new SqliteConfigurationRepository(root, executable, {
      maximumPages: pages,
    });
    const store = new FileAssetStore(root, executable);
    const sha = digest(first);
    try {
      const base = {
        operationId: "asset-write",
        payloadHash: "a".repeat(64),
        expectedRevision: "0",
        source: LosslessJson.parse(JSON.stringify({ assetSHA256: sha })),
        affectedEntities: ["profile-a"],
        assets: [first],
      };
      expect(() =>
        repository.commit({
          ...base,
          source: LosslessJson.parse(
            JSON.stringify({ assetSHA256: sha, padding: "x".repeat(65536) }),
          ),
        }),
      ).toThrow("configuration_storage_full");
      expect(repository.current()).toBeUndefined();
      expect(
        repository.receipt(base.operationId, base.payloadHash),
      ).toBeUndefined();
      expect(store.pending().length).toBe(1);
      expect(store.read(sha)).toEqual(first);
      const committed = repository.commit({
        ...base,
        payloadHash: "b".repeat(64),
      });
      expect(committed.receipt.resultingRevision).toBe("1");
      expect(store.pending()).toEqual([]);
      expect(
        repository.current()!.source.get("/assetSHA256")?.stringValue,
      ).toBe(sha);
      expect(
        readFileSync(join(root, "configuration-v1.sqlite3")).includes(
          Buffer.from(first),
        ),
      ).toBe(false);
      expect(
        repository.commit({
          ...base,
          payloadHash: "b".repeat(64),
          assets: [second],
        }),
      ).toEqual({ ...committed, replayed: true });
      expect(store.read(sha)).toEqual(first);
      expect(() =>
        repository.commit({
          ...base,
          operationId: "stale",
          payloadHash: "c".repeat(64),
        }),
      ).toThrow("configuration_revision_conflict");
      expect(store.pending()).toEqual([]);
    } finally {
      repository.close();
    }
  }));

test("recovery distinguishes a matching committed receipt from an unrelated reuse of an operation ID", () =>
  fixture((root) => {
    let repository = new SqliteConfigurationRepository(root, executable);
    const store = new FileAssetStore(root, executable);
    const base = {
      operationId: "same-id",
      payloadHash: "a".repeat(64),
      expectedRevision: "0",
      source: LosslessJson.parse('{"asset":"reference"}'),
      affectedEntities: ["profile-a"],
      assets: [first],
    };
    const committed = repository.commit(base);
    store.prepare("same-id", "b".repeat(64), [second]);
    repository.close();
    repository = new SqliteConfigurationRepository(root, executable);
    try {
      expect(store.pending()).toEqual([]);
      expect(repository.receipt("same-id", "a".repeat(64))).toEqual(
        committed.receipt,
      );
      expect(store.read(digest(first))).toEqual(first);
    } finally {
      repository.close();
    }
  }));

test("durable receipts and assets recover after actual owner process death before and after commit", async () => {
  for (const mode of ["prepare-hold", "commit-hold"]) {
    const parent = realpathSync(
        mkdtempSync(join(tmpdir(), "thumble-asset-owner-")),
      ),
      root = join(parent, "runtime");
    const child = Bun.spawn(
      [
        process.execPath,
        resolve(import.meta.dir, "helpers/configuration-asset-process.ts"),
        root,
        executable,
        mode,
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    try {
      const reader = child.stdout.getReader();
      let buffer = "";
      const ready = await Promise.race([
        (async () => {
          for (;;) {
            const next = await reader.read();
            if (next.done) throw new Error("asset_owner_not_ready");
            buffer += new TextDecoder().decode(next.value);
            if (buffer.length > 4096)
              throw new Error("asset_owner_output_overflow");
            if (buffer.includes("\n")) return JSON.parse(buffer.trim());
          }
        })(),
        Bun.sleep(5000).then(() => {
          throw new Error("asset_owner_startup_timeout");
        }),
      ]);
      expect(ready.ready).toBe(true);
      expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
        "configuration_owner_exists",
      );
      child.kill("SIGKILL");
      await child.exited;
      expect(await new Response(child.stderr).text()).toBe("");
      const repository = new SqliteConfigurationRepository(root, executable),
        store = new FileAssetStore(root, executable);
      try {
        expect(store.pending()).toEqual([]);
        expect(digest(store.read(ready.sha))).toBe(ready.sha);
        if (mode === "commit-hold") {
          expect(repository.current()!.revision).toBe("1");
          expect(repository.receipt("asset-operation", "a".repeat(64))).toEqual(
            ready.receipt,
          );
        } else {
          expect(repository.current()).toBeUndefined();
          expect(
            repository.receipt("asset-operation", "a".repeat(64)),
          ).toBeUndefined();
        }
      } finally {
        repository.close();
      }
    } finally {
      if (child.exitCode === null) {
        child.kill("SIGKILL");
        await child.exited;
      }
      rmSync(parent, { recursive: true, force: true });
    }
  }
}, 20000);

test(
  "pending journal count is bounded and retirement frees capacity without deleting content",
  () =>
    fixture((root) => {
      const store = new FileAssetStore(root, executable);
      for (let index = 0; index < 64; index++)
        store.prepare(`operation-${index}`, "f".repeat(64), [first]);
      expect(store.pending().length).toBe(64);
      expect(() => store.prepare("overflow", "f".repeat(64), [first])).toThrow(
        "asset_storage_full",
      );
      store.retire(store.pending()[0]!.stageId);
      store.prepare("after-retirement", "f".repeat(64), [first]);
      expect(store.pending().length).toBe(64);
      expect(store.read(digest(first))).toEqual(first);
    }),
  30000,
);

test("TypeScript preparation agrees with the shared binary and stage identity vector", () =>
  fixture((root) => {
    const vector = JSON.parse(
      readFileSync(
        resolve(
          import.meta.dir,
          "../packages/fixtures/asset-files-v1/vector.json",
        ),
        "utf8",
      ),
    );
    const prepared = new FileAssetStore(root, executable).prepare(
      vector.header.operationId,
      vector.header.payloadHash,
      vector.objects.map((entry: { bytes: number[] }) =>
        Uint8Array.from(entry.bytes),
      ),
    );
    expect(prepared).toEqual(vector.preparation);
    const frame = Buffer.from(vector.frameHex, "hex"),
      size = frame.readUInt32BE();
    expect(JSON.parse(frame.subarray(4, 4 + size).toString("utf8"))).toEqual(
      vector.header,
    );
    expect(frame.subarray(4 + size)).toEqual(
      Buffer.concat(
        vector.objects.map((entry: { bytes: number[] }) =>
          Buffer.from(entry.bytes),
        ),
      ),
    );
  }));

test("reopen preserves a committed recovery record until its asset integrity is restored", () =>
  fixture((root) => {
    const operationId = "committed-recovery",
      payloadHash = "6".repeat(64),
      sha = digest(first);
    let repository = new SqliteConfigurationRepository(root, executable);
    const committed = repository.commit({
      operationId,
      payloadHash,
      expectedRevision: "0",
      source: LosslessJson.parse(JSON.stringify({ assetSHA256: sha })),
      affectedEntities: ["profile-a"],
      assets: [first],
    });
    repository.close();
    const store = new FileAssetStore(root, executable),
      stage = store.prepare(operationId, payloadHash, [first]);
    const object = join(root, "assets-v1", `obj-${sha}.bin`);
    writeFileSync(object, "corrupt");
    expect(() => new SqliteConfigurationRepository(root, executable)).toThrow(
      "asset_integrity_failed",
    );
    expect(store.pending().map((s) => s.stageId)).toEqual([stage.stageId]);
    writeFileSync(object, first);
    repository = new SqliteConfigurationRepository(root, executable);
    try {
      expect(store.pending()).toEqual([]);
      expect(repository.receipt(operationId, payloadHash)).toEqual(
        committed.receipt,
      );
      expect(store.read(sha)).toEqual(first);
    } finally {
      repository.close();
    }
  }));
