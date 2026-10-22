import { expect, test } from "bun:test";
import { resolve } from "node:path";

test("actual React controller admission/catalog lifecycle integration passes in isolated renderer", () => {
  // Native host substitutions must remain isolated from the portable domain suite.
  const result = Bun.spawnSync(
    [process.execPath, "test", "src/components/NativeController.test.tsx"],
    {
      cwd: resolve(import.meta.dir, "../apps/mobile"),
      stdout: "pipe",
      stderr: "pipe",
      timeout: 15_000,
    },
  );
  expect(result.exitCode).toBe(0);
  const report = new TextDecoder().decode(result.stderr);
  expect(report).toMatch(/^\s*17 pass$/m);
  expect(report).toMatch(/^\s*0 fail$/m);
  expect(report).not.toMatch(/\d+ skip/);
});
