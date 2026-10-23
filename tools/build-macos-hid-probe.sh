#!/usr/bin/env bash
# Build locally only. Does not install, launch, notarize or publish the probe.
set -euo pipefail
umask 077
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# != 2 ]]; then
  echo 'Usage: bash tools/build-macos-hid-probe.sh PROFILE_PATH SIGNING_IDENTITY' >&2
  exit 2
fi
task_profile="$1"
task_identity="$2"
if [[ "$task_identity" == '-' ]]; then
  echo 'This probe requires a real Apple Development identity and matching HID profile.' >&2
  exit 2
fi
python3 - "$task_profile" <<'PY'
import datetime, plistlib, subprocess, sys
result = subprocess.run(['security', 'cms', '-D', '-i', sys.argv[1]], capture_output=True, check=True)
profile = plistlib.loads(result.stdout)
entitlements = profile.get('Entitlements', {})
assert profile.get('ExpirationDate') > datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None), 'Expired profile'
assert profile.get('TeamIdentifier') == ['67KC823C9A'], 'Wrong team'
assert entitlements.get('com.apple.application-identifier') == '67KC823C9A.com.codybontecou.PocketPadMac', 'Wrong App ID'
assert entitlements.get('com.apple.developer.hid.virtual.device') is True, 'Profile does not authorize virtual HID'
assert 'OSX' in profile.get('Platform', []), 'Not a Mac profile'
print('Profile metadata matches Thumble Mac and includes virtual HID.')
PY
task_app="$task_root/build/Tapping HID Probe.app"
mkdir -p "$task_app/Contents/MacOS"
mkdir -p "$task_app/Contents/Resources/ThirdParty"
xcrun clang -Wall -Wextra -Werror -fblocks -framework IOKit -framework CoreFoundation \
  "$task_root/tools/macos-hid-probe.c" -o "$task_app/Contents/MacOS/tapping-hid-probe"
cp "$task_root/tools/macos-hid-probe-Info.plist" "$task_app/Contents/Info.plist"
cp "$task_profile" "$task_app/Contents/embedded.provisionprofile"
cp "$task_root/ThirdParty/SteamControllerBridge-LICENSE.txt" "$task_app/Contents/Resources/ThirdParty/"
codesign --force --options runtime --timestamp=none --sign "$task_identity" \
  --entitlements "$task_root/tools/macos-hid-probe.entitlements" "$task_app"
codesign --verify --strict "$task_app"
echo "Built: $task_app"
