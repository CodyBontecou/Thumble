#!/usr/bin/env python3
"""Check unminified Apple app bundles for retired hosted clients, keeping local file import."""
import argparse
from pathlib import Path
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--ios-app", type=Path)
parser.add_argument("--mac-app", type=Path)
parser.add_argument("--entitlements", type=Path, default=Path("Resources/iOS/ThumbleiOS.entitlements"))
args = parser.parse_args()
if not args.ios_app and not args.mac_app:
    parser.error("provide at least one app bundle")

retired = [b"URLSessionBuilderArtifactFetcher", b"BuilderArtifactShareReference", b"IOSBuilderArtifactPickupCoordinator",
           b"IOSBuilderArtifactPracticePreview", b"IOSPendingBuilderArtifactStore",
           b"ProfileArtifactAdoptionAssembler", b"ProfileArtifactAdoptionCommitGate",
           b"ProfileArtifactAdoptionLedger"]
for label, bundle in (("iOS", args.ios_app), ("macOS", args.mac_app)):
    if bundle is None:
        continue
    info_path = bundle / ("Contents/Info.plist" if label == "macOS" else "Info.plist")
    info = plistlib.loads(info_path.read_bytes())
    directory = bundle / "Contents/MacOS" if label == "macOS" else bundle
    executable = info["CFBundleExecutable"]
    binaries = [p for p in directory.iterdir() if p.is_file() and (p.name == executable or p.name.endswith(".debug.dylib"))]
    if not binaries:
        raise SystemExit(f"{label}: app executable is missing")
    payloads = [p.read_bytes() for p in binaries]
    for marker in retired:
        if any(marker in payload for payload in payloads):
            raise SystemExit(f"{label}: retired implementation still ships: {marker.decode()}")
    expected = b"PendingProfileRecovery" if label == "iOS" else b"MacSharedKeypadImportModel"
    if not any(expected in payload for payload in payloads):
        raise SystemExit(f"{label}: expected retained implementation is missing (use an unminified app)")
    if label == "macOS" and any(b"Shared build link" in payload for payload in payloads):
        raise SystemExit("macOS: hosted-link import UI still ships")
    print(f"{label}: hosted clients/pruning store absent; retained local recovery/import implementation present")
entitlements = plistlib.loads(args.entitlements.read_bytes())
if entitlements.get("com.apple.developer.associated-domains"):
    raise SystemExit("iOS source entitlements still associate hosted domains")
print("iOS source entitlements: no hosted associated domains")
