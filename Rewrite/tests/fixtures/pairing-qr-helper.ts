import { readFileSync, writeSync } from "node:fs";
const input = readFileSync(0, "utf8");
const mode = process.execPath.split(/[\\/]/).at(-1)!;
if (input.length > 4096) process.exit(3);
if (mode.includes("error")) {
  console.error("DO_NOT_REFLECT_SYNTHETIC_SECRET");
  process.exit(2);
}
if (mode.includes("large")) {
  writeSync(1, Buffer.alloc(1024 * 1024 + 1));
} else if (mode.includes("invalid")) {
  writeSync(1, "not_a_png");
} else if (mode.includes("timeout")) {
  await Bun.sleep(10000);
} else writeSync(1, readFileSync(process.env.THUMBLE_QR_TEST_PNG!));
