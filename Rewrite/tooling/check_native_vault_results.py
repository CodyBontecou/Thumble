"""Require actual provider test execution; build-only/empty/skipped evidence fails."""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

IOS_CASE = "actualDeviceKeychainPersistsSyntheticCredentialAcrossVaultInstances"
ANDROID_CASE = "realAndroidKeystorePersistsAndDetectsTampering"
ANDROID_CLASS = "com.thumble.rewrite.input.PhoneCredentialDeviceTest"

def require(condition, message):
    if not condition:
        raise ValueError(message)

def ios(tests, summary):
    require(summary["result"] == "Passed" and summary["failedTests"] == 0 and summary["passedTests"] > 0, "iOS run did not pass")
    matches = []
    def walk(nodes):
        for node in nodes:
            name = node["name"].removesuffix("()")
            identifier = node.get("nodeIdentifier", "").split("/")[-1].removesuffix("()")
            if node["nodeType"] == "Test Case" and (name == IOS_CASE or identifier == IOS_CASE):
                matches.append(node)
            walk(node.get("children", []))
    walk(tests["testNodes"])
    require(len(matches) == 1 and matches[0].get("result") == "Passed", "Keychain provider case missing, skipped or failed")
    return {"provider": "iOS Keychain", "case": IOS_CASE, "result": "Passed", "passedTests": summary["passedTests"]}

def android(paths):
    matches = []
    total = 0
    for path in paths:
        root = ET.parse(path).getroot()
        for case in root.iter("testcase"):
            total += 1
            require(not any(case.find(tag) is not None for tag in ["failure", "error"]), "Android test failure")
            if case.get("classname") == ANDROID_CLASS and case.get("name") == ANDROID_CASE:
                matches.append(case)
    require(len(matches) == 1 and matches[0].find("skipped") is None, "Keystore provider case missing or skipped")
    return {"provider": "Android Keystore", "case": ANDROID_CASE, "result": "Passed", "totalCases": total}

if __name__ == "__main__":
    if sys.argv[1] == "ios" and len(sys.argv) == 4:
        result = ios(json.loads(Path(sys.argv[2]).read_text()), json.loads(Path(sys.argv[3]).read_text()))
    elif sys.argv[1] == "android" and len(sys.argv) == 3:
        result = android(Path(sys.argv[2]).rglob("TEST-*.xml"))
    else:
        raise SystemExit("expected ios tests.json summary.json OR android results-directory")
    print(json.dumps(result, sort_keys=True))
