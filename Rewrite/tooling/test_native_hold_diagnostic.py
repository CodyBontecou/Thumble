import json
import unittest
from native_hold_diagnostic import decode_native_hold_diagnostic, REASONS


class NativeHoldDiagnosticTests(unittest.TestCase):
    def test_exact_fixed_native_schema_and_all_reasons(self):
        for reason in REASONS:
            value = decode_native_hold_diagnostic(f"probe_hold_diagnostic reason={reason} elapsed_ms=4072 samples=246 report_matches=false\n")
            self.assertEqual(value, {"reason": reason, "elapsedMs": 4072, "samples": 246, "reportMatches": False})
        self.assertTrue(decode_native_hold_diagnostic("probe_hold_diagnostic reason=other elapsed_ms=0 samples=1000000 report_matches=true")["reportMatches"])

    def test_unknown_payloads_numbers_and_extra_fields_cannot_enter_reports(self):
        baseline = "probe_hold_diagnostic reason=input_expired elapsed_ms=4072 samples=246 report_matches=false"
        for text in (baseline + " private=secret", baseline.replace("input_expired", "private_token"), baseline.replace("4072", "180001"), baseline.replace("246", "1000001"), baseline.replace("4072", "-1"), baseline.replace("4072", "04072"), baseline.replace("false", "1"), baseline.replace("4072", "١"), " " + baseline, baseline + " ", "x" * 257, "private secret", None):
            self.assertIsNone(decode_native_hold_diagnostic(text))
        self.assertNotIn("secret", json.dumps(decode_native_hold_diagnostic(baseline)))


if __name__ == "__main__": unittest.main()
