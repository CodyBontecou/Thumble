"""Only the exact known diagnostic may leave the private xcresult export."""
import json
from pathlib import Path
import tempfile
import unittest
from collect_ios_http_diagnostic import collect, validate_diagnostic, NAME, TEST


class HttpDiagnosticTests(unittest.TestCase):
    def value(self):
        return {"phase": "begin-http-failed", "originalErrorIsURL": True, "originalErrorCode": -1005,
                "ephemeralHealthSucceeded": True, "ephemeralHealthErrorCode": 0}

    def attachment(self):
        return {"suggestedHumanReadableName": NAME, "exportedFileName": "synthetic.json", "isAssociatedWithFailure": True}

    def test_validated_exact_fields_retain_the_original_failure(self):
        self.assertEqual(validate_diagnostic(self.value()), self.value())
        for field, value in [("phase", "arbitrary"), ("credential", "must-not-copy"), ("originalErrorCode", True),
                             ("originalErrorCode", -100001), ("originalErrorIsURL", 1), ("ephemeralHealthSucceeded", "true"),
                             ("ephemeralHealthErrorCode", -1001)]:
            with self.subTest(field=field, value=value):
                with self.assertRaisesRegex(ValueError, "ios_http_diagnostic_invalid"):
                    validate_diagnostic({**self.value(), field: value})

    def test_export_copies_only_the_known_json_and_ignores_other_attachment_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "reports/diagnostic.json"
            (root / "synthetic.json").write_text(json.dumps(self.value()))
            unknown = {"suggestedHumanReadableName": "private-screenshot", "exportedFileName": "do-not-read.png", "isAssociatedWithFailure": True}
            manifest = [{"testIdentifier": TEST, "testIdentifierURL": "not-published", "attachments": [unknown, self.attachment()]}]
            (root / "manifest.json").write_text(json.dumps(manifest))
            self.assertTrue(collect(root, output))
            self.assertEqual(json.loads(output.read_text()), self.value())
            self.assertNotIn("not-published", output.read_text())
            self.assertEqual(list(output.parent.iterdir()), [output])
            (root / "manifest.json").write_text("[]")
            self.assertFalse(collect(root, output))
            self.assertFalse(output.exists())

    def test_actual_xctest_generated_name_requires_failure_in_the_same_test(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "reports/diagnostic.json"
            (root / "synthetic.json").write_text(json.dumps(self.value()))
            known = {**self.attachment(), "suggestedHumanReadableName": NAME + "_0_0248D481-B366-4ECB-94A8-34FDEEAF8D3B.json", "isAssociatedWithFailure": False}
            issue = {"suggestedHumanReadableName": "Complete Issue Description.txt", "exportedFileName": "do-not-read.txt", "isAssociatedWithFailure": True}
            (root / "manifest.json").write_text(json.dumps([{"testIdentifier": TEST, "attachments": [known, issue]}]))
            self.assertTrue(collect(root, output))
            self.assertEqual(json.loads(output.read_text()), self.value())
            (root / "manifest.json").write_text(json.dumps([{"testIdentifier": TEST, "attachments": [known]}]))
            with self.assertRaises(ValueError): collect(root, output)
            self.assertFalse(output.exists())

    def test_ambiguous_wrong_test_path_alias_and_symlink_exports_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "reports/diagnostic.json"
            (root / "synthetic.json").write_text(json.dumps(self.value()))
            for change in [{"exportedFileName": "../synthetic.json"}, {"exportedFileName": "folder\\synthetic.json"},
                           {"isAssociatedWithFailure": False}, {"exportedFileName": "/absolute.json"}]:
                with self.subTest(change=change):
                    (root / "manifest.json").write_text(json.dumps([{"testIdentifier": TEST, "attachments": [{**self.attachment(), **change}]}]))
                    with self.assertRaises(ValueError): collect(root, output)
                    self.assertFalse(output.exists())
            (root / "manifest.json").write_text(json.dumps([{"testIdentifier": "other-test", "attachments": [self.attachment()]}]))
            self.assertFalse(collect(root, output))
            (root / "manifest.json").write_text(json.dumps([{"testIdentifier": TEST, "attachments": [self.attachment(), self.attachment()]}]))
            with self.assertRaises(ValueError): collect(root, output)
            (root / "manifest.json").write_text(json.dumps([{"testIdentifier": TEST, "attachments": [self.attachment()]}]))
            (root / "synthetic.json").unlink()
            (root / "target.json").write_text(json.dumps(self.value()))
            (root / "synthetic.json").symlink_to(root / "target.json")
            with self.assertRaises((OSError, ValueError)): collect(root, output)

    def test_oversize_duplicate_keys_and_extra_secret_fields_cannot_be_published(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / "reports/diagnostic.json"
            (root / "manifest.json").write_text(json.dumps([{"testIdentifier": TEST, "attachments": [self.attachment()]}]))
            for text in [" " * 1025, json.dumps({**self.value(), "secret": "must-not-copy"}),
                         json.dumps(self.value())[:-1] + ',"originalErrorCode":-1001}']:
                (root / "synthetic.json").write_text(text)
                with self.assertRaises(ValueError): collect(root, output)
                self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
