#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/Host/Cargo.toml"
GATEWAY="$ROOT_DIR/Host/target/debug/thumble-gateway"
PHASE4_HELPER="$ROOT_DIR/Host/target/debug/examples/phase4_seed"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.88.0}"
MODE="full"
if [[ "${1:-}" == "--focused" ]]; then
  MODE="focused"
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--focused]" >&2
  exit 64
fi

for command in cargo curl gzip python3 sqlite3 sha256sum; do
  command -v "$command" >/dev/null || {
    echo "hosted-builder local verification requires $command" >&2
    exit 1
  }
done
"$ROOT_DIR/scripts/test-gateway-start.sh"

if command -v rustup >/dev/null 2>&1; then
  TOOLCHAIN_BIN="$(dirname "$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc)")"
  export PATH="$TOOLCHAIN_BIN:$PATH"
fi

# Default local acceptance is the pinned full Rust workspace gate. CI may use
# --focused only after its separate pinned workspace job has passed.
if [[ "$MODE" == "full" ]]; then
  python3 "$ROOT_DIR/scripts/verify-mcp-cli-parity.py"
  python3 "$ROOT_DIR/scripts/verify-hosted-builder-capabilities.py"
  python3 "$ROOT_DIR/scripts/verify-cli-profile-persistence-allowlist.py"
  python3 "$ROOT_DIR/scripts/test_verify_controller_template_fixtures.py"
  cargo fmt --manifest-path "$MANIFEST" --all --check
  cargo test --locked --manifest-path "$MANIFEST" --workspace --all-features
  cargo clippy --locked --manifest-path "$MANIFEST" --workspace --all-targets --all-features -- -D warnings
fi

# Keep an explicit named receipt even in full mode: this is the real HTTP +
# rmcp builder path the remainder of this script is designed to deploy locally.
cargo test --locked --manifest-path "$MANIFEST" -p thumble-gateway --test builder_e2e
cargo build --locked --manifest-path "$MANIFEST" -p thumble-gateway --bin thumble-gateway --example phase4_seed

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/thumble-builder-local.XXXXXX")"
DB="$TEMP_DIR/thumble-gateway.db"
BACKUP_DIR="$TEMP_DIR/backups"
LOG="$TEMP_DIR/gateway.log"
RECEIPT="$TEMP_DIR/phase4-receipt.json"
SECRET="local-only-builder-verification-secret-0123456789abcdef"
PORT="$(python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)"
BASE="http://127.0.0.1:$PORT"
GATEWAY_PID=""

stop_gateway() {
  if [[ -n "$GATEWAY_PID" ]] && kill -0 "$GATEWAY_PID" 2>/dev/null; then
    kill -INT "$GATEWAY_PID" 2>/dev/null || true
    for _ in {1..50}; do
      kill -0 "$GATEWAY_PID" 2>/dev/null || break
      sleep 0.1
    done
    if kill -0 "$GATEWAY_PID" 2>/dev/null; then
      kill "$GATEWAY_PID" 2>/dev/null || true
    fi
    wait "$GATEWAY_PID" 2>/dev/null || true
  fi
  GATEWAY_PID=""
}

cleanup() {
  stop_gateway
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT INT TERM

start_gateway() {
  THUMBLE_GATEWAY_BIND="127.0.0.1:$PORT" \
  THUMBLE_GATEWAY_BASE_URL="$BASE" \
  THUMBLE_GATEWAY_DB="$DB" \
  THUMBLE_GATEWAY_TOKEN_SECRET="$SECRET" \
    "$GATEWAY" >>"$LOG" 2>&1 &
  GATEWAY_PID=$!
  for _ in {1..100}; do
    if curl --fail --silent --show-error --max-time 1 "$BASE/healthz" >"$TEMP_DIR/health.json" 2>/dev/null; then
      return
    fi
    if ! kill -0 "$GATEWAY_PID" 2>/dev/null; then
      cat "$LOG" >&2
      echo "gateway stopped before health became ready" >&2
      exit 1
    fi
    sleep 0.1
  done
  cat "$LOG" >&2
  echo "gateway health wait exceeded 10 seconds" >&2
  exit 1
}

verify_metadata_and_challenges() {
  curl --fail --silent --show-error --max-time 2 \
    "$BASE/.well-known/oauth-authorization-server" >"$TEMP_DIR/authorization.json"
  curl --fail --silent --show-error --max-time 2 \
    "$BASE/.well-known/oauth-protected-resource" >"$TEMP_DIR/relay.json"
  curl --fail --silent --show-error --max-time 2 \
    "$BASE/.well-known/oauth-protected-resource/builder/mcp" >"$TEMP_DIR/builder.json"
  python3 - "$BASE" "$TEMP_DIR" <<'PY'
import json
import pathlib
import sys
base, directory = sys.argv[1], pathlib.Path(sys.argv[2])
health = json.loads((directory / "health.json").read_text())
auth = json.loads((directory / "authorization.json").read_text())
relay = json.loads((directory / "relay.json").read_text())
builder = json.loads((directory / "builder.json").read_text())
assert health == {"devices_online": 0, "ok": True}, health
assert auth["issuer"] == base
assert "thumble.build" in auth["scopes_supported"]
assert relay["resource"] == base + "/mcp"
assert "thumble.build" not in relay["scopes_supported"]
assert builder["resource"] == base + "/builder/mcp"
assert builder["scopes_supported"] == ["thumble.build", "offline_access"]
PY

  curl --silent --show-error --max-time 2 -X POST -D "$TEMP_DIR/relay.headers" \
    -o /dev/null "$BASE/mcp"
  curl --silent --show-error --max-time 2 -X POST -D "$TEMP_DIR/builder.headers" \
    -o /dev/null "$BASE/builder/mcp"
  tr -d '\r' <"$TEMP_DIR/relay.headers" >"$TEMP_DIR/relay.headers.clean"
  tr -d '\r' <"$TEMP_DIR/builder.headers" >"$TEMP_DIR/builder.headers.clean"
  grep -Fxq "HTTP/1.1 401 Unauthorized" "$TEMP_DIR/relay.headers.clean"
  grep -Fxq "HTTP/1.1 401 Unauthorized" "$TEMP_DIR/builder.headers.clean"
  relay_challenge="www-authenticate: Bearer error=\"invalid_token\", resource_metadata=\"$BASE/.well-known/oauth-protected-resource\", scope=\"thumble.read thumble.draft thumble.config offline_access\""
  builder_challenge="www-authenticate: Bearer error=\"invalid_token\", resource_metadata=\"$BASE/.well-known/oauth-protected-resource/builder/mcp\", scope=\"thumble.build\""
  grep -Fxiq "$relay_challenge" "$TEMP_DIR/relay.headers.clean"
  grep -Fxiq "$builder_challenge" "$TEMP_DIR/builder.headers.clean"
  ! grep -Fxiq "$builder_challenge" "$TEMP_DIR/relay.headers.clean"
  ! grep -Fxiq "$relay_challenge" "$TEMP_DIR/builder.headers.clean"
}

# Seed a non-empty Phase 4 database through the real Store and BuilderSession
# APIs. The helper writes its three-field credential receipt only to this temp
# file; the share token is never printed by either helper invocation.
"$PHASE4_HELPER" seed "$DB" "$SECRET" "$RECEIPT"
python3 - "$RECEIPT" <<'PY'
import json, pathlib, sys
receipt = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert sorted(receipt) == ["artifactID", "hash", "shareToken"]
assert len(receipt["artifactID"]) == 68 and receipt["artifactID"].startswith("bar_")
assert len(receipt["shareToken"]) == 64
assert len(receipt["hash"]) == 64
PY
"$PHASE4_HELPER" verify "$DB" "$SECRET" "$RECEIPT"

read_receipt() {
  python3 - "$RECEIPT" "$1" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())[sys.argv[2]])
