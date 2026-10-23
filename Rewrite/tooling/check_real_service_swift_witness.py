"""Strict Swift Testing witness admission with bounded, non-secret failure metadata."""
import json
import re
from native_control_terminal import decode_native_control_terminal
from native_input_error import decode_native_input_error
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


_STAGE = re.compile(r'native_probe_stage instance=([1-9][0-9]{0,5}) stage=(startup|command-[a-z]|command-other) event=(started|sent|received|failed) outcome=(none|early-eof|owned-watchdog|start-failed|line-bounds|write-failed|process-exit)')
_PROBE_ERRORS = frozenset({"probe_continuous_hold_interrupted", "probe_continuous_hold_inactive", "probe_condition_timeout", "probe_deadline", "probe_service_timeout", "probe_service_unavailable", "probe_service_disconnected", "probe_invalid_service_response", "probe_saved_binding_lost", "probe_saved_pin", "probe_real_service_failed"})


def project_diagnostics(log):
    """Never upload raw Swift failures/stream values: they can contain credentials."""
    result = {"version": 1, "scope": "real-service-swift-probe-diagnostics", "stages": [], "firstProcessOutcomes": [], "firstProbeError": None, "firstNativeInputError": None, "firstControlOutcomeAfterCleanup": None, "logStatus": "unavailable"}
    try:
        path = Path(log)
        if not path.is_file(): return result
        if path.stat().st_size > 2_097_152:
            result["logStatus"] = "bounds"
            return result
        seen = set()
        with path.open("rb") as source: data = source.read(2_097_153)
        if len(data) > 2_097_152:
            result["logStatus"] = "bounds"
            return result
        for raw in data.splitlines():
            if len(raw) > 1024: continue
            try: line = raw.decode("ascii")
            except UnicodeDecodeError: continue
            match = _STAGE.fullmatch(line)
            if match:
                identifier, stage, event, outcome = match.groups()
                if (outcome == "none") != (event != "failed"): continue
                record = {"instance": int(identifier), "stage": stage, "event": event, "outcome": outcome}
                if len(result["stages"]) < 64: result["stages"].append(record)
                if outcome != "none" and identifier not in seen and len(seen) < 16:
                    seen.add(identifier)
                    result["firstProcessOutcomes"].append(record)
            if result["firstProbeError"] is None:
                error = re.fullmatch(r'Error: "(probe_[a-z_]{1,96})"', line)
                if error and error[1] in _PROBE_ERRORS: result["firstProbeError"] = error[1]
            if result["firstNativeInputError"] is None:
                result["firstNativeInputError"] = decode_native_input_error(line)
            if result["firstControlOutcomeAfterCleanup"] is None:
                result["firstControlOutcomeAfterCleanup"] = decode_native_control_terminal(line)
        result["logStatus"] = "projected"
    except OSError:
        pass
    return result


def write_diagnostics(log, destination):
    """Best effort; diagnostic storage must not change witness admission/cleanup."""
    import os
    import tempfile
    staged = None
    try:
        target = Path(destination)
        payload = (json.dumps(project_diagnostics(log), sort_keys=True) + "\n").encode("ascii")
        if len(payload) > 16384: return False
        with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.' + target.name + '.', delete=False) as output:
            staged = Path(output.name)
            os.fchmod(output.fileno(), 0o600)
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(staged, target)
        return True
    except OSError:
        return False
    finally:
        if staged is not None:
            try: staged.unlink(missing_ok=True)
            except OSError: pass


if __name__ == "__main__":
    arguments = sys.argv[1:]
    if len(arguments) not in {5, 7}: raise SystemExit("real_service_swift_arguments_invalid")
    source, name, count, status, destination = arguments[:5]
    if len(arguments) == 7:
        write_diagnostics(arguments[5], arguments[6])
    result = summarize(source, name, int(count), int(status))
    Path(destination).write_text(json.dumps(result, sort_keys=True) + "\n")
    if result["status"] != "passed":
        raise SystemExit("real_service_swift_witness_failed")
