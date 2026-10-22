// Test-only peer: valid private envelope with an invalid typed result.
// Keep the same stream writer as the real owner and wait for EOF after rejection.
export {};
await new Promise<void>((resolve) => {
  let buffer = Buffer.alloc(0);
  process.stdin.on("data", (chunk: Uint8Array | string) => {
    buffer = Buffer.concat([
      buffer,
      typeof chunk === "string" ? Buffer.from(chunk) : chunk,
    ]);
    for (let newline; (newline = buffer.indexOf(10)) >= 0; ) {
      const request = JSON.parse(buffer.subarray(0, newline).toString("utf8"));
      buffer = buffer.subarray(newline + 1);
      process.stdout.write(
        JSON.stringify({
          version: 1,
          requestId: request.requestId,
          ok: true,
          result: { version: 1, kind: "catalog", revision: "999" },
        }) + "\n",
      );
    }
  });
  process.stdin.on("end", resolve);
  process.stdout.write(
    JSON.stringify({ version: 1, ready: "configuration", pid: process.pid }) +
      "\n",
  );
});
