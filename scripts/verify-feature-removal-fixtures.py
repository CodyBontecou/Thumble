#!/usr/bin/env python3
"""Verify the immutable pre-removal fixtures without regenerating expectations."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent / "Host/fixtures/feature-removal/v1"
manifest = json.loads((root / "manifest.json").read_text())
assert manifest["fixtureVersion"] == 1
for name, expected in manifest["files"].items():
    assert Path(name).name == name
    actual = hashlib.sha256((root / name).read_bytes()).hexdigest()
    assert actual == expected, f"Frozen baseline changed: {name}"
for name, expected in manifest["renders"].items():
    assert Path(name).name == name
    actual = hashlib.sha256((root / "previews" / name).read_bytes()).hexdigest()
    assert actual == expected, f"Frozen native render changed: {name}"
for name, count in [("appearance", "appearanceCases"), ("legacy-profiles", "legacyProfileCases"), ("pending-edits", "pendingEditCases"), ("action-sets", "actionSetCases"), ("migration-cases", "migrationCases")]:
    assert len(json.loads((root / f"{name}.json").read_text())["cases"]) == manifest[count]
print("Frozen feature-removal fixtures verified against checkpoint", manifest["checkpoint"])

# Later native edit oracles are separate from the untouched pre-removal baseline.
repo = root.parents[3]
edits = repo / "Host/fixtures/appearance-edits/v1"
contract = json.loads((edits / "manifest.json").read_text())
assert contract["fixtureVersion"] == 1
assert contract["normalizedColorChannelTolerance"] == 2e-7
assert hashlib.sha256((edits / "fixture.json").read_bytes()).hexdigest() == contract["fixtureSHA256"]
assert hashlib.sha256((repo / contract["nativeGenerator"]).read_bytes()).hexdigest() == contract["nativeGeneratorSHA256"]
oracle = json.loads((edits / "fixture.json").read_text())
assert oracle["schemaVersion"] == 1 and len(oracle["cases"]) == contract["caseCount"]
assert len({case["name"] for case in oracle["cases"]}) == len(oracle["cases"])
expected = {(scheme, action) for scheme in ["light", "dark"] for action in ["base", "left-trigger", "right-trigger", "both-triggers"]}
for case in oracle["cases"]:
    assert len(case["resolutions"]) == 8
    assert {(row["colorScheme"], row["actionSet"]) for row in case["resolutions"]} == expected
    ids = {element["id"].lower() for element in case["profile"]["customization"]["elements"]}
    assert all(set(row["expectedAppearance"]["controls"]) == ids for row in case["resolutions"])
assert sum(len(case["resolutions"]) for case in oracle["cases"]) == contract["resolutionCount"]
print("Native appearance edit oracle verified:", contract["caseCount"], "cases,", contract["resolutionCount"], "results")
