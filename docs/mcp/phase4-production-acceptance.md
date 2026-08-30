# Phase 4 production acceptance — deployment receipt

Status: **production deployed and smoke-verified 2026-08-29; visible ChatGPT developer-mode acceptance remains the final gate before any capability promotion.**

Owner approval: the repository owner explicitly approved push + deploy of this work
("okay, push and deploy it", 2026-08-29).

## Deployed release

| Item | Value |
|---|---|
| Commits | `2114fb8` (hosted builder phases 0–6 + CSS design API), `c4c5776` (Docker fixtures COPY fix) |
| App | `thumble-mcp-gateway` (fly.io, `iad`, machine `891e16eb0eded8`) |
| Rollback release | `deployment-01M12CVNDBNJWVJ8VR6YH1SNT9` (pre-deploy v16, checks passing) |
| Secrets | `THUMBLE_GATEWAY_BASE_URL`, `THUMBLE_GATEWAY_TOKEN_SECRET` preserved (not rotated; digests verified via `fly secrets list`) |
| Volume | `thumble_gateway_data` preserved at `/data` |

## Pre-deploy backup

- `/data/thumble-gateway-predeploy-2114fb8.db`
- SHA-256 `b5415e52f423f608fd422fd9524eed18c60309b994cb6c590a327bbf4481e46f` (1,044,480 bytes)
- Post-deploy the backup file is intact with the identical checksum; the live DB migrated
  (1,093,632 bytes) with no startup errors.

## Post-deploy receipts (all verified against `https://thumble-mcp-gateway.fly.dev`)

- `GET /healthz` → `200 {"ok":true,...}`; machine checks passing.
- `GET /.well-known/oauth-protected-resource/builder/mcp` → exact resource
  `…/builder/mcp`, scopes `thumble.build`, `offline_access`.
- `GET /.well-known/oauth-authorization-server` → S256, authorization-code +
  refresh grants, DCR `registration_endpoint` advertised.
- `GET /.well-known/apple-app-site-association` → `200 application/json`, exact
  `applinks` document (`/share/*`, app `67KC823C9A.com.codybontecou.PocketPad.iOS`),
  no redirect.
- `POST /builder/mcp` unauthenticated → `401`.
- `GET /share/<well-formed unknown id>` → uniform `404` (no enumeration).
- `GET /authorize` with garbage parameters → `400` (fail-closed).
- Security headers on all sampled routes: HSTS, `nosniff`, `no-store`,
  restrictive CSP.

## OAuth browser compatibility follow-up

The first visible ChatGPT attempt exposed two client-compatibility issues:

1. ChatGPT requested the shared issuer's relay scopes (`thumble.read`, etc.)
   while authorizing the builder resource. Commit `04381eb` filters those
   relay-resource scopes and keeps only builder scopes.
2. The browser consent form POST omitted `Origin`. Commit `98e9387` accepts
   that browser-compatible case when the exact one-time scoped consent cookie
   is present; explicit cross-origin or malformed `Origin` values remain
   rejected, and a missing/wrong cookie still returns `403`.

Release v19 (`98e9387`, image
`deployment-01M171X8K3S535Z1FXKZNAYCVD`) is live and healthy. A production
round trip using a disposable DCR client verified:

- shared relay+builder scope union → consent page shows builder scopes only;
- consent POST with the scoped cookie and no `Origin` → `302` callback;
- authorization-code exchange → `200`, scope set exactly
  `{thumble.build, offline_access}`.

The v19 pre-deploy backup is
`/data/thumble-gateway-predeploy-04381eb.db`, SHA-256
`0f5e08c51bd8937cf91b40a9179b9ecf1bcf2068e0c6043c095e1111b9312aad`, with
`PRAGMA integrity_check` = `ok`.

## v20 cookie-partitioned browser compatibility

The browser could still lack both the consent cookie and `Origin`. Commit
`2929bd4` renders a separate 64-character one-time `browser_proof` in the
consent form. The server verifies that proof against the existing hashed
authorization-request nonce, while preserving cookie support and explicit
cross-origin rejection.

