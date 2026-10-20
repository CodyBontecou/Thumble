#!/usr/bin/env python3
"""Verify the unminified Android APK excludes retired hosted clients and the pruning store."""
import argparse
from pathlib import Path
from zipfile import ZipFile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("apk", type=Path)
args = parser.parse_args()
with ZipFile(args.apk) as package:
    dex = [package.read(name) for name in package.namelist() if name.startswith("classes") and name.endswith(".dex")]
    if not dex:
        raise SystemExit("APK contains no DEX files")
    if not any(b"Lcom/thumble/android/PendingBuildRecovery;" in data for data in dex):
        raise SystemExit("Expected read-only recovery implementation is missing (use an unminified APK)")
    retired = [
        "Lcom/thumble/android/BuilderArtifactFetcher;",
        "Lcom/thumble/android/BuilderArtifactShare;",
        "Lcom/thumble/android/SharedBuildLinkActivity;",
        "Lcom/thumble/android/PendingSharedBuildStore;",
        "Lcom/thumble/android/ArtifactAdoptionMetadata;",
        "Lcom/thumble/android/SharedBuildPracticePreview;",
        "ThumbleShare ", "profile_artifact_adoption_begin", "profile_artifact_adoption_chunk",
        "profile_artifact_adoption_commit", "beginSharedBuildPreview", "adoptSharedBuild",
    ]
    for value in retired:
        if any(value.encode() in data for data in dex):
            raise SystemExit(f"Retired implementation still ships: {value}")
    manifest = package.read("AndroidManifest.xml")
    for encoding in ("utf-8", "utf-16le"):
        if "SharedBuildLinkActivity".encode(encoding) in manifest:
            raise SystemExit("Retired link activity still appears in the packaged manifest")
print("Android APK: read-only recovery present; hosted pickup/adoption and pruning implementation absent")
