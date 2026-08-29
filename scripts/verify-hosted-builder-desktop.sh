#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

XCODEBUILD_ARGS=(
  -project Thumble.xcodeproj
  CODE_SIGNING_ALLOWED=NO
  COMPILER_INDEX_STORE_ENABLE=NO
  -jobs 2
)

xcodegen generate

xcodebuild test \
  "${XCODEBUILD_ARGS[@]}" \
  -scheme ThumbleTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ThumbleCLITests/MacSharedKeypadImportTests \
  -only-testing:ThumbleCLITests/BuilderArtifactShareTests \
  -only-testing:ThumbleCLITests/IOSBuilderArtifactPickupTests \
  -only-testing:ThumbleCLITests/ProfileArtifactAdoptionTests

xcodebuild build \
  "${XCODEBUILD_ARGS[@]}" \
  -scheme ThumbleMac \
  -destination 'platform=macOS,arch=arm64'

echo "hosted-builder desktop adoption verification passed"
