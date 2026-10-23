import { expect, test } from "bun:test";
import {
  PackageStageDiagnostic,
  decodePackageStageLine,
  collectPackageStageLines,
} from "./helpers/package-stage-diagnostic.ts";
const decode = (line: string) =>
  JSON.parse(line.slice("package_stage ".length));
test("package trace exposes pending stage and pipe completion without retaining child data", async () => {
  const lines: string[] = [];
  let time = 10,
    release!: (value: string) => void;
  const trace = new PackageStageDiagnostic(
    true,
    (line) => lines.push(line),
    () => time,
  );
  const pending = new Promise<string>((resolve) => {
    release = resolve;
  });
  const operation = trace.run("service-stop", () =>
    Promise.all([
      trace.settled("service-stop", "stdout", pending),
      trace.settled("service-stop", "exit", Promise.resolve(0)),
    ]),
  );
  await Promise.resolve();
  await Promise.resolve();
  expect(lines.map(decode).map((row) => row.phase)).toEqual(["begin", "exit"]);
  time = 2510;
  release("synthetic-secret-output/path/credential");
  expect(await operation).toEqual([
    "synthetic-secret-output/path/credential",
    0,
  ]);
  expect(lines.map(decode)).toEqual([
    { version: 1, stage: "service-stop", phase: "begin", elapsedMs: 0 },
    { version: 1, stage: "service-stop", phase: "exit", elapsedMs: 0 },
    { version: 1, stage: "service-stop", phase: "stdout", elapsedMs: 2500 },
    { version: 1, stage: "service-stop", phase: "end", elapsedMs: 2500 },
  ]);
  expect(lines.join()).not.toContain("synthetic-secret");
});
test("package trace preserves thrown failure and rejects unknown fields by construction", async () => {
  const lines: string[] = [];
  let time = 0;
  const trace = new PackageStageDiagnostic(
    true,
    (line) => lines.push(line),
    () => time,
  );
  trace.event("secret/path", "begin");
  trace.event("service-stop", "secret/path");
  expect(lines).toEqual([]);
  time = 70000;
  const failure = new Error("synthetic-secret-error");
  try {
    await trace.run("mcp-probe", async () => {
      throw failure;
    });
  } catch (error) {
    expect(error).toBe(failure);
  }
  expect(lines.map(decode).map((row) => [row.phase, row.elapsedMs])).toEqual([
    ["begin", 60000],
    ["error", 60000],
  ]);
  expect(lines.join()).not.toContain("synthetic-secret");
});
test("package trace remains bounded and diagnostic sink failure cannot alter work", async () => {
  const lines: string[] = [];
  const trace = new PackageStageDiagnostic(
    true,
    (line) => lines.push(line),
    () => 0,
  );
  for (let i = 0; i < 1000; i++)
    trace.event("configuration-rename-profile", "begin");
  expect(lines.length).toBe(192);
  expect(lines.every((line) => line.length <= 192)).toBe(true);
  expect(lines.join("\n").length).toBeLessThan(32768);
  const broken = new PackageStageDiagnostic(true, () => {
    throw new Error("sink");
  });
  expect(await broken.run("file-probe", async () => 7)).toBe(7);
  const disabled = new PackageStageDiagnostic(
    false,
    () => {
      throw new Error("sink");
    },
    () => {
      throw new Error("clock");
    },
  );
  expect(await disabled.run("file-probe", async () => 9)).toBe(9);
});

test("package collector rejects untrusted rows and noncanonical JSON", () => {
  const good =
    'package_stage {"version":1,"stage":"service-stop","phase":"begin","elapsedMs":1}';
  expect(decodePackageStageLine(good)).toBe(good);
  for (const bad of [
    good.replace("service-stop", "secret"),
    good.replace('"elapsedMs":1', '"elapsedMs":true'),
    good.replace('"elapsedMs":1', '"elapsedMs":-1'),
    good.replace('"elapsedMs":1', '"elapsedMs":60001'),
    good.replace('"elapsedMs":1', '"elapsedMs":1e0'),
    good.replace('"elapsedMs":1', '"elapsedMs":-0'),
    good.replace('"elapsedMs":1', '"elapsedMs":1,"secret":"raw"'),
    good.replace('"version":1', '"version":1,"version":1'),
    good + " ",
    good.replace('"stage":', '"stage": '),
  ])
    expect(decodePackageStageLine(bad)).toBeUndefined();
  expect(collectPackageStageLines("secret\n" + good + "\r\nraw/path\n")).toBe(
    good + "\n",
  );
  expect(
    collectPackageStageLines((good + "\n").repeat(1000))
      .split("\n")
      .filter(Boolean),
  ).toHaveLength(192);
  expect(collectPackageStageLines("x".repeat(65536) + "\n" + good)).toBe("");
});
