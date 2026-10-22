// Test-only peer: valid private envelope with an invalid typed result.
// Keep the same stream writer as the real owner and wait for EOF after rejection.
export {};
let phases = 0;
function phase(
  value: "ready-written" | "request-received" | "reply-written" | "stdin-ended",
) {
  if (process.env.THUMBLE_REWRITE_PIPE_PROBE === "1" && phases++ < 16)
    console.error(`[DEBUG-invalid-owner] phase=${value}`);
}
await new Promise<void>((resolve) => {
  let buffer = Buffer.alloc(0);
  process.stdin.on("data", (chunk: Uint8Array | string) => {
    buffer = Buffer.concat([
      buffer,
      typeof chunk === "string" ? Buffer.from(chunk) : chunk,
    ]);
    for (let newline; (newline = buffer.indexOf(10)) >= 0; ) {
      phase("request-received");
      const request = JSON.parse(buffer.subarray(0, newline).toString("utf8"));
      buffer = buffer.subarray(newline + 1);
      process.stdout.write(
        JSON.stringify({
          version: 1,
          requestId: request.requestId,
          ok: true,
          result: { version: 1, kind: "catalog", revision: "999" },
        }) + "\n",
        () => phase("reply-written"),
      );
    }
  });
  process.stdin.on("end", () => {
    phase("stdin-ended");
    resolve();
  });
  process.stdout.write(
    JSON.stringify({ version: 1, ready: "configuration", pid: process.pid }) +
      "\n",
    () => phase("ready-written"),
  );
});
