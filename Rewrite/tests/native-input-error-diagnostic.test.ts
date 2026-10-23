import { expect, test } from "bun:test";
import {
  decodeNativeInputErrorLine,
  NativeInputErrorForwarder,
} from "../apps/service/src/native-input-error-diagnostic.ts";
const record = (value: Record<string, unknown>) =>
  "native_input_error " +
  JSON.stringify(
    Object.fromEntries(
      Object.entries(value).sort(([a], [b]) => a.localeCompare(b)),
    ),
  );
const io = record({
  version: 1,
  role: "broker",
  context: "native-read",
  ioKind: "would-block",
  osCode: 35,
});
test("error forwarding admits only exact native canonical fields", () => {
  expect(decodeNativeInputErrorLine(io)).toBe(io);
  for (const value of [
    io.replace('"version":1', '"version":1,"version":1'),
    io.replace(":35", ":35.0"),
    io.replace(":35", ":3.5e1"),
    io.replace(":35", ":-0"),
    io.replace('"would-block"', '"secret"'),
    io.replace("{", '{"secret":"credential",'),
    io + "secret",
    record({
      version: 1,
      role: "broker",
      context: "native-server-exit",
      exit: "read-failure",
      owned: 1,
    }),
    record({
      version: 1,
      role: "broker",
      context: "native-read",
      ioKind: "would-block",
      osCode: 2147483648,
    }),
  ])
    expect(decodeNativeInputErrorLine(value)).toBeUndefined();
});
test("partial and oversized lines cannot disclose raw stderr and first16 are retained", () => {
  const output: string[] = [],
    parser = new NativeInputErrorForwarder((line) => output.push(line));
  parser.push(
    Buffer.from(
      "private credentials must not escape\n" +
        "x".repeat(1000) +
        "\n" +
        io.slice(0, 40),
    ),
  );
  expect(output).toEqual([]);
  parser.push(Buffer.from(io.slice(40) + "\n" + (io + "\n").repeat(100)));
  expect(output.length).toBe(16);
  expect(output.every((line) => line === io)).toBe(true);
});
test("diagnostic sink failures and work exhaustion do not throw or grow buffers", () => {
  const parser = new NativeInputErrorForwarder(() => {
    throw new Error("private sink failure");
  });
  expect(() => parser.push(Buffer.from(io + "\n"))).not.toThrow();
  const output: string[] = [],
    exhausted = new NativeInputErrorForwarder((line) => output.push(line));
  exhausted.push(new Uint8Array(65536).fill(120));
  exhausted.push(Buffer.from("\n" + io + "\n"));
  expect(output).toEqual([]);
});

