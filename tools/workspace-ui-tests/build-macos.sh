#!/usr/bin/env bash
set -euo pipefail
task_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
task_app="$task_root/build/Thumble Studio QA.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources/Workspace"
node "$task_root/packages/desktop-workspace/build.mjs"
cp "$task_root/build/desktop-workspace/"* "$task_app/Contents/Resources/Workspace/"
cp "$task_root/apps/receiver/Resources/BuiltInProfiles.json" "$task_app/Contents/Resources/"
xcrun swiftc -swift-version 5 -module-cache-path "$task_root/build/workspace-tests/swift-cache" \
  "$task_root/apps/receiver/Sources/WorkspaceWindow.swift" "$task_root/apps/receiver/Sources/WorkspaceProfiles.swift" \
  "$task_root/apps/receiver/Sources/CloudProfile.swift" "$task_root/apps/receiver/Sources/ProfileCatalog.swift" \
  "$task_root/tools/workspace-ui-tests/main.swift" -o "$task_app/Contents/MacOS/workspace-qa"
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.thumble.studio.qa</string><key>CFBundleName</key><string>Thumble Studio QA</string><key>CFBundleExecutable</key><string>workspace-qa</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
echo "$task_app"
