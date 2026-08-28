#!/bin/sh
set -eu

DB="${THUMBLE_GATEWAY_DB:-/data/thumble-gateway.db}"
BACKUP_DIR="${THUMBLE_GATEWAY_BACKUP_DIR:-/data/backups}"
RETENTION_DAYS="${THUMBLE_GATEWAY_BACKUP_RETENTION_DAYS:-7}"
UPLOAD_TEMPLATE="${THUMBLE_GATEWAY_BACKUP_UPLOAD_URL:-}"
UPLOAD_TOKEN="${THUMBLE_GATEWAY_BACKUP_TOKEN:-}"

case "$DB$BACKUP_DIR" in
  *"'"*) echo "gateway backup paths must not contain single quotes" >&2; exit 1 ;;
esac

mkdir -p "$BACKUP_DIR"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
filename="thumble-gateway-$timestamp.db.gz"
snapshot="$BACKUP_DIR/${filename%.gz}"
archive="$BACKUP_DIR/$filename"

# SQLite's online backup API produces a consistent snapshot while the
# gateway remains live and writing to the source database.
sqlite3 "$DB" ".backup '$snapshot'"
gzip -f "$snapshot"
sha256sum "$archive" > "$archive.sha256"

if [ -n "$UPLOAD_TEMPLATE" ]; then
  upload_url="$(printf '%s' "$UPLOAD_TEMPLATE" | sed "s/{filename}/$filename/g")"
  if [ -n "$UPLOAD_TOKEN" ]; then
    curl --fail --silent --show-error --retry 3 \
      -H "Authorization: Bearer $UPLOAD_TOKEN" \
      --upload-file "$archive" "$upload_url"
    curl --fail --silent --show-error --retry 3 \
      -H "Authorization: Bearer $UPLOAD_TOKEN" \
      --upload-file "$archive.sha256" "$upload_url.sha256"
  else
    curl --fail --silent --show-error --retry 3 \
      --upload-file "$archive" "$upload_url"
    curl --fail --silent --show-error --retry 3 \
      --upload-file "$archive.sha256" "$upload_url.sha256"
  fi
else
  echo "thumble-gateway backup: no offsite upload URL configured; snapshot is local only" >&2
fi

find "$BACKUP_DIR" -type f -name 'thumble-gateway-*.db.gz*' -mtime "+$RETENTION_DAYS" -delete
printf '%s\n' "$archive"
