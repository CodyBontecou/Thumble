import { expect, test } from "bun:test";
import { resolve } from "node:path";

test("native editor facade uses fixed calls and bounded immutable DTOs", () => {
  const result = Bun.spawnSync(
    [process.execPath, "test", "src/editor/NativeEditorSession.test.ts"],
    {
      cwd: resolve(import.meta.dir, "../apps/mobile"),
      stdout: "pipe",
      stderr: "pipe",
      timeout: 15_000,
    },
  );
  expect(result.exitCode).toBe(0);
  const report = new TextDecoder().decode(result.stderr);
  expect(report).toMatch(/^\s*2 pass$/m);
  expect(report).toMatch(/^\s*0 fail$/m);
});
