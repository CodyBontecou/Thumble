#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="${STACK_SAFETY_DERIVED_DATA_PATH:-$ROOT_DIR/build/StackSafetyDerivedData}"
PROJECT_PATH="$ROOT_DIR/Thumble.xcodeproj"
HOST_ARCH="$(uname -m)"

if [[ "$HOST_ARCH" != "arm64" ]]; then
  printf 'error: stack-safety verification requires an arm64 host, found %s\n' "$HOST_ARCH" >&2
  exit 2
fi

printf '%s\n' "==> Host architecture: $HOST_ARCH"
printf '%s\n' "==> Verifying Debug arm64 build settings"
MAC_BUILD_SETTINGS="$(
  xcodebuild -showBuildSettings \
    -project "$PROJECT_PATH" \
    -scheme ThumbleCLI \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64'
)"
IOS_BUILD_SETTINGS="$(
  xcodebuild -showBuildSettings \
    -project "$PROJECT_PATH" \
    -scheme ThumbleiOS \
    -configuration Debug \
    -destination 'generic/platform=iOS'
)"
for settings in "$MAC_BUILD_SETTINGS" "$IOS_BUILD_SETTINGS"; do
  grep -Eq '^[[:space:]]*ARCHS = .*arm64' <<<"$settings" || {
    printf '%s\n' 'error: expected arm64 in resolved ARCHS' >&2
    exit 2
  }
  grep -Eq '^[[:space:]]*SWIFT_OPTIMIZATION_LEVEL = -Onone' <<<"$settings" || {
    printf '%s\n' 'error: expected SWIFT_OPTIMIZATION_LEVEL = -Onone' >&2
    exit 2
  }
done
printf '%s\n' "  macOS: $(grep -m1 -E '^[[:space:]]*ARCHS = ' <<<"$MAC_BUILD_SETTINGS" | xargs); $(grep -m1 -E '^[[:space:]]*SWIFT_OPTIMIZATION_LEVEL = ' <<<"$MAC_BUILD_SETTINGS" | xargs)"
printf '%s\n' "  iOS: $(grep -m1 -E '^[[:space:]]*ARCHS = ' <<<"$IOS_BUILD_SETTINGS" | xargs); $(grep -m1 -E '^[[:space:]]*SWIFT_OPTIMIZATION_LEVEL = ' <<<"$IOS_BUILD_SETTINGS" | xargs)"

printf '%s\n' "==> Verifying stack-frame parser"
python3 "$ROOT_DIR/scripts/check-controller-stack-frames.py" --self-test

printf '%s\n' "==> Running constrained-stack regression tests"
xcodebuild test \
  -project "$PROJECT_PATH" \
  -scheme ThumbleTests \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -only-testing:ThumbleCLITests/StackSafetyRegressionTests \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO

printf '%s\n' "==> Building macOS Debug target with network stack budgets"
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme ThumbleMac \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO

printf '%s\n' "==> Building iOS Debug target with static stack budgets"
xcodebuild build \
  -project "$PROJECT_PATH" \
  -scheme ThumbleiOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  COMPILER_INDEX_STORE_ENABLE=NO

printf '%s\n' "Stack-safety verification passed."
