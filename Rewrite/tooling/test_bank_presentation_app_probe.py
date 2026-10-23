"""Reject empty/skipped/wrong-route instrumentation results."""
import tempfile
from pathlib import Path
import unittest
from run_bank_presentation_app_probe import verify_android_results


class PresentationResultTests(unittest.TestCase):
    def source(self, directory, *, name='actualModifierBanksTrackNativeHeldStateAndRefresh', body='', tests='1'):
        path=Path(directory)/'TEST-qa.xml'
        path.write_text(f'<testsuite tests="{tests}" failures="0" errors="0" skipped="0"><testcase classname="com.thumble.rewrite.qa.BankPresentationAppTest" name="{name}">{body}</testcase></testsuite>')
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


    def test_accepts_actual_gradle_aggregate_with_exact_suite_and_counters(self):
        with tempfile.TemporaryDirectory() as directory:
            path=self.source(directory)
            path.write_text('<testsuites tests="1" failures="0" errors="0" skipped="0">' + path.read_text() + '</testsuites>')
            verify_android_results(directory)

    def test_rejects_invalid_root_or_nested_suites_even_with_exact_case(self):
        for wrapper in ('bogus', 'testsuites'):
            with self.subTest(wrapper=wrapper), tempfile.TemporaryDirectory() as directory:
                path=self.source(directory)
                raw=path.read_text()
                path.write_text(f'<{wrapper}>' + raw + f'</{wrapper}>')
                with self.assertRaises(AssertionError): verify_android_results(directory)
        with tempfile.TemporaryDirectory() as directory:
            path=self.source(directory)
            path.write_text(path.read_text().replace('</testsuite>', '<testsuite tests="0"/></testsuite>'))
            with self.assertRaises(AssertionError): verify_android_results(directory)


if __name__=='__main__': unittest.main()
