//! Persistent gateway state (SQLite, single-writer).
//!
//! Every secret is stored as a SHA-256 digest, never in the clear:
//! device tokens, OAuth authorization codes, access tokens, and refresh
//! tokens. Rotation ancestry for refresh tokens enables reuse detection.

use std::path::Path;
use std::sync::Mutex;

use hmac::{Hmac, Mac as _};
use rusqlite::{Connection, Transaction};
use sha2::Sha256;
use thumble_tunnel::token_digest;

use crate::principal::{OAuthBinding, Principal, PrincipalKind, ResourceKind};

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    token_digest TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS builder_principals (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS oauth_clients (
    client_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    redirect_uris TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS authorization_requests (
    request_digest TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    redirect_uri TEXT NOT NULL,
    state TEXT NOT NULL,
    scope TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    used INTEGER NOT NULL DEFAULT 0,
    resource_kind TEXT NOT NULL DEFAULT 'relay',
    consent_nonce_digest TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS auth_codes (
    code_digest TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    redirect_uri TEXT NOT NULL,
    scope TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    device_id TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    used INTEGER NOT NULL DEFAULT 0,
    principal_kind TEXT NOT NULL DEFAULT 'device',
    principal_id TEXT NOT NULL DEFAULT '',
    resource_kind TEXT NOT NULL DEFAULT 'relay'
);
CREATE TABLE IF NOT EXISTS access_tokens (
    token_digest TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    client_id TEXT NOT NULL DEFAULT '',
    scope TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    revoked INTEGER NOT NULL DEFAULT 0,
    family_id TEXT NOT NULL DEFAULT '',
    principal_kind TEXT NOT NULL DEFAULT 'device',
    principal_id TEXT NOT NULL DEFAULT '',
    resource_kind TEXT NOT NULL DEFAULT 'relay'
);
CREATE TABLE IF NOT EXISTS refresh_tokens (
    token_digest TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    client_id TEXT NOT NULL,
    scope TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    rotated_from TEXT,
    revoked INTEGER NOT NULL DEFAULT 0,
    rotated_at INTEGER NOT NULL DEFAULT 0,
    family_id TEXT NOT NULL DEFAULT '',
    principal_kind TEXT NOT NULL DEFAULT 'device',
    principal_id TEXT NOT NULL DEFAULT '',
    resource_kind TEXT NOT NULL DEFAULT 'relay'
);
CREATE TABLE IF NOT EXISTS link_codes (
    code_digest TEXT PRIMARY KEY,
    pending_key TEXT NOT NULL,
    device_name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    used INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS manifests (
    device_id TEXT PRIMARY KEY,
    tools TEXT NOT NULL,
    resources TEXT NOT NULL,
    instructions TEXT,
    updated_at INTEGER NOT NULL
);
"#;

#[derive(Debug)]
pub struct DeviceRecord {
    pub id: String,
    pub name: String,
}

#[derive(Debug)]
pub struct ClientRecord {
    pub client_id: String,
    pub name: String,
    pub redirect_uris: Vec<String>,
}

#[derive(Debug)]
pub struct AuthorizationRequestRecord {
    pub client_id: String,
    pub redirect_uri: String,
    pub state: String,
    pub scope: String,
    pub code_challenge: String,
    pub resource: ResourceKind,
}

#[derive(Debug)]
pub struct AuthCodeRecord {
    pub client_id: String,
    pub redirect_uri: String,
    pub scope: String,
    pub code_challenge: String,
    /// Compatibility projection for relay callers; empty for builders.
    pub device_id: String,
    pub binding: OAuthBinding,
}

#[derive(Debug)]
pub struct AuthorizationTokenGrant {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub scope: String,
    /// Compatibility projection for relay callers; empty for builders.
    pub device_id: String,
    pub binding: OAuthBinding,
}

/// Typed name used by generic principal/resource APIs.
pub type TokenGrant = AuthorizationTokenGrant;

#[derive(Debug)]
pub struct AccessTokenRecord {
    /// Compatibility projection for relay callers; empty for builders.
    pub device_id: String,
    pub scope: String,
    pub binding: OAuthBinding,
}

#[derive(Debug)]
pub struct RefreshTokenRecord {
    /// Compatibility projection for relay callers; empty for builders.
    pub device_id: String,
    pub client_id: String,
    pub scope: String,
    pub binding: OAuthBinding,
}

#[derive(Debug)]
pub struct RefreshTokenGrant {
    pub access_token: String,
    pub refresh_token: String,
    pub scope: String,
    pub binding: OAuthBinding,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ManifestRecord {
    pub tools: Vec<serde_json::Value>,
    pub resources: Vec<serde_json::Value>,
    pub instructions: Option<String>,
}

pub struct Store {
    pub(crate) connection: Mutex<Connection>,
    link_secret: Vec<u8>,
    max_builder_principals: i64,
    max_oauth_clients: i64,
    oauth_client_eviction_watermark: i64,
    refresh_family_limit: i64,
    refresh_principal_client_limit: i64,
    refresh_global_limit: i64,
    /// How long after a rotation the previous refresh token may be exchanged
    /// again by a concurrent legitimate client. Multi-window clients such as
    /// the ChatGPT desktop app share one token cache across chat runtimes;
    /// without this window, two simultaneous refreshes read as token theft
    /// and revoke the whole session family. Replays after the window (or
    /// beyond the successor budget) still revoke everything.
    refresh_grace_seconds: i64,
}

/// Default concurrent-refresh grace window in seconds.
const DEFAULT_REFRESH_GRACE_SECONDS: i64 = 60;
/// Maximum direct successors one rotated refresh token may ever mint inside
/// the grace window (original exchange plus concurrent peers).
const MAXIMUM_GRACE_SUCCESSORS: i64 = 4;
const DEFAULT_MAXIMUM_BUILDER_PRINCIPALS: i64 = 10_000;
const DEFAULT_MAXIMUM_OAUTH_CLIENTS: i64 = 10_000;
const DEFAULT_OAUTH_CLIENT_EVICTION_WATERMARK: i64 = 9_000;
const MAXIMUM_REFRESH_ROWS_PER_FAMILY: i64 = 4_096;
const MAXIMUM_ACTIVE_REFRESH_ROWS_PER_PRINCIPAL_CLIENT: i64 = 8_192;
const MAXIMUM_REFRESH_ROWS_GLOBAL: i64 = 100_000;
const BUILDER_PRINCIPAL_INACTIVE_SECONDS: i64 = 24 * 60 * 60;

fn prune_expired_oauth(connection: &Connection, now: i64) -> Result<(), String> {
    connection
        .execute(
            "DELETE FROM authorization_requests WHERE used = 1 OR expires_at < ?1",
            rusqlite::params![now],
        )
        .map_err(|error| format!("prune authorization requests: {error}"))?;
    connection
        .execute(
            "DELETE FROM auth_codes WHERE used = 1 OR expires_at < ?1",
            rusqlite::params![now],
        )
        .map_err(|error| format!("prune authorization codes: {error}"))?;
    connection
        .execute(
            "DELETE FROM access_tokens WHERE revoked = 1 OR expires_at < ?1",
            rusqlite::params![now],
        )
        .map_err(|error| format!("prune access tokens: {error}"))?;
    connection
        .execute(
            "DELETE FROM refresh_tokens WHERE expires_at < ?1",
            rusqlite::params![now],
        )
        .map_err(|error| format!("prune refresh tokens: {error}"))?;
    connection
        .execute(
            "DELETE FROM oauth_clients \
             WHERE created_at < ?1 \
               AND NOT EXISTS (SELECT 1 FROM authorization_requests r \
                               WHERE r.client_id = oauth_clients.client_id \
                                 AND r.used = 0 AND r.expires_at >= ?2) \
               AND NOT EXISTS (SELECT 1 FROM auth_codes c \
                               WHERE c.client_id = oauth_clients.client_id \
                                 AND c.used = 0 AND c.expires_at >= ?2) \
               AND NOT EXISTS (SELECT 1 FROM access_tokens a \
                               WHERE a.client_id = oauth_clients.client_id \
                                 AND a.revoked = 0 AND a.expires_at >= ?2) \
               AND NOT EXISTS (SELECT 1 FROM refresh_tokens t \
                               WHERE t.client_id = oauth_clients.client_id \
                                 AND t.revoked = 0 AND t.expires_at >= ?2)",
            rusqlite::params![now - 7 * 24 * 60 * 60, now],
        )
        .map_err(|error| format!("prune inactive OAuth clients: {error}"))?;
    Ok(())
}

#[allow(clippy::too_many_arguments)]
fn insert_rotated_pair(
    transaction: &Transaction<'_>,
    record: &RefreshTokenRecord,
    parent_digest: &str,
    family_id: &str,
    access_token: &str,
    refresh_token: &str,
    now: i64,
    ttl_seconds: i64,
) -> Result<(), String> {
    transaction
        .execute(
            "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at, family_id, principal_kind, principal_id, resource_kind) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, 0, ?7, ?8, ?9, ?10)",
            rusqlite::params![
                token_digest(refresh_token),
                compatibility_device_id(&record.binding),
                record.client_id,
                record.scope,
                now + ttl_seconds,
                parent_digest,
                family_id,
                record.binding.principal.kind,
                record.binding.principal.id,
                record.binding.resource,
            ],
        )
        .map_err(|error| format!("insert rotated refresh token: {error}"))?;
    transaction
        .execute(
            "INSERT INTO access_tokens (token_digest, device_id, client_id, scope, expires_at, revoked, family_id, principal_kind, principal_id, resource_kind) \
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8, ?9)",
            rusqlite::params![
                token_digest(access_token),
                compatibility_device_id(&record.binding),
                record.client_id,
                record.scope,
                now + 900,
                family_id,
                record.binding.principal.kind,
                record.binding.principal.id,
                record.binding.resource,
            ],
        )
        .map_err(|error| format!("insert rotated access token: {error}"))?;
    Ok(())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RefreshCapacity {
    Available,
    FamilyRevoked,
    PrincipalClientFull,
    GlobalFull,
}

#[allow(clippy::too_many_arguments)]
fn enforce_refresh_capacity(
    transaction: &Transaction<'_>,
    binding: &OAuthBinding,
    client_id: &str,
    family_id: &str,
    now: i64,
    family_limit: i64,
    principal_client_limit: i64,
    global_limit: i64,
) -> Result<RefreshCapacity, String> {
    // Expired rows are always removed before counting. Revoked, unexpired rows
    // remain globally/family bounded because they are required for reuse
    // detection until their original expiry.
    transaction
        .execute(
            "DELETE FROM refresh_tokens WHERE expires_at < ?1",
            rusqlite::params![now],
        )
        .map_err(|error| format!("prune refresh tokens before admission: {error}"))?;
    let family_count: i64 = transaction
        .query_row(
            "SELECT COUNT(*) FROM refresh_tokens WHERE principal_kind = ?1 \
               AND principal_id = ?2 AND resource_kind = ?3 AND client_id = ?4 \
               AND family_id = ?5",
            rusqlite::params![
                binding.principal.kind,
                binding.principal.id,
                binding.resource,
                client_id,
                family_id
            ],
            |row| row.get(0),
        )
        .map_err(|error| format!("count refresh-token family: {error}"))?;
    if family_count >= family_limit {
        transaction
            .execute(
                "UPDATE access_tokens SET revoked = 1 WHERE principal_kind = ?1 \
                   AND principal_id = ?2 AND resource_kind = ?3 AND client_id = ?4 \
                   AND family_id = ?5",
                rusqlite::params![
                    binding.principal.kind,
                    binding.principal.id,
                    binding.resource,
                    client_id,
                    family_id
                ],
            )
            .map_err(|error| format!("revoke capacity-exhausted access family: {error}"))?;
        transaction
            .execute(
                "UPDATE refresh_tokens SET revoked = 1 WHERE principal_kind = ?1 \
                   AND principal_id = ?2 AND resource_kind = ?3 AND client_id = ?4 \
                   AND family_id = ?5",
                rusqlite::params![
                    binding.principal.kind,
                    binding.principal.id,
                    binding.resource,
                    client_id,
                    family_id
                ],
            )
            .map_err(|error| format!("revoke capacity-exhausted refresh family: {error}"))?;
        return Ok(RefreshCapacity::FamilyRevoked);
    }
    let active_binding_count: i64 = transaction
        .query_row(
            "SELECT COUNT(*) FROM refresh_tokens WHERE principal_kind = ?1 \
               AND principal_id = ?2 AND resource_kind = ?3 AND client_id = ?4 \
               AND revoked = 0 AND expires_at >= ?5",
            rusqlite::params![
                binding.principal.kind,
                binding.principal.id,
                binding.resource,
                client_id,
                now
            ],
            |row| row.get(0),
        )
        .map_err(|error| format!("count active principal refresh tokens: {error}"))?;
    if active_binding_count >= principal_client_limit {
        return Ok(RefreshCapacity::PrincipalClientFull);
    }
    let global_count: i64 = transaction
        .query_row("SELECT COUNT(*) FROM refresh_tokens", [], |row| row.get(0))
        .map_err(|error| format!("count global refresh tokens: {error}"))?;
    if global_count >= global_limit {
        return Ok(RefreshCapacity::GlobalFull);
    }
    Ok(RefreshCapacity::Available)
}

fn refresh_capacity_reason(capacity: RefreshCapacity) -> Option<&'static str> {
    match capacity {
        RefreshCapacity::Available => None,
        RefreshCapacity::FamilyRevoked => {
            Some("refresh token family capacity reached; token family revoked")
        }
        RefreshCapacity::PrincipalClientFull => {
            Some("refresh token capacity reached for this principal and client")
        }
        RefreshCapacity::GlobalFull => Some("global refresh token capacity reached"),
    }
}

pub(crate) fn require_active_principal(
    connection: &Connection,
    principal: &Principal,
) -> Result<(), String> {
    principal.validate()?;
    let (table, noun) = match principal.kind {
        PrincipalKind::Device => ("devices", "device"),
        PrincipalKind::Builder => ("builder_principals", "builder principal"),
    };
    let sql = format!("SELECT revoked FROM {table} WHERE id = ?1");
    match connection.query_row(&sql, rusqlite::params![principal.id], |row| {
        row.get::<_, i64>(0)
    }) {
        Ok(0) => Ok(()),
        Ok(_) => Err(format!("{noun} is revoked")),
        Err(rusqlite::Error::QueryReturnedNoRows) => Err(format!("unknown {noun}")),
        Err(error) => Err(format!("inspect {noun} state: {error}")),
    }
}

pub(crate) fn touch_builder_principal(
    connection: &Connection,
    principal: &Principal,
    now: i64,
) -> Result<(), String> {
    if principal.kind != PrincipalKind::Builder {
        return Ok(());
    }
    let changed = connection
        .execute(
            "UPDATE builder_principals SET last_seen_at = ?2 WHERE id = ?1 AND revoked = 0",
            rusqlite::params![principal.id, now],
        )
        .map_err(|error| format!("touch builder principal: {error}"))?;
    if changed == 1 {
        Ok(())
    } else {
        Err("builder principal is not active".to_owned())
    }
}

fn prepare_builder_principal_insert(
    transaction: &Transaction<'_>,
    now: i64,
    maximum: i64,
) -> Result<(), String> {
    let mut statement = transaction
        .prepare(
            "SELECT p.id FROM builder_principals p
             WHERE (p.revoked != 0 OR p.last_seen_at < ?1)
               AND NOT EXISTS (SELECT 1 FROM access_tokens t
                               WHERE t.principal_kind = 'builder' AND t.principal_id = p.id
                                 AND t.expires_at > ?2)
               AND NOT EXISTS (SELECT 1 FROM refresh_tokens t
                               WHERE t.principal_kind = 'builder' AND t.principal_id = p.id
                                 AND t.expires_at > ?2)
               AND NOT EXISTS (SELECT 1 FROM builder_workspaces w WHERE w.principal_id = p.id)
               AND NOT EXISTS (SELECT 1 FROM builder_artifacts a WHERE a.principal_id = p.id)
               AND NOT EXISTS (SELECT 1 FROM builder_shares s WHERE s.principal_id = p.id)",
        )
        .map_err(|error| format!("prepare builder principal pruning: {error}"))?;
    let principal_ids = statement
        .query_map(
            rusqlite::params![now - BUILDER_PRINCIPAL_INACTIVE_SECONDS, now],
            |row| row.get::<_, String>(0),
        )
        .map_err(|error| format!("query builder principal pruning: {error}"))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| format!("read builder principal pruning: {error}"))?;
    drop(statement);

    for principal_id in principal_ids {
        for table in ["auth_codes", "access_tokens", "refresh_tokens"] {
            transaction
                .execute(
                    &format!(
                        "DELETE FROM {table} WHERE principal_kind = 'builder' AND principal_id = ?1"
                    ),
                    rusqlite::params![principal_id],
                )
                .map_err(|error| format!("prune builder principal {table}: {error}"))?;
        }
        transaction
            .execute(
                "DELETE FROM builder_session_tombstones WHERE principal_id = ?1",
                rusqlite::params![principal_id],
            )
            .map_err(|error| format!("prune builder principal tombstones: {error}"))?;
        transaction
            .execute(
                "DELETE FROM builder_principals WHERE id = ?1",
                rusqlite::params![principal_id],
            )
            .map_err(|error| format!("prune builder principal: {error}"))?;
    }

    let count: i64 = transaction
        .query_row("SELECT COUNT(*) FROM builder_principals", [], |row| {
            row.get(0)
        })
        .map_err(|error| format!("count builder principals: {error}"))?;
    if count >= maximum {
        return Err(format!(
            "builder principal capacity reached (maximum {maximum})"
        ));
    }
    Ok(())
}

fn table_columns(
    transaction: &Transaction<'_>,
    table: &str,
) -> Result<std::collections::HashSet<String>, String> {
    let mut statement = transaction
        .prepare(&format!("PRAGMA table_info({table})"))
        .map_err(|error| format!("inspect {table} schema: {error}"))?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(1))
        .map_err(|error| format!("read {table} schema: {error}"))?
        .collect::<Result<std::collections::HashSet<_>, _>>()
        .map_err(|error| format!("read {table} columns: {error}"))?;
    Ok(names)
}

pub(crate) fn migrate_schema(connection: &mut Connection) -> Result<(), String> {
    migrate_schema_with_hook(connection, |_| Ok(()))
}

fn migrate_schema_with_hook<F>(connection: &mut Connection, hook: F) -> Result<(), String>
where
    F: FnOnce(&Transaction<'_>) -> Result<(), String>,
{
    let transaction = connection
        .transaction()
        .map_err(|error| format!("begin gateway migration: {error}"))?;
    transaction
        .execute_batch(SCHEMA)
        .map_err(|error| format!("initialize gateway database: {error}"))?;
    let additions: &[(&str, &[(&str, &str)])] = &[
        (
            "builder_principals",
            &[("last_seen_at", "INTEGER NOT NULL DEFAULT 0")],
        ),
        (
            "authorization_requests",
            &[
                ("resource_kind", "TEXT NOT NULL DEFAULT 'relay'"),
                ("consent_nonce_digest", "TEXT NOT NULL DEFAULT ''"),
            ],
        ),
        (
            "auth_codes",
            &[
                ("principal_kind", "TEXT NOT NULL DEFAULT 'device'"),
                ("principal_id", "TEXT NOT NULL DEFAULT ''"),
                ("resource_kind", "TEXT NOT NULL DEFAULT 'relay'"),
            ],
        ),
        (
            "access_tokens",
            &[
                ("client_id", "TEXT NOT NULL DEFAULT ''"),
                ("family_id", "TEXT NOT NULL DEFAULT ''"),
                ("principal_kind", "TEXT NOT NULL DEFAULT 'device'"),
                ("principal_id", "TEXT NOT NULL DEFAULT ''"),
                ("resource_kind", "TEXT NOT NULL DEFAULT 'relay'"),
            ],
        ),
        (
            "refresh_tokens",
            &[
                ("rotated_at", "INTEGER NOT NULL DEFAULT 0"),
                ("family_id", "TEXT NOT NULL DEFAULT ''"),
                ("principal_kind", "TEXT NOT NULL DEFAULT 'device'"),
                ("principal_id", "TEXT NOT NULL DEFAULT ''"),
                ("resource_kind", "TEXT NOT NULL DEFAULT 'relay'"),
            ],
        ),
    ];
    for (table, columns) in additions {
        let existing = table_columns(&transaction, table)?;
        for (name, definition) in *columns {
            if !existing.contains(*name) {
                transaction
                    .execute(
                        &format!("ALTER TABLE {table} ADD COLUMN {name} {definition}"),
                        [],
                    )
                    .map_err(|error| format!("add {table}.{name}: {error}"))?;
            }
        }
    }

    transaction
        .execute(
            "UPDATE builder_principals SET last_seen_at = created_at WHERE last_seen_at <= 0",
            [],
        )
        .map_err(|error| format!("backfill builder principal last seen: {error}"))?;

    // This is intentionally recurring. Rows inserted by a rolled-back old
    // binary after the initial migration receive compatibility defaults and
    // are repaired on every newer startup.
    for table in ["auth_codes", "access_tokens", "refresh_tokens"] {
        transaction
            .execute(
                &format!(
                    "UPDATE {table} SET principal_id = device_id \
                     WHERE principal_kind = 'device' AND principal_id = ''"
                ),
                [],
            )
            .map_err(|error| format!("backfill {table} device principal: {error}"))?;
    }
    // Older access rows did not persist the DCR relationship. Recover it when
    // their isolated family has exactly one refresh-token client.
    transaction
        .execute(
            "UPDATE access_tokens SET client_id = ( \
                 SELECT MIN(r.client_id) FROM refresh_tokens r \
                 WHERE r.family_id = access_tokens.family_id \
                   AND r.principal_kind = access_tokens.principal_kind \
                   AND r.principal_id = access_tokens.principal_id \
                   AND r.resource_kind = access_tokens.resource_kind \
                 HAVING COUNT(DISTINCT r.client_id) = 1) \
             WHERE client_id = '' AND family_id != ''",
            [],
        )
        .map_err(|error| format!("backfill access token client: {error}"))?;

    transaction
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS builder_workspaces (
                 principal_id TEXT NOT NULL,
                 session_id TEXT NOT NULL,
                 revision INTEGER NOT NULL CHECK (revision >= 1),
                 storage_generation INTEGER NOT NULL DEFAULT 1 CHECK (storage_generation >= 1),
                 session_json BLOB NOT NULL,
                 byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
                 created_at INTEGER NOT NULL,
                 updated_at INTEGER NOT NULL,
                 expires_at INTEGER NOT NULL,
                 PRIMARY KEY (principal_id, session_id)
             );
             CREATE TABLE IF NOT EXISTS builder_artifacts (
                 principal_id TEXT NOT NULL,
                 artifact_id TEXT NOT NULL PRIMARY KEY,
                 source_session_id TEXT NOT NULL,
                 source_revision INTEGER NOT NULL CHECK (source_revision >= 1),
                 content_hash TEXT NOT NULL,
                 artifact_json BLOB NOT NULL,
                 byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
                 created_at INTEGER NOT NULL,
                 expires_at INTEGER NOT NULL,
                 UNIQUE (principal_id, source_session_id, source_revision)
             );
             CREATE TABLE IF NOT EXISTS builder_shares (
                 artifact_id TEXT NOT NULL PRIMARY KEY,
                 principal_id TEXT NOT NULL,
                 token_digest TEXT NOT NULL UNIQUE,
                 created_at INTEGER NOT NULL,
                 expires_at INTEGER NOT NULL,
                 revoked INTEGER NOT NULL DEFAULT 0 CHECK (revoked IN (0, 1))
             );
             CREATE TABLE IF NOT EXISTS builder_session_tombstones (
                 principal_id TEXT NOT NULL,
                 session_id TEXT NOT NULL,
                 kind TEXT NOT NULL CHECK (kind IN ('discarded', 'emitted')),
                 revision INTEGER NOT NULL CHECK (revision >= 1),
                 receipt_json BLOB NOT NULL,
                 expires_at INTEGER NOT NULL,
                 PRIMARY KEY (principal_id, session_id)
             );
             CREATE INDEX IF NOT EXISTS builder_workspaces_principal_expiry_idx
                 ON builder_workspaces(principal_id, expires_at);
             CREATE INDEX IF NOT EXISTS builder_workspaces_expiry_idx
                 ON builder_workspaces(expires_at);
             CREATE INDEX IF NOT EXISTS builder_artifacts_principal_expiry_idx
                 ON builder_artifacts(principal_id, expires_at);
             CREATE INDEX IF NOT EXISTS builder_artifacts_expiry_idx
                 ON builder_artifacts(expires_at);
             CREATE INDEX IF NOT EXISTS builder_shares_principal_expiry_idx
                 ON builder_shares(principal_id, expires_at);
             CREATE INDEX IF NOT EXISTS builder_shares_expiry_idx
                 ON builder_shares(expires_at);
             CREATE INDEX IF NOT EXISTS builder_tombstones_expiry_idx
                 ON builder_session_tombstones(expires_at);
             CREATE INDEX IF NOT EXISTS builder_tombstones_principal_expiry_idx
                 ON builder_session_tombstones(principal_id, expires_at);
             CREATE INDEX IF NOT EXISTS auth_codes_binding_idx
                 ON auth_codes(principal_kind, principal_id, resource_kind, client_id);
             CREATE INDEX IF NOT EXISTS access_tokens_binding_family_idx
                 ON access_tokens(principal_kind, principal_id, resource_kind, family_id);
             CREATE INDEX IF NOT EXISTS access_tokens_client_expiry_idx
                 ON access_tokens(client_id, expires_at, revoked);
             CREATE INDEX IF NOT EXISTS authorization_requests_client_live_idx
                 ON authorization_requests(client_id, expires_at, used);
             CREATE INDEX IF NOT EXISTS auth_codes_client_live_idx
                 ON auth_codes(client_id, expires_at, used);
             CREATE INDEX IF NOT EXISTS refresh_tokens_binding_client_family_idx
                 ON refresh_tokens(principal_kind, principal_id, resource_kind, client_id, family_id);
             CREATE INDEX IF NOT EXISTS refresh_tokens_parent_binding_idx
                 ON refresh_tokens(rotated_from, principal_kind, principal_id, resource_kind, client_id);
             CREATE INDEX IF NOT EXISTS refresh_tokens_expiry_idx
                 ON refresh_tokens(expires_at);
             CREATE INDEX IF NOT EXISTS refresh_tokens_active_binding_idx
                 ON refresh_tokens(principal_kind, principal_id, resource_kind, client_id, revoked, expires_at);",
        )
        .map_err(|error| format!("create OAuth binding indexes: {error}"))?;

    // Existing Stage B databases predate the independent persistence CAS.
    // Backfill every live workspace to generation 1; subsequent successful
    // JSON saves advance this column even when the document revision is a no-op.
    let workspace_columns = table_columns(&transaction, "builder_workspaces")?;
    if !workspace_columns.contains("storage_generation") {
        transaction
            .execute(
                "ALTER TABLE builder_workspaces ADD COLUMN storage_generation \
                 INTEGER NOT NULL DEFAULT 1 CHECK (storage_generation >= 1)",
                [],
            )
            .map_err(|error| format!("add builder_workspaces.storage_generation: {error}"))?;
    }
    transaction
        .execute(
            "UPDATE builder_workspaces SET storage_generation = 1 \
             WHERE storage_generation IS NULL OR storage_generation < 1",
            [],
        )
        .map_err(|error| format!("backfill builder workspace storage generation: {error}"))?;

    // The injected failure point deliberately follows every Phase 4 table,
    // column, backfill, generation, and index change so tests attest that the
    // complete startup migration is one rollback boundary.
    hook(&transaction)?;
    transaction
        .commit()
        .map_err(|error| format!("commit gateway migration: {error}"))
}

fn compatibility_device_id(binding: &OAuthBinding) -> &str {
    if binding.principal.kind == PrincipalKind::Device {
        &binding.principal.id
    } else {
        ""
    }
}

fn binding_from_row(
    row: &rusqlite::Row<'_>,
    device_column: usize,
    kind_column: usize,
    id_column: usize,
    resource_column: usize,
) -> rusqlite::Result<(String, OAuthBinding)> {
    let device_id = row.get::<_, String>(device_column)?;
    let kind = row.get::<_, PrincipalKind>(kind_column)?;
    let id = row.get::<_, String>(id_column)?;
    let resource = row.get::<_, ResourceKind>(resource_column)?;
    let principal = Principal::new(kind, id).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            id_column,
            rusqlite::types::Type::Text,
            error.into(),
        )
    })?;
    let binding = OAuthBinding::new(principal, resource).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            resource_column,
            rusqlite::types::Type::Text,
            error.into(),
        )
    })?;
    if device_id != compatibility_device_id(&binding) {
        return Err(rusqlite::Error::FromSqlConversionFailure(
            device_column,
            rusqlite::types::Type::Text,
            "OAuth compatibility device_id does not match the typed binding"
                .to_owned()
                .into(),
        ));
    }
    Ok((device_id, binding))
}

