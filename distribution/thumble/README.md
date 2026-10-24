# Thumble distribution drafts

These files prepare marketplace submissions; they are not evidence of publication or cross-client compatibility.

- `openai/`: portable Agent Plugins package, MCP OAuth settings, current app icon, and review scenarios. ZIP `thumble-openai-0.1.2.zip` contains this folder's contents at the ZIP root.
- `claude/`: Claude-compatible metadata and remote MCP declaration. Client registration is still required.
- `grok/`: Grok Build metadata and remote MCP declaration; OAuth compatibility is unverified.
- `intake.json`: recoverable Grok/Cursor intake copy; missing URLs and attestations are explicit.
- `gemini/`: Gemini CLI extension manifest. Publish at the root of a dedicated public distribution repository or self-contained release archive after authentication testing.
- `registry/`: metadata-only MCP Registry remote server draft; no npm package is needed for remote-only distribution. Authenticate the GitHub namespace before publishing.

Public publisher/contact: Thumble / codybontecou@gmail.com. No account credentials, access tokens or client secrets belong in these packages. The OpenAI public client identifier is intentionally included; it is not a secret.

The packages use the verified pilot URL. Choose the long-term endpoint before review: OpenAI's current update flow does not support changing an existing MCP URL without support.

Read [submission status and blockers](../../docs/marketplaces/status.md) before uploading or publishing. The old `0.1.0` and `0.1.1` OpenAI ZIPs are historical; use `0.1.2`.
