#!/usr/bin/env python3
"""Check the Android executable-setting validation matrix against native Swift.

Uses a read-only transform subprocess with fixture data, never a running receiver
or the user's profile store. The same cases live in SharedBuildTest.kt.
"""
import argparse
import copy
import json
from pathlib import Path
import subprocess


def cases():
    settings = {
        "joystickMapping": {direction: {"gamepadButtons": []} for direction in ("up", "down", "left", "right")},
        "joystickOutputSettings": {"analogTarget": "left_stick", "sendsDigitalDirections": False,
                                   "deadZone": .12, "sensitivity": 1., "invertX": False,
                                   "invertY": False, "snapToCardinal": False},
        "triggerSettings": {"target": "right", "orientation": "vertical", "deadZone": .03,
                            "sensitivity": 1., "sendsDigitalButton": False, "digitalThreshold": .5},
        "trackpadSettings": {"sensitivity": 1.2, "scrollSensitivity": .85, "tapToClick": True,
                             "twoFingerScroll": True, "naturalScrolling": True},
    }
    output = {"gamepadButtons": ["south"], "keyboard": {"keyCode": 12, "modifiersRawValue": 1}}
    yield "valid-settings", settings, True
    yield "valid-output", {"output": output, "partOutputs": ["primary", output]}, True
    for field, value in settings.items():
        for key in value:
            missing = copy.deepcopy(settings)
            del missing[field][key]
            yield f"{field}.{key}.missing", missing, False
            wrong = copy.deepcopy(settings)
            wrong[field][key] = "wrong-type"
            yield f"{field}.{key}.wrong", wrong, False
    for name, value in (
        ("output.missing-buttons", {"output": {}}),
        ("output.future-button", {"output": {"gamepadButtons": ["future-gamepad-button"]}}),
        ("output.wrong-modifiers", {"output": {"gamepadButtons": [], "keyboard": {"keyCode": 12, "modifiers": 1}}}),
        ("parts.object", {"partOutputs": {"primary": output}}),
        ("parts.duplicate", {"partOutputs": ["primary", output, "primary", output]}),
        ("parts.future", {"partOutputs": ["future-part", output]}),
        ("parts.odd", {"partOutputs": ["primary"]}),
        ("identity.legacy-null", {"legacySlot": None}),
    ):
        yield name, value, False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    profile = json.loads((root / "Host/fixtures/profile-artifact/v1.json").read_text())["profiles"][0]
    results = []
    for name, fields, expected in cases():
        candidate = copy.deepcopy(profile)
        candidate["customization"]["elements"][0].update(fields)
        request = {
            "schemaVersion": 1, "nowMillis": 1234,
            "document": {"profiles": [candidate], "activeProfileID": candidate["id"],
                         "defaultProfileID": candidate["id"], "keyBindings": {}, "outputBindings": {},
                         "profileKeyBindings": {}, "profileOutputBindings": {}},
            "operation": {"type": "theme.apply", "profileID": candidate["id"],
                          "variant": "primary", "preset": "cavern-glow"},
        }
        result = subprocess.run([str(args.bridge.resolve())], input=json.dumps(request, separators=(",", ":")) + "\n",
                                text=True, capture_output=True, timeout=10, check=False)
        response = json.loads(result.stdout)
        accepted = result.returncode == 0 and response.get("schemaVersion") == 1 and "document" in response
        # A process/bridge failure must not masquerade as expected type rejection.
        if not accepted and (result.returncode != 1 or response.get("error", {}).get("code") != "invalid_request"):
            raise SystemExit(f"{name}: unexpected bridge failure {result.returncode}: {response}")
        results.append({"case": name, "expectedAccepted": expected, "nativeAccepted": accepted})
        if accepted != expected:
            raise SystemExit(f"{name}: native decoder disagrees with the Android matrix")
    if args.output:
        args.output.write_text(json.dumps({"bridge": str(args.bridge.resolve()), "results": results}, indent=2) + "\n")
    print(f"Native Swift decoder agrees on all {len(results)} executable-setting cases")


if __name__ == "__main__":
    main()
