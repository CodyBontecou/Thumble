// [DEBUG-config-pipe] Temporary independent process oracle. No raw frames in logs.
import { spawn } from "node:child_process";
import { isAbsolute, resolve } from "node:path";
const [bun, path] = process.argv.slice(2);
if (!bun || !path || !isAbsolute(bun))
  throw new Error("probe_arguments_invalid");
const peer = spawn(bun, [resolve(path)], {
  stdio: ["pipe", "pipe", "pipe"],
  windowsHide: true,
  detached: process.platform === "win32",
});
let bytes = 0,
  lines = 0,
  buffer = Buffer.alloc(0),
  ready = false;
let reply = false,
  matched = false,
  done = false;
const phases = [];
const requestId = "00000000-0000-0000-0000-000000000001";
let readyResolve, exitResolve;
const whenReady = new Promise((resolve) => {
  readyResolve = resolve;
});
const exited = new Promise((resolve) => {
  exitResolve = resolve;
});
peer.on("error", () => {
  done = true;
  readyResolve();
  exitResolve();
});
peer.on("exit", () => {
  done = true;
  readyResolve();
  exitResolve();
});
peer.stdin.on("error", () => {});
peer.stderr.on("data", (chunk) => {
  for (const value of chunk
    .toString("utf8")
    .match(/test_peer_(?:listening|input|reply|flushed|end)/g) ?? [])
    if (phases.length < 16) phases.push(value);
});
peer.stdout.on("data", (chunk) => {
  bytes = Math.min(1048576, bytes + chunk.byteLength);
  buffer = Buffer.concat([buffer, chunk]);
  for (let newline; (newline = buffer.indexOf(10)) >= 0; ) {
    const frame = buffer.subarray(0, newline);
    buffer = buffer.subarray(newline + 1);
    lines++;
    let value;
    try {
      value = JSON.parse(frame.toString("utf8"));
    } catch {
      continue;
    }
    if (!ready && value.ready === "configuration") {
      ready = true;
      readyResolve();
    } else if (value.ok === true && value.result?.kind === "catalog") {
      reply = true;
      matched = value.requestId === requestId;
    }
  }
});
const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
await Promise.race([whenReady, pause(3000)]);
if (ready)
  peer.stdin.write(
    JSON.stringify({
      version: 1,
      requestId,
      body: {
        command: "configuration-list",
        expectedRevision: null,
        offset: 0,
      },
    }) + "\n",
  );
const until = performance.now() + 2000;
while (ready && !reply && !done && performance.now() < until) await pause(10);
const beforeEOF = { bytes, lines, reply, matched };
peer.stdin.end();
await Promise.race([exited, pause(1000)]);
if (!done) peer.kill("SIGKILL");
await Promise.race([exited, pause(1000)]);
console.log(
  JSON.stringify({
    scope: "synthetic-peer-observation-only",
    parent: process.versions.bun ? "bun" : "node",
    ready,
    beforeEOF,
    afterEOF: { bytes, lines, reply, matched },
    phases,
  }),
);
