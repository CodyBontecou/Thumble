#!/bin/sh
set -eu

if [ "${THUMBLE_GATEWAY_BACKUP_ENABLED:-0}" = "1" ]; then
  interval="${THUMBLE_GATEWAY_BACKUP_INTERVAL_SECONDS:-86400}"
  database="${THUMBLE_GATEWAY_DB:-/data/thumble-gateway.db}"
  (
    # First-run initialization creates the database in the foreground process.
    # Back it up as soon as it exists, then continue on the configured cadence.
    while [ ! -f "$database" ]; do sleep 1; done
    while :; do
      /usr/local/bin/thumble-gateway-backup || \
        echo "thumble-gateway backup failed; the gateway remains online" >&2
      sleep "$interval"
    done
  ) &
fi

exec /usr/local/bin/thumble-gateway
