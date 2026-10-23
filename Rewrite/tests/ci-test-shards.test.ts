import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import {
  parseTestSelection,
  selectTestFiles,
} from "../tooling/ci-test-options";

describe("CI file shards", () => {
  test("strict arguments reject malformed, repeated and mixed modes", () => {
    expect(parseTestSelection([])).toEqual({ packageMode: false, shard: null });
    expect(parseTestSelection(["--package"]).packageMode).toBe(true);
    expect(parseTestSelection(["--shard", "2/3"]).shard).toEqual({
      index: 2,
      count: 3,
    });
    for (const args of [
      ["--shard"],
      ["--shard", "0/3"],
      ["--shard", "4/3"],
      ["--shard", "01/3"],
      ["--shard", "1/0"],
      ["--shard", "1/17"],
      ["--shard", "1/3junk"],
      ["--shard=1/3"],
      ["--package", "--shard", "1/3"],
      ["--shard", "1/3", "--shard", "2/3"],
      ["--unknown"],
    ]) {
      expect(() => parseTestSelection(args)).toThrow(
        "Invalid CI test arguments",
      );
    }
  });
  test("three deterministic nonempty shards cover every discovered test exactly once", () => {
    const files = [
      ...new Bun.Glob("**/*").scanSync({
        cwd: resolve(import.meta.dir),
        onlyFiles: true,
        followSymlinks: false,
      }),
    ]
      .filter((file) => /(?:^|[._])(?:test|spec)\.[cm]?[jt]sx?$/.test(file))
      .map((file) => `./tests/${file.replaceAll("\\", "/")}`)
      .sort();
    const full = selectTestFiles(files, parseTestSelection([]));
    const shards = [1, 2, 3].map((index) =>
      selectTestFiles(
        [...files].reverse(),
        parseTestSelection(["--shard", `${index}/3`]),
      ),
    );
    expect(full.length).toBeGreaterThanOrEqual(3);
    expect(shards.every((shard) => shard.length > 0)).toBe(true);
    expect(shards.flat().sort()).toEqual(full);
    expect(new Set(shards.flat()).size).toBe(full.length);
    expect(
      Math.max(...shards.map((shard) => shard.length)) -
        Math.min(...shards.map((shard) => shard.length)),
    ).toBeLessThanOrEqual(1);
    expect(selectTestFiles(files, parseTestSelection(["--package"]))).toEqual([
      "./tests/package.test.ts",
    ]);
  });
  test("duplicate, unsafe and empty inventories fail closed", () => {
    for (const files of [
      [],
      ["/tmp/test.ts"],
      ["./tests/../test.ts"],
      ["./tests/a.test.ts", "./tests/a.test.ts"],
    ])
      expect(() => selectTestFiles(files, parseTestSelection([]))).toThrow();
    expect(() =>
      selectTestFiles(
        ["./tests/a.test.ts"],
        parseTestSelection(["--shard", "2/3"]),
      ),
    ).toThrow("Empty CI test selection");
  });
});
