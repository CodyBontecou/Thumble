// Independent official-SDK client runtime; the product server still runs in Bun.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtempSync, realpathSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { isAbsolute, join } from "node:path";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";

const [bun, cli, receiver, restrictedPath] = process.argv.slice(2);
const source = cli?.endsWith(".ts") === true;
if (![bun, cli, receiver].every((p) => typeof p === "string" && isAbsolute(p)))
  throw new Error("invalid_probe_arguments");
const launcher = source ? [bun, cli] : [cli];
const nativeOptions = source ? ["--receiver", receiver] : [];
const serverEnvironment = {
  ...process.env,
  ...(restrictedPath === undefined ? {} : { PATH: restrictedPath }),
};
const parent = realpathSync(mkdtempSync(join(tmpdir(), "thumble-node-mcp-")));
const runtime = join(parent, "runtime");
const execute = promisify(execFile);
const invoke = async (action) => {
  const { stdout, stderr } = await execute(
    launcher[0],
    [
      ...launcher.slice(1),
      "service",
      action,
      "--runtime-dir",
      runtime,
      ...nativeOptions,
    ],
    {
      timeout: 5000,
      maxBuffer: 65536,
      windowsHide: true,
      env: serverEnvironment,
    },
  );
  assert.equal(stderr, "");
  const value = JSON.parse(stdout);
  assert.equal(value.ok, true);
  return value.result;
};
let phase = "startup";
let trace = [];
let completed = 0;
const eras = new Set();
try {
  await invoke("start");
  const token = JSON.parse(
    readFileSync(join(runtime, "endpoint.json"), "utf8"),
  ).token;
  assert.match(token, /^[0-9a-f]{64}$/);
  for (const legacy of [false, true])
    for (const recording of [false, true]) {
      phase = `connect-${legacy ? "legacy" : "modern"}-${recording ? "recording" : "default"}`;
      trace = [];
      const transport = new StdioClientTransport({
        command: launcher[0],
        args: [
          ...launcher.slice(1),
          "mcp",
          "serve",
          "--runtime-dir",
          runtime,
          ...nativeOptions,
          ...(recording
            ? ["--allow-recorded-input", "--allow-wow-capture"]
            : []),
        ],
        env: { ...serverEnvironment, THUMBLE_REWRITE_MCP_TRACE: "1" },
        stderr: "pipe",
      });
      let stderr = "";
      transport.stderr?.on("data", (chunk) => {
        if (stderr.length < 16000) stderr += chunk.toString();
      });
      const client = new Client(
        { name: "thumble-node-interop", version: "1" },
        {
          versionNegotiation: {
            mode: legacy ? "legacy" : { pin: "2026-07-28" },
          },
        },
      );
      const call = (params) => client.callTool(params, { timeout: 5000 });
      try {
        await client.connect(
          transport,
          legacy
            ? { prior: { kind: "legacy" }, timeout: 5000 }
            : { timeout: 5000 },
        );
        assert.equal(client.getProtocolEra(), legacy ? "legacy" : "modern");
        eras.add(client.getProtocolEra());
        phase = "listing";
        const tools = (
          await client.listTools(undefined, { timeout: 5000 })
        ).tools
          .map((t) => t.name)
          .sort();
        assert.deepEqual(
          tools,
          [
            "output_doctor",
            "wow_capture_status",
            "receiver_status",
            "receiver_saved_status",
            "receiver_release",
            "pairing_status",
            "pairing_list",
            "configuration_list",
            "configuration_validate_file",
            ...(recording
              ? [
                  "receiver_activate",
                  "receiver_activate_saved",
                  "receiver_sample",
                  "wow_capture_start",
                  "wow_capture_request",
                  "wow_capture_stop",
                ]
              : []),
          ].sort(),
        );
        const captureStatus = await call({
          name: "wow_capture_status",
          arguments: {},
        });
        assert.equal(captureStatus.structuredContent.ok, true);
        assert.equal(captureStatus.structuredContent.result.enabled, false);
        assert.equal(
          captureStatus.structuredContent.result.permission,
          "not-inspected",
        );
        if (recording) {
          const captureStart = await call({
            name: "wow_capture_start",
            arguments: {},
          });
          assert.equal(captureStart.structuredContent.ok, false);
          assert.equal(
            captureStart.structuredContent.error,
            "wow_capture_not_enabled",
          );
        }
        phase = "output-doctor";
        const doctor = await call({ name: "output_doctor", arguments: {} });
        assert.equal(doctor.isError, undefined);
        assert.equal(doctor.structuredContent.ok, true);
        assert.equal(doctor.structuredContent.result.backend, "recording");
        assert.equal(
          doctor.structuredContent.result.physicalOutputEnabled,
          false,
        );
        assert.equal(doctor.structuredContent.result.runtimeIntegrated, false);
        assert.equal(
          doctor.structuredContent.result.osDeviceAuthorization,
          "not-inspected",
        );
        phase = "status";
        const status = await call({ name: "receiver_status", arguments: {} });
        assert.deepEqual(status.structuredContent, {
          version: 1,
          ok: true,
          result: await invoke("status"),
        });
        assert.equal(JSON.stringify(status).includes(token), false);
        phase = "invalid-arguments";
        assert.equal(
          (await call({ name: "receiver_release", arguments: { extra: true } }))
            .isError,
          true,
        );
        if (recording) {
          phase = "activate";
          const before = await invoke("status");
          assert.notEqual(
            (
              await call({
                name: "receiver_activate",
                arguments: {
                  expectedRevision: before.receiver.snapshot.revision,
                  profileId: "node-profile",
                },
              })
            ).isError,
            true,
          );
          const current = await invoke("status");
          phase = "sample";
          assert.notEqual(
            (
              await call({
                name: "receiver_sample",
                arguments: {
                  expectedGeneration: current.receiver.snapshot.generation,
                  sequence: "1",
                  state: {
                    buttons: ["south"],
                    leftStickX: 0,
                    leftStickY: 0,
                    rightStickX: 0,
                    rightStickY: 0,
                    leftTrigger: 0,
                    rightTrigger: 0,
                  },
                },
              })
            ).isError,
            true,
          );
          assert.equal(
            (await invoke("status")).receiver.snapshot.sequence,
            "1",
          );
        } else {
          phase = "input-opt-in";
          await assert.rejects(
            call({
              name: "receiver_activate",
              arguments: { expectedRevision: "0", profileId: "node-profile" },
            }),
            /tool_unavailable/,
          );
        }
        phase = "release";
        assert.notEqual(
          (await call({ name: "receiver_release", arguments: {} })).isError,
          true,
        );
        assert.equal((await invoke("status")).receiver.snapshot.active, false);
      } finally {
        await client.close();
        const lines = stderr.split(/\r?\n/);
        trace = lines
          .filter((line) => /^MCP transport phase=[a-z-]+$/.test(line))
          .slice(-128);
        assert.equal(
          lines
            .filter((line) => !/^MCP transport phase=[a-z-]+$/.test(line))
            .join("\n")
            .trim(),
          "",
        );
      }
      completed++;
      phase = "service-survival";
      assert.equal(
        (await invoke("status")).receiver.snapshot.inputEnabled,
        false,
      );
    }
  console.log(
    JSON.stringify({
      ok: true,
      runtime: process.version,
      eras: [...eras],
      scenarios: completed,
      server: source ? "bun-source" : "standalone",
      inputEnabled: false,
    }),
  );
} catch {
  console.error(`mcp_node_interop_failed phase=${phase}`);
  for (const line of trace) console.error(line);
  process.exitCode = 1;
} finally {
  try {
    await invoke("stop");
  } catch {}
  for (let i = 0; i < 50; i++) {
    try {
      rmSync(parent, { recursive: true, force: true });
      break;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }
}
