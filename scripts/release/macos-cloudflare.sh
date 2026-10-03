#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Build, notarize, package, and upload Thumble Mac for direct web distribution.

Usage:
  scripts/release/macos-cloudflare.sh [options]

Options:
  --version <version>          Marketing version to stamp into the archive.
  --build-number <number>     Build number to stamp into the archive.
  --release-notes <text>      Release notes to include in macos/latest.json.
  --release-notes-file <path> Read release notes from a file.
  --skip-notarize             Package without submitting to Apple notarization.
  --skip-upload               Build local artifacts but do not upload to Cloudflare R2.
  --skip-xcodegen             Do not regenerate Thumble.xcodeproj from project.yml.
  -h, --help                  Show this help.

Required for upload:
  CF_RELEASES_BUCKET or THUMBLE_RELEASES_BUCKET
  Legacy THUMBCONSOLE_* and POCKETPAD_* variable names remain supported.
  Wrangler authenticated with Cloudflare.

Required for notarization unless --skip-notarize:
  asc API-key auth, NOTARYTOOL_KEYCHAIN_PROFILE, or APPLE_ID + APP_SPECIFIC_PASSWORD + ASC_TEAM_ID.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

VERSION="${THUMBLE_MAC_VERSION:-${THUMBCONSOLE_MAC_VERSION:-${POCKETPAD_MAC_VERSION:-}}}"
BUILD_NUMBER="${THUMBLE_MAC_BUILD_NUMBER:-${THUMBLE_BUILD_NUMBER:-${THUMBCONSOLE_MAC_BUILD_NUMBER:-${THUMBCONSOLE_BUILD_NUMBER:-${POCKETPAD_MAC_BUILD_NUMBER:-${POCKETPAD_BUILD_NUMBER:-}}}}}}"
RELEASE_NOTES="${THUMBLE_RELEASE_NOTES:-${THUMBCONSOLE_RELEASE_NOTES:-${POCKETPAD_RELEASE_NOTES:-}}}"
RELEASE_NOTES_FILE=""
SKIP_NOTARIZE=0
SKIP_UPLOAD=0
SKIP_XCODEGEN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="${2:-}"; shift 2 ;;
    --build-number)
      BUILD_NUMBER="${2:-}"; shift 2 ;;
    --release-notes)
      RELEASE_NOTES="${2:-}"; shift 2 ;;
    --release-notes-file)
      RELEASE_NOTES_FILE="${2:-}"; shift 2 ;;
    --skip-notarize)
      SKIP_NOTARIZE=1; shift ;;
    --skip-upload)
      SKIP_UPLOAD=1; shift ;;
    --skip-xcodegen)
      SKIP_XCODEGEN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "unknown option: $1" ;;
  esac
done

PROJECT="${THUMBLE_XCODE_PROJECT:-${THUMBCONSOLE_XCODE_PROJECT:-${POCKETPAD_XCODE_PROJECT:-Thumble.xcodeproj}}}"
SCHEME="${THUMBLE_MAC_SCHEME:-${THUMBCONSOLE_MAC_SCHEME:-${POCKETPAD_MAC_SCHEME:-ThumbleMac}}}"
CONFIGURATION="${CONFIGURATION:-Release}"
TEAM_ID="${THUMBLE_DEVELOPMENT_TEAM:-${THUMBCONSOLE_DEVELOPMENT_TEAM:-${POCKETPAD_DEVELOPMENT_TEAM:-67KC823C9A}}}"
EXPORT_OPTIONS="${THUMBLE_MAC_EXPORT_OPTIONS:-${THUMBCONSOLE_MAC_EXPORT_OPTIONS:-${POCKETPAD_MAC_EXPORT_OPTIONS:-Config/ExportOptions/Mac-DeveloperID.plist}}}"
ARTIFACT_ROOT="${THUMBLE_RELEASE_DIR:-${THUMBCONSOLE_RELEASE_DIR:-${POCKETPAD_RELEASE_DIR:-.release}}}"
BUCKET="${CF_RELEASES_BUCKET:-${THUMBLE_RELEASES_BUCKET:-${THUMBCONSOLE_RELEASES_BUCKET:-${POCKETPAD_RELEASES_BUCKET:-pocketpad-releases}}}}"
WEBSITE_ORIGIN="${THUMBLE_WEBSITE_ORIGIN:-${THUMBCONSOLE_WEBSITE_ORIGIN:-${POCKETPAD_WEBSITE_ORIGIN:-}}}"

