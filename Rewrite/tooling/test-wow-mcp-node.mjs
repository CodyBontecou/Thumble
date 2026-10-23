// Synthetic local tool admission only; no capture permission or physical input.
import assert from "node:assert/strict";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
const [bun, cli, receiver, runtime] = process.argv.slice(2);
let scenarios = 0;
try {
  for (const legacy of [false, true])
    for (const capture of [false, true])
      for (const write of [false, true]) {
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
            ...(capture ? ["--allow-wow-capture"] : []),
            ...(write ? ["--allow-configuration-write"] : []),
          ],
          stderr: "pipe",
        });
        let stderr = "";
        transport.stderr?.on("data", (c) => {
          if (stderr.length < 4096) stderr += c.toString();
        });
        const client = new Client(
          { name: "wow-scope-probe", version: "1" },
          {
            versionNegotiation: {
              mode: legacy ? "legacy" : { pin: "2026-07-28" },
            },
          },
        );
        const call = (name, args = {}) =>
          client.callTool({ name, arguments: args }, { timeout: 5000 });
        try {
          await client.connect(
            transport,
            legacy
              ? { prior: { kind: "legacy" }, timeout: 5000 }
              : { timeout: 5000 },
          );
          const names = (await client.listTools()).tools.map((t) => t.name);
          assert.equal(names.includes("wow_sync_status"), true);
          for (const name of ["wow_refresh", "wow_sync_start", "wow_sync_stop"])
            assert.equal(names.includes(name), capture && write);
          const status = await call("wow_sync_status");
          assert.equal(status.structuredContent.ok, true);
          assert.equal(status.structuredContent.result.enabled, true);
          if (!capture || !write)
            await assert.rejects(
              call("wow_sync_start", {}),
              /tool_unavailable/,
            );
          else {
            const catalog = (
              await call("configuration_list", {
                expectedRevision: null,
                offset: 0,
              })
            ).structuredContent.result;
            const operationId = `mcp-wow-${legacy ? "legacy" : "modern"}`;
            const start = await call("wow_sync_start", {
              operationId,
              expectedRevision: catalog.revision,
              expectedSourceHash: catalog.contentHash,
            });
            assert.equal(start.structuredContent.ok, true);
            assert.equal(start.structuredContent.result.busy, true);
            const stop = await call("wow_sync_stop", { operationId });
            assert.equal(stop.structuredContent.ok, true);
            let stopped;
            for (let i = 0; i < 100; i++) {
              stopped = (await call("wow_sync_status", { operationId }))
                .structuredContent.result;
              if (!stopped.busy) break;
              await new Promise((r) => setTimeout(r, 10));
            }
            assert.equal(stopped.state, "stopped");
            assert.equal(stopped.busy, false);
          }
          scenarios++;
        } finally {
          await client.close();
        }
        assert.equal(stderr, "");
      }
  console.log(JSON.stringify({ ok: true, scenarios, physicalInput: false }));
} catch {
  console.error("wow_mcp_scope_probe_failed");
  process.exitCode = 1;
}
