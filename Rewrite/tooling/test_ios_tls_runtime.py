import unittest
from check_ios_tls_runtime import validate_result


class RuntimeResultTests(unittest.TestCase):
    def test_strict_fixed_result(self):
        value = dict(version=1, scope='explicit-map-ios-runtime', passed=True, phase='finish', generation='2', elapsedMs=75000, publications=4500, maximumPublicationGapMs=18, tlsRuntimeOutcome='ready', controlFailureStage='none')
        self.assertEqual(validate_result(value), value)
        for key, replacement in [('extra', 'secret'), ('publications', True), ('elapsedMs', 180001), ('tlsRuntimeOutcome', 'private-endpoint'), ('phase', 'holding'), ('generation', '1')]:
            with self.assertRaises(ValueError): validate_result(dict(value, **{key: replacement}))

    def test_failure_preserves_bounded_stage(self):
        value = dict(version=1, scope='explicit-map-ios-runtime', passed=False, phase='holding', generation='1', elapsedMs=4071, publications=246, maximumPublicationGapMs=17, tlsRuntimeOutcome='read-deadline', controlFailureStage='progress')
        self.assertEqual(validate_result(value), value)
