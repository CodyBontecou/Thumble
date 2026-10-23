// Independent modern/legacy MCP and CLI saved-configuration parity; synthetic fixture only.
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
  lastExport,
  lastSelection,
  lastDuplicate;
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
          "configuration_select_profiles",
          "configuration_duplicate_profile",
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
          await assert.rejects(
            call("configuration_select_profiles", {
              operationId: "denied-selection",
              expectedRevision: catalog.revision,
              activeProfileId:
                catalog.profiles[0]?.id ??
                "aaaaaaaa-0000-0000-0000-000000000001",
              defaultProfileId: null,
            }),
            /tool_unavailable/,
          );
          await assert.rejects(
            call("configuration_duplicate_profile", {
              operationId: "denied-copy",
              expectedRevision: catalog.revision,
              profileId: "aaaaaaaa-0000-0000-0000-000000000001",
              newProfileId: "fa000000-0000-0000-0000-000000000001",
              name: "Copy",
              select: false,
            }),
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
          const copies = [];
          for (const selectCopy of [false, true]) {
            const beforeCopy = await invoke("configuration", "list"),
              sourceIndex = selectCopy ? 1 : 0;
            const duplicate = {
              operationId: `copy-${legacy ? "legacy" : "modern"}-${selectCopy ? "select" : "keep"}`,
              expectedRevision: beforeCopy.revision,
              profileId: beforeCopy.profiles[sourceIndex].id,
              newProfileId: `fb000000-0000-0000-0000-${String(100 + scenarios * 2 + (selectCopy ? 1 : 0)).padStart(12, "0")}`,
              name: `  Copy ${sourceIndex} 🦊  `,
              select: selectCopy,
            };
            const duplicateFlags = [
              "--operation-id",
              duplicate.operationId,
              "--expected-revision",
              duplicate.expectedRevision,
              "--profile-id",
              duplicate.profileId.toUpperCase(),
              "--new-profile-id",
              duplicate.newProfileId.toUpperCase(),
              "--name",
              duplicate.name,
              selectCopy ? "--select" : "--keep-selection",
            ];
            const noSelection = duplicateFlags.slice(0, -1);
            for (const invalidFlags of [
              noSelection,
              [...noSelection, "--select", "--keep-selection"],
            ])
              await assert.rejects(
                execute(
                  launcher[0],
                  [
                    ...launcher.slice(1),
                    "configuration",
                    "duplicate-profile",
                    ...common,
                    ...invalidFlags,
                  ],
                  { timeout: 5000, maxBuffer: 65536, windowsHide: true, env },
                ),
                (error) =>
                  JSON.parse(error.stdout).error ===
                  "configuration_selection_required",
              );
            const missingSelect = { ...duplicate };
            delete missingSelect.select;
            assert.equal(
              (await call("configuration_duplicate_profile", missingSelect))
                .isError,
              true,
            );
            const [copiedMcp, copiedCli] = await Promise.all([
              call("configuration_duplicate_profile", duplicate),
              invoke("configuration", "duplicate-profile", duplicateFlags),
            ]);
            assert.notEqual(copiedMcp.isError, true);
            const copied = copiedMcp.structuredContent.result;
            assert.equal(copied.kind, "committed");
            assert.deepEqual(copied.receipt, copiedCli.receipt);
            assert.notEqual(copied.replayed, copiedCli.replayed);
            assert.deepEqual(copied.receipt.affectedEntities, [
              "configuration",
              duplicate.newProfileId,
            ]);
            const afterCopy = await invoke("configuration", "list");
            assert.equal(
              afterCopy.profiles.length,
              beforeCopy.profiles.length + 1,
            );
            assert.equal(
              afterCopy.profiles.find(
                (profile) => profile.id === duplicate.newProfileId,
              ).name,
              duplicate.name.trim(),
            );
            assert.equal(
              afterCopy.activeProfileId,
              selectCopy ? duplicate.newProfileId : beforeCopy.activeProfileId,
            );
            assert.equal(
              afterCopy.defaultProfileId,
              beforeCopy.defaultProfileId,
            );
            const changedCopy = await call("configuration_duplicate_profile", {
              ...duplicate,
              select: !selectCopy,
            });
            assert.equal(
              changedCopy.structuredContent.error,
              "operation_id_reused",
            );
            const staleCopy = await call("configuration_duplicate_profile", {
              ...duplicate,
              operationId: `stale-${duplicate.operationId}`,
            });
            assert.deepEqual(staleCopy.structuredContent.result, {
              version: 1,
              kind: "conflict",
              currentRevision: afterCopy.revision,
            });
            copies.push({ args: duplicate, sourceIndex });
            lastDuplicate = {
              args: duplicate,
              result: copied,
              flags: duplicateFlags,
            };
          }
          const beforeSelection = await invoke("configuration", "list");
          const selection = {
            operationId: `select-${legacy ? "legacy" : "modern"}`,
            expectedRevision: beforeSelection.revision,
            activeProfileId: beforeSelection.profiles[1].id,
            defaultProfileId: beforeSelection.profiles[0].id,
          };
          const selectionFlags = (args) => [
            "--operation-id",
            args.operationId,
            "--expected-revision",
            args.expectedRevision,
            "--active-profile-id",
            args.activeProfileId.toUpperCase(),
            "--default-profile-id",
            args.defaultProfileId === null
              ? "none"
              : args.defaultProfileId.toUpperCase(),
          ];
          const [selectedMcp, selectedCli] = await Promise.all([
            call("configuration_select_profiles", selection),
            invoke(
              "configuration",
              "select-profiles",
              selectionFlags(selection),
            ),
          ]);
          assert.notEqual(selectedMcp.isError, true);
          const selected = selectedMcp.structuredContent.result;
          assert.equal(selected.kind, "committed");
          assert.deepEqual(selected.receipt, selectedCli.receipt);
          assert.notEqual(selected.replayed, selectedCli.replayed);
          assert.deepEqual(selected.receipt.affectedEntities, [
            "configuration",
          ]);
          const afterSelection = await invoke("configuration", "list");
          assert.equal(
            afterSelection.activeProfileId,
            selection.activeProfileId,
          );
          assert.equal(
            afterSelection.defaultProfileId,
            selection.defaultProfileId,
          );
          assert.equal(
            afterSelection.revision,
            selected.receipt.resultingRevision,
          );
          const staleSelection = await call("configuration_select_profiles", {
            ...selection,
            operationId: `stale-selection-${scenarios}`,
          });
          assert.deepEqual(staleSelection.structuredContent.result, {
            version: 1,
            kind: "conflict",
            currentRevision: afterSelection.revision,
          });
          const alteredSelection = await call("configuration_select_profiles", {
            ...selection,
            defaultProfileId: null,
          });
          assert.equal(
            alteredSelection.structuredContent.error,
            "operation_id_reused",
          );
          const missingSelection = await call("configuration_select_profiles", {
            ...selection,
            operationId: `missing-selection-${scenarios}`,
            expectedRevision: afterSelection.revision,
            defaultProfileId: "cccccccc-0000-0000-0000-000000000003",
          });
          assert.equal(
            missingSelection.structuredContent.error,
            "profile_not_found",
          );
          const clearSelection = {
            ...selection,
            operationId: `clear-selection-${scenarios}`,
            expectedRevision: afterSelection.revision,
            defaultProfileId: null,
          };
          const cleared = await invoke(
            "configuration",
            "select-profiles",
            selectionFlags(clearSelection),
          );
          assert.equal(cleared.kind, "committed");
          lastSelection = {
            args: selection,
            result: selected,
            flags: selectionFlags(selection),
          };
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
          const restoredDocument = JSON.parse(
              readFileSync(exportArgs.path, "utf8"),
            ),
            originalDocument = JSON.parse(readFileSync(file, "utf8"));
          const storedActiveId = originalDocument.profiles.find(
            (profile) => profile.id.toLowerCase() === selection.activeProfileId,
          ).id;
          assert.equal(restoredDocument.activeProfileID, storedActiveId);
          assert.equal(restoredDocument.defaultProfileID, null);
          for (const key of Object.keys(originalDocument))
            if (
              ![
                "activeProfileID",
                "defaultProfileID",
                "keyBindings",
                "outputBindings",
                "profileKeyBindings",
                "profileOutputBindings",
                "profiles",
              ].includes(key)
            )
              assert.deepEqual(restoredDocument[key], originalDocument[key]);
          assert.deepEqual(
            restoredDocument.profiles.slice(
              0,
              originalDocument.profiles.length,
            ),
            originalDocument.profiles,
          );
          assert.equal(
            restoredDocument.profiles.length,
            originalDocument.profiles.length + copies.length,
          );
          for (const copy of copies) {
            const actual = restoredDocument.profiles.find(
                (profile) => profile.id === copy.args.newProfileId,
              ),
              original = originalDocument.profiles[copy.sourceIndex];
            assert.equal(actual.name, copy.args.name.trim());
            for (const key of Object.keys(original))
              if (!["id", "name", "updatedAt"].includes(key))
                assert.deepEqual(actual[key], original[key]);
          }
          for (const [root, map] of [
            ["keyBindings", "profileKeyBindings"],
            ["outputBindings", "profileOutputBindings"],
          ]) {
            assert.deepEqual(
              restoredDocument[root],
              restoredDocument[map][storedActiveId],
            );
            for (const [id, value] of Object.entries(originalDocument[map]))
              if (id.toLowerCase() !== selection.activeProfileId)
                assert.deepEqual(restoredDocument[map][id], value);
          }
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
  const recoveredSelection = await invoke(
    "configuration",
    "select-profiles",
    lastSelection.flags,
  );
  assert.deepEqual(recoveredSelection, {
    ...lastSelection.result,
    replayed: true,
  });

  const recoveredDuplicate = await invoke(
    "configuration",
    "duplicate-profile",
    lastDuplicate.flags,
  );
  assert.deepEqual(recoveredDuplicate, {
    ...lastDuplicate.result,
    replayed: true,
  });
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
