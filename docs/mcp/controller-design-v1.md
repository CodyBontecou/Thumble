# Native controller design workspaces

The design service freezes an exact profile into an editable directory and renders unsaved
candidates with the app's native control faces. A captured artboard retains UUID identity and
only authored orientations. It never reconstructs a custom controller from an Xbox template.
CSS, SVG, JSON and raster assets remain editable; compiled packages contain no author scripts.

The shared implementation is `Sources/Shared/ControllerDesignSession.swift`. MCP delegates to
these same CLI commands using fixed argument vectors, bounded output and private temporary
inputs. `thumble design capabilities`, `controller_design_capabilities`, and the resource
`thumble://design/capabilities-v1` query the installed native CLI's actual capabilities.

| CLI | MCP | Result |
| --- | --- | --- |
| `design begin` | `begin_controller_design` | Frozen exact artboard/profile, separate bindings, target revisions and source hash |
| `design update` | `update_controller_design` | Atomic source and typed geometry revision; preserved prior contracts and stale evidence numbers |
| `design review` | `review_controller_design` | Compiled package, native contact sheet, individual frames and hashed manifest |
| `design inspect` | `inspect_controller_design` | Exact artboard, CSS aliases, semantic metadata and source synchronization status |
| `design critique` | `critique_controller_design` | Immutable structured issues bound to exact current review hashes |
| `design apply` | `apply_controller_design` | Authoritative profile transaction and replayable save receipt |

Capture requires the expected configuration revision, a target profile or private draft, and
explicit normalized viewport safe areas for each authored orientation. Draft capture also
requires its revision and a base matching the current configuration. CLI `--viewport-safe-area-zero` explicitly describes an offscreen
viewport. Device hardware insets are unavailable and are never inferred from orientation.
CLI `--private-draft` and MCP `privateDraft: true` create a durable private draft before capture,
under either Rust-host or native-editor authority. They cannot be combined with an existing draft
ID. The session returns the new draft ID/revision; resume it with the normal exact draft arguments.
Private capture never commits or selects a live profile. Native-editor resume/apply additionally
checks the entire base document, and successful native commit removes only the exact committed
draft revision. Replay receipts identify the retry and never commit a second time. Native authority
does not create Rust `state.json` or write directly to preferences from this design service.

```sh
thumble design begin --workspace ./lux-design --profile PROFILE_UUID \
  --identifier com.example.lumen --expected-configuration-revision 17 \
  --viewport-safe-area-zero
thumble design update --workspace ./lux-design --expected-revision 1
thumble design review --workspace ./lux-design --expected-revision 1
```

Each workspace contains `contract/artboard.json`, sanitized `contract/profile.json`,
`contract/bindings.json`, `skin-source.json`, `styles/`, `sources/`, and `reviews/`.
Source schema 3 embeds the captured artboard. The contract files cannot be edited as source files; only the typed layout service can
replace them. Updates stage and validate a private copy before atomic replacement.
An empty edits array synchronizes direct editor changes. Rejected edits leave sources intact.
CLI `--edits` accepts an array of `{ "path": "styles/controller.css", "data": "BASE64" }`;
`data: null` deletes a source file. Contract, evidence, executable, traversal and symlink paths
are rejected. Source budgets are 128 files, 8 MiB per file, and 16 MiB total.

Typed layout updates use CLI `--layout-edits JSON` or MCP `layoutEdits`. A patch names an
exact contract `controlID`, a stored `variant` (`primary`, `landscape`, `portrait`), and one
or more of `centerX`, `centerY` (normalized 0–1), `widthScale`, `heightScale` (0.1–8),
and `rotationDegrees` (−180–180). For example:

```json
[{"variant":"primary","controlID":"builtin.00000000-0000-0000-0000-000000000107","centerX":0.72}]
```

An absent orientation slot is rejected; edit `primary` when that is the authored fallback
canvas. Layout updates cannot change routing, labels, kind, native interaction settings, or
create controls. Unknown fields and IDs fail. The native resolver defines final visible and
hit frames, and the captured artboard validates its canvas bounds. Source appearance changes
and layout edits can share one atomic update. At most 256 patches and 64 KiB of cumulative
plan are accepted. Later patches merge into the same variant/control entry.

The service replaces the current artboard/profile contract, preserves its previous version
under `reviews/contracts/revision-N/`, invalidates prior evidence, and freezes the original
profile separately in `contract/base-profile.json`. `contract/layout-edits.json` and its hash
identify the cumulative plan. Review manifests bind both hashes. Apply checks the original
authoritative profile, reproduces the typed plan, verifies its exact reviewed candidate hash,
then attaches the skin in the same transaction. Rust independently constrains the response to
the planned geometry and appearance while preserving executable outputs and unrelated state.

