#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

binary="${1:-}"
if [[ -z "$binary" ]]; then
  binary="$(find "${HOME}/Library/Developer/Xcode/DerivedData" -path '*/Build/Products/Debug/thumble' -type f -perm -111 2>/dev/null | head -1 || true)"
fi
if [[ -z "$binary" || ! -x "$binary" ]]; then
  echo "usage: $0 /path/to/thumble" >&2
  exit 2
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/thumble-skin-verify.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

package="$temporary/Aurora.pocketpad"
unpacked="$temporary/unpacked"
preview="$temporary/Aurora.png"
reference="docs/skins/examples/indigo-pocket"
reference_a="$temporary/indigo-a.pocketpad"
reference_b="$temporary/indigo-b.pocketpad"
contact_sheet="$temporary/indigo-contact-sheet.png"

# Low-level package workflows remain supported for manually authored package sources.
"$binary" skin pack docs/skins/starter -o "$package"
"$binary" skin validate "$package"
"$binary" skin inspect "$package" --json > "$temporary/inspection.json"
"$binary" skin unpack "$package" -o "$unpacked"
"$binary" skin preview "$package" --artboard showcase-controller-v1 -o "$preview"

# Agent-ready authoring workflows use canonical artboards, editable SVG source,
# deterministic compilation, strict QA, and the native renderer.
"$binary" skin artboard list > "$temporary/artboards.txt"
"$binary" skin artboard show showcase-controller-v1 --json > "$temporary/artboard.json"
"$binary" skin artboard export showcase-controller-v1 -o "$temporary/showcase-profile.json"
"$binary" skin compile "$reference" \
  --build-directory "$temporary/build-a" -o "$reference_a" --clean --strict
"$binary" skin compile "$reference" \
  --build-directory "$temporary/build-b" -o "$reference_b" --clean --strict
"$binary" skin validate "$reference_a" --strict
"$binary" skin quality "$reference" --artboard showcase-controller-v1 --strict
"$binary" skin preview "$reference_a" --artboard showcase-controller-v1 \
  -o "$contact_sheet" --all-variants --all-states --native-renderer --contact-sheet

python3 -m json.tool "$temporary/inspection.json" >/dev/null
python3 -m json.tool "$temporary/artboard.json" >/dev/null
python3 -m json.tool "$temporary/showcase-profile.json" >/dev/null
test -s "$temporary/artboards.txt"
test -s "$unpacked/manifest.json"
test -s "$unpacked/skin.json"
test -s "$preview"
test -s "$contact_sheet"
cmp "$reference_a" "$reference_b"
cmp "$reference_a" "$reference/dist/indigo-pocket-1.0.0.pocketpad"

# CSS authoring (thumble-css-core-1) compiles deterministically into the same package model.
css_reference="docs/skins/examples/css-first-light"
css_a="$temporary/css-a.pocketpad"
css_b="$temporary/css-b.pocketpad"
css_sheet="$temporary/css-contact-sheet.png"
"$binary" skin css capabilities --json > "$temporary/css-capabilities.json"
"$binary" skin css lint "$css_reference" --json > "$temporary/css-lint.json"
python3 -m json.tool "$temporary/css-capabilities.json" >/dev/null
python3 -m json.tool "$temporary/css-lint.json" >/dev/null
"$binary" skin compile "$css_reference" \
  --build-directory "$temporary/css-build-a" -o "$css_a" --clean --strict
"$binary" skin compile "$css_reference" \
  --build-directory "$temporary/css-build-b" -o "$css_b" --clean --strict
"$binary" skin validate "$css_a" --strict
"$binary" skin quality "$css_reference" --artboard showcase-controller-v1 --strict
"$binary" skin preview "$css_a" --artboard showcase-controller-v1 \
  -o "$css_sheet" --all-variants --all-states --native-renderer --contact-sheet
test -s "$css_sheet"
cmp "$css_a" "$css_b"
cmp "$css_a" "$css_reference/dist/css-first-light-1.0.0.pocketpad"

echo "Thumble package, authoring, CSS, quality, and native-preview verification passed: $temporary"
