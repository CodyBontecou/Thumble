#!/usr/bin/env bash
# Run after build-macos-receiver.sh with the same Developer ID identity.
set -euo pipefail
umask 077
task_keychain_args=()
if [[ -n "${THUMBLE_SIGNING_KEYCHAIN:-}" ]]; then task_keychain_args=(--keychain "$THUMBLE_SIGNING_KEYCHAIN"); fi
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# != 1 ]]; then
  echo 'Usage: bash tools/package-macos-receiver.sh "Developer ID Application identity"' >&2
  exit 2
fi
task_app="$task_root/build/Thumble Receiver.app"
task_release="$task_root/build/distribution"
task_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$task_app/Contents/Info.plist")"
task_dmg="$task_release/Thumble-Receiver-$task_version.dmg"
mkdir -p "$task_release"
codesign --verify --strict "$task_app"
codesign -dv --verbose=4 "$task_app" 2> "$task_release/app-signature.txt"
if ! rg -q '^Authority=Developer ID Application:' "$task_release/app-signature.txt" || ! rg -q '^Timestamp=' "$task_release/app-signature.txt"; then
  echo 'Build with Developer ID Application signing and a secure timestamp first.' >&2
  exit 1
fi
python3 - "$task_app" <<'PY'
import json, plistlib, subprocess, sys
from pathlib import Path
app = Path(sys.argv[1])
config = json.loads((app / 'Contents/Resources/Monetization.json').read_text())
if 'sandbox' in config['entitlementServiceURL']:
    sys.exit('Cannot distribute a sandbox-only receiver.')
profile = plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', str(app / 'Contents/embedded.provisionprofile')], capture_output=True, check=True).stdout)
if not profile.get('ProvisionsAllDevices') or profile.get('ProvisionedDevices') or profile['Entitlements'].get('get-task-allow'):
    sys.exit('A Developer ID provisioning profile is required.')
PY
ditto -c -k --keepParent "$task_app" "$task_release/Thumble-Receiver-notarization.zip"
asc notarization submit --file "$task_release/Thumble-Receiver-notarization.zip" --wait --poll-interval 30s --output json > "$task_release/app-notarization.json"
xcrun stapler staple "$task_app"
xcrun stapler validate "$task_app"
spctl --assess --type execute --verbose=2 "$task_app"
task_stage="$(mktemp -d "$task_release/dmg-stage.XXXXXX")"
trap 'rm -rf "$task_stage"' EXIT
ditto "$task_app" "$task_stage/Thumble Receiver.app"
ln -s /Applications "$task_stage/Applications"
hdiutil create -volname 'Thumble Receiver' -srcfolder "$task_stage" -format UDZO -ov "$task_dmg"
chmod 644 "$task_dmg"
codesign "${task_keychain_args[@]}" --force --timestamp --sign "$1" "$task_dmg"
asc notarization submit --file "$task_dmg" --wait --poll-interval 30s --output json > "$task_release/dmg-notarization.json"
xcrun stapler staple "$task_dmg"
xcrun stapler validate "$task_dmg"
codesign --verify --strict "$task_dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$task_dmg"
(cd "$task_release" && shasum -a 256 "$(basename "$task_dmg")" > "$(basename "$task_dmg").sha256")
echo "Ready for distribution: $task_dmg"
