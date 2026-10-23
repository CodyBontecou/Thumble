import { existsSync, writeSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
const directory = process.argv[process.argv.indexOf("--runtime-dir") + 1];
writeSync(
  1,
  JSON.stringify({
    version: 1,
    ready: "configuration",
    pid: process.pid,
    ownerLifetimeId: "11111111-0000-0000-0000-000000000001",
  }) + "\n",
);
const reply = (frame) =>
  writeSync(
    1,
    JSON.stringify({
      version: 1,
      requestId: frame.requestId,
      ok: false,
      error: "configuration_conflict",
    }) + "\n",
  );
const lines = createInterface({ input: process.stdin });
lines.on("line", (line) => {
  const frame = JSON.parse(line);
  if (frame.body.command === "configuration-list") {
    writeSync(2, "read-started\n");
    const timer = setInterval(() => {
      if (existsSync(join(directory, "release"))) {
        clearInterval(timer);
        reply(frame);
      }
    }, 10);
  } else {
    writeSync(2, "editor-dispatched\n");
    reply(frame);
  }
});
lines.on("close", () => process.exit(0));
