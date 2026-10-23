/** Fixed artifact assembly only. No executable is ever launched by this module. */
import { createHash } from "node:crypto";
import {
  lstatSync,
  openSync,
  closeSync,
  fstatSync,
  readSync,
  constants,
  mkdirSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import type { CaptureBuild } from "./build-options.ts";
const NAMES = [
  "thumble-wow-capture-macos",
  "thumble-wow-capture-windows.exe",
  "Optical-THIRD-PARTY-NOTICES.txt",
  "WOW-CAPTURE-MANIFEST.json",
];
const sha = (bytes: Uint8Array) =>
  createHash("sha256").update(bytes).digest("hex");
export function readPackageArtifact(path: string, limit: number): Buffer {
  let descriptor: number | undefined;
  try {
    if (lstatSync(path).isSymbolicLink()) throw new Error();
    descriptor = openSync(
      path,
      constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0),
    );
    const stat = fstatSync(descriptor);
    if (!stat.isFile() || stat.size < 1 || stat.size > limit) throw new Error();
    const bytes = Buffer.alloc(stat.size);
    let at = 0;
    while (at < bytes.length) {
      const count = readSync(descriptor, bytes, at, bytes.length - at, null);
      if (!count) throw new Error();
      at += count;
    }
    if (readSync(descriptor, Buffer.alloc(1), 0, 1, null) !== 0)
      throw new Error();
    const after = lstatSync(path);
    if (
      after.isSymbolicLink() ||
      !after.isFile() ||
      after.dev !== stat.dev ||
      after.ino !== stat.ino
    )
      throw new Error();
    return bytes;
  } catch {
    throw new Error("capture_package_artifact_invalid");
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}
export function packageCapture(root: string, plan: CaptureBuild | null): void {
  const dist = join(root, "dist");
  mkdirSync(dist, { recursive: true });
  const stat = lstatSync(dist);
  if (!stat.isDirectory() || stat.isSymbolicLink())
    throw new Error("capture_package_directory_invalid");
  let helper: Buffer | undefined, notices: Buffer | undefined;
  if (plan) {
    helper = readPackageArtifact(join(root, plan.source), 128 * 1024 * 1024);
    notices =
      plan.platform === "win32"
        ? readPackageArtifact(
            join(root, "native/wow-capture-windows/THIRD-PARTY-NOTICES.txt"),
            256 * 1024,
          )
        : Buffer.from(
            "Thumble optical capture helper (macOS)\nThe standalone Swift package has no external Swift package dependencies.\nApple system frameworks and SDKs are not bundled by this build.\nProject source provenance: native/wow-capture-macos/README.md.\nNo signing, provisioning, permission inspection/request or OS capture is performed by artifact assembly.\n",
          );
  }
  // Remove fixed optional leaves, including symlinks, rather than following stale
  // destinations. A later default build cannot accidentally retain an opt-in helper.
  for (const name of NAMES) rmSync(join(dist, name), { force: true });
  if (!plan || !helper || !notices) return;
  writeFileSync(join(dist, plan.name), helper, { flag: "wx", mode: 0o755 });
  writeFileSync(join(dist, "Optical-THIRD-PARTY-NOTICES.txt"), notices, {
    flag: "wx",
  });
  const manifest = {
    version: 1,
    kind: "optional-wow-capture-package",
    platform: plan.platform,
    helper: { name: plan.name, bytes: helper.length, sha256: sha(helper) },
    notices: {
      name: "Optical-THIRD-PARTY-NOTICES.txt",
      bytes: notices.length,
      sha256: sha(notices),
    },
    captureEnabled: false,
    osCaptureExecuted: false,
    signing: "not-provisioned",
    compatibility: "unverified",
  };
  const text = JSON.stringify(manifest, null, 2) + "\n";
  if (Buffer.byteLength(text) > 4096)
    throw new Error("capture_package_manifest_invalid");
  writeFileSync(join(dist, "WOW-CAPTURE-MANIFEST.json"), text, { flag: "wx" });
}
