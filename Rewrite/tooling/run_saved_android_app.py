"""Run both actual saved-map routes; keep invitation-bearing UI logs/results private."""
import argparse
import json
import re
import os
from pathlib import Path
import subprocess
import sys
import time
from check_saved_app_results import verify

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--abi", choices=["x86_64", "arm64-v8a"], default="x86_64")
    args = parser.parse_args()
    assert re.fullmatch(r"emulator-[0-9]{4,5}", os.environ.get("ANDROID_SERIAL", "")), "select the owned QA emulator explicitly"
    temporary = Path(os.environ["RUNNER_TEMP"])
    reports = ROOT / "reports"
    reports.mkdir(exist_ok=True)
    passed = True
    for mode in ("corner", "unsupported"):
        command = [sys.executable, str(ROOT / "tooling/run_mobile_app_probe.py"), "--platform", "android", "--saved-controller", mode, "--", "bash", str(ROOT / "apps/mobile/android/gradlew"), "-p", str(ROOT / "apps/mobile/android"), "--no-daemon", ":app:connectedNativeQaAndroidTest", "--rerun", f"-PreactNativeArchitectures={args.abi}", "-Pandroid.testInstrumentationRunnerArguments.class=com.thumble.rewrite.qa.SavedControllerAppTest"]
        started_ns = time.time_ns()
        with (temporary / ("saved-app-android-" + mode + ".log")).open("wb") as log:
            status = subprocess.call(command, stdout=log, stderr=subprocess.STDOUT)
        result = verify("android", mode, [ROOT / "apps/mobile/android/app/build/outputs/androidTest-results/connected/nativeQa"], command_failed=status != 0, results_not_before_ns=started_ns)
        (reports / ("mobile-app-android-saved-" + mode + ".json")).write_text(json.dumps(result, sort_keys=True) + "\n")
        passed = passed and result["status"] == "passed"
    if not passed: raise SystemExit("saved_app_witness_failed")


if __name__ == "__main__": main()
