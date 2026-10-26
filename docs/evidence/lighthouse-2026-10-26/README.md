# Thumble Lighthouse audit — October 26, 2026

Published to https://thumble.io using Cloudflare Pages deployment https://5ff8709f.pocketpad-site.pages.dev.

All 24 sitemap pages scored **100 performance, 100 accessibility, 100 best practices and 100 SEO** with Lighthouse's standard mobile configuration. The homepage also scored all 100s with the desktop preset. Lighthouse version: 13.5.0. Each performance run used simulated mobile throttling and a cold browser cache; no audit categories, analytics requests or failures were suppressed. Scores can vary with network and server conditions.

| Homepage | Performance | Accessibility | Best practices | SEO |
|---|---:|---:|---:|---:|
| Mobile before | 82 | 100 | 100 | 100 |
| Mobile after | 100 | 100 | 100 | 100 |
| Desktop before | 97 | 100 | 100 | 100 |
| Desktop after | 100 | 100 | 100 | 100 |

| Mobile metric | Before | After |
|---|---:|---:|
| First Contentful Paint | 1.9 s | 0.9 s |
| Largest Contentful Paint | 4.4 s | 1.1 s |
| Speed Index | 3.7 s | 1.0 s |
| Total Blocking Time | 0 ms | 0 ms |
| Cumulative Layout Shift | 0 | 0 |

## Changes

- Replaced the 497 KB controller PNG with content-hashed responsive WebP variants (8–36 KB), keeping the original asset.
- Converted decorative ability artwork to WebP and replaced the 552 KB header app-icon download with a small 96-pixel WebP.
- Embedded minified CSS in its original cascade position to remove render-blocking stylesheet requests.
- Removed unused homepage and waitlist selectors while retaining selectors for dynamic FAQ and form states. Deferred the configuration script.
- Saved the changes to the existing source at /Users/codybontecou/dev/Thumble-legacy/Website. Reproducible optimization tooling and dependency lockfile are in /Users/codybontecou/dev/Thumble/tools/website. Rerun the optimizer after CSS changes.

## Verification

- All 24 sitemap URLs returned HTTP 200, correct canonicals and indexable responses.
- Every landing-page element retained identical computed styles and geometry at widths 390 and 1440, both initially and with open FAQs, form errors and disabled submit buttons. See css-layout-checks.json.
- Existing SEO and attribution test suites: 8 passed, 0 failed. No real signup was submitted.
- Published CLI downloads retained identical bytes. Markdown content negotiation still returned text/markdown.
- Visible copy and form attributes were unchanged across all 27 HTML files.
- Production homepage and waitlist CSS matched the tested local CSS exactly.

## Reports

- [Final mobile homepage](final-mobile-home.report.html)
- [Final desktop homepage](final-desktop-home.report.html)
- [Final mobile waitlist](final-mobile-waitlist.report.html)
- [Baseline mobile homepage](baseline-mobile.report.html)
- [Baseline desktop homepage](baseline-desktop.report.html)
- [All mobile page results](final-mobile-pages-summary.json)

| Page | Performance | Accessibility | Best practices | SEO |
|---|---:|---:|---:|---:|
| /blog/connect-chatgpt-claude | 100 | 100 | 100 | 100 |
| /blog/development-update-october-2026 | 100 | 100 | 100 | 100 |
| /blog | 100 | 100 | 100 | 100 |
| /docs | 100 | 100 | 100 | 100 |
| / | 100 | 100 | 100 | 100 |
| /privacy | 100 | 100 | 100 | 100 |
| /waitlist | 100 | 100 | 100 | 100 |
| /support | 100 | 100 | 100 | 100 |
| /terms | 100 | 100 | 100 | 100 |
| /about | 100 | 100 | 100 | 100 |
| /developers | 100 | 100 | 100 | 100 |
| /api-policy | 100 | 100 | 100 | 100 |
| /guides | 100 | 100 | 100 | 100 |
| /guides/wow-controller-mac | 100 | 100 | 100 | 100 |
| /guides/consoleport-mac-setup | 100 | 100 | 100 | 100 |
| /guides/install-thumble-wow-addon | 100 | 100 | 100 | 100 |
| /guides/wow-controller-not-detected-mac | 100 | 100 | 100 | 100 |
| /guides/thumble-phone-mac-pairing | 100 | 100 | 100 | 100 |
| /guides/iphone-controller-mac | 100 | 100 | 100 | 100 |
| /compare/wow-phone-vs-gamepad | 100 | 100 | 100 | 100 |
| /guides/consoleport-wrong-action-modifier | 100 | 100 | 100 | 100 |
| /guides/wow-controller-camera-reversed-mac | 100 | 100 | 100 | 100 |
| /guides/consoleport-spell-labels-not-syncing | 100 | 100 | 100 | 100 |
| /guides/wow-classic-controller-mac | 100 | 100 | 100 | 100 |
