"""Reject empty/skipped/wrong-route instrumentation results."""
import tempfile
from pathlib import Path
import unittest
from run_presentation_app_probe import verify_android_results


class PresentationResultTests(unittest.TestCase):
    def source(self, directory, *, name='actualPresentationRefreshWhileNativeInputHeld', body='', tests='1'):
        path=Path(directory)/'TEST-qa.xml'
        path.write_text(f'<testsuite tests="{tests}" failures="0" errors="0" skipped="0"><testcase classname="com.thumble.rewrite.qa.PresentationAppTest" name="{name}">{body}</testcase></testsuite>')
        return path

    def test_exact_case(self):
        with tempfile.TemporaryDirectory() as directory:
            self.source(directory)
            verify_android_results(directory)

    def test_rejects_missing_wrong_skipped_failed_and_duplicate(self):
        for options in ({'name':'wrong'}, {'body':'<skipped/>'}, {'body':'<failure/>'}, {'tests':'0'}):
            with self.subTest(options=options), tempfile.TemporaryDirectory() as directory:
                self.source(directory,**options)
                with self.assertRaises(AssertionError): verify_android_results(directory)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(AssertionError): verify_android_results(directory)
            source=self.source(directory)
            (Path(directory)/'TEST-extra.xml').write_bytes(source.read_bytes())
            with self.assertRaises(AssertionError): verify_android_results(directory)


if __name__=='__main__': unittest.main()