[[ -d "$PROJECT" ]] || die "missing Xcode project: $PROJECT"
[[ -f "$EXPORT_OPTIONS" ]] || die "missing export options plist: $EXPORT_OPTIONS"
command -v xcodebuild >/dev/null || die "xcodebuild not found"
command -v asc >/dev/null || die "asc CLI not found; install/configure asc before releasing"
command -v python3 >/dev/null || die "python3 not found"

if [[ $SKIP_XCODEGEN -eq 0 && -f project.yml ]]; then
  if command -v xcodegen >/dev/null; then
    log "Regenerating Xcode project"
    xcodegen generate
  else
    echo "warning: xcodegen not found; using existing $PROJECT" >&2
  fi
fi

xcode_setting() {
  local key="$1"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings 2>/dev/null \
    | awk -F= -v key="$key" '
      $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
        value=$2
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        print value
        exit
      }'
}

if [[ -z "$VERSION" ]]; then
  VERSION="$(xcode_setting MARKETING_VERSION)"
fi
if [[ -z "$VERSION" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Mac/Info.plist 2>/dev/null || true)"
fi
[[ -n "$VERSION" ]] || die "could not determine version; pass --version"

if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(xcode_setting CURRENT_PROJECT_VERSION)"
fi
if [[ -z "$BUILD_NUMBER" ]]; then
  BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' Resources/Mac/Info.plist 2>/dev/null || true)"
fi
[[ -n "$BUILD_NUMBER" ]] || BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"

if [[ -n "$RELEASE_NOTES_FILE" ]]; then
  [[ -f "$RELEASE_NOTES_FILE" ]] || die "release notes file not found: $RELEASE_NOTES_FILE"
  RELEASE_NOTES="$(cat "$RELEASE_NOTES_FILE")"
fi

safe_version="$(python3 - <<'PY' "$VERSION-$BUILD_NUMBER"
import re, sys
print(re.sub(r'[^A-Za-z0-9._-]+', '-', sys.argv[1]).strip('-'))
PY
)"
release_dir="$ARTIFACT_ROOT/macos/$safe_version"
archive_path="$release_dir/ThumbleMac.xcarchive"
export_dir="$release_dir/export"
notary_zip="$release_dir/ThumbleMac-notary.zip"
final_zip="$release_dir/ThumbleMac-$safe_version.zip"
manifest_path="$release_dir/latest.json"
object_key="macos/$(basename "$final_zip")"
manifest_key="macos/latest.json"

rm -rf "$release_dir"
mkdir -p "$release_dir" "$export_dir"

log "Archiving $SCHEME $VERSION ($BUILD_NUMBER)"
asc xcode archive \
  --project "$PROJECT" \
  --scheme "$SCHEME" \
  --configuration "$CONFIGURATION" \
  --clean \
  --overwrite \
  --archive-path "$archive_path" \
  --xcodebuild-flag=-destination \
  --xcodebuild-flag=generic/platform=macOS \
  --xcodebuild-flag=DEVELOPMENT_TEAM="$TEAM_ID" \
  --xcodebuild-flag=MARKETING_VERSION="$VERSION" \
  --xcodebuild-flag=CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  --output json

log "Exporting Developer ID app"
xcodebuild -exportArchive \
  -archivePath "$archive_path" \
  -exportPath "$export_dir" \
  -exportOptionsPlist "$EXPORT_OPTIONS" \
  -allowProvisioningUpdates

app_path="$(find "$export_dir" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$app_path" ]] || die "export did not produce a .app in $export_dir"

verify_final_artifact() {
  # Export can re-sign the archive. Gate the actual shipped receiver, not just
  # Xcode settings; never confer HID privileges on CLI or other nested helpers.
  python3 "$repo_root/scripts/verify-hid-signing.py" "$app_path" --require-hid \
    --bundle-id com.codybontecou.PocketPadMac --team-id 67KC823C9A --distribution developer-id
}
log "Verifying exported HID signature and embedded profile"
verify_final_artifact

