// Offline file-inspection parity through an independent official Node SDK client.
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { existsSync } from "node:fs";
import { isAbsolute, join } from "node:path";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
const [bun, cli, file, parent, restrictedPath] = process.argv.slice(2);
if (
  ![bun, cli, file, parent].every((p) => typeof p === "string" && isAbsolute(p))
)
  throw new Error("invalid_probe_arguments");
const launcher = cli.endsWith(".ts") ? [bun, cli] : [cli],
  env = {
    ...process.env,
    ...(restrictedPath === undefined ? {} : { PATH: restrictedPath }),
  };
const execute = promisify(execFile),
  runtime = join(parent, "absent-service"),
  receiver = join(parent, "absent-receiver");
assert.equal(existsSync(runtime), false);
assert.equal(existsSync(receiver), false);
const cliResult = await execute(
  launcher[0],
  [
    ...launcher.slice(1),
    "configuration",
    "validate-file",
    "--file",
    file,
    "--json",
  ],
  { timeout: 5000, maxBuffer: 65536, windowsHide: true, env },
);
assert.equal(cliResult.stderr, "");
const result = JSON.parse(cliResult.stdout);
assert.equal(result.ok, true);
assert.equal(result.result.profileCount, 2);
assert.equal(result.result.elementCount, 12);
assert.equal(result.result.appearanceStateCount, 8);
assert.equal(result.result.resourceCount, 2);
assert.equal(result.result.resourceBytes, 27);
assert.equal(result.result.activationCompatibility, "not-evaluated");
assert.match(result.result.contentHash, /^[0-9a-f]{64}$/);
assert.equal(cliResult.stdout.includes("Local fixture app"), false);
for (const legacy of [false, true]) {
  const transport = new StdioClientTransport({
    command: launcher[0],
    args: [
      ...launcher.slice(1),
      "mcp",
      "serve",
      "--runtime-dir",
      runtime,
      "--receiver",
      receiver,
    ],
    env,
    stderr: "pipe",
  });
  let stderr = "";
  transport.stderr?.on("data", (chunk) => {
    if (stderr.length < 4096) stderr += chunk.toString();
  });
  const client = new Client(
    { name: "configuration-file-parity", version: "1" },
    { versionNegotiation: { mode: legacy ? "legacy" : { pin: "2026-07-28" } } },
  );
  try {
    await client.connect(
      transport,
      legacy ? { prior: { kind: "legacy" }, timeout: 5000 } : { timeout: 5000 },
    );
    const response = await client.callTool(
      { name: "configuration_validate_file", arguments: { path: file } },
      { timeout: 5000 },
    );
    assert.deepEqual(response.structuredContent, result);
    assert.notEqual(response.isError, true);
    assert.equal(
      (
        await client.callTool(
          {
            name: "configuration_validate_file",
            arguments: { path: file, source: "forbidden" },
          },
          { timeout: 5000 },
        )
      ).isError,
      true,
    );
    const relative = await client.callTool(
      {
        name: "configuration_validate_file",
        arguments: { path: "relative.json" },
      },
      { timeout: 5000 },
    );
    assert.equal(relative.isError, true);
    assert.equal(
      relative.structuredContent.error,
      "configuration_file_path_invalid",
    );
  } finally {
    await client.close();
    assert.equal(stderr, "");
  }
}
assert.equal(existsSync(runtime), false);
assert.equal(existsSync(receiver), false);
console.log(
  JSON.stringify({
    ok: true,
    scenarios: 2,
    server: cli.endsWith(".ts") ? "bun-source" : "standalone",
    serviceRequired: false,
  }),
);
