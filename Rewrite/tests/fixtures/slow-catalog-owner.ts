import { createInterface } from "node:readline";
process.stdout.write(
  JSON.stringify({ version: 1, ready: "configuration", pid: process.pid }) +
    "\n",
);
let first = true;
for await (const line of createInterface({ input: process.stdin })) {
  const request = JSON.parse(line);
  if (first) {
    first = false;
    await Bun.sleep(2400);
  }
  process.stdout.write(
    JSON.stringify({
      version: 1,
      requestId: request.requestId,
      ok: true,
      result: {
        version: 1,
        kind: "catalog",
        revision: "0",
        contentHash: null,
        profiles: [],
        activeProfileId: null,
        defaultProfileId: null,
        nextOffset: null,
      },
    }) + "\n",
  );
}
