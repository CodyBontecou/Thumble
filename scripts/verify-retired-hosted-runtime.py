#!/usr/bin/env python3
"""Keep hosted transports out of the local runtime and release packaging."""
from pathlib import Path

root = Path(__file__).resolve().parent.parent
workspace = (root / "Host/Cargo.toml").read_text()
for name in ["thumble-gateway", "thumble-tunnel", "thumble-builder"]:
    assert not (root / "Host/crates" / name).exists(), f"Retired hosted crate: {name}"
    assert f'"crates/{name}"' not in workspace
for name in ["thumble-core", "thumble-host", "thumble-mcp", "thumble-cli-bridge", "thumble-protocol", "thumble-receiver"]:
    assert f'"crates/{name}"' in workspace, f"Retained local component missing: {name}"

assert not (root / "fly.toml").exists()
assert not (root / "Host/crates/thumble-mcp/src/relay.rs").exists()
assert not (root / "scripts/install-relay-launch-agent.sh").exists()
adapter = (root / "Host/crates/thumble-mcp/src/main.rs").read_text()
for field in ["relay:", "relay_link:", "relay_relink:", "relay_revoke:", "relay_doctor:"]:
    assert field not in adapter, f"Retired MCP transport flag: {field}"
assert "decode_stdio_request" in adapter and ".serve((output, input))" in adapter
assert 'control_socket: Option<PathBuf>' in adapter
release = (root / "scripts/release/macos-host.sh").read_text()
assert 'install-relay-launch-agent' not in release
assert 'thumble-mcp' in release and 'thumble-cli-bridge' in release
print("Hosted gateway, builder, relay, and installer retired; local runtime remains packaged")
