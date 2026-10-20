# Local preview verification

Selected Everyday Play in the running native Mac editor through its validated
configuration API, using the reviewed1.0.0 package. The dry-run and commit both
preserved all existing profiles and the default profile. Thumble Host remains
stopped. The existing app/CLI clean-preview feature displays the native controller
without editor guides, sidebars or secondary binding glyphs; no new app or CLI
functionality was added for this appearance.

`mac-clean-preview-1.0.0.png` captures only the actual Thumble window using the
purpose-built `thumble app screenshot` command. Primary legends, both clusters,
shoulders and utility controls match the reviewed native appearance. App device
chrome remains native; the website uses the clean renderer output directly.

Updated only Everyday Play's hero asset/caption and screenshot provenance.
`website-hero-preview.png` captures the local8174 hero with Everyday Play selected.
WoW's existing panel and default HTML selection remain intact; original docs
screenshots are retained. No public skin catalog or deployment changed.

Required stack-safety verification passed (`./scripts/verify-stack-safety.sh`),
recorded at `/tmp/thumble-everyday-stack-safety.log`. Both visual passes and strict
independent deterministic QA pass. Exact package, contact sheet and preview hashes
are retained in `review-hashes.json`. Human approval remains pending.
