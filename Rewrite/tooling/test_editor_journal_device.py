import tempfile
from pathlib import Path
import unittest
from check_editor_journal_device import verify, CLASS, CASE

class EditorJournalProviderEvidenceTest(unittest.TestCase):
    def check(self, body):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "TEST-synthetic.xml"
            path.write_text(body)
            return verify([path])
    def xml(self, case=None, counts='tests="1" failures="0" errors="0" skipped="0"'):
        return f'<testsuite {counts}><testcase classname="{CLASS}" name="{CASE}">{case or ""}</testcase></testsuite>'
    def test_exact_case_passes(self):
        self.assertEqual(self.check(self.xml())["result"], "passed")
    def test_empty_or_extra_results_rejected(self):
        with self.assertRaises(ValueError): verify([])
        with self.assertRaises(ValueError): verify([Path("one"), Path("two")])
    def test_bounded_read_rejects_oversize_and_utf16_dtd(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "TEST-synthetic.xml"
            for content in [b"x" * (512 * 1024 + 1), ('<!DOCTYPE testsuite [<!ENTITY x "private">]>' + self.xml()).encode("utf-16")]:
                path.write_bytes(content)
                with self.subTest(), self.assertRaises(ValueError): verify([path])
    def test_nested_failure_nodes_rejected(self):
        variants = [self.xml('<container><failure/></container>'), self.xml().replace('</testsuite>', '<container><skipped/></container></testsuite>'), self.xml('<nested><error/></nested>')]
        for content in variants:
            with self.subTest(), self.assertRaises(ValueError): self.check(content)
    def test_failed_skipped_wrong_case_and_contradictory_counts_rejected(self):
        variants = [self.xml('<skipped/>'), self.xml('<failure message="private arbitrary data"/>'), self.xml().replace(CASE, "unknown"), self.xml(counts='tests="0" failures="0" errors="0" skipped="0"'), self.xml().replace('</testsuite>', '<testcase/></testsuite>'), '<testsuite/>', '<!DOCTYPE testsuite [<!ENTITY x "private">]>' + self.xml()]
        for item in variants:
            with self.subTest(), self.assertRaises(ValueError): self.check(item)

if __name__ == "__main__": unittest.main()
