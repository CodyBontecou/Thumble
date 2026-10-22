"""The diagnostic artifact accepts bounded synthetic state, never arbitrary data."""
import copy
import unittest
from check_ios_loopback import validate_results


class LoopbackResultsTests(unittest.TestCase):
    def value(self):
        return [{"client": "shared", "ok": True, "errorCode": 0}, {"client": "ephemeral", "ok": False, "errorCode": -1001}]

    def test_preserves_exact_client_outcomes_including_failures(self):
        value = self.value()
        self.assertEqual(validate_results(value), value)
        self.assertFalse(value[1]["ok"])

    def test_rejects_unbounded_or_unknown_artifact_fields(self):
        for field, bad in [("client", "untrusted-text"), ("errorCode", "private-error"), ("errorCode", True), ("errorCode", 100001), ("ok", 1), ("credential", "must-not-be-recorded")]:
            with self.subTest(field=field, bad=bad):
                value = copy.deepcopy(self.value())
                value[0][field] = bad
                with self.assertRaisesRegex(ValueError, "loopback_result_invalid"):
                    validate_results(value)
        for bad in [None, {}, [], self.value()[:1], self.value()[::-1], self.value() + self.value()]:
            with self.assertRaisesRegex(ValueError, "loopback_result_invalid"):
                validate_results(bad)


if __name__ == "__main__":
    unittest.main()