Review compiles once and saves numbered immutable-by-convention evidence. Every authored
orientation receives light/dark × normal/pressed/active/disabled plus mixed-state panels.
CLI `--scale 1|2` and MCP `renderScale` select native raster scale; each frame records it.
CLI `--safe-area-overlay` / MCP `showsSafeAreaOverlay` shade the explicitly captured
unsafe margins orange. CLI `--touch-targets` / MCP `showsTouchTargets` draw magenta
rectangles around native hit frames for interactive controls. Both default to false,
apply to every panel, and are recorded in each frame's hashed manifest. These are review
annotations; they never enter the compiled package or modify geometry or hit testing.
Repeat reviews with explicit mixed states to inspect the reveal handle separately.
The CLI accepts `--mixed-states` JSON mapping exact control IDs to native state names.
The default mixed panel presses one button and activates one pointing surface when present.
A missing orientation is never silently synthesized or claimed as reviewed. Each manifest
records viewports, safe areas, source inventory, artboard/profile/binding/package/image hashes,
renderer executable hash, diagnostics and pending independent critique. Each frame also records
the canvas fill, artwork layers, control frames and hit frames, rotations, requested customization,
resolved native presentation, visual and accessibility legends, and baseline/label/font fallback use.
Each control's immutable `nativeContent` contains the same computed layout facts used by
the native face: legend visibility, typography mode and candidate font sizes, scale limits,
label/icon offsets, pointing chrome visibility and local surface bounds. Long native labels
retain their `ViewThatFits` candidates; the report does not invent a selected font size.
`localSurfaceFrames` are layout bounds in points before parent rotation/state scale, not
glyph ink bounds. `nativeFlowSurfaceIDs` identifies legends, symbols and cursors whose exact
flow bounds still require native measurement. `fixedProperties` exposes currently fixed
native pointing chrome values. These limitations remain distinct from authored style tokens.
Review rejects a rendered control inventory or frame geometry that differs from the frozen contract.
Material-only skin application preserves authored silhouettes and never inserts undeclared controls.
Transparent artwork reveals the native canvas; alpha checkerboards belong to editor previews. The returned
`evidenceSHA256` identifies the canonical complete manifest. MCP returns the exact sheet inline.
The iOS drawer uses the same authored reveal face as native review, with normal styling
when collapsed and active styling when open. Its native toggle, swipe, fade, pinning and
accessibility behavior remain owned by the drawer. The drawer positions the face as runtime
chrome; the canvas contract alone does not establish the drawer's placement or menu contents.
The displayed legend determines native label visibility and fallback size; the original
profile label remains the accessibility name. A short authored legend is therefore visible
with a centered icon even when the profile's original label is long.

Apply requires the exact session revision, review number, evidence hash, configuration revision
and invocation UUID. It rejects stale source, contract, renderer, package, pixels or manifest.
The authority also validates the frozen profile hash and package hash inside its transform.
Appearance changes preserve raw unrelated fields, element identity, output mappings, selection
and defaults. Existing installed package versions are never overwritten by this path.
A failed configuration CAS can leave an unused newly installed package; it cannot attach the
package to a changed profile. This is local application, separate from publication approval.
CLI `--skin-library DIRECTORY` and MCP `skinLibraryPath` optionally choose an explicit package
library (useful for isolated fixtures). Without it, the native app's Application Support library
is used. A custom library must remain available to consumers that load that package reference;
the native app's library UI does not automatically enumerate other directories. macOS Foundation
Application Support does not follow a test `HOME`, so fixtures must explicitly choose a library.

## Semantic appearance selection and critique

CSS source schema 3 accepts bounded `controlSemantics` records. Use the exact contract
control ID, not its CSS alias. For example:

```json
{
  "controlID": "builtin.00000000-0000-0000-0000-000000000107",
  "action": "lux.light-binding",
  "purpose": "ability.q",
  "groups": ["abilities", "primary-action"]
}
```

Selectors such as `control[action="lux.light-binding"]`, `[purpose="ability.q"]`, and
`[group~="abilities"]` resolve through these appearance tags and lower to exact native
control rules. Group membership matches complete whitespace-separated tokens, not substrings.
Tags contain 1–64 lowercase ASCII letters, digits, dots, underscores or hyphens; at most
16 distinct groups and 256 control records are accepted. Unknown or duplicate control IDs
are rejected. These source-only tags never rewrite executable mappings. Their changes alter
the source digest and invalidate prior evidence. `design inspect` returns aliases, metadata,
and whether direct source edits have been synchronized; it exposes no binding document.

