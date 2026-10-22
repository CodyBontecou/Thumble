"""Strict Swift Testing witness admission with bounded, non-secret failure metadata."""
import json
from pathlib import Path
import sys

WITNESSES = {
    "actualRealServiceCatalogReadPreservesNativePhoneHeldInput": 2,
    "actualPhoneTouchCrossesTlsAndNativeIpcThenRetiresAndReconnectsNeutral": 5,
    "actualSavedControllerServiceMapDeliversNativeInputAndRejectsUnsupportedProfile": 3,
    "actualSavedAnalogServiceMapDeliversCombinedNativeInputAndRejectsUnsupportedProfile": 3,
}
MODES = {"tls", "udp", "udp-blackhole", "renewal-udp", "renewal-tls-fallback", "tls-fallback", "unsupported"}
EVENTS = {"runStarted", "runEnded", "testStarted", "testEnded", "testCaseStarted", "testCaseEnded"}


def summarize(source, name, count, status):
    if name not in WITNESSES or count != WITNESSES[name]:
        raise ValueError("real_service_swift_arguments_invalid")
    result = {"platform": "swift", "witness": name, "status": "failed", "failureStage": "no_stream"}
    try:
        path = Path(source)
        if not path.is_file():
            return result
        if path.stat().st_size > 2_097_152:
            result["failureStage"] = "stream_bounds"
            return result
        records = [json.loads(line) for line in path.read_text().splitlines() if line]
        if len(records) > 4096 or not all(type(r) is dict and r.get("version") == 0 for r in records):
            result["failureStage"] = "stream_schema"
            return result
        tests = [r["payload"] for r in records if r.get("kind") == "test"]
        result["failureStage"] = "no_test"
        if len(tests) != 1 or tests[0]["name"].split("(")[0] != name:
            return result
        test_id = tests[0]["id"]
        cases = {c["id"] for c in tests[0]["_testCases"]}
        result["failureStage"] = "wrong_case_count"
        if len(cases) != count:
            return result
        events = [r["payload"] for r in records if r.get("kind") == "event"]
        kinds = [e["kind"] for e in events]
        issues = [e for e in events if e["kind"] not in EVENTS]
        if issues:
            result["failureStage"] = "issue_or_skip"
            failed_modes = set()
            known_errors = set()
            for event in issues:
                display = event.get("_testCase", {}).get("displayName", "")
                if type(display) is str and display in {'"' + m + '"' for m in MODES}:
                    failed_modes.add(display[1:-1])
                for message in event.get("messages", []):
                    text = message.get("text", "")
                    # Equality only: never copy arbitrary XCTest errors, paths or arguments.
                    if text in ("Caught error: closed", "Caught error: .closed"): known_errors.add("probe_closed")
                    elif text in ("Caught error: rejected", "Caught error: .rejected"): known_errors.add("rejected")
                    elif type(text) is str and text.startswith("Expectation failed:"):
                        known_errors.add("expectation_failed")
            if failed_modes: result["failedModes"] = sorted(failed_modes)
            if known_errors: result["knownErrors"] = sorted(known_errors)
            return result
        result["failureStage"] = "exit_nonzero"
        if status != 0:
            return result
        result["failureStage"] = "incomplete_run"
        for kind in ("runStarted", "runEnded", "testStarted", "testEnded"):
            if kinds.count(kind) != 1:
                return result
        if not all(e.get("testID", test_id) == test_id for e in events):
            return result
        for kind in ("testCaseStarted", "testCaseEnded"):
            observed = [e["_testCase"]["id"] for e in events if e["kind"] == kind]
            if len(observed) != count or set(observed) != cases:
                return result
        for event in events:
            if event["kind"] in ("testEnded", "runEnded"):
                if not any(m.get("symbol") == "pass" for m in event.get("messages", [])):
                    return result
        result.pop("failureStage")
        result.update(status="passed", cases=count, skipped=0, failures=0)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        result["failureStage"] = "stream_schema"
    return result


if __name__ == "__main__":
    source, name, count, status, destination = sys.argv[1:]
    result = summarize(source, name, int(count), int(status))
    Path(destination).write_text(json.dumps(result, sort_keys=True) + "\n")
    if result["status"] != "passed":
        raise SystemExit("real_service_swift_witness_failed")
