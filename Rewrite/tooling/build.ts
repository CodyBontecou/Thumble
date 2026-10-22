import { buildOptions } from "./build-options.ts";
import { packageCapture } from "./package-capture.ts";
import { checkCliNotices } from "./check-cli-notices.ts";
import { createHash } from "node:crypto";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
const { withMacOutput, capture } = buildOptions(
  process.argv.slice(2),
  process.platform,
);
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
  ...(capture?.platform === "win32"
    ? [[process.execPath, "tooling/windows-capture-notices.ts", "--check"]]
    : []),
  ...(capture ? [[...capture.command]] : []),
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
packageCapture(root, capture);
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
    ...(capture
      ? [
          `Optional optical helper: ${capture.name}. Build does not run it or enable capture. Verify WOW-CAPTURE-MANIFEST.json and retain Optical-THIRD-PARTY-NOTICES.txt.`,
          `Explicit launch: thumble-rewrite service start --runtime-dir ABSOLUTE_PRIVATE_PATH --capture-helper ABSOLUTE_PACKAGE_DIRECTORY/${capture.name} --json`,
          "Then request one frame: thumble-rewrite wow capture-start --source world-of-warcraft --runtime-dir ABSOLUTE_PRIVATE_PATH --json",
          "Capture status exposes receipt metadata only; automatic live sync, real capture compatibility and signing remain unverified.",
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
  capture
    ? "Built standalone CLI, receiver and optional optical helper; no helper execution, signing or capture performed"
    : withMacOutput
      ? "Built standalone CLI and receiver with optional macOS output; no signing or physical activation performed"
      : "Built standalone CLI and recording receiver; no repository checkout is needed at runtime",
);