`design critique --workspace DIR --expected-revision N --report FILE` and
`critique_controller_design` record reports with `id` (UUID), `review` (number),
`evidenceSHA256`, `reviewer`, `stage` (`criticOne`, `criticTwo`, `qa`), `verdict`
(`revise`, `pass`, `fail`), and `issues`. Each issue has a unique `id`, `severity`
(`blocker`, `major`, `minor`, `note`), optional exact `controlID`, `layerID` or
`action`, optional `surfaceID` (`CONTROL_ID/SURFACE_NAME`), `frameTitles`, `observation`, and `requestedCorrection`.
Native surface targets must be visible in every affected panel and match an accompanying
control target. Surface names are listed by capabilities and each control's `nativeContent`.
An empty frame list targets all panels. Reports are limited
to 128 KiB and 128 issues. The service verifies current source, manifest, package and
pixel hashes, rejects invented targets, and stores records without overwriting prior IDs.
Later stages require earlier records from different reviewers; earlier critique can refer
to an earlier revision so the designer can address it. The service records agent assertions;
it cannot establish independence or aesthetic quality by itself, and it never grants human approval.

Local stdio MCP keeps ordinary requests at 256 KiB and permits `update_controller_design`
requests up to 24 MiB, accommodating base64 for the 16 MiB decoded source budget and bounded
metadata. Per-file decoded bytes remain limited to 8 MiB. Strict duplicate-key validation occurs
before classifying the larger request; other tool calls keep their original bound. CLI `--edits`
accepts the same 24 MiB encoded budget through a bounded regular-file reader. Shared capabilities
advertise encoded, decoded, ordinary-request and local source-update limits.

Relay/tunnel requests retain their existing 256 KiB limit. Larger sources on that transport still
require trusted local-file editing followed by synchronization with an empty edits array. Native
JSON responses from native `design review` and `design inspect` are bounded at 12 MiB by
the MCP delegate to support both authored orientations. Other native responses retain the
2 MiB limit. A budget violation stops both pipe readers promptly even when the other stream
remains open. Workspace JSON files, including review manifests, must fit the 8 MiB file
budget before atomic publication; an oversized write preserves the previous file. Shared
capabilities advertise both reply limits.

## Native presentation additions

Pointing interiors support independent per-state paint through these CSS properties:

- `-thumble-trackpad-frame-color`, `-thumble-trackpad-cursor-color`,
  `-thumble-trackpad-indicator-color`, `-thumble-trackpad-secondary-indicator-color`.
- `-thumble-joystick-ring-color`, `-thumble-joystick-knob-fill`,
  `-thumble-joystick-knob-stroke`.
- `-thumble-trackpad-frame-stroke-width` and `-thumble-joystick-ring-stroke-width`
  accept 0–12px. Puck stroke width remains `-thumble-joystick-knob-stroke-width`.

Color properties accept the compiler's bounded color syntax, including `currentColor`.
Normal paint inherits into other states and individual state declarations override only
their property. Unspecified paint retains the native baseline. These properties change
native paint, never input behavior or hit testing. Packages store them in the immutable
`content.pointing` presentation object. Review records effective state paint under
`nativeContent.pointingPaint`, resolved stroke widths and explicit native fallback reasons.
`nativeContent.resolvedPointingPaint` also includes numeric RGBA defaults for the
joystick ring/puck and trackpad frame/cursor/indicators. Rendering consumes the same
resolved bundle. Trackpad tints preserve foreground alpha; the secondary indicator
reflects touch count (zero in review). Requested overrides remain distinct from defaults.

The CSS capability response lists exact syntax and limits for `font-size` (8–72px),
`font-weight`, `-thumble-font-design`, `letter-spacing` (−4–12px), `-thumble-line-limit`
(1–4), `text-align`, `-thumble-label-padding`, and `-thumble-label-placement`.
`-thumble-legend` accepts 1–64 quoted characters without control characters. It changes
the visible legend independently of routing; accessibility retains the profile label.
Typography remains native text with the control's original accessibility label.
Native icon source authoring accepts `-thumble-icon: url(#declared-asset)` (including editable
SVG compiled to package raster assets), or `-thumble-icon-symbol: "scope"`. Placement, scale,
tint, and template/multicolor/original rendering use the corresponding `-thumble-icon-*`
properties. Exact element rules include pointing controls. The reveal handle's exact CSS alias
is `system-top-bar-activation`; element aliases replace the identity dot with a hyphen and
normalize UUIDs to lowercase.
Trackpad frame, cursor and indicators can each be `visible` or `none`. Joystick ring,
knob ratio (0.2–0.9), knob stroke width and existing knob colors can be authored independently.
Raster contrast uses an opaque dominant-face estimate from the actual package image.
It cannot certify a legend over complex artwork; independent native pixel critique remains required.
These optional fields use immutable reference storage and preserve legacy defaults when absent.