fn validate_link_secret(secret: &str) -> Result<(), String> {
    if secret.len() < 32 {
        Err("THUMBLE_GATEWAY_TOKEN_SECRET must contain at least 32 characters".to_owned())
    } else {
        Ok(())
    }
}

fn validate_redirect_uri(uri: &str) -> Result<(), String> {
    if uri.len() > 2048 {
        return Err("redirect_uri exceeds 2048 characters".to_owned());
    }
    let parsed = url::Url::parse(uri).map_err(|_| "redirect_uri is not an absolute URI")?;
    if parsed.fragment().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.host_str().is_none()
    {
        return Err("redirect_uri must not contain credentials or a fragment".to_owned());
    }
    match parsed.scheme() {
        "https" => Ok(()),
        "http" if matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "::1")) => Ok(()),
        _ => Err("redirect_uri must use https (or exact loopback http for development)".to_owned()),
    }
}

impl Store {
    pub fn open(path: &Path, link_secret: &str) -> Result<Self, String> {
        validate_link_secret(link_secret)?;
        let connection = Connection::open(path)
            .map_err(|error| format!("open gateway database {}: {error}", path.display()))?;
        Self::with_connection(connection, link_secret)
    }

    pub fn open_in_memory() -> Result<Self, String> {
        let connection =
            Connection::open_in_memory().map_err(|e| format!("open memory db: {e}"))?;
        Self::with_connection(connection, "gateway-test-link-secret-32-bytes-minimum")
    }

    fn with_connection(mut connection: Connection, link_secret: &str) -> Result<Self, String> {
        migrate_schema(&mut connection)?;
        Ok(Self {
            connection: Mutex::new(connection),
            link_secret: link_secret.as_bytes().to_vec(),
            max_builder_principals: DEFAULT_MAXIMUM_BUILDER_PRINCIPALS,
            max_oauth_clients: DEFAULT_MAXIMUM_OAUTH_CLIENTS,
            oauth_client_eviction_watermark: DEFAULT_OAUTH_CLIENT_EVICTION_WATERMARK,
            refresh_family_limit: MAXIMUM_REFRESH_ROWS_PER_FAMILY,
            refresh_principal_client_limit: MAXIMUM_ACTIVE_REFRESH_ROWS_PER_PRINCIPAL_CLIENT,
            refresh_global_limit: MAXIMUM_REFRESH_ROWS_GLOBAL,
            refresh_grace_seconds: DEFAULT_REFRESH_GRACE_SECONDS,
        })
    }

    /// Override the concurrent-refresh grace window (0 disables it and keeps
    /// strict replay-revocation semantics).
    pub fn with_refresh_grace(mut self, seconds: i64) -> Self {
        self.refresh_grace_seconds = seconds.clamp(0, 3600);
        self
    }

    /// Test helper for exercising the global builder-principal admission cap
    /// without allocating ten thousand identities.
    #[doc(hidden)]
    pub fn with_builder_principal_limit_for_test(mut self, maximum: i64) -> Self {
        self.max_builder_principals = maximum.max(1);
        self
    }

    #[doc(hidden)]
    pub fn with_oauth_client_limit_for_test(mut self, maximum: i64, watermark: i64) -> Self {
        self.max_oauth_clients = maximum.max(1);
        self.oauth_client_eviction_watermark = watermark.clamp(0, self.max_oauth_clients - 1);
        self
    }

    #[doc(hidden)]
    pub fn with_refresh_limits_for_test(
        mut self,
        family: i64,
        principal_client: i64,
        global: i64,
    ) -> Self {
        self.refresh_family_limit = family.max(1);
        self.refresh_principal_client_limit = principal_client.max(1);
        self.refresh_global_limit = global.max(1);
        self
    }

