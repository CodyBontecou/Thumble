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


if __name__ == "__main__":
    unittest.main()
