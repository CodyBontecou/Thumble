// Test-only peer: structurally valid private envelope, invalid typed result.
console.log(
  JSON.stringify({ version: 1, ready: "configuration", pid: process.pid }),
);
let buffer = "";
process.stdin.on("data", (chunk) => {
  buffer += chunk.toString();
  const newline = buffer.indexOf("\n");
  if (newline < 0) return;
  const request = JSON.parse(buffer.slice(0, newline));
  buffer = buffer.slice(newline + 1);
  console.log(
    JSON.stringify({
      version: 1,
      requestId: request.requestId,
      ok: true,
      result: { version: 1, kind: "catalog", revision: "999" },
    }),
  );
});
process.stdin.on("end", () => process.exit(0));
