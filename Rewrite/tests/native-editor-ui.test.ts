import { expect, test } from "bun:test";
import { resolve } from "node:path";
test("editor model and actual label screens preserve durable intent and confirmation states", () => {
  const result = Bun.spawnSync(
    [
      process.execPath,
      "test",
      "src/editor/editor-model.test.ts",
      "src/editor/EditorScreens.test.tsx",
    ],
    {
      cwd: resolve(import.meta.dir, "../apps/mobile"),
      stdout: "pipe",
      stderr: "pipe",
      timeout: 30_000,
    },
  );
  expect(result.exitCode).toBe(0);
  const report = new TextDecoder().decode(result.stderr);
  expect(report).toMatch(/^\s*9 pass$/m);
  expect(report).toMatch(/^\s*0 fail$/m);
});
