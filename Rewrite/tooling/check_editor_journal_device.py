"""Accept exactly the named successful synthetic Android private journal provider case."""
import json
from itertools import islice
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

CLASS = "com.thumble.rewrite.input.EditorJournalDeviceTest"
CASE = "actualAtomicFileReopenFaultsCorruptionAndAliases"

def verify(paths):
    paths = list(islice(paths, 2))
    if len(paths) != 1:
        raise ValueError("editor_provider_result_count")
    path = paths[0]
    with path.open("rb") as stream:
        content = stream.read(512 * 1024 + 1)
    if len(content) > 512 * 1024:
        raise ValueError("editor_provider_result_oversize")
    try:
        text = content.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        raise ValueError("editor_provider_encoding_invalid") from None
    if "<!" in text or "\x00" in text:
        raise ValueError("editor_provider_markup_invalid")
    root = ET.fromstring(text)
    if any(node.tag in {"skipped", "failure", "error"} for node in root.iter()):
        raise ValueError("editor_provider_failure_node")
    if root.tag != "testsuite" or any(root.get(key) != value for key, value in {"tests": "1", "failures": "0", "errors": "0", "skipped": "0"}.items()):
        raise ValueError("editor_provider_counts_invalid")
    cases = list(root.iter("testcase"))
    if len(cases) != 1 or cases[0].get("classname") != CLASS or cases[0].get("name") != CASE or any(cases[0].find(tag) is not None for tag in ["skipped", "failure", "error"]):
        raise ValueError("editor_provider_case_invalid")
    return {"kind": "editor-journal-provider", "version": 1, "case": CASE, "cases": 1, "failures": 0, "skips": 0, "result": "passed"}

if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("expected_result_directory")
    try:
        result = verify(Path(sys.argv[1]).rglob("TEST-*.xml"))
    except (ValueError, OSError, ET.ParseError):
        print(json.dumps({"kind": "editor-journal-provider", "version": 1, "result": "rejected", "category": "invalid-evidence"}, sort_keys=True))
        raise SystemExit(1)
    print(json.dumps(result, sort_keys=True))