PY
}
ARTIFACT_ID="$(read_receipt artifactID)"
SHARE_TOKEN="$(read_receipt shareToken)"
CONTENT_HASH="$(read_receipt hash)"

fetch_seeded_share() {
  destination="$1"
  curl --fail --silent --show-error --max-time 5 \
    -H "Authorization: ThumbleShare $SHARE_TOKEN" \
    "$BASE/share/$ARTIFACT_ID" >"$destination"
  python3 - "$destination" "$CONTENT_HASH" <<'PY'
import json, pathlib, sys
artifact = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert artifact["contentHash"]["algorithm"] == "sha256"
assert artifact["contentHash"]["canonicalization"] == "rfc8785"
assert artifact["contentHash"]["value"] == sys.argv[2]
PY
}

# First gateway boot migrates the already-seeded Phase 4 database and fetches
# the exact atomic artifact/share through the real HTTP endpoint.
start_gateway
verify_metadata_and_challenges
fetch_seeded_share "$TEMP_DIR/original-share.json"
stop_gateway

# Second boot on exactly the same non-empty database exercises idempotent
# startup migration/pruning before readiness is exposed again.
start_gateway
verify_metadata_and_challenges
fetch_seeded_share "$TEMP_DIR/restarted-share.json"
cmp "$TEMP_DIR/original-share.json" "$TEMP_DIR/restarted-share.json"

# Exercise the shipped online SQLite backup while this non-empty gateway is
# live and validate its checksum before restoring it separately.
mkdir -p "$BACKUP_DIR"
archive="$(
  env -u THUMBLE_GATEWAY_BACKUP_UPLOAD_URL \
    -u THUMBLE_GATEWAY_BACKUP_TOKEN \
    THUMBLE_GATEWAY_DB="$DB" \
    THUMBLE_GATEWAY_BACKUP_DIR="$BACKUP_DIR" \
    THUMBLE_GATEWAY_BACKUP_RETENTION_DAYS=7 \
    "$ROOT_DIR/Host/crates/thumble-gateway/backup.sh"
)"
test -f "$archive"
test -f "$archive.sha256"
(
  cd "$BACKUP_DIR"
  sha256sum -c "$(basename "$archive.sha256")"
)
RESTORED_DB="$TEMP_DIR/restored.db"
gzip -dc "$archive" >"$RESTORED_DB"
test "$(sqlite3 "$RESTORED_DB" 'PRAGMA integrity_check;')" = "ok"
test "$(sqlite3 "$RESTORED_DB" 'PRAGMA foreign_key_check;' | wc -l | tr -d ' ')" = "0"
test "$(sqlite3 "$RESTORED_DB" "SELECT COUNT(*) FROM builder_artifacts WHERE artifact_id = '$ARTIFACT_ID';")" = "1"
test "$(sqlite3 "$RESTORED_DB" "SELECT COUNT(*) FROM builder_shares WHERE artifact_id = '$ARTIFACT_ID';")" = "1"
test "$(sqlite3 "$RESTORED_DB" "SELECT COUNT(*) FROM builder_session_tombstones WHERE kind = 'emitted';")" -ge 1

stop_gateway
DB="$RESTORED_DB"
start_gateway
verify_metadata_and_challenges
fetch_seeded_share "$TEMP_DIR/restored-share.json"
cmp "$TEMP_DIR/original-share.json" "$TEMP_DIR/restored-share.json"
"$PHASE4_HELPER" verify "$RESTORED_DB" "$SECRET" "$RECEIPT"
stop_gateway

echo "Hosted builder local verification passed (seeded Phase 4 rows, loopback restore, no production/offsite action)."
