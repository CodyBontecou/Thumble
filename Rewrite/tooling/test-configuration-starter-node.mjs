// Real independent CLI + both MCP protocol eras, empty authority only. No fixtures/input.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
const [bun, cli, receiver, runtime] = process.argv.slice(2);
const execute = promisify(execFile);
const common = ["--runtime-dir", runtime, "--receiver", receiver];
const intent = {
  operationId: "first-starter",
  expectedRevision: "0",
  profileId: "e1000000-0000-0000-0000-000000000001",
  name: "My gamepad",
};
const flags = [
  "--operation-id",
  intent.operationId,
  "--expected-revision",
  "0",
  "--profile-id",
  intent.profileId,
  "--name",
  intent.name,
];
async function invoke(family, action, extra = []) {
  const result = await execute(
    bun,
    [cli, family, action, ...common, ...extra],
    { timeout: 5000, maxBuffer: 65536, windowsHide: true },
  );
  assert.equal(result.stderr, "");
  const reply = JSON.parse(result.stdout);
  assert.equal(reply.ok, true);
  return reply.result;
}
let committed;
try {
  await invoke("service", "start");
  assert.equal((await invoke("configuration", "list")).revision, "0");
  for (const legacy of [false, true])
    for (const writable of [false, true]) {
      const transport = new StdioClientTransport({
        command: bun,
        args: [
          cli,
          "mcp",
          "serve",
          ...common,
          ...(writable ? ["--allow-configuration-write"] : []),
        ],
        stderr: "pipe",
      });
      let stderr = "";
      transport.stderr?.on("data", (chunk) => {
        if (stderr.length < 4096) stderr += chunk.toString();
      });
      const client = new Client(
        { name: "starter-parity", version: "1" },
        {
          versionNegotiation: {
            mode: legacy ? "legacy" : { pin: "2026-07-28" },
          },
        },
      );
      try {
        await client.connect(
          transport,
          legacy
            ? { prior: { kind: "legacy" }, timeout: 5000 }
            : { timeout: 5000 },
        );
        assert.equal(
          (await client.listTools()).tools.some(
            (t) => t.name === "configuration_initialize_starter",
          ),
          writable,
        );
        if (!writable)
          await assert.rejects(
            client.callTool(
              { name: "configuration_initialize_starter", arguments: intent },
              { timeout: 5000 },
            ),
            /tool_unavailable/,
          );
        else {
          const response = await client.callTool(
            { name: "configuration_initialize_starter", arguments: intent },
            { timeout: 5000 },
          );
          assert.notEqual(response.isError, true);
          const result = response.structuredContent.result;
          assert.equal(result.kind, "committed");
          assert.equal(result.replayed, legacy);
          committed ??= result.receipt;
          assert.deepEqual(result.receipt, committed);
          assert.deepEqual(
            (await invoke("configuration", "initialize-starter", flags))
              .receipt,
            committed,
          );
        }
        assert.equal(stderr, "");
      } finally {
        await client.close();
      }
    }
  const catalog = await invoke("configuration", "list");
  assert.equal(catalog.revision, "1");
  assert.equal(catalog.profiles.length, 1);
  assert.equal(catalog.activeProfileId, intent.profileId);
  assert.equal(catalog.defaultProfileId, intent.profileId);
  assert.equal(
    (await invoke("receiver", "status")).receiver.snapshot.active,
    false,
  );
  const conflict = await invoke(
    "configuration",
    "initialize-starter",
    flags.map((v) => (v === intent.operationId ? "different-starter" : v)),
  );
  assert.equal(conflict.kind, "conflict");
  assert.equal(conflict.currentRevision, "1");
  await invoke("service", "stop");
  // Endpoint removal is the confirmed service termination/restart boundary.
  const { existsSync } = await import("node:fs");
  const { join } = await import("node:path");
  const stopDeadline = performance.now() + 3000;
  while (existsSync(join(runtime, "endpoint.json"))) {
    if (performance.now() >= stopDeadline)
      throw new Error("stop_not_confirmed");
    await new Promise((r) => setTimeout(r, 10));
  }
  await invoke("service", "start");
  const replay = await invoke("configuration", "initialize-starter", flags);
  assert.equal(replay.replayed, true);
  assert.deepEqual(replay.receipt, committed);
  assert.equal(
    (await invoke("receiver", "status")).receiver.snapshot.active,
    false,
  );
  console.log(
    JSON.stringify({
      cli: true,
      modernMcp: true,
      legacyMcp: true,
      readonlyDenied: true,
      restartReplay: true,
      existingRefused: true,
      inputActivated: false,
    }),
  );
} finally {
  await invoke("service", "stop").catch(() => {});
}
