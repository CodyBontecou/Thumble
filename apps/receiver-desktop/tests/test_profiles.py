from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest

from thumble_receiver.profiles import ProfileStore, ProfileError, cloud_id, validate_profile, load_json


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.store = ProfileStore(self.temporary.name)
        self.profile = self.store.builtins[0]
        self.source = dict(service='https://thumble.example/v1', accountId='a' * 64,
                           profileId=self.profile['id'], revision=1)

    def test_resource_matches_the_mac_and_starters_survive_upgrade(self):
        repo = Path(__file__).resolve().parents[3]
        self.assertEqual(self.store.builtins, json.loads((repo / 'apps/receiver/Resources/BuiltInProfiles.json').read_bytes()))
        self.assertEqual([item['id'] for item in self.store.summary()['profiles']], ['xbox-standard', 'consoleport-standard'])
        self.store.select('consoleport-standard', 1, 0)
        data = self.store.read()
        data['profiles'] = data['profiles'][:1]
        data['profiles'][0]['profile']['name'] = 'My Xbox'
        (self.store.directory / 'store.json').write_text(json.dumps(data))
        loaded = self.store.read()
        self.assertEqual(loaded['profiles'][0]['profile']['name'], 'My Xbox')
        self.assertEqual(loaded['active']['profile']['theme'], 'consoleport')
        self.assertEqual(len(loaded['profiles']), 2)

    def test_profile_validation_rejects_unsafe_and_ambiguous_fields(self):
        variants = []
        for key, value in [('schemaVersion', True), ('id', '../other'), ('name', '😀' * 41),
                           ('theme', 'code'), ('script', 'bad'), ('controls', []),
                           ('modifiers', {'shift': 'keyboard'}), ('mappings', [])]:
            variants.append({**deepcopy(self.profile), key: value})
        for key, value in [('type', 'macro'), ('label', ''), ('id', []), ('icon', 'https://example.com'),
                           ('color', '#fff'), ('layers', {'SHIFT-': {'label': 'Okay', 'script': 'bad'}}),
                           ('frame', {'x': 0.9, 'y': 0, 'width': 0.2, 'height': 0.1})]:
            value_profile = deepcopy(self.profile)
            value_profile['controls'][0][key] = value
            variants.append(value_profile)
        for mapping in ({'outputs': ['lx', 'rx']}, {'invertX': 1}, {'deadzone': float('nan')},
                        {'sensitivity': 4}, {'controlId': 'missing'}):
            value_profile = deepcopy(self.profile)
            value_profile['mappings'][0].update(mapping)
            variants.append(value_profile)
        duplicate = deepcopy(self.profile)
        duplicate['controls'].append(deepcopy(duplicate['controls'][0]))
        duplicate['mappings'].append(deepcopy(duplicate['mappings'][0]))
        variants.append(duplicate)
        for profile in variants:
            with self.subTest(profile=profile), self.assertRaises(ValueError):
                validate_profile(profile)

    def test_saved_store_rejects_duplicates_invalid_active_and_oversize(self):
        for data in (dict(version=True, profiles=[]), dict(version=1, profiles=[{}, {}]),
                     dict(version=1, profiles=[], active={'revision': True}),
                     dict(version=1, profiles=[dict(profile=self.profile, revision=1)] * 2)):
            (self.store.directory / 'store.json').write_text(json.dumps(data))
            with self.assertRaises(ValueError):
                self.store.read()
        (self.store.directory / 'store.json').write_bytes(b' ' * (8 * 1024 * 1024 + 1))
        with self.assertRaises(ValueError):
            self.store.read()
        with self.assertRaises(ValueError):
            load_json('{"version":1,"version":2}')

    def test_selection_conflicts_are_atomic_and_active_is_a_snapshot(self):
        summary, active = self.store.select('xbox-standard', 1, 0)
        self.assertEqual(summary['activationRevision'], 1)
        before = (self.store.directory / 'store.json').read_bytes()
        for args in (('missing', 1, 1), ('xbox-standard', 2, 1), ('xbox-standard', 1, 0)):
            with self.assertRaises(ValueError):
                self.store.select(*args)
            self.assertEqual((self.store.directory / 'store.json').read_bytes(), before)
        active['profile']['name'] = 'Mutated return value'
        self.assertNotEqual(self.store.read()['active']['profile']['name'], active['profile']['name'])

    def test_concurrent_writers_use_the_agent_directory_lock(self):
        other = ProfileStore(self.temporary.name)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = [pool.submit(store.select, 'xbox-standard', 1, 0) for store in (self.store, other)]
        self.assertEqual(sum(task.exception() is None for task in results), 1)
        self.assertEqual(self.store.read()['active']['revision'], 1)
        self.assertFalse((self.store.directory / 'write.lock').exists())

    def test_cloud_adoption_namespaces_preserves_original_and_is_immutable(self):
        summary, active = self.store.adopt(self.profile, self.source, 0)
        local_id = active['profile']['id']
        self.assertRegex(local_id, r'^cloud-[a-f0-9]{40}$')
        self.assertEqual(summary['adoption']['source'], self.source)
        self.assertEqual(len(self.store.read()['profiles']), 3)
        again, _ = self.store.adopt(self.profile, self.source, 1)
        self.assertEqual(again['activationRevision'], 1)
        changed = {**self.profile, 'name': 'Different content under the same revision'}
        with self.assertRaises(ValueError):
            self.store.adopt(changed, self.source, 1)
        for source in ({**self.source, 'revision': 2}, {**self.source, 'accountId': 'b' * 64},
                       {**self.source, 'service': 'https://another.example/v1'}):
            self.assertNotEqual(cloud_id(source, self.profile), local_id)
        self.assertEqual(self.store.read()['profiles'][0]['profile'], self.profile)

    def test_cloud_provenance_rejects_credentials_queries_and_bad_identity(self):
        for service in ('http://example.com', 'https://user:pass@example.com', 'https://example.com?',
                        'https://example.com#', 'https://', 'https://example.com:bad', 'https://a\\b', 'https://a b'):
            with self.subTest(service=service), self.assertRaises(ValueError):
                cloud_id({**self.source, 'service': service}, self.profile)
        for change in (dict(accountId='a'), dict(profileId='other'), dict(revision=True), dict(extra=1)):
            with self.assertRaises(ValueError):
                cloud_id({**self.source, **change}, self.profile)

    def test_summary_does_not_leak_private_sync_paths_or_character_identifiers(self):
        with self.store.transaction() as store:
            store['consolePortSync'] = dict(profileId='consoleport-character', exportedAt=100,
                                           sourcePath='C:/private/WTF/Account/secret',
                                           character=dict(name='Hero', guid='Player-private'),
                                           modifiers=dict(shift='lt'), buttonCount=2)
        summary = self.store.summary()
        self.assertEqual(summary['consolePortSync']['characterName'], 'Hero')
        self.assertNotIn('private', json.dumps(summary))


if __name__ == '__main__':
    unittest.main()
