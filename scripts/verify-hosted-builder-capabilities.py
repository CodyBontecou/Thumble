#!/usr/bin/env python3
"""Verify the hosted builder capability contract without inventing CLI paths."""

from __future__ import annotations

import json
import re
import sys
from collections import Counter
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
BUILDER_LEDGER = ROOT / "docs/mcp/hosted-builder-capabilities-v1.json"
CLI_LEDGER = ROOT / "docs/mcp/cli-capabilities-v1.json"

STATUS_RANK = {"planned": 0, "foundation": 1, "partial": 2, "current": 3}
EXPECTED_GATES = {"builder-session", "share-read"}
EXPECTED_SHARED_OPERATIONS = {
    "generation.install-spec",
    "profile.export",
    "profile.import",
}
EXPECTED_SHARED_STATUSES = {
    "generation.install-spec": "host-cli-only",
    "profile.export": "host-cli-only",
    "profile.import": "host-cli-only",
}
EXPECTED_OPERATIONS = {
    "builder.session.begin": "begin_builder_session",
    "builder.session.status": "builder_status",
    "builder.profile.edit": "edit_builder_profile",
    "builder.profile.validate": "validate_builder_profile",
    "builder.profile.preview": "preview_builder_profile",
    "builder.template.install": "install_template",
    "builder.generation.generate-spec": "generate_from_spec",
    "builder.artifact.emit": "emit_profile_artifact",
    "builder.session.discard": "discard_builder_session",
}


