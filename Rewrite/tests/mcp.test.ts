import { expect, test } from "bun:test";
import { PassThrough, Writable } from "node:stream";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { BoundedStdioTransport } from "../apps/cli/src/mcp-transport.ts";
import {
  readEndpoint,
  readEndpointAsync,
  request,
} from "@thumble/client/local";

const root = resolve(import.meta.dir, "..");
const receiver = resolve(
  root,
  `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
);
const cli = resolve(root, "apps/cli/src/main.ts");
const rpc = (id: number | string) =>
  JSON.stringify({ jsonrpc: "2.0", id, method: "ping" }) + "\n";

test("MCP framing survives split UTF-8 and coalesced messages, rejects ambiguous or excessive input before dispatch", async () => {
  for (const bad of [
    Buffer.from('{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}\n'),
    Buffer.from([0xff, 10]),
    Buffer.from(" ".repeat(65537)),
    Buffer.from("[1,2]\n"),
    Buffer.from(rpc("x".repeat(129))),
    Buffer.from(rpc(9007199254740992)),
    Buffer.from('{"x":' + "[".repeat(20) + "0" + "]".repeat(20) + "}\n"),
  ]) {
    const input = new PassThrough(),
      output = new PassThrough();
    const transport = new BoundedStdioTransport(input, output);
    let closed = 0,
      dispatched = 0;
    transport.onclose = () => closed++;
    transport.onmessage = () => dispatched++;
    await transport.start();
    input.write(bad);
    expect(closed).toBe(1);
    expect(dispatched).toBe(0);
    await transport.close();
    expect(closed).toBe(1);
  }
  const input = new PassThrough(),
    transport = new BoundedStdioTransport(input, new PassThrough());
  const ids: unknown[] = [];
  transport.onmessage = (m) => {
    if ("id" in m) ids.push(m.id);
  };
  await transport.start();
  const unicode = Buffer.from(rpc("é"));
  const at = unicode.indexOf(0xc3);
  input.write(unicode.subarray(0, at + 1));
  expect(ids).toEqual([]);
  input.write(Buffer.concat([unicode.subarray(at + 1), Buffer.from(rpc(2))]));
  expect(ids).toEqual(["é", 2]);
  await transport.close();
});

test("MCP duplicate outstanding IDs and request/output budgets close the connection", async () => {
  for (const lines of [
    rpc(1) + rpc(1),
    Array.from({ length: 17 }, (_, i) => rpc(i)).join(""),
  ]) {
    const input = new PassThrough(),
      transport = new BoundedStdioTransport(input, new PassThrough());
    let calls = 0,
      closed = false;
    transport.onmessage = () => calls++;
    transport.onclose = () => {
      closed = true;
    };
    await transport.start();
    input.write(lines);
    expect(closed).toBe(true);
    expect(calls).toBeLessThanOrEqual(16);
  }
  const input = new PassThrough();
  const output = new Writable({
    highWaterMark: 1,
    write(_chunk, _encoding, _callback) {},
  });
  const transport = new BoundedStdioTransport(input, output);
  await transport.start();
  const sends = Array.from({ length: 5 }, (_, i) =>
    transport
      .send({ jsonrpc: "2.0", id: i, result: { text: "x".repeat(60000) } })
      .then(
        () => false,
        () => true,
      ),
  );
  expect(await Promise.all(sends)).toEqual([true, true, true, true, true]);
  await transport.close();
  output.destroy();
});

test("MCP accepts the writable backpressure signal without waiting for a platform callback", async () => {
  const input = new PassThrough();
  const output = new Writable({
    highWaterMark: 1024,
    write(_chunk, _encoding, _callback) {},
  });
  const transport = new BoundedStdioTransport(input, output);
  await transport.start();
  try {
    await expect(
      transport.send({ jsonrpc: "2.0", id: 1, result: {} }),
    ).resolves.toBeUndefined();
  } finally {
    await transport.close();
    output.destroy();
  }
});

test("independent Node SDK clients exercise both MCP eras, capability gates and service survival", async () => {
  const child = Bun.spawn(
    [
      "node",
      resolve(root, "tooling/test-mcp-node.mjs"),
      process.execPath,
      cli,
      receiver,
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  const [stdout, stderr, code] = await Promise.all([
    new Response(child.stdout).text(),
    new Response(child.stderr).text(),
    child.exited,
  ]);
  expect(stderr).toBe("");
  expect(code).toBe(0);
  expect(JSON.parse(stdout)).toEqual({
    ok: true,
    runtime: expect.stringMatching(/^v[0-9]+\.[0-9]+\.[0-9]+$/),
    eras: ["modern", "legacy"],
    scenarios: 4,
    server: "bun-source",
    inputEnabled: false,
  });
}, 30000);

test("MCP rejects unavailable tools before dispatch without reflecting caller data", async () => {
  const input = new PassThrough(),
    output = new PassThrough();
  const transport = new BoundedStdioTransport(
    input,
    output,
    () => {},
    new Set(["receiver_status"]),
  );
  let response = "",
    calls = 0;
  output.on("data", (chunk) => {
    response += chunk.toString();
  });
  transport.onmessage = () => {
    calls++;
  };
  await transport.start();
  input.write(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: "private-caller-data", arguments: {} },
    }) + "\n",
  );
  expect(calls).toBe(0);
  expect(JSON.parse(response)).toEqual({
    jsonrpc: "2.0",
    id: 1,
    error: { code: -32602, message: "tool_unavailable" },
  });
  expect(response).not.toContain("private-caller-data");
  input.write(
    JSON.stringify({
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: { name: "receiver_status", arguments: {} },
    }) + "\n",
  );
  expect(calls).toBe(1);
  await transport.close();
});

test("MCP exits naturally on EOF or invalid framing and keeps CLI errors off stdout", async () => {
  const parent = realpathSync(mkdtempSync(join(tmpdir(), "thumble-mcp-eof-")));
  const bounded = async <T>(promise: Promise<T>): Promise<T> => {
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      return await Promise.race([
        promise,
        new Promise<never>((_resolve, reject) => {
          timer = setTimeout(
            () => reject(new Error("mcp_child_did_not_finish")),
            3000,
          );
        }),
      ]);
    } finally {
      clearTimeout(timer);
    }
  };
  try {
    for (const kind of ["eof", "invalid", "arguments"]) {
      const child = Bun.spawn(
        [
          process.execPath,
          cli,
          "mcp",
          "serve",
          "--runtime-dir",
          join(parent, "runtime"),
          ...(kind === "arguments" ? ["--json"] : []),
        ],
        {
          stdin: "pipe",
          stdout: "pipe",
          stderr: "pipe",
          env: { ...process.env, THUMBLE_REWRITE_MCP_TRACE: "0" },
        },
      );
      const reader = child.stdout.getReader();
      const decoder = new TextDecoder();
      try {
        if (kind === "eof") {
          child.stdin.write(
            JSON.stringify({
              jsonrpc: "2.0",
              id: 1,
              method: "initialize",
              params: {
                protocolVersion: "2025-11-25",
                capabilities: {},
                clientInfo: { name: "eof-test", version: "1" },
              },
            }) + "\n",
          );
          let first = "";
          while (!first.includes("\n")) {
            const chunk = await bounded(reader.read());
            expect(chunk.done).not.toBe(true);
            first += decoder.decode(chunk.value, { stream: true });
            expect(first.length).toBeLessThanOrEqual(65536);
          }
          const lines = first.trim().split("\n");
          expect(lines).toHaveLength(1);
          expect(JSON.parse(lines[0]!).id).toBe(1);
          expect(JSON.parse(lines[0]!).result.protocolVersion).toBe(
            "2025-11-25",
          );
          child.stdin.end();
        } else if (kind === "invalid")
          child.stdin.write(
            '{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}\n',
          );
        const remaining = (async () => {
          let text = "";
          while (true) {
            const chunk = await reader.read();
            if (chunk.done) return text;
            text += decoder.decode(chunk.value, { stream: true });
            if (text.length > 65536) throw new Error("mcp_stdout_limit");
          }
        })();
        const [stdout, stderr, code] = await bounded(
          Promise.all([
            remaining,
            new Response(child.stderr).text(),
            child.exited,
          ]),
        );
        expect(stdout).toBe("");
        expect(stderr.trim()).toBe(
          kind === "arguments" ? "invalid_mcp_option" : "",
        );
        expect(code).toBe(kind === "arguments" ? 1 : 0);
      } finally {
        if (child.exitCode === null) child.kill();
        await child.exited;
        reader.releaseLock();
      }
    }
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}, 10000);
