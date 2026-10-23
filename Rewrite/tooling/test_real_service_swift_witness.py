"""Failure reports must remain discriminating without reflecting XCTest payloads."""
import json
from pathlib import Path
import tempfile
import unittest
from check_real_service_swift_witness import summarize

NAME = "actualSavedControllerServiceMapDeliversNativeInputAndRejectsUnsupportedProfile"


def stream():
    cases = [{"id": str(i), "displayName": '"' + mode + '"'} for i, mode in enumerate(("udp", "tls-fallback", "unsupported"))]
    result = [{"version": 0, "kind": "test", "payload": {"id": "synthetic-test", "name": NAME + "(mode:)", "_testCases": cases}}]
    def event(kind, **extra):
        return {"version": 0, "kind": "event", "payload": {"kind": kind, "testID": "synthetic-test", **extra}}
    result.extend([event("runStarted"), event("testStarted")])
    for case in cases:
        result.extend([event("testCaseStarted", _testCase=case), event("testCaseEnded", _testCase=case)])
    result.extend([event("testEnded", messages=[{"symbol": "pass"}]), event("runEnded", messages=[{"symbol": "pass"}])])
    return result


class SwiftWitnessTests(unittest.TestCase):
    def result(self, records, status=0):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            path.write_text("\n".join(json.dumps(r) for r in records))
            return summarize(path, NAME, 3, status)

    def test_exact_complete_cases_pass_and_nonzero_exit_cannot_pass(self):
        self.assertEqual(self.result(stream())["status"], "passed")
        self.assertEqual(self.result(stream(), 1)["failureStage"], "exit_nonzero")

    def test_issue_modes_are_allowlisted_and_private_text_never_reflected(self):
        records = stream()
        records.insert(3, {"version": 0, "kind": "event", "payload": {"kind": "issueRecorded", "_testCase": {"displayName": '"udp"'}, "messages": [{"text": "Caught error: closed"}, {"text": "secret endpoint /private/path"}]}})
        result = self.result(records, 1)
        self.assertEqual(result["failureStage"], "issue_or_skip")
        self.assertEqual(result["failedModes"], ["udp"])
        self.assertEqual(result["knownErrors"], ["probe_closed"])
        self.assertNotIn("secret", json.dumps(result))
        records[3]["payload"]["_testCase"]["displayName"] = "private-token"
        self.assertNotIn("failedModes", self.result(records))

    def test_missing_duplicate_skipped_and_incomplete_cases_fail_closed(self):
        for change, expected in ((lambda r: r.pop(), "incomplete_run"), (lambda r: r[0]["payload"]["_testCases"].pop(), "wrong_case_count"), (lambda r: r[2]["payload"].update(kind="testSkipped"), "issue_or_skip"), (lambda r: r.append(r[-1]), "incomplete_run")):
            records = stream()
            change(records)
            self.assertEqual(self.result(records)["failureStage"], expected)

    def test_absent_oversized_and_malformed_streams_are_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "events.jsonl"
            self.assertEqual(summarize(path, NAME, 3, 1)["failureStage"], "no_stream")
            for value, expected in (("x" * 2_097_153, "stream_bounds"), ("{}", "stream_schema"), ("not-json", "stream_schema")):
                path.write_text(value)
                self.assertEqual(summarize(path, NAME, 3, 1)["failureStage"], expected)
        with self.assertRaisesRegex(ValueError, "arguments_invalid"):
            summarize("unused", "private-name", 3, 1)




class ProbeDiagnosticProjectionTests(unittest.TestCase):
    def project(self, lines):
        from check_real_service_swift_witness import project_diagnostics
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "private.log"
            path.write_text("\n".join(lines))
            return project_diagnostics(path)

    def test_fixed_stages_first_outcome_and_first_native_error_only(self):
        result = self.project([
            'native_probe_stage instance=1 stage=command-q event=sent outcome=none',
            'native_probe_stage instance=1 stage=command-q event=failed outcome=early-eof',
            'native_probe_stage instance=1 stage=command-q event=failed outcome=owned-watchdog',
            'native_probe_stage instance=2 stage=startup event=failed outcome=owned-watchdog',
            'Error: "probe_continuous_hold_interrupted"',
            'native_input_error {"version":1,"role":"broker","context":"native-client","op":3,"code":"native_input_timeout"}',
            'native_input_error {"version":1,"role":"broker","context":"native-client","op":3,"code":"native_input_transport_failed"}',
            'native_control_terminal code=input_session_closed elapsed_us=123',
        ])
        self.assertEqual([v['outcome'] for v in result['firstProcessOutcomes']], ['early-eof', 'owned-watchdog'])
        self.assertEqual(result['firstNativeInputError']['code'], 'native_input_timeout')
        self.assertEqual(result['firstControlOutcomeAfterCleanup']['code'], 'input_session_closed')
        self.assertEqual(result['firstProbeError'], 'probe_continuous_hold_interrupted')

    def test_untrusted_payloads_and_unknown_identifiers_never_reflected(self):
        result = self.project([
            'secret invitation bearer /private/source',
            'native_probe_stage instance=1 stage=secret event=failed outcome=early-eof',
            'native_probe_stage instance=01 stage=startup event=failed outcome=early-eof',
            'native_probe_stage instance=1 stage=startup event=sent outcome=early-eof',
            'native_probe_stage instance=1 stage=startup event=failed outcome=none',
            'Error: "probe_private_secret"',
            'native_probe_stage instance=1 stage=startup event=failed outcome=early-eof extra=secret',
            '\u00e9' * 2048,
        ])
        self.assertEqual(result['stages'], [])
        self.assertIsNone(result['firstProbeError'])
        self.assertNotIn('secret', json.dumps(result))
        self.assertNotIn('/private', json.dumps(result))

    def test_stage_and_process_caps_and_log_size(self):
        result = self.project([f'native_probe_stage instance={i} stage=startup event=failed outcome=early-eof' for i in range(1,101)])
        self.assertEqual(len(result['stages']),64)
        self.assertEqual(len(result['firstProcessOutcomes']),16)
        self.assertLess(len(json.dumps(result)),16384)
        self.assertEqual(self.project(['x' * 2_097_153])['logStatus'],'bounds')

    def test_atomic_private_report_and_failed_diagnostic_write_never_changes_admission(self):
        import os
        from check_real_service_swift_witness import write_diagnostics
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "private.log"
            target = Path(directory) / "diagnostic.json"
            log.write_text('native_probe_stage instance=1 stage=startup event=failed outcome=early-eof\n')
            target.write_text('old')
            os.chmod(target, 0o644)
            self.assertTrue(write_diagnostics(log, target))
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            self.assertEqual(json.loads(target.read_text())['firstProcessOutcomes'][0]['outcome'], 'early-eof')
            self.assertFalse(write_diagnostics(log, Path(directory)/'absent'/'out.json'))
            self.assertEqual(len(list(Path(directory).iterdir())),2)

if __name__ == "__main__":
    unittest.main()
