#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <binary-directory>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FIXTURE_DIR="$ROOT_DIR/Host/fixtures/generation-spec/v1"
BINARY_DIR="$(cd "$1" 2>/dev/null && pwd -P)" || {
  echo "Binary directory does not exist: $1" >&2
  exit 2
}
THUMBLE="$BINARY_DIR/thumble"
CLI_BRIDGE="$BINARY_DIR/thumble-cli-bridge"
CONFIGURATION_BRIDGE="$BINARY_DIR/thumble-bridge"
[[ -x "$THUMBLE" ]] || { echo "Missing executable Swift CLI: $THUMBLE" >&2; exit 2; }
[[ -x "$CLI_BRIDGE" ]] || { echo "Missing executable Rust CLI bridge: $CLI_BRIDGE" >&2; exit 2; }
[[ -x "$CONFIGURATION_BRIDGE" ]] || { echo "Missing executable Swift configuration bridge: $CONFIGURATION_BRIDGE" >&2; exit 2; }
[[ -f "$FIXTURE_DIR/aliases-basic.json" ]] || {
  echo "Missing checked-in generation fixtures: $FIXTURE_DIR" >&2
  exit 1
}

umask 077
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/thumble-generation-flow.XXXXXX")"
cleanup() {
  if [[ -n "${WORK_ROOT:-}" && -d "$WORK_ROOT" ]]; then
    chmod -R u+rwX "$WORK_ROOT" 2>/dev/null || true
    rm -rf -- "$WORK_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM
chmod 700 "$WORK_ROOT"

ISOLATED_HOME="$WORK_ROOT/home"
ISOLATED_TMP="$WORK_ROOT/tmp"
mkdir -m 700 "$ISOLATED_HOME" "$ISOLATED_TMP"
export HOME="$ISOLATED_HOME"
export TMPDIR="$ISOLATED_TMP"

STDOUT_FILE="$WORK_ROOT/stdout"
STDERR_FILE="$WORK_ROOT/stderr"
LIST_JSON="$WORK_ROOT/list.json"
EXPORT_JSON="$WORK_ROOT/export.json"
PREVIEW_PNG="$WORK_ROOT/layout-preview.png"
ALIASES_SPEC="$FIXTURE_DIR/aliases-basic.json"
ALIASES_GENERATED="$FIXTURE_DIR/generated/aliases-basic.json"
RICH_SPEC="$FIXTURE_DIR/rich-appearance.json"
RICH_GENERATED="$FIXTURE_DIR/generated/rich-appearance.json"
TRIGGER_SPEC="$FIXTURE_DIR/trigger-defaults.json"
TRIGGER_GENERATED="$FIXTURE_DIR/generated/trigger-defaults.json"
EXHAUSTION_SPEC="$FIXTURE_DIR/duplicate-exhaustion-reused-layout.json"
UNSAFE_SPEC="$FIXTURE_DIR/failures/unsafe.json"
CONTROL_SPEC="$FIXTURE_DIR/failures/control-character.json"
FIXED_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE11"
REPLACEMENT_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE12"
STDIN_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE13"
RICH_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE14"
TRIGGER_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE15"
PREVIEW_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE16"
STRICT_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE17"
UNSAFE_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE18"
CONTROL_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE19"
BUILTIN_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE20"
BUILTIN_REPLACEMENT_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE21"

assert_one_json_document() {
  python3 - "$1" <<'PY'
import json
import sys

text = open(sys.argv[1], encoding="utf-8").read()
value, end = json.JSONDecoder().raw_decode(text)
assert isinstance(value, dict)
assert not text[end:].strip(), "JSON output has an appended summary or second document"
PY
}

assert_catalog() {
  local expected_count="$1"
  "$THUMBLE" profile list --json >"$LIST_JSON" 2>"$STDERR_FILE"
  [[ ! -s "$STDERR_FILE" ]]
  assert_one_json_document "$LIST_JSON"
  python3 - "$LIST_JSON" "$ALIASES_GENERATED" "$expected_count" <<'PY'
import json
import sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
generated = json.load(open(sys.argv[2], encoding="utf-8"))["profile"]
expected_count = int(sys.argv[3])
profiles = catalog["profiles"]
assert len(profiles) == expected_count
assert sum(profile["profileID"].lower() == generated["id"].lower() for profile in profiles) == 1
assert sum(profile["name"] == generated["name"] for profile in profiles) == 1
if expected_count == 2:
    assert sum(profile["default"] for profile in profiles) == 1
    assert sum(profile["profileID"].lower() != generated["id"].lower() for profile in profiles) == 1
PY
}

# JSON warnings are visible on stderr while stdout remains one uncontaminated generated document.
"$THUMBLE" generate --spec "$EXHAUSTION_SPEC" --json --dry-run \
  --skip-layout-validation >"$STDOUT_FILE" 2>"$STDERR_FILE"
assert_one_json_document "$STDOUT_FILE"
grep -Fq '[slot-exhaustion]' "$STDERR_FILE"
grep -Fq 'control dropped' "$STDERR_FILE"
! grep -Fq 'Generation warnings' "$STDOUT_FILE"

# Dry-run output is the exact checked-in generated profile, with no summary.
"$THUMBLE" generate --spec "$ALIASES_SPEC" --json --dry-run >"$STDOUT_FILE" 2>"$STDERR_FILE"
cmp -s "$ALIASES_GENERATED" "$STDOUT_FILE"
[[ ! -s "$STDERR_FILE" ]]
assert_one_json_document "$STDOUT_FILE"

# Read-only planning in a fresh HOME must not create authority state, locks, or drafts.
python3 - "$ISOLATED_HOME" <<'PY'
import os
import sys

for root, directories, files in os.walk(sys.argv[1]):
    assert "drafts" not in directories, f"dry-run created drafts directory under {root}"
    for artifact in ("state.json", "runtime.lock"):
        assert artifact not in files, f"dry-run created {artifact} under {root}"
PY
[[ ! -e "$ISOLATED_HOME/Library/Application Support/ThumbleHost" ]]

# The exact Swift/Rust sibling pair installs built-in revision 2 in isolated state.
BUILTIN_HOME="$WORK_ROOT/builtin-home"
mkdir -m 700 "$BUILTIN_HOME"
HOME="$BUILTIN_HOME" "$THUMBLE" generate "Hollow Knight" --json \
  --invocation-id "$BUILTIN_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
assert_one_json_document "$STDOUT_FILE"
printf 'Invocation ID: %s\n' "$BUILTIN_INVOCATION" | cmp -s - "$STDERR_FILE"
HOME="$BUILTIN_HOME" "$THUMBLE" generate "Hollow Knight" --json \
  --invocation-id "$BUILTIN_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
printf 'Invocation ID: %s\n' "$BUILTIN_INVOCATION" | cmp -s - "$STDERR_FILE"
HOME="$BUILTIN_HOME" "$THUMBLE" generate "Hollow Knight" --json \
  --invocation-id "$BUILTIN_REPLACEMENT_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
printf 'Invocation ID: %s\n' "$BUILTIN_REPLACEMENT_INVOCATION" | cmp -s - "$STDERR_FILE"
HOME="$BUILTIN_HOME" "$THUMBLE" profile list --json >"$LIST_JSON" 2>"$STDERR_FILE"
[[ ! -s "$STDERR_FILE" ]]
python3 - "$LIST_JSON" <<'PY'
import json
import sys

catalog = json.load(open(sys.argv[1], encoding="utf-8"))
profiles = catalog["profiles"]
assert catalog["configurationRevision"] == 3
assert len(profiles) == 2
assert sum(profile["name"] == "Hollow Knight" for profile in profiles) == 1
PY

# Installing prints only that same JSON document and reports the fixed invocation on stderr.
"$THUMBLE" generate --spec "$ALIASES_SPEC" --json \
  --invocation-id "$FIXED_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
cmp -s "$ALIASES_GENERATED" "$STDOUT_FILE"
printf 'Invocation ID: %s\n' "$FIXED_INVOCATION" | cmp -s - "$STDERR_FILE"
assert_one_json_document "$STDOUT_FILE"
assert_catalog 2

# An exact retry replays without duplicating the deterministic generated profile.
"$THUMBLE" generate --spec "$ALIASES_SPEC" --json \
  --invocation-id "$FIXED_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
cmp -s "$ALIASES_GENERATED" "$STDOUT_FILE"
printf 'Invocation ID: %s\n' "$FIXED_INVOCATION" | cmp -s - "$STDERR_FILE"
assert_one_json_document "$STDOUT_FILE"
assert_catalog 2

# A new invocation replaces the same deterministic profile instead of appending it.
"$THUMBLE" generate --spec "$ALIASES_SPEC" --json \
  --invocation-id "$REPLACEMENT_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
cmp -s "$ALIASES_GENERATED" "$STDOUT_FILE"
printf 'Invocation ID: %s\n' "$REPLACEMENT_INVOCATION" | cmp -s - "$STDERR_FILE"
assert_one_json_document "$STDOUT_FILE"
assert_catalog 2

# Standard-input planning is byte-identical and remains a dry run.
"$THUMBLE" generate --stdin --json --dry-run --invocation-id "$STDIN_INVOCATION" \
  <"$ALIASES_SPEC" >"$STDOUT_FILE" 2>"$STDERR_FILE"
cmp -s "$ALIASES_GENERATED" "$STDOUT_FILE"
[[ ! -s "$STDERR_FILE" ]]
assert_one_json_document "$STDOUT_FILE"
assert_catalog 2

# Rich appearance and trigger defaults survive the real Rust-to-Swift decode path.
"$THUMBLE" generate --spec "$RICH_SPEC" --json --dry-run \
  --invocation-id "$RICH_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
cmp -s "$RICH_GENERATED" "$STDOUT_FILE"
[[ ! -s "$STDERR_FILE" ]]
assert_one_json_document "$STDOUT_FILE"
python3 - "$STDOUT_FILE" <<'PY'
import json
import sys

generated = json.load(open(sys.argv[1], encoding="utf-8"))
element = generated["profile"]["customization"]["elements"][0]
layout = element["layout"]
assert element["builtInButton"] == "focus"
assert layout["icon"] == {
    "placement": "center", "renderingMode": "template", "scale": 1.0,
    "source": "sf_symbol", "value": "sparkles",
}
assert layout["hapticFeedback"] == {
    "duration": 0.09, "intensity": 0.73, "pattern": "double",
    "sharpness": 0.88, "style": "heavy",
}
normal = layout["visualStyle"]["normal"]
assert len(normal["shadows"]) == 2
assert normal["strokeWidth"] == 2.0
assert normal["innerShadowRadius"] == 5.0
assert normal["bevelWidth"] == 1.5
assert layout["visualStyle"]["pressed"]["fillStyle"]["kind"] == "solid"
PY

"$THUMBLE" generate --spec "$TRIGGER_SPEC" --json --dry-run \
  --invocation-id "$TRIGGER_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
cmp -s "$TRIGGER_GENERATED" "$STDOUT_FILE"
[[ ! -s "$STDERR_FILE" ]]
assert_one_json_document "$STDOUT_FILE"
python3 - "$STDOUT_FILE" <<'PY'
import json
import sys

generated = json.load(open(sys.argv[1], encoding="utf-8"))
customization = generated["profile"]["customization"]
element = customization["elements"][0]
custom = customization["customButtons"][0]
expected = {
    "deadZone": 0.03,
    "digitalThreshold": 0.5,
    "orientation": "vertical",
    "sendsDigitalButton": False,
    "sensitivity": 1.0,
    "target": "right",
}
assert element["kind"] == "trigger"
assert element["label"] == "Right Trigge"
assert element["triggerSettings"] == expected
assert custom["controlKind"] == "trigger"
assert custom["triggerSettings"] == expected
PY

# The macOS-native preview renderer must write a nonempty PNG while JSON stays clean.
"$THUMBLE" generate --spec "$ALIASES_SPEC" --json --dry-run \
  --layout-preview "$PREVIEW_PNG" --invocation-id "$PREVIEW_INVOCATION" \
  >"$STDOUT_FILE" 2>"$STDERR_FILE"
cmp -s "$ALIASES_GENERATED" "$STDOUT_FILE"
[[ ! -s "$STDERR_FILE" ]]
assert_one_json_document "$STDOUT_FILE"
python3 - "$PREVIEW_PNG" <<'PY'
import struct
import sys

png = open(sys.argv[1], "rb").read()
assert png.startswith(b"\x89PNG\r\n\x1a\n")
assert len(png) > 32
width, height = struct.unpack(">II", png[16:24])
assert width > 0 and height > 0
PY

# Strict warning handling aborts between planning and import, so the catalog is unchanged.
set +e
"$THUMBLE" generate --spec "$EXHAUSTION_SPEC" --strict-layout \
  --invocation-id "$STRICT_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
STRICT_STATUS=$?
set -e
[[ $STRICT_STATUS -ne 0 ]] || {
  echo "Strict exhaustion generation unexpectedly succeeded" >&2
  exit 1
}
grep -Fq '[slot-exhaustion]' "$STDOUT_FILE"
grep -Fq 'Rust generation reported warnings in strict layout mode.' "$STDERR_FILE"
assert_catalog 2

# Unsafe fields and control characters are rejected as typed failures with no stdout.
set +e
"$THUMBLE" generate --spec "$UNSAFE_SPEC" --json --dry-run \
  --invocation-id "$UNSAFE_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
UNSAFE_STATUS=$?
set -e
[[ $UNSAFE_STATUS -ne 0 ]] || { echo "Unsafe generation spec unexpectedly succeeded" >&2; exit 1; }
[[ ! -s "$STDOUT_FILE" ]]
grep -Fq '[generation_spec_unsafe_field]' "$STDERR_FILE"
grep -Fq "Invocation ID: $UNSAFE_INVOCATION" "$STDERR_FILE"

set +e
"$THUMBLE" generate --spec "$CONTROL_SPEC" --json --dry-run \
  --invocation-id "$CONTROL_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
CONTROL_STATUS=$?
set -e
[[ $CONTROL_STATUS -ne 0 ]] || {
  echo "Control-character generation spec unexpectedly succeeded" >&2
  exit 1
}
[[ ! -s "$STDOUT_FILE" ]]
grep -Fq '[generation_spec_control_character]' "$STDERR_FILE"
grep -Fq "Invocation ID: $CONTROL_INVOCATION" "$STDERR_FILE"
assert_catalog 2

# Export the installed deterministic profile and verify the portable artifact-v1 envelope.
"$THUMBLE" profile export "Alias Arcade" --output "$EXPORT_JSON" \
  >"$STDOUT_FILE" 2>"$STDERR_FILE"
[[ ! -s "$STDOUT_FILE" ]]
[[ ! -s "$STDERR_FILE" ]]
assert_one_json_document "$EXPORT_JSON"
python3 - "$EXPORT_JSON" "$ALIASES_GENERATED" <<'PY'
import json
import re
import sys

artifact = json.load(open(sys.argv[1], encoding="utf-8"))
generated = json.load(open(sys.argv[2], encoding="utf-8"))["profile"]
assert artifact["schema"] == "com.codybontecou.pocketpad.keypad-configuration"
assert artifact["version"] == 4
assert artifact["artifactVersion"] == 1
assert artifact["catalogRevision"] == {
    "controllerTemplates": 1, "deviceFrames": 1, "generationSpec": 1,
}
assert len(artifact["profiles"]) == 1
assert artifact["profiles"][0]["id"].lower() == generated["id"].lower()
assert artifact["profiles"][0]["name"] == generated["name"]
content_hash = artifact["contentHash"]
assert content_hash["algorithm"] == "sha256"
assert content_hash["canonicalization"] == "rfc8785"
assert re.fullmatch(r"[0-9a-f]{64}", content_hash["value"])
PY

[[ "$(stat -f '%Lp' "$ISOLATED_HOME")" == "700" ]]
[[ "$(stat -f '%Lp' "$ISOLATED_TMP")" == "700" ]]
echo "Generation spec real-binary flow verification passed for $BINARY_DIR."
