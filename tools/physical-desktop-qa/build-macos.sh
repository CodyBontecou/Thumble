#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
app="$root/build/Thumble Hardware QA.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Workspace" build/physical-desktop-qa
node packages/desktop-workspace/build.mjs
cp build/desktop-workspace/* "$app/Contents/Resources/Workspace/"
cp apps/receiver/Resources/{BuiltInProfiles,DesktopKeys}.json "$app/Contents/Resources/"
cp config/monetization.json "$app/Contents/Resources/Monetization.json"
node --input-type=module -e 'import fs from "node:fs"; import {desktopProfile} from "./packages/desktop-workspace/src/model.js"; fs.writeFileSync("build/Thumble Hardware QA.app/Contents/Resources/Fixture.json",JSON.stringify({...desktopProfile,id:"desktop-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",name:"Physical phone QA"}));'
python3 - <<'PY'
from pathlib import Path
s=Path('apps/receiver/Sources/Receiver.swift').read_text()
old='private let desktopOutput = DesktopInput()'
assert s.count(old)==1, 'Refuse to build without the isolated input sink'
s=s.replace(old,'private let desktopOutput = DesktopInput(post: QAInput.capture, trusted: { true })')
s=s.replace('"receiverId": accessInfo["receiverId"] ?? ""', '"receiverId": accessInfo["receiverId"] ?? "", "qaAccess": accessInfo, "qaPlayRequested": playRequested, "qaOutputAllowed": outputAllowed, "qaPaused": paused')
Path('build/physical-desktop-qa/Receiver.swift').write_text(s)
PY
xcrun clang -c tools/access-receiver-tests/GamepadStub.c -o build/physical-desktop-qa/stub.o
sources=()
for source in apps/receiver/Sources/*.swift; do
  case "$source" in */main.swift|*/Receiver.swift) ;; *) sources+=("$source");; esac
done
xcrun swiftc -swift-version 5 -D THUMBLE_LOCAL_TESTING -module-cache-path build/swift-module-cache -import-objc-header apps/receiver/Sources/Gamepad.h "${sources[@]}" build/physical-desktop-qa/Receiver.swift tools/physical-desktop-qa/main.swift build/physical-desktop-qa/stub.o -o "$app/Contents/MacOS/hardware-qa"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.thumble.hardware.qa</string><key>CFBundleName</key><string>Thumble Hardware QA</string><key>CFBundleExecutable</key><string>hardware-qa</string><key>CFBundlePackageType</key><string>APPL</string><key>NSLocalNetworkUsageDescription</key><string>Connect the owner's physical phones to the isolated QA receiver.</string></dict></plist>
PLIST
echo "$app"