def fail(message: str) -> None:
    print(f"Hosted builder capability verification failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"cannot load {path.relative_to(ROOT)}: {error}")


def exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    actual = set(value)
    if actual != expected:
        fail(
            f"{label} keys must be exactly {sorted(expected)} "
            f"(missing={sorted(expected - actual)}, extra={sorted(actual - expected)})"
        )
    return value


def string_set(value: Any, label: str) -> set[str]:
    if (
        not isinstance(value, list)
        or not value
        or not all(isinstance(item, str) and item for item in value)
    ):
        fail(f"{label} must be a nonempty-string array")
    if len(value) != len(set(value)):
        fail(f"{label} contains duplicates")
    return set(value)


def status_rank(value: Any, label: str) -> int:
    if value not in STATUS_RANK:
        fail(f"{label} has an unknown status")
    return STATUS_RANK[value]


def main() -> None:
    ledger = exact_keys(
        load_json(BUILDER_LEDGER),
        {
            "schema",
            "version",
            "authority",
            "connector",
            "gates",
            "sharedOperations",
            "shareEndpoint",
            "operations",
        },
        "hosted builder ledger",
    )
    cli_ledger = load_json(CLI_LEDGER)

    if ledger["schema"] != "com.codybontecou.thumble.hosted-builder-capabilities":
        fail("unexpected capability ledger schema")
    if ledger["version"] != 1:
        fail("unsupported capability ledger version")
    if not isinstance(cli_ledger, dict) or cli_ledger.get("schema") != "com.codybontecou.thumble.mcp-cli-capabilities":
        fail("unexpected CLI capability ledger schema")

    authority = exact_keys(
        ledger["authority"],
        {"workspace", "adoption", "phoneSync", "input"},
        "authority contract",
    )
    if authority["workspace"] != "pre-adoption-builder-session":
        fail("builder workspace must remain pre-adoption state")
    if authority["adoption"] != "explicit-profile-artifact-import":
        fail("builder adoption must remain an explicit artifact import")
    if authority["phoneSync"] != "none" or authority["input"] != "none":
        fail("builder must expose neither phone sync nor input authority")

    gates = string_set(ledger["gates"], "gates")
    if gates != EXPECTED_GATES:
        fail(f"gate vocabulary must be exactly {sorted(EXPECTED_GATES)}")

    connector = exact_keys(
        ledger["connector"],
        {"path", "scope", "status"},
        "connector contract",
    )
    if connector["path"] != "/builder/mcp":
        fail("builder connector path must be /builder/mcp")
    if connector["scope"] != "thumble.build":
        fail("builder connector scope must be thumble.build")
    connector_rank = status_rank(connector["status"], "builder connector")

    share = exact_keys(
        ledger["shareEndpoint"],
        {"method", "path", "gate", "status"},
        "share endpoint contract",
    )
    if share["method"] != "GET" or share["path"] != "/share/{artifactID}":
        fail("share endpoint must be GET /share/{artifactID}")
    if share["gate"] != "share-read":
        fail("share endpoint must use the share-read gate")
    if status_rank(share["status"], "share endpoint") > connector_rank:
        fail("share endpoint status cannot exceed the connector status")

    shared_operations = string_set(ledger["sharedOperations"], "sharedOperations")
    if shared_operations != EXPECTED_SHARED_OPERATIONS:
        fail(f"shared operations must be exactly {sorted(EXPECTED_SHARED_OPERATIONS)}")

    cli_operations = [
        operation
        for family in cli_ledger.get("families", [])
        if isinstance(family, dict)
        for operation in family.get("operations", [])
        if isinstance(operation, dict)
    ]
    cli_operation_ids = {operation.get("id") for operation in cli_operations}
    cli_tools = {operation.get("mcpTool") for operation in cli_operations}
    missing_shared = sorted(shared_operations - cli_operation_ids)
    if missing_shared:
        fail(f"shared operations missing from CLI ledger: {', '.join(missing_shared)}")
    cli_statuses = {operation.get("id"): operation.get("status") for operation in cli_operations}
    wrong_shared_statuses = {
        operation_id: cli_statuses.get(operation_id)
        for operation_id, expected in EXPECTED_SHARED_STATUSES.items()
        if cli_statuses.get(operation_id) != expected
    }
    if wrong_shared_statuses:
        fail(
            "shared CLI operations must stay host-cli-only until their general MCP tools ship: "
            + ", ".join(
                f"{operation_id}={status!r}"
                for operation_id, status in sorted(wrong_shared_statuses.items())
            )
        )

    operations = ledger["operations"]
    if not isinstance(operations, list):
        fail("operations must be an array")
    actual_operations: dict[str, str] = {}
    status_counts: Counter[str] = Counter()
    for index, raw_operation in enumerate(operations):
        operation = exact_keys(
            raw_operation,
            {"id", "mcpTool", "executor", "gate", "status", "phoneEffect"},
            f"operation[{index}]",
        )
        operation_id = operation["id"]
        tool = operation["mcpTool"]
        if not isinstance(operation_id, str) or not operation_id:
            fail("operation without a stable ID")
        if operation_id in actual_operations:
            fail(f"duplicate operation ID {operation_id}")
        if not isinstance(tool, str) or not re.fullmatch(r"[a-z][a-z0-9_]*", tool):
            fail(f"operation {operation_id} has an invalid MCP tool name")
        if tool in actual_operations.values():
            fail(f"duplicate MCP tool name {tool}")
        if operation["executor"] != "thumble-builder":
            fail(f"operation {operation_id} must execute in thumble-builder")
        if operation["gate"] != "builder-session":
            fail(f"operation {operation_id} must use the builder-session gate")
        if operation["phoneEffect"] != "none":
            fail(f"operation {operation_id} must have no phone effect")
        if status_rank(operation["status"], f"operation {operation_id}") > connector_rank:
            fail(f"operation {operation_id} status cannot exceed the connector status")
        status_counts[operation["status"]] += 1
        actual_operations[operation_id] = tool

    if actual_operations != EXPECTED_OPERATIONS:
        missing = sorted(set(EXPECTED_OPERATIONS) - set(actual_operations))
        extra = sorted(set(actual_operations) - set(EXPECTED_OPERATIONS))
        wrong = sorted(
            operation_id
            for operation_id in set(actual_operations) & set(EXPECTED_OPERATIONS)
            if actual_operations[operation_id] != EXPECTED_OPERATIONS[operation_id]
        )
        fail(f"operation set mismatch (missing={missing}, extra={extra}, wrongTools={wrong})")

    hosted_ids = set(actual_operations)
    hosted_tools = set(actual_operations.values())
    leaked_ids = sorted(hosted_ids & cli_operation_ids)
    leaked_tools = sorted(hosted_tools & cli_tools)
    if leaked_ids or leaked_tools:
        fail(
            "hosted-only capabilities must not appear in the CLI ledger "
            f"(operationIDs={leaked_ids}, tools={leaked_tools})"
        )

    counts = ", ".join(f"{status}={status_counts[status]}" for status in STATUS_RANK if status_counts[status])
    print(
        "Hosted builder capability ledger verified: "
        f"{len(operations)} tool contracts ({counts}), "
        f"{len(shared_operations)} shared CLI operations"
    )


if __name__ == "__main__":
    main()
