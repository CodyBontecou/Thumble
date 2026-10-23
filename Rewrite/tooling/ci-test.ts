import { mkdirSync, rmSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { parseTestSelection, selectTestFiles } from "./ci-test-options";
const selection = parseTestSelection(process.argv.slice(2));
const root = resolve(import.meta.dir, "..");
mkdirSync(resolve(root, "reports"), { recursive: true });
const { packageMode, shard } = selection;
const inventory = [
  ...new Bun.Glob("**/*").scanSync({
    cwd: resolve(root, "tests"),
    onlyFiles: true,
    followSymlinks: false,
  }),
]
  .filter((file) => /(?:^|[._])(?:test|spec)\.[cm]?[jt]sx?$/.test(file))
  .map((file) => `./tests/${file.replaceAll("\\", "/")}`);
const files = selectTestFiles(inventory, selection);
const report = packageMode
  ? "reports/package-junit.xml"
  : shard
    ? `reports/shard-${shard.index}-of-${shard.count}-junit.xml`
    : "reports/junit.xml";
console.log(
  `CI test selection: ${files.length} files${shard ? `; shard ${shard.index}/${shard.count}` : ""}`,
);
rmSync(resolve(root, report), { force: true });
const result = Bun.spawnSync(
  [
    process.execPath,
    "test",
    ...files,
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
