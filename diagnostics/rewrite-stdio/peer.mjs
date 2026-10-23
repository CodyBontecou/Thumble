// Synthetic peer only. Deliberately remains alive until stdin EOF after both replies.
const mode = process.argv[2];
if (
  !["stdout", "bun-write"].includes(mode) ||
  (mode === "bun-write" && typeof Bun === "undefined")
)
  throw Error("peer_mode");
let phases = 0,
  requests = 0,
  buffer = Buffer.alloc(0);
function phase(code) {
  if (phases++ < 20)
    process.stderr.write(JSON.stringify({ phase: code }) + "\n");
}
async function write(value) {
  const text = JSON.stringify(value) + "\n";
  if (mode === "bun-write") {
    await Bun.write(Bun.stdout, text);
    phase("write-resolved");
  } else
    await new Promise((resolve, reject) =>
      process.stdout.write(text, (error) => {
        phase("write-callback");
        error ? reject(error) : resolve();
      }),
    );
}
const watchdog = setTimeout(() => {
  phase("watchdog");
  process.exit(2);
}, 14000);
try {
  const ended = new Promise((resolve, reject) => {
    let tail = Promise.resolve();
    process.stdin.on("data", (chunk) => {
      buffer = Buffer.concat([buffer, Buffer.from(chunk)]);
      if (buffer.length > 1024) {
        reject(Error("peer_bound"));
        return;
      }
      for (let newline; (newline = buffer.indexOf(10)) >= 0; ) {
        const text = buffer.subarray(0, newline).toString("utf8");
        buffer = buffer.subarray(newline + 1);
        tail = tail
          .then(async () => {
            const request = JSON.parse(text);
            requests++;
            if (
              requests > 2 ||
              JSON.stringify(request) !==
                JSON.stringify({
                  version: 1,
                  requestId: `00000000-0000-0000-0000-${String(requests).padStart(12, "0")}`,
                  body: { command: "configuration-list" },
                })
            )
              throw Error("peer_request");
            phase("request-received");
            await write({
              version: 1,
              requestId: request.requestId,
              ok: true,
              result:
                requests === 1
                  ? { version: 1, kind: "catalog", revision: "1", profiles: [] }
                  : { version: 1, kind: "catalog", revision: "999" },
            });
          })
          .catch(reject);
      }
    });
    process.stdin.on("end", () => {
      phase("stdin-eof");
      tail.then(resolve, reject);
    });
    process.stdin.on("error", reject);
  });
  await write({ version: 1, ready: "configuration", pid: process.pid });
  await ended;
  if (buffer.length !== 0 || requests !== 2) throw Error("peer_incomplete");
  phase("complete");
} finally {
  clearTimeout(watchdog);
}
