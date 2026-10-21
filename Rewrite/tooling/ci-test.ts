import { mkdirSync, statSync } from "node:fs";
import { resolve } from "node:path";
const root = resolve(import.meta.dir, "..");
mkdirSync(resolve(root, "reports"), { recursive: true });
const packageMode = process.argv.includes("--package");
const report = packageMode ? "reports/package-junit.xml" : "reports/junit.xml";
const result = Bun.spawnSync(
  [
    process.execPath,
    "test",
    ...(packageMode ? ["tests/package.test.ts"] : []),
    "--reporter=junit",
    `--reporter-outfile=${report}`,
  ],
  {
    cwd: root,
    env: {
      ...process.env,
      ...(packageMode ? { THUMBLE_REWRITE_PACKAGE_TEST: "1" } : {}),
    },
    stdout: "inherit",
    stderr: "inherit",
  },
);
if (result.exitCode !== 0) process.exit(result.exitCode);
// Fail even if the runtime reports passing tests but fails to write the evidence.
if (statSync(resolve(root, report)).size === 0)
  throw new Error("Empty JUnit test report");
