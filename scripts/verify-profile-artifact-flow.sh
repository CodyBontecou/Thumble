#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <binary-directory>" >&2
  exit 2
fi

BINARY_DIR="$(cd "$1" 2>/dev/null && pwd -P)" || {
  echo "Binary directory does not exist: $1" >&2
  exit 2
}
THUMBLE="$BINARY_DIR/thumble"
CLI_BRIDGE="$BINARY_DIR/thumble-cli-bridge"
[[ -x "$THUMBLE" ]] || { echo "Missing executable Swift CLI: $THUMBLE" >&2; exit 2; }
[[ -x "$CLI_BRIDGE" ]] || { echo "Missing executable Rust CLI bridge: $CLI_BRIDGE" >&2; exit 2; }

umask 077
WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/thumble-profile-flow.XXXXXX")"
cleanup() {
  if [[ -n "${WORK_ROOT:-}" && -d "$WORK_ROOT" ]]; then
    chmod -R u+rwX "$WORK_ROOT" 2>/dev/null || true
    rm -rf -- "$WORK_ROOT"
  fi
}
trap cleanup EXIT HUP INT TERM

ISOLATED_HOME="$WORK_ROOT/home"
mkdir -m 700 "$ISOLATED_HOME" "$WORK_ROOT/tmp"
export HOME="$ISOLATED_HOME"
export TMPDIR="$WORK_ROOT/tmp"

ARTIFACT_ONE="$WORK_ROOT/export-one.json"
ARTIFACT_TWO="$WORK_ROOT/export-two.json"
LIST_JSON="$WORK_ROOT/list.json"
STDOUT_FILE="$WORK_ROOT/stdout"
STDERR_FILE="$WORK_ROOT/stderr"
FIXED_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE01"
TAMPER_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE02"
LEGACY_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE03"
RAW_INVOCATION="AAAAAAAA-BBBB-5CCC-8DDD-EEEEEEEEEE04"

"$THUMBLE" profile export --all --output "$ARTIFACT_ONE"
python3 - "$ISOLATED_HOME" "$ARTIFACT_ONE" <<'PY'
import json
import os
import re
import sys

home, path = sys.argv[1:]
assert os.stat(home).st_mode & 0o777 == 0o700
with open(path, encoding="utf-8") as source:
    artifact = json.load(source)
assert artifact["schema"] == "com.codybontecou.pocketpad.keypad-configuration"
assert artifact["version"] == 4
assert artifact["artifactVersion"] == 1
assert len(artifact["profiles"]) == 1
content_hash = artifact["contentHash"]
assert content_hash["algorithm"] == "sha256"
assert content_hash["canonicalization"] == "rfc8785"
assert re.fullmatch(r"[0-9a-f]{64}", content_hash["value"])
profile_ids = {profile["id"].lower() for profile in artifact["profiles"]}
assert artifact["activeProfileID"].lower() in profile_ids
if artifact["defaultProfileID"] is not None:
    assert artifact["defaultProfileID"].lower() in profile_ids
PY

"$THUMBLE" profile import "$ARTIFACT_ONE" --append --default \
  --invocation-id "$FIXED_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
printf 'Imported 1 profile as copies.\n' | cmp -s - "$STDOUT_FILE"
printf 'Invocation ID: %s\n' "$FIXED_INVOCATION" | cmp -s - "$STDERR_FILE"

"$THUMBLE" profile list --json >"$LIST_JSON"
"$THUMBLE" profile export --all --output "$ARTIFACT_TWO"
python3 - "$LIST_JSON" "$ARTIFACT_TWO" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    catalog = json.load(source)
with open(sys.argv[2], encoding="utf-8") as source:
    artifact = json.load(source)
assert len(catalog["profiles"]) == 2
assert sum(profile["default"] for profile in catalog["profiles"]) == 1
catalog_ids = {profile["profileID"].lower() for profile in catalog["profiles"]}
default_id = next(profile["profileID"].lower() for profile in catalog["profiles"] if profile["default"])
assert len(artifact["profiles"]) == 2
artifact_ids = {profile["id"].lower() for profile in artifact["profiles"]}
assert catalog_ids == artifact_ids
assert artifact["defaultProfileID"].lower() == default_id
assert artifact["defaultProfileID"].lower() in artifact_ids
PY

TAMPERED="$WORK_ROOT/tampered.json"
LEGACY="$WORK_ROOT/legacy-v4.json"
RAW_PROFILE="$WORK_ROOT/raw-profile.json"
python3 - "$ARTIFACT_ONE" "$TAMPERED" "$LEGACY" "$RAW_PROFILE" <<'PY'
import json
import sys

source_path, tampered_path, legacy_path, raw_path = sys.argv[1:]
with open(source_path, encoding="utf-8") as source:
    artifact = json.load(source)

tampered = dict(artifact)
tampered["profiles"] = [dict(profile) for profile in artifact["profiles"]]
tampered["profiles"][0]["name"] += " tampered"
with open(tampered_path, "w", encoding="utf-8") as output:
    json.dump(tampered, output, separators=(",", ":"))

legacy_fields = (
    "schema", "version", "exportedAt", "profiles", "activeProfileID",
    "defaultProfileID", "profileKeyBindings", "profileOutputBindings",
)
legacy = {key: artifact[key] for key in legacy_fields if key in artifact}
with open(legacy_path, "w", encoding="utf-8") as output:
    json.dump(legacy, output, separators=(",", ":"))
with open(raw_path, "w", encoding="utf-8") as output:
    json.dump(artifact["profiles"][0], output, separators=(",", ":"))
PY

set +e
"$THUMBLE" profile import "$TAMPERED" --append \
  --invocation-id "$TAMPER_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
TAMPER_STATUS=$?
set -e
[[ $TAMPER_STATUS -ne 0 ]] || {
  echo "Tampered hashed artifact was accepted" >&2
  exit 1
}
[[ ! -s "$STDOUT_FILE" ]]
grep -Fq '[profile_artifact_hash_mismatch]' "$STDERR_FILE"
grep -Fq "Invocation ID: $TAMPER_INVOCATION" "$STDERR_FILE"

"$THUMBLE" profile import "$LEGACY" --append --no-select \
  --invocation-id "$LEGACY_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
printf 'Imported 1 profile as copies.\n' | cmp -s - "$STDOUT_FILE"
printf 'Invocation ID: %s\n' "$LEGACY_INVOCATION" | cmp -s - "$STDERR_FILE"

"$THUMBLE" profile import "$RAW_PROFILE" --append --no-select \
  --invocation-id "$RAW_INVOCATION" >"$STDOUT_FILE" 2>"$STDERR_FILE"
printf 'Imported 1 profile as copies.\n' | cmp -s - "$STDOUT_FILE"
printf 'Invocation ID: %s\n' "$RAW_INVOCATION" | cmp -s - "$STDERR_FILE"

[[ "$(find "$ISOLATED_HOME" -type f | wc -l | tr -d ' ')" -gt 0 ]]
echo "Profile artifact flow verification passed for $BINARY_DIR."
