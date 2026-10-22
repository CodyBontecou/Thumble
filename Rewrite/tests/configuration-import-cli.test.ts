import { expect, test } from "bun:test";
import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
const root = resolve(import.meta.dir, "..");
test("CLI and both MCP SDK eras import/export, poll, enforce scoped files and recover safe retries", async () => {
  const parent = realpathSync(
    mkdtempSync(join(tmpdir(), "thumble-import-cli-")),
  );
  try {
    const child = Bun.spawn(
      [
        "node",
        resolve(root, "tooling/test-configuration-import-node.mjs"),
        process.execPath,
        resolve(root, "apps/cli/src/main.ts"),
        resolve(
          root,
          `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
        ),
        join(parent, "runtime"),
        resolve(root, "packages/fixtures/owned-configuration-v1/document.json"),
      ],
      { stdout: "pipe", stderr: "pipe" },
    );
    const [out, err, code] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited,
    ]);
    expect(err).toBe("");
    expect(code).toBe(0);
    expect(JSON.parse(out)).toEqual({
      ok: true,
      scenarios: 4,
      imports: 2,
      server: "bun-source",
    });
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}, 30000);
