import { nativeNoticeSupplement } from "./native-notice-supplements.ts";
// Regenerate after cargo fetch --locked. Reads only the locked registry source cache.
import { createHash } from "node:crypto";
import {
  existsSync,
  readFileSync,
  readdirSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { basename, join, resolve } from "node:path";
const root = resolve(import.meta.dir, "../native/receiver");
const lock = readFileSync(join(root, "Cargo.lock"), "utf8");
const parsed = Bun.TOML.parse(lock) as {
  package: { name: string; version: string; source?: string }[];
};
const registry = join(
  process.env.CARGO_HOME ?? join(homedir(), ".cargo"),
  "registry/src",
);
const roots = readdirSync(registry)
  .sort()
  .map((name) => join(registry, name));
function source(name: string, version: string): string {
  const path = roots
    .map((base) => join(base, `${name}-${version}`))
    .find(existsSync);
  if (!path)
    throw new Error(
      `Missing locked source ${name} ${version}; run cargo fetch --locked`,
    );
  return path;
}
let output = `Native receiver third-party notices\nCargo.lock SHA-256: ${createHash("sha256").update(lock).digest("hex")}\n\nIncludes every locked registry dependency, including target-specific and development dependencies. MIT is selected where offered as a license alternative. Supplemental notices are retained.\n`;
for (const pkg of parsed.package) {
  if (!pkg.source) continue;
  if (!pkg.source.startsWith("registry+"))
    throw new Error(`Unsupported source for ${pkg.name}`);
  const directory = source(pkg.name, pkg.version);
  const all = readdirSync(directory, { recursive: true })
    .filter((path): path is string => typeof path === "string")
    .filter(
      (path) =>
        /^(LICENSE|COPYING|COPYRIGHT|NOTICE)([.-]|$)/i.test(basename(path)) &&
        statSync(join(directory, path)).isFile(),
    )
    .sort();
  const mit = all.find(
    (path) => !path.includes("/") && /^license-mit$/i.test(path),
  );
  let selected =
    pkg.name === "ring" || !mit
      ? all
      : [
          mit,
          ...all.filter((path) =>
            /^(COPYRIGHT|NOTICE|LICENSE-UNICODE)([.-]|$)/i.test(basename(path)),
          ),
        ];
  output += `\n${"=".repeat(72)}\n${pkg.name} ${pkg.version}\n`;
  if (!selected.length) {
    const audited = nativeNoticeSupplement(
      root,
      pkg.name,
      pkg.version,
      directory,
    );
    if (audited !== undefined) {
      output += audited;
      continue;
    }
    // These published subcrates omit license files; use the same upstream project's packaged license.
    const fallback =
      pkg.name === "asn1-rs-impl"
        ? ["asn1-rs", "0.7.2"]
        : /^winapi-(i686|x86_64)-pc-windows-gnu$/.test(pkg.name)
          ? ["winapi", "0.3.9"]
          : pkg.name === "rsqlite-vfs"
            ? ["sqlite-wasm-rs", "0.5.5", "LICENSE"]
            : undefined;
    if (!fallback) throw new Error(`No license files for ${pkg.name}`);
    const name = fallback[2] ?? "LICENSE-MIT";
    output += `\n${name} (same upstream project: ${fallback.slice(0, 2).join(" ")})\n${readFileSync(join(source(fallback[0]!, fallback[1]!), name), "utf8").trimEnd()}\n`;
  }
  if (pkg.name === "libsqlite3-sys") {
    const sqlite = readFileSync(join(directory, "sqlite3/sqlite3.c"), "utf8");
    const declaration = sqlite.indexOf("The author disclaims copyright");
    const begin = sqlite.lastIndexOf("/*", declaration);
    const end = sqlite.indexOf("*/", declaration);
    if (declaration < 0 || begin < 0 || end < begin)
      throw new Error("SQLite public-domain declaration missing");
    output += `\nBundled SQLite (sqlite3/sqlite3.c public-domain declaration)\n${sqlite.slice(begin, end + 2)}\n`;
  }
  for (const path of selected)
    output += `\n${path.replaceAll("\\", "/")}\n${readFileSync(join(directory, path), "utf8").trimEnd()}\n`;
}
output = output.replaceAll("\r\n", "\n");
const target = join(root, "THIRD-PARTY-NOTICES.txt");
if (process.argv.includes("--check")) {
  if (readFileSync(target, "utf8") !== output)
    throw new Error("Native dependency notices are stale");
} else writeFileSync(target, output);
console.log(
  `Native notices ${process.argv.includes("--check") ? "verified" : "generated"} for ${parsed.package.filter((pkg) => pkg.source).length} locked crates`,
);
