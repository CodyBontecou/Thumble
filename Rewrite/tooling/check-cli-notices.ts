import { createHash } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
const root = resolve(import.meta.dir, "..");
export function checkCliNotices(): void {
  const manifest = JSON.parse(
    readFileSync(join(root, "apps/cli/runtime-notices.json"), "utf8"),
  ) as {
    noticesSha256: string;
    packages: {
      name: string;
      version: string;
      files: Record<string, string>;
    }[];
  };
  const hash = (path: string) =>
    createHash("sha256").update(readFileSync(path)).digest("hex");
  if (
    hash(join(root, "apps/cli/THIRD-PARTY-NOTICES.txt")) !==
    manifest.noticesSha256
  )
    throw new Error("cli_notices_changed");
  for (const item of manifest.packages) {
    let directory = dirname(
      Bun.resolveSync(
        item.name,
        item.name === "@modelcontextprotocol/core"
          ? dirname(
              Bun.resolveSync(
                "@modelcontextprotocol/server",
                join(root, "apps/cli"),
              ),
            )
          : join(root, "apps/cli"),
      ),
    );
    while (!existsSync(join(directory, "package.json"))) {
      const parent = dirname(directory);
      if (parent === directory) throw new Error("cli_dependency_unavailable");
      directory = parent;
    }
    const info = JSON.parse(
      readFileSync(join(directory, "package.json"), "utf8"),
    );
    if (info.name !== item.name || info.version !== item.version)
      throw new Error("cli_dependency_notices_stale");
    for (const [path, expected] of Object.entries(item.files))
      if (hash(join(directory, path)) !== expected)
        throw new Error("cli_dependency_notices_stale");
  }
}
if (import.meta.main) {
  checkCliNotices();
  console.log("CLI dependency notices match the audited runtime distributions");
}
