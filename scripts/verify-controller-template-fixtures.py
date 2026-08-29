#!/usr/bin/env python3
"""Regenerate and byte-verify canonical controller template fixtures."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid
from collections.abc import Callable

REPOSITORY = Path(__file__).resolve().parents[1]
CATALOG_PATH = REPOSITORY / "docs/mcp/controller-templates-v1.json"
FIXTURE_DIRECTORY = REPOSITORY / "Host/fixtures/controller-templates/v1"
INVOCATION_ID = "aaaaaaaa-bbbb-5ccc-8ddd-eeeeeeeeeeee"
CATALOG_SCHEMA = "com.codybontecou.thumble.controller-templates"
MANIFEST_SCHEMA = "com.codybontecou.thumble.controller-template-fixture-manifest"
CATALOG_FIELDS = ("schema", "version", "templates")
TEMPLATE_FIELDS = ("id", "name", "description", "revision", "customElementIDCount")
FIXTURE_FIELDS = {
    "fixtureVersion",
    "templateID",
    "revision",
    "displayName",
    "canonicalProfileID",
    "customElementIDs",
    "profile",
    "profileKeyBindings",
    "profileOutputBindings",
}
EXPECTED_TEMPLATE_IDS = (
    "productivityStarter",
    "productivityOneHandedLeft",
    "productivityOneHandedRight",
    "nes",
    "snes",
    "nintendo64",
    "gameCube",
    "gameBoy",
    "gameBoyAdvance",
    "genesisSixButton",
    "saturn",
    "dreamcast",
    "arcadeStick",
    "psp",
    "playStation",
    "xbox",
    "softWhite",
)
SAFE_TEMPLATE_ID = re.compile(r"[a-z][A-Za-z0-9]*\Z")


def encoded(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def zero_updated_at(value: object) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "updatedAt":
                value[key] = 0
            else:
                zero_updated_at(child)
    elif isinstance(value, list):
        for child in value:
            zero_updated_at(child)


def validate_zero_updated_at(value: object, *, template_id: str) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "updatedAt" and child != 0:
                raise RuntimeError(f"{template_id}: nonzero updatedAt in fixture")
            validate_zero_updated_at(child, template_id=template_id)
    elif isinstance(value, list):
        for child in value:
            validate_zero_updated_at(child, template_id=template_id)


def run(command: list[str], *, home: Path) -> subprocess.CompletedProcess[str]:
    environment = os.environ.copy()
    environment["HOME"] = str(home)
    environment["TMPDIR"] = str(home / "tmp")
    return subprocess.run(
        command,
        env=environment,
        text=True,
        capture_output=True,
        timeout=60,
        check=True,
    )


def validate_catalog(catalog: object) -> list[dict[str, object]]:
    if not isinstance(catalog, dict) or tuple(catalog) != CATALOG_FIELDS:
        raise RuntimeError(f"controller template catalog fields/order must be {CATALOG_FIELDS}")
    if catalog["schema"] != CATALOG_SCHEMA or catalog["version"] != 1:
        raise RuntimeError("controller template catalog schema/version is unsupported")
    entries = catalog["templates"]
    if not isinstance(entries, list) or len(entries) != len(EXPECTED_TEMPLATE_IDS):
        raise RuntimeError("controller template catalog must contain exactly 17 entries")

    validated: list[dict[str, object]] = []
    for expected_id, raw_entry in zip(EXPECTED_TEMPLATE_IDS, entries):
        if not isinstance(raw_entry, dict) or tuple(raw_entry) != TEMPLATE_FIELDS:
            raise RuntimeError(f"{expected_id}: catalog entry fields/order must be {TEMPLATE_FIELDS}")
        template_id = raw_entry["id"]
        if template_id != expected_id or not isinstance(template_id, str) or not SAFE_TEMPLATE_ID.fullmatch(template_id):
            raise RuntimeError(f"unsafe or out-of-order controller template ID: {template_id!r}")
        if Path(f"{template_id}.json").name != f"{template_id}.json":
            raise RuntimeError(f"unsafe fixture filename for {template_id}")
        for field in ("name", "description"):
            value = raw_entry[field]
            if not isinstance(value, str) or not value or any(
                ord(character) < 32 or ord(character) == 127 for character in value
            ):
                raise RuntimeError(f"{template_id}: invalid {field}")
        revision = raw_entry["revision"]
        custom_count = raw_entry["customElementIDCount"]
        if type(revision) is not int or revision < 1:
            raise RuntimeError(f"{template_id}: invalid revision")
        if type(custom_count) is not int or not 0 <= custom_count <= 128:
            raise RuntimeError(f"{template_id}: invalid customElementIDCount")
        validated.append(raw_entry)
    return validated


def fixture_for(binary_directory: Path, entry: dict[str, object], work: Path) -> dict[str, object]:
    template_id = str(entry["id"])
    display_name = str(entry["name"])
    home = work / template_id / "home"
    home.mkdir(parents=True, mode=0o700)
    (home / "tmp").mkdir(mode=0o700)
    if stat.S_IMODE(home.stat().st_mode) != 0o700:
        raise RuntimeError(f"isolated HOME is not mode 0700: {home}")

    thumble = binary_directory / "thumble"
    run(
        [
            str(thumble),
            "template",
            "install",
            template_id,
            "--name",
            display_name,
            "--invocation-id",
            INVOCATION_ID,
        ],
        home=home,
    )
    artifact_path = work / template_id / "artifact.json"
    run(
        [
            str(thumble),
            "profile",
            "export",
            display_name,
            "--output",
            str(artifact_path),
        ],
        home=home,
    )
    artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
    if len(artifact["profiles"]) != 1:
        raise RuntimeError(f"{template_id}: profile export did not contain exactly one profile")
    profile = artifact["profiles"][0]
    profile_id = profile["id"]
    key_maps = artifact["profileKeyBindings"]
    output_maps = artifact["profileOutputBindings"]
    if set(key_maps) != {profile_id} or set(output_maps) != {profile_id}:
        raise RuntimeError(f"{template_id}: exported per-profile maps do not match profile ID")

    custom_ids = [button["id"] for button in profile["customization"].get("customButtons", [])]
    expected_count = int(entry["customElementIDCount"])
    if len(custom_ids) != expected_count or len(set(custom_ids)) != expected_count:
        raise RuntimeError(f"{template_id}: expected {expected_count} ordered custom IDs, got {len(custom_ids)}")

    zero_updated_at(profile)
    return {
        "fixtureVersion": 1,
        "templateID": template_id,
        "revision": int(entry["revision"]),
        "displayName": display_name,
        "canonicalProfileID": profile_id,
        "customElementIDs": custom_ids,
        "profile": profile,
        "profileKeyBindings": key_maps[profile_id],
        "profileOutputBindings": output_maps[profile_id],
    }


def canonical_uuid(value: object, *, context: str) -> str:
    if not isinstance(value, str):
        raise RuntimeError(f"{context}: UUID must be a string")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise RuntimeError(f"{context}: invalid UUID") from error
    if str(parsed).upper() != value.upper():
        raise RuntimeError(f"{context}: UUID is not canonical")
    return value


def validate_fixture(fixture: object, entry: dict[str, object]) -> None:
    template_id = str(entry["id"])
    if not isinstance(fixture, dict) or set(fixture) != FIXTURE_FIELDS:
        raise RuntimeError(f"{template_id}: fixture fields are not exact")
    if (
        fixture["fixtureVersion"] != 1
        or fixture["templateID"] != template_id
        or fixture["revision"] != entry["revision"]
        or fixture["displayName"] != entry["name"]
    ):
        raise RuntimeError(f"{template_id}: fixture metadata mismatch")
    profile_id = canonical_uuid(fixture["canonicalProfileID"], context=f"{template_id} profile")
    custom_ids_raw = fixture["customElementIDs"]
    if not isinstance(custom_ids_raw, list):
        raise RuntimeError(f"{template_id}: customElementIDs must be an array")
    custom_ids = [canonical_uuid(value, context=f"{template_id} custom ID") for value in custom_ids_raw]
    if len(custom_ids) != entry["customElementIDCount"] or len(set(custom_ids)) != len(custom_ids):
        raise RuntimeError(f"{template_id}: customElementIDs count/uniqueness mismatch")

    profile = fixture["profile"]
    if not isinstance(profile, dict) or profile.get("id") != profile_id or profile.get("name") != entry["name"]:
        raise RuntimeError(f"{template_id}: fixture profile identity mismatch")
    for structure_name in ("customization", "landscapeCustomization", "portraitCustomization"):
        structure = profile.get(structure_name)
        if structure is None:
            continue
        if not isinstance(structure, dict):
            raise RuntimeError(f"{template_id}: {structure_name} must be an object")
        controls = structure.get("customButtons")
        elements = structure.get("elements")
        if not isinstance(controls, list) or not isinstance(elements, list):
            raise RuntimeError(f"{template_id}: malformed {structure_name} controls/elements")
        control_ids = [control.get("id") if isinstance(control, dict) else None for control in controls]
        if control_ids != custom_ids:
            raise RuntimeError(f"{template_id}: {structure_name} custom controls differ from declaration")
        element_ids = [element.get("id") if isinstance(element, dict) else None for element in elements]
        if any(element_ids.count(custom_id) != 1 for custom_id in custom_ids):
            raise RuntimeError(f"{template_id}: {structure_name} custom elements differ from declaration")
    if "customization" not in profile:
        raise RuntimeError(f"{template_id}: primary customization is missing")
    validate_zero_updated_at(profile, template_id=template_id)


def build_manifest(entries: list[dict[str, object]], generated: dict[str, bytes]) -> bytes:
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "version": 1,
        "fixtures": [
            {
                "templateID": str(entry["id"]),
                "revision": int(entry["revision"]),
                "file": f"{entry['id']}.json",
                "sha256": hashlib.sha256(generated[str(entry["id"])]).hexdigest(),
            }
            for entry in entries
        ],
    }
    return encoded(manifest)


def expected_names(entries: list[dict[str, object]]) -> set[str]:
    return {f"{entry['id']}.json" for entry in entries} | {"manifest.json"}


def verify_directory(
    directory: Path,
    entries: list[dict[str, object]],
    generated: dict[str, bytes],
    manifest_bytes: bytes,
) -> None:
    names = {path.name for path in directory.iterdir()} if directory.is_dir() else set()
    expected = expected_names(entries)
    if names != expected:
        raise RuntimeError(
            f"fixture set mismatch; missing={sorted(expected - names)}, extra={sorted(names - expected)}"
        )
    for entry in entries:
        template_id = str(entry["id"])
        path = directory / f"{template_id}.json"
        if not path.is_file() or path.is_symlink() or path.read_bytes() != generated[template_id]:
            raise RuntimeError(f"fixture differs from real materializer output: {path}")
        validate_fixture(json.loads(path.read_text(encoding="utf-8")), entry)
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file() or manifest_path.is_symlink() or manifest_path.read_bytes() != manifest_bytes:
        raise RuntimeError(f"fixture hash manifest differs: {manifest_path}")


def fsync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def exchange_directories(left: Path, right: Path) -> None:
    """Atomically swap two sibling directories on Darwin or Linux."""
    libc = ctypes.CDLL(None, use_errno=True)
    at_fdcwd = -2 if sys.platform == "darwin" else -100
    left_bytes = os.fsencode(left)
    right_bytes = os.fsencode(right)
    if sys.platform == "darwin":
        rename = libc.renameatx_np
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = rename(at_fdcwd, left_bytes, at_fdcwd, right_bytes, 0x00000002)
    elif sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        rename = libc.renameat2
        rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = rename(at_fdcwd, left_bytes, at_fdcwd, right_bytes, 0x00000002)
    else:
        raise RuntimeError("atomic directory exchange is unsupported on this platform")
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), f"{left} <-> {right}")


def atomic_replace_directory(
    destination: Path,
    staged: Path,
    verify: Callable[[Path], None],
    *,
    exchange: Callable[[Path, Path], None] = exchange_directories,
) -> None:
    """Install staged without a missing/partial destination and roll back verification failures."""
    parent = destination.parent
    if destination.exists():
        if not destination.is_dir() or destination.is_symlink():
            raise RuntimeError(f"fixture destination is not a real directory: {destination}")
        exchange(destination, staged)
        fsync_directory(parent)
        try:
            verify(destination)
        except BaseException:
            exchange(destination, staged)
            fsync_directory(parent)
            raise
        shutil.rmtree(staged)
        fsync_directory(parent)
    else:
        os.replace(staged, destination)
        fsync_directory(parent)
        verify(destination)


def write_staged_directory(
    directory: Path,
    entries: list[dict[str, object]],
    generated: dict[str, bytes],
    manifest_bytes: bytes,
) -> None:
    for entry in entries:
        template_id = str(entry["id"])
        path = directory / f"{template_id}.json"
        with path.open("xb") as output:
            output.write(generated[template_id])
            output.flush()
            os.fsync(output.fileno())
    with (directory / "manifest.json").open("xb") as output:
        output.write(manifest_bytes)
        output.flush()
        os.fsync(output.fileno())
    fsync_directory(directory)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary_directory", type=Path)
    parser.add_argument("--update", action="store_true", help="atomically rewrite fixtures and hash manifest")
    arguments = parser.parse_args()

    binary_directory = arguments.binary_directory.resolve()
    for sibling in ("thumble", "thumble-cli-bridge", "thumble-bridge"):
        path = binary_directory / sibling
        if not path.is_file() or not os.access(path, os.X_OK):
            parser.error(f"missing executable sibling: {path}")

    catalog = json.loads(CATALOG_PATH.read_text(encoding="utf-8"))
    entries = validate_catalog(catalog)

    with tempfile.TemporaryDirectory(prefix="thumble-controller-templates-") as temporary:
        work = Path(temporary)
        work.chmod(0o700)
        generated = {
            str(entry["id"]): encoded(fixture_for(binary_directory, entry, work))
            for entry in entries
        }
    for entry in entries:
        validate_fixture(json.loads(generated[str(entry["id"])]), entry)
    manifest_bytes = build_manifest(entries, generated)

    if arguments.update:
        FIXTURE_DIRECTORY.parent.mkdir(parents=True, exist_ok=True)
        staged = Path(
            tempfile.mkdtemp(
                prefix=f".{FIXTURE_DIRECTORY.name}.update-",
                dir=FIXTURE_DIRECTORY.parent,
            )
        )
        staged.chmod(0o700)
        try:
            write_staged_directory(staged, entries, generated, manifest_bytes)
            verifier = lambda path: verify_directory(path, entries, generated, manifest_bytes)
            verifier(staged)
            atomic_replace_directory(FIXTURE_DIRECTORY, staged, verifier)
        finally:
            if staged.exists():
                shutil.rmtree(staged)
    else:
        verify_directory(FIXTURE_DIRECTORY, entries, generated, manifest_bytes)

    mode = "updated" if arguments.update else "verified"
    print(f"Controller template fixtures {mode} for all {len(entries)} templates using {binary_directory}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as error:
        if error.stdout:
            print(error.stdout, file=sys.stderr, end="")
        if error.stderr:
            print(error.stderr, file=sys.stderr, end="")
        raise
