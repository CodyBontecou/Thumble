# Recommended for App follow-up

Target: https://thumble.io. Implemented October 24, 2026 (America/Puerto_Rico).

The original recommendation pool earned 15.1/20. After the first pass, a homepage scan earned 17.5/20. After correcting consistent error-schema references, a forced live scan earned **18.1/20** with all eight operations passing typed-schema compatibility and the error model passing. Original root scans reused cached Ora evidence, so verification used an inert readiness query on the identical live homepage. Canonical website URLs remain unchanged. The final verification uses Ora’s documented force option to bypass its six-hour freshness cache.

Changes:
- Native REST rate-limit binding: 600 requests/60 seconds per credential or anonymous source IP, per Cloudflare location. Real policy headers, JSON 429, conservative Retry-After. No fabricated remaining balance on successful requests.
- Free, synthetic, read-only GET /v1/sandbox with no account or database access. Writes return 405. Real account routes still require OAuth.
- Official read-only CLI in packages/cli. Website script and installable npm-compatible package are live. Registry publication pending npm sign-in (whoami returned 401); no registry publication is claimed.
- All eight OpenAPI operations have explicit, typed success schemas. Full controller schema is published, errors consistently reference Error, and delivery state uses the implemented failed value.
- /api-policy and developer docs specify stable /v1 lifecycle and at least 90 days notice before removal of a documented operation.
- Owner-supplied public business address and support email in Organization metadata and About page.
- Clearer product title and developer links for future indexing. Search ranking changes are external and not immediate.

Validation: 234 tests pass, including CLI execution through npm-style symlinks, missing credentials, safe request targets, redacted errors, quota decisions and sandbox isolation. All OpenAPI success and error schemas compile; representative read payloads validate. Pages Functions compile; Worker deployment dry-run confirms the native quota binding. CLI archive installs and runs, and its live downloaded bytes match the tested package. Live sandbox succeeds, POST returns 405, account reads remain 401 and config exposes quota headers.

Cloud deployment: ec819c4f-43dd-4148-a3fd-9f9eb2c6df32.
Final Pages deployment: https://a6dd46bf.pocketpad-site.pages.dev.

The canonical Is Agentic report now confirms **18.1/20**, **17/19 Recommended for App checks passed**, and **100/100 overall**, snapshot 2026-10-25 01:37 UTC. See `final-report.json` and `app-score.png`.

Remaining external limits: search indexing/ranking; public scanner cannot inspect OAuth-protected MCP tools. Authentication remains enabled. CLI registry publication needs publisher authentication.
