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
