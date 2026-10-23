"""Synthetic artifact metadata and hostile-container tests. Never build, sign or install."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('artifact', Path(__file__).with_name('check-mobile-store-artifact.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def integer(value):
    out = bytearray()
    while value > 127:
        out.append((value & 127) | 128)
        value >>= 7
    out.append(value)
    return bytes(out)


def field(key, value):
    return integer(key * 8 + (0 if isinstance(value, int) else 2)) + (integer(value) if isinstance(value, int) else integer(len(value)) + value)


def element(tag, attrs=(), children=()):
    data = field(3, tag.encode())
    for namespace, key, value, compiled in attrs:
        attribute = field(1, namespace.encode()) + field(2, key.encode()) + field(3, value.encode())
        if compiled is not None:
            attribute += field(6, compiled)
        data += field(4, attribute)
    for child in children:
        data += field(5, child)
    return field(1, data)


def attr(key, value, compiled=None, namespace=module.ANDROID):
    return namespace, key, value, compiled


def android(debug='false', compiled_debug=None, permission='android.permission.CAMERA', target='36', instrumentation=False):
    children = [element('uses-sdk', [attr('minSdkVersion', '26'), attr('targetSdkVersion', target)])]
    for value in ['android.permission.INTERNET', 'android.permission.VIBRATE', permission, 'com.thumble.android.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION']:
        children.append(element('uses-permission', [attr('name', value)]))
    children.append(element('uses-feature', [attr('name', 'android.hardware.camera'), attr('required', 'false')]))
    children.append(element('application', [attr('debuggable', debug, compiled_debug), attr('allowBackup', 'false'), attr('icon', '@mipmap/ic_launcher', field(1, field(2, 123)))]))
    if instrumentation:
        children.append(element('instrumentation'))
    return element('manifest', [attr('package', 'com.thumble.android', namespace=''), attr('versionCode', '4'), attr('versionName', '1.0.0')], children)


class ArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.archive = self.root / 'Thumble.xcarchive'
        self.app = self.archive / 'Products/Applications/Thumble.app'
        self.app.mkdir(parents=True)
        self.info = {'CFBundleExecutable': 'Thumble', 'CFBundleIdentifier': 'com.codybontecou.PocketPad.iOS', 'CFBundleVersion': '4', 'CFBundleShortVersionString': '1.0.0', 'UIDeviceFamily': [1], 'MinimumOSVersion': '15.1', 'NSCameraUsageDescription': 'Scan', 'NSLocalNetworkUsageDescription': 'Pair'}
        self.write('Info.plist', {'ApplicationProperties': {'ApplicationPath': 'Applications/Thumble.app'}})
        self.write('Products/Applications/Thumble.app/Info.plist', self.info)
        self.privacy = {'NSPrivacyTracking': False, 'NSPrivacyAccessedAPITypes': [{'NSPrivacyAccessedAPIType': k, 'NSPrivacyAccessedAPITypeReasons': [v]} for k, v in module.REASONS.items()]}
        self.write('Products/Applications/Thumble.app/PrivacyInfo.xcprivacy', self.privacy)
        (self.app / 'Thumble').write_bytes(b'synthetic executable placeholder')
        (self.app / 'Assets.car').write_bytes(b'synthetic icon catalog')
        (self.app / 'THIRD-PARTY-NOTICES.txt').write_text('Synthetic fixture license text')
        self.bundle = self.root / 'Thumble.aab'

    def tearDown(self):
        self.temp.cleanup()

    def write(self, path, data):
        destination = self.archive / path
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(plistlib.dumps(data))

    def aab(self, manifest=None, extras=()):
        with zipfile.ZipFile(self.bundle, 'w', compression=zipfile.ZIP_DEFLATED) as out:
            out.writestr('base/manifest/AndroidManifest.xml', android() if manifest is None else manifest)
            out.writestr('base/assets/thumble-qr-notices.txt', 'Synthetic fixture license')
            out.writestr('base/dex/classes.dex', b'synthetic dex placeholder')
            for path, data in extras:
                out.writestr(path, data)

    def audit(self, platform):
        return module.audit(self.archive if platform == 'ios' else self.bundle, platform, '1.0.0', '4')

    def test_both_metadata_candidates_pass_without_claiming_signing_or_distribution(self):
        self.aab()
        for platform in ['ios', 'android']:
            result = self.audit(platform)
            self.assertTrue(result['ok'])
            self.assertFalse(result['distributionAccepted'])
            self.assertEqual(result['signingStatus'], 'unverified')
            self.assertIn('complete-third-party-notices', result['unverifiedChecks'])
            self.assertEqual(len(result['inventory']['treeSHA256']), 64)
        self.assertEqual(len(self.audit('android')['inventory']['artifactSHA256']), 64)

    def test_ios_wrong_identity_version_families_qa_and_missing_notices_fail(self):
        for key, value, check in [('CFBundleIdentifier', 'example.other', 'identity'), ('CFBundleVersion', '40', 'version'), ('UIDeviceFamily', [1, 2], 'iphone_only')]:
            changed = dict(self.info, **{key: value})
            self.write('Products/Applications/Thumble.app/Info.plist', changed)
            self.assertFalse(self.audit('ios')['checks'][check])
        self.write('Products/Applications/Thumble.app/Info.plist', self.info)
        (self.app / 'NativeQATests.xctest').mkdir()
        (self.app / 'NativeQATests.xctest/test').write_text('test')
        self.assertFalse(self.audit('ios')['checks']['qa_bundles_excluded'])
        (self.app / 'THIRD-PARTY-NOTICES.txt').unlink()
        self.assertFalse(self.audit('ios')['checks']['notice_files_present'])

    def test_privacy_reasons_require_real_arrays_and_all_bundled_privacy_is_parseable(self):
        self.privacy['NSPrivacyAccessedAPITypes'][0]['NSPrivacyAccessedAPITypeReasons'] = 'CA92.1'
        self.write('Products/Applications/Thumble.app/PrivacyInfo.xcprivacy', self.privacy)
        with self.assertRaises(module.Invalid): self.audit('ios')
        self.write('Products/Applications/Thumble.app/PrivacyInfo.xcprivacy', {'NSPrivacyTracking': False})
        self.assertFalse(self.audit('ios')['checks']['app_privacy_reasons'])
        (self.app / 'Framework.xcprivacy').write_bytes(b'not a plist')
        with self.assertRaises(plistlib.InvalidFileException): self.audit('ios')

    def test_compiled_boolean_overrides_misleading_raw_string_and_target_is_required(self):
        self.aab(android(compiled_debug=field(7, field(8, 1))))
        self.assertFalse(self.audit('android')['checks']['not_debuggable'])
        self.aab(android(debug='true', compiled_debug=field(7, field(8, 0))))
        self.assertTrue(self.audit('android')['checks']['not_debuggable'])
        self.aab(android(target='unresolved'))
        self.assertFalse(self.audit('android')['checks']['sdk_versions_declared'])

    def test_android_permission_qa_unknown_format_and_critical_references_fail_closed(self):
        self.aab(android(permission='android.permission.RECORD_AUDIO', instrumentation=True))
        result = self.audit('android')
        self.assertFalse(result['checks']['permissions'])
        self.assertFalse(result['checks']['qa_excluded'])
        for manifest in [b'<manifest/>', b'\x0a\x80', android(compiled_debug=field(1, field(2, 1)))]:
            self.aab(manifest)
            with self.assertRaises(module.Invalid): self.audit('android')
        self.aab(extras=[('feature/manifest/AndroidManifest.xml', android())])
        with self.assertRaises(module.Invalid): self.audit('android')

    def test_duplicate_protobuf_attributes_and_ambiguous_oneof_rejected(self):
        data = element('manifest', [attr('package', 'x', namespace=''), attr('package', 'y', namespace='')])
        with self.assertRaises(module.Invalid): module.manifest_node(data)
        with self.assertRaises(module.Invalid): module.manifest_node(field(1, field(3, b'x')) + field(2, b'text'))
        with self.assertRaises(module.Invalid): module.fields(b'\x80' * 12)
        node = element('x')
        for _ in range(34): node = element('x', children=[node])
        with self.assertRaises(module.Invalid): module.manifest_node(node)

    def test_unsafe_zip_names_duplicates_symlinks_and_size_limits_rejected(self):
        for path in ['../outside', '/absolute', 'base\\escape', 'base/./x', 'BASE/manifest/androidmanifest.xml']:
            self.aab(extras=[(path, b'x')])
            with self.assertRaises(module.Invalid): self.audit('android')
        self.aab(extras=[('base/file', b'x'), ('base/file/child', b'y')])
        with self.assertRaises(module.Invalid): self.audit('android')
        self.aab()
        with zipfile.ZipFile(self.bundle, 'a') as out:
            entry = zipfile.ZipInfo('base/link')
            entry.external_attr = 0o120777 << 16
            out.writestr(entry, '/private/secret')
        with self.assertRaises(module.Invalid): self.audit('android')
        self.aab()
        with patch.object(module, 'MAX_TOTAL', 10):
            with self.assertRaises(module.Invalid): self.audit('android')

    def test_filesystem_symlink_hardlink_and_entry_limit_rejected(self):
        link = self.app / 'linked'
        link.symlink_to(self.app / 'Info.plist')
        with self.assertRaises(module.Invalid): self.audit('ios')
        link.unlink()
        os.link(self.app / 'Info.plist', link)
        with self.assertRaises(module.Invalid): self.audit('ios')
        link.unlink()
        with patch.object(module, 'MAX_ENTRIES', 2):
            with self.assertRaises(module.Invalid): self.audit('ios')

    def test_empty_qa_directories_cannot_escape_visible_bundle_checks(self):
        (self.app / 'NativeQATests.xctest').mkdir()
        self.aab(extras=[('base/assets/nativeQa/', b'')])
        for platform, check in [('ios', 'qa_bundles_excluded'), ('android', 'qa_excluded')]:
            with self.subTest(platform=platform):
                self.assertFalse(self.audit(platform)['checks'][check])

    def test_duplicate_plist_keys_fail_instead_of_silently_choosing_one(self):
        data = b'<?xml version="1.0"?><plist version="1.0"><dict><key>NSPrivacyTracking</key><true/><key>NSPrivacyTracking</key><false/></dict></plist>'
        with self.assertRaises(module.Invalid): module.privacy_ok(data)
        with self.assertRaises(module.Invalid): module.UniquePlistDict([('key', 1), ('key', 2)])

    def test_cli_errors_are_fixed_and_do_not_echo_private_paths(self):
        missing = self.root / 'private-credential-name.aab'
        result = subprocess.run([sys.executable, str(Path(module.__file__)), '--platform', 'android', '--artifact', str(missing), '--version', '1.0.0', '--build', '4'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(str(missing), result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['error'], 'store_artifact_invalid_or_unsupported')
        self.assertEqual(result.stderr, '')
        result = subprocess.run([sys.executable, str(Path(module.__file__)), '--platform', 'private-token-value'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn('private-token-value', result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')


if __name__ == '__main__': unittest.main()
