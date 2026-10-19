import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('upgrade', Path(__file__).with_name('prepare-receiver-upgrade.py'))
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)

P = '00000000-0000-0000-0000-000000000201'
A = '00000000-0000-0000-0000-000000000101'
B = 'CB465C18-ABBA-4EF5-BFE9-52F1130E4D8D'
J = 'CB465C18-ABBA-4EF5-BFE9-52F1130E4D8E'


def source():
    return {'schemaVersion': 2, 'serverID': 'server-unchanged', 'trustedClients': {'fixture-only-token': {'name': 'fixture'}},
            'configurationRevision': 17, 'configurationUpdatedAt': 0, 'recentConfigurationCommits': [],
            'activeProfileID': P, 'defaultProfileID': P,
            'keyBindings': {'up': {'keyCode': 126, 'modifiersRawValue': 0}}, 'outputBindings': {},
            'profileKeyBindings': {}, 'profileOutputBindings': {},
            'profiles': [{'id': P, 'name': 'Original', 'customization': {
                'elements': [{'id': A, 'kind': 'button', 'label': 'Up', 'builtInButton': 'up', 'legacySlot': 'up', 'layout': {'centerX': .2}},
                             {'id': B, 'kind': 'button', 'label': 'Other', 'legacySlot': 'up', 'layout': {'centerX': .8}}],
                'buttonCustomizations': ['up', {'centerX': .2}], 'labelOverrides': ['up', 'North'],
                'designMetadata': {'layerOrder': [{'kind': 'builtin', 'button': 'up'}, {'kind': 'custom', 'id': B}], 'groups': []},
                'customButtons': [{'id': B, 'controlKind': 'button', 'mappedButton': 'up', 'label': 'Other', 'layout': {'centerX': .8}}]}}]}


class PrepareUpgradeTests(unittest.TestCase):
    def test_rebuild_uses_existing_uuids_and_preserves_authority_and_geometry(self):
        old = source(); original = copy.deepcopy(old)
        result, report = upgrade.prepare(old)
        self.assertEqual(old, original)
        for key in ['serverID', 'trustedClients', 'activeProfileID', 'defaultProfileID']:
            self.assertEqual(result[key], old[key])
        elements = result['profiles'][0]['customization']['elements']
        self.assertEqual([e['id'] for e in elements], [A, B])
        self.assertEqual([e['layout'] for e in elements], [e['layout'] for e in old['profiles'][0]['customization']['elements']])
        self.assertEqual(result['outputBindings'][A], result['outputBindings'][B])
        self.assertEqual(result['schemaVersion'], 3)
        self.assertEqual(result['configurationRevision'], 18)
        self.assertEqual(result['profiles'][0]['customization']['labelOverrides'], [A, 'North'])
        for e in elements:
            self.assertFalse(set(e).intersection(upgrade.ROUTING))
        self.assertEqual(report[0]['declaredUUIDs'], 2)

    def test_direct_clear_and_direction_bindings_remain_owned(self):
        old = source(); layout = old['profiles'][0]['customization']
        joy = {'id': J, 'kind': 'joystick', 'legacySlot': 'up', 'layout': {},
               'output': {}, 'partOutputs': ['joystick_up', {}],
               'joystickMapping': {d: 'up' for d in upgrade.DIRECTIONS}}
        layout['elements'].append(joy)
        result, _ = upgrade.prepare(old)
        converted = result['profiles'][0]['customization']['elements'][-1]
        self.assertEqual(converted['output'], {})
        self.assertEqual(converted['joystickMapping']['up'], {})
        self.assertEqual(converted['joystickMapping']['down']['keyboard']['keyCode'], 126)

    def test_duplicate_identity_and_wrong_source_schema_fail(self):
        old = source(); old['profiles'][0]['customization']['elements'].append(copy.deepcopy(old['profiles'][0]['customization']['elements'][0]))
        with self.assertRaises(AssertionError): upgrade.prepare(old)
        old = source(); old['schemaVersion'] = 3
        with self.assertRaises(AssertionError): upgrade.prepare(old)

    def test_absent_design_controls_are_reported_without_inventing_ids(self):
        old = source(); old['profiles'][0]['customization']['designMetadata']['layerOrder'].append({'kind': 'builtin', 'button': 'absent'})
        result, report = upgrade.prepare(old)
        self.assertEqual(report[0]['staleDesignReferencesRemoved'], 1)
        self.assertEqual(len(result['profiles'][0]['customization']['elements']), 2)

if __name__ == '__main__': unittest.main()
