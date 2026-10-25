# Thumble agent readiness

Verified October 24, 2026 (America/Puerto_Rico).

Target: https://thumble.io
Report: https://is-agentic.com/scan/thumble.io

Initial stored score: **62/100**, snapshot 2026-10-25T01:14:07.030Z UTC.
After deployment, the live rescan displayed **100/100** with all **10/10 Essential** checks passing, Recommended 15.1/20 and bonus 4.7 points. Screenshot: `score-100.png`.

## Changes

Website source: `/Users/codybontecou/dev/Thumble/Website`.

- Negotiated Markdown for public HTML pages; Vary: Accept and no-store prevent mixed representations in shared caches.
- Useful Markdown 404 with correct HTTP status and recovery links.
- Typed OpenAPI 3.1 contract for public configuration and supported authenticated account reads.
- Developer documentation, agent guidance, MCP discovery documents and API catalog.
- Factual product/organization JSON-LD and About page; no invented postal address.
- Existing issuer metadata is discoverable through root OAuth/OIDC redirects in `apps/cloud/src/worker.js`.

AI generation remains disabled. Account reads and MCP remain authenticated.

## Validation

- Existing cloud test suite: 63 passed.
- New OAuth discovery regression: GET/HEAD destinations and POST rejection passed.
- Markdown preference, GET/HEAD, HTML, Markdown 404, and unchanged POST handling passed.
- Pages Functions compiled successfully.
- Live homepage HTML/Markdown, missing-page Markdown 404, API config, OpenAPI, MCP server card and OAuth discovery verified.
- New developer page verified in browser.

Cloud version: `33202b4e-43ab-4dbf-bec4-cdf003b7a124`.
Final Pages deployment: https://ea82a9c3.pocketpad-site.pages.dev

The confirmation scan completed and the canonical report now displays **100/100** with a saved snapshot at 2026-10-25 01:18 UTC. The public JSON report also confirms 100/100; retained in `final-report.json`.
