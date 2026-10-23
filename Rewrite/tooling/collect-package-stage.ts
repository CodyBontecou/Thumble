/** Test-only CI sanitizer. No raw child output is copied to the retained artifact. */
import { openSync, readSync, closeSync, writeFileSync } from "node:fs";
import { collectPackageStageLines } from "../tests/helpers/package-stage-diagnostic.ts";
try {
  const descriptor = openSync("reports/package-stage-private.txt", "r");
  const buffer = Buffer.alloc(65536);
  let size: number;
  try {
    size = readSync(descriptor, buffer, 0, buffer.length, 0);
  } finally {
    closeSync(descriptor);
  }
  writeFileSync(
    "reports/package-stage.jsonl",
    collectPackageStageLines(buffer.subarray(0, size).toString("utf8")),
    { mode: 0o600 },
  );
} catch {
  console.error("package_stage_collection_failed");
  process.exitCode = 1;
}
