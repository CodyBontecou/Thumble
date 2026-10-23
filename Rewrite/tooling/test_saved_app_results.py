import json
from pathlib import Path
import tempfile
import unittest
from check_saved_app_results import verify


class SavedAppResultTests(unittest.TestCase):
    def test_exact_ios_case_only_and_no_skip_or_private_attachment_reflection(self):
        with tempfile.TemporaryDirectory() as directory:
            summary = Path(directory) / "summary.json"
            cases = Path(directory) / "cases.json"
            good = {"totalTestCount": 1, "passedTests": 1, "failedTests": 0, "skippedTests": 0, "result": "Passed"}
            case = {"nodeType": "Test Case", "name": "testActualReactSavedMapSummaryCornerAndDismissal()", "result": "Passed", "private": "typed invitation"}
            summary.write_text(json.dumps(good)); cases.write_text(json.dumps({"testNodes": [case]}))
            result = verify("ios", "corner", [summary, cases])
            self.assertEqual(result["status"], "passed")
            self.assertNotIn("invitation", json.dumps(result))
            for bad in ({**good, "skippedTests": 1}, {**good, "totalTestCount": 2}, {**good, "result": "Failed"}):
                summary.write_text(json.dumps(bad))
                self.assertEqual(verify("ios", "unsupported", [summary, cases])["status"], "failed")
            summary.write_text(json.dumps(good))
            for change in ({**case, "name": "private"}, {**case, "result": "Skipped"}):
                cases.write_text(json.dumps({"testNodes": [change]}))
                self.assertEqual(verify("ios", "corner", [summary, cases])["status"], "failed")

    def test_android_requires_exact_one_production_route_case(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.xml"
            case = '<testcase classname="com.thumble.rewrite.qa.SavedControllerAppTest" name="actualSavedMapSummaryCornerAndDismissal" />'
            path.write_text('<testsuite tests="1" failures="0" errors="0" skipped="0">' + case + '</testsuite>')
            self.assertEqual(verify("android", "corner", [path])["status"], "passed")
            for body in (case.replace('/>', '><skipped /></testcase>'), case + case, case.replace('SavedControllerAppTest', 'PracticeInputTest')):
                path.write_text('<testsuite tests="1">' + body + '</testsuite>')
                self.assertEqual(verify("android", "corner", [path])["status"], "failed")
            path.write_text("x" * 2_097_153)
            self.assertEqual(verify("android", "corner", [path])["status"], "failed")

    def test_failed_command_cannot_admit_old_passing_results(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.xml"
            path.write_text('<testsuite tests="1"><testcase classname="com.thumble.rewrite.qa.SavedControllerAppTest" name="actualSavedMapSummaryCornerAndDismissal" /></testsuite>')
            result = verify("android", "corner", [path], command_failed=True)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["diagnostic"]["failureCategory"], "command-failed")
            stale = verify("android", "corner", [path], command_failed=True, results_not_before_ns=path.stat().st_mtime_ns + 1)
            self.assertEqual(stale["diagnostic"]["failureCategory"], "stale-results")

    def test_android_exact_assertion_category_without_message_reflection(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "test.xml"
            def failure(message):
                path.write_text('<testsuite tests="1" failures="1"><testcase classname="com.thumble.rewrite.qa.SavedControllerAppTest" name="actualSavedMapSummaryCornerAndDismissal"><failure message="' + message + '" /></testcase></testsuite>')
                return verify("android", "unsupported", [path], command_failed=True)
            result = failure("saved_controller_unsupported_not_reported")
            self.assertEqual(result["diagnostic"], {"stage": "assertion", "case": "saved-controller", "failureCategory": "assertion", "assertion": "unsupported-result"})
            for value in ["secret saved_controller_unsupported_not_reported", "saved_controller_connection_not_ready secret", "https://private.invalid/token", "secret"]:
                result = failure(value)
                self.assertEqual(result["diagnostic"]["failureCategory"], "test-failed")
                self.assertNotIn(value, json.dumps(result))

    def test_ios_failed_case_exports_only_source_authored_marker(self):
        with tempfile.TemporaryDirectory() as directory:
            summary, cases = Path(directory) / "summary", Path(directory) / "cases"
            summary.write_text(json.dumps({"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0, "result": "Failed", "testFailures": [{"failureText": "Native saved controller did not become ready", "url": "private"}]}))
            cases.write_text(json.dumps({"testNodes": [{"nodeType": "Test Case", "name": "testActualReactSavedMapSummaryCornerAndDismissal()", "result": "Failed", "attachments": ["private"]}]}))
            result = verify("ios", "corner", [summary, cases], command_failed=True)
            self.assertEqual(result["diagnostic"]["assertion"], "connection-ready")
            self.assertNotIn("private", json.dumps(result))
            result = verify("ios", "corner", [summary, cases], command_failed=True, export_failed=True)
            self.assertEqual(result["diagnostic"]["stage"], "result-export")

    def test_missing_malformed_and_wrong_case_never_claim_assertion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "missing.xml"
            result = verify("android", "corner", [path], command_failed=True)
            self.assertEqual(result["diagnostic"]["stage"], "app-command")
            path.write_text('<testsuite><testcase classname="private" name="private"><failure message="saved_controller_connection_not_ready" /></testcase></testsuite>')
            result = verify("android", "corner", [path], command_failed=True)
            self.assertEqual(result["diagnostic"]["case"], "not-evaluated")
            path.write_text("not xml")
            self.assertEqual(verify("android", "corner", [path])["status"], "failed")

    def test_contradictory_ios_summary_never_attributes_an_assertion(self):
        with tempfile.TemporaryDirectory() as directory:
            summary, cases = Path(directory) / "summary", Path(directory) / "cases"
            failed_summary = {"totalTestCount": 1, "passedTests": 0, "failedTests": 1, "skippedTests": 0, "result": "Failed", "testFailures": [{"failureText": "Native saved controller did not become ready"}]}
            for case_result, change in [("Passed", {}), ("Skipped", {}), ("Failed", {"failedTests": 0}), ("Failed", {"totalTestCount": 2}), ("Failed", {"passedTests": 1}), ("Failed", {"skippedTests": 1}), ("Failed", {"result": "Passed"})]:
                summary.write_text(json.dumps({**failed_summary, **change}))
                cases.write_text(json.dumps({"testNodes": [{"nodeType": "Test Case", "name": "testActualReactSavedMapSummaryCornerAndDismissal()", "result": case_result}]}))
                result = verify("ios", "corner", [summary, cases], command_failed=True)
                self.assertEqual(result["status"], "failed")
                self.assertNotIn("assertion", result["diagnostic"])
                self.assertNotEqual(result["diagnostic"]["stage"], "assertion")


if __name__ == "__main__": unittest.main()
