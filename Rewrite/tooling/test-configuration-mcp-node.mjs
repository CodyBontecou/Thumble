// Independent Node SDK client for CLI/MCP configuration parity. Synthetic catalog only.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { isAbsolute } from "node:path";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
const [bun, cli, receiver, runtime, restrictedPath] = process.argv.slice(2);
if (
  ![bun, cli, receiver, runtime].every(
    (p) => typeof p === "string" && isAbsolute(p),
  )
)
  throw new Error("invalid_probe_arguments");
const launcher = cli.endsWith(".ts") ? [bun, cli] : [cli];
const common = ["--runtime-dir", runtime, "--receiver", receiver];
const env = {
  ...process.env,
  ...(restrictedPath === undefined ? {} : { PATH: restrictedPath }),
};
const execute = promisify(execFile);
async function invoke(family, action, options = []) {
  const result = await execute(
    launcher[0],
    [...launcher.slice(1), family, action, ...common, ...options],
    { timeout: 5000, maxBuffer: 65536, windowsHide: true, env },
  );
  assert.equal(result.stderr, "");
  const value = JSON.parse(result.stdout);
  assert.equal(value.ok, true);
  return value.result;
}
const a = "aaaaaaaa-0000-0000-0000-000000000001";
let scenarios = 0;
for (const legacy of [false, true])
  for (const writable of [false, true]) {
    const transport = new StdioClientTransport({
      command: launcher[0],
      args: [
        ...launcher.slice(1),
        "mcp",
        "serve",
        ...common,
        ...(writable ? ["--allow-configuration-write"] : []),
      ],
      env,
      stderr: "pipe",
    });
    let stderr = "";
    transport.stderr?.on("data", (chunk) => {
      if (stderr.length < 4096) stderr += chunk.toString();
    });
    const client = new Client(
      { name: "configuration-parity", version: "1" },
      {
        versionNegotiation: { mode: legacy ? "legacy" : { pin: "2026-07-28" } },
      },
    );
    const call = async (name, args) =>
      client.callTool({ name, arguments: args }, { timeout: 5000 });
    try {
      await client.connect(
        transport,
        legacy
          ? { prior: { kind: "legacy" }, timeout: 5000 }
          : { timeout: 5000 },
      );
      const names = (await client.listTools()).tools.map((t) => t.name);
      assert.equal(names.includes("configuration_list"), true);
      assert.equal(names.includes("configuration_rename_profile"), writable);
      assert.equal(names.includes("receiver_activate"), false);
      const list = await invoke("configuration", "list");
      assert.equal(list.kind, "catalog");
      assert.equal(list.profiles.length, 2);
      const observed = await call("configuration_list", {
        expectedRevision: null,
        offset: 0,
      });
      assert.deepEqual(observed.structuredContent, {
        version: 1,
        ok: true,
        result: list,
      });
      assert.equal(
        (
          await call("configuration_list", {
            expectedRevision: null,
            offset: 0,
            source: "forbidden",
          })
        ).isError,
        true,
      );
      const args = {
        operationId: `sdk-${legacy ? "legacy" : "modern"}`,
        expectedRevision: list.revision,
        profileId: a,
        name: `SDK ${legacy ? "legacy" : "modern"} 🦊`,
      };
      if (!writable)
        await assert.rejects(
          call("configuration_rename_profile", args),
          /tool_unavailable/,
        );
      else {
        const flags = [
          "--operation-id",
          args.operationId,
          "--expected-revision",
          args.expectedRevision,
          "--profile-id",
          a.toUpperCase(),
          "--name",
          args.name,
        ];
        const [mcp, cliResult] = await Promise.all([
          call("configuration_rename_profile", args),
          invoke("configuration", "rename-profile", flags),
        ]);
        assert.notEqual(mcp.isError, true);
        const written = mcp.structuredContent.result;
        assert.equal(written.kind, "committed");
        assert.deepEqual(written.receipt, cliResult.receipt);
        assert.notEqual(written.replayed, cliResult.replayed);
        assert.deepEqual(
          (await call("configuration_rename_profile", args)).structuredContent
            .result,
          { ...written, replayed: true },
        );
        const conflict = await call("configuration_rename_profile", {
          ...args,
          operationId: `stale-${scenarios}`,
        });
        assert.deepEqual(conflict.structuredContent.result, {
          version: 1,
          kind: "conflict",
          currentRevision: written.receipt.resultingRevision,
        });
        const altered = await call("configuration_rename_profile", {
          ...args,
          name: "Changed payload",
        });
        assert.equal(altered.isError, true);
        assert.equal(altered.structuredContent.error, "operation_id_reused");
        const current = await invoke("configuration", "list");
        assert.equal(current.profiles.find((p) => p.id === a).name, args.name);
        assert.equal(
          current.activeProfileId,
          "bbbbbbbb-0000-0000-0000-000000000002",
        );
        assert.equal(current.revision, written.receipt.resultingRevision);
      }
    } finally {
      await client.close();
      assert.equal(stderr, "");
    }
    assert.equal(
      (await invoke("receiver", "status")).receiver.snapshot.inputEnabled,
      false,
    );
    scenarios++;
  }
console.log(
  JSON.stringify({
    ok: true,
    scenarios,
    server: cli.endsWith(".ts") ? "bun-source" : "standalone",
  }),
);
