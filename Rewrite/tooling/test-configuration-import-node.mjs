// Independent modern/legacy MCP and CLI import parity, synthetic local fixture only.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { copyFileSync, existsSync, readFileSync, rmSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
const [bun, cli, receiver, runtime, fixture, restrictedPath] =
  process.argv.slice(2);
if (
  ![bun, cli, receiver, runtime, fixture].every(
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
const file = join(dirname(runtime), "import-source.json");
copyFileSync(fixture, file);
async function invoke(family, action, flags = []) {
  const result = await execute(
    launcher[0],
    [
      ...launcher.slice(1),
      family,
      action,
      ...(action === "validate-file" ? [] : common),
      ...flags,
    ],
    { timeout: 5000, maxBuffer: 65536, windowsHide: true, env },
  );
  assert.equal(result.stderr, "");
  const reply = JSON.parse(result.stdout);
  assert.equal(reply.ok, true);
  return reply.result;
}
const statusArgs = (command) => ({
  operationId: command.operationId,
  expectedRevision: command.expectedRevision,
  expectedSourceHash: command.expectedSourceHash,
});
const flags = (args) => [
  "--operation-id",
  args.operationId,
  "--expected-revision",
  args.expectedRevision,
  "--expected-source-hash",
  args.expectedSourceHash,
];
let scenarios = 0,
  last,
  lastExport;
try {
  await invoke("service", "start");
  const inspection = await invoke("configuration", "validate-file", [
    "--file",
    file,
  ]);
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
        { name: "owned-import-parity", version: "1" },
        {
          versionNegotiation: {
            mode: legacy ? "legacy" : { pin: "2026-07-28" },
          },
        },
      );
      const call = (name, arguments_) =>
        client.callTool({ name, arguments: arguments_ }, { timeout: 5000 });
      try {
        await client.connect(
          transport,
          legacy
            ? { prior: { kind: "legacy" }, timeout: 5000 }
            : { timeout: 5000 },
        );
        const names = (await client.listTools()).tools.map((tool) => tool.name);
        for (const name of [
          "configuration_import_file",
          "configuration_import_status",
          "configuration_export_file",
          "configuration_export_status",
        ])
          assert.equal(names.includes(name), writable);
        const catalog = await invoke("configuration", "list");
        const args = {
          operationId: `import-${legacy ? "legacy" : "modern"}`,
          expectedRevision: catalog.revision,
          expectedSourceHash: inspection.contentHash,
          path: file,
        };
        if (!writable) {
          await assert.rejects(
            call("configuration_import_file", args),
            /tool_unavailable/,
          );
          await assert.rejects(
            call("configuration_export_file", args),
            /tool_unavailable/,
          );
        } else {
          const [mcpStart, cliStart] = await Promise.all([
            call("configuration_import_file", args),
            invoke("configuration", "import-file", [
              ...flags(args),
              "--file",
              file,
            ]),
          ]);
          assert.notEqual(mcpStart.isError, true);
          assert.match(
            mcpStart.structuredContent.result.kind,
            /^import-(pending|committed)$/,
          );
          assert.match(cliStart.kind, /^import-(pending|committed)$/);
          let result;
          const deadline = performance.now() + 10000;
          do {
            const response = await call(
              "configuration_import_status",
              statusArgs(args),
            );
            assert.notEqual(response.isError, true);
            result = response.structuredContent.result;
            if (result.kind === "import-pending") await sleep(20);
          } while (
            result.kind === "import-pending" &&
            performance.now() < deadline
          );
          assert.equal(result.kind, "import-committed");
          assert.equal(result.validation, "owned-v5-structural");
          assert.equal(result.activationCompatibility, "not-evaluated");
          assert.deepEqual(result.receipt.affectedEntities, ["configuration"]);
          assert.equal(
            result.receipt.resultingRevision,
            (BigInt(catalog.revision) + 1n).toString(),
          );
          assert.equal(JSON.stringify(result).includes(file), false);
          const cliStatus = await invoke(
            "configuration",
            "import-status",
            flags(args),
          );
          assert.deepEqual(cliStatus.receipt, result.receipt);
          const replay = await call("configuration_import_file", args);
          assert.equal(replay.structuredContent.result.replayed, true);
          assert.deepEqual(
            replay.structuredContent.result.receipt,
            result.receipt,
          );
          const reused = await call("configuration_import_file", {
            ...args,
            expectedSourceHash: "f".repeat(64),
          });
          assert.equal(reused.structuredContent.error, "operation_id_reused");
          const invalid = {
            ...args,
            operationId: `invalid-${scenarios}`,
            expectedRevision: result.receipt.resultingRevision,
            expectedSourceHash: "0".repeat(64),
          };
          await call("configuration_import_file", invalid);
          let failed;
          do {
            failed = (
              await call("configuration_import_status", statusArgs(invalid))
            ).structuredContent.result;
            if (failed.kind === "import-pending") await sleep(20);
          } while (
            failed.kind === "import-pending" &&
            performance.now() < deadline
          );
          assert.equal(failed.kind, "import-failed");
          assert.equal(failed.error, "configuration_source_changed");
          assert.equal(
            (await invoke("configuration", "list")).revision,
            result.receipt.resultingRevision,
          );
          const authority = await invoke("configuration", "list");
          const exportArgs = {
            operationId: `export-${legacy ? "legacy" : "modern"}`,
            expectedRevision: authority.revision,
            expectedSourceHash: authority.contentHash,
            path: join(
              dirname(runtime),
              `export-${legacy ? "legacy" : "modern"}.json`,
            ),
          };
          const exportFlags = [...flags(exportArgs), "--file", exportArgs.path];
          const [mcpExport, cliExport] = await Promise.all([
            call("configuration_export_file", exportArgs),
            invoke("configuration", "export-file", exportFlags),
          ]);
          assert.notEqual(mcpExport.isError, true);
          assert.match(
            mcpExport.structuredContent.result.kind,
            /^(export-pending|exported)$/,
          );
          assert.match(cliExport.kind, /^(export-pending|exported)$/);
          let exported;
          do {
            exported = (await call("configuration_export_status", exportArgs))
              .structuredContent.result;
            if (exported.kind === "export-pending") await sleep(20);
          } while (
            exported.kind === "export-pending" &&
            performance.now() < deadline
          );
          assert.equal(exported.kind, "exported");
          assert.equal(exported.revision, authority.revision);
          assert.equal(exported.sourceHash, authority.contentHash);
          assert.equal(
            exported.byteCount,
            readFileSync(exportArgs.path).length,
          );
          assert.equal(
            JSON.stringify(exported).includes(exportArgs.path),
            false,
          );
          assert.deepEqual(
            JSON.parse(readFileSync(exportArgs.path, "utf8")),
            JSON.parse(readFileSync(file, "utf8")),
          );
          const cliExportStatus = await invoke(
            "configuration",
            "export-status",
            exportFlags,
          );
          assert.deepEqual(cliExportStatus, exported);
          const badExport = await call("configuration_export_file", {
            ...exportArgs,
            path: join(dirname(runtime), "different-output.json"),
          });
          assert.equal(
            badExport.structuredContent.error,
            "operation_id_reused",
          );
          assert.equal(
            (await invoke("configuration", "list")).revision,
            authority.revision,
          );
          lastExport = {
            args: exportArgs,
            result: exported,
            flags: exportFlags,
          };
          last = { args, result };
        }
        const receiverStatus = await invoke("receiver", "status");
        assert.equal(receiverStatus.receiver.snapshot.inputEnabled, false);
        assert.equal(receiverStatus.receiver.snapshot.active, false);
      } finally {
        await client.close();
        assert.equal(stderr, "");
      }
      scenarios++;
    }
  await invoke("service", "stop");
  rmSync(file);
  await invoke("service", "start");
  const pending = await invoke("configuration", "import-file", [
    ...flags(last.args),
    "--file",
    file,
  ]);
  assert.equal(pending.kind, "import-pending");
  let recovered;
  const deadline = performance.now() + 10000;
  do {
    recovered = await invoke(
      "configuration",
      "import-status",
      flags(last.args),
    );
    if (recovered.kind === "import-pending") await sleep(20);
  } while (recovered.kind === "import-pending" && performance.now() < deadline);
  assert.deepEqual(recovered, { ...last.result, replayed: true });
  const exportPending = await invoke(
    "configuration",
    "export-file",
    lastExport.flags,
  );
  assert.equal(exportPending.kind, "export-pending");
  let exported;
  do {
    exported = await invoke("configuration", "export-status", lastExport.flags);
    if (exported.kind === "export-pending") await sleep(20);
  } while (exported.kind === "export-pending" && performance.now() < deadline);
  assert.deepEqual(exported, { ...lastExport.result, replayed: true });

  console.log(
    JSON.stringify({
      ok: true,
      scenarios,
      imports: 2,
      server: cli.endsWith(".ts") ? "bun-source" : "standalone",
    }),
  );
} finally {
  if (existsSync(join(runtime, "endpoint.json")))
    try {
      await invoke("service", "stop");
    } catch {}
  const deadline = performance.now() + 3000;
  while (
    existsSync(join(runtime, "endpoint.json")) &&
    performance.now() < deadline
  )
    await sleep(20);
  rmSync(file, { force: true });
}
