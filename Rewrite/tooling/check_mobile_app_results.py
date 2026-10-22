"""Fail closed if headless app witnesses did not actually execute."""
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ANDROID = {
    "touchSurfaceHasNoReactRootAncestor",
    "connectedEngineSurvivesInstallationCapturesTouchesAndReleasesOnRemoval",
    "everyActualSurfaceHitMatchesTheSharedReportAndReleases",
    "sixNativeTouchesAndCancellationWorkWhileActualJsQueueIsBlocked",
    "rotationReleasesOldSurfaceAndReopensNeutral",
    "backgroundingReleasesCapturedNativeTouches",
    "sleepingReleasesNativeTouchesAndWakingStartsNeutral",
    "doneWithASecondFingerReleasesTheHeldController",
}

def check_android(path):
    cases = []
    for file in Path(path).rglob("TEST-*.xml"):
        root = ET.parse(file).getroot()
        cases.extend(root.iter("testcase"))
    assert len(cases) == len(ANDROID), "expected exactly eight app tests on one emulator"
    assert {c.get("name") for c in cases} == ANDROID, "missing/unexpected app cases"
    assert all(c.get("classname") == "com.thumble.rewrite.qa.PracticeInputTest" for c in cases)
    assert all(not any(c.find(tag) is not None for tag in ("skipped", "failure", "error")) for c in cases), "app test failure or skip"

def check_ios(path, tests_path):
    summary = json.loads(Path(path).read_text())
    assert summary["totalTestCount"] == 3, "expected all three UIKit app tests"
    assert summary["passedTests"] == 3 and summary["failedTests"] == 0
    assert summary["skippedTests"] == 0, "UIKit app tests skipped"
    assert summary["result"] == "Passed", "UIKit app run did not pass"
    expected = {"testConnectedEngineSurvivesInitialInstallationAndReleasesOnRemoval", "testActualReactRootDoesNotOwnTouchSurface", "testHiddenAndRemovedAnchorsReleaseAndStopIntercepting"}
    cases = []
    def walk(nodes):
        for node in nodes:
            if node["nodeType"] == "Test Case":
                cases.append(node)
            walk(node.get("children", []))
    walk(json.loads(Path(tests_path).read_text())["testNodes"])
    assert len(cases) == 3 and {c["name"].removesuffix("()") for c in cases} == expected, "wrong/missing UIKit witnesses"
    assert all(c.get("result") == "Passed" for c in cases)

if __name__ == "__main__":
    platform, *paths = sys.argv[1:]
    {"android": check_android, "ios": check_ios}[platform](*paths)
    print(f"Verified {platform} native app witnesses executed without skips")
