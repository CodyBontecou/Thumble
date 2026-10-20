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

# The profile-format matrix is a later hand-authored compatibility contract.
formats = repo / "Host/fixtures/profile-formats"
contract = json.loads((formats / "manifest.json").read_text())
assert contract["fixtureVersion"] == 1 and contract["advertisedFormats"] == [4]
assert hashlib.sha256((formats / "v1.json").read_bytes()).hexdigest() == contract["fixtureSHA256"]
matrix = json.loads((formats / "v1.json").read_text())
assert matrix["schemaVersion"] == 1
for key, count in [("negotiations", "negotiationCount"), ("frames", "frameCount")]:
    rows = matrix[key]
    assert len(rows) == contract[count] and len({row["name"] for row in rows}) == len(rows)
    assert all(isinstance(row["allowed"], bool) for row in rows)
print("Profile-format matrix verified:", contract["negotiationCount"], "negotiations,", contract["frameCount"], "frames")

# Explicit v5 destination specimens; not outputs of an activated migration.
owned = repo / "Host/fixtures/owned-configuration/v1"
contract = json.loads((owned / "manifest.json").read_text())
assert contract["fixtureVersion"] == 1
for name, digest in contract["files"].items():
    assert Path(name).name == name
    assert hashlib.sha256((owned / name).read_bytes()).hexdigest() == digest
for name, digest in contract["sources"].items():
    assert not Path(name).is_absolute() and ".." not in Path(name).parts
    assert hashlib.sha256((repo / name).read_bytes()).hexdigest() == digest
rows = json.loads((owned / "cases.json").read_text())["cases"]
assert len(rows) == contract["caseCount"] and len({row["name"] for row in rows}) == len(rows)
document = json.loads((owned / "document.json").read_text())
assert document["version"] == 5 and all(p["profileFormatVersion"] == 5 for p in document["profiles"])
retired = {"skinReference", "skinBaselineCustomization", "landscapeSkinBaselineCustomization", "portraitSkinBaselineCustomization", "landscapeCustomization", "portraitCustomization", "orientationPreference"}
assert all(not (retired & p.keys()) for p in document["profiles"])
print("Explicit owned-configuration contract verified:", contract["caseCount"], "cases")
