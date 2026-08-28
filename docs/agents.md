# Use Thumble with an AI agent

Thumble's macOS editor has a command-line counterpart designed for coding agents and automation. An agent can create and revise keypad profiles, bind shortcuts, validate layouts, install skins, inspect the running Mac helper, and sync changes to a paired iPhone without driving the UI.

This guide is for users who want to tell an agent such as Pi, Claude Code, Codex, or another terminal-capable assistant to configure Thumble on their behalf.

## What to give your agent

Give the agent these inputs:

1. The `thumble` executable, either on `PATH` or at a known absolute path.
2. This repository's [`SKILL.md`](../SKILL.md), which documents the full agent workflow and command surface.
3. A concrete outcome, including the target app or game, important controls, and whether the agent may install/select the result.

A good request is outcome-focused:

> Use Thumble to create a landscape keypad for Celeste. Research the default Mac keyboard controls, keep movement on the left and actions on the right, dry-run the profile first, install and select it, validate both orientations, and report the final bindings. Read `/path/to/Thumble/SKILL.md` before using the CLI.

You do not need to translate the request into CLI commands. The skill teaches the agent how to inspect the current setup, choose the right workflow, and verify its work.

## Make the skill available

### One task

Include the absolute path to `SKILL.md` in your prompt:

```text
Before working on Thumble, read /absolute/path/to/Thumble/SKILL.md
and follow its inspection, dry-run, safety, and verification guidance.
```

This is the simplest option when the agent can read local files.

### Reusable project instruction

Add this to the instruction file your agent already reads, such as `AGENTS.md` or `CLAUDE.md`:

```md
## Thumble

When a task involves an iPhone keypad, Mac shortcuts, game controls, or
Thumble runtime diagnostics, read `/absolute/path/to/Thumble/SKILL.md`
and use the `thumble` CLI. Inspect before editing, preview or dry-run when
available, avoid UI automation, and verify the saved profile after changes.
```

### Agent Skills-compatible tools

Tools that discover `SKILL.md` directories can use the repository skill directly or copy it into their documented project/user skill directory. For example, if your tool follows the `.agents/skills` convention:

```bash
mkdir -p .agents/skills/thumble
cp /absolute/path/to/Thumble/SKILL.md \
  .agents/skills/thumble/SKILL.md
```

Use the skill directory documented by your agent host if it expects a different location. Keep the copied skill updated when Thumble adds commands.

### ChatGPT and Codex plugin

The repository also ships an installable ChatGPT/Codex plugin at `plugins/thumble` that bundles the keypad-generator skill together with the local `thumble-mcp` stdio server (typed profile, layout, binding, and runtime tools). A repo marketplace at `.agents/plugins/marketplace.json` exposes it:

1. Restart the ChatGPT desktop app with this repository checked out (or run `codex plugin marketplace add /absolute/path/to/Thumble`).
2. Open **Plugins** in the sidebar, choose the **Thumble (repo marketplace)** source, and install **Thumble**.

The bundled MCP launcher finds the adapter via `$THUMBLE_MCP_BINARY`, the Thumble Host app bundle, or `PATH`. Input and configuration writes stay disabled unless explicitly enabled. See [`plugins/thumble/README.md`](../plugins/thumble/README.md) and [`docs/rust-host.md`](rust-host.md) for details, security defaults, and the remote relay option for ChatGPT chat-side connectors.

## Locate or build the CLI

First ask the agent to check whether the CLI is already available:

```bash
command -v thumble
thumble --help
```

From a Thumble source checkout, build to a predictable location:

```bash
xcodebuild -project Thumble.xcodeproj \
  -scheme ThumbleCLI \
  -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData \
  build

export THUMBLE_CLI="$PWD/build/DerivedData/Build/Products/Debug/thumble"
"$THUMBLE_CLI" --help
```

The build also produces `thumbconsole` and `pocketpad` compatibility executables, but new instructions should use `thumble`.

## Recommended agent workflow

Ask the agent to follow this loop for reliable, reviewable changes.

### 1. Inspect without changing anything

```bash
thumble --help
thumble profile list --ids
thumble profile show active --json
thumble status --json
```

`profile` commands can inspect saved configuration while the Mac helper is closed. Runtime status and syncing require Thumble Mac to be running.

### 2. Choose the smallest workflow

| Goal | Preferred command |
|---|---|
| Known game with a built-in generator | `generate "Game Name" --dry-run` |
| Unknown game | Research controls, write a JSON spec, then `generate --spec FILE --dry-run` |
| Familiar console/emulator layout | `template list`, then `template install` |
| Productivity or app shortcuts | `profile create`, `element`, and `binding` |
| Revise an existing keypad | `profile show`, then targeted `element`, `binding`, or `output` changes |
| Fix spacing or touch targets | `layout validate`, `layout fix`, and `layout preview` |
| Apply an existing visual skin | `skin inspect`, `skin validate`, then `skin import` / `skin apply` |
| Diagnose the Mac helper | `status`, `monitor`, `latency`, `server`, `pairing`, or `accessibility` |

For generated profiles, remember that `generate` installs, selects, and makes the new profile the default unless the agent passes `--no-select` or `--no-default`. The dry-run summary also lists every control's rendered point size on the reference canvas, so the agent can confirm buttons are thumb-sized before installing.

### 3. Preview before applying

Use the non-mutating path whenever one exists:

```bash
thumble generate --spec /tmp/game-keypad.json --json --dry-run
thumble layout validate --profile "My Keypad" --json
thumble layout preview --profile "My Keypad" \
  --variant landscape \
  -o /tmp/my-keypad-landscape.png
```

For unknown games, the spec should identify its source and use an honest `high`, `medium`, or `low` confidence value. A low-confidence but playable mapping is better than silently presenting guessed controls as fact.

