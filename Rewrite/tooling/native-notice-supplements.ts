import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
type Declaration = { sha256: string; text: string };
type Entry = {
  name: string;
  version: string;
  repository: string;
  vcsCommit: string;
  license: string;
  declarationUrl: string;
  sourceHashes: { "Cargo.toml": string; ".cargo_vcs_info.json": string };
};
/** Offline, exact-version fallback for audited crate archives that omit licenses. */
export function nativeNoticeSupplement(
  root: string,
  name: string,
  version: string,
  directory: string,
): string | undefined {
  const audit = JSON.parse(
    readFileSync(join(root, "notice-supplements/objc2.json"), "utf8"),
  ) as {
    scope: string;
    packages: Entry[];
    declaration: Declaration;
    mitTemplate: Declaration & { url: string };
  };
  const entry = audit.packages.find(
    (p) => p.name === name && p.version === version,
  );
  if (!entry) return undefined;
  for (const file of ["Cargo.toml", ".cargo_vcs_info.json"] as const)
    if (
      createHash("sha256")
        .update(readFileSync(join(directory, file)))
        .digest("hex") !== entry.sourceHashes[file]
    )
      throw new Error(`Unreviewed license source for ${name} ${version}`);
  const metadata = Bun.TOML.parse(
    readFileSync(join(directory, "Cargo.toml"), "utf8"),
  ) as {
    package: {
      name: string;
      version: string;
      repository: string;
      license: string;
      authors?: string[];
    };
  };
  const vcs = JSON.parse(
    readFileSync(join(directory, ".cargo_vcs_info.json"), "utf8"),
  ) as { git: { sha1: string } };
  if (
    metadata.package.name !== name ||
    metadata.package.version !== version ||
    metadata.package.repository !== entry.repository ||
    entry.repository !== "https://github.com/madsmtm/objc2" ||
    metadata.package.license !== entry.license ||
    !entry.license.split(" OR ").includes("MIT") ||
    vcs.git.sha1 !== entry.vcsCommit ||
    !/^[0-9a-f]{40}$/.test(entry.vcsCommit) ||
    entry.declarationUrl !==
      `${entry.repository.replace("github.com", "raw.githubusercontent.com")}/${entry.vcsCommit}/LICENSE.md`
  )
    throw new Error(`Unreviewed license metadata for ${name} ${version}`);
  for (const text of [audit.declaration, audit.mitTemplate])
    if (createHash("sha256").update(text.text).digest("hex") !== text.sha256)
      throw new Error("Audited license text hash mismatch");
  return `\nPublished crate omits LICENSE/COPYING files. Audited metadata: ${entry.repository}\nVersion ${version}; VCS commit ${entry.vcsCommit}; license ${entry.license}; MIT selected.\nPublished package authors (not an invented copyright notice): ${JSON.stringify(metadata.package.authors ?? [])}\nUpstream declaration: ${entry.declarationUrl}\nSHA-256: ${audit.declaration.sha256}\n${audit.declaration.text.trimEnd()}\n\nStandard SPDX MIT template; literal placeholders are not a project-specific copyright claim.\nSource: ${audit.mitTemplate.url}\nSHA-256: ${audit.mitTemplate.sha256}\n${audit.mitTemplate.text.trimEnd()}\n`;
}
