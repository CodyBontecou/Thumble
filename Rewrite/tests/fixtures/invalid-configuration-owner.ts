import { writeFileSync } from "node:fs";
export {};
// Test-only peer: structurally valid private envelope, invalid typed result.
// [DEBUG-config-peer] Bounded phases only; never print requests or their fields.
const phase = (value: "listening" | "input" | "reply" | "flushed" | "end") =>
  process.stderr.write(`test_peer_${value}\n`);
await new Promise<void>((resolve) => {
  let buffer = Buffer.alloc(0);
  process.stdin.on("data", (chunk: Uint8Array | string) => {
    phase("input");
    buffer = Buffer.concat([
      buffer,
      typeof chunk === "string" ? Buffer.from(chunk) : chunk,
    ]);
    for (let newline; (newline = buffer.indexOf(10)) >= 0; ) {
      const request = JSON.parse(buffer.subarray(0, newline).toString("utf8"));
      buffer = buffer.subarray(newline + 1);
      writeFileSync(
        1,
        JSON.stringify({
          version: 1,
          requestId: request.requestId,
          ok: true,
          result: { version: 1, kind: "catalog", revision: "999" },
        }) + "\n",
      );
      phase("flushed");
      phase("reply");
    }
  });
  process.stdin.on("end", () => {
    phase("end");
    resolve();
  });
  process.stdin.resume();
  phase("listening");
  process.stdout.write(
    JSON.stringify({ version: 1, ready: "configuration", pid: process.pid }) +
      "\n",
  );
});
