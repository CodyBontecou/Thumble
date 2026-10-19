#!/usr/bin/env python3
"""Verify a packaged Thumble Link CLI against a private child-process home, with no input output."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("binary_directory", type=Path)
args = parser.parse_args()
binary = args.binary_directory.resolve() / "thumble"
for name in ("thumble", "thumble-cli-bridge", "thumble-bridge"):
    assert os.access(args.binary_directory.resolve() / name, os.X_OK), f"Missing executable: {name}"
root = Path(__file__).resolve().parent.parent
fixture = root / "Tests/Fixtures/ThumbleLink/warrior.txt"

with tempfile.TemporaryDirectory(prefix="thumble-link-cli-") as temporary:
    private_home = Path(temporary) / "account"
    private_home.mkdir(mode=0o700)
    # Only test subprocesses see this home; the caller's shell and real account are unchanged.
    environment = dict(os.environ, HOME=str(private_home))

    def run(*arguments, data=None, success=True):
        result = subprocess.run([str(binary), *arguments], input=data, text=True,
                                capture_output=True, env=environment, timeout=60)
        if success:
            assert result.returncode == 0, result.stderr
        else:
            assert result.returncode != 0, result.stdout
        return result

    def export():
        return json.loads(run("profile", "export", "--all").stdout)

    initial = export()
    review = json.loads(run("wow", "import", str(fixture), "--dry-run", "--json").stdout)
    assert not review["imported"] and not review["isRefresh"]
    assert initial["profiles"] == export()["profiles"], "dry run changed profiles"
    imported = json.loads(run("wow", "import", "-", "--no-select", "--json", data=fixture.read_text()).stdout)
    assert imported["imported"] and not imported["isRefresh"]
    first = export()
    assert len(first["profiles"]) == len(initial["profiles"]) + 1
    assert first["activeProfileID"] == initial["activeProfileID"]
    assert first["defaultProfileID"] == initial["defaultProfileID"]
    profile = next(p for p in first["profiles"] if p["id"].lower() == imported["profileID"].lower())
    assert "thumbleLink" in profile
    first_element = next(e for e in profile["customization"]["elements"] if e["output"]["keyboard"]["keyCode"] == 18)
    run("profile", "rename", profile["id"], "Warrior Phone")
    # Use the authority's supported profile import to simulate an editor move.
    # Legacy CLI element geometry writes are intentionally blocked under Rust authority.
    moved = export()
    moved_profile = next(p for p in moved["profiles"] if p["id"] == profile["id"])
    for collection in ("elements", "customButtons"):
        for element in moved_profile["customization"].get(collection, []):
            if element["id"] == first_element["id"]:
                element["layout"]["centerX"] = 0.24
                element["layout"]["centerY"] = 0.54
    native = {key: moved[key] for key in ("schema", "version", "exportedAt", "profileKeyBindings", "profileOutputBindings")}
    native.update(profiles=[moved_profile], activeProfileID=profile["id"], defaultProfileID=None)
    for field in ("profileKeyBindings", "profileOutputBindings"):
        native[field] = {key: value for key, value in native[field].items() if key.lower() == profile["id"].lower()}
    moved_file = Path(temporary) / "moved.json"
    moved_file.write_text(json.dumps(native))
    run("profile", "import", str(moved_file), "--no-select")
    before_refresh = next(p for p in export()["profiles"] if p["id"] == profile["id"])
    before_layout = next(e["layout"] for e in before_refresh["customization"]["elements"] if e["id"] == first_element["id"])
    snapshot = json.loads(fixture.read_text().removeprefix("THUMBLELINK1:"))
    snapshot["actions"][0]["keys"] = ["E"]
    snapshot["actions"][0]["label"] = "New Ability"
    refreshed = json.loads(run("wow", "import", "-", "--json", data=json.dumps(snapshot)).stdout)
    assert refreshed["isRefresh"] and refreshed["profileName"] == "Warrior Phone"
    after = export()
    assert len(after["profiles"]) == len(first["profiles"])
    updated = next(p for p in after["profiles"] if p["id"] == profile["id"])
    updated_element = next(e for e in updated["customization"]["elements"] if e["id"] == first_element["id"])
    assert updated_element["layout"] == before_layout
    assert updated_element["output"]["keyboard"]["keyCode"] == 14
    assert updated_element["label"] == "New Ability"
    assert after["defaultProfileID"] == initial["defaultProfileID"]
    run("wow", "import", "-", data="x" * (256 * 1024 + 1), success=False)
    run("wow", "import", "-", data="{}", success=False)
    assert export()["profiles"] == after["profiles"], "invalid import changed profiles"
print("Thumble Link CLI checks passed: review, file/stdin import, selection, refresh, geometry, metadata, and invalid input.")
