> Current source: `apps/website` in the new Thumble repository. Website source, tests and tooling were migrated to main in commit `f468b92`; production was redeployed from that checkout at https://3e733347.pocketpad-site.pages.dev. Legacy paths below describe historical work only. Use `npm run website:test`, `npm run website:build` and `npm run website:deploy` from this repository. See `docs/website-migration.md`.


### Production deployment — October 26, 2026

Deployed the first content batch to the `pocketpad-site` production branch `main` using an isolated staging directory. Deployment URL: https://a79a6e0f.pocketpad-site.pages.dev. Existing published CLI script/package bytes were preserved; the receiver Worker, database schema and release objects were not changed.

All 17 live HTTP checks passed against https://thumble.io: hub and three articles in HTML and Markdown, homepage discovery links, setup compatibility section, sitemap (16 URLs), guide CSS, Markdown HEAD response, real missing-guide 404, both CLI downloads and receiver-download HEAD. Published guide HTML matched the staged files after removing Cloudflare's injected analytics script. A production browser check confirmed the ConsolePort title, H1, canonical, form source and no horizontal overflow at 390px. No real signup was submitted.

Deployment is complete. Search indexing/rankings and full acquisition attribution remain separate follow-up work.

## Second batch deployed — October 26, 2026

Production deployment: https://70d987e3.pocketpad-site.pages.dev, serving thumble.io.

Added `/guides/wow-controller-not-detected-mac` and `/guides/thumble-phone-mac-pairing`, with links from the hub, setup, support and ConsolePort guide. The hub now contains five articles and the sitemap has 18 URLs. Instructions were checked against the current receiver invitation handling, addon recovery policy and documented setup, and identify themselves as documented checks rather than universally reproduced fixes.

Signup attribution is now active. The browser preserves an approved first landing within its tab, and submits approved first/latest landing and campaign values with signup. The server validates the same allowlists. The additive `waitlist_attribution` table preserves the first tracked source/touch and updates latest attribution on subsequent signup. Subscriber and attribution writes run in one D1 batch. Existing historical acquisition remains unknown; this is not per-user organic-keyword or cross-device attribution. Privacy copy explains the change.

Source remains in `/Users/codybontecou/dev/Thumble-legacy/Website`; tests are under that repository's `scripts/website`. Current app code in this repository was not changed for the SEO rollout. Aggregate reporting queries are in the website source's `reports/attribution.sql`; database migrations and reports were excluded from public deployment assets. The published CLI script/package were preserved.

Verification: eight Node tests passed, including real SQLite upserts, migration repeatability, rollback and validation/honeypot/consent checks. Wrangler compiled the Functions bundle. A local browser exercised an actual signup against an isolated in-memory database, confirming first landing survives navigation to the waitlist. Mobile and desktop checks passed at 320, 390 and 1440px. Production D1 schema was verified without reading subscriber records. Twenty-one live content/download checks plus two JavaScript MIME checks and one invalid-signup rejection passed. Production browser confirmed module loading and attribution capture. No production subscriber was created.

Remaining: connect an authorized Search Console property and record query/page baselines, then use real impressions and qualified signup counts to choose the next content expansion. No automatic publishing or recurring job was created.

## Third article batch deployed — October 26, 2026

Published `/guides/iphone-controller-mac` (phone-controller workflow, requirements, setup and availability) and `/compare/wow-phone-vs-gamepad` (documented method comparison, with physical-controller recommendations where appropriate). Deployment: https://693b5bbf.pocketpad-site.pages.dev.

The guide hub now has seven articles. The homepage, category and ConsolePort guides link to the new decision-stage pages, the sitemap lists 20 URLs, and both paths are recognized by the bounded attribution helper. No database migration or signup-handler behavior change was required. Phone apps remain marked coming soon. The comparison makes no hands-on, latency, battery-life or competitive-performance claims; ConsolePort is presented as a complementary addon.

