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

## Remaining gate

Visible ChatGPT developer-mode builder acceptance (fresh conversation:
OAuth consent → all nine tools → artifact emission → share retrieval →
artifact import), recorded `openai-client-acceptance.md` style. Until that
receipt exists, every hosted-builder capability stays `partial` and no ledger
entry is promoted to `current`. Physical-device iPhone pickup/adoption
receipts (Phase 5) also remain open.
