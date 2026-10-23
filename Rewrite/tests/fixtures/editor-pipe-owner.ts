const mode = process.argv[2] ?? "error";
process.stdout.write(
  JSON.stringify({
    version: 1,
    ready: mode.startsWith("owner-") ? "configuration" : "test",
    ...(mode.startsWith("owner-")
      ? { ownerLifetimeId: "11111111-0000-0000-0000-000000000001" }
      : {}),
    pid: process.pid,
  }) + "\n",
);
let input = "";
process.stdin.on("data", (chunk) => {
  input += chunk.toString();
  let end: number;
  while ((end = input.indexOf("\n")) >= 0) {
    const frame = JSON.parse(input.slice(0, end));
    input = input.slice(end + 1);
    if (mode === "exit") {
      process.exit(0);
    }
    if (mode === "silent" || mode === "owner-silent") continue;
    if (mode === "owner-corrupt") {
      process.stdout.write(
        JSON.stringify({
          version: 1,
          requestId: frame.requestId,
          ok: true,
          result: {
            envelope: { ...frame.body, eventId: "wrong" },
            outcome: { version: 1, kind: "conflict", currentRevision: "1" },
          },
        }) + "\n",
      );
      continue;
    }
    process.stdout.write(
      JSON.stringify({
        version: 1,
        requestId: frame.requestId,
        ok: false,
        error: "configuration_owner_unavailable",
      }) + "\n",
    );
  }
});
process.stdin.on("end", () => process.exit(0));
