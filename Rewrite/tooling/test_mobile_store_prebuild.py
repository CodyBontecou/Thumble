"""Pure metadata regressions for check-mobile-store-prebuild.py; no native builds."""
import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("store_audit", Path(__file__).with_name("check-mobile-store-prebuild.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class StoreAuditTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        for directory in ("ios/Thumble", "ios/Thumble.xcodeproj", "android/app/src/main"):
            (self.root / directory).mkdir(parents=True)
        self.info = {"CFBundleDisplayName": "Thumble", "CFBundleShortVersionString": "1.0.0",
                     "CFBundleVersion": "4", "NSCameraUsageDescription": "Scan an invitation",
                     "NSLocalNetworkUsageDescription": "Connect to your receiver"}
        self.write_plist("ios/Thumble/Info.plist", self.info)
        self.privacy = {"NSPrivacyTracking": False, "NSPrivacyAccessedAPITypes": [
            {"NSPrivacyAccessedAPIType": k, "NSPrivacyAccessedAPITypeReasons": [v]}
            for k, v in audit.REASONS.items()]}
        self.write_plist("ios/Thumble/PrivacyInfo.xcprivacy", self.privacy)
        (self.root / "ios/Thumble.xcodeproj/project.pbxproj").write_text(
            ('PRODUCT_BUNDLE_IDENTIFIER = "com.codybontecou.PocketPad.iOS";\n'
             'TARGETED_DEVICE_FAMILY = "1";\n') * 2)
        self.gradle = ('applicationId \'com.thumble.android\'\nversionCode 4\nversionName "1.0.0"\n'
                       '        release {\n            // Signing intentionally external\n        }\n')
        (self.root / "android/app/build.gradle").write_text(self.gradle)
        permissions = ''.join(f'<uses-permission android:name="{name}" tools:node="remove"/>'
                              for name in audit.BLOCKED)
        self.manifest = ('<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
                         'xmlns:tools="http://schemas.android.com/tools">' + permissions +
                         '<application android:allowBackup="false"/></manifest>')
        (self.root / "android/app/src/main/AndroidManifest.xml").write_text(self.manifest)

    def tearDown(self):
        self.temporary.cleanup()

    def write_plist(self, relative, value):
        (self.root / relative).write_bytes(plistlib.dumps(value))

    def test_valid_fixture_is_prebuild_only_and_never_distribution_acceptance(self):
        result = audit.audit(self.root, "1.0.0", "4")
        self.assertTrue(result["ok"])
        self.assertFalse(result["distributionAccepted"])
        self.assertTrue(result["finalArchiveAndBundleReviewRequired"])

    def test_missing_privacy_reason_and_release_debug_key_fail(self):
        self.privacy["NSPrivacyAccessedAPITypes"] = []
        self.write_plist("ios/Thumble/PrivacyInfo.xcprivacy", self.privacy)
        (self.root / "android/app/build.gradle").write_text(self.gradle.replace(
            "// Signing intentionally external", "signingConfig signingConfigs.debug"))
        result = audit.audit(self.root, "1.0.0", "4")
        self.assertFalse(result["ok"])
        self.assertFalse(result["checks"]["app_privacy_reasons"])
        self.assertFalse(result["checks"]["no_release_debug_signing"])

    def test_build_number_prefix_cannot_pass_exact_store_version_check(self):
        (self.root / "android/app/build.gradle").write_text(self.gradle.replace("versionCode 4", "versionCode 40"))
        self.assertFalse(audit.audit(self.root, "1.0.0", "4")["checks"]["android_version"])

    def test_stale_version_or_permission_removal_fail(self):
        (self.root / "android/app/src/main/AndroidManifest.xml").write_text(
            self.manifest.replace('tools:node="remove"', 'tools:node="merge"'))
        result = audit.audit(self.root, "1.0.1", "5")
        self.assertFalse(result["ok"])
        self.assertFalse(result["checks"]["ios_version"])
        self.assertFalse(result["checks"]["source_permission_removals"])

    def test_merged_permissions_require_exact_release_set_and_optional_camera(self):
        names = ["android.permission.INTERNET", "android.permission.CAMERA", "android.permission.VIBRATE",
                 "com.thumble.android.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"]
        data = ('<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="com.thumble.android">' +
                ''.join(f'<uses-permission android:name="{name}"/>' for name in names) +
                '<uses-feature android:name="android.hardware.camera" android:required="false"/>' +
                '<application/></manifest>')
        merged = self.root / "merged.xml"
        merged.write_text(data)
        self.assertTrue(audit.audit(self.root, "1.0.0", "4", merged)["ok"])
        merged.write_text(data.replace('<application/>', '<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"/><application/>'))
        self.assertFalse(audit.audit(self.root, "1.0.0", "4", merged)["checks"]["merged_permissions"])

    def test_linked_and_oversized_input_are_refused_without_reading_payload(self):
        path = self.root / "oversized"
        with path.open("wb") as target:
            target.truncate(2_097_153)
        with self.assertRaises(ValueError):
            audit.read(path)
        link = self.root / "linked"
        link.symlink_to(path)
        with self.assertRaises(ValueError):
            audit.read(link)


if __name__ == "__main__":
    unittest.main()
