import { expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { SqliteConfigurationRepository } from "@thumble/storage";
import { catalogFixtureSource, a, b } from "./helpers/configuration-fixture.ts";
import { readEndpoint, request } from "@thumble/client/local";
const root = resolve(import.meta.dir, "..");
const receiver = resolve(
  root,
  `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
const cli = resolve(root, "apps/cli/src/main.ts");

test("CLI/MCP configuration operations share one service authority, CAS and durable retry across restart", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-configuration-cli-")),
    ),
    runtime = join(parent, "runtime");
  const initial = catalogFixtureSource();
  const repository = new SqliteConfigurationRepository(runtime, receiver);
  try {
    repository.commit({
      operationId: "fixture-seed",
      payloadHash: "f".repeat(64),
      expectedRevision: "0",
      source: initial,
      affectedEntities: [a, b],
    });
  } finally {
    repository.close();
  }
  async function invoke(family: string, action: string, ...options: string[]) {
    const process_ = Bun.spawn(
      [
        process.execPath,
        cli,
        family,
        action,
        "--runtime-dir",
        runtime,
        "--receiver",
        receiver,
        ...options,
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [out, err, code] = await Promise.all([
      new Response(process_.stdout).text(),
      new Response(process_.stderr).text(),
      process_.exited,
    ]);
    expect(err).toBe("");
    const result = JSON.parse(out);
    expect(code).toBe(0);
    expect(result.ok).toBe(true);
    return result.result;
  }
  try {
    await invoke("service", "start");
    const child = Bun.spawn(
      [
        "node",
        resolve(root, "tooling/test-configuration-mcp-node.mjs"),
        process.execPath,
        cli,
        receiver,
        runtime,
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [out, err, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(err).toBe("");
    expect(code).toBe(0);
    expect(JSON.parse(out)).toEqual({
      ok: true,
      scenarios: 4,
      server: "bun-source",
    });
    const current = await invoke("configuration", "list");
    expect(current.revision).toBe("3");
    await invoke("service", "stop");
    await invoke("service", "start");
    expect(await invoke("configuration", "list")).toEqual(current);
    const replay = await invoke(
      "configuration",
      "rename-profile",
      "--operation-id",
      "sdk-modern",
      "--expected-revision",
      "1",
      "--profile-id",
      a,
      "--name",
      "SDK modern 🦊",
    );
    expect(replay.replayed).toBe(true);
    expect(replay.receipt.resultingRevision).toBe("2");
    expect((await invoke("configuration", "list")).revision).toBe("3");
    await invoke("service", "stop");
    // Wait for the service-owned ledger lease to end before inspecting source.
    let reopened: SqliteConfigurationRepository | undefined;
    const deadline = Date.now() + 3000;
    while (!reopened && Date.now() < deadline) {
      try {
        reopened = new SqliteConfigurationRepository(runtime, receiver);
      } catch (error) {
        if (
          !(error instanceof Error) ||
          error.message !== "configuration_owner_exists"
        )
          throw error;
        await Bun.sleep(20);
      }
    }
    if (!reopened) throw new Error("configuration_owner_shutdown_timeout");
    try {
      const source = reopened.current()!.source;
      for (const path of [
        "/opaque",
        "/profiles/0/customization",
        "/profiles/1",
        "/activeProfileID",
        "/defaultProfileID",
      ])
        expect(source.get(path)?.text()).toBe(initial.get(path)?.text());
    } finally {
      reopened.close();
    }
  } finally {
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
}, 30000);