log "Creating notarization zip"
ditto -c -k --keepParent "$app_path" "$notary_zip"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
  command -v xcrun >/dev/null || die "xcrun not found"
  if [[ -n "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]; then
    log "Submitting notarization with keychain profile $NOTARYTOOL_KEYCHAIN_PROFILE"
    xcrun notarytool submit "$notary_zip" --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" --wait
  elif [[ -n "${APPLE_ID:-}" || -n "${APP_SPECIFIC_PASSWORD:-}" || -n "${ASC_TEAM_ID:-}" ]]; then
    [[ -n "${APPLE_ID:-}" ]] || die "APPLE_ID is required when using Apple ID notarization"
    [[ -n "${APP_SPECIFIC_PASSWORD:-}" ]] || die "APP_SPECIFIC_PASSWORD is required when using Apple ID notarization"
    [[ -n "${ASC_TEAM_ID:-}" ]] || die "ASC_TEAM_ID is required when using Apple ID notarization"
    log "Submitting notarization with Apple ID credentials"
    xcrun notarytool submit "$notary_zip" \
      --apple-id "$APPLE_ID" \
      --password "$APP_SPECIFIC_PASSWORD" \
      --team-id "$ASC_TEAM_ID" \
      --wait
  else
    log "Submitting notarization with asc API-key auth"
    asc notarization submit --file "$notary_zip" --wait --output json
  fi

  log "Stapling notarization ticket"
  xcrun stapler staple "$app_path"
  xcrun stapler validate "$app_path"
  spctl -a -vvv -t execute "$app_path" || true
else
  echo "warning: skipping notarization; Gatekeeper will warn users for this artifact" >&2
fi

log "Verifying final app before download packaging/upload"
verify_final_artifact
log "Creating final download zip"
rm -f "$final_zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$final_zip"

checksum="$(shasum -a 256 "$final_zip" | awk '{print $1}')"
size_bytes="$(stat -f%z "$final_zip" 2>/dev/null || stat -c%s "$final_zip")"
published_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
download_path="$(python3 - <<'PY' "$object_key"
from urllib.parse import quote
import sys
print('/api/download-mac?file=' + quote(sys.argv[1], safe=''))
PY
)"
if [[ -n "$WEBSITE_ORIGIN" ]]; then
  download_url="${WEBSITE_ORIGIN%/}$download_path"
else
  download_url="$download_path"
fi

export THUMBLE_MANIFEST_VERSION="$VERSION"
export THUMBLE_MANIFEST_BUILD="$BUILD_NUMBER"
export THUMBLE_MANIFEST_OBJECT_KEY="$object_key"
export THUMBLE_MANIFEST_DOWNLOAD_PATH="$download_path"
export THUMBLE_MANIFEST_DOWNLOAD_URL="$download_url"
export THUMBLE_MANIFEST_SHA256="$checksum"
export THUMBLE_MANIFEST_SIZE="$size_bytes"
export THUMBLE_MANIFEST_PUBLISHED_AT="$published_at"
export THUMBLE_MANIFEST_NOTARIZED="$([[ $SKIP_NOTARIZE -eq 0 ]] && echo true || echo false)"
export THUMBLE_MANIFEST_RELEASE_NOTES="$RELEASE_NOTES"

python3 - <<'PY' > "$manifest_path"
import json
import os
manifest = {
    "platform": "macOS",
    "name": "Thumble Mac",
    "version": os.environ["THUMBLE_MANIFEST_VERSION"],
    "buildNumber": os.environ["THUMBLE_MANIFEST_BUILD"],
    "minimumOS": "14.0",
    "objectKey": os.environ["THUMBLE_MANIFEST_OBJECT_KEY"],
    "downloadPath": os.environ["THUMBLE_MANIFEST_DOWNLOAD_PATH"],
    "downloadURL": os.environ["THUMBLE_MANIFEST_DOWNLOAD_URL"],
    "sha256": os.environ["THUMBLE_MANIFEST_SHA256"],
    "sizeBytes": int(os.environ["THUMBLE_MANIFEST_SIZE"]),
    "notarized": os.environ["THUMBLE_MANIFEST_NOTARIZED"] == "true",
    "publishedAt": os.environ["THUMBLE_MANIFEST_PUBLISHED_AT"],
    "releaseNotes": os.environ.get("THUMBLE_MANIFEST_RELEASE_NOTES", ""),
}
print(json.dumps(manifest, indent=2, sort_keys=True))
PY

if [[ $SKIP_UPLOAD -eq 0 ]]; then
  command -v wrangler >/dev/null || die "wrangler not found; install/configure Wrangler or pass --skip-upload"
  log "Uploading zip to Cloudflare R2: $BUCKET/$object_key"
  wrangler r2 object put "$BUCKET/$object_key" \
    --remote \
    --file "$final_zip" \
    --content-type application/zip \
    --content-disposition "attachment; filename=\"$(basename "$final_zip")\"" \
    --cache-control "public, max-age=31536000, immutable"

  log "Uploading latest manifest to Cloudflare R2: $BUCKET/$manifest_key"
  wrangler r2 object put "$BUCKET/$manifest_key" \
    --remote \
    --file "$manifest_path" \
    --content-type 'application/json; charset=utf-8' \
    --cache-control "public, max-age=60"
else
  echo "warning: skipping Cloudflare upload" >&2
fi

log "Done"
echo "zip:      $final_zip"
echo "manifest: $manifest_path"
echo "download: $download_url"
