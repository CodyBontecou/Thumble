from copy import deepcopy
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

from thumble_receiver.consoleport import (ConsolePortSync, decode_saved, validate_snapshot,
                                         make_profile, commit, snapshot_files, short_label)
from thumble_receiver.profiles import MODIFIERS, ProfileStore, validate_profile
from thumble_receiver.workspace_profiles import WorkspaceProfiles


def snapshot(name='Hero', guid='Player-123-456', label='Attack', now=100):
    return dict(bridgeVersion=1, kind='consoleport-sync', exportedAt=now,
                character=dict(name=name, guid=guid), actionPage=1, consolePortVersion='2.9',
                modifiers=dict(GamePadEmulateShift='PADLTRIGGER', GamePadEmulateCtrl='PADRTRIGGER',
                               GamePadEmulateAlt='NONE'),
                consolePortLayout=[dict(key=key, layers=[dict(modifier=state, label=label,
                    command='ACTIONBUTTON1', kind='spell', id=6603) if key == 'PAD1'
                    else dict(modifier=state, label='Jump', command='JUMP') for state in sorted(MODIFIERS)])
                    for key in ('PAD1', 'PAD2')])


def saved(value):
    data = json.dumps(value, ensure_ascii=False).replace('\\', '\\\\').replace('"', '\\"')
    return ('ThumbleBridgeDB = {\n ["syncText"] = "' + data + '",\n}').encode()


