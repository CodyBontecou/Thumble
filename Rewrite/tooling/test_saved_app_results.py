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


if __name__ == "__main__": unittest.main()
