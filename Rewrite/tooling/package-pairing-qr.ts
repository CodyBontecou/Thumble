/** Optional fixed-name QR binary assembly. Never executes a helper. */
import { createHash } from "node:crypto";
import { lstatSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { readPackageArtifact } from "./package-capture.ts";
export function packagePairingQR(root: string, enabled: boolean): void {
  const dist = join(root, "dist");
  mkdirSync(dist, { recursive: true });
  const stat = lstatSync(dist);
  if (!stat.isDirectory() || stat.isSymbolicLink())
    throw new Error("pairing_qr_package_directory_invalid");
  let bytes: Buffer | undefined;
  if (enabled) {
    try {
      bytes = readPackageArtifact(
        join(
          root,
          "native/pairing-qr-macos/.build/release/thumble-pairing-qr-macos",
        ),
        128 * 1024 * 1024,
      );
    } catch {
      throw new Error("pairing_qr_package_artifact_invalid");
    }
  }
  for (const name of [
    "thumble-pairing-qr-macos",
    "PAIRING-QR-MANIFEST.json",
    "Pairing-QR-NOTICES.txt",
  ])
    rmSync(join(dist, name), { force: true });
  if (!bytes) return;
  const sha = (value: Uint8Array) =>
    createHash("sha256").update(value).digest("hex");
  const notices = Buffer.from(
    "Thumble macOS pairing QR helper\nProduction-owned Swift source, with no external package dependencies. Apple system frameworks are not bundled.\nProvenance: native/pairing-qr-macos/README.md. Artifact assembly never executes helper code, provisions/signs identities or opens pairing.\n",
  );
  writeFileSync(join(dist, "thumble-pairing-qr-macos"), bytes, {
    flag: "wx",
    mode: 0o755,
  });
  writeFileSync(join(dist, "Pairing-QR-NOTICES.txt"), notices, { flag: "wx" });
  writeFileSync(
    join(dist, "PAIRING-QR-MANIFEST.json"),
    JSON.stringify(
      {
        version: 1,
        kind: "optional-macos-pairing-qr",
        helper: {
          name: "thumble-pairing-qr-macos",
          bytes: bytes.length,
          sha256: sha(bytes),
        },
        notices: { name: "Pairing-QR-NOTICES.txt", sha256: sha(notices) },
        helperExecuted: false,
        pairingOpened: false,
        signing: "not-provisioned",
      },
      null,
      2,
    ) + "\n",
    { flag: "wx" },
  );
}