### 4. Apply the requested change

When the prompt clearly asks the agent to create, install, select, or update a keypad, it may make that scoped change after previewing it. It should avoid unrelated profile, default, output-mode, or appearance changes.

When Thumble Mac is running, saved CLI changes are reloaded and synced to the paired iPhone. The iPhone may still show the saved profile offline when the helper is closed, but it cannot control the Mac until reconnected.

### 5. Verify and report

```bash
thumble profile show active --json
thumble layout validate --profile active --json
thumble binding display --profile active --json
thumble status --json
```

A useful final report names the profile, confidence/source when relevant, final bindings, layout validation result, whether it was selected/defaulted, and whether sync could be confirmed.

## Copy-paste prompts

Replace paths and names before sending these to your agent.

### Create a game keypad

```text
Read /absolute/path/to/Thumble/SKILL.md, then use the thumble CLI to
create a keypad for [GAME]. Look up the default Mac keyboard controls from a
reliable source. Dry-run before installing. Put movement on the left, frequent
actions within easy right-thumb reach, and pause/menu away from primary actions.
Make controls thumb-sized — primary actions at least ~90pt rendered, nothing
under 66pt (check the dry-run size table). Install and select the profile, but
do not replace unrelated profiles. Validate the layout and summarize the source,
confidence, bindings, control sizes, and validation result.
```

### Create a productivity pad

```text
Read /absolute/path/to/Thumble/SKILL.md and create a Thumble profile
named "[NAME]" for [APP]. I need controls for [LIST OF ACTIONS/SHORTCUTS]. Keep
labels short, use a trackpad only if it helps this workflow, attach the app at
[APP PATH] only if it exists, and preserve my current default profile. Preview
and validate the layout, then show me exactly what changed.
```

### Improve an existing layout

```text
Read /absolute/path/to/Thumble/SKILL.md. Inspect my Thumble profile
"[PROFILE]" without changing it first. Validate portrait and landscape layouts,
then fix only touch-target, overlap, edge, size, and thumb-reach issues. Preserve
all bindings, labels, output modes, and the current default. Render layout
previews and report each repair plus any issue that remains.
```

### Diagnose connection or input lag

```text
Read /absolute/path/to/Thumble/SKILL.md. Diagnose Thumble without UI
automation. Inspect status and accessibility, then use the synthetic latency
compare/verify commands before suggesting physical-device capture. Do not restart
the server, open System Settings, launch apps, or send test input unless I approve
that action. Summarize evidence separately from recommendations.
```

### Install a skin safely

```text
Read /absolute/path/to/Thumble/SKILL.md. Inspect and strictly validate
[PACKAGE.pocketpad], explain what it can style and any warnings, then apply it to
"[PROFILE]" only. Preserve geometry, labels, bindings, launch targets, and output
mode. Do not publish or submit the skin anywhere.
```

Handcrafted skin creation has a stricter art-direction, editable-source, native-render, critique, QA, and human-approval workflow. Agents should also read [`docs/skins/README.md`](skins/README.md) and use the project `thumble-skin-author` skill before authoring or revising a community skin.

## Safe automation boundaries

Tell the agent about any stricter boundaries you want. The repository skill uses these defaults:

- Prefer CLI inspection and mutation over clicking through the Mac or iPhone UI.
- Use `thumble app screenshot` for visual verification. It captures a Thumble window without activating it or sending keyboard/mouse events.
- Do not launch Thumble Mac, open System Settings, or trigger permission prompts without user permission because those actions can change focus or interrupt work.
- Treat `test tap`, `test down`, and `test up` as real input: they invoke the selected control's configured output in the focused Mac app.
- Use `release-all` if a test is interrupted or a held input is uncertain.
- Inspect before destructive commands such as profile deletion/reset, skin removal, binding reset, or output-mode replacement. Export a backup with `profile export --all` before a broad migration or reset.
- Do not print or publish pairing codes, trusted reconnect material, private app paths, or captured diagnostics unless the user requested them.
- Never claim that a skin was approved or publish one without explicit human approval of the exact review artifact and package hash.

## What agents can and cannot verify

An agent can verify saved profiles, bindings, output mappings, layout-health checks, rendered previews, Mac helper state, accessibility status, and synthetic latency assumptions from the CLI.

An agent cannot infer that physical iPhone input feels good from a rendered preview or synthetic replay. Final ergonomic judgment, real network latency, game recognition, and virtual-controller availability may require the paired device, the target app, and a human test. Ask the agent to state these limits instead of claiming success from configuration alone.

## Troubleshooting an agent session

- **`thumble: command not found`:** Give the agent the absolute binary path or let it build the CLI from the source checkout.
- **The agent keeps trying to click the app:** Explicitly require `SKILL.md`, CLI-only operation, and `app screenshot` for visual checks.
- **A new profile unexpectedly became the default:** Generation defaults to install + select + default. Request `--no-default` and optionally `--no-select`.
- **An unknown game fails generation:** Ask the agent to research or infer controls and provide a JSON spec instead of inventing a hidden fallback.
- **Changes do not appear on iPhone:** Saved changes can still be valid. Thumble Mac must be running and the iPhone paired for immediate sync.
- **Screenshot verification fails:** Screen Recording access must already be granted to the terminal or agent host. Do not ask the agent to bypass the permission with screen-control automation.
- **Controller mode does not appear in a game:** System-visible virtual gamepad output requires Apple's virtual HID entitlement. Keyboard and pointer output can still work.

For the full command reference and agent decision tree, use [`SKILL.md`](../SKILL.md). For ordinary app setup and editor usage, return to the [main README](../README.md) or the [website documentation](../Website/docs.html).
