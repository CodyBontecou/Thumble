import { expect, test } from "bun:test";
import { createHash } from "node:crypto";
import {
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { nativeNoticeSupplement } from "../tooling/native-notice-supplements.ts";

test("audited optional notices bind exact package metadata, source and verbatim text hashes", () => {
  const root = mkdtempSync(join(tmpdir(), "thumble-notice-audit-"));
  try {
    const audit = JSON.parse(
      readFileSync(
        resolve(
          import.meta.dir,
          "../native/receiver/notice-supplements/objc2.json",
        ),
        "utf8",
      ),
    );
    mkdirSync(join(root, "notice-supplements"));
    const source = join(root, "crate");
    mkdirSync(source);
    const digest = (s: string) => createHash("sha256").update(s).digest("hex");
    const save = () =>
      writeFileSync(
        join(root, "notice-supplements/objc2.json"),
        JSON.stringify(audit),
      );
    for (const entry of audit.packages) {
      const toml = `[package]\nname = "${entry.name}"\nversion = "${entry.version}"\nrepository = "${entry.repository}"\nlicense = "${entry.license}"\n`;
      const vcs = JSON.stringify({ git: { sha1: entry.vcsCommit } });
      entry.sourceHashes = {
        "Cargo.toml": digest(toml),
        ".cargo_vcs_info.json": digest(vcs),
      };
      writeFileSync(join(source, "Cargo.toml"), toml);
      writeFileSync(join(source, ".cargo_vcs_info.json"), vcs);
      save();
      const notice = nativeNoticeSupplement(
        root,
        entry.name,
        entry.version,
        source,
      );
      expect(notice).toContain(audit.declaration.text.trimEnd());
      expect(notice).toContain(audit.mitTemplate.text.trimEnd());
      expect(notice).toContain(entry.vcsCommit);
      expect(
        nativeNoticeSupplement(root, entry.name, "99.0.0", source),
      ).toBeUndefined();
      writeFileSync(join(source, "Cargo.toml"), toml + "# changed archive\n");
      expect(() =>
        nativeNoticeSupplement(root, entry.name, entry.version, source),
      ).toThrow("Unreviewed license source");
      writeFileSync(join(source, "Cargo.toml"), toml);
      const original = entry.repository;
      entry.repository = "https://example.invalid/license";
      save();
      expect(() =>
        nativeNoticeSupplement(root, entry.name, entry.version, source),
      ).toThrow("Unreviewed license metadata");
      entry.repository = original;
      const text = audit.declaration.text;
      audit.declaration.text += "changed";
      save();
      expect(() =>
        nativeNoticeSupplement(root, entry.name, entry.version, source),
      ).toThrow("Audited license text hash mismatch");
      audit.declaration.text = text;
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
