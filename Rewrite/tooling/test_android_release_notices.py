import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

SPEC = importlib.util.spec_from_file_location('notices', Path(__file__).with_name('android-release-notices.py'))
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class NoticeInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.build = self.root / 'apps/mobile/android/app/build'
        self.package = self.root / 'node_modules/.bun/example@1.2.3/node_modules/example'
        self.package.mkdir(parents=True)
        (self.package / 'package.json').write_text(json.dumps({'name': 'example', 'version': '1.2.3', 'license': 'MIT'}))
        (self.package / 'LICENSE').write_text('Actual pinned license bytes\n')
        (self.package / 'index.js').write_text('module.exports=1;')
        (self.root / 'bun.lock').write_text('pinned-lock')
        self.map = self.root / 'release.map'
        self.map.write_text(json.dumps({'version': 3, 'sources': ['/node_modules/.bun/example@1.2.3/node_modules/example/index.js'], 'mappings': 'AAAA'}))
        self.bundle = self.build / 'generated/assets/react/release/index.android.bundle'
        self.bundle.parent.mkdir(parents=True)
        self.bundle.write_bytes(b'synthetic-hermes')
        self.lib = b'elf-unstripped'
        self.stripped = b'elf-stripped'
        for stage, task, value in [('merged_native_libs', 'mergeReleaseNativeLibs', self.lib), ('stripped_native_libs', 'stripReleaseDebugSymbols', self.stripped)]:
            p = self.build / f'intermediates/{stage}/release/{task}/out/lib/arm64-v8a/libsample.so'
            p.parent.mkdir(parents=True)
            p.write_bytes(value)
        self.cache = self.root / 'cache'
        self.aar = self.cache / 'org.example/sample/2.0/hash/sample-2.0-release.aar'
        self.aar.parent.mkdir(parents=True)
        with zipfile.ZipFile(self.aar, 'w') as z:
            z.writestr('jni/arm64-v8a/libsample.so', self.lib)
            z.writestr('META-INF/NOTICE', 'Actual AAR notice')
        self.graph = self.root / 'graph.json'
        self.graph.write_text(json.dumps({'schema': 1, 'configuration': 'releaseRuntimeClasspath', 'components': [{'key': 'm:org.example:sample:2.0'}], 'archives': [{'component': 'm:org.example:sample:2.0', 'file': str(self.aar)}]}))
        self.aab = self.root / 'release.aab'
        self.write_aab()

    def write_aab(self, native=None, bundle=None):
        with zipfile.ZipFile(self.aab, 'w') as z:
            z.writestr('base/assets/index.android.bundle', bundle or self.bundle.read_bytes())
            z.writestr('base/lib/arm64-v8a/libsample.so', native or self.stripped)
            z.writestr('base/root/META-INF/annotation/LICENSE.txt', 'Nested metadata license')
            z.writestr('base/root/okhttp3/internal/publicsuffix/NOTICE', 'PSL attribution')

    def audit(self):
        return AUDIT.inventory(argparse.Namespace(root=str(self.root), aab=self.aab, source_map=self.map,
                               graph=self.graph, maven_cache=self.cache))

    def test_actual_graph_map_native_chain_and_all_zip_notice_paths(self):
        result, texts = self.audit()
        self.assertFalse(result['complete'])
        self.assertFalse(result['distributionAccepted'])
        self.assertEqual(result['javascript']['packages'][0]['component'], 'example@1.2.3')
        native = result['nativeLibraries'][0]
        self.assertTrue(native['strippedMatchesPackage'])
        self.assertEqual(native['exactAAROwners'][0]['component'], 'm:org.example:sample:2.0')
        self.assertEqual(len(result['packagedNotices']), 2)
        self.assertEqual(len(texts.values), 4)
        self.assertNotIn(str(self.root), json.dumps(result))

    def test_package_license_field_is_not_text_coverage(self):
        (self.package / 'LICENSE').unlink()
        result, _ = self.audit()
        self.assertEqual(result['javascript']['packages'][0]['texts'], [])
        self.assertFalse(result['complete'])

    def test_unreferenced_source_not_counted(self):
        data = json.loads(self.map.read_text())
        data['sources'].append('/node_modules/not-installed/secret.js')
        self.map.write_text(json.dumps(data))
        result, _ = self.audit()
        self.assertEqual(result['javascript']['referencedSourceCount'], 1)
        self.assertEqual(result['javascript']['sourceCount'], 2)

    def test_virtual_source_is_explicit_unresolved(self):
        self.map.write_text(json.dumps({'version': 3, 'sources': ['\x00polyfill:external-require'], 'mappings': 'AAAA'}))
        result, _ = self.audit()
        self.assertEqual(result['javascript']['unresolved'][0]['reason'], 'generated_origin_unresolved')

    def test_native_or_hermes_package_mismatch_fails(self):
        self.write_aab(native=b'wrong')
        with self.assertRaisesRegex(ValueError, 'native_package_mismatch'):
            self.audit()
        self.write_aab(bundle=b'wrong')
        with self.assertRaisesRegex(ValueError, 'hermes_bundle_mismatch'):
            self.audit()

    def test_debug_aar_not_inferred_from_matching_version_cache(self):
        debug = self.aar.with_name('sample-2.0-debug.aar')
        with zipfile.ZipFile(debug, 'w') as z:
            z.writestr('META-INF/NOTICE', 'Debug only text')
        result, texts = self.audit()
        self.assertEqual(len(result['releaseRuntimeClasspath'][0]['archives']), 1)
        self.assertNotIn(AUDIT.sha(b'Debug only text'), texts.values)

    def test_vlq_bounds_and_duplicate_json_reject(self):
        for mapping in ('AA', 'ACAA', 'AAAA!', 'ggggggggggA'):
            with self.assertRaises(ValueError):
                AUDIT.referenced_sources(mapping, 1)
        self.map.write_text('{"version":3,"version":3}')
        with self.assertRaisesRegex(ValueError, 'duplicate_json_key'):
            self.audit()

    def test_traversal_and_symlink_sources_reject(self):
        self.map.write_text(json.dumps({'version': 3, 'sources': ['/../private.js'], 'mappings': 'AAAA'}))
        with self.assertRaisesRegex(ValueError, 'invalid_member_name'):
            self.audit()
        path = self.root / 'link'
        path.symlink_to(self.root / 'bun.lock')
        with self.assertRaises(OSError):
            AUDIT.read(path)

    def test_audited_upstream_text_requires_exact_package_json_commit_and_bytes(self):
        result, texts = self.audit()
        package = result['javascript']['packages'][0]
        commit = 'a' * 40
        value = b'Previously audited exact upstream text'
        bundle = self.root / 'upstream.txt'
        bundle.write_bytes(value)
        proof = self.root / 'upstream.json'
        entry = {'sha256': AUDIT.sha(value), 'offset': 0, 'byteCount': len(value), 'origins': [{
            'kind': 'npm-release-gitHead-upstream-license', 'component': 'example', 'version': '1.2.3',
            'packageJsonSHA256': package['packageJsonSHA256'], 'gitHead': commit,
            'url': 'https://raw.githubusercontent.com/owner/repo/' + commit + '/LICENSE'}]}
        data = {'schemaVersion': 1, 'bundleSHA256': AUDIT.sha(value), 'bundleByteCount': len(value), 'selectedTexts': [entry]}
        proof.write_text(json.dumps(data))
        AUDIT.upstream_supplement(result['javascript'], proof, bundle, texts)
        self.assertEqual(package['upstreamTexts'][0]['sha256'], AUDIT.sha(value))
        entry['origins'][0]['packageJsonSHA256'] = '0' * 64
        proof.write_text(json.dumps(data))
        with self.assertRaisesRegex(ValueError, 'upstream_component_mismatch'):
            AUDIT.upstream_supplement(result['javascript'], proof, bundle, texts)
        bundle.write_bytes(b'wrong')
        with self.assertRaisesRegex(ValueError, 'upstream_bundle_mismatch'):
            AUDIT.upstream_supplement(result['javascript'], proof, bundle, texts)

    def test_corrupt_zip_and_duplicate_file_reject(self):
        self.aab.write_bytes(b'notzip')
        with self.assertRaises(zipfile.BadZipFile):
            self.audit()
        with zipfile.ZipFile(self.aab, 'w') as z:
            z.writestr('a/NOTICE', 'one')
            z.writestr('a/notice', 'two')
        with self.assertRaisesRegex(ValueError, 'zip_duplicate_member'):
            list(AUDIT.members(self.aab))


if __name__ == '__main__':
    unittest.main()
