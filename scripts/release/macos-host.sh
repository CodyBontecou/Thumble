#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUTPUT_DIR="${OUTPUT_DIR:-}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARYTOOL_KEYCHAIN_PROFILE="${NOTARYTOOL_KEYCHAIN_PROFILE:-}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.88.0}"

usage() {
  cat <<'USAGE'
Build a universal macOS Thumble Host app bundle.

Usage: scripts/release/macos-host.sh [options]
  --version VERSION          Bundle/package version (default: 0.1.0)
  --build-number NUMBER      Bundle build number (default: 1)
  --output DIR               Release output directory
  --sign IDENTITY            Developer ID Application identity (default: ad-hoc)
  --notary-profile PROFILE   notarytool keychain profile; requires --sign

The script builds arm64 and x86_64 host, MCP, standalone CLI, constrained CLI authority bridge,
and constrained Swift bridge binaries, combines them with lipo, creates a background-only app bundle, signs it (ad-hoc by default),
optionally notarizes it, and emits a ZIP plus SHA-256 checksum.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --build-number) BUILD_NUMBER="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    --sign) SIGNING_IDENTITY="$2"; shift 2 ;;
    --notary-profile) NOTARYTOOL_KEYCHAIN_PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in rustup lipo ditto plutil shasum codesign xcodegen xcodebuild; do
  command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done

OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/.release/thumble-host-$VERSION}"

if [[ -n "$NOTARYTOOL_KEYCHAIN_PROFILE" && -z "$SIGNING_IDENTITY" ]]; then
  echo "--notary-profile requires --sign" >&2
  exit 2
fi

MANIFEST="$ROOT_DIR/Host/Cargo.toml"
INFO_PLIST="$ROOT_DIR/Resources/Host/Info.plist"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
[[ -f "$MANIFEST" ]] || { echo "Missing Rust host manifest: $MANIFEST" >&2; exit 1; }
[[ -f "$INFO_PLIST" ]] || { echo "Missing host Info.plist: $INFO_PLIST" >&2; exit 1; }

if [[ -L "$OUTPUT_DIR" ]]; then
  echo "Refusing symlink release output: $OUTPUT_DIR" >&2
  exit 2
fi
if [[ -e "$OUTPUT_DIR" && ! -f "$OUTPUT_DIR/.thumble-host-release-dir" ]]; then
  echo "Refusing to replace unmarked release output: $OUTPUT_DIR" >&2
  exit 2
fi

rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --component rustfmt --component clippy
rustup target add --toolchain "$RUST_TOOLCHAIN" aarch64-apple-darwin x86_64-apple-darwin
"$ROOT_DIR/scripts/verify-rust-host.sh"
RUSTC_BIN="$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc)"
RUSTDOC_BIN="$(rustup which --toolchain "$RUST_TOOLCHAIN" rustdoc)"
RUSTC="$RUSTC_BIN" RUSTDOC="$RUSTDOC_BIN" rustup run "$RUST_TOOLCHAIN" cargo build --locked --manifest-path "$MANIFEST" -p thumble-host -p thumble-mcp -p thumble-cli-bridge --release --target aarch64-apple-darwin
RUSTC="$RUSTC_BIN" RUSTDOC="$RUSTDOC_BIN" rustup run "$RUST_TOOLCHAIN" cargo build --locked --manifest-path "$MANIFEST" -p thumble-host -p thumble-mcp -p thumble-cli-bridge --release --target x86_64-apple-darwin

xcodegen generate --spec "$ROOT_DIR/project.yml" --project "$ROOT_DIR"
SWIFT_BUILD_ROOT="$ROOT_DIR/Host/target/swift-bridge-release"
rm -rf "$SWIFT_BUILD_ROOT"
xcodebuild -project "$ROOT_DIR/Thumble.xcodeproj" -scheme ThumbleBridge \
  -configuration Release -sdk macosx -arch arm64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$SWIFT_BUILD_ROOT/arm64" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project "$ROOT_DIR/Thumble.xcodeproj" -scheme ThumbleBridge \
  -configuration Release -sdk macosx -arch x86_64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$SWIFT_BUILD_ROOT/x86_64" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project "$ROOT_DIR/Thumble.xcodeproj" -scheme ThumbleCLI \
  -configuration Release -sdk macosx -arch arm64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$SWIFT_BUILD_ROOT/arm64" CODE_SIGNING_ALLOWED=NO build