Release v20 (`2929bd4`, image
`deployment-01M1A1DAV0YDC4Q4NF7VM0EESH`) is live and healthy. Its pre-deploy
backup is `/data/thumble-gateway-predeploy-2929bd4.db`, SHA-256
`f2d1d10cb8109b7a0597770f6e67aa8195aa8b7217bf427381e25f5ab77f8241`,
1,101,824 bytes, and `PRAGMA integrity_check` = `ok`.

A production DCR → consent → authorization-code exchange smoke verified the
exact browser case: **no Cookie + no Origin + the hidden one-time proof**
returns `302`, and token exchange returns `200` with only
`offline_access thumble.build`.

## v21 authoritative form-proof compatibility

A further visible attempt showed that the isolated OAuth webview could send an
explicit opaque Origin and a stale partitioned cookie. Commit `0e928dc` makes
the valid one-time form proof authoritative on that path; stale cookies and
unreliable Origin are ignored only when that proof is present. Legacy
cookie-only submissions again require the exact gateway Origin.

An independent read-only OAuth/CSRF review confirmed the form-proof model is
bound to the client, redirect URI, builder resource, PKCE challenge, and
single-use authorization request. The review also identified and caused the
cookie-only missing-Origin gate to be restored before deployment. Gateway
validation passed (118 library + 10 integration tests, fmt, clippy), including:

- `Origin: null` + stale cookie + valid form proof → allowed;
- wrong form proof + valid cookie → `403` without consuming the request;
- cookie-only + missing/cross-site Origin → `403`.

Release v21 (`0e928dc`, image
`deployment-01M1A37Y9B8TPR0M7Y64RB1N9N`) is live and healthy. Its pre-deploy
backup is `/data/thumble-gateway-predeploy-0e928dc.db`, SHA-256
`6d4b5782401164c7d8414270c0ef6e3c09f0777d3c8150c5adc96d35641cdb1f`,
1,110,016 bytes, and `PRAGMA integrity_check` = `ok`; v20/image
`deployment-01M1A1DAV0YDC4Q4NF7VM0EESH` remains the immediate rollback.
A production isolated-webview smoke verified `Origin: null` + stale cookie +
valid proof → `302`, then token exchange → `200` with the builder-only scope
set. Fixed-label rejection telemetry contains no request/proof/token values.

## v22 explicit loopback callback handoff

Visible acceptance then showed consent succeeding while ChatGPT remained
unauthenticated. Production evidence made the boundary exact: three builder
consents had minted three unexchanged authorization codes, all for loopback
callbacks. The OAuth webview was suppressing the cross-origin `302` returned
from the POSTed consent form.

Commit `e80eb3c` reuses the already accepted relay flow's explicit no-script
handoff: builder consent now returns a `200` page with an immediate standards-
based meta refresh and a visible **Return to ChatGPT** link containing the
same validated callback. A second consent/code is never needed.

Release v22 (`e80eb3c`, image
`deployment-01M1A3VMJ5F2H1XWC6AHBCCQAY`) is live and healthy. Its pre-deploy
backup is `/data/thumble-gateway-predeploy-e80eb3c.db`, SHA-256
`043bb4cf30141ec54850d155261be5969d2f1250ddecc256a7a158b06e3883f6`,
1,110,016 bytes, and `PRAGMA integrity_check` = `ok`; v21/image
`deployment-01M1A37Y9B8TPR0M7Y64RB1N9N` remains the immediate rollback.

A production test with a real ephemeral `127.0.0.1` listener verified the
complete ChatGPT-style path: consent confirmation → `200` handoff page → local
loopback callback received with exact state → authorization-code exchange
`200` → builder-only scope set. Callback, code, and token values were redacted.

## Remaining gate

Visible ChatGPT developer-mode builder acceptance (fresh conversation:
OAuth consent → all nine tools → artifact emission → share retrieval →
artifact import), recorded `openai-client-acceptance.md` style. Until that
receipt exists, every hosted-builder capability stays `partial` and no ledger
entry is promoted to `current`. Physical-device iPhone pickup/adoption
receipts (Phase 5) also remain open.
