import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
const [bun, cli, receiver, runtime, fixture] = process.argv.slice(2),
  launcher = cli.endsWith(".ts") ? [bun, cli] : [cli],
  common = ["--runtime-dir", runtime, "--receiver", receiver],
  execute = promisify(execFile);
async function invoke(family, action, args = [], success = true) {
  let out;
  try {
    out = await execute(
      launcher[0],
      [
        ...launcher.slice(1),
        family,
        action,
        ...(action === "validate-file" ? [] : common),
        ...args,
      ],
      { timeout: 5000, maxBuffer: 65536, windowsHide: true },
    );
  } catch (error) {
    if (success) throw error;
    out = error;
  }
  assert.equal(out.stderr, "");
  const reply = JSON.parse(out.stdout);
  assert.equal(reply.ok, success);
  return success ? reply.result : reply.error;
}
const flags = (revision, pin) => [
  "--expected-receiver-revision",
  revision,
  "--expected-configuration-revision",
  pin.revision,
  "--expected-source-hash",
  pin.contentHash,
  "--profile-id",
  pin.activeProfileId,
];
let scenarios = 0;
try {
  await invoke("service", "start");
  const inspection = await invoke("configuration", "validate-file", [
    "--file",
    fixture,
  ]);
  const importFlags = [
    "--operation-id",
    "saved-activation-seed",
    "--expected-revision",
    "0",
    "--expected-source-hash",
    inspection.contentHash,
    "--file",
    fixture,
  ];
  await invoke("configuration", "import-file", importFlags);
  const deadline = performance.now() + 10000;
  let imported;
  do {
    imported = await invoke(
      "configuration",
      "import-status",
      importFlags.slice(0, -2),
    );
    if (imported.kind === "import-pending") await sleep(20);
  } while (imported.kind === "import-pending" && performance.now() < deadline);
  assert.equal(imported.kind, "import-committed");
  let pin = await invoke("configuration", "list");
  assert.equal((await invoke("receiver", "saved-status")).savedBinding, null);
  const first = await invoke("receiver", "activate-saved", flags("0", pin));
  assert.equal(first.savedBinding.sourceHash, pin.contentHash);
  assert.equal(first.savedBinding.configurationRevision, pin.revision);
  assert.equal(first.savedBinding.profileId, pin.activeProfileId);
  assert.equal(first.snapshot.generation, "1");
  assert.equal(first.snapshot.inputEnabled, false);
  assert.equal(
    await invoke("receiver", "activate-saved", flags("0", pin), false),
    "revision_conflict",
  );
  for (const [key, value, error] of [
    ["--expected-source-hash", "0".repeat(64), "configuration_source_changed"],
    [
      "--expected-configuration-revision",
      "99",
      "configuration_revision_conflict",
    ],
    [
      "--profile-id",
      "ffffffff-0000-0000-0000-000000000001",
      "saved_profile_not_selected",
    ],
  ]) {
    const args = flags("1", pin);
    args[args.indexOf(key) + 1] = value;
    assert.equal(
      await invoke("receiver", "activate-saved", args, false),
      error,
    );
  }
  assert.deepEqual(
    (await invoke("receiver", "saved-status")).savedBinding,
    first.savedBinding,
  );
  for (const legacy of [false, true])
    for (const allowed of [false, true]) {
      const transport = new StdioClientTransport({
        command: launcher[0],
        args: [
          ...launcher.slice(1),
          "mcp",
          "serve",
          ...common,
          ...(allowed ? ["--allow-recorded-input"] : []),
        ],
        stderr: "pipe",
      });
      const client = new Client(
        { name: "saved-activation-witness", version: "1" },
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
        const tools = (await client.listTools()).tools;
        assert.equal(
          tools.some((t) => t.name === "receiver_activate_saved"),
          allowed,
        );
        assert.equal(
          tools.find((t) => t.name === "receiver_saved_status").annotations
            .readOnlyHint,
          true,
        );
        const status = (
          await client.callTool({
            name: "receiver_saved_status",
            arguments: {},
          })
        ).structuredContent.result;
        if (allowed) {
          const reply = await client.callTool({
            name: "receiver_activate_saved",
            arguments: {
              expectedReceiverRevision: status.snapshot.revision,
              expectedConfigurationRevision: pin.revision,
              expectedSourceHash: pin.contentHash,
              profileId: pin.activeProfileId,
            },
          });
          assert.notEqual(reply.isError, true);
          const bound = reply.structuredContent.result;
          assert.equal(
            BigInt(bound.snapshot.generation),
            BigInt(status.snapshot.generation) + 1n,
          );
          assert.equal(bound.savedBinding.sourceHash, pin.contentHash);
          assert.deepEqual(
            (await invoke("receiver", "saved-status")).savedBinding,
            bound.savedBinding,
          );
        } else
          await assert.rejects(
            client.callTool({ name: "receiver_activate_saved", arguments: {} }),
            /tool_unavailable/,
          );
        scenarios++;
      } finally {
        await client.close();
        await transport.close();
      }
    }
  const pinnedBeforeEdit = await invoke("receiver", "saved-status");
  await invoke("configuration", "rename-profile", [
    "--operation-id",
    "saved-rename",
    "--expected-revision",
    pin.revision,
    "--profile-id",
    pin.activeProfileId,
    "--name",
    "Renamed pinned profile",
  ]);
  const afterEdit = await invoke("receiver", "saved-status");
  assert.deepEqual(afterEdit.savedBinding, pinnedBeforeEdit.savedBinding);
  assert.equal(
    await invoke(
      "receiver",
      "activate-saved",
      flags(afterEdit.snapshot.revision, pin),
      false,
    ),
    "configuration_revision_conflict",
  );
  pin = await invoke("configuration", "list");
  const reactivated = await invoke(
    "receiver",
    "activate-saved",
    flags(afterEdit.snapshot.revision, pin),
  );
  assert.equal(reactivated.savedBinding.configurationRevision, pin.revision);
  assert.equal(reactivated.savedBinding.sourceHash, pin.contentHash);
  const before = await invoke("receiver", "saved-status");
  await invoke("receiver", "activate", [
    "--expected-revision",
    before.snapshot.revision,
    "--profile-id",
    pin.activeProfileId,
  ]);
  assert.equal((await invoke("receiver", "saved-status")).savedBinding, null);
  const fresh = await invoke("receiver", "status");
  await invoke(
    "receiver",
    "activate-saved",
    flags(fresh.receiver.snapshot.revision, pin),
  );
  await invoke("receiver", "release");
  assert.equal((await invoke("receiver", "saved-status")).savedBinding, null);
  await invoke("service", "stop");
  const end = performance.now() + 5000;
  while (existsSync(join(runtime, "endpoint.json")) && performance.now() < end)
    await sleep(20);
  await invoke("service", "start");
  assert.equal((await invoke("receiver", "saved-status")).savedBinding, null);
  console.log(
    JSON.stringify({
      ok: true,
      scenarios,
      recordingOnly: true,
      server: cli.endsWith(".ts") ? "source" : "standalone",
    }),
  );
} finally {
  if (existsSync(join(runtime, "endpoint.json")))
    try {
      await invoke("service", "stop");
    } catch {}
}
