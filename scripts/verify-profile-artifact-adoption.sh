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

# Opt in to the existing project when local project/scheme edits must be kept.
case "${PROFILE_ARTIFACT_ADOPTION_SKIP_PROJECT_GENERATION:-0}" in
  0) xcodegen generate ;;
  1) echo "Using existing Thumble.xcodeproj; project generation explicitly skipped." ;;
  *) echo "PROFILE_ARTIFACT_ADOPTION_SKIP_PROJECT_GENERATION must be 0 or 1" >&2; exit 2 ;;
esac
ARTIFACT_DERIVED_DATA_PATH="${PROFILE_ARTIFACT_ADOPTION_DERIVED_DATA_PATH:-$ROOT/build/ProfileArtifactAdoptionDerivedData}"
XCODEBUILD_ARGS+=(-derivedDataPath "$ARTIFACT_DERIVED_DATA_PATH")
export STACK_SAFETY_DERIVED_DATA_PATH="${STACK_SAFETY_DERIVED_DATA_PATH:-$ARTIFACT_DERIVED_DATA_PATH}"

xcodebuild test \
  "${XCODEBUILD_ARGS[@]}" \
  -scheme ThumbleTests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:ThumbleCLITests/PortableProfileArtifactTests \
  -only-testing:ThumbleCLITests/IOSPendingBuilderArtifactStoreTests \
  -only-testing:ThumbleCLITests/IOSLocalKeypadUXTests \
  -only-testing:ThumbleCLITests/PendingProfileRecoveryTests \
  -only-testing:ThumbleCLITests/MacSharedKeypadImportTests \
  -only-testing:ThumbleCLITests/ProfileArtifactAdoptionTests

xcodebuild build \
  "${XCODEBUILD_ARGS[@]}" \
  -scheme ThumbleiOS \
  -destination 'generic/platform=iOS Simulator'

xcodebuild build \
  "${XCODEBUILD_ARGS[@]}" \
  -scheme ThumbleMac \
  -destination 'platform=macOS,arch=arm64'

./scripts/verify-stack-safety.sh
python3 scripts/verify-mcp-cli-parity.py
python3 scripts/verify-apple-hosted-retirement.py \
  --ios-app "$ARTIFACT_DERIVED_DATA_PATH/Build/Products/Debug-iphonesimulator/Thumble.app" \
  --mac-app "$ARTIFACT_DERIVED_DATA_PATH/Build/Products/Debug/Thumble Mac.app"

echo "local profile import, read-only recovery and retired-adoption rejection verification passed"
