#!/usr/bin/env bash
set -euo pipefail
umask 077
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# != 2 ]]; then echo 'Usage: bash tools/build-macos-receiver.sh PROFILE_PATH SIGNING_IDENTITY' >&2; exit 2; fi
task_app="$task_root/build/Tapping Receiver.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources/ThirdParty" "$task_root/build/receiver"
xcrun clang -Wall -Wextra -Werror -fblocks -c "$task_root/apps/receiver/Sources/Gamepad.c" -o "$task_root/build/receiver/Gamepad.o"
xcrun swiftc -swift-version 5 -O -import-objc-header "$task_root/apps/receiver/Sources/Gamepad.h" "$task_root"/apps/receiver/Sources/*.swift "$task_root/build/receiver/Gamepad.o" -framework AppKit -framework Network -framework Security -framework CryptoKit -framework IOKit -o "$task_app/Contents/MacOS/tapping-receiver"
cp "$task_root/config/monetization.json" "$task_app/Contents/Resources/Monetization.json"
cp "$task_root/apps/receiver/Info.plist" "$task_app/Contents/Info.plist"
cp "$1" "$task_app/Contents/embedded.provisionprofile"
cp "$task_root/ThirdParty/SteamControllerBridge-LICENSE.txt" "$task_app/Contents/Resources/ThirdParty/"
codesign --force --options runtime --timestamp=none --sign "$2" --entitlements "$task_root/tools/macos-hid-probe.entitlements" "$task_app"
codesign --verify --strict "$task_app"
echo "Built: $task_app"
