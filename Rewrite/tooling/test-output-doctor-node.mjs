// Independent official SDK clients, modern and legacy; no service is started.
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { isAbsolute } from "node:path";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
const [bun, cli, receiver, runtime] = process.argv.slice(2);
assert.ok([bun, cli, receiver, runtime].every(isAbsolute));
for (const legacy of [false, true]) {
  const transport = new StdioClientTransport({
    command: bun,
    args: [
      cli,
      "mcp",
      "serve",
      "--runtime-dir",
      runtime,
      "--receiver",
      receiver,
    ],
    stderr: "pipe",
  });
  let stderr = "";
  transport.stderr?.on("data", (chunk) => {
    stderr += chunk.toString();
  });
  const client = new Client(
    { name: "offline-output-doctor-test", version: "1" },
    { versionNegotiation: { mode: legacy ? "legacy" : { pin: "2026-07-28" } } },
  );
  try {
    await client.connect(
      transport,
      legacy ? { prior: { kind: "legacy" }, timeout: 5000 } : { timeout: 5000 },
    );
    const tools = (await client.listTools()).tools;
    const tool = tools.find((t) => t.name === "output_doctor");
    assert.ok(tool);
    assert.equal(tool.annotations.readOnlyHint, true);
    const reply = await client.callTool({
      name: "output_doctor",
      arguments: {},
    });
    assert.equal(reply.isError, undefined);
    assert.equal(reply.structuredContent.ok, true);
    const result = reply.structuredContent.result;
    assert.equal(result.backend, "recording");
    assert.equal(result.physicalOutputEnabled, false);
    assert.equal(result.runtimeIntegrated, false);
    assert.equal(result.osDeviceAuthorization, "not-inspected");
    assert.equal(result.windows.sdkLinked, false);
    assert.equal(result.windows.driver, "not-inspected");
    let rejected = false;
    try {
      const bad = await client.callTool({
        name: "output_doctor",
        arguments: { enable: true },
      });
      rejected = bad.isError === true;
    } catch {
      rejected = true;
    }
    assert.ok(rejected);
    assert.equal(existsSync(runtime), false);
  } finally {
    await client.close();
  }
  assert.equal(stderr, "");
}
console.log(JSON.stringify({ ok: true, scenarios: 2, serviceStarted: false }));