    fn link_code_digest(&self, code: &str) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.link_secret)
            .expect("HMAC accepts keys of any length");
        mac.update(code.as_bytes());
        mac.finalize()
            .into_bytes()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    pub(crate) fn builder_hmac_digest(&self, domain: &[u8], fields: &[&[u8]]) -> String {
        // Builder credentials currently carry no key identifier and replay
        // derives them from this one gateway secret. A future secret rotation
        // therefore needs an explicit previous-key verification/derivation
        // window; tightening accepted production secrets does not solve that.
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.link_secret)
            .expect("HMAC accepts keys of any length");
        mac.update(domain);
        for field in fields {
            mac.update(&(field.len() as u64).to_be_bytes());
            mac.update(field);
        }
        mac.finalize()
            .into_bytes()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    fn new_token_family_id() -> String {
        token_digest(&thumble_tunnel::random_token(24))
    }

    pub(crate) fn now() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs() as i64)
            .unwrap_or(0)
    }

    pub fn create_device(&self, name: &str) -> Result<(String, String), String> {
        let device_id = format!("dev_{}", thumble_tunnel::random_token(12));
        let token = thumble_tunnel::random_token(32);
        let now = Self::now();
        self.connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO devices (id, token_digest, name, created_at, last_seen_at, revoked) \
                 VALUES (?1, ?2, ?3, ?4, ?4, 0)",
                rusqlite::params![device_id, token_digest(&token), name, now],
            )
            .map_err(|e| format!("create device: {e}"))?;
        Ok((device_id, token))
    }

    pub fn create_builder_principal(&self, name: &str) -> Result<String, String> {
        if name.is_empty() || name.len() > 128 {
            return Err("builder principal name must be 1-128 characters".to_owned());
        }
        let builder_id = format!("bpr_{}", thumble_tunnel::random_token(18));
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin builder principal creation: {error}"))?;
        prepare_builder_principal_insert(&transaction, now, self.max_builder_principals)?;
        transaction
            .execute(
                "INSERT INTO builder_principals (id, name, created_at, last_seen_at, revoked) \
                 VALUES (?1, ?2, ?3, ?3, 0)",
                rusqlite::params![builder_id, name, now],
            )
            .map_err(|error| format!("create builder principal: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit builder principal creation: {error}"))?;
        Ok(builder_id)
    }

    /// Revoke a builder identity and only token families bound to it.
    pub fn revoke_builder_principal(&self, builder_id: &str) -> Result<(), String> {
        let principal = Principal::builder(builder_id.to_owned())?;
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin builder principal revocation: {error}"))?;
        transaction
            .execute(
                "UPDATE builder_principals SET revoked = 1 WHERE id = ?1",
                rusqlite::params![principal.id],
            )
            .map_err(|error| format!("revoke builder principal: {error}"))?;
        for table in ["access_tokens", "refresh_tokens"] {
            transaction
                .execute(
                    &format!(
                        "UPDATE {table} SET revoked = 1 \
                         WHERE principal_kind = ?1 AND principal_id = ?2 AND resource_kind = ?3"
                    ),
                    rusqlite::params![PrincipalKind::Builder, principal.id, ResourceKind::Builder],
                )
                .map_err(|error| format!("revoke builder {table}: {error}"))?;
        }
        transaction
            .execute(
                "UPDATE builder_shares SET revoked = 1 WHERE principal_id = ?1",
                rusqlite::params![principal.id],
            )
            .map_err(|error| format!("revoke builder shares: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit builder principal revocation: {error}"))
    }

    /// Look up a device by bearer token. Returns None for unknown or revoked.
    pub fn device_for_token(&self, token: &str) -> Result<Option<DeviceRecord>, String> {
        let digest = token_digest(token);
        self.connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT id, name FROM devices WHERE token_digest = ?1 AND revoked = 0",
                rusqlite::params![digest],
                |row| {
                    Ok(DeviceRecord {
                        id: row.get(0)?,
                        name: row.get(1)?,
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("lookup device: {other}")),
            })
    }

    /// Look up an active device by id (name and liveness bookkeeping).
    pub fn device(&self, device_id: &str) -> Result<Option<DeviceRecord>, String> {
        self.connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT id, name FROM devices WHERE id = ?1 AND revoked = 0",
                rusqlite::params![device_id],
                |row| {
                    Ok(DeviceRecord {
                        id: row.get(0)?,
                        name: row.get(1)?,
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("lookup device by id: {other}")),
            })
    }

    pub fn touch_device(&self, device_id: &str) -> Result<(), String> {
        self.connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE devices SET last_seen_at = ?2 WHERE id = ?1",
                rusqlite::params![device_id, Self::now()],
            )
            .map_err(|e| format!("touch device: {e}"))?;
        Ok(())
    }

    /// Replace the credential of an existing (non-revoked) device in place.
    ///
    /// Rotation keeps the same device identity and OAuth bindings while the
    /// old bearer token stops working the moment the digest row is replaced.
    /// There is never a window in which both the old and the new token are
    /// valid, and a failed rotation leaves the previous token untouched.
    pub fn rotate_device_token(&self, device_id: &str, name: &str) -> Result<String, String> {
        let token = thumble_tunnel::random_token(32);
        let updated = self
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE devices SET token_digest = ?2, name = ?3, last_seen_at = ?4 \
                 WHERE id = ?1 AND revoked = 0",
                rusqlite::params![device_id, token_digest(&token), name, Self::now()],
            )
            .map_err(|e| format!("rotate device token: {e}"))?;
        if updated != 1 {
            return Err("device is revoked or unknown; link it again".to_owned());
        }
        Ok(token)
    }

    /// Revoke a device and every token family bound to it.
    pub fn revoke_device(&self, device_id: &str) -> Result<(), String> {
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin device revocation: {error}"))?;
        transaction
            .execute(
                "UPDATE devices SET revoked = 1 WHERE id = ?1",
                rusqlite::params![device_id],
            )
            .map_err(|e| format!("revoke device: {e}"))?;
        transaction
            .execute(
                "UPDATE access_tokens SET revoked = 1 \
                 WHERE principal_kind = 'device' AND principal_id = ?1 AND resource_kind = 'relay'",
                rusqlite::params![device_id],
            )
            .map_err(|e| format!("revoke device access tokens: {e}"))?;
        transaction
            .execute(
                "UPDATE refresh_tokens SET revoked = 1 \
                 WHERE principal_kind = 'device' AND principal_id = ?1 AND resource_kind = 'relay'",
                rusqlite::params![device_id],
            )
            .map_err(|e| format!("revoke device refresh tokens: {e}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit device revocation: {error}"))?;
        Ok(())
    }

    pub fn register_client(
        &self,
        name: &str,
        redirect_uris: Vec<String>,
    ) -> Result<String, String> {
        if name.is_empty() || name.len() > 128 {
            return Err("client_name must be 1-128 characters".to_owned());
        }
        if redirect_uris.is_empty() || redirect_uris.len() > 8 {
            return Err("redirect_uris must contain 1-8 exact URIs".to_owned());
        }
        let mut unique = std::collections::HashSet::new();
        for uri in &redirect_uris {
            if !unique.insert(uri) {
                return Err("redirect_uris must not contain duplicates".to_owned());
            }
            validate_redirect_uri(uri)?;
        }
        let client_id = format!("cc_{}", thumble_tunnel::random_token(16));
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin dynamic client registration: {error}"))?;
        prune_expired_oauth(&transaction, now)?;
        let mut client_count: i64 = transaction
            .query_row("SELECT COUNT(*) FROM oauth_clients", [], |row| row.get(0))
            .map_err(|error| format!("count OAuth clients: {error}"))?;
        let eviction_trigger = self.max_oauth_clients - (self.max_oauth_clients / 20).max(1);
        if client_count >= eviction_trigger {
            let removal_target = (client_count - self.oauth_client_eviction_watermark).max(0);
            if removal_target > 0 {
                transaction
                    .execute(
                        "DELETE FROM oauth_clients WHERE client_id IN ( \
                           SELECT c.client_id FROM oauth_clients c \
                           WHERE NOT EXISTS (SELECT 1 FROM authorization_requests r \
                                             WHERE r.client_id = c.client_id AND r.used = 0 AND r.expires_at >= ?1) \
                             AND NOT EXISTS (SELECT 1 FROM auth_codes a \
                                             WHERE a.client_id = c.client_id AND a.used = 0 AND a.expires_at >= ?1) \
                             AND NOT EXISTS (SELECT 1 FROM access_tokens a \
                                             WHERE a.client_id = c.client_id AND a.revoked = 0 AND a.expires_at >= ?1) \
                             AND NOT EXISTS (SELECT 1 FROM refresh_tokens r \
                                             WHERE r.client_id = c.client_id AND r.revoked = 0 AND r.expires_at >= ?1) \
                           ORDER BY c.created_at ASC, c.client_id ASC LIMIT ?2)",
                        rusqlite::params![now, removal_target],
                    )
                    .map_err(|error| format!("evict unreferenced OAuth clients: {error}"))?;
                client_count = transaction
                    .query_row("SELECT COUNT(*) FROM oauth_clients", [], |row| row.get(0))
                    .map_err(|error| format!("recount OAuth clients: {error}"))?;
            }
        }
        if client_count >= self.max_oauth_clients {
            return Err("dynamic client registration capacity reached".to_owned());
        }
        transaction
            .execute(
                "INSERT INTO oauth_clients (client_id, name, redirect_uris, created_at) \
                 VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![
                    client_id,
                    name,
                    serde_json::to_string(&redirect_uris).unwrap(),
                    now
                ],
            )
            .map_err(|e| format!("register client: {e}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit dynamic client registration: {error}"))?;
        Ok(client_id)
    }

    pub fn client(&self, client_id: &str) -> Result<Option<ClientRecord>, String> {
        self.connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT client_id, name, redirect_uris FROM oauth_clients WHERE client_id = ?1",
                rusqlite::params![client_id],
                |row| {
                    Ok(ClientRecord {
                        client_id: row.get(0)?,
                        name: row.get(1)?,
                        redirect_uris: serde_json::from_str(&row.get::<_, String>(2)?)
                            .unwrap_or_default(),
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("lookup client: {other}")),
            })
    }

    pub fn create_link_code(
        &self,
        pending_key: &str,
        device_name: &str,
        ttl_seconds: i64,
        max_existing: usize,
    ) -> Result<String, String> {
        let connection = self.connection.lock().unwrap();
        let now = Self::now();
        connection
            .execute(
                "DELETE FROM link_codes WHERE expires_at < ?1 OR used = 1",
                rusqlite::params![now],
            )
            .map_err(|e| format!("prune link codes: {e}"))?;
        let live: i64 = connection
            .query_row("SELECT COUNT(*) FROM link_codes", [], |row| row.get(0))
            .map_err(|e| format!("count link codes: {e}"))?;
        if live as usize >= max_existing {
            return Err("too many pending link codes; try again shortly".to_owned());
        }
        let code = thumble_tunnel::random_link_code();
        let code_digest = self.link_code_digest(&code);
        connection
            .execute(
                "INSERT INTO link_codes (code_digest, pending_key, device_name, created_at, expires_at, attempts, used) \
                 VALUES (?1, ?2, ?3, ?4, ?5, 0, 0)",
                rusqlite::params![code_digest, pending_key, device_name, now, now + ttl_seconds],
            )
            .map_err(|e| format!("create link code: {e}"))?;
        Ok(code)
    }

    /// Verify a link code entered by a user. Burns one attempt; on success
    /// marks it used and returns the pending key that identifies the
    /// anonymous device control connection waiting for the grant.
    pub fn consume_link_code(&self, code: &str) -> Result<Result<String, String>, String> {
        let connection = self.connection.lock().unwrap();
        let code_digest = self.link_code_digest(code);
        let row = connection.query_row(
            "SELECT pending_key, expires_at, attempts, used FROM link_codes WHERE code_digest = ?1",
            rusqlite::params![code_digest],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            },
        );
        let (pending_key, expires_at, attempts, used) = match row {
            Ok(value) => value,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown link code".to_owned()));
            }
            Err(other) => return Err(format!("lookup link code: {other}")),
        };
        if used == 1 {
            return Ok(Err("link code already used".to_owned()));
        }
        if Self::now() > expires_at {
            return Ok(Err("link code expired".to_owned()));
        }
        if attempts >= i64::from(thumble_tunnel::LINK_CODE_MAX_ATTEMPTS) {
            return Ok(Err("link code locked after too many attempts".to_owned()));
        }
        connection
            .execute(
                "UPDATE link_codes SET attempts = attempts + 1 WHERE code_digest = ?1",
                rusqlite::params![code_digest],
            )
            .map_err(|e| format!("burn link attempt: {e}"))?;
        connection
            .execute(
                "UPDATE link_codes SET used = 1 WHERE code_digest = ?1",
                rusqlite::params![code_digest],
            )
            .map_err(|e| format!("use link code: {e}"))?;
        Ok(Ok(pending_key))
    }

    pub fn create_authorization_request(
        &self,
        client_id: &str,
        redirect_uri: &str,
        state: &str,
        scope: &str,
        code_challenge: &str,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        self.create_authorization_request_for_resource(
            client_id,
            redirect_uri,
            state,
            scope,
            code_challenge,
            ResourceKind::Relay,
            ttl_seconds,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn create_authorization_request_for_resource(
        &self,
        client_id: &str,
        redirect_uri: &str,
        state: &str,
        scope: &str,
        code_challenge: &str,
        resource: ResourceKind,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        if resource == ResourceKind::Builder {
            return Err("builder authorization requests require a consent nonce".to_owned());
        }
        self.insert_authorization_request(
            client_id,
            redirect_uri,
            state,
            scope,
            code_challenge,
            resource,
            "",
            ttl_seconds,
        )
    }

    /// Create a builder request and its 256-bit browser-only consent nonce.
    /// Only the nonce digest is persisted; the clear nonce must be placed in
    /// the scoped HttpOnly consent cookie by the caller.
    #[allow(clippy::too_many_arguments)]
    pub fn create_builder_authorization_request(
        &self,
        client_id: &str,
        redirect_uri: &str,
        state: &str,
        scope: &str,
        code_challenge: &str,
        ttl_seconds: i64,
    ) -> Result<(String, String), String> {
        let consent_nonce = thumble_tunnel::random_token(32);
        let request_id = self.insert_authorization_request(
            client_id,
            redirect_uri,
            state,
            scope,
            code_challenge,
            ResourceKind::Builder,
            &token_digest(&consent_nonce),
            ttl_seconds,
        )?;
        Ok((request_id, consent_nonce))
    }

    #[allow(clippy::too_many_arguments)]
    fn insert_authorization_request(
        &self,
        client_id: &str,
        redirect_uri: &str,
        state: &str,
        scope: &str,
        code_challenge: &str,
        resource: ResourceKind,
        consent_nonce_digest: &str,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        if state.len() > 2048 {
            return Err("OAuth state exceeds 2048 characters".to_owned());
        }
        let request_id = thumble_tunnel::random_token(24);
        let now = Self::now();
        let connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        let live: i64 = connection
            .query_row("SELECT COUNT(*) FROM authorization_requests", [], |row| {
                row.get(0)
            })
            .map_err(|error| format!("count authorization requests: {error}"))?;
        if live >= 1_000 {
            return Err("authorization request capacity reached; retry later".to_owned());
        }
        connection
            .execute(
                "INSERT INTO authorization_requests (request_digest, client_id, redirect_uri, state, scope, code_challenge, expires_at, attempts, used, resource_kind, consent_nonce_digest) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, 0, ?8, ?9)",
                rusqlite::params![
                    token_digest(&request_id),
                    client_id,
                    redirect_uri,
                    state,
                    scope,
                    code_challenge,
                    now + ttl_seconds,
                    resource,
                    consent_nonce_digest,
                ],
            )
            .map_err(|error| format!("create authorization request: {error}"))?;
        Ok(request_id)
    }

    pub fn authorization_request(
        &self,
        request_id: &str,
    ) -> Result<Result<AuthorizationRequestRecord, String>, String> {
        let record = self.connection.lock().unwrap().query_row(
            "SELECT client_id, redirect_uri, state, scope, code_challenge, resource_kind, expires_at, used \
             FROM authorization_requests WHERE request_digest = ?1",
            rusqlite::params![token_digest(request_id)],
            |row| {
                Ok((
                    AuthorizationRequestRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        state: row.get(2)?,
                        scope: row.get(3)?,
                        code_challenge: row.get(4)?,
                        resource: row.get(5)?,
                    },
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                ))
            },
        );
        match record {
            Ok((_record, _, 1)) => Ok(Err("authorization request already used".to_owned())),
            Ok((_record, expires_at, _)) if Self::now() > expires_at => {
                Ok(Err("authorization request expired".to_owned()))
            }
            Ok((record, _, _)) => Ok(Ok(record)),
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                Ok(Err("unknown authorization request".to_owned()))
            }
            Err(error) => Err(format!("lookup authorization request: {error}")),
        }
    }

    pub fn record_authorization_attempt(&self, request_id: &str) -> Result<(), String> {
        let changed = self
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE authorization_requests SET attempts = attempts + 1 \
                 WHERE request_digest = ?1 AND used = 0 AND expires_at >= ?2 AND attempts < 10",
                rusqlite::params![token_digest(request_id), Self::now()],
            )
            .map_err(|error| format!("record authorization attempt: {error}"))?;
        if changed == 1 {
            Ok(())
        } else {
            Err("authorization request is expired, used, or locked after ten attempts".to_owned())
        }
    }

    pub fn consume_authorization_request(&self, request_id: &str) -> Result<(), String> {
        let changed = self
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE authorization_requests SET used = 1 \
                 WHERE request_digest = ?1 AND used = 0 AND expires_at >= ?2 \
                   AND resource_kind = 'relay'",
                rusqlite::params![token_digest(request_id), Self::now()],
            )
            .map_err(|error| format!("consume authorization request: {error}"))?;
        if changed == 1 {
            Ok(())
        } else {
            Err("authorization request is expired or already used".to_owned())
        }
    }

    /// Atomically claim a live authorization request and its valid fallback
    /// link code. Denial/approval races cannot burn the code without winning
    /// the request, and no code can override a request already consumed by a
    /// pushed decision or timeout.
    pub fn consume_authorization_with_link_code(
        &self,
        request_id: &str,
        code: &str,
    ) -> Result<Result<(AuthorizationRequestRecord, String), String>, String> {
        let request_digest = token_digest(request_id);
        let code_digest = self.link_code_digest(code);
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin authorization/link claim: {error}"))?;

        let authorization = transaction.query_row(
            "SELECT client_id, redirect_uri, state, scope, code_challenge, resource_kind, expires_at, used \
             FROM authorization_requests WHERE request_digest = ?1",
            rusqlite::params![request_digest],
            |row| {
                Ok((
                    AuthorizationRequestRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        state: row.get(2)?,
                        scope: row.get(3)?,
                        code_challenge: row.get(4)?,
                        resource: row.get(5)?,
                    },
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                ))
            },
        );
        let (authorization, authorization_expires, authorization_used) = match authorization {
            Ok(value) => value,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown authorization request".to_owned()))
            }
            Err(error) => return Err(format!("lookup authorization request for link: {error}")),
        };
        if authorization_used == 1 {
            return Ok(Err("authorization request already used".to_owned()));
        }
        if now > authorization_expires {
            return Ok(Err("authorization request expired".to_owned()));
        }
        if authorization.resource != ResourceKind::Relay {
            return Ok(Err(
                "link codes can authorize only the relay resource".to_owned()
            ));
        }

        let link = transaction.query_row(
            "SELECT pending_key, expires_at, attempts, used FROM link_codes WHERE code_digest = ?1",
            rusqlite::params![code_digest],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            },
        );
        let (pending_key, link_expires, link_attempts, link_used) = match link {
            Ok(value) => value,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown link code".to_owned()))
            }
            Err(error) => return Err(format!("lookup link code for authorization: {error}")),
        };
        if link_used == 1 {
            return Ok(Err("link code already used".to_owned()));
        }
        if now > link_expires {
            return Ok(Err("link code expired".to_owned()));
        }
        if link_attempts >= i64::from(thumble_tunnel::LINK_CODE_MAX_ATTEMPTS) {
            return Ok(Err("link code locked after too many attempts".to_owned()));
        }

        transaction
            .execute(
                "UPDATE authorization_requests SET used = 1 WHERE request_digest = ?1",
                rusqlite::params![request_digest],
            )
            .map_err(|error| format!("claim authorization request: {error}"))?;
        transaction
            .execute(
                "UPDATE link_codes SET attempts = attempts + 1, used = 1 WHERE code_digest = ?1",
                rusqlite::params![code_digest],
            )
            .map_err(|error| format!("claim link code: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit authorization/link claim: {error}"))?;
        Ok(Ok((authorization, pending_key)))
    }

    /// Atomically consume a builder authorization request and create its code.
    /// No device row is required or created.
    pub fn complete_builder_authorization(
        &self,
        request_id: &str,
        consent_nonce: &str,
        builder_id: &str,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        let binding = OAuthBinding::builder(builder_id.to_owned())?;
        let code = thumble_tunnel::random_token(24);
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin builder authorization completion: {error}"))?;
        require_active_principal(&transaction, &binding.principal)?;
        let request = transaction
            .query_row(
                "SELECT client_id, redirect_uri, scope, code_challenge, resource_kind, expires_at, used, consent_nonce_digest \
                 FROM authorization_requests WHERE request_digest = ?1",
                rusqlite::params![token_digest(request_id)],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, ResourceKind>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, i64>(6)?,
                        row.get::<_, String>(7)?,
                    ))
                },
            )
            .map_err(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => {
                    "unknown authorization request".to_owned()
                }
                other => format!("lookup builder authorization request: {other}"),
            })?;
        let (
            client_id,
            redirect_uri,
            scope,
            code_challenge,
            resource,
            expires_at,
            used,
            consent_nonce_digest,
        ) = request;
        if resource != ResourceKind::Builder
            || consent_nonce_digest.is_empty()
            || !thumble_tunnel::constant_time_eq(
                consent_nonce_digest.as_bytes(),
                token_digest(consent_nonce).as_bytes(),
            )
        {
            return Err("builder consent verification failed".to_owned());
        }
        if used != 0 || now > expires_at {
            return Err("authorization request is expired or already used".to_owned());
        }
        let changed = transaction
            .execute(
                "UPDATE authorization_requests SET used = 1 WHERE request_digest = ?1 \
                   AND used = 0 AND expires_at >= ?2 AND resource_kind = 'builder' \
                   AND consent_nonce_digest = ?3",
                rusqlite::params![token_digest(request_id), now, token_digest(consent_nonce)],
            )
            .map_err(|error| format!("consume builder authorization request: {error}"))?;
        if changed != 1 {
            return Err("authorization request changed during completion".to_owned());
        }
        transaction
            .execute(
                "INSERT INTO auth_codes (code_digest, client_id, redirect_uri, scope, code_challenge, device_id, expires_at, used, principal_kind, principal_id, resource_kind) \
                 VALUES (?1, ?2, ?3, ?4, ?5, '', ?6, 0, 'builder', ?7, 'builder')",
                rusqlite::params![
                    token_digest(&code),
                    client_id,
                    redirect_uri,
                    scope,
                    code_challenge,
                    now + ttl_seconds,
                    binding.principal.id,
                ],
            )
            .map_err(|error| format!("create builder authorization code: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit builder authorization completion: {error}"))?;
        Ok(code)
    }

    /// Atomically consume one builder consent, create a fresh opaque builder
    /// principal, and mint its authorization code. Expected stale, reused, or
    /// cross-resource requests are returned as a closed grant rather than a
    /// storage error. No device or tunnel state participates in this flow.
    pub fn complete_new_builder_authorization(
        &self,
        request_id: &str,
        consent_nonce: &str,
        ttl_seconds: i64,
    ) -> Result<Result<(String, String, AuthorizationRequestRecord), String>, String> {
        let builder_id = format!("bpr_{}", thumble_tunnel::random_token(18));
        let binding = OAuthBinding::builder(builder_id.clone())?;
        let code = thumble_tunnel::random_token(24);
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin new builder authorization: {error}"))?;
        let request = transaction.query_row(
            "SELECT client_id, redirect_uri, state, scope, code_challenge, resource_kind, expires_at, used, consent_nonce_digest \
             FROM authorization_requests WHERE request_digest = ?1",
            rusqlite::params![token_digest(request_id)],
            |row| {
                Ok((
                    AuthorizationRequestRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        state: row.get(2)?,
                        scope: row.get(3)?,
                        code_challenge: row.get(4)?,
                        resource: row.get(5)?,
                    },
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, String>(8)?,
                ))
            },
        );
        let (request, expires_at, used, consent_nonce_digest) = match request {
            Ok(request) => request,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown authorization request".to_owned()))
            }
            Err(error) => {
                return Err(format!("lookup new builder authorization: {error}"));
            }
        };
        if request.resource != ResourceKind::Builder
            || consent_nonce_digest.is_empty()
            || !thumble_tunnel::constant_time_eq(
                consent_nonce_digest.as_bytes(),
                token_digest(consent_nonce).as_bytes(),
            )
        {
            return Ok(Err("builder consent verification failed".to_owned()));
        }
        if used != 0 {
            return Ok(Err("authorization request already used".to_owned()));
        }
        if now > expires_at {
            return Ok(Err("authorization request expired".to_owned()));
        }
        prepare_builder_principal_insert(&transaction, now, self.max_builder_principals)?;
        let changed = transaction
            .execute(
                "UPDATE authorization_requests SET used = 1 WHERE request_digest = ?1 \
                 AND used = 0 AND expires_at >= ?2 AND resource_kind = 'builder' \
                 AND consent_nonce_digest = ?3",
                rusqlite::params![token_digest(request_id), now, token_digest(consent_nonce)],
            )
            .map_err(|error| format!("consume new builder authorization: {error}"))?;
        if changed != 1 {
            return Ok(Err(
                "authorization request is expired or already used".to_owned()
            ));
        }
        transaction
            .execute(
                "INSERT INTO builder_principals (id, name, created_at, last_seen_at, revoked) \
                 VALUES (?1, 'OAuth builder session', ?2, ?2, 0)",
                rusqlite::params![binding.principal.id, now],
            )
            .map_err(|error| format!("create OAuth builder principal: {error}"))?;
        transaction
            .execute(
                "INSERT INTO auth_codes (code_digest, client_id, redirect_uri, scope, code_challenge, device_id, expires_at, used, principal_kind, principal_id, resource_kind) \
                 VALUES (?1, ?2, ?3, ?4, ?5, '', ?6, 0, 'builder', ?7, 'builder')",
                rusqlite::params![
                    token_digest(&code),
                    request.client_id,
                    request.redirect_uri,
                    request.scope,
                    request.code_challenge,
                    now + ttl_seconds,
                    binding.principal.id,
                ],
            )
            .map_err(|error| format!("create new builder authorization code: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit new builder authorization: {error}"))?;
        Ok(Ok((code, builder_id, request)))
    }

    /// Atomically verify and consume a denied builder consent. The request is
    /// returned for its already-validated callback and state fields.
    pub fn deny_builder_authorization(
        &self,
        request_id: &str,
        consent_nonce: &str,
    ) -> Result<Result<AuthorizationRequestRecord, String>, String> {
        let now = Self::now();
        let request_digest = token_digest(request_id);
        let nonce_digest = token_digest(consent_nonce);
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin builder authorization denial: {error}"))?;
        let row = transaction.query_row(
            "SELECT client_id, redirect_uri, state, scope, code_challenge, resource_kind, expires_at, used, consent_nonce_digest \
             FROM authorization_requests WHERE request_digest = ?1",
            rusqlite::params![request_digest],
            |row| {
                Ok((
                    AuthorizationRequestRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        state: row.get(2)?,
                        scope: row.get(3)?,
                        code_challenge: row.get(4)?,
                        resource: row.get(5)?,
                    },
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, String>(8)?,
                ))
            },
        );
        let (request, expires_at, used, stored_nonce_digest) = match row {
            Ok(row) => row,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown authorization request".to_owned()))
            }
            Err(error) => return Err(format!("lookup builder authorization denial: {error}")),
        };
        if request.resource != ResourceKind::Builder
            || stored_nonce_digest.is_empty()
            || !thumble_tunnel::constant_time_eq(
                stored_nonce_digest.as_bytes(),
                nonce_digest.as_bytes(),
            )
        {
            return Ok(Err("builder consent verification failed".to_owned()));
        }
        if used != 0 {
            return Ok(Err("authorization request already used".to_owned()));
        }
        if now > expires_at {
            return Ok(Err("authorization request expired".to_owned()));
        }
        let changed = transaction
            .execute(
                "UPDATE authorization_requests SET used = 1 WHERE request_digest = ?1 \
                 AND used = 0 AND expires_at >= ?2 AND resource_kind = 'builder' \
                 AND consent_nonce_digest = ?3",
                rusqlite::params![request_digest, now, nonce_digest],
            )
            .map_err(|error| format!("consume denied builder authorization: {error}"))?;
        if changed != 1 {
            return Ok(Err(
                "authorization request is expired or already used".to_owned()
            ));
        }
        transaction
            .commit()
            .map_err(|error| format!("commit builder authorization denial: {error}"))?;
        Ok(Ok(request))
    }

    pub fn create_auth_code(
        &self,
        client_id: &str,
        redirect_uri: &str,
        scope: &str,
        code_challenge: &str,
        device_id: &str,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        self.create_auth_code_for_binding(
            client_id,
            redirect_uri,
            scope,
            code_challenge,
            &OAuthBinding::device_relay(device_id.to_owned())?,
            ttl_seconds,
        )
    }

    pub fn create_auth_code_for_binding(
        &self,
        client_id: &str,
        redirect_uri: &str,
        scope: &str,
        code_challenge: &str,
        binding: &OAuthBinding,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        binding.validate()?;
        let code = thumble_tunnel::random_token(24);
        let now = Self::now();
        let connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        connection
            .execute(
                "INSERT INTO auth_codes (code_digest, client_id, redirect_uri, scope, code_challenge, device_id, expires_at, used, principal_kind, principal_id, resource_kind) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, ?8, ?9, ?10)",
                rusqlite::params![
                    token_digest(&code),
                    client_id,
                    redirect_uri,
                    scope,
                    code_challenge,
                    compatibility_device_id(binding),
                    now + ttl_seconds,
                    binding.principal.kind,
                    binding.principal.id,
                    binding.resource,
                ],
            )
            .map_err(|e| format!("create auth code: {e}"))?;
        Ok(code)
    }

    /// Verify every authorization-code binding, including PKCE, before
    /// marking the code used. A guessed/intercepted code with the wrong
    /// verifier cannot deny service to the legitimate client.
    pub fn consume_auth_code(
        &self,
        code: &str,
        client_id: &str,
        redirect_uri: &str,
        code_verifier: &str,
    ) -> Result<Result<AuthCodeRecord, String>, String> {
        self.consume_auth_code_for_resource(
            code,
            client_id,
            redirect_uri,
            code_verifier,
            ResourceKind::Relay,
        )
    }

    pub fn consume_auth_code_for_resource(
        &self,
        code: &str,
        client_id: &str,
        redirect_uri: &str,
        code_verifier: &str,
        resource: ResourceKind,
    ) -> Result<Result<AuthCodeRecord, String>, String> {
        let digest = token_digest(code);
        let connection = self.connection.lock().unwrap();
        let record = connection.query_row(
            "SELECT client_id, redirect_uri, scope, code_challenge, device_id, principal_kind, principal_id, resource_kind, expires_at, used \
             FROM auth_codes WHERE code_digest = ?1",
            rusqlite::params![digest],
            |row| {
                let (device_id, binding) = binding_from_row(row, 4, 5, 6, 7)?;
                Ok((
                    AuthCodeRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        scope: row.get(2)?,
                        code_challenge: row.get(3)?,
                        device_id,
                        binding,
                    },
                    row.get::<_, i64>(8)?,
                    row.get::<_, i64>(9)?,
                ))
            },
        );
        match record {
            Ok((record, expires_at, used)) => {
                if used != 0 {
                    return Ok(Err("authorization code already used".to_owned()));
                }
                if Self::now() > expires_at {
                    return Ok(Err("authorization code expired".to_owned()));
                }
                if record.client_id != client_id || record.redirect_uri != redirect_uri {
                    return Ok(Err(
                        "authorization code does not match the client".to_owned()
                    ));
                }
                if record.binding.resource != resource {
                    return Ok(Err(
                        "authorization code does not match the resource".to_owned()
                    ));
                }
                if !thumble_tunnel::pkce_s256_matches(code_verifier, &record.code_challenge) {
                    return Ok(Err("PKCE verification failed".to_owned()));
                }
                let changed = connection
                    .execute(
                        "UPDATE auth_codes SET used = 1 WHERE code_digest = ?1 AND used = 0",
                        rusqlite::params![digest],
                    )
                    .map_err(|e| format!("use auth code: {e}"))?;
                if changed != 1 {
                    return Ok(Err("authorization code is no longer usable".to_owned()));
                }
                Ok(Ok(record))
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                Ok(Err("unknown authorization code".to_owned()))
            }
            Err(other) => Err(format!("lookup auth code: {other}")),
        }
    }

    /// Verify and consume an authorization code while issuing its isolated
    /// access/optional-refresh token family in the same transaction. Any
    /// storage or active-device failure rolls the code consumption back.
    #[allow(clippy::too_many_arguments)]
    pub fn exchange_auth_code(
        &self,
        code: &str,
        client_id: &str,
        redirect_uri: &str,
        code_verifier: &str,
        access_ttl_seconds: i64,
        refresh_ttl_seconds: i64,
    ) -> Result<Result<AuthorizationTokenGrant, String>, String> {
        self.exchange_auth_code_for_resource(
            code,
            client_id,
            redirect_uri,
            code_verifier,
            ResourceKind::Relay,
            access_ttl_seconds,
            refresh_ttl_seconds,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn exchange_auth_code_for_resource(
        &self,
        code: &str,
        client_id: &str,
        redirect_uri: &str,
        code_verifier: &str,
        resource: ResourceKind,
        access_ttl_seconds: i64,
        refresh_ttl_seconds: i64,
    ) -> Result<Result<AuthorizationTokenGrant, String>, String> {
        let code_digest = token_digest(code);
        let access_token = thumble_tunnel::random_token(32);
        let refresh_token = thumble_tunnel::random_token(32);
        let family_id = Self::new_token_family_id();
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin authorization-code exchange: {error}"))?;
        let record = transaction.query_row(
            "SELECT client_id, redirect_uri, scope, code_challenge, device_id, principal_kind, principal_id, resource_kind, expires_at, used \
             FROM auth_codes WHERE code_digest = ?1",
            rusqlite::params![code_digest],
            |row| {
                let (device_id, binding) = binding_from_row(row, 4, 5, 6, 7)?;
                Ok((
                    AuthCodeRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        scope: row.get(2)?,
                        code_challenge: row.get(3)?,
                        device_id,
                        binding,
                    },
                    row.get::<_, i64>(8)?,
                    row.get::<_, i64>(9)?,
                ))
            },
        );
        let (record, expires_at, used) = match record {
            Ok(record) => record,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown authorization code".to_owned()));
            }
            Err(error) => return Err(format!("lookup authorization code: {error}")),
        };
        if used != 0 {
            return Ok(Err("authorization code already used".to_owned()));
        }
        if now > expires_at {
            return Ok(Err("authorization code expired".to_owned()));
        }
        if record.client_id != client_id || record.redirect_uri != redirect_uri {
            return Ok(Err(
                "authorization code does not match the client".to_owned()
            ));
        }
        if record.binding.resource != resource {
            return Ok(Err(
                "authorization code does not match the resource".to_owned()
            ));
        }
        if !thumble_tunnel::pkce_s256_matches(code_verifier, &record.code_challenge) {
            return Ok(Err("PKCE verification failed".to_owned()));
        }
        require_active_principal(&transaction, &record.binding.principal)?;
        let include_refresh = record
            .scope
            .split_whitespace()
            .any(|scope| scope == "offline_access");
        if include_refresh {
            let capacity = enforce_refresh_capacity(
                &transaction,
                &record.binding,
                client_id,
                &family_id,
                now,
                self.refresh_family_limit,
                self.refresh_principal_client_limit,
                self.refresh_global_limit,
            )?;
            if let Some(reason) = refresh_capacity_reason(capacity) {
                if capacity == RefreshCapacity::FamilyRevoked {
                    transaction.commit().map_err(|error| {
                        format!("commit refresh family capacity revocation: {error}")
                    })?;
                }
                return Ok(Err(reason.to_owned()));
            }
        }
        touch_builder_principal(&transaction, &record.binding.principal, now)?;
        let consumed = transaction
            .execute(
                "UPDATE auth_codes SET used = 1 WHERE code_digest = ?1 AND used = 0",
                rusqlite::params![code_digest],
            )
            .map_err(|error| format!("consume authorization code: {error}"))?;
        if consumed != 1 {
            return Ok(Err("authorization code is no longer usable".to_owned()));
        }
        transaction
            .execute(
                "INSERT INTO access_tokens (token_digest, device_id, client_id, scope, expires_at, revoked, family_id, principal_kind, principal_id, resource_kind) \
                 VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8, ?9)",
                rusqlite::params![
                    token_digest(&access_token),
                    compatibility_device_id(&record.binding),
                    client_id,
                    record.scope,
                    now + access_ttl_seconds,
                    family_id,
                    record.binding.principal.kind,
                    record.binding.principal.id,
                    record.binding.resource,
                ],
            )
            .map_err(|error| format!("issue authorization access token: {error}"))?;
        if include_refresh {
            transaction
                .execute(
                    "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at, family_id, principal_kind, principal_id, resource_kind) \
                     VALUES (?1, ?2, ?3, ?4, ?5, NULL, 0, 0, ?6, ?7, ?8, ?9)",
                    rusqlite::params![
                        token_digest(&refresh_token),
                        compatibility_device_id(&record.binding),
                        client_id,
                        record.scope,
                        now + refresh_ttl_seconds,
                        family_id,
                        record.binding.principal.kind,
                        record.binding.principal.id,
                        record.binding.resource,
                    ],
                )
                .map_err(|error| format!("issue authorization refresh token: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit authorization-code exchange: {error}"))?;
        Ok(Ok(AuthorizationTokenGrant {
            access_token,
            refresh_token: include_refresh.then_some(refresh_token),
            scope: record.scope,
            device_id: record.device_id,
            binding: record.binding,
        }))
    }

    pub fn issue_access_token(
        &self,
        device_id: &str,
        scope: &str,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        self.issue_access_token_for_binding(
            &OAuthBinding::device_relay(device_id.to_owned())?,
            scope,
            ttl_seconds,
        )
    }

    pub fn issue_access_token_for_binding(
        &self,
        binding: &OAuthBinding,
        scope: &str,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        binding.validate()?;
        let token = thumble_tunnel::random_token(32);
        let family_id = Self::new_token_family_id();
        let mut connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, Self::now())?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin access-token issuance: {error}"))?;
        require_active_principal(&transaction, &binding.principal)?;
        transaction
            .execute(
                "INSERT INTO access_tokens (token_digest, device_id, client_id, scope, expires_at, revoked, family_id, principal_kind, principal_id, resource_kind) \
                 VALUES (?1, ?2, '', ?3, ?4, 0, ?5, ?6, ?7, ?8)",
                rusqlite::params![
                    token_digest(&token),
                    compatibility_device_id(binding),
                    scope,
                    Self::now() + ttl_seconds,
                    family_id,
                    binding.principal.kind,
                    binding.principal.id,
                    binding.resource,
                ],
            )
            .map_err(|e| format!("issue access token: {e}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit access-token issuance: {error}"))?;
        Ok(token)
    }

    /// Issue the authorization-code access/refresh credential pair in one
    /// isolated family and one transaction. Reuse of an older independent
    /// grant can revoke only its own family, never this newly approved one.
    pub fn issue_authorization_tokens(
        &self,
        device_id: &str,
        client_id: &str,
        scope: &str,
        access_ttl_seconds: i64,
        refresh_ttl_seconds: i64,
        include_refresh: bool,
    ) -> Result<(String, Option<String>), String> {
        self.issue_authorization_tokens_for_binding(
            &OAuthBinding::device_relay(device_id.to_owned())?,
            client_id,
            scope,
            access_ttl_seconds,
            refresh_ttl_seconds,
            include_refresh,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn issue_authorization_tokens_for_binding(
        &self,
        binding: &OAuthBinding,
        client_id: &str,
        scope: &str,
        access_ttl_seconds: i64,
        refresh_ttl_seconds: i64,
        include_refresh: bool,
    ) -> Result<(String, Option<String>), String> {
        binding.validate()?;
        let access = thumble_tunnel::random_token(32);
        let refresh = include_refresh.then(|| thumble_tunnel::random_token(32));
        let family_id = Self::new_token_family_id();
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin authorization-token issuance: {error}"))?;
        require_active_principal(&transaction, &binding.principal)?;
        if include_refresh {
            let capacity = enforce_refresh_capacity(
                &transaction,
                binding,
                client_id,
                &family_id,
                now,
                self.refresh_family_limit,
                self.refresh_principal_client_limit,
                self.refresh_global_limit,
            )?;
            if let Some(reason) = refresh_capacity_reason(capacity) {
                if capacity == RefreshCapacity::FamilyRevoked {
                    transaction.commit().map_err(|error| {
                        format!("commit refresh family capacity revocation: {error}")
                    })?;
                }
                return Err(reason.to_owned());
            }
        }
        transaction
            .execute(
                "INSERT INTO access_tokens (token_digest, device_id, client_id, scope, expires_at, revoked, family_id, principal_kind, principal_id, resource_kind) \
                 VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7, ?8, ?9)",
                rusqlite::params![
                    token_digest(&access),
                    compatibility_device_id(binding),
                    client_id,
                    scope,
                    now + access_ttl_seconds,
                    family_id,
                    binding.principal.kind,
                    binding.principal.id,
                    binding.resource,
                ],
            )
            .map_err(|error| format!("issue authorization access token: {error}"))?;
        if let Some(refresh) = refresh.as_deref() {
            transaction
                .execute(
                    "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at, family_id, principal_kind, principal_id, resource_kind) \
                     VALUES (?1, ?2, ?3, ?4, ?5, NULL, 0, 0, ?6, ?7, ?8, ?9)",
                    rusqlite::params![
                        token_digest(refresh),
                        compatibility_device_id(binding),
                        client_id,
                        scope,
                        now + refresh_ttl_seconds,
                        family_id,
                        binding.principal.kind,
                        binding.principal.id,
                        binding.resource,
                    ],
                )
                .map_err(|error| format!("issue authorization refresh token: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit authorization-token issuance: {error}"))?;
        Ok((access, refresh))
    }

    pub fn access_token(&self, token: &str) -> Result<Option<AccessTokenRecord>, String> {
        self.access_token_for_resource(token, ResourceKind::Relay)
    }

    pub fn access_token_for_resource(
        &self,
        token: &str,
        resource: ResourceKind,
    ) -> Result<Option<AccessTokenRecord>, String> {
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin access-token lookup: {error}"))?;
        let result = transaction.query_row(
            "SELECT device_id, scope, principal_kind, principal_id, resource_kind, expires_at, revoked \
             FROM access_tokens WHERE token_digest = ?1",
            rusqlite::params![token_digest(token)],
            |row| {
                let (device_id, binding) = binding_from_row(row, 0, 2, 3, 4)?;
                Ok((
                    AccessTokenRecord {
                        device_id,
                        scope: row.get(1)?,
                        binding,
                    },
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            },
        );
        let (record, expires_at, revoked) = match result {
            Ok(record) => record,
            Err(rusqlite::Error::QueryReturnedNoRows) => return Ok(None),
            Err(error) => return Err(format!("lookup access token: {error}")),
        };
        if record.binding.resource != resource || revoked != 0 || now > expires_at {
            return Ok(None);
        }
        match require_active_principal(&transaction, &record.binding.principal) {
            Ok(()) => {
                touch_builder_principal(&transaction, &record.binding.principal, now)?;
                transaction
                    .commit()
                    .map_err(|error| format!("commit access-token lookup: {error}"))?;
                Ok(Some(record))
            }
            Err(reason) if reason.starts_with("unknown ") || reason.ends_with(" is revoked") => {
                Ok(None)
            }
            Err(error) => Err(error),
        }
    }

    pub fn issue_refresh_token(
        &self,
        device_id: &str,
        client_id: &str,
        scope: &str,
        ttl_seconds: i64,
        rotated_from: Option<&str>,
    ) -> Result<String, String> {
        self.issue_refresh_token_for_binding(
            &OAuthBinding::device_relay(device_id.to_owned())?,
            client_id,
            scope,
            ttl_seconds,
            rotated_from,
        )
    }

    pub fn issue_refresh_token_for_binding(
        &self,
        binding: &OAuthBinding,
        client_id: &str,
        scope: &str,
        ttl_seconds: i64,
        rotated_from: Option<&str>,
    ) -> Result<String, String> {
        binding.validate()?;
        let token = thumble_tunnel::random_token(32);
        let rotated_from_digest = rotated_from.map(token_digest);
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin refresh-token issuance: {error}"))?;
        require_active_principal(&transaction, &binding.principal)?;
        let family_id = if let Some(parent) = rotated_from_digest.as_deref() {
            transaction
                .query_row(
                    "SELECT family_id, device_id, principal_kind, principal_id, resource_kind \
                     FROM refresh_tokens \
                     WHERE token_digest = ?1 AND principal_kind = ?2 AND principal_id = ?3 \
                       AND resource_kind = ?4 AND client_id = ?5",
                    rusqlite::params![
                        parent,
                        binding.principal.kind,
                        binding.principal.id,
                        binding.resource,
                        client_id
                    ],
                    |row| {
                        let (_, persisted_binding) = binding_from_row(row, 1, 2, 3, 4)?;
                        if persisted_binding != *binding {
                            return Err(rusqlite::Error::InvalidQuery);
                        }
                        row.get::<_, String>(0)
                    },
                )
                .map_err(|error| format!("lookup parent refresh-token family: {error}"))?
        } else {
            Self::new_token_family_id()
        };
        let capacity = enforce_refresh_capacity(
            &transaction,
            binding,
            client_id,
            &family_id,
            now,
            self.refresh_family_limit,
            self.refresh_principal_client_limit,
            self.refresh_global_limit,
        )?;
        if let Some(reason) = refresh_capacity_reason(capacity) {
            if capacity == RefreshCapacity::FamilyRevoked {
                transaction.commit().map_err(|error| {
                    format!("commit refresh family capacity revocation: {error}")
                })?;
            }
            return Err(reason.to_owned());
        }
        transaction
            .execute(
                "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at, family_id, principal_kind, principal_id, resource_kind) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, 0, ?7, ?8, ?9, ?10)",
                rusqlite::params![
                    token_digest(&token),
                    compatibility_device_id(binding),
                    client_id,
                    scope,
                    now + ttl_seconds,
                    rotated_from_digest,
                    family_id,
                    binding.principal.kind,
                    binding.principal.id,
                    binding.resource,
                ],
            )
            .map_err(|e| format!("issue refresh token: {e}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit refresh-token issuance: {error}"))?;
        Ok(token)
    }

    /// Rotate a refresh token. Validation, reuse-family revocation, device
    /// state checking, old-token revocation, and replacement insertion are a
    /// single SQLite transaction, so concurrent replay/revoke cannot mint a
    /// token after the family has been invalidated.
    ///
    /// Presenting an already-rotated token is either a concurrent refresh by
    /// another window of the same desktop client (they share one token
    /// cache) or a replayed stolen token. Recent rotations (inside the grace
    /// window, within the successor budget, on an active device) mint one
    /// additional successor per caller; anything later revokes the family.
    #[allow(clippy::type_complexity)]
    pub fn rotate_refresh_token(
        &self,
        token: &str,
        client_id: &str,
        ttl_seconds: i64,
    ) -> Result<Result<(String, String, String), String>, String> {
        self.rotate_refresh_token_for_resource(token, client_id, ResourceKind::Relay, ttl_seconds)
            .map(|result| {
                result.map(|grant| (grant.access_token, grant.refresh_token, grant.scope))
            })
    }

    pub fn rotate_refresh_token_for_resource(
        &self,
        token: &str,
        client_id: &str,
        resource: ResourceKind,
        ttl_seconds: i64,
    ) -> Result<Result<RefreshTokenGrant, String>, String> {
        let digest = token_digest(token);
        let new_refresh = thumble_tunnel::random_token(32);
        let new_access = thumble_tunnel::random_token(32);
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin refresh rotation: {error}"))?;
        let record = transaction.query_row(
            "SELECT device_id, client_id, scope, principal_kind, principal_id, resource_kind, expires_at, revoked, family_id \
             FROM refresh_tokens WHERE token_digest = ?1",
            rusqlite::params![digest],
            |row| {
                let (device_id, binding) = binding_from_row(row, 0, 3, 4, 5)?;
                Ok((
                    RefreshTokenRecord {
                        device_id,
                        client_id: row.get(1)?,
                        scope: row.get(2)?,
                        binding,
                    },
                    row.get::<_, i64>(6)?,
                    row.get::<_, i64>(7)?,
                    row.get::<_, String>(8)?,
                ))
            },
        );
        let (record, expires_at, revoked, family_id) = match record {
            Ok(value) => value,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown refresh token".to_owned()));
            }
            Err(other) => return Err(format!("lookup refresh token: {other}")),
        };
        if record.client_id != client_id {
            return Ok(Err(
                "refresh token was issued to a different client".to_owned()
            ));
        }
        if record.binding.resource != resource {
            return Ok(Err("refresh token does not match the resource".to_owned()));
        }
        if revoked == 1 {
            let rotated_at: i64 = transaction
                .query_row(
                    "SELECT rotated_at FROM refresh_tokens WHERE token_digest = ?1 \
                       AND principal_kind = ?2 AND principal_id = ?3 AND resource_kind = ?4 \
                       AND client_id = ?5 AND family_id = ?6",
                    rusqlite::params![
                        digest,
                        record.binding.principal.kind,
                        record.binding.principal.id,
                        record.binding.resource,
                        record.client_id,
                        family_id
                    ],
                    |row| row.get(0),
                )
                .unwrap_or(0);
            let within_grace = rotated_at > 0
                && now - rotated_at <= self.refresh_grace_seconds
                && self.refresh_grace_seconds > 0;
            let successors: i64 = if within_grace {
                transaction
                    .query_row(
                        "SELECT COUNT(*) FROM refresh_tokens WHERE rotated_from = ?1 \
                           AND principal_kind = ?2 AND principal_id = ?3 AND resource_kind = ?4 \
                           AND client_id = ?5 AND family_id = ?6",
                        rusqlite::params![
                            digest,
                            record.binding.principal.kind,
                            record.binding.principal.id,
                            record.binding.resource,
                            record.client_id,
                            family_id
                        ],
                        |row| row.get(0),
                    )
                    .unwrap_or(i64::MAX)
            } else {
                i64::MAX
            };
            if within_grace && successors < MAXIMUM_GRACE_SUCCESSORS && now <= expires_at {
                if let Err(reason) =
                    require_active_principal(&transaction, &record.binding.principal)
                {
                    return Ok(Err(reason));
                }
                let capacity = enforce_refresh_capacity(
                    &transaction,
                    &record.binding,
                    &record.client_id,
                    &family_id,
                    now,
                    self.refresh_family_limit,
                    self.refresh_principal_client_limit,
                    self.refresh_global_limit,
                )?;
                if let Some(reason) = refresh_capacity_reason(capacity) {
                    if capacity == RefreshCapacity::FamilyRevoked {
                        transaction.commit().map_err(|error| {
                            format!("commit refresh family capacity revocation: {error}")
                        })?;
                    }
                    return Ok(Err(reason.to_owned()));
                }
                insert_rotated_pair(
                    &transaction,
                    &record,
                    &digest,
                    &family_id,
                    &new_access,
                    &new_refresh,
                    now,
                    ttl_seconds,
                )?;
                touch_builder_principal(&transaction, &record.binding.principal, now)?;
                transaction
                    .commit()
                    .map_err(|error| format!("commit grace refresh rotation: {error}"))?;
                return Ok(Ok(RefreshTokenGrant {
                    access_token: new_access,
                    refresh_token: new_refresh,
                    scope: record.scope,
                    binding: record.binding,
                }));
            }
            transaction
                .execute(
                    "UPDATE access_tokens SET revoked = 1 WHERE principal_kind = ?1 \
                       AND principal_id = ?2 AND resource_kind = ?3 AND family_id = ?4",
                    rusqlite::params![
                        record.binding.principal.kind,
                        record.binding.principal.id,
                        record.binding.resource,
                        family_id
                    ],
                )
                .map_err(|error| format!("revoke family access tokens: {error}"))?;
            transaction
                .execute(
                    "UPDATE refresh_tokens SET revoked = 1 WHERE principal_kind = ?1 \
                       AND principal_id = ?2 AND resource_kind = ?3 AND client_id = ?4 \
                       AND family_id = ?5",
                    rusqlite::params![
                        record.binding.principal.kind,
                        record.binding.principal.id,
                        record.binding.resource,
                        record.client_id,
                        family_id
                    ],
                )
                .map_err(|error| format!("revoke family refresh tokens: {error}"))?;
            transaction
                .commit()
                .map_err(|error| format!("commit refresh reuse revocation: {error}"))?;
            return Ok(Err(
                "refresh token reuse detected; token family revoked".to_owned()
            ));
        }
        if now > expires_at {
            return Ok(Err("refresh token expired".to_owned()));
        }
        require_active_principal(&transaction, &record.binding.principal)?;
        let capacity = enforce_refresh_capacity(
            &transaction,
            &record.binding,
            &record.client_id,
            &family_id,
            now,
            self.refresh_family_limit,
            self.refresh_principal_client_limit,
            self.refresh_global_limit,
        )?;
        if let Some(reason) = refresh_capacity_reason(capacity) {
            if capacity == RefreshCapacity::FamilyRevoked {
                transaction.commit().map_err(|error| {
                    format!("commit refresh family capacity revocation: {error}")
                })?;
            }
            return Ok(Err(reason.to_owned()));
        }
        let changed = transaction
            .execute(
                "UPDATE refresh_tokens SET revoked = 1, rotated_at = ?2 WHERE token_digest = ?1 \
                   AND principal_kind = ?3 AND principal_id = ?4 AND resource_kind = ?5 \
                   AND client_id = ?6 AND family_id = ?7 AND revoked = 0",
                rusqlite::params![
                    digest,
                    now,
                    record.binding.principal.kind,
                    record.binding.principal.id,
                    record.binding.resource,
                    record.client_id,
                    family_id
                ],
            )
            .map_err(|error| format!("rotate refresh token: {error}"))?;
        if changed != 1 {
            return Ok(Err(
                "refresh token binding changed during rotation".to_owned()
            ));
        }
        insert_rotated_pair(
            &transaction,
            &record,
            &digest,
            &family_id,
            &new_access,
            &new_refresh,
            now,
            ttl_seconds,
        )?;
        touch_builder_principal(&transaction, &record.binding.principal, now)?;
        transaction
            .commit()
            .map_err(|error| format!("commit refresh rotation: {error}"))?;
        Ok(Ok(RefreshTokenGrant {
            access_token: new_access,
            refresh_token: new_refresh,
            scope: record.scope,
            binding: record.binding,
        }))
    }

    pub fn store_manifest(&self, device_id: &str, manifest: &ManifestRecord) -> Result<(), String> {
        self.connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO manifests (device_id, tools, resources, instructions, updated_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5) \
                 ON CONFLICT(device_id) DO UPDATE SET tools = ?2, resources = ?3, instructions = ?4, updated_at = ?5",
                rusqlite::params![
                    device_id,
                    serde_json::to_string(&manifest.tools).unwrap(),
                    serde_json::to_string(&manifest.resources).unwrap(),
                    manifest.instructions,
                    Self::now()
                ],
            )
            .map_err(|e| format!("store manifest: {e}"))?;
        Ok(())
    }

    pub fn manifest(&self, device_id: &str) -> Result<Option<ManifestRecord>, String> {
        self.connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT tools, resources, instructions FROM manifests WHERE device_id = ?1",
                rusqlite::params![device_id],
                |row| {
                    Ok(ManifestRecord {
                        tools: serde_json::from_str(&row.get::<_, String>(0)?).unwrap_or_default(),
                        resources: serde_json::from_str(&row.get::<_, String>(1)?)
                            .unwrap_or_default(),
                        instructions: row.get(2)?,
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("lookup manifest: {other}")),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> Store {
        Store::open_in_memory().unwrap()
    }

    fn pkce_pair() -> (String, String) {
        use base64::Engine as _;
        use sha2::Digest as _;
        let verifier = "store-verifier-store-verifier-store-verifier-123".to_owned();
        let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(sha2::Sha256::digest(verifier.as_bytes()));
        (verifier, challenge)
    }

    #[test]
    fn devices_round_trip_and_revoke_fail_closed() {
        let store = store();
        let (id, token) = store.create_device("Cody's Mac").unwrap();
        let device = store.device_for_token(&token).unwrap().unwrap();
        assert_eq!(device.id, id);
        assert_eq!(device.name, "Cody's Mac");
        store.revoke_device(&id).unwrap();
        assert!(store.device_for_token(&token).unwrap().is_none());
    }

    #[test]
    fn rotating_a_device_token_replaces_the_credential_in_place() {
        let store = store();
        let (id, token) = store.create_device("Mac").unwrap();
        let rotated = store.rotate_device_token(&id, "MacBook").unwrap();
        assert_ne!(rotated, token);
        // The old credential stops working immediately; no dual-valid window.
        assert!(store.device_for_token(&token).unwrap().is_none());
        let device = store.device_for_token(&rotated).unwrap().unwrap();
        assert_eq!(device.id, id, "rotation must keep the device identity");
        assert_eq!(device.name, "MacBook");
        // Revoked (or unknown) devices cannot rotate back in.
        store.revoke_device(&id).unwrap();
        assert!(store.rotate_device_token(&id, "Mac").is_err());
        assert!(store.rotate_device_token("dev_missing", "Mac").is_err());
    }

    #[test]
    fn unknown_tokens_are_rejected() {
        let store = store();
        assert!(store.device_for_token("nope").unwrap().is_none());
    }

    #[test]
    fn link_codes_are_keyed_at_rest_burn_attempts_and_expire() {
        let store = store();
        let code = store.create_link_code("pending-1", "Mac", 60, 16).unwrap();
        let digest: String = store
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT code_digest FROM link_codes", [], |row| row.get(0))
            .unwrap();
        assert_ne!(digest, code);
        assert_eq!(digest.len(), 64);
        let second = store.consume_link_code(&code).unwrap().unwrap();
        assert_eq!(second, "pending-1");
        assert!(store.consume_link_code(&code).unwrap().is_err());
        let other = store.create_link_code("pending-2", "Mac", -1, 16).unwrap();
        assert!(store.consume_link_code(&other).unwrap().is_err());
    }

    #[test]
    fn client_registration_requires_https_redirects() {
        let store = store();
        for invalid in [
            "http://evil.example/cb",
            "http://localhost.evil/cb",
            "https://user@example.com/cb",
            "https://example.com/cb#fragment",
        ] {
            assert!(store
                .register_client("ChatGPT", vec![invalid.to_owned()])
                .is_err());
        }
        assert!(store
            .register_client(
                "ChatGPT",
                vec![
                    "https://chatgpt.com/cb".to_owned(),
                    "https://chatgpt.com/cb".to_owned()
                ]
            )
            .is_err());
        let client_id = store
            .register_client(
                "ChatGPT",
                vec!["https://chatgpt.com/connector/oauth/callback".to_owned()],
            )
            .unwrap();
        assert!(client(&store, &client_id).is_some());
    }

    fn client(store: &Store, id: &str) -> Option<ClientRecord> {
        store.client(id).unwrap()
    }

    #[test]
    fn inactive_clients_and_expired_authorization_requests_are_pruned() {
        let store = store();
        let old_client = store
            .register_client("Old", vec!["https://example.com/cb".to_owned()])
            .unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE oauth_clients SET created_at = 0 WHERE client_id = ?1",
                rusqlite::params![old_client],
            )
            .unwrap();
        store
            .create_authorization_request(
                "old",
                "https://example.com/cb",
                "state",
                "thumble.read",
                "challenge",
                -1,
            )
            .unwrap();
        store
            .register_client("New", vec!["https://example.com/new".to_owned()])
            .unwrap();
        assert!(store.client(&old_client).unwrap().is_none());
        let request_count: i64 = store
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM authorization_requests", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(request_count, 0);
    }

    #[test]
    fn dynamic_registration_evicts_only_oldest_unreferenced_clients_and_rejects_when_full() {
        let eviction_store = store().with_oauth_client_limit_for_test(3, 1);
        let protected = eviction_store
            .register_client(
                "Protected",
                vec!["https://example.com/protected".to_owned()],
            )
            .unwrap();
        eviction_store
            .create_authorization_request(
                &protected,
                "https://example.com/protected",
                "state",
                "thumble.read",
                "challenge",
                600,
            )
            .unwrap();
        let evictable = eviction_store
            .register_client(
                "Evictable",
                vec!["https://example.com/evictable".to_owned()],
            )
            .unwrap();
        let replacement = eviction_store
            .register_client(
                "Replacement",
                vec!["https://example.com/replacement".to_owned()],
            )
            .unwrap();
        assert!(eviction_store.client(&protected).unwrap().is_some());
        assert!(eviction_store.client(&evictable).unwrap().is_none());
        assert!(eviction_store.client(&replacement).unwrap().is_some());

        let store = store().with_oauth_client_limit_for_test(2, 1);
        let first = store
            .register_client("First", vec!["https://example.com/first".to_owned()])
            .unwrap();
        let (device, _) = store.create_device("DCR client").unwrap();
        let (_access, refresh) = store
            .issue_authorization_tokens(
                &device,
                &first,
                "thumble.read offline_access",
                600,
                600,
                true,
            )
            .unwrap();
        assert!(refresh.is_some());
        let second = store
            .register_client("Second", vec!["https://example.com/second".to_owned()])
            .unwrap();
        store
            .create_authorization_request(
                &second,
                "https://example.com/second",
                "state",
                "thumble.read",
                "challenge",
                600,
            )
            .unwrap();
        assert!(store
            .register_client("Rejected", vec!["https://example.com/rejected".to_owned()])
            .is_err());
        assert!(store.client(&first).unwrap().is_some());
        assert!(store.client(&second).unwrap().is_some());
    }

    #[test]
    fn authorization_requests_are_server_bound_and_lock_after_ten_attempts() {
        let store = store();
        let request = store
            .create_authorization_request(
                "cc_1",
                "https://chatgpt.com/cb",
                "state",
                "thumble.read",
                "challenge",
                60,
            )
            .unwrap();
        let loaded = store.authorization_request(&request).unwrap().unwrap();
        assert_eq!(loaded.client_id, "cc_1");
        for _ in 0..10 {
            store.record_authorization_attempt(&request).unwrap();
        }
        assert!(store.record_authorization_attempt(&request).is_err());
        store.consume_authorization_request(&request).unwrap();
        assert!(store.authorization_request(&request).unwrap().is_err());
    }

    #[test]
    fn fallback_code_and_authorization_are_claimed_atomically() {
        let store = store();
        let denied_request = store
            .create_authorization_request(
                "cc_1",
                "https://chatgpt.com/cb",
                "state",
                "thumble.read",
                "challenge",
                60,
            )
            .unwrap();
        let preserved_code = store
            .create_link_code("pending-denied", "Mac", 60, 16)
            .unwrap();
        store
            .consume_authorization_request(&denied_request)
            .unwrap();
        assert!(store
            .consume_authorization_with_link_code(&denied_request, &preserved_code)
            .unwrap()
            .is_err());
        assert_eq!(
            store.consume_link_code(&preserved_code).unwrap().unwrap(),
            "pending-denied",
            "losing the authorization race must not burn the fallback code"
        );

        let live_request = store
            .create_authorization_request(
                "cc_1",
                "https://chatgpt.com/cb",
                "state-2",
                "thumble.read",
                "challenge",
                60,
            )
            .unwrap();
        let live_code = store
            .create_link_code("pending-live", "Mac", 60, 16)
            .unwrap();
        let (claimed, pending_key) = store
            .consume_authorization_with_link_code(&live_request, &live_code)
            .unwrap()
            .unwrap();
        assert_eq!(claimed.state, "state-2");
        assert_eq!(pending_key, "pending-live");
        assert!(store.authorization_request(&live_request).unwrap().is_err());
        assert!(store.consume_link_code(&live_code).unwrap().is_err());
    }

    #[test]
    fn pre_family_schema_migrates_with_rollback_compatible_defaults() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE access_tokens (
                    token_digest TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE refresh_tokens (
                    token_digest TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    client_id TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    rotated_from TEXT,
                    revoked INTEGER NOT NULL DEFAULT 0,
                    rotated_at INTEGER NOT NULL DEFAULT 0
                );",
            )
            .unwrap();
        let store = Store::with_connection(connection, "gateway-test-link-secret-32-bytes-minimum")
            .unwrap();
        let (device, _) = store.create_device("Mac").unwrap();
        let connection = store.connection.lock().unwrap();
        // Old binaries omit family_id. The migration default keeps those
        // inserts valid if the deployment must roll back after migration.
        connection
            .execute(
                "INSERT INTO access_tokens (token_digest, device_id, scope, expires_at, revoked) \
                 VALUES ('legacy-access', ?1, 'thumble.read', ?2, 0)",
                rusqlite::params![device, Store::now() + 60],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at) \
                 VALUES ('legacy-refresh', ?1, 'cc_1', 'thumble.read', ?2, NULL, 0, 0)",
                rusqlite::params![device, Store::now() + 60],
            )
            .unwrap();
        let families: (String, String) = connection
            .query_row(
                "SELECT
                    (SELECT family_id FROM access_tokens WHERE token_digest = 'legacy-access'),
                    (SELECT family_id FROM refresh_tokens WHERE token_digest = 'legacy-refresh')",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(families, (String::new(), String::new()));
    }

    #[test]
    fn auth_codes_verify_pkce_before_single_use_consumption() {
        let store = store();
        let (_device, _token) = store.create_device("Mac").unwrap();
        let (verifier, challenge) = pkce_pair();
        let code = store
            .create_auth_code(
                "cc_1",
                "https://chatgpt.com/cb",
                "thumble.read",
                &challenge,
                "dev_x",
                60,
            )
            .unwrap();
        assert!(store
            .consume_auth_code(
                &code,
                "cc_1",
                "https://chatgpt.com/cb",
                "wrong-verifier-wrong-verifier-wrong-verifier-123",
            )
            .unwrap()
            .is_err());
        let first = store
            .consume_auth_code(&code, "cc_1", "https://chatgpt.com/cb", &verifier)
            .unwrap()
            .unwrap();
        assert_eq!(first.device_id, "dev_x");
        assert_eq!(first.code_challenge, challenge);
        assert!(store
            .consume_auth_code(&code, "cc_1", "https://chatgpt.com/cb", &verifier)
            .unwrap()
            .is_err());
        assert!(store
            .consume_auth_code(&code, "cc_1", "https://other.example/cb", &verifier,)
            .unwrap()
            .is_err());
        assert!(store
            .consume_auth_code("unknown", "cc_1", "https://chatgpt.com/cb", &verifier,)
            .unwrap()
            .is_err());
    }

    #[test]
    fn nonzero_authorization_code_used_values_never_issue_tokens() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let (verifier, challenge) = pkce_pair();
        let code = store
            .create_auth_code(
                "cc_1",
                "https://chatgpt.com/cb",
                "thumble.read offline_access",
                &challenge,
                &device,
                60,
            )
            .unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE auth_codes SET used = 2 WHERE code_digest = ?1",
                rusqlite::params![token_digest(&code)],
            )
            .unwrap();

        assert!(store
            .consume_auth_code(&code, "cc_1", "https://chatgpt.com/cb", &verifier)
            .unwrap()
            .is_err());
        for _ in 0..2 {
            assert!(store
                .exchange_auth_code(
                    &code,
                    "cc_1",
                    "https://chatgpt.com/cb",
                    &verifier,
                    900,
                    3600,
                )
                .unwrap()
                .is_err());
        }
        let connection = store.connection.lock().unwrap();
        let persisted: (i64, i64, i64) = connection
            .query_row(
                "SELECT used, (SELECT COUNT(*) FROM access_tokens), \
                 (SELECT COUNT(*) FROM refresh_tokens) \
                 FROM auth_codes WHERE code_digest = ?1",
                rusqlite::params![token_digest(&code)],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(persisted, (2, 0, 0));
    }

    #[test]
    fn failed_authorization_token_issuance_does_not_consume_the_code() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let (verifier, challenge) = pkce_pair();
        let code = store
            .create_auth_code(
                "cc_1",
                "https://chatgpt.com/cb",
                "thumble.read offline_access",
                &challenge,
                &device,
                60,
            )
            .unwrap();
        store.revoke_device(&device).unwrap();

        assert!(store
            .exchange_auth_code(
                &code,
                "cc_1",
                "https://chatgpt.com/cb",
                &verifier,
                900,
                3600,
            )
            .is_err());
        // The transaction rolled back before marking the code used.
        assert!(store
            .consume_auth_code(&code, "cc_1", "https://chatgpt.com/cb", &verifier)
            .unwrap()
            .is_ok());
    }

    #[test]
    fn access_tokens_expire_and_revoke() {
        let store = store();
        let (device, _token) = store.create_device("Mac").unwrap();
        let access = store
            .issue_access_token(&device, "thumble.read", -1)
            .unwrap();
        assert!(store.access_token(&access).unwrap().is_none());
    }

    #[test]
    fn refresh_rows_are_bounded_across_normal_rotation_and_abuse() {
        let cadence_store = store();
        let (device, _) = cadence_store.create_device("Monthly cadence").unwrap();
        let mut refresh = cadence_store
            .issue_refresh_token(&device, "monthly", "thumble.read", 31 * 24 * 60 * 60, None)
            .unwrap();
        for _ in 0..365 {
            refresh = cadence_store
                .rotate_refresh_token(&refresh, "monthly", 31 * 24 * 60 * 60)
                .unwrap()
                .unwrap()
                .1;
        }
        let count: i64 = cadence_store
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM refresh_tokens", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 366);
        assert!(count < MAXIMUM_REFRESH_ROWS_PER_FAMILY);

        let store = store().with_refresh_limits_for_test(3, 20, 20);
        let (device, _) = store.create_device("Abuse").unwrap();
        let first = store
            .issue_refresh_token(&device, "client", "thumble.read", 3600, None)
            .unwrap();
        let first_grant = store
            .rotate_refresh_token(&first, "client", 3600)
            .unwrap()
            .unwrap();
        let second_grant = store
            .rotate_refresh_token(&first_grant.1, "client", 3600)
            .unwrap()
            .unwrap();
        assert!(store
            .rotate_refresh_token(&second_grant.1, "client", 3600)
            .unwrap()
            .is_err());
        let connection = store.connection.lock().unwrap();
        let (rows, live): (i64, i64) = connection
            .query_row(
                "SELECT COUNT(*), SUM(CASE WHEN revoked = 0 THEN 1 ELSE 0 END) FROM refresh_tokens",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!((rows, live), (3, 0));
    }

    #[test]
    fn refresh_principal_client_and_global_caps_preserve_isolation() {
        let store = store().with_refresh_limits_for_test(20, 2, 4);
        let (relay, _) = store.create_device("Relay").unwrap();
        let builder = store.create_builder_principal("Builder").unwrap();
        for _ in 0..2 {
            store
                .issue_refresh_token(&relay, "shared", "thumble.read", 3600, None)
                .unwrap();
        }
        assert!(store
            .issue_refresh_token(&relay, "shared", "thumble.read", 3600, None)
            .is_err());
        // A different client and a typed builder principal retain independent
        // principal/resource/client budgets until the process-wide cap.
        store
            .issue_refresh_token(&relay, "other", "thumble.read", 3600, None)
            .unwrap();
        store
            .issue_refresh_token_for_binding(
                &OAuthBinding::builder(&builder).unwrap(),
                "shared",
                "thumble.build",
                3600,
                None,
            )
            .unwrap();
        assert!(store
            .issue_refresh_token(&relay, "global-full", "thumble.read", 3600, None)
            .is_err());
        let rows: i64 = store
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM refresh_tokens", [], |row| row.get(0))
            .unwrap();
        assert_eq!(rows, 4);
    }

    #[test]
    fn grace_successors_obey_the_same_family_row_cap() {
        let store = store().with_refresh_limits_for_test(2, 20, 20);
        let (device, _) = store.create_device("Grace cap").unwrap();
        let parent = store
            .issue_refresh_token(&device, "client", "thumble.read", 3600, None)
            .unwrap();
        let grant = store
            .rotate_refresh_token(&parent, "client", 3600)
            .unwrap()
            .unwrap();
        assert!(store
            .rotate_refresh_token(&parent, "client", 3600)
            .unwrap()
            .is_err());
        assert!(store.access_token(&grant.0).unwrap().is_none());
        let rows: i64 = store
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM refresh_tokens", [], |row| row.get(0))
            .unwrap();
        assert_eq!(rows, 2);
    }

    #[test]
    fn refresh_rotation_detects_reuse_after_the_grace_window() {
        let store = store().with_refresh_grace(0);
        let (device, _token) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let (access, new_refresh, scope) = store
            .rotate_refresh_token(&refresh, "cc_1", 3600)
            .unwrap()
            .unwrap();
        assert_eq!(scope, "thumble.read");
        assert!(store.access_token(&access).unwrap().is_some());
        // Replaying the old token after the grace window revokes the family.
        let replay = store.rotate_refresh_token(&refresh, "cc_1", 3600).unwrap();
        assert!(replay.is_err());
        assert!(store.access_token(&access).unwrap().is_none());
        assert!(store
            .rotate_refresh_token(&new_refresh, "cc_1", 3600)
            .unwrap()
            .is_err());
    }

    #[test]
    fn stale_refresh_replay_cannot_revoke_a_new_authorization_family() {
        let store = store().with_refresh_grace(0);
        let (device, _) = store.create_device("Mac").unwrap();
        let (_, old_refresh) = store
            .issue_authorization_tokens(
                &device,
                "cc_1",
                "thumble.read offline_access",
                900,
                3600,
                true,
            )
            .unwrap();
        let old_refresh = old_refresh.unwrap();
        let (old_access, old_successor, _) = store
            .rotate_refresh_token(&old_refresh, "cc_1", 3600)
            .unwrap()
            .unwrap();
        // Simulate rows migrated from the pre-family production schema. All
        // legacy grants intentionally share the empty compatibility family.
        {
            let connection = store.connection.lock().unwrap();
            connection
                .execute("UPDATE refresh_tokens SET family_id = ''", [])
                .unwrap();
            connection
                .execute("UPDATE access_tokens SET family_id = ''", [])
                .unwrap();
        }

        // A user explicitly authorizes the same device/client again while a
        // stale desktop window still holds a refresh token from the old grant.
        let (new_access, new_refresh) = store
            .issue_authorization_tokens(
                &device,
                "cc_1",
                "thumble.read offline_access",
                900,
                3600,
                true,
            )
            .unwrap();
        let replay = store
            .rotate_refresh_token(&old_refresh, "cc_1", 3600)
            .unwrap();
        assert!(replay.is_err());
        assert!(store.access_token(&old_access).unwrap().is_none());
        assert!(store
            .rotate_refresh_token(&old_successor, "cc_1", 3600)
            .unwrap()
            .is_err());

        // Reuse revokes only the compromised old family. The independently
        // approved replacement remains valid and refreshable.
        assert!(store.access_token(&new_access).unwrap().is_some());
        assert!(store
            .rotate_refresh_token(&new_refresh.unwrap(), "cc_1", 3600)
            .unwrap()
            .is_ok());
    }

    #[test]
    fn concurrent_refreshes_within_grace_each_keep_their_session() {
        use std::sync::{Arc, Barrier};

        // Multi-window desktop clients share one token cache: two chat
        // runtimes refresh the same token at the same moment. Both must walk
        // away with a working credential pair, and the family must survive.
        let store = Arc::new(store());
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let barrier = Arc::new(Barrier::new(3));
        let handles = (0..2)
            .map(|_| {
                let store = store.clone();
                let refresh = refresh.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    store
                        .rotate_refresh_token(&refresh, "cc_1", 3600)
                        .unwrap()
                        .unwrap()
                })
            })
            .collect::<Vec<_>>();
        barrier.wait();
        let mut grants = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();
        let second = grants.pop().unwrap();
        let first = grants.pop().unwrap();
        assert_ne!(first.1, second.1, "each caller gets its own successor");
        assert!(store.access_token(&first.0).unwrap().is_some());
        assert!(store.access_token(&second.0).unwrap().is_some());
        // Both successors remain usable; the family is alive.
        assert!(store
            .rotate_refresh_token(&first.1, "cc_1", 3600)
            .unwrap()
            .is_ok());
        assert!(store
            .rotate_refresh_token(&second.1, "cc_1", 3600)
            .unwrap()
            .is_ok());
    }

    #[test]
    fn grace_replay_is_bounded_by_the_successor_budget() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        // The original exchange plus (MAXIMUM_GRACE_SUCCESSORS - 1) peers
        // succeed, for MAXIMUM_GRACE_SUCCESSORS live successors total;
        // grinding past the budget revokes everything.
        let mut last_access = None;
        for _ in 0..MAXIMUM_GRACE_SUCCESSORS {
            let (access, _, _) = store
                .rotate_refresh_token(&refresh, "cc_1", 3600)
                .unwrap()
                .unwrap();
            last_access = Some(access);
        }
        let grinding = store.rotate_refresh_token(&refresh, "cc_1", 3600).unwrap();
        assert!(grinding.is_err());
        assert!(
            store.access_token(&last_access.unwrap()).unwrap().is_none(),
            "the whole family must die once the budget is exceeded"
        );
    }

    #[test]
    fn rotated_children_do_not_free_the_parent_grace_budget_across_bindings() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let builder = store.create_builder_principal("Builder").unwrap();
        let relay_binding = OAuthBinding::device_relay(&device).unwrap();
        let builder_binding = OAuthBinding::builder(&builder).unwrap();
        let client = "cc_shared";
        let relay_parent = store
            .issue_refresh_token_for_binding(&relay_binding, client, "thumble.read", 3600, None)
            .unwrap();
        let builder_parent = store
            .issue_refresh_token_for_binding(&builder_binding, client, "thumble.build", 3600, None)
            .unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute("UPDATE refresh_tokens SET family_id = 'forced-family'", [])
            .unwrap();

        let mut relay_accesses = Vec::new();
        let mut relay_parent_grants = 0;
        for _ in 0..MAXIMUM_GRACE_SUCCESSORS {
            let grant = store
                .rotate_refresh_token_for_resource(&relay_parent, client, ResourceKind::Relay, 3600)
                .unwrap()
                .unwrap();
            relay_parent_grants += 1;
            relay_accesses.push(grant.access_token);
            let child_grant = store
                .rotate_refresh_token_for_resource(
                    &grant.refresh_token,
                    client,
                    ResourceKind::Relay,
                    3600,
                )
                .unwrap()
                .unwrap();
            relay_accesses.push(child_grant.access_token);
        }
        let relay_children: i64 = store
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM refresh_tokens WHERE rotated_from = ?1 \
                 AND principal_kind = 'device' AND principal_id = ?2",
                rusqlite::params![token_digest(&relay_parent), device],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(relay_children, MAXIMUM_GRACE_SUCCESSORS);
        assert_eq!(relay_parent_grants, MAXIMUM_GRACE_SUCCESSORS);
        assert!(store
            .rotate_refresh_token_for_resource(&relay_parent, client, ResourceKind::Relay, 3600,)
            .unwrap()
            .is_err());
        for access in relay_accesses {
            assert!(store.access_token(&access).unwrap().is_none());
        }

        // The builder has the same client and forced family id, but is a
        // separate typed binding and retains its own four-successor budget.
        let mut builder_accesses = Vec::new();
        let mut builder_parent_grants = 0;
        for _ in 0..MAXIMUM_GRACE_SUCCESSORS {
            let grant = store
                .rotate_refresh_token_for_resource(
                    &builder_parent,
                    client,
                    ResourceKind::Builder,
                    3600,
                )
                .unwrap()
                .unwrap();
            builder_parent_grants += 1;
            builder_accesses.push(grant.access_token);
            let child_grant = store
                .rotate_refresh_token_for_resource(
                    &grant.refresh_token,
                    client,
                    ResourceKind::Builder,
                    3600,
                )
                .unwrap()
                .unwrap();
            builder_accesses.push(child_grant.access_token);
        }
        assert_eq!(builder_parent_grants, MAXIMUM_GRACE_SUCCESSORS);
        let (relay_guard, relay_guard_refresh) = store
            .issue_authorization_tokens_for_binding(
                &relay_binding,
                client,
                "thumble.read offline_access",
                900,
                3600,
                true,
            )
            .unwrap();
        assert!(
            store
                .rotate_refresh_token_for_resource(
                    &builder_parent,
                    client,
                    ResourceKind::Builder,
                    3600,
                )
                .unwrap()
                .is_err()
        );
        for access in builder_accesses {
            assert!(store
                .access_token_for_resource(&access, ResourceKind::Builder)
                .unwrap()
                .is_none());
        }
        assert!(store.access_token(&relay_guard).unwrap().is_some());
        assert!(store
            .rotate_refresh_token(&relay_guard_refresh.unwrap(), client, 3600)
            .unwrap()
            .is_ok());
    }

    #[test]
    fn device_revocation_blocks_grace_exchanges() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let (access, _new_refresh, _) = store
            .rotate_refresh_token(&refresh, "cc_1", 3600)
            .unwrap()
            .unwrap();
        store.revoke_device(&device).unwrap();
        // A grace replay must not resurrect a revoked device's session.
        let replay = store.rotate_refresh_token(&refresh, "cc_1", 3600).unwrap();
        assert!(replay.is_err());
        assert!(store.access_token(&access).unwrap().is_none());
    }

    #[test]
    fn concurrent_refresh_replay_cannot_leave_valid_replacements() {
        use std::sync::{Arc, Barrier};

        // With the grace window disabled, exactly one racer wins and the
        // replay still revokes the family — the strict theft policy.
        let store = Arc::new(store().with_refresh_grace(0));
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let barrier = Arc::new(Barrier::new(3));
        let mut handles = Vec::new();
        for _ in 0..2 {
            let store = store.clone();
            let refresh = refresh.clone();
            let barrier = barrier.clone();
            handles.push(std::thread::spawn(move || {
                barrier.wait();
                store.rotate_refresh_token(&refresh, "cc_1", 3600).unwrap()
            }));
        }
        barrier.wait();
        let outcomes = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(outcomes.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(outcomes.iter().filter(|result| result.is_err()).count(), 1);
        let access = outcomes.into_iter().find_map(Result::ok).unwrap().0;
        assert!(store.access_token(&access).unwrap().is_none());
    }

    #[test]
    fn revoke_racing_rotation_cannot_mint_after_revocation() {
        use std::sync::{Arc, Barrier};

        let store = Arc::new(store());
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let barrier = Arc::new(Barrier::new(3));
        let rotation = {
            let store = store.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                store.rotate_refresh_token(&refresh, "cc_1", 3600)
            })
        };
        let revocation = {
            let store = store.clone();
            let device = device.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                store.revoke_device(&device)
            })
        };
        barrier.wait();
        let rotation = rotation.join().unwrap().unwrap();
        revocation.join().unwrap().unwrap();
        if let Ok((access, _, _)) = rotation {
            assert!(store.access_token(&access).unwrap().is_none());
        }
        assert!(store
            .issue_access_token(&device, "thumble.read", 60)
            .is_err());
    }

    #[test]
    fn fresh_schema_and_pragma_migration_are_idempotent() {
        let store = store();
        let mut connection = store.connection.lock().unwrap();
        migrate_schema(&mut connection).unwrap();
        migrate_schema(&mut connection).unwrap();
        for (table, expected) in [
            (
                "authorization_requests",
                vec!["resource_kind", "consent_nonce_digest"],
            ),
            (
                "auth_codes",
                vec!["principal_kind", "principal_id", "resource_kind"],
            ),
            (
                "access_tokens",
                vec![
                    "client_id",
                    "family_id",
                    "principal_kind",
                    "principal_id",
                    "resource_kind",
                ],
            ),
            (
                "refresh_tokens",
                vec![
                    "rotated_at",
                    "family_id",
                    "principal_kind",
                    "principal_id",
                    "resource_kind",
                ],
            ),
        ] {
            let transaction = connection.transaction().unwrap();
            let columns = table_columns(&transaction, table).unwrap();
            transaction.rollback().unwrap();
            for column in expected {
                assert!(columns.contains(column), "missing {table}.{column}");
            }
        }
        let indexes: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' \
                 AND name IN ('auth_codes_binding_idx', 'access_tokens_binding_family_idx', \
                              'access_tokens_client_expiry_idx', \
                              'authorization_requests_client_live_idx', \
                              'auth_codes_client_live_idx', \
                              'refresh_tokens_binding_client_family_idx', \
                              'refresh_tokens_parent_binding_idx', \
                              'refresh_tokens_expiry_idx', \
                              'refresh_tokens_active_binding_idx')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(indexes, 9);
    }

    #[test]
    fn synthetic_legacy_oauth_schema_migrates_and_backfills() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE authorization_requests (
                    request_digest TEXT PRIMARY KEY, client_id TEXT NOT NULL,
                    redirect_uri TEXT NOT NULL, state TEXT NOT NULL, scope TEXT NOT NULL,
                    code_challenge TEXT NOT NULL, expires_at INTEGER NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, used INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE auth_codes (
                    code_digest TEXT PRIMARY KEY, client_id TEXT NOT NULL,
                    redirect_uri TEXT NOT NULL, scope TEXT NOT NULL,
                    code_challenge TEXT NOT NULL, device_id TEXT NOT NULL,
                    expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE access_tokens (
                    token_digest TEXT PRIMARY KEY, device_id TEXT NOT NULL,
                    scope TEXT NOT NULL, expires_at INTEGER NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE refresh_tokens (
                    token_digest TEXT PRIMARY KEY, device_id TEXT NOT NULL,
                    client_id TEXT NOT NULL, scope TEXT NOT NULL,
                    expires_at INTEGER NOT NULL, rotated_from TEXT,
                    revoked INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO authorization_requests VALUES
                    ('legacy-request', 'cc_1', 'https://example.com/cb', 'state',
                     'thumble.read', 'challenge', 9999999999, 0, 0);
                INSERT INTO auth_codes VALUES
                    ('legacy-code', 'cc_1', 'https://example.com/cb', 'thumble.read',
                     'challenge', 'dev_legacy', 9999999999, 0);
                INSERT INTO access_tokens VALUES
                    ('legacy-access', 'dev_legacy', 'thumble.read', 9999999999, 0);
                INSERT INTO refresh_tokens VALUES
                    ('legacy-refresh', 'dev_legacy', 'cc_1', 'thumble.read',
                     9999999999, NULL, 0);",
            )
            .unwrap();
        let store = Store::with_connection(connection, "gateway-test-link-secret-32-bytes-minimum")
            .unwrap();
        let connection = store.connection.lock().unwrap();
        for table in ["auth_codes", "access_tokens", "refresh_tokens"] {
            let (kind, principal_id, resource): (String, String, String) = connection
                .query_row(
                    &format!(
                        "SELECT principal_kind, principal_id, resource_kind FROM {table} LIMIT 1"
                    ),
                    [],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                )
                .unwrap();
            assert_eq!(
                (kind.as_str(), principal_id.as_str(), resource.as_str()),
                ("device", "dev_legacy", "relay")
            );
        }
        let request_resource_column: String = connection
            .query_row(
                "SELECT name FROM pragma_table_info('authorization_requests') \
                 WHERE name = 'resource_kind'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(request_resource_column, "resource_kind");
        let legacy_request: (String, String) = connection
            .query_row(
                "SELECT resource_kind, consent_nonce_digest FROM authorization_requests \
                 WHERE request_digest = 'legacy-request'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(legacy_request, ("relay".to_owned(), String::new()));
    }

    #[test]
    fn failed_migration_rolls_back_schema_and_data_changes() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE authorization_requests (
                    request_digest TEXT PRIMARY KEY, client_id TEXT NOT NULL,
                    redirect_uri TEXT NOT NULL, state TEXT NOT NULL, scope TEXT NOT NULL,
                    code_challenge TEXT NOT NULL, expires_at INTEGER NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, used INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE auth_codes (
                    code_digest TEXT PRIMARY KEY, client_id TEXT NOT NULL,
                    redirect_uri TEXT NOT NULL, scope TEXT NOT NULL,
                    code_challenge TEXT NOT NULL, device_id TEXT NOT NULL,
                    expires_at INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE access_tokens (
                    token_digest TEXT PRIMARY KEY, device_id TEXT NOT NULL,
                    scope TEXT NOT NULL, expires_at INTEGER NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE refresh_tokens (
                    token_digest TEXT PRIMARY KEY, device_id TEXT NOT NULL,
                    client_id TEXT NOT NULL, scope TEXT NOT NULL,
                    expires_at INTEGER NOT NULL, rotated_from TEXT,
                    revoked INTEGER NOT NULL DEFAULT 0
                );
                INSERT INTO access_tokens VALUES
                    ('legacy-access', 'dev_legacy', 'thumble.read', 9999999999, 0);",
            )
            .unwrap();

        let failure = migrate_schema_with_hook(&mut connection, |_| {
            Err("injected migration failure".to_owned())
        });
        assert_eq!(failure.unwrap_err(), "injected migration failure");
        let added_columns: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('access_tokens') \
                 WHERE name IN ('family_id', 'principal_kind', 'principal_id', 'resource_kind')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            added_columns, 0,
            "SQLite DDL must roll back with the transaction"
        );
        let request_columns: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM pragma_table_info('authorization_requests') \
                 WHERE name IN ('resource_kind', 'consent_nonce_digest')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(request_columns, 0, "request migration must also roll back");
        let legacy_device: String = connection
            .query_row(
                "SELECT device_id FROM access_tokens WHERE token_digest = 'legacy-access'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(legacy_device, "dev_legacy");

        migrate_schema(&mut connection).unwrap();
        let migrated: (String, String, String) = connection
            .query_row(
                "SELECT principal_kind, principal_id, resource_kind FROM access_tokens \
                 WHERE token_digest = 'legacy-access'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(
            migrated,
            (
                "device".to_owned(),
                "dev_legacy".to_owned(),
                "relay".to_owned()
            )
        );
    }

    #[test]
    fn phase4_migration_failure_rolls_back_every_schema_and_data_change_and_retries() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("phase4-migration-rollback.db");
        let mut connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE builder_principals (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL,
                    created_at INTEGER NOT NULL, revoked INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE builder_workspaces (
                    principal_id TEXT NOT NULL, session_id TEXT NOT NULL,
                    revision INTEGER NOT NULL, session_json BLOB NOT NULL,
                    byte_count INTEGER NOT NULL, created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL, expires_at INTEGER NOT NULL,
                    PRIMARY KEY (principal_id, session_id)
                );
                INSERT INTO builder_principals VALUES ('bpr_legacy', 'Legacy', 123, 0);
                INSERT INTO builder_workspaces VALUES
                    ('bpr_legacy', 'session-legacy', 7, X'7B7D', 2, 123, 124, 9999999999);",
            )
            .unwrap();

        assert_eq!(
            migrate_schema_with_hook(&mut connection, |_| {
                Err("injected phase4 migration failure".to_owned())
            })
            .unwrap_err(),
            "injected phase4 migration failure"
        );
        for (table, column) in [
            ("builder_principals", "last_seen_at"),
            ("builder_workspaces", "storage_generation"),
            ("access_tokens", "principal_kind"),
        ] {
            let count: i64 = connection
                .query_row(
                    "SELECT COUNT(*) FROM pragma_table_info(?1) WHERE name = ?2",
                    rusqlite::params![table, column],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 0, "rolled back {table}.{column}");
        }
        let phase4_objects: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE name IN
                 ('builder_artifacts', 'builder_shares', 'builder_session_tombstones',
                  'builder_workspaces_expiry_idx', 'access_tokens_binding_family_idx')",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(phase4_objects, 0);
        let legacy: (String, i64, Vec<u8>) = connection
            .query_row(
                "SELECT p.name, w.revision, w.session_json
                 FROM builder_principals p JOIN builder_workspaces w ON w.principal_id = p.id",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(legacy, ("Legacy".to_owned(), 7, b"{}".to_vec()));
        drop(connection);

        // A failed process leaves an ordinary old database that SQLite can
        // reopen and the next gateway startup can migrate transactionally.
        let raw = Connection::open(&path).unwrap();
        assert_eq!(
            raw.query_row("SELECT COUNT(*) FROM builder_principals", [], |row| {
                row.get::<_, i64>(0)
            })
            .unwrap(),
            1
        );
        drop(raw);
        let store = Store::open(&path, "phase4-retry-secret-at-least-32-bytes").unwrap();
        let connection = store.connection.lock().unwrap();
        let migrated: (i64, i64) = connection
            .query_row(
                "SELECT p.last_seen_at, w.storage_generation
                 FROM builder_principals p JOIN builder_workspaces w ON w.principal_id = p.id",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(migrated, (123, 1));
    }

    #[test]
    fn recurring_backfill_repairs_rows_created_by_rolled_back_binaries() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        {
            let connection = store.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO access_tokens \
                     (token_digest, device_id, scope, expires_at, revoked, family_id) \
                     VALUES ('rollback-access', ?1, 'thumble.read', ?2, 0, '')",
                    rusqlite::params![device, Store::now() + 60],
                )
                .unwrap();
            let principal_id: String = connection
                .query_row(
                    "SELECT principal_id FROM access_tokens WHERE token_digest = 'rollback-access'",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            assert!(principal_id.is_empty());
        }
        let mut connection = store.connection.lock().unwrap();
        migrate_schema(&mut connection).unwrap();
        let principal_id: String = connection
            .query_row(
                "SELECT principal_id FROM access_tokens WHERE token_digest = 'rollback-access'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(principal_id, device);
    }

    #[test]
    fn typed_oauth_rows_reject_incompatible_device_projections() {
        let store = store().with_refresh_grace(0);
        let (device, _) = store.create_device("Mac").unwrap();
        let (other_device, _) = store.create_device("Other Mac").unwrap();
        let builder = store.create_builder_principal("Builder").unwrap();
        let device_binding = OAuthBinding::device_relay(&device).unwrap();
        let builder_binding = OAuthBinding::builder(&builder).unwrap();
        let device_guard = store
            .issue_access_token_for_binding(&device_binding, "thumble.read", 900)
            .unwrap();
        let other_guard = store
            .issue_access_token(&other_device, "thumble.read", 900)
            .unwrap();
        let builder_guard = store
            .issue_access_token_for_binding(&builder_binding, "thumble.build", 900)
            .unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute("UPDATE access_tokens SET family_id = 'shared-family'", [])
            .unwrap();
        let (verifier, challenge) = pkce_pair();

        for (binding, incompatible_device_id) in [
            (device_binding, other_device.as_str()),
            (builder_binding, device.as_str()),
        ] {
            let code = store
                .create_auth_code_for_binding(
                    "cc_1",
                    "https://chatgpt.com/cb",
                    "thumble.read offline_access",
                    &challenge,
                    &binding,
                    60,
                )
                .unwrap();
            store
                .connection
                .lock()
                .unwrap()
                .execute(
                    "UPDATE auth_codes SET device_id = ?2 WHERE code_digest = ?1",
                    rusqlite::params![token_digest(&code), incompatible_device_id],
                )
                .unwrap();
            assert!(store
                .consume_auth_code_for_resource(
                    &code,
                    "cc_1",
                    "https://chatgpt.com/cb",
                    &verifier,
                    binding.resource,
                )
                .is_err());
            assert!(store
                .exchange_auth_code_for_resource(
                    &code,
                    "cc_1",
                    "https://chatgpt.com/cb",
                    &verifier,
                    binding.resource,
                    900,
                    3600,
                )
                .is_err());

            let access = store
                .issue_access_token_for_binding(&binding, "thumble.read", 900)
                .unwrap();
            store
                .connection
                .lock()
                .unwrap()
                .execute(
                    "UPDATE access_tokens SET device_id = ?2 WHERE token_digest = ?1",
                    rusqlite::params![token_digest(&access), incompatible_device_id],
                )
                .unwrap();
            assert!(store
                .access_token_for_resource(&access, binding.resource)
                .is_err());

            let refresh = store
                .issue_refresh_token_for_binding(&binding, "cc_1", "thumble.read", 3600, None)
                .unwrap();
            store
                .connection
                .lock()
                .unwrap()
                .execute(
                    "UPDATE refresh_tokens SET device_id = ?2, revoked = 1, \
                     rotated_at = ?3, family_id = 'shared-family' \
                     WHERE token_digest = ?1",
                    rusqlite::params![token_digest(&refresh), incompatible_device_id, Store::now()],
                )
                .unwrap();
            assert!(store
                .rotate_refresh_token_for_resource(&refresh, "cc_1", binding.resource, 3600,)
                .is_err());
        }

        assert!(store.access_token(&device_guard).unwrap().is_some());
        assert!(store.access_token(&other_guard).unwrap().is_some());
        assert!(store
            .access_token_for_resource(&builder_guard, ResourceKind::Builder)
            .unwrap()
            .is_some());
    }

    #[test]
    fn malformed_persisted_binding_is_rejected() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let mixed = OAuthBinding {
            principal: Principal::device(&device).unwrap(),
            resource: ResourceKind::Builder,
        };
        assert!(store
            .issue_access_token_for_binding(&mixed, "thumble.read", 60)
            .is_err());
        let clear = "not-stored-in-cleartext";
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO access_tokens \
                 (token_digest, device_id, scope, expires_at, revoked, family_id, \
                  principal_kind, principal_id, resource_kind) \
                 VALUES (?1, ?2, 'thumble.read', ?3, 0, 'family', 'device', ?2, 'builder')",
                rusqlite::params![token_digest(clear), device, Store::now() + 60],
            )
            .unwrap();
        assert!(store
            .access_token_for_resource(clear, ResourceKind::Builder)
            .is_err());
        let persisted: String = store
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT token_digest FROM access_tokens WHERE device_id = ?1",
                rusqlite::params![device],
                |row| row.get(0),
            )
            .unwrap();
        assert_ne!(persisted, clear);
    }

    #[test]
    fn builder_principal_cap_rejects_sybil_fill() {
        let store = store().with_builder_principal_limit_for_test(2);
        store.create_builder_principal("one").unwrap();
        store.create_builder_principal("two").unwrap();
        let error = store.create_builder_principal("three").unwrap_err();
        assert_eq!(error, "builder principal capacity reached (maximum 2)");
        assert_eq!(
            store
                .connection
                .lock()
                .unwrap()
                .query_row("SELECT COUNT(*) FROM builder_principals", [], |row| row
                    .get::<_, i64>(0))
                .unwrap(),
            2
        );
    }

    #[test]
    fn inactive_principals_with_unexpired_tokens_workspaces_or_artifacts_are_retained() {
        fn make_inactive(store: &Store, builder: &str) {
            store
                .connection
                .lock()
                .unwrap()
                .execute(
                    "UPDATE builder_principals SET last_seen_at = ?2 WHERE id = ?1",
                    rusqlite::params![
                        builder,
                        Store::now() - BUILDER_PRINCIPAL_INACTIVE_SECONDS - 1
                    ],
                )
                .unwrap();
        }

        let access_store = store().with_builder_principal_limit_for_test(1);
        let access_builder = access_store.create_builder_principal("access").unwrap();
        access_store
            .issue_access_token_for_binding(
                &OAuthBinding::builder(&access_builder).unwrap(),
                "thumble.build",
                3600,
            )
            .unwrap();
        make_inactive(&access_store, &access_builder);
        assert!(access_store.create_builder_principal("blocked").is_err());

        let refresh_store = store().with_builder_principal_limit_for_test(1);
        let refresh_builder = refresh_store.create_builder_principal("refresh").unwrap();
        refresh_store
            .issue_refresh_token_for_binding(
                &OAuthBinding::builder(&refresh_builder).unwrap(),
                "cc_builder",
                "thumble.build",
                3600,
                None,
            )
            .unwrap();
        make_inactive(&refresh_store, &refresh_builder);
        assert!(refresh_store.create_builder_principal("blocked").is_err());

        let workspace_store = store().with_builder_principal_limit_for_test(1);
        let workspace_builder = workspace_store
            .create_builder_principal("workspace")
            .unwrap();
        let workspace = thumble_builder::BuilderSession::begin(
            "00000000-0000-4000-8000-000000000301",
            Store::now(),
            3600,
        )
        .unwrap();
        workspace_store
            .create_builder_workspace(&workspace_builder, &workspace)
            .unwrap();
        make_inactive(&workspace_store, &workspace_builder);
        assert!(workspace_store.create_builder_principal("blocked").is_err());

        let artifact_store = store().with_builder_principal_limit_for_test(1);
        let artifact_builder = artifact_store.create_builder_principal("artifact").unwrap();
        let mut session = thumble_builder::BuilderSession::begin(
            "00000000-0000-4000-8000-000000000302",
            Store::now(),
            3600,
        )
        .unwrap();
        let workspace = artifact_store
            .create_builder_workspace(&artifact_builder, &session)
            .unwrap();
        let emission = session
            .emit_artifact(session.revision(), Store::now())
            .unwrap();
        let handoff = session
            .mark_emitted(session.revision(), Store::now())
            .unwrap();
        artifact_store
            .emit_builder_artifact(
                &artifact_builder,
                &session,
                session.revision(),
                workspace.storage_generation,
                &emission,
                &handoff,
            )
            .unwrap();
        make_inactive(&artifact_store, &artifact_builder);
        assert!(artifact_store.create_builder_principal("blocked").is_err());
    }

    #[test]
    fn expired_or_unreferenced_principals_prune_safely_and_recover_capacity() {
        let store = store().with_builder_principal_limit_for_test(2);
        let (device, _) = store.create_device("Relay remains").unwrap();
        let relay_access = store
            .issue_access_token(&device, "thumble.read", 3600)
            .unwrap();
        let stale = store.create_builder_principal("stale").unwrap();
        let retained = store.create_builder_principal("retained").unwrap();
        let stale_refresh = store
            .issue_refresh_token_for_binding(
                &OAuthBinding::builder(&stale).unwrap(),
                "cc_builder",
                "thumble.build",
                -1,
                None,
            )
            .unwrap();
        let stale_refresh_digest = token_digest(&stale_refresh);
        {
            let connection = store.connection.lock().unwrap();
            connection
                .execute(
                    "UPDATE builder_principals SET last_seen_at = ?2 WHERE id = ?1",
                    rusqlite::params![stale, Store::now() - BUILDER_PRINCIPAL_INACTIVE_SECONDS - 1],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO builder_session_tombstones
                     (principal_id, session_id, kind, revision, receipt_json, expires_at)
                     VALUES (?1, 'orphan-check', 'discarded', 1, X'7B7D', ?2)",
                    rusqlite::params![stale, Store::now() + 3600],
                )
                .unwrap();
        }

        let replacement = store.create_builder_principal("replacement").unwrap();
        let connection = store.connection.lock().unwrap();
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM builder_principals WHERE id = ?1",
                    rusqlite::params![stale],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            0
        );
        for (table, predicate) in [
            ("auth_codes", "principal_id"),
            ("access_tokens", "principal_id"),
            ("refresh_tokens", "principal_id"),
            ("builder_workspaces", "principal_id"),
            ("builder_artifacts", "principal_id"),
            ("builder_shares", "principal_id"),
            ("builder_session_tombstones", "principal_id"),
        ] {
            let count: i64 = connection
                .query_row(
                    &format!("SELECT COUNT(*) FROM {table} WHERE {predicate} = ?1"),
                    rusqlite::params![stale],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 0, "orphaned {table}");
        }
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM refresh_tokens WHERE token_digest = ?1",
                    rusqlite::params![stale_refresh_digest],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            0
        );
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM devices WHERE id = ?1",
                    rusqlite::params![device],
                    |row| row.get::<_, i64>(0)
                )
                .unwrap(),
            1
        );
        drop(connection);
        assert!(store.access_token(&relay_access).unwrap().is_some());
        assert!(
            store
                .connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT COUNT(*) FROM builder_principals WHERE id IN (?1, ?2)",
                    rusqlite::params![retained, replacement],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap()
                == 2
        );
    }

    #[test]
    fn successful_builder_access_refresh_and_workspace_operations_touch_last_seen() {
        let store = store();
        let builder = store.create_builder_principal("touch").unwrap();
        let binding = OAuthBinding::builder(&builder).unwrap();
        let access = store
            .issue_access_token_for_binding(&binding, "thumble.build", 3600)
            .unwrap();
        let refresh = store
            .issue_refresh_token_for_binding(&binding, "cc", "thumble.build", 3600, None)
            .unwrap();
        let old = Store::now() - 100;
        let reset = || {
            store
                .connection
                .lock()
                .unwrap()
                .execute(
                    "UPDATE builder_principals SET last_seen_at = ?2 WHERE id = ?1",
                    rusqlite::params![builder, old],
                )
                .unwrap();
        };
        let seen = || {
            store
                .connection
                .lock()
                .unwrap()
                .query_row(
                    "SELECT last_seen_at FROM builder_principals WHERE id = ?1",
                    rusqlite::params![builder],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap()
        };
        reset();
        assert!(store
            .access_token_for_resource(&access, ResourceKind::Builder)
            .unwrap()
            .is_some());
        assert!(seen() > old);
        reset();
        assert!(store
            .rotate_refresh_token_for_resource(&refresh, "cc", ResourceKind::Builder, 3600)
            .unwrap()
            .is_ok());
        assert!(seen() > old);
        reset();
        store
            .begin_builder_workspace(&builder, "00000000-0000-4000-8000-000000000303", Some(3600))
            .unwrap();
        assert!(seen() > old);
    }

    #[test]
    fn builder_authorization_and_exchange_need_zero_devices() {
        let store = store();
        let builder = store.create_builder_principal("Hosted builder").unwrap();
        let device_count: i64 = store
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM devices", [], |row| row.get(0))
            .unwrap();
        assert_eq!(device_count, 0);
        let (verifier, challenge) = pkce_pair();
        let (request, consent_nonce) = store
            .create_builder_authorization_request(
                "cc_builder",
                "https://example.com/cb",
                "state",
                "thumble.build offline_access",
                &challenge,
                60,
            )
            .unwrap();
        assert_eq!(
            store
                .authorization_request(&request)
                .unwrap()
                .unwrap()
                .resource,
            ResourceKind::Builder
        );
        assert!(store
            .complete_builder_authorization(&request, "wrong-consent-nonce", &builder, 60)
            .is_err());
        let code = store
            .complete_builder_authorization(&request, &consent_nonce, &builder, 60)
            .unwrap();
        assert!(store
            .exchange_auth_code(
                &code,
                "cc_builder",
                "https://example.com/cb",
                &verifier,
                900,
                3600
            )
            .unwrap()
            .is_err());
        let grant = store
            .exchange_auth_code_for_resource(
                &code,
                "cc_builder",
                "https://example.com/cb",
                &verifier,
                ResourceKind::Builder,
                900,
                3600,
            )
            .unwrap()
            .unwrap();
        assert_eq!(grant.binding, OAuthBinding::builder(&builder).unwrap());
        assert!(grant.device_id.is_empty());
        assert!(store.access_token(&grant.access_token).unwrap().is_none());
        let access = store
            .access_token_for_resource(&grant.access_token, ResourceKind::Builder)
            .unwrap()
            .unwrap();
        assert_eq!(access.binding, grant.binding);
        let refresh = grant.refresh_token.unwrap();
        assert!(store
            .rotate_refresh_token(&refresh, "cc_builder", 3600)
            .unwrap()
            .is_err());
        let rotated = store
            .rotate_refresh_token_for_resource(&refresh, "cc_builder", ResourceKind::Builder, 3600)
            .unwrap()
            .unwrap();
        assert_eq!(rotated.binding, OAuthBinding::builder(builder).unwrap());
    }

    #[test]
    fn builder_consent_atomically_creates_a_fresh_opaque_principal() {
        let store = store();
        let (verifier, challenge) = pkce_pair();
        let (request, consent_nonce) = store
            .create_builder_authorization_request(
                "cc_builder",
                "https://example.com/cb",
                "state",
                "thumble.build offline_access",
                &challenge,
                60,
            )
            .unwrap();
        let persisted_nonce: String = store
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT consent_nonce_digest FROM authorization_requests \
                 WHERE request_digest = ?1",
                rusqlite::params![token_digest(&request)],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(persisted_nonce, token_digest(&consent_nonce));
        assert_ne!(persisted_nonce, consent_nonce);
        assert!(store
            .complete_new_builder_authorization(&request, "wrong-consent-nonce", 60)
            .unwrap()
            .is_err());
        assert!(store.consume_authorization_request(&request).is_err());
        assert_eq!(
            store
                .connection
                .lock()
                .unwrap()
                .query_row("SELECT COUNT(*) FROM builder_principals", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap(),
            0
        );
        let (code, builder_id, _) = store
            .complete_new_builder_authorization(&request, &consent_nonce, 60)
            .unwrap()
            .unwrap();
        assert!(builder_id.starts_with("bpr_"));
        assert!(store
            .complete_new_builder_authorization(&request, &consent_nonce, 60)
            .unwrap()
            .is_err());
        let grant = store
            .exchange_auth_code_for_resource(
                &code,
                "cc_builder",
                "https://example.com/cb",
                &verifier,
                ResourceKind::Builder,
                900,
                3600,
            )
            .unwrap()
            .unwrap();
        assert_eq!(grant.binding, OAuthBinding::builder(builder_id).unwrap());
        let (expired, expired_nonce) = store
            .create_builder_authorization_request(
                "cc_builder",
                "https://example.com/cb",
                "state",
                "thumble.build",
                &challenge,
                -1,
            )
            .unwrap();
        assert!(store
            .complete_new_builder_authorization(&expired, &expired_nonce, 60)
            .unwrap()
            .is_err());
        let connection = store.connection.lock().unwrap();
        let device_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM devices", [], |row| row.get(0))
            .unwrap();
        let builder_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM builder_principals", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(device_count, 0);
        assert_eq!(builder_count, 1);
    }

    #[test]
    fn builder_revocation_and_reuse_are_isolated_from_relay_families() {
        let store = store().with_refresh_grace(0);
        let (device, _) = store.create_device("Mac").unwrap();
        let builder = store.create_builder_principal("Builder").unwrap();
        let relay_binding = OAuthBinding::device_relay(&device).unwrap();
        let builder_binding = OAuthBinding::builder(&builder).unwrap();
        let relay_access = store
            .issue_access_token_for_binding(&relay_binding, "thumble.read", 900)
            .unwrap();
        let builder_access = store
            .issue_access_token_for_binding(&builder_binding, "thumble.build", 900)
            .unwrap();
        let relay_refresh = store
            .issue_refresh_token_for_binding(
                &relay_binding,
                "cc_shared",
                "thumble.read",
                3600,
                None,
            )
            .unwrap();
        let builder_refresh = store
            .issue_refresh_token_for_binding(
                &builder_binding,
                "cc_shared",
                "thumble.build",
                3600,
                None,
            )
            .unwrap();
        // Even an accidental family-id collision cannot cross the complete
        // principal/resource/client binding used by reuse revocation.
        store
            .connection
            .lock()
            .unwrap()
            .execute("UPDATE refresh_tokens SET family_id = 'forced-family'", [])
            .unwrap();
        let builder_successor = store
            .rotate_refresh_token_for_resource(
                &builder_refresh,
                "cc_shared",
                ResourceKind::Builder,
                3600,
            )
            .unwrap()
            .unwrap();
        assert!(store
            .rotate_refresh_token_for_resource(
                &builder_refresh,
                "cc_shared",
                ResourceKind::Builder,
                3600,
            )
            .unwrap()
            .is_err());
        assert!(store
            .access_token_for_resource(&builder_successor.access_token, ResourceKind::Builder)
            .unwrap()
            .is_none());
        assert!(store.access_token(&relay_access).unwrap().is_some());
        assert!(store
            .rotate_refresh_token(&relay_refresh, "cc_shared", 3600)
            .unwrap()
            .is_ok());

        store.revoke_builder_principal(&builder).unwrap();
        assert!(store
            .access_token_for_resource(&builder_access, ResourceKind::Builder)
            .unwrap()
            .is_none());
        assert!(store.access_token(&relay_access).unwrap().is_some());
        assert!(store.device(&device).unwrap().is_some());
        let rollback_device_id: String = store
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT device_id FROM access_tokens WHERE principal_kind = 'builder' LIMIT 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            rollback_device_id.is_empty(),
            "old binaries must fail closed"
        );
    }

    #[test]
    fn manifests_upsert() {
        let store = store();
        let manifest = ManifestRecord {
            tools: vec![serde_json::json!({"name": "host_status"})],
            resources: vec![],
            instructions: Some("hi".to_owned()),
        };
        store.store_manifest("dev_1", &manifest).unwrap();
        let loaded = store.manifest("dev_1").unwrap().unwrap();
        assert_eq!(loaded.tools.len(), 1);
        assert!(store.manifest("dev_missing").unwrap().is_none());
    }
}
