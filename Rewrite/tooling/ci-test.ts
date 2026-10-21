import { mkdirSync, statSync } from "node:fs";
import { resolve } from "node:path";
const root = resolve(import.meta.dir, "..");
mkdirSync(resolve(root, "reports"), { recursive: true });
const result = Bun.spawnSync([process.execPath, "test", "--reporter=junit", "--reporter-outfile=reports/junit.xml"], {
  cwd: root, stdout: "inherit", stderr: "inherit",
});
if (result.exitCode !== 0) process.exit(result.exitCode);
// Fail even if the runtime reports passing tests but fails to write the evidence.
if (statSync(resolve(root, "reports/junit.xml")).size === 0) throw new Error("Empty JUnit test report");
