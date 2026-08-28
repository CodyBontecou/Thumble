#!/usr/bin/env bash
# Fail if the plugin's bundled skill copy has drifted from the root SKILL.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_SKILL="$ROOT_DIR/SKILL.md"
PLUGIN_SKILL="$ROOT_DIR/plugins/thumble/skills/thumble-keypad-generator/SKILL.md"

if [[ ! -f "$PLUGIN_SKILL" ]]; then
  printf 'error: plugin skill copy missing: %s\n' "$PLUGIN_SKILL" >&2
  exit 1
fi

if ! cmp -s "$SOURCE_SKILL" "$PLUGIN_SKILL"; then
  printf 'error: plugins/thumble skill copy is out of sync with the root SKILL.md.\n' >&2
  printf 'Refresh it before shipping:\n\n  cp SKILL.md plugins/thumble/skills/thumble-keypad-generator/SKILL.md\n\n' >&2
  exit 1
fi

printf 'Plugin skill copy is in sync with the root SKILL.md.\n'
