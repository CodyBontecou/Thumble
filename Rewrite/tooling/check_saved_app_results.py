"""Admit exact actual-route cases; never publish raw UI logs or attachments."""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def bounded(path):
    source = Path(path)
    if source.stat().st_size > 2_097_152:
        raise ValueError("saved_app_results_invalid")
    return source.read_bytes()


def check_ios(summary_path, cases_path):
    summary = json.loads(bounded(summary_path))
    assert summary["totalTestCount"] == 1 and summary["passedTests"] == 1
    assert summary["failedTests"] == 0 and summary["skippedTests"] == 0 and summary["result"] == "Passed"
    cases = []
    pending = list(json.loads(bounded(cases_path))["testNodes"])
    count = 0
    while pending:
        count += 1
        assert count <= 256
        node = pending.pop()
        if node["nodeType"] == "Test Case": cases.append(node)
        pending.extend(node.get("children", []))
    assert len(cases) == 1 and cases[0]["name"].removesuffix("()") == "testActualReactSavedMapSummaryCornerAndDismissal"
    assert cases[0]["result"] == "Passed"


def check_android(path):
    source = Path(path)
    files = list(source.rglob("TEST-*.xml")) if source.is_dir() else [source]
    assert 1 <= len(files) <= 4
    roots = [ET.fromstring(bounded(file)) for file in files]
    cases = [case for root in roots for case in root.iter("testcase")]
    assert len(cases) == 1
    assert cases[0].get("classname") == "com.thumble.rewrite.qa.SavedControllerAppTest"
    assert cases[0].get("name") == "actualSavedMapSummaryCornerAndDismissal"
    assert not any(cases[0].find(tag) is not None for tag in ("skipped", "failure", "error"))
    for root in roots:
        for suite in root.iter("testsuite"):
            assert int(suite.attrib["tests"]) == 1
            assert all(int(suite.get(k, "0")) == 0 for k in ("failures", "errors", "skipped"))


ASSERTIONS = {
    "saved_controller_device_asleep": "device-asleep",
    "saved_controller_app_not_visible": "app-not-visible",
    "saved_controller_rotation_unsettled": "orientation",
    "saved_controller_pairing_dialog_missing": "pairing-form",
    "saved_controller_unsupported_not_reported": "unsupported-result",
    "saved_controller_connection_not_ready": "connection-ready",
    "saved_controller_touch_injection_failed": "touch-injection",
    "saved_controller_overlaps_header": "header-geometry",
    "saved_controller_control_overlaps_done": "done-geometry",
    "invitation_entry_empty": "invitation-entry",
    "Native saved controller did not become ready": "connection-ready",
    "Pair action was unavailable after keyboard dismissal": "pair-action",
}


def failure_diagnostic(platform, paths, command_failed, export_failed, results_not_before_ns):
    # The case identity is admitted independently; arbitrary source labels/messages
    # never become artifact fields. No inference about the native first cause.
    result = {"stage": "result-validation", "case": "not-evaluated", "failureCategory": "invalid-results"}
    if export_failed:
        return {**result, "stage": "result-export", "failureCategory": "export-failed"}
    try:
        messages = []
        assertion_evidence = False
        if platform == "ios":
            summary = json.loads(bounded(paths[0]))
            pending = list(json.loads(bounded(paths[1]))["testNodes"])
            cases = []
            count = 0
            while pending:
                count += 1
                if count > 256: raise ValueError("bounded")
                node = pending.pop()
                if node["nodeType"] == "Test Case": cases.append(node)
                pending.extend(node.get("children", []))
            if len(cases) != 1 or cases[0].get("name", "").removesuffix("()") != "testActualReactSavedMapSummaryCornerAndDismissal":
                return result
            case = cases[0]
            failed = case.get("result") == "Failed"
            skipped = case.get("result") == "Skipped"
            failures = summary.get("testFailures", [])
            if not isinstance(failures, list) or len(failures) > 256: return result
            assertion_evidence = (failed and all(type(summary.get(key)) is int for key in ("totalTestCount", "passedTests", "failedTests", "skippedTests")) and summary.get("totalTestCount") == 1 and summary.get("passedTests") == 0 and summary.get("failedTests") == 1 and summary.get("skippedTests") == 0 and summary.get("result") == "Failed")
            messages = [item.get("failureText", "") for item in failures if isinstance(item, dict)] if assertion_evidence else []
        else:
            source = Path(paths[0])
            files = list(source.rglob("TEST-*.xml")) if source.is_dir() else [source]
            if not 1 <= len(files) <= 4: return result
            if results_not_before_ns is not None and any(file.stat().st_mtime_ns < results_not_before_ns for file in files):
                return {**result, "failureCategory": "stale-results"}
            roots = [ET.fromstring(bounded(file)) for file in files]
            cases = [case for root in roots for case in root.iter("testcase")]
            if len(cases) != 1 or cases[0].get("classname") != "com.thumble.rewrite.qa.SavedControllerAppTest" or cases[0].get("name") != "actualSavedMapSummaryCornerAndDismissal": return result
            case = cases[0]
            failed = any(case.find(tag) is not None for tag in ("failure", "error"))
            skipped = case.find("skipped") is not None
            messages = [item.get("message", "") for tag in ("failure", "error") for item in case.findall(tag)] if failed and not skipped else []
        result.update(stage="test-case", case="saved-controller", failureCategory="test-skipped" if skipped else "test-failed" if failed else "command-failed" if command_failed else "invalid-results")
        # Match only an exact source-authored prefix, never a substring inside
        # an untrusted exception, stack, attachment, URL or synthetic invitation.
        for message in messages:
            if not isinstance(message, str) or len(message) > 65536: continue
            for marker, fixed in ASSERTIONS.items():
                if message == marker or message.startswith(marker + " expected:"):
                    result.update(stage="assertion", failureCategory="assertion", assertion=fixed)
                    return result
        return result
    except (AssertionError, OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError, IndexError, ET.ParseError):
        return {**result, "stage": "app-command" if command_failed else "result-validation", "failureCategory": "command-failed" if command_failed else "results-unavailable"}


def verify(platform, mode, paths, *, command_failed=False, export_failed=False, results_not_before_ns=None):
    assert platform in ("ios", "android") and mode in ("corner", "unsupported")
    result = {"platform": platform, "mode": mode, "status": "failed", "scope": "actual-react-saved-map"}
    try:
        if platform == "ios": check_ios(*paths)
        else: check_android(*paths)
        if not command_failed and not export_failed:
            result.update(status="passed", cases=1, skipped=0, failures=0)
    except (AssertionError, OSError, ValueError, KeyError, TypeError, AttributeError, RecursionError, ET.ParseError):
        pass
    if result["status"] == "failed":
        result["diagnostic"] = failure_diagnostic(platform, paths, command_failed, export_failed, results_not_before_ns)
    return result


if __name__ == "__main__":
    platform, mode, destination, *paths = sys.argv[1:]
    command_failed = "--command-failed" in paths
    export_failed = "--export-failed" in paths
    paths = [item for item in paths if item not in ("--command-failed", "--export-failed")]
    result = verify(platform, mode, paths, command_failed=command_failed, export_failed=export_failed)
    Path(destination).write_text(json.dumps(result, sort_keys=True) + "\n")
    if result["status"] != "passed": raise SystemExit("saved_app_witness_failed")
