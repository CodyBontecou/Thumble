/** Source-only helper notice audit. No native helper or OS APIs are executed. */
import { createHash } from "node:crypto";
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
const root = resolve(import.meta.dir, "../native/wow-capture-windows");
const metadata = Bun.spawnSync(
  [
    "cargo",
    "+1.88.0",
    "metadata",
    "--locked",
    "--format-version",
    "1",
    "--manifest-path",
    join(root, "Cargo.toml"),
  ],
  { stdout: "pipe", stderr: "pipe" },
);
if (metadata.exitCode !== 0)
  throw new Error("windows_capture_notice_metadata_failed");
const packages: unknown = JSON.parse(
  Buffer.from(metadata.stdout).toString("utf8"),
).packages;
if (!Array.isArray(packages))
  throw new Error("windows_capture_notice_metadata_invalid");
const entries = packages
  .filter((p) => p.source !== null)
  .sort((a, b) =>
    `${a.name}@${a.version}` < `${b.name}@${b.version}` ? -1 : 1,
  );
const hash = createHash("sha256")
  .update(readFileSync(join(root, "Cargo.lock")))
  .digest("hex");
let output = `Windows optical helper third-party source notices\nCargo.lock SHA-256: ${hash}\nIncludes every locked registry package, including Windows-only dependencies.\nMIT is selected where offered as an alternative; Unicode data notice retained.\nNo third-party implementation source is vendored.\n\n`;
for (const pkg of entries) {
  if (
    ![
      "MIT",
      "Unlicense OR MIT",
      "MIT OR Apache-2.0",
      "(MIT OR Apache-2.0) AND Unicode-3.0",
    ].includes(pkg.license)
  )
    throw new Error("windows_capture_notice_license_unreviewed");
  const directory = dirname(pkg.manifest_path),
    files = readdirSync(directory)
      .filter((name) =>
        ["license-mit", "license-unicode", "notice", "copyright"].includes(
          name.toLowerCase(),
        ),
      )
      .sort();
  if (
    !files.some((name) => name.toLowerCase() === "license-mit") ||
    (pkg.name === "unicode-ident" && !files.includes("LICENSE-UNICODE"))
  )
    throw new Error("windows_capture_notice_missing_license");
  output += `${pkg.name} ${pkg.version}\nDeclared license: ${pkg.license}\n`;
  for (const name of files) {
    const bytes = readFileSync(join(directory, name));
    if (bytes.length > 65536)
      throw new Error("windows_capture_notice_file_too_large");
    output += `--- ${name} (SHA-256 ${createHash("sha256").update(bytes).digest("hex")}) ---\n${bytes.toString("utf8").trimEnd()}\n`;
  }
  output += "\n";
}
output = output.trimEnd() + "\n";
const file = join(root, "THIRD-PARTY-NOTICES.txt");
if (process.argv.includes("--check")) {
  if (readFileSync(file, "utf8") !== output)
    throw new Error("windows_capture_notices_stale");
} else writeFileSync(file, output);
console.log(
  JSON.stringify({
    kind: "windows-capture-source-notices",
    packages: entries.length,
    checked: process.argv.includes("--check"),
    osCapture: false,
  }),
);
