#!/usr/bin/env python3
"""Verify that the MCP capability ledger covers the Swift CLI command surface.

This is deliberately source-based: a new top-level CLI command or canonical
subcommand must be represented in the checked-in ledger before CI passes.
The ledger records planned work as well as implemented work, so it cannot be
used to overstate runtime parity.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "Sources/CLI/ThumbleCLI.swift"
LEDGER = ROOT / "docs/mcp/cli-capabilities-v1.json"
OPERATION_SCHEMA = ROOT / "docs/mcp/configuration-operation-v1.schema.json"
DEVICE_CATALOG = ROOT / "docs/mcp/device-frames-v1.json"

ALLOWED_STATUSES = {"planned", "foundation", "partial", "current", "host-cli-only"}
# Transport/lifecycle commands configure how the same MCP tool surface is
# reached; they are not host capabilities and therefore do not belong in the
# CLI-operation-to-MCP-tool ledger.
NON_MCP_TRANSPORT_ROOTS = {"relay"}

FORBIDDEN_SCHEMA_KEYS = {
    "argv",
    "arguments",
    "authToken",
    "executable",
    "keyCode",
    "modifierMask",
    "rawKeyCode",
    "serverID",
    "shell",
    "trustedClients",
}

# Functions whose first string-case switch is their command dispatcher.
SUBCOMMAND_FUNCTIONS = {
    "profile": "profile",
    "template": "template",
    "theme": "theme",
    "skin": "skin",
    "binding": "binding",
    "output": "output",
    "customization": "customization",
    "style": "style",
    "layer": "layer",
    "group": "group",
    "asset": "asset",
    "device": "device",
    "controlBar": "control-bar",
    "element": "element",
    "server": "server",
    "pairing": "pairing",
    "accessibility": "accessibility",
    "test": "test",
    "latency": "latency",
    "app": "app",
}


def fail(message: str) -> None:
    print(f"MCP CLI parity verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load {path.relative_to(ROOT)}: {error}")


def function_body(source: str, name: str) -> str:
    marker = re.search(rf"^    private static func {re.escape(name)}\(", source, re.MULTILINE)
    if marker is None:
        fail(f"missing expected CLI function {name}")
    next_function = re.search(r"^    private static func ", source[marker.end() :], re.MULTILINE)
    end = marker.end() + next_function.start() if next_function else len(source)
    return source[marker.start() : end]


def direct_string_cases(body: str) -> list[str]:
    cases: list[str] = []
    for line in body.splitlines():
        match = re.match(r'^        case "([^"]+)"(?:,.*)?:', line)
        if match:
            cases.append(match.group(1))
    return cases


def schema_keys(value: Any) -> set[str]:
    if isinstance(value, dict):
        result = set(value)
        for child in value.values():
            result.update(schema_keys(child))
        return result
    if isinstance(value, list):
        result: set[str] = set()
        for child in value:
            result.update(schema_keys(child))
        return result
    return set()


def main() -> None:
    source = CLI.read_text(encoding="utf-8")
    ledger = load_json(LEDGER)
    operation_schema = load_json(OPERATION_SCHEMA)
    device_catalog = load_json(DEVICE_CATALOG)

    if ledger.get("schema") != "com.codybontecou.thumble.mcp-cli-capabilities":
        fail("unexpected capability ledger schema")
    if ledger.get("version") != 1:
        fail("unsupported capability ledger version")

    gates = set(ledger.get("gates", []))
    operations: list[dict[str, Any]] = []
    for family in ledger.get("families", []):
        family_id = family.get("id")
        if not isinstance(family_id, str) or not family_id:
            fail("family without a stable ID")
        if family.get("gate") not in gates:
            fail(f"family {family_id} has an unknown gate")
        for operation in family.get("operations", []):
            merged = dict(operation)
            merged.setdefault("gate", family.get("gate"))
            merged["family"] = family_id
            operations.append(merged)

    operation_ids = [operation.get("id") for operation in operations]
    if any(not isinstance(operation_id, str) or not operation_id for operation_id in operation_ids):
        fail("operation without a stable ID")
    if len(operation_ids) != len(set(operation_ids)):
        fail("duplicate operation ID")

    cli_paths: set[str] = set()
    for operation in operations:
        operation_id = operation["id"]
        if operation.get("status") not in ALLOWED_STATUSES:
            fail(f"operation {operation_id} has an unknown status")
        if operation.get("gate") not in gates:
            fail(f"operation {operation_id} has an unknown gate")
        paths = operation.get("cli")
        if not isinstance(paths, list) or not paths or not all(isinstance(path, str) and path for path in paths):
            fail(f"operation {operation_id} has no CLI path")
        for path in paths:
            if path in cli_paths:
                fail(f"CLI path {path!r} is mapped more than once")
            cli_paths.add(path)
        tool = operation.get("mcpTool")
        if not isinstance(tool, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", tool):
            fail(f"operation {operation_id} has an invalid MCP tool name")

    # Top-level source coverage. Compatibility aliases intentionally map to the
    # canonical first case value rather than duplicating every alias as a family.
    run_body = function_body(source, "run")
    root_commands = (
        set(direct_string_cases(run_body))
        - {"--help"}
        - NON_MCP_TRANSPORT_ROOTS
    )
    ledger_roots = {path.split()[0] for path in cli_paths}
    missing_roots = sorted(root_commands - ledger_roots)
    if missing_roots:
        fail(f"unmapped root CLI commands: {', '.join(missing_roots)}")

    # Canonical subcommand coverage. Parent dispatchers such as `skin artboard`
    # and `control-bar item` are covered by their typed child operations.
    missing_subcommands: list[str] = []
    for function_name, root in SUBCOMMAND_FUNCTIONS.items():
        body = function_body(source, function_name)
        for subcommand in direct_string_cases(body):
            path = f"{root} {subcommand}"
            if not any(candidate == path or candidate.startswith(path + " ") for candidate in cli_paths):
                missing_subcommands.append(path)
    if missing_subcommands:
        fail(f"unmapped canonical CLI subcommands: {', '.join(sorted(missing_subcommands))}")

    forbidden = sorted(schema_keys(operation_schema) & FORBIDDEN_SCHEMA_KEYS)
    if forbidden:
        fail(f"configuration operation schema exposes forbidden fields: {', '.join(forbidden)}")
    if operation_schema.get("$schema") != "https://json-schema.org/draft/2020-12/schema":
        fail("configuration operation contract is not JSON Schema 2020-12")
    schema_operation_ids: set[str] = set()
    definitions = operation_schema.get("$defs", {})
    for entry in operation_schema.get("oneOf", []):
        if not isinstance(entry, dict):
            fail("configuration operation contract contains a non-object operation")
        reference = entry.get("$ref")
        if reference is None:
            definition = entry
            location = "inline operation"
        elif isinstance(reference, str) and reference.startswith("#/$defs/"):
            definition = definitions.get(reference.removeprefix("#/$defs/"), {})
            location = reference
        else:
            fail("configuration operation contract has a non-local operation reference")
        operation_id = definition.get("properties", {}).get("type", {}).get("const")
        if not isinstance(operation_id, str) or not operation_id:
            fail(f"configuration operation {location} has no exact type constant")
        if operation_id in schema_operation_ids:
            fail(f"duplicate configuration operation schema type {operation_id}")
        schema_operation_ids.add(operation_id)
    unknown_schema_operations = sorted(schema_operation_ids - set(operation_ids))
    if unknown_schema_operations:
        fail(f"configuration schema operations missing from ledger: {', '.join(unknown_schema_operations)}")
    missing_current_writes = sorted(
        operation["id"]
        for operation in operations
        if operation.get("status") == "current"
        and operation.get("mcpTool") == "edit_configuration_draft"
        and operation["id"] not in schema_operation_ids
    )
    if missing_current_writes:
        fail(f"current draft writes missing from operation schema: {', '.join(missing_current_writes)}")

    if device_catalog.get("schema") != "com.codybontecou.thumble.device-frames":
        fail("unexpected device-frame catalog schema")
    if device_catalog.get("version") != 1:
        fail("unsupported device-frame catalog version")
    frames = device_catalog.get("frames")
    if not isinstance(frames, list) or len(frames) != 68:
        fail("device-frame catalog must contain exactly 68 built-in frames")
    frame_ids = [frame.get("id") for frame in frames if isinstance(frame, dict)]
    if len(frame_ids) != 68 or len(set(frame_ids)) != 68:
        fail("device-frame catalog IDs must be complete and unique")
    for frame in frames:
        frame_id = frame.get("id")
        orientation = frame.get("orientation")
        if not isinstance(frame_id, str) or frame_id.startswith("custom-"):
            fail("device-frame catalog contains a custom or invalid ID")
        if orientation not in {"portrait", "landscape"} or not frame_id.endswith(f"-{orientation}"):
            fail(f"device-frame catalog orientation mismatch for {frame_id}")
        if not isinstance(frame.get("width"), (int, float)) or not 240 <= frame["width"] <= 1800:
            fail(f"device-frame catalog width is invalid for {frame_id}")
        if not isinstance(frame.get("height"), (int, float)) or not 240 <= frame["height"] <= 1800:
            fail(f"device-frame catalog height is invalid for {frame_id}")
    schema_frame_ids = operation_schema.get("$defs", {}).get("deviceFrameID", {}).get("enum")
    if schema_frame_ids != frame_ids:
        fail("device.set schema does not exactly match the checked-in frame catalog")
    repair_canvas_variants = (
        operation_schema.get("$defs", {})
        .get("LayoutRepairCanvasInput", {})
        .get("oneOf", [])
    )
    repair_frame = next(
        (
            variant
            for variant in repair_canvas_variants
            if variant.get("properties", {}).get("source", {}).get("const") == "frame"
        ),
        None,
    )
    if repair_frame is None or repair_frame.get("properties", {}).get("frameID", {}).get("$ref") != "#/$defs/deviceFrameID":
        fail("customization.fix frame canvas does not exactly reference the checked-in frame catalog")
    repair_size = next(
        (
            variant
            for variant in repair_canvas_variants
            if variant.get("properties", {}).get("source", {}).get("const") == "size"
        ),
        None,
    )
    for dimension in ("width", "height"):
        bounds = (repair_size or {}).get("properties", {}).get(dimension, {})
        if bounds.get("minimum") != 240.0 or bounds.get("maximum") != 1800.0:
            fail(f"customization.fix {dimension} bounds are not 240...1800")

    print(
        f"MCP CLI parity ledger verified: {len(operations)} operations, "
        f"{len(root_commands)} root commands, {len(cli_paths)} CLI spellings"
    )


if __name__ == "__main__":
    main()
