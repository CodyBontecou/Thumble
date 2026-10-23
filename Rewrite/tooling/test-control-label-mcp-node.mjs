// Independent Node SDK witness. Synthetic starter only; no phone or OS output.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
const [bun, cli, receiver, runtime, profileId, controlId] =
  process.argv.slice(2);
assert(
  [bun, cli, receiver, runtime].every(
    (p) => typeof p === "string" && isAbsolute(p),
  ),
);
assert([profileId, controlId].every((p) => /^[a-f0-9-]{36}$/.test(p)));
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
async function assertInactiveRecording() {
  const snapshot = (await invoke("receiver", "status")).receiver.snapshot;
  assert.equal(snapshot.inputEnabled, false);
  assert.equal(snapshot.active, false);
}
const directory = realpathSync(
  mkdtempSync(join(tmpdir(), "thumble-label-sdk-")),
);
let exportNumber = 0;
async function exportedLabel() {
  const list = await invoke("configuration", "list");
  const operationId = `label-export-${exportNumber++}`;
  const file = join(directory, `${operationId}.json`);
  const flags = [
    "--operation-id",
    operationId,
    "--expected-revision",
    list.revision,
    "--expected-source-hash",
    list.contentHash,
    "--file",
    file,
  ];
  let result = await invoke("configuration", "export-file", flags);
  const deadline = Date.now() + 5000;
  while (result.kind === "export-pending" && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 20));
    result = await invoke("configuration", "export-status", flags);
  }
  const fixedExportErrors = new Set([
    "configuration_export_directory_unsafe",
    "configuration_export_directory_unavailable",
    "configuration_export_path_invalid",
    "configuration_export_file_unsafe",
    "configuration_export_exists",
  ]);
  const exportCode =
    result.kind === "export-failed" && fixedExportErrors.has(result.error)
      ? result.error
      : "configuration_export_failed";
  assert.equal(result.kind, "exported", exportCode);
  const bytes = readFileSync(file);
  assert(bytes.length <= 8388608);
  const document = JSON.parse(bytes);
  const profile = document.profiles.find((p) => p.id === profileId);
  assert(profile);
  return profile.customization.labelOverrides?.[controlId];
}
let scenarios = 0;
let durable;
try {
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
        { name: "control-label-parity", version: "1" },
        {
          versionNegotiation: {
            mode: legacy ? "legacy" : { pin: "2026-07-28" },
          },
        },
      );
      const call = (args) =>
        client.callTool(
          { name: "configuration_set_control_label", arguments: args },
          { timeout: 5000 },
        );
      try {
        await client.connect(
          transport,
          legacy
            ? { prior: { kind: "legacy" }, timeout: 5000 }
            : { timeout: 5000 },
        );
        const names = (await client.listTools()).tools.map((tool) => tool.name);
        assert.equal(
          names.includes("configuration_set_control_label"),
          writable,
        );
        assert.equal(names.includes("receiver_activate"), false);
        const list = await invoke("configuration", "list");
        const args = {
          operationId: `label-sdk-${legacy ? "legacy" : "modern"}`,
          expectedRevision: list.revision,
          profileId,
          controlId,
          label: `Saved ${legacy ? "legacy" : "modern"} 🦊`,
        };
        if (!writable) await assert.rejects(call(args), /tool_unavailable/);
        else {
          const flags = [
            "--operation-id",
            args.operationId,
            "--expected-revision",
            args.expectedRevision,
            "--profile-id",
            profileId.toUpperCase(),
            "--control-id",
            controlId.toUpperCase(),
            "--label",
            args.label,
          ];
          const [mcp, cliResult] = await Promise.all([
            call(args),
            invoke("configuration", "set-control-label", flags),
          ]);
          assert.notEqual(mcp.isError, true);
          const written = mcp.structuredContent.result;
          assert.equal(written.kind, "committed");
          assert.deepEqual(written.receipt, cliResult.receipt);
          assert.deepEqual(written.receipt.affectedEntities, [
            profileId,
            controlId,
          ]);
          assert.notEqual(written.replayed, cliResult.replayed);
          assert.equal(await exportedLabel(), args.label);
          assert.deepEqual((await call(args)).structuredContent.result, {
            ...written,
            replayed: true,
          });
          const stale = await call({
            ...args,
            operationId: `stale-${scenarios}`,
          });
          assert.deepEqual(stale.structuredContent.result, {
            version: 1,
            kind: "conflict",
            currentRevision: written.receipt.resultingRevision,
          });
          const reused = await call({ ...args, label: "Changed intent" });
          assert.equal(reused.isError, true);
          assert.equal(reused.structuredContent.error, "operation_id_reused");
          const blank = {
            ...args,
            operationId: `blank-${scenarios}`,
            expectedRevision: written.receipt.resultingRevision,
            label: "",
          };
          const blankResult = (await call(blank)).structuredContent.result;
          assert.equal(blankResult.kind, "committed");
          assert.equal(await exportedLabel(), "");
          const clear = {
            ...args,
            operationId: `clear-${scenarios}`,
            expectedRevision: blankResult.receipt.resultingRevision,
            label: null,
          };
          const clearResult = await invoke(
            "configuration",
            "set-control-label",
            [
              "--operation-id",
              clear.operationId,
              "--expected-revision",
              clear.expectedRevision,
              "--profile-id",
              profileId,
              "--control-id",
              controlId,
              "--clear-label",
            ],
          );
          assert.equal(clearResult.kind, "committed");
          assert.equal(await exportedLabel(), undefined);
          assert.deepEqual((await call(clear)).structuredContent.result, {
            ...clearResult,
            replayed: true,
          });
          durable = { args, written };
        }
      } finally {
        await client.close();
        assert.equal(stderr, "");
      }
      await assertInactiveRecording();
      scenarios++;
    }
  const current = await invoke("configuration", "list");
  await invoke("service", "stop");
  await invoke("service", "start");
  assert.deepEqual(await invoke("configuration", "list"), current);
  const { args, written } = durable;
  const replay = await invoke("configuration", "set-control-label", [
    "--operation-id",
    args.operationId,
    "--expected-revision",
    args.expectedRevision,
    "--profile-id",
    profileId,
    "--control-id",
    controlId,
    "--label",
    args.label,
  ]);
  assert.deepEqual(replay, { ...written, replayed: true });
  assert.equal(await exportedLabel(), undefined);
  await assertInactiveRecording();
  console.log(
    JSON.stringify({
      ok: true,
      scenarios,
      concurrentReceipt: true,
      blankAndClear: true,
      restartReplay: true,
      inputActivated: false,
    }),
  );
} finally {
  rmSync(directory, { recursive: true, force: true });
}
