#!/usr/bin/env bash
set -euo pipefail
umask 077
task_keychain_args=()
if [[ -n "${THUMBLE_SIGNING_KEYCHAIN:-}" ]]; then task_keychain_args=(--keychain "$THUMBLE_SIGNING_KEYCHAIN"); fi
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -lt 2 || $# -gt 3 || ( $# == 3 && "$3" != '--testflight' && "$3" != '--local-testing' ) ]]; then echo 'Usage: bash tools/build-macos-receiver.sh PROFILE_PATH SIGNING_IDENTITY [--testflight|--local-testing]' >&2; exit 2; fi
task_mode="${3:-production}"
task_config="$task_root/config/monetization.json"
task_entitlements="$task_root/tools/macos-hid-probe.entitlements"
task_swift_flags=()
if [[ "$task_mode" == '--local-testing' ]]; then
  task_swift_flags=(-D THUMBLE_LOCAL_TESTING)
fi
task_app="$task_root/build/Thumble Receiver.app"
if [[ "$task_mode" == '--testflight' ]]; then
  task_config="$task_root/config/monetization.sandbox.json"
  task_app="$task_root/build/Thumble TestFlight Receiver.app"
  task_entitlements="$task_root/build/receiver/TestFlight.entitlements"
  mkdir -p "$task_root/build/receiver"
fi
if [[ "$task_mode" == '--local-testing' ]]; then
  task_app="$task_root/build/Thumble Local Test Receiver.app"
fi
python3 - "$1" "$task_root/tools/macos-hid-probe.entitlements" "$task_entitlements" "$task_mode" "$task_config" <<'PY'
import datetime
import json
import plistlib, subprocess, sys
profile = plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', sys.argv[1]], capture_output=True, check=True).stdout)
with open(sys.argv[2], 'rb') as source:
    expected = plistlib.load(source)
with open(sys.argv[5]) as source:
    sandbox = 'sandbox' in json.load(source)['entitlementServiceURL']
if sandbox != (sys.argv[4] == '--testflight'):
    sys.exit('Sandbox verifier configuration requires --testflight; production builds require a production verifier.')
if sys.argv[4] == '--testflight':
    with open(sys.argv[3], 'wb') as output:
        plistlib.dump(expected, output)
actual = profile.get('Entitlements', {})
if actual.get('com.apple.application-identifier') != expected['com.apple.application-identifier'] or actual.get('com.apple.developer.hid.virtual.device') is not True:
    sys.exit('Use a provisioning profile matching the receiver identifier with the virtual HID capability. Both modes use the existing approved PocketPad Mac identity.')
if profile.get('ExpirationDate', datetime.datetime.min) <= datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None) or 'OSX' not in profile.get('Platform', []):
    sys.exit('The Mac provisioning profile is expired or for the wrong platform.')
if sys.argv[4] != '--testflight' and (profile.get('ProvisionedDevices') or not profile.get('ProvisionsAllDevices') or actual.get('get-task-allow')):
    sys.exit('Public distribution requires a Developer ID profile for all devices, without debug access.')
PY
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources/ThirdParty" "$task_root/build/receiver"
task_arches="arm64 x86_64"
if [[ "$task_mode" == '--testflight' ]]; then task_arches="$(uname -m)"; fi
for task_arch in $task_arches; do
  xcrun clang -target "$task_arch-apple-macosx15.0" -Wall -Wextra -Werror -fblocks -c "$task_root/apps/receiver/Sources/Gamepad.c" -o "$task_root/build/receiver/Gamepad-$task_arch.o"
  xcrun swiftc ${task_swift_flags[@]+"${task_swift_flags[@]}"} -target "$task_arch-apple-macosx15.0" -swift-version 5 -O -module-cache-path "$task_root/build/receiver/swift-cache" -import-objc-header "$task_root/apps/receiver/Sources/Gamepad.h" "$task_root"/apps/receiver/Sources/*.swift "$task_root/build/receiver/Gamepad-$task_arch.o" -framework AppKit -framework Network -framework Security -framework CryptoKit -framework IOKit -o "$task_root/build/receiver/thumble-receiver-$task_arch"
done
if [[ "$task_mode" == '--testflight' ]]; then
  cp "$task_root/build/receiver/thumble-receiver-$task_arches" "$task_app/Contents/MacOS/thumble-receiver"
else
  xcrun lipo -create "$task_root/build/receiver/thumble-receiver-arm64" "$task_root/build/receiver/thumble-receiver-x86_64" -output "$task_app/Contents/MacOS/thumble-receiver"
fi
cp "$task_config" "$task_app/Contents/Resources/Monetization.json"
node "$task_root/packages/desktop-workspace/build.mjs"
mkdir -p "$task_app/Contents/Resources/Workspace"
cp "$task_root/build/desktop-workspace/"* "$task_app/Contents/Resources/Workspace/"
node "$task_root/tools/export-builtin-profiles.mjs"
cp "$task_root/apps/receiver/Resources/BuiltInProfiles.json" "$task_app/Contents/Resources/BuiltInProfiles.json"
cp "$task_root/apps/receiver/Info.plist" "$task_app/Contents/Info.plist"
if [[ "$task_mode" == '--testflight' ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Thumble TestFlight Receiver' "$task_app/Contents/Info.plist"
fi
if [[ "$task_mode" == '--local-testing' ]]; then
  /usr/libexec/PlistBuddy -c 'Set :CFBundleName Thumble Local Test Receiver' "$task_app/Contents/Info.plist"
fi
cp "$1" "$task_app/Contents/embedded.provisionprofile"
cp "$task_root/ThirdParty/SteamControllerBridge-LICENSE.txt" "$task_app/Contents/Resources/ThirdParty/"
cp "$task_root/apps/receiver/Resources/AppIcon.icns" "$task_app/Contents/Resources/AppIcon.icns"
if [[ "$task_mode" == '--testflight' ]]; then
  codesign ${task_keychain_args[@]+"${task_keychain_args[@]}"} --force --options runtime --timestamp=none --sign "$2" --entitlements "$task_entitlements" "$task_app"
else
  find "$task_app" -type d -exec chmod 755 {} +
  find "$task_app" -type f -exec chmod 644 {} +
  chmod 755 "$task_app/Contents/MacOS/thumble-receiver"
  codesign ${task_keychain_args[@]+"${task_keychain_args[@]}"} --force --options runtime --timestamp --sign "$2" --entitlements "$task_entitlements" "$task_app"
  codesign -d --extract-certificates="$task_root/build/receiver/signing-" "$task_app"
  python3 - "$1" "$task_root/build/receiver/signing-0" <<'PY'
import plistlib, subprocess, sys
profile = plistlib.loads(subprocess.run(['security', 'cms', '-D', '-i', sys.argv[1]], capture_output=True, check=True).stdout)
with open(sys.argv[2], 'rb') as source:
    certificate = source.read()
if certificate not in profile['DeveloperCertificates']:
    sys.exit('The signing certificate is not authorized by the embedded provisioning profile.')
PY
  codesign -dv --verbose=4 "$task_app" 2> "$task_root/build/receiver/signature.txt"
  if ! rg -q '^Authority=Developer ID Application:' "$task_root/build/receiver/signature.txt" || ! rg -q '^Timestamp=' "$task_root/build/receiver/signature.txt"; then
    echo 'Public distribution requires Developer ID Application signing and a secure timestamp.' >&2; exit 1
  fi
fi
codesign --verify --strict "$task_app"
echo "Built: $task_app"
