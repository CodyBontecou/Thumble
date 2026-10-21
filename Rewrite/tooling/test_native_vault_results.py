import copy
from pathlib import Path
import tempfile
import unittest
import check_native_vault_results as check

class ProviderEvidenceTests(unittest.TestCase):
    def ios(self):
        return {"testNodes":[{"nodeType":"Test Suite","name":"MobileInputTests","children":[{"nodeType":"Test Case","name":check.IOS_CASE+"()","result":"Passed"}]}]}, {"result":"Passed","passedTests":1,"failedTests":0}
    def test_ios_requires_specific_passed_case(self):
        tree, summary = self.ios()
        self.assertEqual(check.ios(tree, summary)["result"], "Passed")
        for status in ["Skipped", "Failed", "unknown"]:
            bad = copy.deepcopy(tree); bad["testNodes"][0]["children"][0]["result"] = status
            with self.assertRaises(ValueError): check.ios(bad, summary)
        with self.assertRaises(ValueError): check.ios({"testNodes":[]}, summary)
        with self.assertRaises(ValueError): check.ios(tree, {"result":"Passed","passedTests":0,"failedTests":0})
    def test_android_requires_specific_non_skipped_case(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/"TEST-provider.xml"
            for extra in ["", "<skipped/>", "<failure/>", "<error/>"]:
                path.write_text(f'<testsuite><testcase classname="{check.ANDROID_CLASS}" name="{check.ANDROID_CASE}">{extra}</testcase></testsuite>')
                if extra:
                    with self.assertRaises(ValueError): check.android([path])
                else: self.assertEqual(check.android([path])["result"], "Passed")
            with self.assertRaises(ValueError): check.android([])
            path.write_text('<testsuite><testcase classname="other" name="other"/></testsuite>')
            with self.assertRaises(ValueError): check.android([path])

if __name__ == "__main__": unittest.main()
