#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/Host/Cargo.toml"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-1.88.0}"

[[ -f "$MANIFEST" ]] || { echo "Missing Rust host manifest: $MANIFEST" >&2; exit 1; }

python3 "$ROOT_DIR/scripts/verify-mcp-cli-parity.py"
python3 "$ROOT_DIR/scripts/verify-hosted-builder-capabilities.py"
python3 "$ROOT_DIR/scripts/verify-cli-profile-persistence-allowlist.py"

for script in \
  "$ROOT_DIR/scripts/verify-profile-artifact-flow.sh" \
  "$ROOT_DIR/scripts/verify-generation-spec-flow.sh" \
  "$ROOT_DIR/scripts/verify-controller-template-fixtures.sh" \
  "$ROOT_DIR/scripts/verify-hosted-builder-local.sh" \
  "$ROOT_DIR/scripts/test-gateway-start.sh" \
  "$ROOT_DIR/scripts/install-relay-launch-agent.sh" \
  "$ROOT_DIR/Host/crates/thumble-gateway/backup.sh" \
  "$ROOT_DIR/Host/crates/thumble-gateway/start.sh"; do
  bash -n "$script"
done
grep -Fq 'install-relay-launch-agent.sh' "$ROOT_DIR/scripts/release/macos-host.sh" || {
  echo "macOS host release does not package the relay LaunchAgent installer." >&2
  exit 1
}

BRANDING_PATTERN='PocketPad Host|PocketPad MCP|PocketPad (skin|controller)|PocketPad(Skin|Mcp)|pocketpad-(host|mcp|core|protocol)|POCKETPAD NATIVE'
if grep -RInE "$BRANDING_PATTERN" \
  "$ROOT_DIR/Host/crates" \
  "$ROOT_DIR/Sources" \
  "$ROOT_DIR/Tests" \
  "$ROOT_DIR/Resources/Host" \
  "$ROOT_DIR/README.md" \
  "$ROOT_DIR/docs/rust-host.md" \
  "$ROOT_DIR/docs/skins" \
  "$ROOT_DIR/docs/stack-safety.md" \
  "$ROOT_DIR/AGENTS.md" \
  "$ROOT_DIR/.pi/agents" \
  "$ROOT_DIR/.pi/skills/thumble-skin-author"; then
  echo "Found pre-rename product branding outside compatibility identifiers." >&2
  exit 1
fi

if command -v rustup >/dev/null 2>&1; then
  TOOLCHAIN_BIN="$(dirname "$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc)")"
  export PATH="$TOOLCHAIN_BIN:$PATH"
fi

cargo fmt --manifest-path "$MANIFEST" --all --check
cargo clippy --locked --manifest-path "$MANIFEST" --workspace --all-targets --all-features -- -D warnings
cargo test --locked --manifest-path "$MANIFEST" --workspace --all-features
cargo check --locked --manifest-path "$MANIFEST" --package thumble-host --package thumble-mcp --package thumble-tunnel --package thumble-gateway --package thumble-builder --all-targets

echo "Thumble Rust host and MCP verification passed."
