# Shared desktop workspace

The desktop application owns precise layout design, controller profiles and connection management. The phone keeps its controller, practice mode and quick layout editor. The same desktop HTML/CSS/JavaScript runs in macOS WebKit and Windows/Linux Qt WebEngine; native input remains in the existing receivers. No Node runtime or remote website is required by the installed application.

## Acceptance requirements

- One shared interface with Design, Controllers and Connections views on all three platforms.
- Actual controller canvas with selection, dragging, independent resizing, keyboard nudging, add/remove, labels, colors, gamepad outputs and stick settings; undo/redo, validation and explicit save/send actions.
- Profile creation, duplication, rename, import/export, switching and removal, preserving built-in/cloud originals and unrelated profiles.
- Native revision-checked transactions. Saving a draft does not activate it. Sending pauses/releases input and uses the existing rendered-layout acknowledgement; stale edits must not overwrite phone/agent changes.
- Real receiver state: pairing QR, connected/disconnected, output readiness, pending/acknowledged activation, WoW sync, disconnect/forget, receiver retry, and existing settings/permissions entry points. Errors and missing drivers must be actionable.
- Bundled local assets and a bounded, allowlisted native bridge. No web origin receives receiver authority. Imported profiles are declarative and validated in native code.
- Browser preview with an explicit simulated receiver for deterministic UI QA, including offline, missing driver, stale revisions and reconnect states. Simulation must never be enabled silently in production.
- Shared model/contract fixtures exercised by both receiver adapters. Package and UI tests on macOS, Windows and Linux; preserve native input checks and expose platform acceptance gaps honestly.

## Implementation location

Worktree: `/private/tmp/thumble-desktop-workspace-20261111`, branch `codex/shared-desktop-workspace`, based on submitted build 10 (`83f810e`). The original development worktree has unrelated pending changes and is preserved.

Shared source lives in `packages/desktop-workspace`. Assets are built into receiver resources during native packaging. Requests and responses use structured JSON with request IDs; only native code accesses profile files or receiver lifecycle. Each adapter exposes the same operations and response shapes. The existing phone/profile wire protocol remains authoritative for delivery and acknowledgement.

## Verification boundary

Automated UI and native input tests establish their specific contracts. They do not establish real-game latency, home-network pairing, firewall prompts, suspend/resume, or physical-phone behavior on Windows/Linux. Those remain explicit external beta acceptance checks rather than claims inferred from green CI.

## Development and packaging

Run `npm ci`, then `npm run desktop:build`. The build bundles the shared assets and stages the exact same files into the Python receiver package. Run `npm run desktop:preview` for the explicitly simulated receiver at `http://127.0.0.1:4179`. Preview code is built separately and is excluded from native packages. Run `npm run desktop:test` for editing and acknowledgement tests.

The existing macOS signing/package script includes the workspace under `Contents/Resources/Workspace`. The existing Windows/Linux packaging command builds and bundles it into Qt WebEngine. Installed applications load only local assets and use their native bridge, with remote navigation and pop-up creation blocked.

`--gui-smoke PATH` now runs the real bundled Qt workspace, creates and saves a draft through the bridge, proves that Save did not activate it, selects the exact saved revision, and captures its native window. All data and pairing credentials are synthetic and temporary; no input driver, network receiver or production profile store is used by this test. Linux package verification runs under Xvfb with the native X11 Qt platform.

For isolated macOS WebKit QA, run `bash tools/workspace-ui-tests/build-macos.sh`, then launch the generated app with `THUMBLE_WORKSPACE_QA_DIR` pointing to a disposable directory. This uses the production bridge and real store with no input device. The shipping receiver continues using its actual native input loop.

## Verification recorded during implementation

- All 10 shared editing tests pass; the existing 299 source tests pass. The Python receiver suite passes 86 tests (two platform-specific skips on macOS).
- One transaction fixture runs against Swift and Python. It covers draft persistence, optimistic revision checks, unchanged active content after draft saves, stale selection refusal and active-profile deletion protection.
- Native macOS WebKit window: create, save and exact-revision selection verified through the UI against an isolated real store.
- Native Qt WebEngine window on macOS: automated create/save/select flow and screenshot pass, including clean process exit. This verifies the Qt bridge but does not substitute for Windows/Linux packaging execution.
- Chromium/Argent: actual pointer dragging, saving, profile selection and connection page inspected using the simulated receiver.
- Windows and Linux packaged-application checks passed on the initial implementation, including native gamepad output and installed workspace save/send. The final recovery changes require another package pass and visual inspection of its stable-canvas captures.
- WoW label sync preserves desktop identity and unsent drafts in both Swift and Python. The real phone Connection class negotiates and saves profiles against the Python receiver in transport integration tests.

## Scope

This workspace edits the current gamepad/WoW profile format. Arbitrary keyboard shortcuts and trackpad controls from the older ThumbConsole are not yet implemented. The preview canvas uses a chosen logical viewport; it does not automatically discover the connected phone's screen dimensions. Physical-phone and real-game acceptance on Windows/Linux remains outstanding.
