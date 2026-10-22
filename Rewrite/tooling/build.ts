import { checkCliNotices } from "./check-cli-notices.ts";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
const arguments_ = process.argv.slice(2);
if (
  arguments_.length > 1 ||
  (arguments_.length === 1 && arguments_[0] !== "--with-macos-output")
)
  throw new Error("unsupported_build_option");
const withMacOutput = arguments_[0] === "--with-macos-output";
if (withMacOutput && process.platform !== "darwin")
  throw new Error("macos_output_build_requires_macos");
checkCliNotices();
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

copyFileSync(
  resolve(root, "apps/cli/THIRD-PARTY-NOTICES.txt"),
  resolve(root, "dist/CLI-THIRD-PARTY-NOTICES.txt"),
);

for (const command of [
  [
    "cargo",
    "+1.88.0",
    "build",
    "--locked",
    "--release",
    ...(withMacOutput ? ["--features", "output-macos"] : []),
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
copyFileSync(resolve(root, "REVIEWING.md"), resolve(root, "dist/REVIEWING.md"));
writeFileSync(
  resolve(root, "dist/README.txt"),
  [
    withMacOutput
      ? "Thumble rewrite review package. Optional macOS HID code compiled; recording remains the default."
      : "Thumble rewrite review package. Recording backend only; no OS input is emitted.",
    ...(withMacOutput
      ? [
          "Physical output requires explicit service selection and --allow-physical-output, and an appropriately authorized native helper. This build does not sign or provision that helper.",
        ]
      : []),
    "Keep thumble-rewrite and thumble-rewrite-receiver (with .exe on Windows) together.",
    "Run: thumble-rewrite service start --runtime-dir ABSOLUTE_PRIVATE_PATH --json",
    "Then: thumble-rewrite receiver status --runtime-dir ABSOLUTE_PRIVATE_PATH --json",
    "Stop: thumble-rewrite service stop --runtime-dir ABSOLUTE_PRIVATE_PATH --json",
    "Agent entry: thumble-rewrite mcp serve --runtime-dir ABSOLUTE_PRIVATE_PATH",
    "MCP is read-only by default; configuration writes and recording input require explicit flags.",
    "Runtime state is isolated from the retained product. Signing, physical output, drivers and gameplay acceptance remain pending.",
    "See REVIEWING.md for source review and verification; source checkout paths in that guide are not required at runtime.",
    "",
  ].join("\n"),
);
console.log(
  withMacOutput
    ? "Built standalone CLI and receiver with optional macOS output; no signing or physical activation performed"
    : "Built standalone CLI and recording receiver; no repository checkout is needed at runtime",
);
