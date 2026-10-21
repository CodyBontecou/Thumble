import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
const root = resolve(import.meta.dir, ".."),
  extension = process.platform === "win32" ? ".exe" : "";
mkdirSync(resolve(root, "dist"), { recursive: true });
const noticePath = resolve(root, "native/receiver/THIRD-PARTY-NOTICES.txt");
const lockHash = createHash("sha256")
  .update(readFileSync(resolve(root, "native/receiver/Cargo.lock")))
  .digest("hex");
if (
  !readFileSync(noticePath, "utf8").includes(
    `Cargo.lock SHA-256: ${lockHash}\n`,
  )
)
  throw new Error(
    "Native dependency notices must be refreshed for the current lockfile",
  );
copyFileSync(noticePath, resolve(root, "dist/Native-THIRD-PARTY-NOTICES.txt"));

for (const command of [
  [
    "cargo",
    "+1.88.0",
    "build",
    "--locked",
    "--release",
    "--manifest-path",
    "native/receiver/Cargo.toml",
  ],
  [
    process.execPath,
    "build",
    "--compile",
    "apps/cli/src/main.ts",
    "--outfile",
    `dist/thumble-rewrite${extension}`,
  ],
]) {
  const result = Bun.spawnSync(command, {
    cwd: root,
    stdout: "inherit",
    stderr: "inherit",
  });
  if (result.exitCode !== 0) process.exit(result.exitCode);
}
copyFileSync(
  resolve(
    root,
    `native/receiver/target/release/thumble-rewrite-receiver${extension}`,
  ),
  resolve(root, `dist/thumble-rewrite-receiver${extension}`),
);
copyFileSync(
  resolve(root, "../ThirdParty/SteamControllerBridge-LICENSE.txt"),
  resolve(root, "dist/SteamControllerBridge-LICENSE.txt"),
);
writeFileSync(
  resolve(root, "dist/README.txt"),
  "M2 development package. Native recording backend only; no OS input is emitted. Keep the CLI and receiver siblings together. User-restricted runtime state is isolated from the retained authority. Production signing, drivers and gameplay acceptance remain pending.\n",
);
console.log(
  "Built standalone CLI and recording receiver; no repository checkout is needed at runtime",
);
