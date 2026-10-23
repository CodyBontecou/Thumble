import copy
import unittest
from run_bank_presentation_ios_probe import verify_results, CASE, OWNED, validate_owned_simulator, cleanup_all

class BankIOSResultsTest(unittest.TestCase):
    def fixture(self):
        return ({'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0, 'result': 'Passed'},
                {'testNodes': [{'nodeType': 'Test Case', 'name': CASE + '()', 'nodeIdentifier': 'BankPresentationUITests/' + CASE + '()', 'result': 'Passed'}]})

    def test_exact_case(self):
        verify_results(*self.fixture())

    def test_rejects_skips_wrong_case_extra_case_and_failure(self):
        for mutation in ('skip', 'wrong', 'extra', 'failure', 'nested', 'boolean', 'wrongclass'):
            with self.subTest(mutation=mutation):
                summary, tree = copy.deepcopy(self.fixture())
                if mutation == 'skip': summary['skippedTests'] = 1
                if mutation == 'boolean': summary['passedTests'] = True
                if mutation == 'wrong': tree['testNodes'][0]['name'] = 'unrelated'
                if mutation == 'wrongclass': tree['testNodes'][0]['nodeIdentifier'] = 'Other/' + CASE
                if mutation == 'extra': tree['testNodes'] *= 2
                if mutation == 'failure': tree['testNodes'][0]['result'] = 'Failed'
                if mutation == 'nested': tree['testNodes'][0]['children'] = [dict(tree['testNodes'][0])]
                with self.assertRaises(AssertionError): verify_results(summary, tree)

class BankIOSOwnershipCleanupTest(unittest.TestCase):
    def inventory(self, identifier, name):
        return {'devices': {'runtime': [{'udid': identifier, 'name': name, 'isAvailable': True}]}}

    def test_accepts_only_owned_local_or_named_ci_simulator(self):
        validate_owned_simulator(OWNED, self.inventory(OWNED, 'Thumble Rewrite QA'))
        device = '11111111-2222-3333-4444-555555555555'
        validate_owned_simulator(device, self.inventory(device, 'Thumble Rewrite Bank CI run_42'))

    def test_rejects_unrelated_unknown_unavailable_duplicate_and_physical(self):
        device = '11111111-2222-3333-4444-555555555555'
        for mode in ('unrelated', 'unknown', 'unavailable', 'duplicate', 'physical', 'lowercase'):
            with self.subTest(mode=mode):
                identifier = device
                inventory = self.inventory(device, 'Thumble Rewrite Bank CI run42')
                if mode == 'unrelated': inventory['devices']['runtime'][0]['name'] = 'Personal iPhone'
                if mode == 'unknown': inventory['devices']['runtime'] = []
                if mode == 'unavailable': inventory['devices']['runtime'][0]['isAvailable'] = False
                if mode == 'duplicate': inventory['devices']['runtime'] *= 2
                if mode == 'physical': identifier = '00008110-00046CC63CA0401E'
                if mode == 'lowercase': identifier = OWNED.lower()
                with self.assertRaises(AssertionError): validate_owned_simulator(identifier, inventory)

    def test_cleanup_attempts_all_actions_and_does_not_replace_primary(self):
        visited = []
        primary = RuntimeError('primary')
        def broken():
            visited.append('failed')
            raise OSError('cleanup')
        original = None
        try:
            raise primary
        except RuntimeError as error:
            original = error
        finally:
            self.assertFalse(cleanup_all([broken, lambda: visited.append('restored')]))
        self.assertIs(original, primary)
        self.assertEqual(visited, ['failed', 'restored'])
        self.assertTrue(cleanup_all([lambda: visited.append('ok')]))

if __name__ == '__main__': unittest.main()
