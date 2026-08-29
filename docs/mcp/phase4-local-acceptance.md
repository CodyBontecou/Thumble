# Phase 4 hosted-builder acceptance receipt

This is a local acceptance receipt, not a production deployment or ChatGPT
connector receipt. Hosted-builder connector, share, and tool statuses are
`partial`: locally implemented and verified, but unavailable until the separate
production and OpenAI client gates are completed.

## Local gate

Run from the repository root with Rust 1.88.0 and no production environment
variables:

```bash
bash -n scripts/verify-hosted-builder-local.sh
./scripts/verify-hosted-builder-local.sh
```

The script is constrained to a random loopback port, a fresh temporary SQLite
database, a temporary backup directory, and a local-only signing secret. It
runs the pinned Rust/verifier gates, the real HTTP + rmcp builder e2e, starts
the start/backup existing/new/failure shell harness, and the real HTTP + rmcp
builder path. A test-only Rust example seeds a principal, generation-advanced
workspace, atomic artifact/share, and emission tombstone through the real
`Store` + `BuilderSession` APIs. The script starts the real gateway with the
same explicit local HMAC secret, fetches that exact share, performs and
checksums a live SQLite backup, restores to a separate database, starts the
real gateway on the restore, fetches identical bytes, and verifies terminal
emission/tombstone replay through the helper/store. CI additionally builds the
exact Dockerfile used by `fly.toml` before running the focused gate.

Local result: **passed on 2026-08-29** with `bash -n`,
`./scripts/verify-hosted-builder-local.sh --focused`, and the complete
`./scripts/verify-hosted-builder-local.sh` workspace gate.

## Local production-restore rehearsal runbook

This is an operator rehearsal for a copy of production-shaped data. It is not
evidence of an offsite backup or a production restore.

1. Record the source deployment's existing `THUMBLE_GATEWAY_TOKEN_SECRET`
   without printing it to logs. Artifact IDs/share tokens are deterministically
   HMAC-derived; restoring with a new secret makes terminal replay credentials
   unusable. Do not rotate this secret during an ordinary restore.
2. On an isolated local machine, set source, checksum, restore, and secret
   paths explicitly. Never overwrite the live database:

   ```bash
   archive=/secure/operator-copy/thumble-gateway-YYYYMMDDTHHMMSSZ.db.gz
   checksum="$archive.sha256"
   restored="$TMPDIR/thumble-gateway-production-rehearsal.db"
   secret_file=/secure/operator-copy/token-secret
   (cd "$(dirname "$archive")" && sha256sum -c "$(basename "$checksum")")
   test ! -e "$restored"
   gzip -dc "$archive" >"$restored"
   test "$(sqlite3 "$restored" 'PRAGMA integrity_check;')" = ok
   test -z "$(sqlite3 "$restored" 'PRAGMA foreign_key_check;')"
   ```

3. Start the reviewed gateway binary only on loopback and only against the
   separate restore, preserving the exact HMAC secret:

   ```bash
   THUMBLE_GATEWAY_BIND=127.0.0.1:18080 \
   THUMBLE_GATEWAY_BASE_URL=http://127.0.0.1:18080 \
   THUMBLE_GATEWAY_DB="$restored" \
   THUMBLE_GATEWAY_TOKEN_SECRET="$(cat "$secret_file")" \
     Host/target/debug/thumble-gateway
   curl -fsS http://127.0.0.1:18080/healthz
   ```

4. Validate only operator-approved, non-production test credentials/rows;
   stop the loopback process and remove the rehearsal database according to
   the operator's retention policy. Do not paste share tokens into terminals,
   tickets, CI output, or logs.

A real production restore still requires explicit approval, a reviewed source
archive/checksum and image provenance, a maintenance/rollback plan, and an
independent post-restore receipt. These local steps do not prove upload,
offsite retention, production recovery, or client acceptance.

## Residual production and client gates (not executed)

> **BLOCKED — Do not run `flyctl deploy` or promote any hosted-builder
> capability to `current` without explicit production-owner/user approval to
> modify the live `thumble-mcp-gateway` service. No such approval has been
> granted. Approval must identify the reviewed commit/image, confirm a verified
> pre-deploy database backup and checksum, preserve the existing
> `thumble_gateway_data` volume and exact `THUMBLE_GATEWAY_TOKEN_SECRET`, and
> name the rollback release.**

Before any availability status changes, review the exact diff and committed
provenance, preserve the existing production token secret and volume, then run:

```bash
flyctl auth whoami
flyctl deploy --app thumble-mcp-gateway --config fly.toml
curl -fsS -D - https://thumble-mcp-gateway.fly.dev/healthz
flyctl status --app thumble-mcp-gateway
flyctl releases --app thumble-mcp-gateway --image
flyctl volumes list --app thumble-mcp-gateway
```

Those commands are recorded for the production operator only and were **not
executed by this local stage**. After deployment, complete a separate ChatGPT
developer-mode connector acceptance covering builder OAuth, all nine tools,
share retrieval, artifact import, and explicit human approval. Do not promote
`docs/mcp/hosted-builder-capabilities-v1.json` entries until both receipts are
reviewed.