## Remaining implementation work

The full proposal is still in progress: runtime chrome beyond the native preview canvas and
complete fallback reporting need completion. Original captured-draft
application passed an isolated host/MCP/native-bridge end-to-end check: stale-draft rejection,
original-draft reuse, one configuration commit, UUID-key binding/default preservation, unknown
field preservation, and idempotent replay. Rust attachment validation also rejects changes
to owned controls, geometry, outputs, selection, defaults and unrelated profile fields. Native-editor private drafts now use the canonical durable
store; a disposable native-editor protocol fixture with the real Swift transform verified durable
capture, full-base conflict rejection, typed layout apply, output/default/unknown-field preservation,
committed-draft cleanup, one-commit replay, and absence of Rust state creation. The fixture exercises
the native socket protocol, not a launched graphical editor.
The bounded Lux landscape proof completed two visual critique passes and independent proof QA.
Its editable source, 40 native frames, package and pending human approval record are preserved
in `build/LuxController/LumenInstrumentDesign`. Full-skin strict QA still fails on the intentional
missing-portrait warning; no application, installation, publication or human approval occurred. Icon placement/scale/tint/rendering already exist in the native model;
the design source interface exposes them through the shared CSS compiler. Icon fit/mask/padding, remote fonts, scripts and CSS hit testing
are explicitly unsupported. Diagnostics cannot grant aesthetic or human publication approval.

## Bounded composition anchors