Verification: eight automated tests passed, including discovery, canonical/heading/schema/link checks, attribution allowlist coverage and HTML/Markdown negotiation. Local browser checks at 320, 390 and 1440px found no page overflow or missing images for the hub and both new pages. All 25 production HTTP checks passed, including exact published article HTML (excluding Cloudflare's injected analytics script), Markdown, 20-URL sitemap and preserved downloads. A production mobile-browser check confirmed the comparison title, canonical, seven comparison rows, form source and attribution path. No production signup or gameplay input was generated. Evidence: `docs/evidence/seo-articles-2026-10-26/production-checks.json`.

Search-performance conclusions remain constrained by the initial Search Console snapshot in `search-console-baseline-2026-10-26.md`; no ranking or indexing gain is implied by publication.

## Fourth article batch deployed — October 26, 2026

Published `/guides/consoleport-wrong-action-modifier` and `/guides/wow-controller-camera-reversed-mac`. Deployment: https://daa714b8.pocketpad-site.pages.dev.

The articles separate incorrect bindings, active modifier combinations and stale snapshot labels, and distinguish ConsolePort game-camera behavior from Thumble touch-axis calibration/dead zones. Settings names and sync options are conditional on installed builds; source-only settings are not presented as universally shipped features. These are documented diagnostic steps, not claims of reproduced fixes or live-game certification.

The guide hub now has nine articles and the sitemap lists 22 URLs. Contextual links were added to setup, support, ConsolePort setup and controller detection. Both paths have bounded attribution coverage. No database migration, gameplay action or app-code change was required.

Verification: eight automated tests passed. Local browser checks covered the hub and both articles at 320, 390 and 1440px with no page overflow. All 29 production HTTP checks passed, covering published HTML and Markdown, the 22-URL sitemap and preserved downloads. A production mobile browser confirmed the binding article's title, H1, canonical, form source and attribution path. Evidence: `docs/evidence/seo-control-troubleshooting-2026-10-26/production-checks.json`. No production subscriber was created. Publication does not establish indexing or search-performance gains.

## Fifth article batch deployed — October 26, 2026

Published `/guides/consoleport-spell-labels-not-syncing` and reorganized the guide hub into Choose your controls (3 articles), Set up WoW (2), and Troubleshoot your setup (5). Deployment: https://241a490e.pocketpad-site.pages.dev. The hub now contains ten articles and the sitemap lists 23 URLs.

The new article distinguishes incorrect actions from stale labels, explains the saved snapshot and /reload workflow, and covers the selected character, receiver installation and active phone controller. Sync menus and status reporting are conditional on installed builds. Labels and cooldowns are not described as live telemetry. Contextual links connect addon installation, binding troubleshooting, setup and support to this article. Article/Breadcrumb structured data, the hub ItemList, Markdown output and bounded attribution allowlist were updated.

Verification: eight automated tests passed and git diff --check was clean. Local hub and article checks passed at 320, 390 and 1440px without horizontal overflow; desktop and mobile screenshots were reviewed. All 31 production HTTP checks passed, including exact guide HTML (excluding the Cloudflare analytics injection), Markdown, the 23-URL sitemap, real 404 handling and preserved CLI/download endpoints. Production mobile checks confirmed the hub categories, all ten cards, category anchor targets, article title/canonical/form source and module loading. Evidence: `docs/evidence/seo-label-sync-2026-10-26/production-checks.json`. No production subscriber was created. Publishing does not establish indexing or ranking gains.

## Sixth article batch deployed — October 26, 2026

Published `/guides/wow-classic-controller-mac`: a client-specific setup and compatibility checklist with a two-column component table, physical and phone controller paths, exact-version checks and common questions. Deployment: https://b3748655.pocketpad-site.pages.dev.

This page addresses Classic release selection rather than duplicating the generic ConsolePort installation steps. ConsolePort’s multiple release flavors are distinguished from the documented Thumble addon 0.1.2 Classic Era 1.15.9 scope. No additional Classic or Retail certification is asserted. Official ConsolePort, CurseForge and Apple sources were checked, alongside the approved local addon release metadata. Source notes: `docs/evidence/seo-classic-compatibility-2026-10-26/sources.md`.

The hub now contains 11 articles, grouped 3/3/5 across choosing controls, setup and troubleshooting. Contextual links were added from the category, ConsolePort setup, companion-addon installation and setup reference. The 24-URL sitemap, hub ItemList, Article/Breadcrumb data, Markdown and bounded attribution allowlist include the new guide.

Verification: all eight automated tests passed; git diff --check was clean. Local checks covered the hub and article at 320, 390 and 1440px without page overflow, with reviewed mobile and desktop screenshots. The table was simplified to two columns after mobile review. All 33 production HTTP checks passed. Production browser confirmed the new article’s title, H1, canonical, form source, attribution module loading and four table rows, plus all 11 hub cards and schema items. Evidence: `docs/evidence/seo-classic-compatibility-2026-10-26/production-checks.json`. Existing CLI bytes were preserved. No database change, production signup or app-code edit was made. No indexing or ranking gain is inferred.

## Seventh article batch deployed — October 26, 2026

Published `/guides/wow-addons-not-showing-mac`, covering missing versus disabled addons, CurseForge instance selection, manual folder/TOC structure, release mismatches and the transition to controller-input troubleshooting. Deployment: https://f3986f80.pocketpad-site.pages.dev.

The page includes a four-row symptom table and real ThumbleBridge folder examples. Wrap opportunities between folder names prevent path overflow on mobile while preserving the copied text. Sources were checked against the official CurseForge documentation, the Townlong Yak addon-author installation guide and local Thumble release records. Development interface declarations were not treated as proof of public release support.

The guide hub contains 12 articles, grouped 3/3/6 across choosing controls, setup and troubleshooting. Contextual links were added from ConsolePort setup, Thumble addon installation, Classic compatibility and support. Article/Breadcrumb schema, the hub ItemList, Markdown, attribution allowlist and 25-URL sitemap include the new guide. A concurrent website README edit was preserved; only this batch’s ten changed source/test files were saved.

Verification: all eight automated tests passed and git diff --check was clean. Local hub and article checks covered 320, 390 and 1440px, with reviewed desktop and mobile screenshots. The initial path overflow was corrected and rechecked. All 35 production HTTP checks passed, including published HTML/Markdown, sitemap, real missing-page responses and preserved CLI/download endpoints. Production mobile browser confirmed the article title, H1, canonical, form source, attribution module, folder text and no overflow, plus all 12 hub cards and matching schema entries. Evidence: `docs/evidence/seo-missing-addons-2026-10-26/production-checks.json`; source notes are in the same folder. No gameplay or production signup was performed, and no indexing or ranking gain is inferred.

## Eighth article batch deployed — October 26, 2026

Published `/guides/consoleport-keybindings-mac`, a beginner’s planning guide with five action groups, a base-layout workflow, modifier practice and a five-step verification sequence. Deployment: https://121eacc9.pocketpad-site.pages.dev.

The article addresses initial binding decisions, complementing the symptom-driven wrong-action guide. It labels the grouping and practice method as editorial advice, not an official preset, tested class build or universal button map. In-game bindings remain separate from phone label metadata. Thumble snapshot features are conditional on matching builds and the published addon scope remains Classic Era 1.15.9. Source and editorial-scope notes: `docs/evidence/seo-keybindings-2026-10-26/sources.md`.

The hub now contains 13 articles, grouped 3/4/6 across choosing controls, setup and troubleshooting. Contextual links connect ConsolePort setup, Classic compatibility and wrong-action troubleshooting. The sitemap contains 26 URLs. Article/Breadcrumb data, hub ItemList, Markdown and bounded attribution include the new route. Nine changed source/test files were saved with concurrent-edit checks.

Verification: all eight automated tests passed and git diff --check was clean. Local article and hub checks at 320, 390 and 1440px found no page overflow; mobile worksheet and desktop/mobile article screenshots were reviewed. All 37 production HTTP checks passed, including published HTML and Markdown, sitemap and preserved downloads. Production mobile browser confirmed article title/H1/canonical/form source, five worksheet rows, attribution module loading and no overflow; the hub has 13 cards and matching schema items. Evidence: `docs/evidence/seo-keybindings-2026-10-26/production-checks.json`. No gameplay or production signup was performed. Publication does not establish indexing or ranking gains.

## Ninth article batch deployed — October 26, 2026

Published `/compare/wow-controller-vs-keyboard-mouse-mac`, comparing movement, ability access, targeting, menus, chat and setup effort. Includes selection guidance and a mixed-input transition checklist. Deployment: https://ba64d91d.pocketpad-site.pages.dev.

The comparison addresses whether to adopt controller play, distinct from the existing comparison between phone controls and physical gamepads. It makes no measured performance, raid/PvP or ergonomic claims. ConsolePort’s documented tools and Apple connection requirements were checked; source notes are in `docs/evidence/seo-keyboard-comparison-2026-10-26/sources.md`. Public phone apps remain coming soon and published companion-addon scope is kept explicit.

The hub now contains 14 articles, grouped 4/4/6 across choosing controls, setup and troubleshooting. Contextual links connect the category page, beginner binding guide and phone-versus-gamepad comparison. The sitemap has 27 URLs; Article/Breadcrumb, hub ItemList, Markdown and bounded attribution include the new route. Nine source/test files were saved with concurrent-edit checks.

Verification: all eight automated tests passed and git diff --check was clean. Local hub and comparison checks at 320, 390 and 1440px found no page overflow; desktop, mobile and table screenshots were reviewed. All 39 production HTTP checks passed, including exact published article HTML, Markdown, sitemap and preserved downloads. Production mobile browser confirmed title/H1/canonical/form source, six comparison rows, attribution module loading and no overflow; hub cards and structured-data items both total 14. Evidence: `docs/evidence/seo-keyboard-comparison-2026-10-26/production-checks.json`. No gameplay or production signup was performed. Publication does not establish indexing or ranking gains.

## Main-guide navigation improvements deployed — October 26, 2026

Improved `/guides/wow-controller-mac` and `/guides/consoleport-mac-setup`. Deployment: https://8f757933.pocketpad-site.pages.dev. No new article URL was added; the hub remains at 14 articles and the sitemap at 27 URLs.

The category page now offers a six-row task-based next-step table near the start, with a table-of-contents anchor. ConsolePort setup offers six symptom-based troubleshooting routes under its existing anchor. Related links were moved beside installation, controller-choice and binding instructions. Repeated bottom-of-page related sections were consolidated, leaving the consented launch signup as the final article section. The existing responsive controller preview and canonical/form sources were preserved. Three source files changed: both HTML pages and generated Markdown.

Verification: all eight automated checks passed and git diff --check was clean. Both pages were checked at 320, 390 and 1440px without overflow; mobile tables and desktop layout were visually reviewed. All 39 production HTTP checks passed, covering published HTML/Markdown, sitemap and preserved downloads. Production browser confirmed six rows on each revised page, the new TOC target, retained preview image and signup placement. Evidence: `docs/evidence/seo-guide-navigation-2026-10-26/production-checks.json`. No production signup or gameplay was performed. No indexing or ranking gain is inferred.

## Supporting-article navigation cleanup deployed — October 26, 2026

Consolidated related links on all 12 supporting articles and comparisons. Deployment: https://33982488.pocketpad-site.pages.dev. The two main guides retain their task/symptom tables. The hub remains at 14 articles and the sitemap at 27 URLs.

Each supporting page now has a single topic-specific related-guides section with three distinct non-self links, placed immediately before signup and reachable through its table of contents. Repeated trailing related sections were replaced. The original body instructions and sources remain in place. Signup is now the final article section on all 14 pages. Thirteen source files changed: twelve HTML pages and generated Markdown.

Verification: all eight automated checks passed and git diff --check was clean. A structural audit covered all 14 articles; 28 responsive browser checks at 320 and 1440px found no overflow or signup-order failures. Mobile and desktop related-link sections were visually reviewed. All 39 production HTTP checks passed. A separate production DOM audit confirmed signup last on all 14 pages and three related links plus TOC access on all 12 updated supporting pages. Evidence: `docs/evidence/seo-related-navigation-2026-10-26/`. Existing download bytes were preserved; no gameplay, production signup, database change or indexing/ranking gain is claimed.
