#!/usr/bin/env python3
"""Read-only store metadata audit. Does not build, sign, install, export or upload.
Generated prebuild checks are intentionally separate from final archive/AAB review.
"""
import argparse
import hashlib
import json
import plistlib
import re
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

ANDROID = "{http://schemas.android.com/apk/res/android}"
TOOLS = "{http://schemas.android.com/tools}"
BLOCKED = {"android.permission." + name for name in (
    "READ_EXTERNAL_STORAGE", "WRITE_EXTERNAL_STORAGE", "SYSTEM_ALERT_WINDOW")}
REASONS = {"NSPrivacyAccessedAPICategoryUserDefaults": "CA92.1",
           "NSPrivacyAccessedAPICategorySystemBootTime": "35F9.1"}


def read(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 2_097_152:
        raise ValueError("store_review_file_invalid")
    return path.read_bytes()


def audit(root, version, build, merged=None):
    checks, hashes = {}, {}

    def blob(relative):
        data = read(root / relative)
        hashes[relative] = hashlib.sha256(data).hexdigest()
        return data

    info = plistlib.loads(blob("ios/Thumble/Info.plist"))
    privacy = plistlib.loads(blob("ios/Thumble/PrivacyInfo.xcprivacy"))
    project = blob("ios/Thumble.xcodeproj/project.pbxproj").decode("utf8")
    gradle = blob("android/app/build.gradle").decode("utf8")
    manifest = ET.fromstring(blob("android/app/src/main/AndroidManifest.xml"))
    checks["ios_identity"] = (info.get("CFBundleDisplayName") == "Thumble" and
        len(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER = [\"]?com\.codybontecou\.PocketPad\.iOS[\"]?;', project)) == 2)
    checks["ios_version"] = (info.get("CFBundleShortVersionString") == version and
                             info.get("CFBundleVersion") == build)
    checks["iphone_only"] = project.count('TARGETED_DEVICE_FAMILY = "1";') == 2
    checks["purpose_strings"] = all(isinstance(info.get(k), str) and info[k].strip()
        for k in ("NSCameraUsageDescription", "NSLocalNetworkUsageDescription"))
    reasons = {entry.get("NSPrivacyAccessedAPIType"): entry.get("NSPrivacyAccessedAPITypeReasons", [])
               for entry in privacy.get("NSPrivacyAccessedAPITypes", [])}
    checks["app_privacy_reasons"] = all(reason in reasons.get(category, [])
                                             for category, reason in REASONS.items())
    checks["tracking_disabled"] = privacy.get("NSPrivacyTracking") is False
    checks["android_identity"] = bool(re.search(r'applicationId [\"\']com\.thumble\.android[\"\']', gradle))
    checks["android_version"] = (bool(re.search(rf"^\s*versionCode\s+{re.escape(build)}\s*$", gradle, re.M)) and
                                  bool(re.search(rf'^\s*versionName "{re.escape(version)}"\s*$', gradle, re.M)))
    checks["android_no_backup"] = manifest.find("application").get(ANDROID + "allowBackup") == "false"
    permissions = manifest.findall("uses-permission")
    checks["source_permission_removals"] = all(any(
        p.get(ANDROID + "name") == name and p.get(TOOLS + "node") == "remove"
        for p in permissions) for name in BLOCKED)
    release = re.search(r"^        release \{(.*?)^        \}", gradle, re.M | re.S)
    checks["no_release_debug_signing"] = bool(release and "signingConfigs.debug" not in release[1])
    checks["qa_excluded"] = ("nativeQa" not in gradle and "NativeQATests" not in project and
                              not (root / "android/app/src/androidTest").exists())
    if merged:
        merged_data = read(merged)
        hashes["mergedReleaseManifest"] = hashlib.sha256(merged_data).hexdigest()
        actual = ET.fromstring(merged_data)
        names = {p.get(ANDROID + "name") for p in actual.findall("uses-permission")}
        expected = {"android.permission.INTERNET", "android.permission.CAMERA", "android.permission.VIBRATE",
                    "com.thumble.android.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"}
        checks["merged_permissions"] = names == expected
        checks["merged_release_not_debuggable"] = actual.find("application").get(ANDROID + "debuggable", "false") == "false"
        checks["camera_optional"] = any(feature.get(ANDROID + "name") == "android.hardware.camera" and
            feature.get(ANDROID + "required") == "false" for feature in actual.findall("uses-feature"))
        checks["merged_release_identity"] = actual.get("package") == "com.thumble.android"
        checks["merged_no_instrumentation"] = actual.find("instrumentation") is None
    return {"kind": "mobile-store-prebuild-review", "ok": all(checks.values()),
            "checks": checks, "sha256": hashes,
            "distributionAccepted": False, "finalArchiveAndBundleReviewRequired": True,
            "privacyLabelsAndNativeDependencyNoticesReviewRequired": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mobile-root", required=True, type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--merged-android-manifest", type=Path)
    args = parser.parse_args()
    if (not args.mobile_root.is_absolute() or
        not re.fullmatch(r"(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})\.(?:0|[1-9][0-9]{0,2})", args.version) or
        not re.fullmatch(r"[1-9][0-9]{0,3}", args.build) or
        (args.merged_android_manifest and not args.merged_android_manifest.is_absolute())):
        raise ValueError("store_review_arguments_invalid")
    result = audit(args.mobile_root, args.version, args.build, args.merged_android_manifest)
    print(json.dumps(result, separators=(",", ":")))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, AttributeError, ET.ParseError, plistlib.InvalidFileException):
        print(json.dumps({"ok": False, "error": "store_review_metadata_invalid"}))
        sys.exit(1)
