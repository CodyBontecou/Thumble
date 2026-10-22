"""The diagnostic artifact accepts bounded synthetic state, never arbitrary data."""
import copy
import contextlib
import io
import json
from pathlib import Path
import subprocess
import tempfile
from unittest.mock import patch
import unittest
from check_ios_loopback import validate_results
import check_ios_loopback


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


class LoopbackFailureArtifactTests(unittest.TestCase):
    def test_compile_failure_keeps_bounded_partial_artifact_without_error_text(self):
        with tempfile.TemporaryDirectory(prefix="thumble-loopback-failure-") as temporary:
            report = Path(temporary) / "report.json"
            output = io.StringIO()
            with patch("sys.argv", ["check_ios_loopback.py", "--report", str(report)]), \
                 patch.object(check_ios_loopback, "command", return_value="/synthetic/sdk"), \
                 patch.object(check_ios_loopback.subprocess, "run", side_effect=subprocess.CalledProcessError(1, ["must-not-be-recorded"])), \
                 contextlib.redirect_stdout(output):
                with self.assertRaises(subprocess.CalledProcessError):
                    check_ios_loopback.main()
            value = json.loads(report.read_text())
            self.assertEqual(value["phase"], "compiling")
            self.assertTrue(value["failed"])
            self.assertFalse(value["completed"])
            self.assertEqual(value["launches"], [])
            self.assertEqual(value["httpRequests"], 0)
            self.assertTrue(value["serverThreadAlive"])
            self.assertIn("preparing", value["phaseDurationsMs"])
            self.assertNotIn("must-not-be-recorded", report.read_text() + output.getvalue())
            self.assertNotIn("/synthetic/sdk", report.read_text() + output.getvalue())


if __name__ == "__main__":
    unittest.main()