`update_controller_design` accepts anchors through bounded `skin-source.json` source edits;
there is no separate routing or layout operation hidden in artwork. CSS schema 3 source
assets with purpose `canvas_artwork` can target one exact `controlID`, semantic `action`, or
`group`. The shared capabilities report `artworkAnchorTargets`, `artworkAnchorLimitations`,
`maximumAnchoredAssets` (8) and `maximumAnchorControls` (32). See
[CSS authoring](../skins/css-authoring.md#passive-artwork-anchored-to-captured-controls) for
units, bounds and an editable SVG example. Layout revisions re-resolve these frames and stale
older evidence. Captured packages check exact geometry instead of canonical-template ancestry;
rotation now enters new appearance contracts independently of the binding digest.

## Persistent native presentation

An element's optional `presentation` object persists in its native profile, independently of
its legacy editor `label`, `visualRole` and executable `output`/`partOutputs`. Edit it through
the existing CLI `element.set` operation or MCP `edit_configuration_draft` with an `element.set` operation, preferably
on a private draft before `begin`. `changes.presentation` replaces the complete object;
`changes.clearPresentation: true` removes it. Setting both fails. `element.add` also accepts
presentation. The authoritative bridge checks the exact requested metadata and rejects any
routing delta during a presentation-only edit. Such edits touch the requested authored orientation
and its existing primary/orientation mirrors, preserve unrelated raw fields and order, and never
materialize an unauthored orientation. Import/persistence validates the same bounds.

```json
{
  "presentation": {
    "schemaVersion": 1,
    "actionID": "lux.light-binding",
    "purposeID": "primary",
    "groupIDs": ["abilities"],
    "legend": "Q",
    "caption": "Light Binding",
    "accessibilityName": "Cast Light Binding"
  }
}
```

Action/purpose/group tags use 1–64 lowercase ASCII letters, digits, dots, underscores or
hyphens. Groups are unique and bounded to 16. Legends allow 64 Unicode scalars; captions and
accessibility names allow 128. Control characters and blank accessibility names fail. These
fields never become key codes or routing aliases. Duplication keeps descriptive intent while
assigning a fresh element UUID. Legacy profiles decode with absent presentation unchanged.

Capture freezes this metadata in each authored orientation. CSS action/purpose/group selectors
and SVG anchors use native intent when no explicit source `controlSemantics` record replaces
it. The renderer uses the native legend as its fallback and the native accessibility name for
VoiceOver. CSS can restyle or override the visual legend without changing accessibility or
routing. A nonempty caption uses native secondary text only where the integrated legend is
visible; its current fixed typography/opacity/width rules appear in review evidence. It does
not replace the optional executable-binding hint. Interactive iOS controls use the persisted
legend and accessibility name, with captions independent of the binding-glyph preference. Owned
interactive buttons, joysticks, trackpads and triggers draw through the same native face as review,
including per-state authored typography, icons and pointing paint. Touch capture, the press
animation and accessibility overlays remain
owned by the runtime. Increased contrast, reduced transparency and accessibility label scaling
are explicit runtime adaptations; the current review matrix uses their default values. Joystick
displacement and trackpad touch feedback are transient runtime inputs to the shared face; review currently renders centered pucks and zero-touch cursor/indicator feedback. The
former live-only direction glyphs and aiming outline are no longer layered over authored
pointing faces. Differentiation overlays remain explicit accessibility adaptations. Trigger review includes a
`trigger-fill` surface with its exact local frame, orientation, value and fixed foreground-tint
opacity. Normal/disabled panels use zero value, pressed/active panels use full value; the native
minimum fill dimension is four points, bounded by the face. The runtime supplies its actual
normalized value without altering routing. Trigger tint opacity is currently fixed at 0.18 in
light and 0.24 in dark; reduced transparency uses 0.62. Interaction animations and runtime chrome
still require full graphical flow review; runtime chrome also requires native review coverage.
Review and live faces share settled input feedback: pressed input buttons multiply authored scale
by 0.94 and active trackpads by 0.97. System chrome is excluded from the button rule. Native
content evidence exposes `fixedProperties.nativeStateScaleMultiplier` and the composed
`effectiveFaceScale`; geometry/hit frames stay in their authored coordinate system. Local surface
frames precede parent scale/rotation. CLI/MCP capabilities expose these rules and the sampling
limits in `nativeRuntimeRules`. Intermediate spring-animation frames and accessibility adaptations
remain outside the current matrix.

Each control's optional `nativeInk` records native paint bounds for visible legend, caption, icon
and trackpad-cursor surfaces. The renderer makes transparent surface masks while retaining native
layout/fitting, then measures RGBA8 premultiplied sRGB pixels with alpha greater than 1/255.
Samples include backing-scale pixel bounds, canvas-point bounds and the canonical raw RGBA hash.
They include state scale, rotation and viewport clipping, before occlusion by sibling surfaces or
artwork. A null bound means the mask painted no pixels above that threshold. These are ink bounds;
layout containers and the selected font remain unmeasured. Masks are bounded to five flow surfaces
per control and 16 megapixels/8192 pixels per raster axis. No mask is installed or sent to the live
host. The optional boxed evidence keeps older reviews readable and shared model footprints small.

`review_controller_design` accepts `showsBindingHints: true` (CLI `--binding-hints`) to
render compact native hints derived from the frozen profile's executable outputs and output
mode, using the runtime formatter. Hints are disabled by default; review does not read the
device preference or live binding cache. Each frame records this input. The native content
reports the visible `bindingHint`, fixed typography and a separate `binding-hint` surface
with native ink bounds/hash. Captions retain their own surface. Native duplicate suppression
omits a hint matching the control label or a text icon; hidden integrated legends also hide
hints. The separate frozen bindings digest remains unchanged by this review choice.
System controls without an owned element
have fixed descriptive metadata; attempting this element edit on them fails explicitly.

The expanded control bar now has a shared native label implementation for profile,
launch target, Edit/Done and connection actions. Both live iOS and the editor preview
consume it, along with their existing shared item surface styles and layout. The native
renderer has a bar-rendering entry point with explicit orientation, connection/default
status and editing state; its width comes from the selected authored profile canvas.
Design review includes expanded bar evidence by default (`includesControlBar: false` / CLI
`--no-control-bar` explicitly omits it). `controlBar.frames` records eight panels per authored
orientation: light/dark × connected/offline × editing on/off. The frozen profile name, visible
item inventory, explicit context and native raster dimensions accompany each PNG hash.
The bar uses the same skin-applied customization as that orientation's controller review.
A separate `controlBar.contactSheet` is hashed, returned inline by MCP alongside the controller
sheet, and checked with every bar image before apply. Older manifests may omit this boxed field.

Bar surfaces have exact descriptive IDs: `native-control-bar` and
`native-control-bar/<item raw value>` (spacing-only items are excluded). Structured critique may
target layer `native-control-bar` and these surface IDs using explicit bar frame titles. A surface
must be visible in every affected frame. These IDs do not create control UUIDs or output aliases.

The scope remains bounded: the default-profile flag is explicitly false, connection state is
connected/offline, and device practice/builder/accessibility policies are unsampled. Drawer
position, menus, bar glyph ink/paint extents, hit frames and live device context capture remain open. The
bar does not contribute guessed geometry to the appearance artboard.

Each bar frame now includes optional boxed `nativeLayout` evidence captured by native SwiftUI
geometry probes during the same raster render. It contains the bar and visible-item layout
bounds in bar-image point coordinates, including spacers as layout-only entries. The named
coordinate space is local to the standalone bar image. `viewport`, `clippedFrames` and
`outOfViewportIDs` describe raster clipping explicitly. Missing inventory or nonfinite frames
fail review. These are item container bounds; internal paint transforms, glyph ink, shadows and
hit geometry are separate. Runtime drawing installs no probes. Older bar frames may omit this
field. The optional immutable storage preserves the shared inline-size budgets.

Newly captured variant `nativeChrome.containerPresentation` and each bar frame's optional
boxed `containerPresentation` expose version-1 fixed native paint: numeric sRGB fill/stroke,
shape and portrait corner radius, border width, item spacing, padding, and shadow color/radius/y.
The bar layout and shared drawer shadow use the same presentation model as these facts.
These values describe native container styling; they are not editable CSS properties or measured
shadow/glyph extents. Older captured variants and review frames may omit the optional field.

Bar frames also expose boxed `drawerLayoutInputs`, using the same padding resolver as the live
iOS drawer. The captured normalized safe areas become canvas-point insets; review does not
query a live window. `minimumPortraitTopInset` (CLI `--portrait-top-inset`) accepts 0–128 points,
defaulting to zero, and is ignored in landscape. Live iPhone portrait retains its 54-point
minimum and merged window safe areas. These are explicit placement inputs and resolved padding,
not measured drawer frames. The shared native drawer composition renderer samples expanded,
collapsed and faded surfaces with real pin policy; its pixels are not yet included in the
CLI/MCP review manifest. Drawer geometry, composition sheets and menus remain open.

Typed `layoutEdits` also accept native semantic changes for exact owned element IDs:
`presentation` replaces bounded version-1 action/purpose/groups/legend/caption/accessibility
metadata, while `clearPresentation: true` removes it. Replacement and clear are mutually
exclusive. Geometry and presentation can share a patch; subsequent geometry-only edits
retain the prior semantic patch. System chrome has no owned metadata slot and rejects
semantic edits. CLI uses the same `--layout-edits` JSON as MCP. Updates recapture the exact
appearance contract, preserve the separate binding digest, retain prior contracts and sheets,
and invalidate earlier review evidence. Apply replays the cumulative plan from the frozen
base profile and verifies the exact reviewed profile hash; authority accepts only those
explicit semantic changes while preserving outputs, defaults and unknown fields.

Typed design plans also support `visualRole` and `clearVisualRole` on owned native
elements, separately from presentation text/tags and executable bindings. The existing
bounded role enum is shared with element authoring. Replacement and clear reject together;
geometry-only changes retain the declared role. Clearing a button role resolves to `custom`.
Undeclared roles now depend only on control kind (joystick/trigger/trackpad/decoration/custom),
never historical preset positions. Existing explicit profile roles remain authoritative.
System chrome rejects role edits. Native review/capture and transactional apply carry and
verify the declaration alongside the exact semantic/geometry plan.

Control review evidence exposes optional `visualRole` for each resolved native control.
Ergonomic primary-action checks require a declared movement/action role; neutral `custom`
controls still receive geometry/hit/overlap diagnostics without label-based importance.
The two fixed published skin catalog artboards retain explicit authored role declarations
and their committed contracts; these declarations are not generic profile fallbacks.

New review manifests include optional boxed version-1 `diagnostics` with one normalized
stream from source validation, package/style quality and native layout diagnostics. Each
issue has a deterministic 64-character ID, origin/severity/code/message/source path, exact
control/action/layer/surface targets, affected frame titles, repair suggestions and optional
metric. Source warnings repeated by the quality evaluator appear once in this stream.
Native layout reports use the exact authored canvas once per orientation; caller-safe-area
quality issues retain exact control IDs. Style issues link reviewed native control and bar
item bindings. Layer safety issues carry exact layer IDs. Component alignment issues link
their declared role/button selectors. Labels never identify a target. Global resource issues
have `targetResolution: global`; paths with no reviewed binding remain explicitly
`unresolved`, without guessed identities. Frame titles describe affected binding contexts;
diagnostics do not certify pixel quality or aesthetic approval. The combined budget is 4096
issues. Older reviews and raw quality issues may omit their additive diagnostic/target fields.

Style/contrast quality targets include the local style ID and its defining appearance ID.
`ThumbleSkin.styleSources` uses the same matching-variant order as native appearance
resolution; diagnostic links follow the winning definition in each orientation/scheme.
A shadowed base definition remains unresolved for frames that use a variant override.
Namespaced quality paths are never guessed by splitting IDs or matching label text.

A quality style target's absent `appearanceID` identifies the base definition; a present
value is the exact variant ID, including a variant literally named `base`. The cascade's
style-source map namespaces variant origins to distinguish that legal name from the base.


Native bar item icons now use the shared local asset image renderer, matching controller-face
asset handling: original/multicolor preserve payload colors, template uses authored tint or
inherited foreground, and scale changes the bounded image frame. Missing asset payloads use
`photo.badge.exclamationmark`. SF symbols and text keep their existing native path. Bar label
trees own icon placement; placement, fit, mask and padding remain unauthored for these labels.
Captured chrome lists source/value/scale/tint/rendering as supported item properties, while
bar typography and content tokens remain unsupported. No interaction or output mapping changes.

Bar snapshots use the owned cleared RGBA raster path shared with drawer and ink capture.
This prevents prior transparent-buffer paint from leaking between differently tinted captures;
native layout collection and drawing still use the same view tree.


CLI/MCP `begin` now performs native baseline layout capture before publishing the workspace.
Each authored variant's optional immutable `nativeLayout` contains eight control samples
(light/dark × four settled states), including measured native flow leaf frames, and 24 chrome
samples (8 standalone bar + 16 drawer requested-open/closed contexts). Bar frames use bar-image
point coordinates; drawer and flow frames use canvas points. The matrix binds the renderer
SHA-256 and 1x scale. Frozen safe areas, default-profile false, collapsed opacity 1 and portrait
minimum zero are explicit baseline inputs. Primitive frames and inventory remain in
`nativeSurfaces`/`nativeChrome`; source-edited native results are measured separately in review.

Typed geometry or semantic/role updates recapture the native baseline within the same staged
contract transaction and archive the previous measured contract. Source-only updates retain it.
The low-level geometry-only Swift snapshot path remains usable on constrained threads; it
rejects typed edits to a measured contract instead of dropping its measurements. CLI and MCP
use the native path. Legacy contracts decode without `nativeLayout`. Capture bounds are two
authored orientations, 128 controls per orientation and the existing 8 MiB per JSON file limit.
Binding hints depend on separate frozen outputs and are excluded from baseline flow frames.
Internal bar glyph layout, selected fonts, ink, exact hit shapes, live device adaptations,
menus and animated transitions retain their separately declared measurement limits.


Native bar capture now includes named `native-control-bar/ITEM/legend` and `/icon` leaf
frames as well as item containers. The probes are enabled only by offscreen native capture;
runtime/editor labels use the identical view tree with no collector. Compact portrait bars
omit profile/edit legends and use a connection icon; landscape connections show a legend and
an icon only when authored. Status keeps both leaves. Launch payload/fallback icons use the
same icon surface ID. Hidden items and spacers emit no paint leaves.

Frozen chrome inventories these eligible leaves and their supported icon properties. Native
baseline and source-edited review retain actual frames, including ancestor transforms, in
the existing coordinate spaces. These are layout frames, not glyph ink or selected fonts;
text-sized frames may align differently at 1x and 2x. Every rendered bar/drawer sample must
contain exactly its native item and leaf inventory. Capture permits at most 32 layout frames
per sample and rejects incomplete measurement. Frame IDs enter the hashed review manifest;
spacers remain layout-only and are excluded from paint surface IDs.


New `begin` captures derive the artboard ID from the exact profile UUID, independently of the
random session UUID and target revision. Re-capturing that profile with changed outputs and
unchanged appearance retains the same artboard/source hashes when renderer, name, package
identifier and safe areas are unchanged; profile/binding hashes change separately. Each
workspace still has its own session ID and transaction/review history. Existing workspaces
retain their stored artboard IDs during typed recapture; no old contract is rewritten merely
to migrate its ID. Geometry, semantics, native baseline measurements or renderer changes can
still change the appearance hash as intended.

Binding operations remain separate from design edits. Their native bridge synchronizes
only output fields and the profile mode/timestamp, retaining raw control order, layout,
defaults and extension fields across authored variants. Missing configured outputs stay
absent unless the requested operation explicitly assigns one; typed normalization does not
invent an empty output for an unbound trigger. Host delta checks accept equivalent JSON
number spellings (`1` and `1.0`) within the exact integer range, while still rejecting
layout/default changes and rounded equality of distinct large integers.

Output-only `element.set` patches use the same raw-field preservation rule for the exact
selected element. They update only `output` or the requested `partOutputs` entry on the
existing primary/orientation mirrors, preserve independent orientations and sidecar maps,
and do not create missing orientation layouts. Native semantic key resolution and part/kind
validation still apply. The host reconstructs the exact allowed output change and rejects
sibling/order/layout/default mutations or a primary output change during a part edit.
Explicit `false` values for appearance fields remain meaningful combined patches; they are
not classified as metadata-only or output-only requests.

Native bar item paint is now captured from the actual SwiftUI surface/icon paths. Each
measured layout contains optional immutable `paint` evidence with exact requested appearance,
resolved override paint or native fallback RGBA, native enabled state, height/padding, renderer
shape/corner inputs and explicit missing/incompatible style reasons. Icon records retain
requested properties, effective size/frame, resolved source/rendering mode, explicit tint,
payload SHA-256 and missing/undecodable-image fallbacks. `foregroundBySurfaceID` records
inherited item/legend/icon foregrounds; original raster icons omit a foreground and report
ignored tint. Multicolor symbol palettes remain native intrinsic paint. Glyph ink, selected
fonts, paint-effect extents and hit geometry remain separate measurements.

Frozen baseline chrome samples carry this paint before authoring. Reviewed bar and drawer
layouts capture the source-edited result at the same seams; collapsed drawers contain no bar
paint records. Capture requires the exact visible non-spacer item/icon inventory and bounds
records to ten items and ten icons. Old layouts without `paint` remain decodable. Native
runtime/editor and CLI/MCP use the same view paths; the collector is absent in runtime/editor.

The complete native baseline matrix remains in the immutable workspace contract and hashed
review evidence. Runtime package compatibility retains exact captured geometry and semantic
metadata but omits `nativeLayout`: runtime matching does not consume that review matrix, and
repeating it in the pretty-printed manifest can exceed the package entry budget. The original
contract/hash and review evidence remain intact; package size limits are unchanged.

### Native joystick legend contrast estimates

CSS quality checks normal, pressed, active and disabled resolved style paint. For tokens
selected by joystick role or an exact captured joystick input, an authored puck fill is
the representative legend background. A token also used by buttons retains its face
contrast check. Native pressed adjustment applies to legacy authored puck colors.
The original contrast thresholds remain unchanged. Unconfigured native puck defaults,
alpha, gradients and composited artwork still require independent native pixel review;
these estimates do not certify the rendered legend or grant visual approval.

### Full controller proof and authority parity

The full Lumen Instrument candidate exercises the captured 16-control profile plus
standalone reveal in both authored orientations, with 20 controller, 16 bar and 24
settled-drawer panels per review. Revision 6 retains complete native 1× and 2× matrices
and editable optical SVG sources. The exact native system reveal identity is
`system.top_bar_activation` throughout capture, layout decoding and attachment guards;
other system spellings and semantic edits to that surface are rejected.

Native skin attachment can add passive `artworkLayers` alongside its asset/style libraries.
The authority accepts those appearance fields while continuing to reject unplanned owned
geometry, hit-inset changes, output changes and unrelated customization extensions.
The host regression suite passes all 182 tests. A credential-free temporary local MCP
host applies the complete reviewed artifact and replays the same invocation with one
configuration commit; semantic UUID/default identity, outputs and pointing settings are
preserved. Native UUID serialization may change letter case without changing identity.
The live host and skin library are untouched by this verification.

Evidence is under `build/LuxController/LumenInstrumentFullDesign/`, including
`parent-final-native-evidence-check.json` and `full-private-apply-verification.json`.
Configuration attachment/save is atomic; the previously documented possibility of an
unused newly installed package after a failed CAS remains. Visual review and human
publication approval remain separate from successful application.

The exact revision-6 full candidate now has two independent final visual passes and a
strict QA pass. QA proves two independent compilations and unpack/repack are byte-identical
to the reviewed package; all 60 native rerendered frames match review 6. The three pass
records target the same exact evidence hash and are immutable. Final coverage/evidence
is in `build/LuxController/LumenInstrumentFullDesign/completion-audit.json`; pending
approval names all three sheets and the package hash. Four native thumb-reach heuristic
warnings remain explicit notes (D in landscape; D, F and R in portrait). These do not
become ergonomic certification because visual review or strict package QA passes.
