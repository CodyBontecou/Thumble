#!/usr/bin/env python3
"""Prepare an isolated development artifact from an already-authorized lab bundle.

Never launches code, provisions accounts, installs profiles or creates HID devices.
The existing lab bundle remains untouched. This is not distribution signing.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys


def run(argv):
    result = subprocess.run([str(a) for a in argv], capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"{Path(argv[0]).name} failed")
    return result.stdout


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regular(path, limit):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= limit:
        raise RuntimeError("invalid bounded source artifact")


def prepare(package, authorized, destination):
    spec = importlib.util.spec_from_file_location("hid_signing", Path(__file__).with_name("verify-hid-signing.py"))
    hid = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hid)
    bundle_id = "com.codybontecou.PocketPadMac"
    hid.verify_artifact(authorized, bundle_id=bundle_id, distribution="development")
    info = plistlib.loads((authorized / "Contents/Info.plist").read_bytes())
    old_main = authorized / "Contents/MacOS" / info["CFBundleExecutable"]
    signature = hid.inspect_signature(old_main, arch="arm64")
    identity = hashlib.sha1(signature["certificate"]).hexdigest().upper()
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"]).decode()
    if identity not in identities:
        raise RuntimeError("authorized development signing identity unavailable")
    profile = authorized / "Contents/embedded.provisionprofile"
    decoded_profile = hid.decode_profile(profile)
    receiver = package / "thumble-rewrite-receiver"
    capture = package / "thumble-wow-capture-macos"
    for source in (receiver, capture):
        regular(source, 128 * 1024 * 1024)
    if not destination.is_absolute() or destination.exists() or destination.is_symlink():
        raise RuntimeError("destination must be a new absolute app bundle path")
    if destination.suffix != ".app" or destination.resolve().is_relative_to(authorized.resolve()):
        raise RuntimeError("destination must be isolated from authorized bundle")
    contents = destination / "Contents"
    macos = contents / "MacOS"
    helpers = contents / "Helpers"
    macos.mkdir(parents=True)
    helpers.mkdir()
    main = macos / receiver.name
    nested = helpers / capture.name
    shutil.copyfile(receiver, main)
    shutil.copyfile(capture, nested)
    main.chmod(0o755)
    nested.chmod(0o755)
    shutil.copyfile(profile, contents / "embedded.provisionprofile")
    bundle_info = {
        "CFBundleIdentifier": bundle_id,
        "CFBundleExecutable": receiver.name,
        "CFBundleName": "Thumble Rewrite Development Receiver",
        "CFBundleDisplayName": "Thumble Rewrite Development Receiver",
        "CFBundlePackageType": "APPL",
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleVersion": "1",
        "CFBundleShortVersionString": "0.1.0",
        "LSBackgroundOnly": True,
        "LSMinimumSystemVersion": "14.0",
        "NSLocalNetworkUsageDescription": "Receive controller input from paired phones on the local network.",
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(bundle_info))
    entitlements = destination.parent / (destination.stem + ".entitlements.plist")
    if entitlements.exists() or entitlements.is_symlink():
        raise RuntimeError("entitlement sidecar already exists")
    entitlements.write_bytes(plistlib.dumps(signature["entitlements"]))
    # Nested capture has no restricted HID entitlements. Do not sign the Bun CLI
    # with invented hardened-runtime/JIT entitlements: it remains a sibling.
    run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity, nested])
    run(["codesign", "--force", "--options", "runtime", "--timestamp=none", "--sign", identity,
         "--entitlements", entitlements, destination])
    hid.verify_artifact(destination, bundle_id=bundle_id, distribution="development")
    manifest = {
        "version": 1, "distribution": "development", "teamId": hid.TEAM_ID,
        "bundleId": bundle_id, "signerCertificateSha256": hashlib.sha256(signature["certificate"]).hexdigest(),
        "profileSha256": sha(profile), "profileExpires": decoded_profile["ExpirationDate"].isoformat() + "Z",
        "hidAuthorized": True, "launched": False, "physicalOutputExecuted": False,
        "captureExecuted": False, "distributionAcceptance": False,
        "files": {str(path.relative_to(destination)): {"sha256": sha(path), "bytes": path.stat().st_size}
                  for path in sorted(destination.rglob("*")) if path.is_file()},
        "unsignedSourceHashes": {receiver.name: sha(receiver), capture.name: sha(capture)},
    }
    manifest_path = destination.parent / (destination.stem + ".manifest.json")
    if manifest_path.exists() or manifest_path.is_symlink():
        raise RuntimeError("manifest sidecar already exists")
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"status": "development-signing-verified", "manifestSha256": sha(manifest_path),
                      "physicalOutputExecuted": False, "captureExecuted": False}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--authorized-bundle", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.package, args.authorized_bundle, args.destination)
    except Exception as error:  # Signing/profile tool failures stay sanitized.
        print(f"Development bundle preparation failed: {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