xcodebuild -project "$ROOT_DIR/Thumble.xcodeproj" -scheme ThumbleCLI \
  -configuration Release -sdk macosx -arch x86_64 ONLY_ACTIVE_ARCH=YES \
  -derivedDataPath "$SWIFT_BUILD_ROOT/x86_64" CODE_SIGNING_ALLOWED=NO build

rm -rf "$OUTPUT_DIR"
APP_DIR="$OUTPUT_DIR/Thumble Host.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
touch "$OUTPUT_DIR/.thumble-host-release-dir"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP_DIR/Contents/Info.plist"
plutil -lint "$APP_DIR/Contents/Info.plist"

lipo -create \
  "$ROOT_DIR/Host/target/aarch64-apple-darwin/release/thumble-host" \
  "$ROOT_DIR/Host/target/x86_64-apple-darwin/release/thumble-host" \
  -output "$MACOS_DIR/thumble-host"
lipo -create \
  "$ROOT_DIR/Host/target/aarch64-apple-darwin/release/thumble-mcp" \
  "$ROOT_DIR/Host/target/x86_64-apple-darwin/release/thumble-mcp" \
  -output "$MACOS_DIR/thumble-mcp"
lipo -create \
  "$ROOT_DIR/Host/target/aarch64-apple-darwin/release/thumble-cli-bridge" \
  "$ROOT_DIR/Host/target/x86_64-apple-darwin/release/thumble-cli-bridge" \
  -output "$MACOS_DIR/thumble-cli-bridge"
lipo -create \
  "$SWIFT_BUILD_ROOT/arm64/Build/Products/Release/thumble-bridge" \
  "$SWIFT_BUILD_ROOT/x86_64/Build/Products/Release/thumble-bridge" \
  -output "$MACOS_DIR/thumble-bridge"
lipo -create \
  "$SWIFT_BUILD_ROOT/arm64/Build/Products/Release/thumble" \
  "$SWIFT_BUILD_ROOT/x86_64/Build/Products/Release/thumble" \
  -output "$MACOS_DIR/thumble"
for executable in thumble-host thumble-mcp thumble-cli-bridge thumble-bridge thumble; do
  lipo "$MACOS_DIR/$executable" -verify_arch arm64 x86_64
done
chmod 755 "$MACOS_DIR/thumble-host" "$MACOS_DIR/thumble-mcp" "$MACOS_DIR/thumble-cli-bridge" "$MACOS_DIR/thumble-bridge" "$MACOS_DIR/thumble"
cp "$ROOT_DIR/scripts/install-relay-launch-agent.sh" "$RESOURCES_DIR/install-relay-launch-agent.sh"
chmod 755 "$RESOURCES_DIR/install-relay-launch-agent.sh"
bash -n "$RESOURCES_DIR/install-relay-launch-agent.sh"

if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$MACOS_DIR/thumble-mcp"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$MACOS_DIR/thumble"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$MACOS_DIR/thumble-cli-bridge"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$MACOS_DIR/thumble-bridge"
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
  # Ad-hoc signing makes local/debug bundles structurally complete. Stable
  # Accessibility approval and distribution still require Developer ID signing.
  codesign --force --options runtime --sign - "$MACOS_DIR/thumble-mcp"
  codesign --force --options runtime --sign - "$MACOS_DIR/thumble"
  codesign --force --options runtime --sign - "$MACOS_DIR/thumble-cli-bridge"
  codesign --force --options runtime --sign - "$MACOS_DIR/thumble-bridge"
  codesign --force --options runtime --sign - "$APP_DIR"
fi
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

ZIP_PATH="$OUTPUT_DIR/ThumbleHost-$VERSION-macOS-universal.zip"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

if [[ -n "$NOTARYTOOL_KEYCHAIN_PROFILE" ]]; then
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARYTOOL_KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$APP_DIR"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
fi

shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"
file "$MACOS_DIR/thumble-host" "$MACOS_DIR/thumble-mcp" "$MACOS_DIR/thumble" "$MACOS_DIR/thumble-cli-bridge" "$MACOS_DIR/thumble-bridge"
echo "Built $ZIP_PATH"
