from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest

from thumble_receiver.profiles import ProfileStore, ProfileError
from thumble_receiver.workspace_profiles import WorkspaceProfiles

FIXTURE = Path(__file__).resolve().parents[3] / 'packages/desktop-workspace/test/contracts.json'


class WorkspaceContracts(unittest.TestCase):
    def test_shared_revision_and_activation_contract(self):
        fixture = json.loads(FIXTURE.read_text())
        with tempfile.TemporaryDirectory() as directory:
            workspace = WorkspaceProfiles(ProfileStore(directory))
            profile_id = fixture['profile']['id']
            for index, step in enumerate(fixture['steps']):
                with self.subTest(step=index):
                    def operation():
                        if step['operation'] == 'save':
                            profile = deepcopy(fixture['profile']); profile['name'] = step['name']
                            if step.get('small'): profile['controls'][0]['frame']['width'] = .01
                            workspace.save(profile, step['expected'], fixture['viewport'])
                        elif step['operation'] == 'activate':
                            workspace.activate(profile_id, step['expected'], step['activation'], fixture['viewport'])
                        else: workspace.delete(profile_id, step['expected'], step['activation'])
                    if step.get('error'):
                        before = Path(directory, 'store.json').read_bytes()
                        with self.assertRaises((ProfileError, ValueError)): operation()
                        self.assertEqual(Path(directory, 'store.json').read_bytes(), before)
                    else: operation()
                    state = workspace.snapshot()
                    entry = next(e for e in state['profiles'] if e['profile']['id'] == profile_id)
                    self.assertEqual(entry['revision'], step['profileRevision'])
                    self.assertEqual(state['activationRevision'], step['activationRevision'])
                    self.assertTrue(entry['editable'])
                    if 'activeName' in step: self.assertEqual(state['active']['profile']['name'], step['activeName'])

    def test_originals_are_preserved_and_drafts_can_be_removed(self):
        fixture = json.loads(FIXTURE.read_text())
        with tempfile.TemporaryDirectory() as directory:
            workspace = WorkspaceProfiles(ProfileStore(directory))
            original = workspace.snapshot()['profiles'][0]
            changed = deepcopy(original['profile']); changed['name'] = 'Overwrite original'
            with self.assertRaises(ProfileError): workspace.save(changed, 1, fixture['viewport'])
            with self.assertRaises(ProfileError): workspace.delete(original['profile']['id'], 1, 0)
            workspace.save(fixture['profile'], 0, fixture['viewport'])
            workspace.delete(fixture['profile']['id'], 1, 0)
            self.assertFalse(any(e['profile']['id'] == fixture['profile']['id'] for e in workspace.snapshot()['profiles']))


if __name__ == '__main__': unittest.main()
