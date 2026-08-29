#!/bin/sh
set -eu

backup_enabled="${THUMBLE_GATEWAY_BACKUP_ENABLED:-0}"
interval="${THUMBLE_GATEWAY_BACKUP_INTERVAL_SECONDS:-86400}"
database="${THUMBLE_GATEWAY_DB:-/data/thumble-gateway.db}"
backup_executable="${THUMBLE_GATEWAY_BACKUP_EXECUTABLE:-/usr/local/bin/thumble-gateway-backup}"
gateway_executable="${THUMBLE_GATEWAY_EXECUTABLE:-/usr/local/bin/thumble-gateway}"
periodic_enabled="${THUMBLE_GATEWAY_BACKUP_PERIODIC_ENABLED:-1}"

if [ "$backup_enabled" = "1" ]; then
  if [ -f "$database" ]; then
    # Existing databases may require a startup migration. Produce and checksum
    # a consistent snapshot synchronously; never expose the newer binary if
    # this pre-migration safety boundary fails.
    "$backup_executable"
    if [ "$periodic_enabled" = "1" ]; then
      (
        # The synchronous snapshot above is the immediate backup. Wait one full
        # cadence so startup cannot create a duplicate archive in the same second.
        sleep "$interval"
        while :; do
          "$backup_executable" || \
            echo "thumble-gateway backup failed; the gateway remains online" >&2
          sleep "$interval"
        done
      ) &
    fi
  else
    (
      # First-run initialization belongs to the foreground gateway. Back up
      # once after it creates the database, then continue on the cadence.
      while [ ! -f "$database" ]; do sleep 1; done
      # Opening SQLite creates the file before the transactional schema commit.
      # Wait for a committed Phase 4 table so the first archive cannot attest
      # an empty pre-migration database.
      while ! sqlite3 "$database" \
        "SELECT 1 FROM builder_principals LIMIT 1;" >/dev/null 2>&1; do
        sleep 1
      done
      "$backup_executable" || \
        echo "thumble-gateway backup failed; the gateway remains online" >&2
      if [ "$periodic_enabled" = "1" ]; then
        while :; do
          sleep "$interval"
          "$backup_executable" || \
            echo "thumble-gateway backup failed; the gateway remains online" >&2
        done
      fi
    ) &
  fi
fi

exec "$gateway_executable"
