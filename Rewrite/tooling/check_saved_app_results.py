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


def verify(platform, mode, paths):
    assert platform in ("ios", "android") and mode in ("corner", "unsupported")
    result = {"platform": platform, "mode": mode, "status": "failed", "scope": "actual-react-saved-map"}
    try:
        if platform == "ios": check_ios(*paths)
        else: check_android(*paths)
        result.update(status="passed", cases=1, skipped=0, failures=0)
    except (AssertionError, OSError, ValueError, KeyError, TypeError, ET.ParseError):
        pass
    return result


if __name__ == "__main__":
    platform, mode, destination, *paths = sys.argv[1:]
    result = verify(platform, mode, paths)
    Path(destination).write_text(json.dumps(result, sort_keys=True) + "\n")
    if result["status"] != "passed": raise SystemExit("saved_app_witness_failed")
