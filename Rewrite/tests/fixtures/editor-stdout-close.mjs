import { closeSync } from "node:fs";
// End the actual Node/libuv stream as well as fd 1. On Windows libuv can
// duplicate a standard pipe handle; closing only the CRT descriptor leaves
// that write handle alive and therefore does not produce EOF for the parent.
process.stdin.on("end", () => process.exit(0));
process.stdin.resume();
process.stdout.end(
  JSON.stringify({ version: 1, ready: "test", pid: process.pid }) + "\n",
  () => closeSync(1),
);
