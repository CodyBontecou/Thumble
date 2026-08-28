# Thumble plugin (ChatGPT + Codex)

One installable package that bundles:

- **Skill** — `thumble-keypad-generator`: the full agent workflow for generating,
  dry-running, installing, and editing Thumble keypad profiles with the `thumble` CLI,
  including thumb-sized control guidance.
- **MCP server** — a local stdio adapter (`thumble-mcp`) exposing Thumble Host's
  revision-safe profile, layout, binding, and runtime operations as typed MCP tools.

Works in Codex (CLI, IDE extension, and Codex in the ChatGPT desktop app). Published
plugin builds also surface in ChatGPT chat surfaces.

## Install (repo marketplace)

The repository ships a local marketplace at `.agents/plugins/marketplace.json`.

1. Clone this repo and open the ChatGPT desktop app.
2. Restart the ChatGPT desktop app so the repo marketplace is discovered.
3. Open **Plugins** in the sidebar → choose the **Thumble (repo marketplace)** source →
   install **Thumble**.

From the CLI you can also register the marketplace explicitly:

```bash
codex plugin marketplace add /absolute/path/to/Thumble
```

After installing, invoke the skill with `$thumble-keypad-generator` (or just ask for a
Thumble keypad). The MCP tools appear as the `thumble` MCP server.

## Requirements

- **Thumble Host** running locally for runtime and configuration tools. The bundled
  MCP launcher resolves the adapter in this order:
  1. `$THUMBLE_MCP_BINARY` (absolute path override),
  2. `/Applications/Thumble Host.app/Contents/MacOS/thumble-mcp` (app bundle),
  3. `thumble-mcp` on `PATH` (e.g. `cargo install --locked --path Host/crates/thumble-mcp`).
- **`thumble` CLI** for the skill's full workflow (generate/spec/bindings/skins). Build
  it from the repo or install it on `PATH`; the skill documents both.

## Security defaults

The MCP adapter ships with input and configuration writes **disabled**:

- `press_control` requires `--allow-input` or `THUMBLE_MCP_ALLOW_INPUT=1`.
- Saving configuration drafts requires `--allow-config-write` or
  `THUMBLE_MCP_ALLOW_CONFIG_WRITE=1` (plus the host-side flag).

Read/inspect tools work without opt-in. See `docs/rust-host.md` for the full model.

## Notes

- **MCP Apps UI** (controller preview/editor surfaces) is experimental in Codex desktop;
  enable with `[features] enable_mcp_apps = true` in `~/.codex/config.toml`, then fully
  restart. Tools remain fully usable as structured output without it.
- **ChatGPT chat-side connectors** require a remote MCP endpoint. Run
  `thumble-mcp --relay wss://thumble-mcp-gateway.fly.dev/tunnel` and register the
  gateway URL in ChatGPT developer mode — see `docs/rust-host.md` ("Remote MCP
  connector relay").
- **Keeping the bundled skill in sync**: `skills/thumble-keypad-generator/SKILL.md` is a
  copy of the repository root `SKILL.md`. Refresh the copy whenever the root skill
  changes before publishing or shipping a release.
