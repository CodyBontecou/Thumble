import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
import { ConfigurationCatalog } from "@thumble/domain/configuration-catalog";
import { OwnedAuthorityDocument } from "@thumble/domain/owned-authority";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { readEndpoint, request } from "@thumble/client/local";
const root = resolve(import.meta.dir, "..");
const receiver = resolve(
  root,
  "native/receiver/target/debug/thumble-rewrite-receiver" +
    (process.platform === "win32" ? ".exe" : ""),
);
const cli = resolve(root, "apps/cli/src/main.ts");
const profileId = "e1000000-0000-0000-0000-000000000001";
const b = "e1000000-0000-0000-0000-000000000002";
const c = "e1000000-0000-0000-0000-000000000003";
const digest = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");

test("independent Node MCP profile deletion preserves source and installed recording pin across durable replay", async () => {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-delete-mcp-")),
  );
  const runtime = join(parent, "runtime");
  const starter = starterConfiguration(profileId, "Synthetic starter", "1").set(
    "/opaque",
    '{"exact":9007199254740993.000,"future":true}',
  );
  const original = ConfigurationCatalog.read(starter)
    .duplicateProfile(profileId, b, "Profile B", "1", false)
    .duplicateProfile(profileId, c, "Profile C", "1", false).source;
  const prepared = OwnedAuthorityDocument.prepare(original, digest);
  let repository: SqliteConfigurationRepository | undefined =
    new SqliteConfigurationRepository(runtime, receiver);
  repository.commit({
    operationId: "fixture-delete-seed",
    payloadHash: "f".repeat(64),
    expectedRevision: "0",
    source: prepared.document.source,
    assets: prepared.assets(),
    affectedEntities: ["configuration"],
  });
  repository.close();
  repository = undefined;
  const invoke = async (family: string, action: string) => {
    const result = await promisify(execFile)(
      process.execPath,
      [cli, family, action, "--runtime-dir", runtime, "--receiver", receiver],
      { timeout: 5000, maxBuffer: 65536, windowsHide: true },
    );
    expect(result.stderr).toBe("");
    const value = JSON.parse(result.stdout);
    expect(value.ok).toBe(true);
    return value.result;
  };
  try {
    await invoke("service", "start");
    const result = await promisify(execFile)(
      process.env.THUMBLE_REWRITE_NODE ?? "node",
      [
        resolve(root, "tooling/test-profile-delete-mcp-node.mjs"),
        process.execPath,
        cli,
        receiver,
        runtime,
        profileId,
        b,
        c,
      ],
      {
        timeout: 35000,
        maxBuffer: 65536,
        windowsHide: true,
      },
    );
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toEqual({
      ok: true,
      scenarios: 4,
      concurrentReceipt: true,
      installedPinPreserved: true,
      explicitRelease: true,
      restartReplay: true,
      physicalOutput: false,
    });
    const catalog = await invoke("configuration", "list");
    expect(catalog.revision).toBe("3");
    expect(catalog.activeProfileId).toBe(c);
    expect(catalog.defaultProfileId).toBe(c);
    await invoke("service", "stop");
    const deadline = Date.now() + 3000;
    while (!repository && Date.now() < deadline) {
      try {
        repository = new SqliteConfigurationRepository(runtime, receiver);
      } catch (error) {
        if (
          !(error instanceof Error) ||
          error.message !== "configuration_owner_exists"
        )
          throw error;
        await Bun.sleep(20);
      }
    }
    if (!repository) throw new Error("configuration_owner_shutdown_timeout");
    const stored = repository.current()!;
    expect(stored.revision).toBe("3");
    const source = OwnedAuthorityDocument.read(stored.source).materialize(
      () => {
        throw new Error("unexpected_resource_read");
      },
      digest,
    ).source;
    const selected = ConfigurationCatalog.read(original).selectProfiles(
      c,
      c,
    ).source;
    for (const path of ["/keyBindings", "/outputBindings"])
      expect(source.get(path)?.text()).toBe(selected.get(path)?.text());
    expect(source.get("/opaque")?.text()).toBe(original.get("/opaque")?.text());
    expect(source.get("/profiles/0")?.text()).toBe(
      original.get("/profiles/2")?.text(),
    );
    expect(source.get("/profiles/1")).toBeUndefined();
    for (const name of ["profileKeyBindings", "profileOutputBindings"]) {
      expect(source.get(`/${name}/${c}`)?.text()).toBe(
        original.get(`/${name}/${c}`)?.text(),
      );
      expect(source.get(`/${name}/${profileId}`)).toBeUndefined();
      expect(source.get(`/${name}/${b}`)).toBeUndefined();
    }
    expect(source.get("/activeProfileID")?.stringValue).toBe(c);
    expect(source.get("/defaultProfileID")?.stringValue).toBe(c);
  } finally {
    repository?.close();
    try {
      await request(readEndpoint(runtime, receiver), { command: "stop" });
    } catch {}
    for (let attempt = 0; attempt < 100; attempt++) {
      try {
        rmSync(parent, { recursive: true, force: true });
        break;
      } catch (error) {
        if (attempt === 99) throw error;
        await Bun.sleep(20);
      }
    }
  }
}, 45000);
