# Thumble Controller

Inspect your saved Thumble phone-controller layouts, registered phones and existing delivery receipts from Claude. This plugin provides an inspection skill and a remote MCP reference to **https://thumble.io/mcp**. It reads existing account data and does not generate, save or send controllers or issue gameplay input.

## Install and connect

This package is being submitted to Anthropic's plugin directory. It is not yet available from `claude-plugins-official`. Install the public package directly in Claude Code 2.1.275 or later:

```text
/plugin install thumble-controller --marketplace CodyBontecou/thumble-claude-code
```

For local evaluation, clone this repository and start Claude Code with `claude --plugin-dir /absolute/path/to/thumble-claude-code`. Run `/mcp`, choose Thumble and authenticate. On Claude.ai, connect the published [Thumble connector](https://claude.ai/directory/thumble) and use the plugin after directory approval.

Claude Code uses the public client `thumble-claude-code` and a fixed local callback at `http://localhost:8766/callback`. Keep port 8766 available. Sign in to Thumble by email code, Google or Apple, review the read-only permissions and allow access. No client secret or API key is required. Use a current Claude Code release with `oauth.clientId`, `oauth.callbackPort` and `oauth.scopes` support. The public configuration pins read-only scopes; general-purpose dynamic registration is restricted.

## Try it

Ask “List my saved Thumble controllers,” “Inspect the latest revision of my controller,” or “Check this existing delivery receipt.” The inspection skill uses returned identifiers and reports the actual saved revision or receipt state. Empty controller or phone lists are valid for a new account. Phone-specific results require a registered phone signed in with the same account; the [public iOS beta](https://testflight.apple.com/join/kxwHv4qW) is available for testing.

## Permissions and data handling

OAuth uses authorization code, S256 PKCE, explicit consent and tokens bound to https://thumble.io/mcp. Scopes are `offline_access`, `profiles:read`, `devices:read` and `deliveries:read`. Claude stores its OAuth credentials and may renew the consented connection. The plugin has no hooks, executable scripts, telemetry or additional service endpoints. The declared Thumble service processes account-scoped tool requests and stores saved controllers, registered-device records and delivery receipts according to its [privacy policy](https://thumble.io/privacy). The plugin itself adds no separate data store.

The MCP endpoint also advertises a pairing QR tool, but this plugin's OAuth client has no pairing permission. Use its read-only inspection workflow. A rendered receipt confirms phone rendering, not Mac input or game bindings. Gameplay requires Thumble's separate local Mac receiver and the built-in ConsolePort controller.

For authentication failures, retry the normal `/mcp` authorization flow. Keep tokens and sign-in codes out of support messages and GitHub issues. For callback failures, check port 8766 and retry.

[Website](https://thumble.io) · [Documentation](https://thumble.io/docs) · [Privacy](https://thumble.io/privacy) · [Terms](https://thumble.io/terms) · [Support](mailto:cody@isolated.tech)
