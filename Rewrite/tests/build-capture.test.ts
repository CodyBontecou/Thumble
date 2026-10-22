import { expect, test } from "bun:test";
import { buildOptions } from "../tooling/build-options.ts";
import { packageCapture } from "../tooling/package-capture.ts";
import {
  mkdtempSync,
  mkdirSync,
  writeFileSync,
  readFileSync,
  existsSync,
  rmSync,
  symlinkSync,
  truncateSync,
} from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { createHash } from "node:crypto";
test("optical packaging is explicitly requested and composes with literal macOS output option", () => {
  for (const platform of ["darwin", "win32", "linux"]) {
    expect(buildOptions([], platform)).toEqual({
      withMacOutput: false,
      capture: null,
    });
  }
  expect(
    buildOptions(["--with-wow-capture", "--with-macos-output"], "darwin")
      .withMacOutput,
  ).toBe(true);
  expect(
    buildOptions(["--with-macos-output", "--with-wow-capture"], "darwin")
      .capture?.name,
  ).toBe("thumble-wow-capture-macos");
  for (const args of [
    ["--with-wow-capture", "--with-wow-capture"],
    ["--with-macos-output", "--with-macos-output"],
    ["--allow-physical-output"],
    ["--capture-helper", "x"],
    ["--with-wow-capture=yes"],
  ])
    expect(() => buildOptions(args, "darwin")).toThrow(
      "unsupported_build_option",
    );
  expect(() => buildOptions(["--with-wow-capture"], "linux")).toThrow(
    "wow_capture_build_requires_macos_or_windows",
  );
  expect(() =>
    buildOptions(["--with-macos-output", "--with-wow-capture"], "win32"),
  ).toThrow("macos_output_build_requires_macos");
});
test("native helper build plans only compile fixed source and never invoke their output", () => {
  for (const platform of ["darwin", "win32"]) {
    const plan = buildOptions(["--with-wow-capture"], platform).capture!;
    expect(plan.command[0]).toBe(platform === "darwin" ? "swift" : "cargo");
    expect(plan.command.includes("--capture")).toBe(false);
    expect(plan.command.includes("--status")).toBe(false);
    expect(plan.command.includes("--request-permission")).toBe(false);
    expect(plan.command).not.toContain(plan.name);
    expect(plan.source).toStartWith("native/wow-capture-");
  }
});
test("fixed optical artifacts include exact byte hashes and notices; later default assembly removes optional leaves", () => {
  for (const platform of ["darwin", "win32"]) {
    const root = mkdtempSync(join(tmpdir(), "thumble-capture-package-"));
    try {
      const plan = buildOptions(["--with-wow-capture"], platform).capture!,
        source = join(root, plan.source);
      mkdirSync(dirname(source), { recursive: true });
      const bytes = Buffer.from("synthetic binary, never executed");
      writeFileSync(source, bytes);
      if (platform === "win32")
        writeFileSync(
          join(root, "native/wow-capture-windows/THIRD-PARTY-NOTICES.txt"),
          "owned synthetic notice",
        );
      packageCapture(root, plan);
      const manifest = JSON.parse(
        readFileSync(join(root, "dist/WOW-CAPTURE-MANIFEST.json"), "utf8"),
      );
      expect(manifest.helper.name).toBe(plan.name);
      expect(manifest.helper.sha256).toBe(
        createHash("sha256").update(bytes).digest("hex"),
      );
      expect(manifest.helper.bytes).toBe(bytes.length);
      expect(readFileSync(join(root, "dist", plan.name))).toEqual(bytes);
      expect(manifest.captureEnabled).toBe(false);
      expect(manifest.osCaptureExecuted).toBe(false);
      expect(manifest.signing).toBe("not-provisioned");
      const notice = readFileSync(join(root, "dist", manifest.notices.name));
      expect(manifest.notices.sha256).toBe(
        createHash("sha256").update(notice).digest("hex"),
      );
      expect(JSON.stringify(manifest)).not.toContain(root);
      writeFileSync(join(root, "dist/unrelated.txt"), "keep");
      packageCapture(root, null);
      expect(existsSync(join(root, "dist", plan.name))).toBe(false);
      expect(existsSync(join(root, "dist/WOW-CAPTURE-MANIFEST.json"))).toBe(
        false,
      );
      expect(readFileSync(join(root, "dist/unrelated.txt"), "utf8")).toBe(
        "keep",
      );
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  }
});
test("assembly refuses empty or linked source binaries and cannot follow a stale destination link", () => {
  const root = mkdtempSync(join(tmpdir(), "thumble-capture-package-invalid-"));
  try {
    const plan = buildOptions(["--with-wow-capture"], "darwin").capture!,
      source = join(root, plan.source);
    mkdirSync(dirname(source), { recursive: true });
    writeFileSync(source, "");
    expect(() => packageCapture(root, plan)).toThrow(
      "capture_package_artifact_invalid",
    );
    truncateSync(source, 128 * 1024 * 1024 + 1);
    expect(() => packageCapture(root, plan)).toThrow(
      "capture_package_artifact_invalid",
    );
    truncateSync(source, 0);
    if (process.platform !== "win32") {
      const target = join(root, "owned-target");
      writeFileSync(target, "preserve");
      rmSync(source);
      symlinkSync(target, source);
      expect(() => packageCapture(root, plan)).toThrow(
        "capture_package_artifact_invalid",
      );
      rmSync(source);
      writeFileSync(source, "synthetic");
      mkdirSync(join(root, "dist"), { recursive: true });
      symlinkSync(target, join(root, "dist", plan.name));
      packageCapture(root, plan);
      expect(readFileSync(target, "utf8")).toBe("preserve");
      expect(readFileSync(join(root, "dist", plan.name), "utf8")).toBe(
        "synthetic",
      );
    }
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
