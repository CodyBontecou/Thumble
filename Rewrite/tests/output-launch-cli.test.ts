import { expect, test } from "bun:test";
import { mkdtempSync, existsSync, rmSync } from "node:fs";
import { join, resolve } from "node:path";
import { tmpdir } from "node:os";

test("CLI rejects invalid physical launch policy before creating runtime state", () => {
  const parent = mkdtempSync(join(tmpdir(), "thumble-output-policy-"));
  const runtime = join(parent, "must-remain-absent");
  try {
    for (const [args, error] of [
      [
        ["service", "start", "--output", "macos-hid"],
        "physical_output_explicit_flag_required",
      ],
      [
        ["service", "start", "--allow-physical-output"],
        "physical_output_option_mismatch",
      ],
      [
        [
          "receiver",
          "status",
          "--output",
          "macos-hid",
          "--allow-physical-output",
        ],
        "invalid_output_launch_option",
      ],
    ] as const) {
      const child = Bun.spawnSync(
        [
          process.execPath,
          resolve(import.meta.dir, "../apps/cli/src/main.ts"),
          ...args,
          "--runtime-dir",
          runtime,
          "--json",
        ],
        { stdout: "pipe", stderr: "pipe" },
      );
      expect(child.exitCode).toBe(1);
      expect(child.stderr.toString()).toBe("");
      expect(JSON.parse(child.stdout.toString())).toEqual({
        version: 1,
        ok: false,
        error,
      });
      expect(existsSync(runtime)).toBe(false);
    }
  } finally {
    rmSync(parent, { recursive: true, force: true });
  }
});