const connect = record({
  version: 1,
  role: "broker",
  context: "native-connect",
  stage: "proof-read",
  elapsedMs: 250,
  code: "native_input_timeout",
});
const handshake = record({
  version: 1,
  role: "receiver",
  context: "native-handshake",
  stage: "complete",
  acceptGapMs: 5,
  queueMs: 300,
  readMs: 0,
  proofMs: 0,
});
test("original handshake diagnostics admit only fixed phases and bounded canonical times", () => {
  for (const stage of [
    "tcp-connect",
    "challenge-send",
    "proof-read",
    "proof-validate",
  ]) {
    const line = record({
      ...JSON.parse(connect.slice("native_input_error ".length)),
      stage,
    });
    expect(decodeNativeInputErrorLine(line)).toBe(line);
  }
  for (const stage of [
    "accepted",
    "challenge-read",
    "proof-send",
    "complete",
  ]) {
    const line = record({
      ...JSON.parse(handshake.slice("native_input_error ".length)),
      stage,
    });
    expect(decodeNativeInputErrorLine(line)).toBe(line);
  }
  const client = JSON.parse(connect.slice("native_input_error ".length));
  const server = JSON.parse(handshake.slice("native_input_error ".length));
  for (const change of [
    { stage: [] },
    { stage: "secret" },
    { elapsedMs: true },
    { elapsedMs: -1 },
    { elapsedMs: 60001 },
    { code: "secret" },
    { role: "receiver" },
    { endpoint: "secret" },
  ]) {
    expect(
      decodeNativeInputErrorLine(record({ ...client, ...change })),
    ).toBeUndefined();
  }
  for (const field of ["acceptGapMs", "queueMs", "readMs", "proofMs"]) {
    for (const invalid of [-1, 60001, true, {}, "secret", 0.1]) {
      expect(
        decodeNativeInputErrorLine(record({ ...server, [field]: invalid })),
      ).toBeUndefined();
    }
    for (const valid of [0, 60000]) {
      const line = record({ ...server, [field]: valid });
      expect(decodeNativeInputErrorLine(line)).toBe(line);
    }
  }
  for (const line of [
    connect.replace(":250", ":2.5e2"),
    connect.replace(":250", ":250.0"),
    connect.replace(":250", ':250,"elapsedMs":250'),
    record({ ...server, challenge: "secret" }),
    record({ ...server, role: "broker" }),
  ]) {
    expect(decodeNativeInputErrorLine(line)).toBeUndefined();
  }
});
test("chunked handshake events retain bounded order without forwarding raw text", () => {
  const output: string[] = [],
    forwarder = new NativeInputErrorForwarder((line) => output.push(line));
  const bytes = new TextEncoder().encode(
    "secret raw child stderr\n" +
      connect +
      "\n" +
      handshake +
      "\n" +
      (connect + "\n").repeat(30),
  );
  for (let at = 0; at < bytes.length; at += 7)
    forwarder.push(bytes.slice(at, at + 7));
  expect(output.length).toBe(16);
  expect(output.slice(0, 2)).toEqual([connect, handshake]);
  expect(output.every((line) => [connect, handshake].includes(line))).toBe(
    true,
  );
});
test("actual NativePipe forwards only bounded events under explicit flag", async () => {
  const module = new URL("../apps/service/src/native-pipe.ts", import.meta.url)
    .href;
  const grandchild = `process.stdout.write('{"ready":true}\\n');process.stderr.write(${JSON.stringify("private-fixture-output\n" + io + "\n" + connect + "\n" + handshake + "\n")});for await(const value of Bun.stdin.stream()){break;}`;
  const source = `import{NativePipe}from ${JSON.stringify(module)};const pipe=new NativePipe(process.execPath,["-e",${JSON.stringify(grandchild)}],{ready:()=>true,reply:()=>true},"test_unavailable");const closed=new Promise(resolve=>pipe.child.once("close",resolve));await pipe.ready;pipe.child.stdin.end("q\\n");await closed;`;
  for (const flag of ["0", "1"]) {
    const child = Bun.spawn([process.execPath, "-e", source], {
      env: { ...process.env, THUMBLE_REWRITE_INPUT_ERROR_PROBE: flag },
      stdout: "ignore",
      stderr: "pipe",
      timeout: 5000,
    });
    const stderr = await new Response(child.stderr).text();
    const status = await child.exited;
    expect(status).toBe(0);
    expect(stderr).toBe(
      flag === "1" ? [io, connect, handshake].join("\n") + "\n" : "",
    );
  }
});

test("first serving error is distinct from cleanup op4 and strictly bounded to fixed stages/codes", () => {
  const original = record({
    version: 1,
    role: "broker",
    context: "phone-control-before-cleanup",
    stage: "progress",
    code: "phone_trust_reservation_expired",
  });
  expect(decodeNativeInputErrorLine(original)).toBe(original);
  const cleanup = record({
    version: 1,
    role: "broker",
    context: "native-client",
    op: 4,
    code: "native_input_timeout",
  });
  const output: string[] = [];
  const forwarder = new NativeInputErrorForwarder((line) => output.push(line));
  forwarder.push(new TextEncoder().encode(original + "\n" + cleanup + "\n"));
  expect(output).toEqual([original, cleanup]);
  for (const row of [
    {
      version: 1,
      role: "receiver",
      context: "phone-control-before-cleanup",
      stage: "progress",
      code: "native_input_timeout",
    },
    {
      version: 1,
      role: "broker",
      context: "phone-control-before-cleanup",
      stage: "secret",
      code: "native_input_timeout",
    },
    {
      version: 1,
      role: "broker",
      context: "phone-control-before-cleanup",
      stage: "progress",
      code: "secret",
    },
    {
      version: 1,
      role: "broker",
      context: "phone-control-before-cleanup",
      stage: "progress",
      code: "native_input_timeout",
      op: 4,
    },
  ])
    expect(decodeNativeInputErrorLine(record(row))).toBeUndefined();
});
