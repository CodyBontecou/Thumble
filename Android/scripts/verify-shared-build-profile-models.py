#!/usr/bin/env python3
"""Check portable profile model cases against the native Swift decoder.

The bridge transforms only in-memory fixture documents. --write-fixture saves the
native acceptance/normalized-profile evidence for Android unit/device tests.
"""
import argparse
import base64
import copy
import json
from pathlib import Path
import subprocess
import uuid

PROFILE = "00000000-0000-0000-0000-000000000201"
ELEMENT = "81C296ED-309D-4F05-BB11-F5A2E2027801"
GROUP = "00000000-0000-0000-0000-000000000301"
OTHER = "00000000-0000-0000-0000-000000000999"


def cases():
    base = {"id": PROFILE, "name": "Portable models", "updatedAt": 42,
            "customization": {"elements": [{"id": ELEMENT, "kind": "button", "label": "Owned"}]}}

    def case(name, fields=None, accepted=True, element=None, profile=None):
        raw = copy.deepcopy(base)
        raw.update(profile or {})
        raw["customization"].update(copy.deepcopy(fields or {}))
        raw["customization"]["elements"][0].update(copy.deepcopy(element or {}))
        return name, raw, accepted

    yield case("baseline")
    for field in ("labelOverrides", "buttonCustomizations"):
        value = "Label" if field == "labelOverrides" else {"centerX": .4}
        yield case(field + ".pairs", {field: [ELEMENT, value]})
        yield case(field + ".object", {field: {ELEMENT: value}}, False)
        yield case(field + ".duplicate-alias", {field: [ELEMENT, value, ELEMENT.lower(), value]}, False)
        yield case(field + ".unknown-owner", {field: [OTHER, value]}, False)
        yield case(field + ".odd", {field: [ELEMENT]}, False)

    mirror = {"id": ELEMENT}
    yield case("mirror.defaults", {"customButtons": [mirror]})
    yield case("mirror.null-defaults", {"customButtons": [{**mirror, "label": None, "controlKind": None}]})
    yield case("mirror.label-type", {"customButtons": [{**mirror, "label": 4}]}, False)
    yield case("mirror.kind-mismatch", {"customButtons": [{**mirror, "controlKind": "trigger"}]}, False)
    yield case("mirror.undeclared", {"customButtons": [{"id": OTHER}]}, False)
    yield case("mirror.duplicate", {"customButtons": [mirror, mirror]}, False)
    joystick = {"analogTarget": "left_stick", "sendsDigitalDirections": False, "deadZone": .12,
                "sensitivity": 1., "invertX": False, "invertY": False, "snapToCardinal": False}
    trigger = {"target": "right", "orientation": "vertical", "deadZone": .03,
               "sensitivity": 1., "sendsDigitalButton": False, "digitalThreshold": .5}
    trackpad = {"sensitivity": 1.2, "scrollSensitivity": .85, "tapToClick": True,
                "twoFingerScroll": True, "naturalScrolling": True}
    for kind, field, settings in (("joystick", "joystickOutputSettings", joystick),
                                   ("trigger", "triggerSettings", trigger),
                                   ("trackpad", "trackpadSettings", trackpad)):
        e = {"kind": kind, field: settings}
        m = {**mirror, "controlKind": kind}
        yield case(f"mirror.{kind}.inherits", {"customButtons": [m]}, element=e)
        yield case(f"mirror.{kind}.matches", {"customButtons": [{**m, field: settings}]}, element=e)
        changed = {**settings, "sensitivity": 2.}
        yield case(f"mirror.{kind}.override", {"customButtons": [{**m, field: changed}]}, False, e)
        yield case(f"mirror.{kind}.clamps", {"customButtons": [{**m, field: {**settings, "sensitivity": 100.}}]},
                   element={"kind": kind, field: {**settings, "sensitivity": 99.}})
    yield case("mirror.irrelevant-settings", {"customButtons": [{**mirror, "trackpadSettings": trackpad}]})
    binding = {"gamepadButtons": ["south", "east"]}
    mapping = {direction: binding for direction in ("up", "down", "left", "right")}
    reordered = {direction: {"gamepadButtons": ["east", "south", "east"], "future": True} for direction in mapping}
    yield case("mirror.mapping.set-equality", {"customButtons": [{**mirror, "controlKind": "joystick", "joystickMapping": reordered}]},
               element={"kind": "joystick", "joystickMapping": mapping})
    changed = {**mapping, "up": {"gamepadButtons": []}}
    yield case("mirror.mapping.override", {"customButtons": [{**mirror, "controlKind": "joystick", "joystickMapping": changed}]},
               False, {"kind": "joystick", "joystickMapping": mapping})
    yield case("mirror.mapping.cannot-declare", {"customButtons": [{**mirror, "controlKind": "joystick", "joystickMapping": mapping}]},
               False, {"kind": "joystick"})
    yield case("mirror.mapping.irrelevant-declaration", {"customButtons": [{**mirror, "joystickMapping": mapping}]},
               False, {"joystickMapping": mapping})

    identity = {"kind": "custom", "id": ELEMENT}
    design = {"schemaVersion": 1, "layerOrder": [identity, "system.top_bar_activation"], "groups": [],
              "grid": {"showsGrid": False, "snapToGrid": False, "snapToObjects": True, "gridSize": 16., "snapTolerance": 6.},
              "guides": [], "tags": []}
    group = {"id": GROUP, "name": "Group", "children": [identity], "isLocked": False, "isHidden": False}
    yield case("design.valid", {"designMetadata": design})
    yield case("design.string-identity", {"designMetadata": {**design, "layerOrder": ["custom." + ELEMENT]}})
    yield case("design.system-alias", {"designMetadata": {**design, "layerOrder": ["top_bar_activation"]}})
    yield case("design.uuid-is-builtin", {"designMetadata": {**design, "layerOrder": [ELEMENT]}}, False)
    yield case("design.duplicate-alias", {"designMetadata": {**design, "layerOrder": [identity, "custom." + ELEMENT.lower()]}}, False)
    yield case("design.wrong-kind", {"designMetadata": {**design, "layerOrder": [{"kind": "builtin", "button": ELEMENT}]}}, False)
    yield case("design.bar-is-not-canvas", {"designMetadata": {**design, "layerOrder": ["control_bar_item.settings"]}}, False)
    yield case("design.unknown", {"designMetadata": {**design, "layerOrder": ["custom." + OTHER]}}, False)
    yield case("design.group", {"designMetadata": {**design, "groups": [group]}})
    yield case("design.duplicate-group", {"designMetadata": {**design, "groups": [group, group]}}, False)
    yield case("design.duplicate-child", {"designMetadata": {**design, "groups": [{**group, "children": [identity, identity]}]}}, False)
    yield case("design.unknown-child", {"designMetadata": {**design, "groups": [{**group, "children": ["custom." + OTHER]}]}}, False)
    for field in design:
        missing = copy.deepcopy(design)
        del missing[field]
        yield case("design.missing." + field, {"designMetadata": missing}, False)
    for field in design["grid"]:
        invalid = copy.deepcopy(design)
        invalid["grid"][field] = "wrong-type"
        yield case("design.grid-type." + field, {"designMetadata": invalid}, False)

    asset = {"id": "portable.icon", "name": "Reference", "contentType": "image/png", "byteCount": 0, "role": "reference", "data": None}
    yield case("asset.reference", {"assetLibrary": {"assets": [asset]}})
    for field in ("id", "name", "contentType", "byteCount", "role"):
        missing = copy.deepcopy(asset)
        del missing[field]
        yield case("asset.missing." + field, {"assetLibrary": {"assets": [missing]}}, False)
    yield case("asset.role", {"assetLibrary": {"assets": [{**asset, "role": "future"}]}}, False)
    yield case("canvas.frame", {"deviceCanvas": {"frameID": "iphone-17-pro-portrait"}})
    yield case("canvas.missing-frame", {"deviceCanvas": {}}, False)
    yield case("bar.items", {"controlBarItems": ["profile_menu", "settings", "settings"]})
    yield case("bar.unknown-item", {"controlBarItems": ["future"]}, False)
    yield case("bar.appearance", {"controlBarItemCustomizations": [{"item": "settings", "appearance": {"widthScale": 2.}}]})
    yield case("bar.missing-appearance", {"controlBarItemCustomizations": [{"item": "settings"}]}, False)
    yield case("presentation.defaults", element={"presentation": {}})
    yield case("presentation.unknown", accepted=False, element={"presentation": {"future": None}})
    yield case("presentation.legend-too-long", accepted=False, element={"presentation": {"legend": "x" * 65}})
    yield case("presentation.group-duplicate", accepted=False, element={"presentation": {"groupIDs": ["a", "a"]}})
    yield case("skin-reference.type", accepted=False, profile={"skinReference": {"identifier": 1, "version": "1.0.0"}})
    yield case("background.type", {"backgroundLightColor": {"red": "bad", "green": 0., "blue": 0., "alpha": 1.}}, False)
    templates = Path(__file__).resolve().parents[2] / "Host/fixtures/controller-templates/v1"
    for path in sorted(templates.glob("*.json")):
        template = json.loads(path.read_text()).get("profile")
        if template:
            template.pop("launchTarget", None)
            yield "template." + path.stem, template, True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", type=Path, required=True)
    parser.add_argument("--write-fixture", type=Path)
    args = parser.parse_args()
    results = []
    for name, profile, expected in cases():
        artifact = {"schema": "com.codybontecou.pocketpad.keypad-configuration", "version": 4,
                    "artifactVersion": 1, "exportedAt": 1, "profiles": [profile], "activeProfileID": profile["id"],
                    "defaultProfileID": None, "catalogRevision": {"controllerTemplates": 1, "deviceFrames": 1, "generationSpec": 1}}
        # Use the actual ECMAScript number/string serialization and UTF-16 key
        # ordering, rather than approximating RFC 8785 with Python JSON floats.
        canonicalizer = """
const fs = require('fs'), crypto = require('crypto');
const artifact = JSON.parse(fs.readFileSync(0, 'utf8'));
function canonical(v) {
  if (Array.isArray(v)) return '[' + v.map(canonical).join(',') + ']';
  if (v !== null && typeof v === 'object') return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + canonical(v[k])).join(',') + '}';
  return JSON.stringify(v);
}
const content = {...artifact}; delete content.exportedAt;
artifact.contentHash = {algorithm:'sha256',canonicalization:'rfc8785',value:crypto.createHash('sha256').update(canonical(content)).digest('hex')};
process.stdout.write(JSON.stringify(artifact));
"""
        data = subprocess.run(["node", "-e", canonicalizer], input=json.dumps(artifact), text=True,
                              capture_output=True, check=True, timeout=10).stdout.encode()
        nonce = str(uuid.uuid4())
        request = {"schemaVersion": 1, "invocationID": nonce, "profileArtifactCommand": "validate",
                   "artifactBase64": base64.b64encode(data).decode()}
        result = subprocess.run([str(args.bridge.resolve())], input=json.dumps(request, separators=(",", ":")) + "\n",
                                text=True, capture_output=True, timeout=10, check=False)
        response = json.loads(result.stdout)
        accepted = result.returncode == 0 and response.get("schemaVersion") == 1 and response.get("invocationID", "").lower() == nonce and "profiles" in response
        if not accepted and (result.returncode != 1 or response.get("error", {}).get("code") != "invalid_request"):
            raise SystemExit(f"{name}: unexpected native bridge failure: {response}")
        if accepted != expected:
            raise SystemExit(f"{name}: native verdict {accepted} disagrees with expected {expected}")
        row = {"name": name, "profile": profile, "accepted": accepted}
        if accepted:
            row["normalizedProfile"] = response["profiles"][0]
        results.append(row)
    if args.write_fixture:
        args.write_fixture.parent.mkdir(parents=True, exist_ok=True)
        args.write_fixture.write_text(json.dumps({"schemaVersion": 1, "cases": results}, ensure_ascii=False, indent=2) + "\n")
    print(f"Native Swift decoder confirms {len(results)} portable profile model cases")


if __name__ == "__main__":
    main()
