// Run with pinned Node. Each independent row runs once; no failure becomes a retry.
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync, existsSync } from "node:fs";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
const directory = fileURLToPath(new URL(".", import.meta.url));
const evidence = resolve(process.argv[2] ?? "");
if (!process.argv[2] || existsSync(evidence))
  throw Error("new_evidence_directory_required");
mkdirSync(evidence, { recursive: true });
const bun = process.env.THUMBLE_DIAG_BUN;
if (!bun) throw Error("explicit_bun_executable_required");
const bunVersion = spawnSync(bun, ["--version"], {
  encoding: "utf8",
  timeout: 3000,
  maxBuffer: 1024,
});
if (
  bunVersion.status !== 0 ||
  bunVersion.stdout.trim() !== "1.4.3" ||
  process.version !== "v26.8.1"
)
  throw Error("pinned_runtimes_required");
const rows = [];
for (const context of ["script", "bun-test"])
  for (const parent of ["node-spawn", "bun-spawn"])
    for (const writer of ["stdout", "bun-write"])
      rows.push({ context, parent, writer, child: "bun" });
for (const context of ["script", "bun-test"])
  for (const parent of ["node-spawn", "bun-spawn"])
    rows.push({ context, parent, writer: "stdout", child: "node" });
rows.push({
  context: "node-script",
  parent: "node-spawn",
  writer: "stdout",
  child: "node",
});
// Keep original cell1..13 identities and assertions for exact hosted comparison.
for (const parent of ["node-spawn", "bun-spawn"])
  for (const writer of ["stdout", "bun-write"])
    rows.push({ context: "bun-test-await", parent, writer, child: "bun" });
for (const parent of ["node-spawn", "bun-spawn"])
  rows.push({
    context: "bun-test-await",
    parent,
    writer: "stdout",
    child: "node",
  });
const started = Date.now(),
  results = [];
for (let index = 0; index < rows.length; index++) {
  const spec = {
    ...rows[index],
    id: `cell-${index + 1}`,
    bun,
    node: process.execPath,
  };
  let result;
  if (Date.now() - started > 155000)
    result = {
      version: 1,
      id: spec.id,
      passed: false,
      failure: "matrix_budget",
    };
  else {
    const command = spec.context === "node-script" ? process.execPath : bun;
    const args =
      spec.context === "bun-test" || spec.context === "bun-test-await"
        ? ["test", join(directory, "bun-matcher.test.mjs")]
        : [join(directory, "harness.mjs"), "--row"];
    const child = spawnSync(command, args, {
      env: { ...process.env, THUMBLE_STDIO_CASE: JSON.stringify(spec) },
      encoding: "utf8",
      timeout: 16000,
      maxBuffer: 65536,
    });
    const text = child.stdout + "\n" + child.stderr;
    const line = text
      .split(/\r?\n/)
      .find((value) => value.startsWith("STDIO_RESULT "));
    if (line) {
      try {
        result = JSON.parse(line.slice("STDIO_RESULT ".length));
      } catch {}
    }
    if (!result)
      result = {
        version: 1,
        id: spec.id,
        passed: false,
        failure: child.error
          ? "outer_timeout_or_spawn"
          : "missing_bounded_result",
      };
    if (child.status !== 0 && result.passed) {
      result.passed = false;
      result.failure = "outer_exit_failed";
    }
  }
  const data = JSON.stringify(result, null, 2) + "\n";
  if (data.length > 32768) throw Error("evidence_bound");
  writeFileSync(join(evidence, `${spec.id}.json`), data);
  results.push({
    id: spec.id,
    context: spec.context,
    parent: spec.parent,
    child: spec.child,
    writer: spec.writer,
    passed: result.passed,
    failure: result.failure,
    replyOnlyAfterEof: result.replyOnlyAfterEof ?? false,
  });
  console.log(JSON.stringify(results.at(-1)));
}
const head = process.env.GITHUB_SHA;
const summary = {
  version: 1,
  scope: "synthetic-stdio-transport-diagnostic",
  sourceHead: head && /^[a-f0-9]{40}$/.test(head) ? head : null,
  node: process.version,
  bun: bunVersion.stdout.trim(),
  cells: results,
  passed: results.every((row) => row.passed),
  originalCellsPassed: results.slice(0, 13).every((row) => row.passed),
  nativeAwaitControlsPassed: results.slice(13).every((row) => row.passed),
  // Original async-matcher cells are retained known-red observations, not a
  // required product assertion. Script baselines and ALL six repair controls
  // must still pass; a diagnostic red remains red in every stored row.
  requiredControlsPassed:
    results.length === 19 &&
    results
      .filter((row) => row.context !== "bun-test")
      .every((row) => row.passed),
  noRetries: true,
  productChanged: false,
};
writeFileSync(
  join(evidence, "summary.json"),
  JSON.stringify(summary, null, 2) + "\n",
);
if (!summary.requiredControlsPassed) process.exitCode = 1;
