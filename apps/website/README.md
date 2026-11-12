# Thumble website

Production source for thumble.io (Cloudflare Pages project `pocketpad-site`).
The site uses the app's Native design (November 2026 redesign): system dark,
the system font, #0A64D8 blue, and `native.css` as the design system. New pages
(`index.html`, `pricing.html`, `download.html`) load only `native.css`; older pages
load it last so it rethemes their existing styles and gives every page the same
header and footer. The homepage controller and customization tiles are inline SVG
drawn from the app's default Xbox layout (844 × 390).

Positioning (November 12, 2026): Thumble is a phone game controller for any
game with controller support. General pages stay game-neutral; World of
Warcraft content lives in the game guides (`/guides`, `/compare`) and in the
clearly labeled WoW sections of `/docs`.

Plans: Weekly $0.99 and Yearly $29.99 with 7-day free trials, Lifetime $49.99;
App Store-only Family plans $1.99 / $49.99 / $89.99. Thumble for Android links to
Google Play (`com.thumble.android`); the iPhone app is marked coming soon and its
CTA leads to the waitlist until the App Store listing is public. `terms.html` and
`privacy.html` still describe the earlier 30-minute demo and $19.99 Pro and need
an owner-reviewed legal update. AI controller generation is disabled.

The Mac DMG is served separately by the `thumble-downloads` Worker at
`/downloads/receiver-latest.dmg`; its source is in the current app repository at
`apps/downloads/`. The old `/api/download-mac` ZIP endpoint and release manifest
are legacy and are not used by the homepage. Do not overwrite the legacy R2
manifest when publishing a receiver.

The homepage hero uses `assets/screenshots/consoleport-circles-78393f9ef12f.png`,
a capture of the ConsolePort variant with circular ability buttons from
`docs/designs/consoleport-phone/reviews/pixel-circles-applied.png`. Its filename
includes a content hash for immutable asset caching. Existing Warrior ability and ConsolePort target-selection
icons fill the remaining ability slots through HTML/CSS overlays; the source capture
stays intact. View, Menu, L3, R3, and the movement/camera sticks remain labeled. The historic blog
and its images are retained as dated development records.

Source: `apps/website` in the current Thumble repository.
Preview: `npm run website:dev` from the repository root.
Build: `npm run website:build`; deploy: `npm run website:deploy`.
Deploy only the staged `dist/website` artifact, not the source directory.
The existing D1 waitlist and R2 bindings are defined in wrangler.toml. Preserve
those bindings and the project's existing encrypted secrets. Signup forms retain
the existing consent, honeypot and optional Turnstile integration.

The down button uses Sunder Armor (`ability_warrior_sunder`) in place of the
food icon in the source capture. Icon source:
https://wow.zamimg.com/images/wow/icons/large/ability_warrior_sunder.jpg

The waitlist Open Graph and Twitter card use `assets/og/waitlist-v7.png`
(1200 × 630), rendered from `tools/website/artwork/waitlist-og.html` in the repository.
It reuses the homepage Warrior ConsolePort artwork, including Sunder Armor.
Rebuild with `node tools/website/artwork/render-waitlist-og.cjs` from the repository root.

The waitlist page itself reuses the homepage ConsolePort Warrior preview markup
and ability overlays, including Sunder Armor.

The setup guide includes a dedicated #thumble-addon section explaining CurseForge installation, exact client selection, enabling both addons, updates, /thumble discovery, and the initial Classic Era 1.15.9 release scope. CurseForge approval and the public 0.1.2 release were verified on October 25, 2026. Direct install link: https://www.curseforge.com/wow/addons/thumble (Classic Era 1.15.9).

## Agent discovery and Markdown

Public HTML pages negotiate Markdown with `Accept: text/markdown` through
`functions/_middleware.js`. Both representations declare `Vary: Accept` and
use `Cache-Control: no-store` to avoid shared-cache representation collisions.
Missing Markdown pages retain HTTP 404 and link to recovery resources.
After changing public page copy, run `node apps/website/build-markdown.mjs apps/website`
to refresh the source Markdown map. The standard build also regenerates it in the deployment artifact.

`/developers` documents the supported read-only hosted integration. `/openapi.json`
covers public configuration and authenticated account reads; `/llms.txt`,
`/.well-known/mcp.json`, `/.well-known/mcp/server-card.json` and the API catalog
link to the existing OAuth-protected MCP endpoint. These documents do not enable
generation or expose account data. Root OAuth discovery redirects are maintained
in the current app repository at `apps/cloud/src/worker.js`.

## Developer CLI distribution

The hosted CLI source is maintained in the current app repository at `packages/cli/src/thumble.mjs`. The website build verifies the script and existing archive against `cli-distribution.json`, then stages them under `/cli/`. See `tools/website/README.md` for the cache and offline archive input. Update the manifest deliberately when publishing a new CLI version; do not commit generated `.tgz` archives.

