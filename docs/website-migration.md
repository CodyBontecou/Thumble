# Website ownership in the current repository

The production website source is now `apps/website`, in the current Thumble codebase. The legacy checkout is retained as a historical copy and is not needed for builds or deployment.

## Included

- Landing/setup/support pages, historical blog and all 14 guide/comparison articles.
- Original and optimized artwork, CSS, browser scripts and agent discovery documents.
- Pages Functions, Markdown negotiation and the waitlist/attribution handler.
- D1 schema, additive migration and reporting queries (excluded from deployment assets).
- Website tests, artwork sources and optional Lighthouse image/CSS tooling under `tools/website`.
- Root build/test/preview/deploy commands and `.github/workflows/website.yml` checks.

## Commands

From the repository root, use Node 24 or newer:

```sh
npm run website:test
npm run website:build
npm run website:dev
npm run website:deploy
```

The artifact is `dist/website`. The existing Cloudflare Pages project is `pocketpad-site`, production branch `main`, domain thumble.io. The current D1 and R2 bindings are retained; Cloudflare continues to hold encrypted production secrets. The receiver download Worker remains independent in `apps/downloads`.

The CLI script and archive are pinned by SHA-256 in `apps/website/cli-distribution.json`. The build copies the script from `packages/cli`, caches the existing public archive under ignored `build/website-downloads`, and rejects mismatches. It can accept a matching offline archive. No generated tarballs or local database files are committed.

## Verification

The imported build preserved all 105 files in the previously deployed artifact. HTML, artwork and CLI downloads were byte-identical; the negotiated Markdown map intentionally restores related-reading links, while continuing to omit navigation and table-of-contents noise.

Ten website tests cover content discovery, all article routes derived from the hub, canonical/link/attribution coverage, HTML/Markdown negotiation, real SQLite signup/rollback behavior and deployment source exclusion. A new regression assertion preserves related links in Markdown. Local Pages Functions served the home, guide hub, keybindings article, sitemap, CLI and real missing-page response, and accepted a synthetic signup against local-only D1.

The CI workflow builds and tests website changes without production credentials. Deployment remains an explicit action through an authorized Cloudflare session.
