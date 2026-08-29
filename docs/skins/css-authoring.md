# Authoring Thumble skins with CSS

Thumble skins can be authored with real CSS instead of the material JSON model. The CSS is a **compile-time authoring format**: `thumble skin compile` parses it, runs a standard cascade over a virtual controller document, and lowers the result into the same deterministic native style model the material path produces. No CSS, stylesheet, or browser engine ever ships inside a `.pocketpad` package or runs on the phone.

The supported language is versioned as profile **`thumble-css-core-1`**. Anything the profile does not support is a **strict compile error** — unsupported CSS is never silently ignored.

```bash
thumble skin scaffold "My Skin" --identifier com.me.my-skin --css
thumble skin css capabilities
thumble skin css lint .
thumble skin css computed . --control builtin-jump --scheme dark --state pressed
thumble skin compile . --strict
thumble skin preview . -o reviews/contact-sheet-1.png \
  --all-variants --all-states --native-renderer --contact-sheet --columns 4
```

## The virtual controller document

Selectors match a semantic document generated from the workspace's canonical artboard:

```text
controller            (the root; also matches :root)
└── control elements (one per artboard control)
```

Every control exposes these attributes:

| Attribute | Values |
|---|---|
| `id` | Stable kebab-case ID, e.g. `builtin-jump`, `builtin-left-shoulder`, `custom-button-3` |
| `kind` | `button`, `joystick`, `trigger`, `trackpad`, `text`, `decoration` |
| `role` | `movement`, `primary_action`, `secondary_action`, `utility`, `menu`, `custom`, `joystick`, `trigger`, `trackpad`, `decoration`, `system` |
| `button` | Built-in button ID for face buttons, e.g. `jump`, `attack`, `leftShoulder` |

Run `thumble skin css computed .` (without `--control`) to list every element ID on your artboard.

```css
:root {
  --surface: #F2EEF5;
  --ink: #7C61A8;
}

controller {
  background: linear-gradient(160deg, #E9E4F2, #C9C2D2);
}

control {
  color: var(--ink);
  background: var(--surface);
  border: 1px solid rgba(255, 255, 255, 0.6);
  border-radius: 14px;
  box-shadow: 0 2px 4px #101027;
}

control[role="primary_action"] {
  background: linear-gradient(135deg, #8A6FD0, #5B4497);
  color: #FFFFFF;
}

#builtin-jump { border-radius: 50%; }

@media (prefers-color-scheme: dark) {
  :root { --surface: #211A46; --ink: #B8A0E8; }
  controller { background: #17143B; }
}
```

## Selectors

| Selector | Meaning |
|---|---|
| `controller` / `:root` | The controller root (background canvas) |
| `control` | Every control |
| `button`, `joystick`, `trigger`, `trackpad`, `text`, `decoration` | Controls of one kind |
| `#builtin-jump` | One control by stable ID |
| `[kind="button"]`, `[role~="primary_action"]`, `[button="jump"]` | Attribute selectors (`=` and `~=`) |
| `controller control` | Descendant selector |
| `:normal`, `:pressed`, `:active`, `:disabled` | Interaction state |

Specificity, source order, and `var()` fallbacks follow CSS semantics. Custom properties declared on `:root` inherit to every control; `color` inherits like CSS. Classes, pseudo-elements, combinators other than descendant, and functional pseudo-classes are not supported and produce explicit errors.

`:active` maps to Thumble's engaged/active presentation state (a held or latched control), and `:pressed` to the momentary press state.

## Properties

`thumble skin css capabilities` prints the live list. Summary:

| Property | Syntax |
|---|---|
| `background`, `background-color` | `<color>`, gradient, or `url(#asset)` |
| `background-image` | `linear-gradient(…)` / `radial-gradient(…)` / `url(#asset)` |
| `color` | `<color>` |
| `border` | `<length> solid? <color>?` |
| `border-width`, `border-color` | length / color |
| `border-radius` | one to four lengths |
| `box-shadow` | `none` or `[inset? <length>{2,3} <color>?]#` |
| `opacity` | number 0–1 or percentage (e.g. `50%`) |
| `transform` | `scale(<number>)` |
| `filter` | `blur(<length>)` |
| `-thumble-glow-color`, `-thumble-glow-radius` | native glow effect |
| `-thumble-knob-color` | joystick knob color (joystick role) |
| `-thumble-haptic-style` | `none` `light` `medium` `heavy` `soft` `rigid` |

Image fills reference SVG source assets declared in `skin-source.json` (`sourceAssets`). The compiler rasterizes each declared asset at its declared output size, embeds the PNG in the package, and resolves `url(#asset-id)` to a native image fill. Unknown IDs are strict compile errors.

Lengths use `px` (compiled 1:1 to points). Gradients support `deg` angles, `to top|right|bottom|left` directions (including diagonals like `to top left`), and evenly-distributed or explicit percentage stops. Colors accept hex (`#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`), `rgb()`/`rgba()`, `transparent`, `currentColor`, and common keyword colors.

## Media queries

`@media` adapts styling per declared variant. Two features are supported:

| Feature | Values |
|---|---|
| `prefers-color-scheme` | `light`, `dark` |
| `orientation` | `portrait`, `landscape` |

```css
@media (prefers-color-scheme: dark) {
  control { background: #211A46; }
}

@media (orientation: portrait) and (prefers-color-scheme: dark) {
  #builtin-jump { box-shadow: none; }
}
```

Conditions combine with `and`. Each `@media` block takes a **single** query: comma-separated query lists and `not` are strict compile errors. Blocks may nest up to two levels. The compiler resolves the cascade for every orientation/scheme combination declared in `skin-source.json`, so `orientation` rules apply only to the matching variant.

## How CSS lowers into packages

Compilation resolves the cascade for every artboard control, state (`normal`, `pressed`, `active`, `disabled`), orientation, and color scheme, then emits:

- role rules and built-in button rules referencing generated style tokens (`css-role-*`, `css-button-*`),
- a default-control rule from bare `control` styling,
- `controller { background }` as the keypad background,
- one skin variant per declared orientation/scheme combination.

Because lowering flows through roles and built-in buttons, a CSS skin styles **any** profile whose controls use the same semantic roles and built-in buttons — not just the authoring artboard. Package bytes are deterministic: identical CSS and artboard always produce identical `.pocketpad` output.

## Quality gate

`thumble skin quality --strict` understands CSS workspaces:

- Material-system, shell-component, and editable-SVG checks are replaced by stylesheet presence and compiled role-rule coverage.
- Legend contrast is evaluated on the compiled style tokens (light and dark variants), with the same 3:1 error and 4.5:1 warning thresholds as materials.
- Because CSS packages embed no raster previews, the preview matrix is checked against the workspace's `previews` requests instead of `manifest.previews`.
- State completeness applies to the compiled tokens: base declarations fill every state, so `:pressed`/`:disabled` overrides that actually differ from normal are what the indistinguishable-state checks look for.

## Safety boundaries

CSS in Thumble is appearance-only, exactly like material workspaces:

- No `@import`, external `url()`, fonts, scripts, or network access.
- Stylesheets live under `styles/` in the workspace and are referenced by `skin-source.json` (`schemaVersion: 2`, `stylesheets: ["styles/controller.css"]`).
- CSS never controls bindings, labels, hit testing, geometry, or accessibility.
- Resource limits cap stylesheet size, rule, declaration, selector, gradient, shadow, and `var()` expansion counts.

## Workspace example

See [`examples/css-first-light/`](examples/css-first-light/) for a complete CSS-authored workspace, and `docs/skins/README.md` for the material JSON path. Both authoring models compile to the same validated package format.
