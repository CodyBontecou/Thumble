import { resolve } from "node:path";
const root = resolve(import.meta.dir, "..");
const child = Bun.spawn(
  [
    "node",
    resolve(root, "tooling/test-mcp-node.mjs"),
    process.execPath,
    resolve(root, "apps/cli/src/main.ts"),
    resolve(
      root,
      `native/receiver/target/debug/thumble-rewrite-receiver${process.platform === "win32" ? ".exe" : ""}`,
    ),
  ],
  { cwd: root, stdout: "inherit", stderr: "inherit" },
);
process.exitCode = await child.exited;
