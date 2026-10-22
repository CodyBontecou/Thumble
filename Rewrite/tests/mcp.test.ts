import { expect, test } from "bun:test";
import { PassThrough, Writable } from "node:stream";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { Client } from "@modelcontextprotocol/client";
import { StdioClientTransport } from "@modelcontextprotocol/client/stdio";
import { BoundedStdioTransport } from "../apps/cli/src/mcp-transport.ts";
import { readEndpoint, request } from "@thumble/client/local";
import { neutralGamepadState } from "@thumble/contracts";

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
  const output = new Writable({ write(_chunk, _encoding, _callback) {} });
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

test("SDK modern and legacy clients share CLI authority, preserve input opt-in and emergency release across MCP exit", async () => {
  const parent = realpathSync(mkdtempSync(join(tmpdir(), "thumble-mcp-"))),
    runtime = join(parent, "runtime");
  const start = Bun.spawn(
    [
      process.execPath,
      cli,
      "service",
      "start",
      "--runtime-dir",
      runtime,
      "--receiver",
      receiver,
    ],
    { stdout: "pipe", stderr: "pipe" },
  );
  try {
    expect(await start.exited).toBe(0);
    expect(await new Response(start.stderr).text()).toBe("");
    const endpoint = readEndpoint(runtime, receiver);
    for (const legacy of [false, true])
      for (const optIn of [false, true]) {
        const transport = new StdioClientTransport({
          command: process.execPath,
          args: [
            cli,
            "mcp",
            "serve",
            "--runtime-dir",
            runtime,
            "--receiver",
            receiver,
            ...(optIn ? ["--allow-recorded-input"] : []),
          ],
          stderr: "pipe",
        });
        let stderr = "";
        transport.stderr?.on("data", (chunk) => {
          stderr += chunk.toString();
        });
        const client = new Client({
          name: "thumble-headless-test",
          version: "1",
        });
        try {
          await client.connect(
            transport,
            legacy ? { prior: { kind: "legacy" } } : {},
          );
          const tools = await client.listTools();
          expect(tools.tools.map((t) => t.name).sort()).toEqual(
            [
              "receiver_status",
              "receiver_release",
              "pairing_status",
              "pairing_list",
              ...(optIn ? ["receiver_activate", "receiver_sample"] : []),
            ].sort(),
          );
          const status = await client.callTool({
            name: "receiver_status",
            arguments: {},
          });
          expect(status.structuredContent).toEqual({
            version: 1,
            ok: true,
            result: await request(endpoint, { command: "status" }),
          });
          expect(JSON.stringify(status)).not.toContain(endpoint.token);
          const invalid = await client.callTool({
            name: "receiver_release",
            arguments: { extra: true },
          });
          expect(invalid.isError).toBe(true);
          if (optIn) {
            const current = await request(endpoint, { command: "status" });
            const active = await client.callTool({
              name: "receiver_activate",
              arguments: {
                expectedRevision: current.receiver.snapshot.revision,
                profileId: "mcp-profile",
              },
            });
            expect(active.isError).not.toBe(true);
            const generation = (await request(endpoint, { command: "status" }))
              .receiver.snapshot.generation;
            const sampled = await client.callTool({
              name: "receiver_sample",
              arguments: {
                expectedGeneration: generation,
                sequence: "1",
                state: { ...neutralGamepadState(), buttons: ["south"] },
              },
            });
            expect(sampled.isError).not.toBe(true);
            expect(
              (await request(endpoint, { command: "status" })).receiver.snapshot
                .sequence,
            ).toBe("1");
          } else {
            await expect(
              client.callTool({
                name: "receiver_activate",
                arguments: { expectedRevision: "0", profileId: "mcp-profile" },
              }),
            ).rejects.toThrow("Tool receiver_activate not found");
          }
          expect(
            (await client.callTool({ name: "receiver_release", arguments: {} }))
              .isError,
          ).not.toBe(true);
          expect(
            (await request(endpoint, { command: "status" })).receiver.snapshot
              .active,
          ).toBe(false);
        } finally {
          await client.close();
        }
        expect(stderr).toBe("");
        expect(
          (await request(endpoint, { command: "status" })).service.instanceId,
        ).toBe(endpoint.instanceId);
      }
  } finally {
    try {
      await request(readEndpoint(runtime, receiver), { command: "stop" });
    } catch {}
    for (let i = 0; i < 50; i++) {
      try {
        rmSync(parent, { recursive: true, force: true });
        break;
      } catch {
        await Bun.sleep(20);
      }
    }
  }
}, 30000);
