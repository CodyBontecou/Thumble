#!/usr/bin/env bash
set -euo pipefail

LABEL="com.codybontecou.thumble.mcp-relay"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
URL="${THUMBLE_MCP_RELAY_URL:-wss://thumble-mcp-gateway.fly.dev/tunnel}"
BINARY="${THUMBLE_MCP_BINARY:-/Applications/Thumble Host.app/Contents/MacOS/thumble-mcp}"
ALLOW_CONFIG_WRITE=0

while (($#)); do
  case "$1" in
    --allow-config-write) ALLOW_CONFIG_WRITE=1 ;;
    --url) shift; URL="${1:?--url requires a value}" ;;
    --binary) shift; BINARY="${1:?--binary requires a path}" ;;
    --uninstall)
      launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
      rm -f "$PLIST"
      echo "Removed $LABEL"
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[[ -x "$BINARY" ]] || { echo "thumble-mcp is not executable: $BINARY" >&2; exit 1; }
mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs/Thumble"

python3 - "$PLIST" "$LABEL" "$BINARY" "$URL" "$ALLOW_CONFIG_WRITE" "$HOME" <<'PY'
import plistlib, sys
path, label, binary, url, allow, home = sys.argv[1:]
args = [binary, "--relay", url]
if allow == "1":
    args.append("--allow-config-write")
payload = {
    "Label": label,
    "ProgramArguments": args,
    "RunAtLoad": True,
    "KeepAlive": {"SuccessfulExit": False},
    "ThrottleInterval": 10,
    "ProcessType": "Background",
    "StandardOutPath": f"{home}/Library/Logs/Thumble/mcp-relay.log",
    "StandardErrorPath": f"{home}/Library/Logs/Thumble/mcp-relay-error.log",
}
with open(path, "wb") as output:
    plistlib.dump(payload, output, sort_keys=True)
PY
chmod 600 "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"
echo "Installed and started $LABEL"
echo "Status: launchctl print gui/$UID/$LABEL"
echo "Note: the packaged CLI equivalent is 'thumble relay install' (and 'thumble relay doctor' verifies readiness)."
