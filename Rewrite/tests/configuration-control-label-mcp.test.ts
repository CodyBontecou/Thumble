import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import {
  mkdirSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { promisify } from "node:util";
import { starterConfiguration } from "@thumble/domain/starter-configuration";
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
const digest = (value: string | Uint8Array) =>
  createHash("sha256").update(value).digest("hex");

test("independent modern/legacy Node MCP and CLI label authors share durable CAS while preserving starter input", async () => {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-label-mcp-")),
  );
  const runtime = join(parent, "runtime");
  // Native export rejects aliased ancestors. Exercise Node's temp-directory
  // canonicalization explicitly rather than depending on this runner's TMPDIR.
  const nodeEnvironment = { ...process.env };
  if (process.platform !== "win32") {
    const canonical = join(parent, "node-temp");
    const alias = join(parent, "node-temp-alias");
    mkdirSync(canonical, { mode: 0o700 });
    symlinkSync(canonical, alias, "dir");
    nodeEnvironment.TMPDIR = alias;
  }
  const original = starterConfiguration(
    profileId,
    "Synthetic starter",
    "1",
  ).set("/opaque", '{"exact":9007199254740993.000,"future":true}');
  const elements = original.get("/profiles/0/customization/elements")!;
  const controlId = elements.get("/0/id")!.stringValue!;
  const prepared = OwnedAuthorityDocument.prepare(original, digest);
  let repository: SqliteConfigurationRepository | undefined =
    new SqliteConfigurationRepository(runtime, receiver);
  repository.commit({
    operationId: "fixture-label-seed",
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
        resolve(root, "tooling/test-control-label-mcp-node.mjs"),
        process.execPath,
        cli,
        receiver,
        runtime,
        profileId,
        controlId,
      ],
      {
        timeout: 35000,
        maxBuffer: 65536,
        windowsHide: true,
        env: nodeEnvironment,
      },
    );
    expect(result.stderr).toBe("");
    expect(JSON.parse(result.stdout)).toEqual({
      ok: true,
      scenarios: 4,
      concurrentReceipt: true,
      blankAndClear: true,
      restartReplay: true,
      inputActivated: false,
    });
    const catalog = await invoke("configuration", "list");
    expect(catalog.revision).toBe("7");
    expect(catalog.activeProfileId).toBe(profileId);
    expect(catalog.defaultProfileId).toBe(profileId);
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
    expect(stored.revision).toBe("7");
    const source = OwnedAuthorityDocument.read(stored.source).materialize(
      () => {
        throw new Error("unexpected_resource_read");
      },
      digest,
    ).source;
    for (const path of [
      "/opaque",
      "/keyBindings",
      "/outputBindings",
      "/profileKeyBindings",
      "/profileOutputBindings",
      "/activeProfileID",
      "/defaultProfileID",
      "/profiles/0/customization/elements",
    ])
      expect(source.get(path)?.text()).toBe(original.get(path)?.text());
    expect(
      source.get(`/profiles/0/customization/labelOverrides/${controlId}`),
    ).toBeUndefined();
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
