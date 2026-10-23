#!/usr/bin/env bun
/** Only the longer simulator UI fixture; existing 60s SDK harness is unchanged. */
import assert from "node:assert/strict";
import { isAbsolute, basename } from "node:path";
const index = process.argv.indexOf("--service-probe");
const path = process.argv[index + 1];
assert(index >= 0 && path && isAbsolute(path));
assert(basename(path) === "presentation-service-probe.ts");
assert(process.argv.includes("--bank-presentation"));
const { PresentationServiceProbe } = await import(path);
const probe = new PresentationServiceProbe({ bankPalette: "ios-wide" });
let closing = false;
async function terminate(code: number) {
  if (closing) return;
  closing = true;
  try {
    await probe.close();
  } catch {}
  process.exit(code);
}
const watchdog = setTimeout(() => void terminate(1), 180_000);
process.once("SIGTERM", () => void terminate(1));
process.once("SIGINT", () => void terminate(1));
try {
  process.stdout.write(JSON.stringify(await probe.start()) + "\n");
  for await (const bytes of Bun.stdin.stream()) {
    for (const byte of bytes) {
      const command = String.fromCharCode(byte);
      assert(["a", "w", "m", "g", "n", "f", "i"].includes(command));
      process.stdout.write(JSON.stringify(await probe.command(command)) + "\n");
      if (command === "f") {
        clearTimeout(watchdog);
        process.exit(0);
      }
    }
  }
  throw Error("bank_ios_probe_eof");
} catch {
  process.stderr.write("bank_ios_probe_failed\n");
  await terminate(1);
}
