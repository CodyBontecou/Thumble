# Thumble marketplace packages

Canonical hosted MCP: https://thumble.io/mcp. Authentication, token exchange and reviewer sign-in use thumble.io. Current hosted capabilities are pairing and read-only inspection; controller generation, saving and sending are disabled.

- `openai-read-only/`: current OpenAI 0.2.3 correction source. `thumble-controller-openai-0.2.3.zip` is submitted and in review after owner-approved final attestations. Five positive/three negative review cases, read-only base scopes, canonical endpoints. Private reviewer details remain in the portal.
- `openai/`, `openai-canonical/` and earlier ZIPs: historical package sources/releases; do not use their older capability claims for a new submission. 0.2.2 had canonical auth URLs but still advertised disabled writes.
- `claude/`: submitted Claude Code plugin source, separate from the published standalone Claude connector. Public repository: https://github.com/CodyBontecou/thumble-claude-code . Scan passed; publication requested; reviewer approval pending.
- `cline/`: public remote-MCP setup package. https://github.com/CodyBontecou/thumble-cline . README-only Cline agent installation and authenticated read calls passed with the normal interactive OAuth handoff. Submission #3255 has both installation checkboxes checked and awaits review.
- `gemini/`: public Gemini CLI extension, https://github.com/CodyBontecou/thumble-gemini . Root manifest and required topic confirmed; gallery indexing unconfirmed.
- `registry/`: active official MCP Registry remote-server metadata, version 0.1.0.
- `muse/`: submitted canonical replacement; all three requirements complete and in review.
- `grok/` and `intake.json`: combined Grok/Grok Bot/Cursor intake copy and separate Grok Build draft. Combined intake was submitted; no Grok Build PR has been opened.

Publisher: Thumble / Isotech. Contact: codybontecou@gmail.com; directory support also uses cody@isolated.tech. Never put private account credentials, access tokens or client secrets in these public packages. Public OAuth client identifiers are not secrets.

Use [marketplace status](../../docs/marketplaces/status.md) for live submission state and outstanding requirements. Local package edits do not update a submitted listing.
