// Synthetic recording-only Node SDK witness; no phone or physical output.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { isAbsolute } from "node:path";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
const [bun, cli, receiver, runtime, a, b, c] = process.argv.slice(2);
assert(
  [bun, cli, receiver, runtime].every(
    (p) => typeof p === "string" && isAbsolute(p),
  ),
);
assert(
  [a, b, c].every((p) =>
    /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/.test(p),
  ),
);
const launcher = cli.endsWith(".ts") ? [bun, cli] : [cli];
const common = ["--runtime-dir", runtime, "--receiver", receiver];
const execute = promisify(execFile);
async function invoke(family, action, flags = []) {
  const result = await execute(
    launcher[0],
    [...launcher.slice(1), family, action, ...common, ...flags],
    { timeout: 5000, maxBuffer: 65536, windowsHide: true },
  );
  assert.equal(result.stderr, "");
  const value = JSON.parse(result.stdout);
  assert.equal(value.ok, true);
  return value.result;
}
function flags(args) {
  return [
    "--operation-id",
    args.operationId,
    "--expected-revision",
    args.expectedRevision,
    "--profile-id",
    args.profileId.toUpperCase(),
    "--active-profile-id",
    args.activeProfileId.toUpperCase(),
    "--default-profile-id",
    args.defaultProfileId?.toUpperCase() ?? "none",
  ];
}
const initial = await invoke("configuration", "list");
assert.deepEqual(
  initial.profiles.map((p) => p.id),
  [a, b, c],
);
await invoke("receiver", "activate-saved", [
  "--expected-receiver-revision",
  "0",
  "--expected-configuration-revision",
  initial.revision,
  "--expected-source-hash",
  initial.contentHash,
  "--profile-id",
  a,
]);
const installed = await invoke("receiver", "saved-status");
assert.equal(installed.snapshot.active, true);
assert.equal(installed.snapshot.backend, "recording");
assert.equal(installed.snapshot.inputEnabled, false);
assert.equal(installed.savedBinding.profileId, a);
async function assertInstalled() {
  const now = await invoke("receiver", "saved-status");
  assert.deepEqual(now.savedBinding, installed.savedBinding);
  assert.equal(now.snapshot.active, true);
  assert.equal(now.snapshot.inputEnabled, false);
  assert.equal(now.snapshot.generation, installed.snapshot.generation);
  assert.equal(now.snapshot.revision, installed.snapshot.revision);
}
let scenarios = 0;
let durable;
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
      stderr: "pipe",
    });
    let stderr = "";
    transport.stderr?.on("data", (bytes) => {
      if (stderr.length < 4096)
        stderr += bytes.toString().slice(0, 4096 - stderr.length);
    });
    const client = new Client(
      { name: "profile-delete-parity", version: "1" },
      {
        versionNegotiation: { mode: legacy ? "legacy" : { pin: "2026-07-28" } },
      },
    );
    const call = (args) =>
      client.callTool(
        { name: "configuration_delete_profile", arguments: args },
        { timeout: 5000 },
      );
    try {
      await client.connect(
        transport,
        legacy
          ? { prior: { kind: "legacy" }, timeout: 5000 }
          : { timeout: 5000 },
      );
      const tools = (await client.listTools()).tools;
      const tool = tools.find((t) => t.name === "configuration_delete_profile");
      assert.equal(!!tool, writable);
      assert.equal(
        tools.some((t) => t.name === "receiver_activate"),
        false,
      );
      const catalog = await invoke("configuration", "list");
      const args = {
        operationId: `delete-${legacy ? "legacy" : "modern"}`,
        expectedRevision: catalog.revision,
        profileId: legacy ? a : b,
        activeProfileId: legacy ? c : a,
        defaultProfileId: c,
      };
      if (!writable) {
        let rejection;
        try {
          await call(args);
        } catch (error) {
          rejection = error;
        }
        assert(
          rejection instanceof Error &&
            /tool_unavailable/.test(rejection.message),
        );
      } else {
        assert.equal(tool.annotations.destructiveHint, true);
        assert.equal(tool.annotations.idempotentHint, true);
        const [mcp, cliResult] = await Promise.all([
          call(args),
          invoke("configuration", "delete-profile", flags(args)),
        ]);
        assert.notEqual(mcp.isError, true);
        const written = mcp.structuredContent.result;
        assert.equal(written.kind, "committed");
        assert.deepEqual(written.receipt, cliResult.receipt);
        assert.notEqual(written.replayed, cliResult.replayed);
        assert.deepEqual(written.receipt.affectedEntities, [
          "configuration",
          args.profileId,
        ]);
        assert.deepEqual((await call(args)).structuredContent.result, {
          ...written,
          replayed: true,
        });
        assert.deepEqual(
          (await call({ ...args, operationId: `stale-${scenarios}` }))
            .structuredContent.result,
          {
            version: 1,
            kind: "conflict",
            currentRevision: written.receipt.resultingRevision,
          },
        );
        const reused = await call({ ...args, defaultProfileId: null });
        assert.equal(reused.isError, true);
        assert.equal(reused.structuredContent.error, "operation_id_reused");
        if (!legacy) durable = { args, written };
        else {
          const last = await call({
            ...args,
            operationId: "delete-last",
            expectedRevision: written.receipt.resultingRevision,
            profileId: c,
            activeProfileId: c,
          });
          assert.equal(last.isError, true);
          assert.equal(
            last.structuredContent.error,
            "configuration_last_profile",
          );
        }
      }
    } finally {
      await client.close();
      assert.equal(stderr, "");
    }
    await assertInstalled();
    scenarios++;
  }
const current = await invoke("configuration", "list");
assert.deepEqual(
  current.profiles.map((p) => p.id),
  [c],
);
assert.equal(current.activeProfileId, c);
assert.equal(current.defaultProfileId, c);
await invoke("receiver", "release");
assert.equal(
  (await invoke("receiver", "status")).receiver.snapshot.active,
  false,
);
await invoke("service", "stop");
await invoke("service", "start");
assert.deepEqual(await invoke("configuration", "list"), current);
const replay = await invoke(
  "configuration",
  "delete-profile",
  flags(durable.args),
);
assert.deepEqual(replay, { ...durable.written, replayed: true });
assert.deepEqual(await invoke("configuration", "list"), current);
const restarted = (await invoke("receiver", "status")).receiver.snapshot;
assert.equal(restarted.active, false);
assert.equal(restarted.inputEnabled, false);
console.log(
  JSON.stringify({
    ok: true,
    scenarios,
    concurrentReceipt: true,
    restartReplay: true,
    installedPinPreserved: true,
    explicitRelease: true,
    physicalOutput: false,
  }),
);