class ConsolePortTests(unittest.TestCase):
    def test_desktop_identity_and_unsent_draft_survive_label_sync(self):
        workspace = WorkspaceProfiles(self.store)
        source = deepcopy(self.store.builtins[1])
        source.update(id='desktop-'+'b'*32, name='My desktop layout')
        control_id = next(m['controlId'] for m in source['mappings'] if m['outputs'] == ['a'])
        next(c for c in source['controls'] if c['id'] == control_id)['label'] = 'My jump'
        viewport = dict(width=844, height=390)
        workspace.save(source, 0, viewport); workspace.activate(source['id'], 1, 0, viewport)
        value = validate_snapshot(json.dumps(snapshot()).encode(), 100)
        refreshed = make_profile(value, source)
        self.assertEqual(refreshed['id'], source['id']); self.assertEqual(refreshed['name'], source['name'])
        self.assertEqual(next(c for c in refreshed['controls'] if c['id'] == control_id)['label'], 'My jump')
        commit(self.store, refreshed, value, '/isolated/wow', 1)
        state = workspace.snapshot()
        entry = next(e for e in state['profiles'] if e['profile']['id'] == source['id'])
        self.assertTrue(entry['editable']); self.assertEqual(entry['revision'], 2)
        draft = {**refreshed, 'name': 'Unsent desktop draft'}
        workspace.save(draft, 2, viewport)
        before = (self.store.directory / 'store.json').read_bytes()
        updated = validate_snapshot(json.dumps(snapshot(label='Later ability')).encode(), 100)
        with self.assertRaises(ValueError):
            commit(self.store, make_profile(updated, refreshed), updated, '/isolated/wow', 2)
        self.assertEqual((self.store.directory / 'store.json').read_bytes(), before)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.store = ProfileStore(self.root / 'profiles')
        self.game = self.root / 'World of Warcraft/_classic_era_'
        self.file = self.game / 'WTF/Account/123/Realm/Hero/SavedVariables/ThumbleBridge.lua'
        self.file.parent.mkdir(parents=True)
        self.stamp = time.time_ns()
        self.sync = ConsolePortSync(self.store, [self.game.parent], wall=lambda: 100)

    def write(self, value):
        self.file.write_bytes(saved(value))
        self.stamp += 1_000_000_000
        os.utime(self.file, ns=(self.stamp, self.stamp))

    def test_bounded_data_only_lua_decoder(self):
        value = snapshot(label='Atk "quoted" \\ emoji 😀')
        self.assertEqual(json.loads(decode_saved(saved(value))), value)
        self.assertEqual(decode_saved(b'ThumbleBridgeDB = {["syncText"]="\\123\\034x\\034\\0581\\125"}'), b'{"x":1}')
        for data in (b'return os.execute("bad")', b'ThumbleBridgeDB = {["syncText"]="\\999"}',
                     b'ThumbleBridgeDB = {["syncText"]="\\q"}', b'ThumbleBridgeDB = {["syncText"]="unterminated',
                     b'ThumbleBridgeDB = {["syncText"]="a\nb"}', b' ' * (4 * 1024 * 1024 + 1),
                     b'ThumbleBridgeDB = {["syncText"]="' + b'a' * 262145 + b'"}'):
            with self.assertRaises(ValueError):
                decode_saved(data)

    def test_snapshot_rejects_stale_future_duplicate_and_injection_values(self):
        variants = [snapshot(now=-201), snapshot(now=401), {**snapshot(), 'bridgeVersion': True}]
        value = snapshot()
        value['consolePortLayout'].append(deepcopy(value['consolePortLayout'][0]))
        variants.append(value)
        for key, item in (('label', '|cffbad'), ('label', 'line\nline'), ('command', 'line\nline'),
                          ('modifier', 'CUSTOM-'), ('kind', 'lua'), ('id', True)):
            value = snapshot()
            value['consolePortLayout'][0]['layers'][0][key] = item
            variants.append(value)
        value = snapshot()
        value['modifiers']['GamePadEmulateShift'] = 'KEYBOARD'
        variants.append(value)
        value = snapshot()
        value['consolePortLayout'][0]['layers'][1] = deepcopy(value['consolePortLayout'][0]['layers'][0])
        variants.append(value)
        for value in variants:
            with self.assertRaises(ValueError):
                validate_snapshot(json.dumps(value).encode(), 100)

    def test_profile_preserves_geometry_mapping_and_all_modifier_layers(self):
        source = self.store.builtins[1]
        value = validate_snapshot(json.dumps(snapshot()).encode(), 100)
        profile = make_profile(value, source)
        validate_profile(profile)
        self.assertEqual(profile['mappings'], source['mappings'])
        self.assertEqual([control['frame'] for control in profile['controls']], [control['frame'] for control in source['controls']])
        self.assertEqual(profile['modifiers'], dict(shift='lt', ctrl='rt', alt='none'))
        control_id = next(mapping['controlId'] for mapping in profile['mappings'] if mapping['outputs'] == ['a'])
        button = next(control for control in profile['controls'] if control['id'] == control_id)
        self.assertEqual(button['icon'], 'ability_meleedamage')
        self.assertEqual(set(button['layers']), MODIFIERS)
        self.assertRegex(profile['id'], r'^consoleport-[a-f0-9]{24}$')
        self.assertEqual(short_label('😀' * 50), '😀' * 40)

    def test_baseline_no_activation_then_reload_import_and_idempotence(self):
        self.write(snapshot())
        self.sync.poll(baseline=True)
        self.assertIsNone(self.store.read()['active'])
        self.write(snapshot())
        self.sync.poll()
        first = self.store.read()['active']
        self.assertEqual(first['revision'], 1)
        self.assertIn('Hero synced', self.sync.detail)
        self.write(snapshot())
        self.sync.poll()
        self.assertEqual(self.store.read()['active']['revision'], 1)
        self.write(snapshot(label='Changed attack'))
        self.sync.poll()
        self.assertEqual(self.store.read()['active']['revision'], 2)
        self.assertEqual(self.store.summary()['consolePortSync']['buttonCount'], 2)

    def test_stale_and_nonconsoleport_layouts_are_retained(self):
        self.store.select('xbox-standard', 1, 0)
        before = (self.store.directory / 'store.json').read_bytes()
        self.write(snapshot())
        self.sync.poll()
        self.assertEqual((self.store.directory / 'store.json').read_bytes(), before)
        self.assertIn('Select a ConsolePort', self.sync.detail)
        self.store.select('consoleport-standard', 1, 1)
        self.write(snapshot())
        self.sync.poll()
        before = (self.store.directory / 'store.json').read_bytes()
        self.write(snapshot(now=1_000))
        self.sync.poll()
        self.assertEqual((self.store.directory / 'store.json').read_bytes(), before)

    def test_commit_conflict_does_not_overwrite_a_newer_character(self):
        profile = make_profile(snapshot(), self.store.builtins[1])
        self.store.select('xbox-standard', 1, 0)
        with self.assertRaises(ValueError):
            commit(self.store, profile, snapshot(), self.file, expected=0)
        self.assertEqual(self.store.read()['active']['profile']['id'], 'xbox-standard')

    def test_snapshot_discovery_excludes_symlink_escape(self):
        self.write(snapshot())
        self.assertEqual(snapshot_files([self.game.parent]), [self.file.resolve()])
        link = self.game / 'WTF/Account/123/Realm/Linked'
        try:
            link.symlink_to(self.file.parent.parent, target_is_directory=True)
        except OSError:
            self.skipTest('Target OS does not grant symlink creation to this runner')
        self.assertEqual(snapshot_files([self.game.parent]), [self.file.resolve()])


if __name__ == '__main__':
    unittest.main()
