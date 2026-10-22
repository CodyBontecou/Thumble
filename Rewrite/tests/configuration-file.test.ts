import { expect, test } from "bun:test";
import {
  copyFileSync,
  mkdtempSync,
  realpathSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { inspectConfigurationFile } from "../apps/service/src/configuration-files.ts";
import { readConfigurationFile } from "@thumble/client/local";
const root = resolve(import.meta.dir, ".."),
  fixture = resolve(
    root,
    "packages/fixtures/owned-configuration-v1/document.json",
  );
test("offline CLI/MCP inspection agrees through both SDK eras without a receiver or service", async () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-file-inspection-")),
    ),
    file = join(parent, "owned.json");
  try {
    copyFileSync(fixture, file);
    const child = Bun.spawn(
      [
        "node",
        resolve(root, "tooling/test-configuration-file-node.mjs"),
        process.execPath,
        resolve(root, "apps/cli/src/main.ts"),
        file,
        parent,
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
      scenarios: 2,
      server: "bun-source",
      serviceRequired: false,
    });
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
}, 15000);
test("file inspection rejects unsafe paths, invalid source and byte overflow without returning source", () => {
  const parent = realpathSync(
      mkdtempSync(join(tmpdir(), "thumble-file-boundary-")),
    ),
    file = join(parent, "owned.json");
  try {
    for (const path of ["relative.json", file + "\0", "x".repeat(4097)])
      expect(() => readConfigurationFile(path)).toThrow(
        "configuration_file_path_invalid",
      );
    expect(() => readConfigurationFile(file)).toThrow(
      "configuration_file_unavailable",
    );
    copyFileSync(fixture, file);
    const result = inspectConfigurationFile(file);
    expect(result.profileCount).toBe(2);
    expect(result.activationCompatibility).toBe("not-evaluated");
    expect(JSON.stringify(result)).not.toContain("Local fixture app");
    writeFileSync(file, '{"schema":"not-owned","version":5}');
    expect(() => inspectConfigurationFile(file)).toThrow();
    writeFileSync(file, new Uint8Array(8 * 1024 * 1024 + 1));
    expect(() => readConfigurationFile(file)).toThrow(
      "configuration_file_too_large",
    );
    if (process.platform !== "win32") {
      const link = join(parent, "link.json");
      symlinkSync(file, link);
      expect(() => readConfigurationFile(link)).toThrow(
        "unsafe_configuration_file",
      );
    }
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
});
