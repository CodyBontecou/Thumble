import { closeSync, writeSync } from "node:fs";
writeSync(
  1,
  JSON.stringify({ version: 1, ready: "test", pid: process.pid }) + "\n",
);
closeSync(1);
process.stdin.resume();
process.stdin.on("end", () => process.exit(0));
