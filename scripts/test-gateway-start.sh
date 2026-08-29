#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START="$ROOT_DIR/Host/crates/thumble-gateway/start.sh"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/thumble-gateway-start.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT INT TERM

cat >"$TEMP_DIR/backup-ok" <<'SH'
#!/bin/sh
set -eu
count_file="$TEST_DIR/backup-count"
count=0
[ ! -f "$count_file" ] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
printf 'snapshot-%s\n' "$count" >"$TEST_DIR/snapshot"
printf 'checksum-%s\n' "$count" >"$TEST_DIR/snapshot.sha256"
SH
cat >"$TEMP_DIR/backup-fail" <<'SH'
#!/bin/sh
exit 23
SH
cat >"$TEMP_DIR/gateway-existing" <<'SH'
#!/bin/sh
set -eu
test "$(cat "$TEST_DIR/backup-count")" = "1"
test -s "$TEST_DIR/snapshot"
test -s "$TEST_DIR/snapshot.sha256"
printf 'started\n' >"$TEST_DIR/gateway-started"
SH
cat >"$TEMP_DIR/gateway-new" <<'SH'
#!/bin/sh
set -eu
sqlite3 "$THUMBLE_GATEWAY_DB" \
  'CREATE TABLE builder_principals (id TEXT PRIMARY KEY);'
attempt=0
while [ "$attempt" -lt 40 ]; do
  [ ! -f "$TEST_DIR/backup-count" ] || break
  sleep 0.05
  attempt=$((attempt + 1))
done
test "$(cat "$TEST_DIR/backup-count")" = "1"
printf 'started\n' >"$TEST_DIR/gateway-started"
SH
chmod +x "$TEMP_DIR"/backup-* "$TEMP_DIR"/gateway-*

run_start() {
  TEST_DIR="$1" \
  THUMBLE_GATEWAY_DB="$1/gateway.db" \
  THUMBLE_GATEWAY_BACKUP_ENABLED=1 \
  THUMBLE_GATEWAY_BACKUP_PERIODIC_ENABLED=0 \
  THUMBLE_GATEWAY_BACKUP_EXECUTABLE="$2" \
  THUMBLE_GATEWAY_EXECUTABLE="$3" \
    "$START"
}

existing="$TEMP_DIR/existing"
mkdir "$existing"
printf 'old-db\n' >"$existing/gateway.db"
run_start "$existing" "$TEMP_DIR/backup-ok" "$TEMP_DIR/gateway-existing"
test "$(cat "$existing/backup-count")" = "1"
test -f "$existing/gateway-started"

new="$TEMP_DIR/new"
mkdir "$new"
run_start "$new" "$TEMP_DIR/backup-ok" "$TEMP_DIR/gateway-new"
test "$(cat "$new/backup-count")" = "1"
test -f "$new/gateway-started"

failure="$TEMP_DIR/failure"
mkdir "$failure"
printf 'old-db\n' >"$failure/gateway.db"
set +e
run_start "$failure" "$TEMP_DIR/backup-fail" "$TEMP_DIR/gateway-existing"
status=$?
set -e
test "$status" = "23"
test ! -e "$failure/gateway-started"

echo "gateway start backup harness passed (existing/new/failure)"
