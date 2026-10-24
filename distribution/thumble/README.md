# Thumble distribution drafts

These files prepare marketplace submissions; they are not evidence of publication or cross-client compatibility.

- `openai/`: portable Agent Plugins package, MCP OAuth settings, current app icon, and review scenarios. Source manifests use thumble.io; existing 0.1.x ZIPs preserve their original pilot endpoints.
- `claude/`: Claude-compatible metadata and remote MCP declaration. Client registration is still required.
- `grok/`: Grok Build metadata and remote MCP declaration; OAuth compatibility is unverified.
- `intake.json`: recoverable Grok/Cursor intake copy; missing URLs and attestations are explicit.
- `gemini/`: Gemini CLI extension manifest. Publish at the root of a dedicated public distribution repository or self-contained release archive after authentication testing.
- `registry/`: metadata-only MCP Registry remote server draft; no npm package is needed for remote-only distribution. Authenticate the GitHub namespace before publishing.

Public publisher/contact: Thumble / codybontecou@gmail.com. No account credentials, access tokens or client secrets belong in these packages. The OpenAI public client identifier is intentionally included; it is not a secret.

All source packages use `https://thumble.io/mcp`, with authorization and token exchange under `https://thumble.io/api/auth`. OpenAI's current update flow does not support changing an existing MCP URL without support.

Read [submission status and blockers](../../docs/marketplaces/status.md) before uploading or publishing. All `thumble-openai-0.1.x.zip` archives are historical pilot snapshots. Use `thumble-controller-openai-0.2.1.zip` for the current canonical endpoints.


## Canonical OpenAI draft (October 24, 2026)

The submitted 0.2.0 package was built from `openai-canonical/`; use `thumble-controller-openai-0.2.1.zip` for subsequent uploads with canonical authorization endpoints. It keeps the public display name Thumble and uses `https://thumble.io/mcp`. OpenAI does not allow replacing the origin on the old `thumble` draft; the new package name identifies a separate draft. The `openai/` source manifest also uses the canonical domain; the 0.1.x ZIPs remain historical pilot snapshots.

Current portal: https://platform.openai.com/plugins/manage/plugin_asdk_app_6adc8f83963881918c960106b339df6d

See [submission status and blockers](../../docs/marketplaces/status.md) for the current portal state. Package source updates do not change an already submitted listing.


## Authentication domain migration (October 24, 2026)

The canonical package now uses `https://thumble.io` for authorization and token exchange as well as MCP. Use `thumble-controller-openai-0.2.1.zip` for a future update. The 0.2.0 and pilot archives remain historical snapshots; installed connections continue using their cached endpoints. This local package update does not update a submitted marketplace listing.