`/v1/sandbox` is implemented by the cloud Worker, not Pages. It returns synthetic, read-only records without database access. `/api-policy` documents stable read API lifecycle commitments. OpenAPI response schemas are inlined for clients that do not resolve component references; Controller matches `packages/controller/src/profile-schema.js` and must be refreshed when that contract changes.

## Search guides

`/guides` is the evergreen controller guide hub. Its first cluster covers WoW
controller options on Mac, ConsolePort setup and the Thumble companion addon.
Keep `/docs` as the canonical Thumble installation path and link detailed guides
from the relevant setup sections. Phone download CTAs remain launch updates until
public store links exist. The historical blog URLs are retained with current-scope
notes; they are not the current product installation instructions.

Guide forms send distinct bounded `source` identifiers through the existing
waitlist API. The handler records bounded first/latest signup attribution as described below;
Search Console baseline records are maintained under `docs/research`.

The Markdown generator traverses the public `blog`, `guides` and `compare`
content directories as well as root pages. It preserves page-relative anchors
and converts HTML tables to Markdown tables. Do not place private content in
these public directories. Run from the repository root:

```sh
node apps/website/build-markdown.mjs apps/website
npm run website:test
```

The checks cover nested discovery, duplicate routes, guide metadata and links,
Markdown content negotiation, HEAD handling and missing-page responses. They do
not certify live-game compatibility, external search rankings or email delivery.

## Signup attribution and database migration

Apply `migrations/0001_waitlist_attribution.sql` to the existing waitlist D1
database before deploying the attribution-aware signup handler. It creates one
new table without rewriting existing subscriber records. Fresh installations can
apply schema.sql, which includes the table. The handler uses one D1 batch for
subscriber and attribution writes; a failed batch must not report success.

`attribution.mjs` shares the allowlists between the browser and handler. A
sessionStorage record retains the first approved landing in this tab; the latest
approved page is updated during navigation. Only approved paths and recognized
utm_source, utm_medium and utm_campaign values are retained. No visitor ID, email,
full referrer or arbitrary query string is stored in the browser record. It is
sent with a consented signup. Storage denial falls back to the current page.

The database retains the first tracked signup source and first observed landing
submitted at that signup. Repeat submissions update only latest attribution;
unknown historical acquisition cannot be backfilled. A native form without JS
continues to work and records unknown landing data. This does not provide
individual organic search queries or cross-device visitor tracking.

Scripts that load script.js use type=module because it imports attribution.mjs.
When deploying, exclude migrations/ and reports/ from the public assets. Existing
privacy, consent, Turnstile and honeypot behavior remain in place.

Run both suites (Node.js 22.13+ with node:sqlite support, or Node 24+):

```sh
npm run website:test
```

For aggregate reporting, run reports/attribution.sql against D1 using an
authorized read. Counts are distinct tracked subscribers, not installations.

The decision-stage articles are `/guides/iphone-controller-mac` and
`/compare/wow-phone-vs-gamepad`. They use the same article template and appear in
`/guides`; no separate comparison index is needed for one comparison. Keep them
linked from the category/ConsolePort pages and maintain their attribution paths.
The comparison describes documented methods, not benchmark results or an
independent review. Update coming-soon copy only when phone releases are public.

Control troubleshooting now has dedicated binding/modifier and reversed-camera
guides. They distinguish game-side ConsolePort behavior from phone touch-input
calibration, and action correctness from stale display labels. Do not describe
source-only settings screens as universally shipped: names and sync features
remain conditional on the installed build. Keep related links from /docs,
/support and the detection/ConsolePort guides.

## Lighthouse optimization

The October 26 performance pass adds responsive content-hashed WebP variants of the controller screenshot, compressed ability artwork and a small header app icon. Original PNG assets remain available. Each HTML page embeds minified CSS at the stylesheet's original cascade position using `data-inline-css` markers.

After editing a stylesheet, refresh the embedded copies before deploying:

```
npm run website:optimize
```

Dependencies and usage are documented in `tools/website/README.md`. Lighthouse baseline and final reports are in `docs/evidence/lighthouse-2026-10-26`. Assemble deployments with the existing published `/cli` downloads preserved.

## Repository migration

The website was imported with all 14 guides/comparisons, public discovery documents, original and optimized artwork, Functions, attribution schema and migration, and reporting queries. Existing Cloudflare project identity, bindings and encrypted secrets are reused. The legacy checkout remains a historical copy and is not a build dependency.

Source/test paths are now repository-relative. The CI workflow `.github/workflows/website.yml` runs website tests and builds on relevant pull requests and pushes to main. Relevant pushes to `main` now run tests, build, deploy, and verify production through GitHub Actions. Pull requests only run checks. The dedicated `CLOUDFLARE_PAGES_API_TOKEN` repository secret and `CLOUDFLARE_ACCOUNT_ID` repository variable authorize CI deployment. `npm run website:deploy` remains available for an explicit local deployment.
