//! Principal-scoped persistence for hosted builder workspaces and emissions.
//!
//! This module deliberately exposes no owner/global listing APIs. Every mutable
//! operation is bound to one active builder principal, while share reads are
//! authorized only by the opaque artifact id and share token.

use std::fmt;

use rusqlite::{OptionalExtension as _, Transaction};
use thumble_builder::{
    BuilderArtifactEmission, BuilderArtifactReceipt, BuilderDiscardReceipt, BuilderEmissionHandoff,
    BuilderSession, BuilderSessionState, MAXIMUM_BUILDER_SESSION_JSON_BYTES,
    MAXIMUM_BUILDER_SESSION_TTL_SECONDS as BUILDER_CRATE_MAXIMUM_SESSION_TTL_SECONDS,
};
use thumble_core::ProfileArtifact;
use thumble_tunnel::{constant_time_eq, token_digest};

use crate::principal::Principal;
use crate::store::{require_active_principal, touch_builder_principal, Store};

pub const DEFAULT_BUILDER_SESSION_TTL_SECONDS: i64 = 60 * 60;
pub const MAXIMUM_BUILDER_SESSION_TTL_SECONDS: i64 = BUILDER_CRATE_MAXIMUM_SESSION_TTL_SECONDS;
pub const MAXIMUM_ACTIVE_BUILDER_WORKSPACES: i64 = 4;
pub const MAXIMUM_BUILDER_WORKSPACE_BYTES: usize = 18 * 1024 * 1024;
pub const MAXIMUM_BUILDER_WORKSPACE_AGGREGATE_BYTES: i64 = 36 * 1024 * 1024;
pub const MAXIMUM_BUILDER_ARTIFACTS: i64 = 8;
pub const MAXIMUM_BUILDER_ARTIFACT_BYTES: usize = 8 * 1024 * 1024;
pub const MAXIMUM_BUILDER_ARTIFACT_AGGREGATE_BYTES: i64 = 32 * 1024 * 1024;
pub const MAXIMUM_BUILDER_RETENTION_SECONDS: i64 = 24 * 60 * 60;
pub const BUILDER_TOMBSTONE_TTL_SECONDS: i64 = 24 * 60 * 60;
pub const MAXIMUM_BUILDER_TOMBSTONES_PER_PRINCIPAL: i64 = 32;
pub const MAXIMUM_BUILDER_TOMBSTONE_BYTES_PER_PRINCIPAL: i64 = 8 * 1024;
pub const MAXIMUM_GLOBAL_BUILDER_TOMBSTONES: i64 = 10_000;
pub const MAXIMUM_GLOBAL_BUILDER_TOMBSTONE_BYTES: i64 = 80 * 1024 * 1024;
pub const MAXIMUM_GLOBAL_LIVE_BUILDER_BYTES: i64 = 512 * 1024 * 1024;
/// Version of the length-delimited HMAC domains used for deterministic builder
/// artifact IDs and share tokens.
pub const BUILDER_DOMAIN_DERIVATION_VERSION: u32 = 1;
const BUILDER_ARTIFACT_ID_DOMAIN: &[u8] = b"thumble-builder-artifact-id-v1";
const BUILDER_SHARE_TOKEN_DOMAIN: &[u8] = b"thumble-builder-share-token-v1";
const BUILDER_ARTIFACT_ID_BYTES: usize = 4 + 64;
const BUILDER_SHARE_TOKEN_BYTES: usize = 64;
// Both tombstone receipt shapes contain only bounded UUID/hash/integer fields.
// Keeping this bound tight makes workspace-time tombstone reservations useful.
const MAXIMUM_TOMBSTONE_RECEIPT_BYTES: usize = 512;
const BUILDER_PRUNE_BATCH_ROWS: i64 = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuilderQuota {
    WorkspaceCount,
    WorkspaceBytes,
    WorkspaceAggregateBytes,
    ArtifactCount,
    ArtifactBytes,
    ArtifactAggregateBytes,
    TombstoneCount,
    TombstoneBytes,
    GlobalTombstoneCount,
    GlobalTombstoneBytes,
    GlobalLiveBytes,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuilderStoreError {
    NotFound,
    Conflict { expected: u64, actual: Option<u64> },
    StorageGenerationConflict { expected: u64, actual: Option<u64> },
    QuotaExceeded(BuilderQuota),
    InactivePrincipal,
    InvalidInput(String),
    CorruptData(String),
    Storage(String),
}

impl fmt::Display for BuilderStoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotFound => formatter.write_str("builder record not found"),
            Self::Conflict { expected, actual } => match actual {
                Some(actual) => write!(
                    formatter,
                    "builder revision conflict: expected {expected}, actual {actual}"
                ),
                None => write!(formatter, "builder revision conflict: expected {expected}"),
            },
            Self::StorageGenerationConflict { expected, actual } => match actual {
                Some(actual) => write!(
                    formatter,
                    "builder storage generation conflict: expected {expected}, actual {actual}"
                ),
                None => write!(
                    formatter,
                    "builder storage generation conflict: expected {expected}"
                ),
            },
            Self::QuotaExceeded(quota) => write!(formatter, "builder quota exceeded: {quota:?}"),
            Self::InactivePrincipal => formatter.write_str("builder principal is not active"),
            Self::InvalidInput(message) => write!(formatter, "invalid builder input: {message}"),
            Self::CorruptData(message) => write!(formatter, "corrupt builder data: {message}"),
            Self::Storage(message) => write!(formatter, "builder storage failure: {message}"),
        }
    }
}

impl std::error::Error for BuilderStoreError {}

type BuilderResult<T> = Result<T, BuilderStoreError>;

#[derive(Debug, Clone, PartialEq)]
pub struct BuilderWorkspaceRecord {
    pub session: BuilderSession,
    pub storage_generation: u64,
    pub byte_count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuilderDeleteRecord {
    pub session_id: String,
    pub revision: u64,
    pub storage_generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuilderDiscardResult {
    Discarded(BuilderDiscardReceipt),
    Replayed(BuilderDiscardReceipt),
}

#[derive(Clone, PartialEq, Eq)]
pub struct BuilderArtifactRecord {
    pub artifact_id: String,
    pub source_session_id: String,
    pub source_revision: u64,
    pub content_hash: String,
    pub artifact_json: Vec<u8>,
    pub expires_at: i64,
}

#[derive(Clone, PartialEq, Eq)]
pub struct BuilderShareCredential {
    pub artifact_id: String,
    pub share_token: String,
    pub expires_at: i64,
}

#[derive(Clone, PartialEq, Eq)]
pub enum BuilderEmissionResult {
    Emitted {
        artifact: BuilderArtifactRecord,
        share: BuilderShareCredential,
    },
    Replayed {
        artifact: BuilderArtifactRecord,
        share: BuilderShareCredential,
    },
}

#[derive(Clone, PartialEq, Eq)]
pub struct BuilderSharedArtifact {
    pub artifact_id: String,
    pub content_hash: String,
    pub artifact_json: Vec<u8>,
    pub expires_at: i64,
}

impl fmt::Debug for BuilderArtifactRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BuilderArtifactRecord")
            .field("artifact_id", &self.artifact_id)
            .field("source_session_id", &self.source_session_id)
            .field("source_revision", &self.source_revision)
            .field("content_hash", &self.content_hash)
            .field("byte_count", &self.artifact_json.len())
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

impl fmt::Debug for BuilderShareCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BuilderShareCredential")
            .field("artifact_id", &self.artifact_id)
            .field("share_token", &"REDACTED")
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

impl fmt::Debug for BuilderEmissionResult {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Emitted { artifact, share } => formatter
                .debug_struct("BuilderEmissionResult::Emitted")
                .field("artifact", artifact)
                .field("share", share)
                .finish(),
            Self::Replayed { artifact, share } => formatter
                .debug_struct("BuilderEmissionResult::Replayed")
                .field("artifact", artifact)
                .field("share", share)
                .finish(),
        }
    }
}

impl fmt::Debug for BuilderSharedArtifact {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BuilderSharedArtifact")
            .field("artifact_id", &self.artifact_id)
            .field("content_hash", &self.content_hash)
            .field("byte_count", &self.artifact_json.len())
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

#[derive(Debug, Clone, Copy)]
struct WorkspaceCas {
    revision: u64,
    storage_generation: u64,
}

struct WorkspaceRow {
    revision: u64,
    storage_generation: u64,
    session_json: Vec<u8>,
    byte_count: i64,
    created_at: i64,
    updated_at: i64,
    expires_at: i64,
}

fn storage(context: &str, error: impl fmt::Display) -> BuilderStoreError {
    BuilderStoreError::Storage(format!("{context}: {error}"))
}

fn row_revision(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<u64> {
    let value = row.get::<_, i64>(index)?;
    u64::try_from(value).map_err(|_| rusqlite::Error::IntegralValueOutOfRange(index, value))
}

fn sql_revision(revision: u64) -> BuilderResult<i64> {
    i64::try_from(revision).map_err(|_| {
        BuilderStoreError::InvalidInput("revision exceeds SQLite's integer range".to_owned())
    })
}

fn principal(builder_id: &str) -> BuilderResult<Principal> {
    Principal::builder(builder_id.to_owned()).map_err(BuilderStoreError::InvalidInput)
}

fn require_builder(transaction: &Transaction<'_>, builder_id: &str) -> BuilderResult<Principal> {
    let principal = principal(builder_id)?;
    require_active_principal(transaction, &principal)
        .map_err(|_| BuilderStoreError::InactivePrincipal)?;
    touch_builder_principal(transaction, &principal, Store::now())
        .map_err(|_| BuilderStoreError::InactivePrincipal)?;
    Ok(principal)
}

fn prune_expired(transaction: &Transaction<'_>, now: i64) -> BuilderResult<()> {
    transaction
        .execute(
            "DELETE FROM builder_shares WHERE rowid IN (\
                 SELECT s.rowid FROM builder_shares s \
                 WHERE s.expires_at <= ?1 OR s.artifact_id IN \
                     (SELECT artifact_id FROM builder_artifacts WHERE expires_at <= ?1) \
                 LIMIT ?2\
             )",
            rusqlite::params![now, BUILDER_PRUNE_BATCH_ROWS],
        )
        .map_err(|error| storage("prune builder shares", error))?;
    transaction
        .execute(
            "DELETE FROM builder_artifacts WHERE rowid IN (\
                 SELECT a.rowid FROM builder_artifacts a \
                 WHERE a.expires_at <= ?1 \
                   AND a.artifact_id NOT IN (SELECT artifact_id FROM builder_shares) \
                 LIMIT ?2\
             )",
            rusqlite::params![now, BUILDER_PRUNE_BATCH_ROWS],
        )
        .map_err(|error| storage("prune builder artifacts", error))?;
    transaction
        .execute(
            "DELETE FROM builder_workspaces WHERE rowid IN (\
                 SELECT rowid FROM builder_workspaces WHERE expires_at <= ?1 LIMIT ?2\
             )",
            rusqlite::params![now, BUILDER_PRUNE_BATCH_ROWS],
        )
        .map_err(|error| storage("prune builder workspaces", error))?;
    transaction
        .execute(
            "DELETE FROM builder_session_tombstones WHERE rowid IN (\
                 SELECT rowid FROM builder_session_tombstones \
                 WHERE expires_at <= ?1 LIMIT ?2\
             )",
            rusqlite::params![now, BUILDER_PRUNE_BATCH_ROWS],
        )
        .map_err(|error| storage("prune builder tombstones", error))?;
    Ok(())
}

fn query_workspace(
    transaction: &Transaction<'_>,
    builder_id: &str,
    session_id: &str,
) -> BuilderResult<Option<WorkspaceRow>> {
    transaction
        .query_row(
            "SELECT revision, storage_generation, session_json, byte_count, created_at, updated_at, expires_at \
             FROM builder_workspaces WHERE principal_id = ?1 AND session_id = ?2",
            rusqlite::params![builder_id, session_id],
            |row| {
                Ok(WorkspaceRow {
                    revision: row_revision(row, 0)?,
                    storage_generation: row_revision(row, 1)?,
                    session_json: row.get(2)?,
                    byte_count: row.get(3)?,
                    created_at: row.get(4)?,
                    updated_at: row.get(5)?,
                    expires_at: row.get(6)?,
                })
            },
        )
        .optional()
        .map_err(|error| storage("load builder workspace row", error))
}

fn decode_workspace(session_id: &str, row: WorkspaceRow) -> BuilderResult<BuilderWorkspaceRecord> {
    if row.byte_count < 0 || row.byte_count as usize != row.session_json.len() {
        return Err(BuilderStoreError::CorruptData(
            "workspace byte count does not match its BLOB".to_owned(),
        ));
    }
    let session = BuilderSession::decode_json(&row.session_json)
        .map_err(|error| BuilderStoreError::CorruptData(error.to_string()))?;
    if session.session_id() != session_id
        || session.revision() != row.revision
        || session.created_at() != row.created_at
        || session.updated_at() != row.updated_at
        || session.expires_at() != row.expires_at
    {
        return Err(BuilderStoreError::CorruptData(
            "workspace columns do not match decoded session metadata".to_owned(),
        ));
    }
    Ok(BuilderWorkspaceRecord {
        session,
        storage_generation: row.storage_generation,
        byte_count: row.byte_count as usize,
    })
}

fn encode_active_session(session: &BuilderSession, now: i64) -> BuilderResult<Vec<u8>> {
    sql_revision(session.revision())?;
    let bytes = session
        .encode_json()
        .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
    let decoded = BuilderSession::decode_json(&bytes)
        .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
    if decoded != *session {
        return Err(BuilderStoreError::InvalidInput(
            "session did not survive an encode/decode validation round trip".to_owned(),
        ));
    }
    let status = session
        .status(now)
        .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
    if status.state != BuilderSessionState::Active {
        return Err(BuilderStoreError::InvalidInput(
            "workspace session is not active".to_owned(),
        ));
    }
    if bytes.len() > MAXIMUM_BUILDER_WORKSPACE_BYTES
        || bytes.len() > MAXIMUM_BUILDER_SESSION_JSON_BYTES
    {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::WorkspaceBytes,
        ));
    }
    Ok(bytes)
}

fn sum_bytes(transaction: &Transaction<'_>, sql: &str, value: Option<&str>) -> BuilderResult<i64> {
    let result = match value {
        Some(value) => transaction.query_row(sql, rusqlite::params![value], |row| row.get(0)),
        None => transaction.query_row(sql, [], |row| row.get(0)),
    };
    result.map_err(|error| storage("sum builder bytes", error))
}

fn count_rows(transaction: &Transaction<'_>, sql: &str, value: &str) -> BuilderResult<i64> {
    transaction
        .query_row(sql, rusqlite::params![value], |row| row.get(0))
        .map_err(|error| storage("count builder rows", error))
}

fn check_global_bytes(transaction: &Transaction<'_>, delta: i64) -> BuilderResult<()> {
    let total = sum_bytes(
        transaction,
        "SELECT COALESCE((SELECT SUM(byte_count) FROM builder_workspaces), 0) + \
         COALESCE((SELECT SUM(byte_count) FROM builder_artifacts), 0) + \
         COALESCE((SELECT SUM(LENGTH(receipt_json)) FROM builder_session_tombstones), 0)",
        None,
    )?;
    if total
        .checked_add(delta)
        .is_none_or(|value| value > MAXIMUM_GLOBAL_LIVE_BUILDER_BYTES)
    {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::GlobalLiveBytes,
        ));
    }
    Ok(())
}

fn tombstone_usage(
    transaction: &Transaction<'_>,
    builder_id: Option<&str>,
) -> BuilderResult<(i64, i64)> {
    let sql = match builder_id {
        Some(_) => {
            "SELECT COUNT(*), COALESCE(SUM(LENGTH(receipt_json)), 0) \
             FROM builder_session_tombstones WHERE principal_id = ?1"
        }
        None => {
            "SELECT COUNT(*), COALESCE(SUM(LENGTH(receipt_json)), 0) \
             FROM builder_session_tombstones"
        }
    };
    let result = match builder_id {
        Some(builder_id) => transaction.query_row(sql, rusqlite::params![builder_id], |row| {
            Ok((row.get(0)?, row.get(1)?))
        }),
        None => transaction.query_row(sql, [], |row| Ok((row.get(0)?, row.get(1)?))),
    };
    result.map_err(|error| storage("measure builder tombstones", error))
}

fn ensure_tombstone_insert(
    transaction: &Transaction<'_>,
    builder_id: &str,
    receipt_bytes: usize,
) -> BuilderResult<()> {
    let (principal_count, principal_bytes) = tombstone_usage(transaction, Some(builder_id))?;
    if principal_count >= MAXIMUM_BUILDER_TOMBSTONES_PER_PRINCIPAL {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::TombstoneCount,
        ));
    }
    if principal_bytes
        .checked_add(receipt_bytes as i64)
        .is_none_or(|value| value > MAXIMUM_BUILDER_TOMBSTONE_BYTES_PER_PRINCIPAL)
    {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::TombstoneBytes,
        ));
    }
    let (global_count, global_bytes) = tombstone_usage(transaction, None)?;
    if global_count >= MAXIMUM_GLOBAL_BUILDER_TOMBSTONES {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::GlobalTombstoneCount,
        ));
    }
    if global_bytes
        .checked_add(receipt_bytes as i64)
        .is_none_or(|value| value > MAXIMUM_GLOBAL_BUILDER_TOMBSTONE_BYTES)
    {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::GlobalTombstoneBytes,
        ));
    }
    Ok(())
}

fn ensure_tombstone_reservation(
    transaction: &Transaction<'_>,
    builder_id: &str,
) -> BuilderResult<()> {
    let principal_workspaces = count_rows(
        transaction,
        "SELECT COUNT(*) FROM builder_workspaces WHERE principal_id = ?1",
        builder_id,
    )?;
    let (principal_count, principal_bytes) = tombstone_usage(transaction, Some(builder_id))?;
    if principal_count + principal_workspaces + 1 > MAXIMUM_BUILDER_TOMBSTONES_PER_PRINCIPAL {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::TombstoneCount,
        ));
    }
    if principal_bytes + (principal_workspaces + 1) * MAXIMUM_TOMBSTONE_RECEIPT_BYTES as i64
        > MAXIMUM_BUILDER_TOMBSTONE_BYTES_PER_PRINCIPAL
    {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::TombstoneBytes,
        ));
    }
    let global_workspaces =
        sum_bytes(transaction, "SELECT COUNT(*) FROM builder_workspaces", None)?;
    let (global_count, global_bytes) = tombstone_usage(transaction, None)?;
    if global_count + global_workspaces + 1 > MAXIMUM_GLOBAL_BUILDER_TOMBSTONES {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::GlobalTombstoneCount,
        ));
    }
    if global_bytes + (global_workspaces + 1) * MAXIMUM_TOMBSTONE_RECEIPT_BYTES as i64
        > MAXIMUM_GLOBAL_BUILDER_TOMBSTONE_BYTES
    {
        return Err(BuilderStoreError::QuotaExceeded(
            BuilderQuota::GlobalTombstoneBytes,
        ));
    }
    Ok(())
}

fn artifact_identifiers(
    store: &Store,
    builder_id: &str,
    session_id: &str,
    revision: u64,
    content_hash: &str,
) -> (String, String) {
    let revision = revision.to_string();
    let fields = [
        builder_id.as_bytes(),
        session_id.as_bytes(),
        revision.as_bytes(),
        content_hash.as_bytes(),
    ];
    let artifact_id = format!(
        "bar_{}",
        store.builder_hmac_digest(BUILDER_ARTIFACT_ID_DOMAIN, &fields)
    );
    let share_token = store.builder_hmac_digest(BUILDER_SHARE_TOKEN_DOMAIN, &fields);
    (artifact_id, share_token)
}

fn tombstone_receipt<T: serde::Serialize>(receipt: &T) -> BuilderResult<Vec<u8>> {
    let bytes = serde_json::to_vec(receipt)
        .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
    if bytes.len() > MAXIMUM_TOMBSTONE_RECEIPT_BYTES {
        return Err(BuilderStoreError::InvalidInput(
            "builder tombstone receipt is too large".to_owned(),
        ));
    }
    Ok(bytes)
}

fn tombstone(
    transaction: &Transaction<'_>,
    builder_id: &str,
    session_id: &str,
) -> BuilderResult<Option<(String, u64, Vec<u8>)>> {
    transaction
        .query_row(
            "SELECT kind, revision, receipt_json FROM builder_session_tombstones \
             WHERE principal_id = ?1 AND session_id = ?2",
            rusqlite::params![builder_id, session_id],
            |row| Ok((row.get(0)?, row_revision(row, 1)?, row.get(2)?)),
        )
        .optional()
        .map_err(|error| storage("load builder tombstone", error))
}

fn artifact_from_row(
    artifact_id: String,
    source_session_id: String,
    source_revision: u64,
    content_hash: String,
    artifact_json: Vec<u8>,
    byte_count: i64,
    expires_at: i64,
) -> BuilderResult<BuilderArtifactRecord> {
    if byte_count < 0
        || byte_count as usize > MAXIMUM_BUILDER_ARTIFACT_BYTES
        || artifact_json.len() > MAXIMUM_BUILDER_ARTIFACT_BYTES
        || byte_count as usize != artifact_json.len()
    {
        return Err(BuilderStoreError::CorruptData(
            "artifact byte count does not match its BLOB".to_owned(),
        ));
    }
    let decoded = ProfileArtifact::decode_json(&artifact_json)
        .map_err(|error| BuilderStoreError::CorruptData(error.to_string()))?;
    if decoded.content_hash.value != content_hash {
        return Err(BuilderStoreError::CorruptData(
            "artifact content hash does not match its column".to_owned(),
        ));
    }
    Ok(BuilderArtifactRecord {
        artifact_id,
        source_session_id,
        source_revision,
        content_hash,
        artifact_json,
        expires_at,
    })
}

fn query_source_artifact(
    transaction: &Transaction<'_>,
    builder_id: &str,
    session_id: &str,
    revision: u64,
) -> BuilderResult<Option<BuilderArtifactRecord>> {
    let row = transaction
        .query_row(
            "SELECT artifact_id, source_session_id, source_revision, content_hash, \
                    artifact_json, byte_count, expires_at \
             FROM builder_artifacts WHERE principal_id = ?1 \
               AND source_session_id = ?2 AND source_revision = ?3",
            rusqlite::params![builder_id, session_id, sql_revision(revision)?],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row_revision(row, 2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, Vec<u8>>(4)?,
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            },
        )
        .optional()
        .map_err(|error| storage("load builder artifact", error))?;
    row.map(|row| artifact_from_row(row.0, row.1, row.2, row.3, row.4, row.5, row.6))
        .transpose()
}

fn existing_emission(
    transaction: &Transaction<'_>,
    store: &Store,
    builder_id: &str,
    session_id: &str,
    revision: u64,
    content_hash: &str,
    artifact_json: &[u8],
) -> BuilderResult<Option<(BuilderArtifactRecord, BuilderShareCredential)>> {
    let Some(artifact) = query_source_artifact(transaction, builder_id, session_id, revision)?
    else {
        return Ok(None);
    };
    let (expected_id, share_token) =
        artifact_identifiers(store, builder_id, session_id, revision, content_hash);
    if artifact.artifact_id != expected_id
        || artifact.content_hash != content_hash
        || artifact.artifact_json != artifact_json
    {
        return Err(BuilderStoreError::Conflict {
            expected: revision,
            actual: Some(artifact.source_revision),
        });
    }
    let share = transaction
        .query_row(
            "SELECT token_digest, expires_at, revoked FROM builder_shares \
             WHERE artifact_id = ?1 AND principal_id = ?2",
            rusqlite::params![artifact.artifact_id, builder_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                ))
            },
        )
        .optional()
        .map_err(|error| storage("load builder artifact share", error))?
        .ok_or_else(|| {
            BuilderStoreError::CorruptData("artifact is missing its atomic share row".to_owned())
        })?;
    if share.2 != 0
        || share.1 != artifact.expires_at
        || !constant_time_eq(share.0.as_bytes(), token_digest(&share_token).as_bytes())
    {
        return Err(BuilderStoreError::CorruptData(
            "artifact share row does not match deterministic credential".to_owned(),
        ));
    }
    // The caller's receipt hash is the source receipt for this replay; the
    // decoded embedded hash was checked by `artifact_from_row` above.
    if artifact.content_hash != content_hash {
        return Err(BuilderStoreError::CorruptData(
            "artifact content hash does not match its source receipt".to_owned(),
        ));
    }
    let credential = BuilderShareCredential {
        artifact_id: artifact.artifact_id.clone(),
        share_token,
        expires_at: share.1,
    };
    Ok(Some((artifact, credential)))
}

impl Store {
    /// Removes one bounded batch of expired builder rows. Callers may invoke
    /// this idempotently from startup or a periodic maintenance task.
    pub fn prune_builder_storage(&self) -> BuilderResult<()> {
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin builder storage pruning", error))?;
        prune_expired(&transaction, now)?;
        transaction
            .commit()
            .map_err(|error| storage("commit builder storage pruning", error))
    }

    pub fn begin_builder_workspace(
        &self,
        builder_id: &str,
        session_id: &str,
        ttl_seconds: Option<i64>,
    ) -> BuilderResult<BuilderWorkspaceRecord> {
        let now = Self::now();
        let session = BuilderSession::begin(
            session_id,
            now,
            ttl_seconds.unwrap_or(DEFAULT_BUILDER_SESSION_TTL_SECONDS),
        )
        .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
        self.create_builder_workspace(builder_id, &session)
    }

    pub fn create_builder_workspace(
        &self,
        builder_id: &str,
        session: &BuilderSession,
    ) -> BuilderResult<BuilderWorkspaceRecord> {
        let now = Self::now();
        let bytes = encode_active_session(session, now)?;
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin builder workspace creation", error))?;
        require_builder(&transaction, builder_id)?;
        prune_expired(&transaction, now)?;
        if let Some(row) = query_workspace(&transaction, builder_id, session.session_id())? {
            return Err(BuilderStoreError::Conflict {
                expected: session.revision(),
                actual: Some(row.revision),
            });
        }
        if let Some((_, revision, _)) = tombstone(&transaction, builder_id, session.session_id())? {
            return Err(BuilderStoreError::Conflict {
                expected: session.revision(),
                actual: Some(revision),
            });
        }
        // Reserve bounded count/bytes for the terminal receipt this live
        // workspace will eventually require.
        ensure_tombstone_reservation(&transaction, builder_id)?;
        let count = count_rows(
            &transaction,
            "SELECT COUNT(*) FROM builder_workspaces WHERE principal_id = ?1",
            builder_id,
        )?;
        if count >= MAXIMUM_ACTIVE_BUILDER_WORKSPACES {
            return Err(BuilderStoreError::QuotaExceeded(
                BuilderQuota::WorkspaceCount,
            ));
        }
        let aggregate = sum_bytes(
            &transaction,
            "SELECT COALESCE(SUM(byte_count), 0) FROM builder_workspaces WHERE principal_id = ?1",
            Some(builder_id),
        )?;
        if aggregate + bytes.len() as i64 > MAXIMUM_BUILDER_WORKSPACE_AGGREGATE_BYTES {
            return Err(BuilderStoreError::QuotaExceeded(
                BuilderQuota::WorkspaceAggregateBytes,
            ));
        }
        check_global_bytes(&transaction, bytes.len() as i64)?;
        transaction
            .execute(
                "INSERT INTO builder_workspaces \
                 (principal_id, session_id, revision, storage_generation, session_json, byte_count, created_at, updated_at, expires_at) \
                 VALUES (?1, ?2, ?3, 1, ?4, ?5, ?6, ?7, ?8)",
                rusqlite::params![
                    builder_id,
                    session.session_id(),
                    sql_revision(session.revision())?,
                    bytes,
                    bytes.len() as i64,
                    session.created_at(),
                    session.updated_at(),
                    session.expires_at(),
                ],
            )
            .map_err(|error| storage("insert builder workspace", error))?;
        transaction
            .commit()
            .map_err(|error| storage("commit builder workspace creation", error))?;
        Ok(BuilderWorkspaceRecord {
            session: session.clone(),
            storage_generation: 1,
            byte_count: bytes.len(),
        })
    }

    pub fn load_builder_workspace(
        &self,
        builder_id: &str,
        session_id: &str,
    ) -> BuilderResult<BuilderWorkspaceRecord> {
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin builder workspace load", error))?;
        require_builder(&transaction, builder_id)?;
        prune_expired(&transaction, now)?;
        let row = query_workspace(&transaction, builder_id, session_id)?
            .ok_or(BuilderStoreError::NotFound)?;
        let record = decode_workspace(session_id, row)?;
        transaction
            .commit()
            .map_err(|error| storage("commit builder workspace load", error))?;
        Ok(record)
    }

    pub fn save_builder_workspace(
        &self,
        builder_id: &str,
        expected_revision: u64,
        expected_storage_generation: u64,
        session: &BuilderSession,
    ) -> BuilderResult<BuilderWorkspaceRecord> {
        let now = Self::now();
        let bytes = encode_active_session(session, now)?;
        if session.revision() < expected_revision {
            return Err(BuilderStoreError::InvalidInput(
                "saved session revision precedes the CAS revision".to_owned(),
            ));
        }
        let next_storage_generation =
            expected_storage_generation.checked_add(1).ok_or_else(|| {
                BuilderStoreError::InvalidInput("storage generation overflow".to_owned())
            })?;
        sql_revision(expected_storage_generation)?;
        sql_revision(next_storage_generation)?;
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin builder workspace save", error))?;
        require_builder(&transaction, builder_id)?;
        prune_expired(&transaction, now)?;
        let row = query_workspace(&transaction, builder_id, session.session_id())?
            .ok_or(BuilderStoreError::NotFound)?;
        if row.revision != expected_revision {
            return Err(BuilderStoreError::Conflict {
                expected: expected_revision,
                actual: Some(row.revision),
            });
        }
        if row.storage_generation != expected_storage_generation {
            return Err(BuilderStoreError::StorageGenerationConflict {
                expected: expected_storage_generation,
                actual: Some(row.storage_generation),
            });
        }
        let old = decode_workspace(session.session_id(), row)?;
        if old.session.created_at() != session.created_at()
            || old.session.expires_at() != session.expires_at()
            || session.updated_at() < old.session.updated_at()
        {
            return Err(BuilderStoreError::InvalidInput(
                "saved session changed immutable or monotonic metadata".to_owned(),
            ));
        }
        let delta = bytes.len() as i64 - old.byte_count as i64;
        let aggregate = sum_bytes(
            &transaction,
            "SELECT COALESCE(SUM(byte_count), 0) FROM builder_workspaces WHERE principal_id = ?1",
            Some(builder_id),
        )?;
        if aggregate + delta > MAXIMUM_BUILDER_WORKSPACE_AGGREGATE_BYTES {
            return Err(BuilderStoreError::QuotaExceeded(
                BuilderQuota::WorkspaceAggregateBytes,
            ));
        }
        check_global_bytes(&transaction, delta)?;
        let changed = transaction
            .execute(
                "UPDATE builder_workspaces SET revision = ?5, storage_generation = ?6, session_json = ?7, byte_count = ?8, \
                 updated_at = ?9, expires_at = ?10 WHERE principal_id = ?1 AND session_id = ?2 \
                 AND revision = ?3 AND storage_generation = ?4",
                rusqlite::params![
                    builder_id,
                    session.session_id(),
                    sql_revision(expected_revision)?,
                    sql_revision(expected_storage_generation)?,
                    sql_revision(session.revision())?,
                    sql_revision(next_storage_generation)?,
                    bytes,
                    bytes.len() as i64,
                    session.updated_at(),
                    session.expires_at(),
                ],
            )
            .map_err(|error| storage("CAS save builder workspace", error))?;
        if changed != 1 {
            let actual = query_workspace(&transaction, builder_id, session.session_id())?;
            if actual
                .as_ref()
                .is_some_and(|row| row.revision != expected_revision)
            {
                return Err(BuilderStoreError::Conflict {
                    expected: expected_revision,
                    actual: actual.map(|row| row.revision),
                });
            }
            return Err(BuilderStoreError::StorageGenerationConflict {
                expected: expected_storage_generation,
                actual: actual.map(|row| row.storage_generation),
            });
        }
        transaction
            .commit()
            .map_err(|error| storage("commit builder workspace save", error))?;
        Ok(BuilderWorkspaceRecord {
            session: session.clone(),
            storage_generation: next_storage_generation,
            byte_count: bytes.len(),
        })
    }

    pub fn delete_builder_workspace(
        &self,
        builder_id: &str,
        session_id: &str,
        expected_revision: u64,
        expected_storage_generation: u64,
    ) -> BuilderResult<BuilderDeleteRecord> {
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin builder workspace deletion", error))?;
        require_builder(&transaction, builder_id)?;
        prune_expired(&transaction, now)?;
        let Some(row) = query_workspace(&transaction, builder_id, session_id)? else {
            return Err(BuilderStoreError::NotFound);
        };
        if row.revision != expected_revision {
            return Err(BuilderStoreError::Conflict {
                expected: expected_revision,
                actual: Some(row.revision),
            });
        }
        if row.storage_generation != expected_storage_generation {
            return Err(BuilderStoreError::StorageGenerationConflict {
                expected: expected_storage_generation,
                actual: Some(row.storage_generation),
            });
        }
        decode_workspace(session_id, row)?;
        let changed = transaction
            .execute(
                "DELETE FROM builder_workspaces WHERE principal_id = ?1 AND session_id = ?2 \
                 AND revision = ?3 AND storage_generation = ?4",
                rusqlite::params![
                    builder_id,
                    session_id,
                    sql_revision(expected_revision)?,
                    sql_revision(expected_storage_generation)?
                ],
            )
            .map_err(|error| storage("CAS delete builder workspace", error))?;
        if changed != 1 {
            return Err(BuilderStoreError::Conflict {
                expected: expected_revision,
                actual: query_workspace(&transaction, builder_id, session_id)?
                    .map(|row| row.revision),
            });
        }
        transaction
            .commit()
            .map_err(|error| storage("commit builder workspace deletion", error))?;
        Ok(BuilderDeleteRecord {
            session_id: session_id.to_owned(),
            revision: expected_revision,
            storage_generation: expected_storage_generation,
        })
    }

    pub fn discard_builder_workspace(
        &self,
        builder_id: &str,
        session_id: &str,
        expected_revision: u64,
        expected_storage_generation: Option<u64>,
    ) -> BuilderResult<BuilderDiscardResult> {
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin builder workspace discard", error))?;
        require_builder(&transaction, builder_id)?;
        prune_expired(&transaction, now)?;
        let Some(row) = query_workspace(&transaction, builder_id, session_id)? else {
            let Some((kind, revision, receipt_json)) =
                tombstone(&transaction, builder_id, session_id)?
            else {
                return Err(BuilderStoreError::NotFound);
            };
            if revision != expected_revision || kind != "discarded" {
                return Err(BuilderStoreError::Conflict {
                    expected: expected_revision,
                    actual: Some(revision),
                });
            }
            let receipt: BuilderDiscardReceipt = serde_json::from_slice(&receipt_json)
                .map_err(|error| BuilderStoreError::CorruptData(error.to_string()))?;
            if receipt.session_id != session_id || receipt.revision != revision {
                return Err(BuilderStoreError::CorruptData(
                    "discard tombstone metadata mismatch".to_owned(),
                ));
            }
            transaction
                .commit()
                .map_err(|error| storage("commit builder discard replay", error))?;
            return Ok(BuilderDiscardResult::Replayed(receipt));
        };
        if row.revision != expected_revision {
            return Err(BuilderStoreError::Conflict {
                expected: expected_revision,
                actual: Some(row.revision),
            });
        }
        let expected_storage_generation = expected_storage_generation.ok_or_else(|| {
            BuilderStoreError::InvalidInput(
                "live builder discard requires a loaded storage generation".to_owned(),
            )
        })?;
        if row.storage_generation != expected_storage_generation {
            return Err(BuilderStoreError::StorageGenerationConflict {
                expected: expected_storage_generation,
                actual: Some(row.storage_generation),
            });
        }
        let workspace_bytes = row.byte_count;
        let mut session = decode_workspace(session_id, row)?.session;
        let receipt = session
            .discard(expected_revision, now)
            .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
        let receipt_json = tombstone_receipt(&receipt)?;
        ensure_tombstone_insert(&transaction, builder_id, receipt_json.len())?;
        check_global_bytes(&transaction, receipt_json.len() as i64 - workspace_bytes)?;
        let deleted = transaction
            .execute(
                "DELETE FROM builder_workspaces WHERE principal_id = ?1 AND session_id = ?2 \
                 AND revision = ?3 AND storage_generation = ?4",
                rusqlite::params![
                    builder_id,
                    session_id,
                    sql_revision(expected_revision)?,
                    sql_revision(expected_storage_generation)?
                ],
            )
            .map_err(|error| storage("delete discarded builder workspace", error))?;
        if deleted != 1 {
            return Err(BuilderStoreError::Conflict {
                expected: expected_revision,
                actual: query_workspace(&transaction, builder_id, session_id)?
                    .map(|row| row.revision),
            });
        }
        transaction
            .execute(
                "INSERT INTO builder_session_tombstones \
                 (principal_id, session_id, kind, revision, receipt_json, expires_at) \
                 VALUES (?1, ?2, 'discarded', ?3, ?4, ?5)",
                rusqlite::params![
                    builder_id,
                    session_id,
                    sql_revision(expected_revision)?,
                    receipt_json,
                    now + BUILDER_TOMBSTONE_TTL_SECONDS,
                ],
            )
            .map_err(|error| storage("insert builder discard tombstone", error))?;
        transaction
            .commit()
            .map_err(|error| storage("commit builder workspace discard", error))?;
        Ok(BuilderDiscardResult::Discarded(receipt))
    }

    pub fn emit_builder_artifact(
        &self,
        builder_id: &str,
        session: &BuilderSession,
        expected_revision: u64,
        expected_storage_generation: u64,
        emission: &BuilderArtifactEmission,
        handoff: &BuilderEmissionHandoff,
    ) -> BuilderResult<BuilderEmissionResult> {
        self.emit_builder_artifact_with_hook(
            builder_id,
            session,
            WorkspaceCas {
                revision: expected_revision,
                storage_generation: expected_storage_generation,
            },
            emission,
            handoff,
            |_| Ok(()),
        )
    }

    fn emit_builder_artifact_with_hook<F>(
        &self,
        builder_id: &str,
        session: &BuilderSession,
        cas: WorkspaceCas,
        emission: &BuilderArtifactEmission,
        handoff: &BuilderEmissionHandoff,
        hook: F,
    ) -> BuilderResult<BuilderEmissionResult>
    where
        F: FnOnce(&Transaction<'_>) -> BuilderResult<()>,
    {
        let expected_revision = cas.revision;
        let expected_storage_generation = cas.storage_generation;
        if expected_revision != session.revision()
            || emission.receipt.session_id != session.session_id()
            || emission.receipt.revision != expected_revision
            || handoff.session_id != session.session_id()
            || handoff.revision != expected_revision
            || handoff.content_hash != emission.receipt.content_hash
            || !handoff.delete_session
        {
            return Err(BuilderStoreError::InvalidInput(
                "emission source, receipt, and deletion handoff do not match".to_owned(),
            ));
        }
        let encoded = session
            .encode_json()
            .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
        let decoded = BuilderSession::decode_json(&encoded)
            .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
        if decoded != *session {
            return Err(BuilderStoreError::InvalidInput(
                "emitted session failed encode/decode validation".to_owned(),
            ));
        }
        let mut regenerated_session = session.clone();
        let regenerated = regenerated_session
            .emit_artifact(expected_revision, emission.receipt.emitted_at)
            .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
        let regenerated_handoff = regenerated_session
            .mark_emitted(expected_revision, emission.receipt.emitted_at)
            .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
        if regenerated != *emission || regenerated_handoff != *handoff {
            return Err(BuilderStoreError::InvalidInput(
                "artifact bytes, content hash, or receipt do not match the session".to_owned(),
            ));
        }
        let artifact_json = emission.artifact_json.as_bytes();
        if artifact_json.len() > MAXIMUM_BUILDER_ARTIFACT_BYTES {
            return Err(BuilderStoreError::QuotaExceeded(
                BuilderQuota::ArtifactBytes,
            ));
        }
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin atomic builder emission", error))?;
        require_builder(&transaction, builder_id)?;
        prune_expired(&transaction, now)?;

        let workspace = query_workspace(&transaction, builder_id, session.session_id())?;
        if workspace.is_none() {
            let Some((kind, revision, receipt_json)) =
                tombstone(&transaction, builder_id, session.session_id())?
            else {
                return Err(BuilderStoreError::NotFound);
            };
            if kind != "emitted" || revision != expected_revision {
                return Err(BuilderStoreError::Conflict {
                    expected: expected_revision,
                    actual: Some(revision),
                });
            }
            let receipt: BuilderArtifactReceipt = serde_json::from_slice(&receipt_json)
                .map_err(|error| BuilderStoreError::CorruptData(error.to_string()))?;
            if receipt != emission.receipt {
                return Err(BuilderStoreError::Conflict {
                    expected: expected_revision,
                    actual: Some(revision),
                });
            }
            let existing = existing_emission(
                &transaction,
                self,
                builder_id,
                session.session_id(),
                expected_revision,
                &emission.receipt.content_hash,
                artifact_json,
            )?
            .ok_or_else(|| {
                BuilderStoreError::CorruptData(
                    "emission tombstone is missing its artifact".to_owned(),
                )
            })?;
            transaction
                .commit()
                .map_err(|error| storage("commit builder emission replay", error))?;
            return Ok(BuilderEmissionResult::Replayed {
                artifact: existing.0,
                share: existing.1,
            });
        }

        let row = workspace.expect("checked above");
        if row.revision != expected_revision {
            return Err(BuilderStoreError::Conflict {
                expected: expected_revision,
                actual: Some(row.revision),
            });
        }
        if row.storage_generation != expected_storage_generation {
            return Err(BuilderStoreError::StorageGenerationConflict {
                expected: expected_storage_generation,
                actual: Some(row.storage_generation),
            });
        }
        let workspace_bytes = row.byte_count;
        let mut persisted = decode_workspace(session.session_id(), row)?.session;
        let persisted_emission = persisted
            .emit_artifact(expected_revision, emission.receipt.emitted_at)
            .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
        let persisted_handoff = persisted
            .mark_emitted(expected_revision, emission.receipt.emitted_at)
            .map_err(|error| BuilderStoreError::InvalidInput(error.to_string()))?;
        if persisted != *session || persisted_emission != *emission || persisted_handoff != *handoff
        {
            return Err(BuilderStoreError::InvalidInput(
                "loaded workspace does not match the emission handoff".to_owned(),
            ));
        }

        if let Some(existing) = existing_emission(
            &transaction,
            self,
            builder_id,
            session.session_id(),
            expected_revision,
            &emission.receipt.content_hash,
            artifact_json,
        )? {
            return Err(BuilderStoreError::CorruptData(format!(
                "artifact {} exists while its source workspace is still live",
                existing.0.artifact_id
            )));
        }
        let artifact_count = count_rows(
            &transaction,
            "SELECT COUNT(*) FROM builder_artifacts WHERE principal_id = ?1",
            builder_id,
        )?;
        if artifact_count >= MAXIMUM_BUILDER_ARTIFACTS {
            return Err(BuilderStoreError::QuotaExceeded(
                BuilderQuota::ArtifactCount,
            ));
        }
        let aggregate = sum_bytes(
            &transaction,
            "SELECT COALESCE(SUM(byte_count), 0) FROM builder_artifacts WHERE principal_id = ?1",
            Some(builder_id),
        )?;
        if aggregate + artifact_json.len() as i64 > MAXIMUM_BUILDER_ARTIFACT_AGGREGATE_BYTES {
            return Err(BuilderStoreError::QuotaExceeded(
                BuilderQuota::ArtifactAggregateBytes,
            ));
        }
        let receipt_json = tombstone_receipt(&emission.receipt)?;
        ensure_tombstone_insert(&transaction, builder_id, receipt_json.len())?;
        check_global_bytes(
            &transaction,
            artifact_json.len() as i64 + receipt_json.len() as i64 - workspace_bytes,
        )?;
        let (artifact_id, share_token) = artifact_identifiers(
            self,
            builder_id,
            session.session_id(),
            expected_revision,
            &emission.receipt.content_hash,
        );
        let expires_at = now + MAXIMUM_BUILDER_RETENTION_SECONDS;
        transaction
            .execute(
                "INSERT INTO builder_artifacts \
                 (principal_id, artifact_id, source_session_id, source_revision, content_hash, \
                  artifact_json, byte_count, created_at, expires_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                rusqlite::params![
                    builder_id,
                    artifact_id,
                    session.session_id(),
                    sql_revision(expected_revision)?,
                    emission.receipt.content_hash,
                    artifact_json,
                    artifact_json.len() as i64,
                    now,
                    expires_at,
                ],
            )
            .map_err(|error| storage("insert builder artifact", error))?;
        transaction
            .execute(
                "INSERT INTO builder_shares \
                 (artifact_id, principal_id, token_digest, created_at, expires_at, revoked) \
                 VALUES (?1, ?2, ?3, ?4, ?5, 0)",
                rusqlite::params![
                    artifact_id,
                    builder_id,
                    token_digest(&share_token),
                    now,
                    expires_at,
                ],
            )
            .map_err(|error| storage("insert builder share", error))?;
        hook(&transaction)?;
        let deleted = transaction
            .execute(
                "DELETE FROM builder_workspaces WHERE principal_id = ?1 AND session_id = ?2 \
                 AND revision = ?3 AND storage_generation = ?4",
                rusqlite::params![
                    builder_id,
                    session.session_id(),
                    sql_revision(expected_revision)?,
                    sql_revision(expected_storage_generation)?
                ],
            )
            .map_err(|error| storage("delete emitted builder workspace", error))?;
        if deleted != 1 {
            return Err(BuilderStoreError::Conflict {
                expected: expected_revision,
                actual: query_workspace(&transaction, builder_id, session.session_id())?
                    .map(|row| row.revision),
            });
        }
        transaction
            .execute(
                "INSERT INTO builder_session_tombstones \
                 (principal_id, session_id, kind, revision, receipt_json, expires_at) \
                 VALUES (?1, ?2, 'emitted', ?3, ?4, ?5)",
                rusqlite::params![
                    builder_id,
                    session.session_id(),
                    sql_revision(expected_revision)?,
                    receipt_json,
                    now + BUILDER_TOMBSTONE_TTL_SECONDS,
                ],
            )
            .map_err(|error| storage("insert builder emission tombstone", error))?;
        transaction
            .commit()
            .map_err(|error| storage("commit atomic builder emission", error))?;
        let artifact = BuilderArtifactRecord {
            artifact_id: artifact_id.clone(),
            source_session_id: session.session_id().to_owned(),
            source_revision: expected_revision,
            content_hash: emission.receipt.content_hash.clone(),
            artifact_json: artifact_json.to_vec(),
            expires_at,
        };
        Ok(BuilderEmissionResult::Emitted {
            artifact,
            share: BuilderShareCredential {
                artifact_id,
                share_token,
                expires_at,
            },
        })
    }

    /// Recover the exact terminal emission after the source workspace has been
    /// atomically deleted. This is principal scoped and returns no global
    /// listing surface; it exists solely to make MCP emission retries replay
    /// the Stage B tombstone receipt.
    pub fn replay_builder_emission(
        &self,
        builder_id: &str,
        session_id: &str,
        expected_revision: u64,
    ) -> BuilderResult<BuilderEmissionResult> {
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin builder emission replay", error))?;
        require_builder(&transaction, builder_id)?;
        prune_expired(&transaction, now)?;
        if let Some(row) = query_workspace(&transaction, builder_id, session_id)? {
            return Err(BuilderStoreError::Conflict {
                expected: expected_revision,
                actual: Some(row.revision),
            });
        }
        let Some((kind, revision, receipt_json)) = tombstone(&transaction, builder_id, session_id)?
        else {
            return Err(BuilderStoreError::NotFound);
        };
        if kind != "emitted" || revision != expected_revision {
            return Err(BuilderStoreError::Conflict {
                expected: expected_revision,
                actual: Some(revision),
            });
        }
        let receipt: BuilderArtifactReceipt = serde_json::from_slice(&receipt_json)
            .map_err(|error| BuilderStoreError::CorruptData(error.to_string()))?;
        if receipt.session_id != session_id
            || receipt.revision != revision
            || receipt.content_hash.len() != 64
        {
            return Err(BuilderStoreError::CorruptData(
                "emission tombstone metadata mismatch".to_owned(),
            ));
        }
        let artifact =
            query_source_artifact(&transaction, builder_id, session_id, expected_revision)?
                .ok_or_else(|| {
                    BuilderStoreError::CorruptData(
                        "emission tombstone is missing its artifact".to_owned(),
                    )
                })?;
        if artifact.content_hash != receipt.content_hash {
            return Err(BuilderStoreError::CorruptData(
                "emission receipt hash does not match its artifact".to_owned(),
            ));
        }
        let existing = existing_emission(
            &transaction,
            self,
            builder_id,
            session_id,
            expected_revision,
            &receipt.content_hash,
            &artifact.artifact_json,
        )?
        .ok_or_else(|| {
            BuilderStoreError::CorruptData("emission tombstone is missing its share".to_owned())
        })?;
        transaction
            .commit()
            .map_err(|error| storage("commit builder emission replay", error))?;
        Ok(BuilderEmissionResult::Replayed {
            artifact: existing.0,
            share: existing.1,
        })
    }

    pub fn lookup_builder_share(
        &self,
        artifact_id: &str,
        share_token: &str,
    ) -> BuilderResult<Option<BuilderSharedArtifact>> {
        // Reject malformed credentials before any indexed lookup or digest work.
        if artifact_id.len() != BUILDER_ARTIFACT_ID_BYTES
            || share_token.len() != BUILDER_SHARE_TOKEN_BYTES
        {
            return Ok(None);
        }
        let now = Self::now();
        let presented_digest = token_digest(share_token);
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin builder share lookup", error))?;
        prune_expired(&transaction, now)?;

        // Authenticate from small metadata only. Do not materialize the
        // attacker-selected artifact BLOB until all credential checks pass.
        let metadata = transaction
            .query_row(
                "SELECT s.token_digest, s.principal_id, s.expires_at, s.revoked, p.revoked, \
                        a.byte_count, length(a.artifact_json) \
                 FROM builder_shares s JOIN builder_principals p ON p.id = s.principal_id \
                 JOIN builder_artifacts a ON a.artifact_id = s.artifact_id \
                    AND a.principal_id = s.principal_id \
                 WHERE s.artifact_id = ?1",
                rusqlite::params![artifact_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                        row.get::<_, i64>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, i64>(6)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| storage("lookup builder share metadata", error))?;
        let Some((
            digest,
            principal_id,
            expires_at,
            share_revoked,
            principal_revoked,
            byte_count,
            sql_blob_length,
        )) = metadata
        else {
            transaction
                .commit()
                .map_err(|error| storage("commit missing builder share lookup", error))?;
            return Ok(None);
        };
        if share_revoked != 0
            || principal_revoked != 0
            || expires_at <= now
            || digest.len() != 64
            || byte_count < 0
            || sql_blob_length < 0
            || byte_count != sql_blob_length
            || byte_count as usize > MAXIMUM_BUILDER_ARTIFACT_BYTES
            || sql_blob_length as usize > MAXIMUM_BUILDER_ARTIFACT_BYTES
            || !constant_time_eq(digest.as_bytes(), presented_digest.as_bytes())
        {
            transaction
                .commit()
                .map_err(|error| storage("commit unauthorized builder share lookup", error))?;
            return Ok(None);
        }

        let artifact_row = transaction
            .query_row(
                "SELECT artifact_id, source_session_id, source_revision, content_hash, \
                        artifact_json, byte_count, expires_at \
                 FROM builder_artifacts WHERE artifact_id = ?1 AND principal_id = ?2",
                rusqlite::params![artifact_id, principal_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row_revision(row, 2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, Vec<u8>>(4)?,
                        row.get::<_, i64>(5)?,
                        row.get::<_, i64>(6)?,
                    ))
                },
            )
            .optional()
            .map_err(|error| storage("load authenticated builder artifact", error))?;
        let artifact = artifact_row
            .map(|row| artifact_from_row(row.0, row.1, row.2, row.3, row.4, row.5, row.6))
            .transpose();
        let result = match artifact {
            Ok(Some(artifact)) if artifact.expires_at == expires_at => {
                let source_receipt =
                    tombstone(&transaction, &principal_id, &artifact.source_session_id)?;
                match source_receipt {
                    Some((kind, revision, receipt_json))
                        if kind == "emitted" && revision == artifact.source_revision =>
                    {
                        let receipt =
                            serde_json::from_slice::<BuilderArtifactReceipt>(&receipt_json).ok();
                        receipt
                            .filter(|receipt| {
                                receipt.session_id == artifact.source_session_id
                                    && receipt.revision == artifact.source_revision
                                    && receipt.content_hash == artifact.content_hash
                            })
                            .map(|_| BuilderSharedArtifact {
                                artifact_id: artifact.artifact_id,
                                content_hash: artifact.content_hash,
                                artifact_json: artifact.artifact_json,
                                expires_at,
                            })
                    }
                    _ => None,
                }
            }
            // Corrupt or missing authenticated artifacts are deliberately
            // hidden behind the same not-found result as invalid credentials.
            _ => None,
        };
        transaction
            .commit()
            .map_err(|error| storage("commit builder share lookup", error))?;
        Ok(result)
    }

    pub fn revoke_builder_share(&self, builder_id: &str, artifact_id: &str) -> BuilderResult<()> {
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| storage("begin builder share revocation", error))?;
        require_builder(&transaction, builder_id)?;
        prune_expired(&transaction, now)?;
        let changed = transaction
            .execute(
                "UPDATE builder_shares SET revoked = 1 WHERE artifact_id = ?1 \
                 AND principal_id = ?2 AND revoked = 0",
                rusqlite::params![artifact_id, builder_id],
            )
            .map_err(|error| storage("revoke builder share", error))?;
        if changed != 1 {
            return Err(BuilderStoreError::NotFound);
        }
        transaction
            .commit()
            .map_err(|error| storage("commit builder share revocation", error))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use thumble_builder::BuilderEdit;

    fn setup() -> (Store, String) {
        let store = Store::open_in_memory().unwrap();
        let builder = store
            .create_builder_principal("Builder store test")
            .unwrap();
        (store, builder)
    }

    fn sid(number: u16) -> String {
        format!("00000000-0000-4000-8000-{number:012x}")
    }

    fn session(number: u16) -> BuilderSession {
        BuilderSession::begin(sid(number), Store::now(), 3600).unwrap()
    }

    fn emitted(
        store: &Store,
        builder: &str,
        number: u16,
    ) -> (
        BuilderSession,
        BuilderArtifactEmission,
        BuilderEmissionHandoff,
    ) {
        let mut session = session(number);
        store.create_builder_workspace(builder, &session).unwrap();
        let now = Store::now();
        let emission = session.emit_artifact(session.revision(), now).unwrap();
        let handoff = session.mark_emitted(session.revision(), now).unwrap();
        (session, emission, handoff)
    }

    fn parts(result: BuilderEmissionResult) -> (BuilderArtifactRecord, BuilderShareCredential) {
        match result {
            BuilderEmissionResult::Emitted { artifact, share }
            | BuilderEmissionResult::Replayed { artifact, share } => (artifact, share),
        }
    }

    #[test]
    fn builder_schema_is_fresh_idempotent_and_indexed() {
        let (store, _) = setup();
        let mut connection = store.connection.lock().unwrap();
        super::super::store::migrate_schema(&mut connection).unwrap();
        super::super::store::migrate_schema(&mut connection).unwrap();
        for table in [
            "builder_workspaces",
            "builder_artifacts",
            "builder_shares",
            "builder_session_tombstones",
        ] {
            let count: i64 = connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                    rusqlite::params![table],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 1, "missing {table}");
        }
        let indexes: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' \
                 AND name LIKE 'builder_%_idx'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(indexes >= 7);
    }

    #[test]
    fn create_load_save_delete_and_principal_isolation() {
        let (store, owner) = setup();
        let other = store.create_builder_principal("Other").unwrap();
        let mut session = session(1);
        store.create_builder_workspace(&owner, &session).unwrap();
        assert_eq!(
            store
                .load_builder_workspace(&owner, session.session_id())
                .unwrap()
                .session,
            session
        );
        assert_eq!(
            store
                .load_builder_workspace(&other, session.session_id())
                .unwrap_err(),
            BuilderStoreError::NotFound
        );
        let operation = sid(101);
        session
            .apply_edit(
                &operation,
                1,
                BuilderEdit::ProfileRename {
                    name: "Stored".to_owned(),
                },
                Store::now(),
            )
            .unwrap();
        store
            .save_builder_workspace(&owner, 1, 1, &session)
            .unwrap();
        assert_eq!(
            store
                .save_builder_workspace(&owner, 1, 2, &session)
                .unwrap_err(),
            BuilderStoreError::Conflict {
                expected: 1,
                actual: Some(2)
            }
        );
        assert_eq!(
            store
                .delete_builder_workspace(&other, session.session_id(), 2, 2)
                .unwrap_err(),
            BuilderStoreError::NotFound
        );
        store
            .delete_builder_workspace(&owner, session.session_id(), 2, 2)
            .unwrap();
        assert_eq!(
            store
                .load_builder_workspace(&owner, session.session_id())
                .unwrap_err(),
            BuilderStoreError::NotFound
        );
    }

    #[test]
    fn default_and_maximum_workspace_ttls_are_enforced() {
        let (store, builder) = setup();
        let default = store
            .begin_builder_workspace(&builder, &sid(3), None)
            .unwrap();
        assert_eq!(
            default.session.expires_at() - default.session.created_at(),
            DEFAULT_BUILDER_SESSION_TTL_SECONDS
        );
        store
            .begin_builder_workspace(&builder, &sid(4), Some(MAXIMUM_BUILDER_SESSION_TTL_SECONDS))
            .unwrap();
        assert!(matches!(
            store.begin_builder_workspace(
                &builder,
                &sid(5),
                Some(MAXIMUM_BUILDER_SESSION_TTL_SECONDS + 1),
            ),
            Err(BuilderStoreError::InvalidInput(_))
        ));
    }

    #[test]
    fn concurrent_cas_saves_have_one_winner() {
        let (store, builder) = setup();
        let store = std::sync::Arc::new(store);
        let mut updated = session(6);
        store.create_builder_workspace(&builder, &updated).unwrap();
        updated
            .apply_edit(
                &sid(106),
                1,
                BuilderEdit::ProfileRename {
                    name: "CAS winner".to_owned(),
                },
                Store::now(),
            )
            .unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(3));
        let mut threads = Vec::new();
        for _ in 0..2 {
            let store = store.clone();
            let builder = builder.clone();
            let updated = updated.clone();
            let barrier = barrier.clone();
            threads.push(std::thread::spawn(move || {
                barrier.wait();
                store.save_builder_workspace(&builder, 1, 1, &updated)
            }));
        }
        barrier.wait();
        let results = threads
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(
                    result,
                    Err(BuilderStoreError::Conflict {
                        expected: 1,
                        actual: Some(2)
                    })
                ))
                .count(),
            1
        );
    }

    #[test]
    fn concurrent_noop_saves_advance_generation_without_losing_operation_history() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("builder-cas.db");
        let secret = "builder-multi-connection-secret-32-bytes";
        let first_store = Store::open(&path, secret).unwrap();
        let builder = first_store
            .create_builder_principal("Multi-connection builder")
            .unwrap();
        let initial = session(60);
        let created = first_store
            .create_builder_workspace(&builder, &initial)
            .unwrap();
        assert_eq!(created.storage_generation, 1);
        let second_store = Store::open(&path, secret).unwrap();

        let mut left = first_store
            .load_builder_workspace(&builder, initial.session_id())
            .unwrap();
        let mut right = second_store
            .load_builder_workspace(&builder, initial.session_id())
            .unwrap();
        assert_eq!(left.storage_generation, right.storage_generation);
        left.session
            .apply_edit(
                &sid(160),
                1,
                BuilderEdit::ProfileRename {
                    name: "Default".to_owned(),
                },
                Store::now(),
            )
            .unwrap();
        right
            .session
            .apply_edit(
                &sid(161),
                1,
                BuilderEdit::ProfileRename {
                    name: "Default".to_owned(),
                },
                Store::now(),
            )
            .unwrap();
        assert_eq!(left.session.revision(), 1);
        assert_eq!(right.session.revision(), 1);

        let winner = first_store
            .save_builder_workspace(&builder, 1, left.storage_generation, &left.session)
            .unwrap();
        assert_eq!(winner.storage_generation, 2);
        assert_eq!(winner.session.operation_count(), 1);
        assert_eq!(
            second_store
                .save_builder_workspace(&builder, 1, right.storage_generation, &right.session,)
                .unwrap_err(),
            BuilderStoreError::StorageGenerationConflict {
                expected: 1,
                actual: Some(2),
            }
        );

        let mut reloaded = second_store
            .load_builder_workspace(&builder, initial.session_id())
            .unwrap();
        assert_eq!(reloaded.session.operation_count(), 1);
        reloaded
            .session
            .apply_edit(
                &sid(161),
                1,
                BuilderEdit::ProfileRename {
                    name: "Default".to_owned(),
                },
                Store::now(),
            )
            .unwrap();
        let merged = second_store
            .save_builder_workspace(&builder, 1, reloaded.storage_generation, &reloaded.session)
            .unwrap();
        assert_eq!(merged.storage_generation, 3);
        assert_eq!(merged.session.operation_count(), 2);
    }

    #[test]
    fn concurrent_noop_generations_conflict_on_storage_generation_and_merge_after_reload() {
        let (store, builder) = setup();
        let initial = session(63);
        store.create_builder_workspace(&builder, &initial).unwrap();
        let fixture = include_bytes!("../../../fixtures/generation-spec/v1/aliases-basic.json");
        let mut baseline = store
            .load_builder_workspace(&builder, initial.session_id())
            .unwrap();
        baseline
            .session
            .generate_from_spec(&sid(163), 1, fixture, None, Store::now())
            .unwrap();
        let baseline = store
            .save_builder_workspace(&builder, 1, baseline.storage_generation, &baseline.session)
            .unwrap();
        assert_eq!(baseline.session.revision(), 2);

        let mut left = store
            .load_builder_workspace(&builder, initial.session_id())
            .unwrap();
        let mut right = left.clone();
        let left_summary = left
            .session
            .generate_from_spec(&sid(164), 2, fixture, None, Store::now())
            .unwrap();
        let right_summary = right
            .session
            .generate_from_spec(&sid(165), 2, fixture, None, Store::now())
            .unwrap();
        assert!(!left_summary.changed);
        assert!(!right_summary.changed);
        assert_eq!(left.session.revision(), 2);
        let saved = store
            .save_builder_workspace(&builder, 2, left.storage_generation, &left.session)
            .unwrap();
        assert_eq!(saved.storage_generation, 3);
        assert_eq!(
            store
                .save_builder_workspace(&builder, 2, right.storage_generation, &right.session)
                .unwrap_err(),
            BuilderStoreError::StorageGenerationConflict {
                expected: 2,
                actual: Some(3),
            }
        );
        let mut reloaded = store
            .load_builder_workspace(&builder, initial.session_id())
            .unwrap();
        assert_eq!(reloaded.session.operation_count(), 2);
        reloaded
            .session
            .generate_from_spec(&sid(165), 2, fixture, None, Store::now())
            .unwrap();
        let merged = store
            .save_builder_workspace(&builder, 2, reloaded.storage_generation, &reloaded.session)
            .unwrap();
        assert_eq!(merged.storage_generation, 4);
        assert_eq!(merged.session.operation_count(), 3);
    }

    #[test]
    fn legacy_workspace_schema_backfills_storage_generation_once() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("builder-migration.db");
        let secret = "builder-migration-secret-at-least-32-bytes";
        let store = Store::open(&path, secret).unwrap();
        let builder = store.create_builder_principal("Migration builder").unwrap();
        let session = session(61);
        store.create_builder_workspace(&builder, &session).unwrap();
        drop(store);

        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute_batch(
                "ALTER TABLE builder_workspaces RENAME TO builder_workspaces_new; \
                 CREATE TABLE builder_workspaces ( \
                   principal_id TEXT NOT NULL, session_id TEXT NOT NULL, \
                   revision INTEGER NOT NULL CHECK (revision >= 1), \
                   session_json BLOB NOT NULL, byte_count INTEGER NOT NULL CHECK (byte_count >= 0), \
                   created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, \
                   PRIMARY KEY (principal_id, session_id)); \
                 INSERT INTO builder_workspaces \
                   (principal_id, session_id, revision, session_json, byte_count, created_at, updated_at, expires_at) \
                   SELECT principal_id, session_id, revision, session_json, byte_count, created_at, updated_at, expires_at \
                   FROM builder_workspaces_new; \
                 DROP TABLE builder_workspaces_new;",
            )
            .unwrap();
        drop(connection);

        let reopened = Store::open(&path, secret).unwrap();
        let loaded = reopened
            .load_builder_workspace(&builder, session.session_id())
            .unwrap();
        assert_eq!(loaded.storage_generation, 1);
        drop(reopened);
        let reopened = Store::open(&path, secret).unwrap();
        assert_eq!(
            reopened
                .load_builder_workspace(&builder, session.session_id())
                .unwrap()
                .storage_generation,
            1
        );
    }

    #[test]
    fn tampered_session_or_denormalized_metadata_is_rejected() {
        let (store, builder) = setup();
        let session = session(2);
        store.create_builder_workspace(&builder, &session).unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE builder_workspaces SET revision = revision + 1 WHERE principal_id = ?1",
                rusqlite::params![builder],
            )
            .unwrap();
        assert!(matches!(
            store.load_builder_workspace(&builder, session.session_id()),
            Err(BuilderStoreError::CorruptData(_))
        ));
    }

    #[test]
    fn workspace_count_quota_and_expiry_pruning_are_transactional() {
        let (store, builder) = setup();
        for number in 10..14 {
            store
                .create_builder_workspace(&builder, &session(number))
                .unwrap();
        }
        assert_eq!(
            store
                .create_builder_workspace(&builder, &session(14))
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::WorkspaceCount)
        );
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE builder_workspaces SET expires_at = ?1 WHERE session_id = ?2",
                rusqlite::params![Store::now(), sid(10)],
            )
            .unwrap();
        store
            .create_builder_workspace(&builder, &session(14))
            .unwrap();
        assert_eq!(
            store
                .load_builder_workspace(&builder, &sid(10))
                .unwrap_err(),
            BuilderStoreError::NotFound
        );
    }

    #[test]
    fn aggregate_and_global_byte_quotas_are_enforced() {
        let (store, builder) = setup();
        let now = Store::now();
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO builder_workspaces \
                 (principal_id, session_id, revision, session_json, byte_count, created_at, updated_at, expires_at) \
                 VALUES (?1, 'filler', 1, X'', ?2, ?3, ?3, ?4)",
                rusqlite::params![
                    builder,
                    MAXIMUM_BUILDER_WORKSPACE_AGGREGATE_BYTES,
                    now,
                    now + 3600
                ],
            )
            .unwrap();
        assert_eq!(
            store
                .create_builder_workspace(&builder, &session(20))
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::WorkspaceAggregateBytes)
        );

        let (store, builder) = setup();
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO builder_artifacts \
                 (principal_id, artifact_id, source_session_id, source_revision, content_hash, \
                  artifact_json, byte_count, created_at, expires_at) \
                 VALUES (?1, 'filler', 'filler', 1, 'hash', X'', ?2, ?3, ?4)",
                rusqlite::params![builder, MAXIMUM_GLOBAL_LIVE_BUILDER_BYTES, now, now + 3600],
            )
            .unwrap();
        assert_eq!(
            store
                .create_builder_workspace(&builder, &session(21))
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::GlobalLiveBytes)
        );

        // Tombstone receipt bytes participate in the same global builder-byte
        // accounting as workspace and artifact BLOBs.
        let (store, builder) = setup();
        let tombstone_bytes = 1024 * 1024_i64;
        {
            let connection = store.connection.lock().unwrap();
            connection
                .execute(
                    "INSERT INTO builder_session_tombstones \
                     (principal_id, session_id, kind, revision, receipt_json, expires_at) \
                     VALUES ('global-filler', 'receipt', 'discarded', 1, zeroblob(?1), ?2)",
                    rusqlite::params![tombstone_bytes, now + 3600],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO builder_artifacts \
                     (principal_id, artifact_id, source_session_id, source_revision, content_hash, \
                      artifact_json, byte_count, created_at, expires_at) \
                     VALUES (?1, 'filler', 'filler', 1, 'hash', X'', ?2, ?3, ?4)",
                    rusqlite::params![
                        builder,
                        MAXIMUM_GLOBAL_LIVE_BUILDER_BYTES - tombstone_bytes,
                        now,
                        now + 3600
                    ],
                )
                .unwrap();
        }
        assert_eq!(
            store
                .create_builder_workspace(&builder, &session(22))
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::GlobalLiveBytes)
        );
    }

    #[test]
    fn artifact_count_and_aggregate_quotas_leave_workspace_live() {
        let (store, builder) = setup();
        let (session, emission, handoff) = emitted(&store, &builder, 22);
        let now = Store::now();
        {
            let mut connection = store.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            for index in 0..MAXIMUM_BUILDER_ARTIFACTS {
                transaction
                    .execute(
                        "INSERT INTO builder_artifacts \
                         (principal_id, artifact_id, source_session_id, source_revision, content_hash, \
                          artifact_json, byte_count, created_at, expires_at) \
                         VALUES (?1, ?2, ?3, 1, 'hash', X'', 0, ?4, ?5)",
                        rusqlite::params![
                            builder,
                            format!("filler-{index}"),
                            format!("source-{index}"),
                            now,
                            now + 3600
                        ],
                    )
                    .unwrap();
            }
            transaction.commit().unwrap();
        }
        assert_eq!(
            store
                .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::ArtifactCount)
        );
        assert!(store
            .load_builder_workspace(&builder, session.session_id())
            .is_ok());

        let (store, builder) = setup();
        let (session, emission, handoff) = emitted(&store, &builder, 23);
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO builder_artifacts \
                 (principal_id, artifact_id, source_session_id, source_revision, content_hash, \
                  artifact_json, byte_count, created_at, expires_at) \
                 VALUES (?1, 'aggregate-filler', 'aggregate-source', 1, 'hash', X'', ?2, ?3, ?4)",
                rusqlite::params![
                    builder,
                    MAXIMUM_BUILDER_ARTIFACT_AGGREGATE_BYTES,
                    now,
                    now + 3600
                ],
            )
            .unwrap();
        assert_eq!(
            store
                .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::ArtifactAggregateBytes)
        );
        assert!(store
            .load_builder_workspace(&builder, session.session_id())
            .is_ok());
    }

    #[test]
    fn tombstones_are_bounded_replayable_and_recover_after_expiry() {
        let (store, builder) = setup();
        let mut first_session_id = String::new();
        for number in 100..100 + MAXIMUM_BUILDER_TOMBSTONES_PER_PRINCIPAL as u16 {
            let session = session(number);
            if first_session_id.is_empty() {
                first_session_id = session.session_id().to_owned();
            }
            store.create_builder_workspace(&builder, &session).unwrap();
            store
                .discard_builder_workspace(&builder, session.session_id(), 1, Some(1))
                .unwrap();
        }
        assert_eq!(
            store
                .begin_builder_workspace(&builder, &sid(200), None)
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::TombstoneCount)
        );
        assert!(matches!(
            store
                .discard_builder_workspace(&builder, &first_session_id, 1, Some(1))
                .unwrap(),
            BuilderDiscardResult::Replayed(_)
        ));

        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE builder_session_tombstones SET expires_at = ?1",
                rusqlite::params![Store::now()],
            )
            .unwrap();
        store
            .begin_builder_workspace(&builder, &sid(200), None)
            .unwrap();
        let remaining: i64 = store
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT COUNT(*) FROM builder_session_tombstones",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(remaining, 0);
    }

    #[test]
    fn tombstone_byte_limits_leave_terminal_workspace_live() {
        let (store, builder) = setup();
        let live = session(201);
        store.create_builder_workspace(&builder, &live).unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO builder_session_tombstones \
                 (principal_id, session_id, kind, revision, receipt_json, expires_at) \
                 VALUES (?1, 'filler', 'discarded', 1, zeroblob(?2), ?3)",
                rusqlite::params![
                    builder,
                    MAXIMUM_BUILDER_TOMBSTONE_BYTES_PER_PRINCIPAL,
                    Store::now() + 3600
                ],
            )
            .unwrap();
        assert_eq!(
            store
                .discard_builder_workspace(&builder, live.session_id(), 1, Some(1))
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::TombstoneBytes)
        );
        assert!(store
            .load_builder_workspace(&builder, live.session_id())
            .is_ok());
    }

    #[test]
    fn global_tombstone_count_and_bytes_are_bounded() {
        let (store, builder) = setup();
        {
            let mut connection = store.connection.lock().unwrap();
            let transaction = connection.transaction().unwrap();
            for index in 0..MAXIMUM_GLOBAL_BUILDER_TOMBSTONES {
                transaction
                    .execute(
                        "INSERT INTO builder_session_tombstones \
                         (principal_id, session_id, kind, revision, receipt_json, expires_at) \
                         VALUES ('global-filler', ?1, 'discarded', 1, X'', ?2)",
                        rusqlite::params![index.to_string(), Store::now() + 3600],
                    )
                    .unwrap();
            }
            transaction.commit().unwrap();
        }
        assert_eq!(
            store
                .begin_builder_workspace(&builder, &sid(202), None)
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::GlobalTombstoneCount)
        );

        let (store, builder) = setup();
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO builder_session_tombstones \
                 (principal_id, session_id, kind, revision, receipt_json, expires_at) \
                 VALUES ('global-filler', 'bytes', 'discarded', 1, zeroblob(?1), ?2)",
                rusqlite::params![MAXIMUM_GLOBAL_BUILDER_TOMBSTONE_BYTES, Store::now() + 3600],
            )
            .unwrap();
        assert_eq!(
            store
                .begin_builder_workspace(&builder, &sid(203), None)
                .unwrap_err(),
            BuilderStoreError::QuotaExceeded(BuilderQuota::GlobalTombstoneBytes)
        );
    }

    #[test]
    fn discard_is_exact_and_replayable() {
        let (store, builder) = setup();
        let session = session(30);
        store.create_builder_workspace(&builder, &session).unwrap();
        let first = store
            .discard_builder_workspace(&builder, session.session_id(), 1, Some(1))
            .unwrap();
        let replay = store
            .discard_builder_workspace(&builder, session.session_id(), 1, None)
            .unwrap();
        let (BuilderDiscardResult::Discarded(first), BuilderDiscardResult::Replayed(replay)) =
            (first, replay)
        else {
            panic!("unexpected discard results")
        };
        assert_eq!(first, replay);
        assert_eq!(
            store
                .discard_builder_workspace(&builder, session.session_id(), 2, Some(1))
                .unwrap_err(),
            BuilderStoreError::Conflict {
                expected: 2,
                actual: Some(1)
            }
        );
    }

    #[test]
    fn emission_is_atomic_replayable_and_never_stores_clear_token() {
        let (store, builder) = setup();
        let (session, emission, handoff) = emitted(&store, &builder, 40);
        let first = store
            .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
            .unwrap();
        let replay = store
            .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
            .unwrap();
        assert!(matches!(replay, BuilderEmissionResult::Replayed { .. }));
        let (first_artifact, first_share) = parts(first);
        let (replay_artifact, replay_share) = parts(replay);
        assert_eq!(first_artifact, replay_artifact);
        assert_eq!(first_share, replay_share);
        let persisted: String = store
            .connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT token_digest FROM builder_shares WHERE artifact_id = ?1",
                rusqlite::params![first_share.artifact_id],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(persisted, token_digest(&first_share.share_token));
        assert_ne!(persisted, first_share.share_token);
        assert_eq!(persisted.len(), 64);
    }

    #[test]
    fn sqlite_file_contains_neither_share_token_nor_link_secret() {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("builder-secrets.db");
        let link_secret = "builder-secret-scan-link-key-32-bytes";
        let store = Store::open(&database, link_secret).unwrap();
        let builder = store.create_builder_principal("Secret scan").unwrap();
        let (session, emission, handoff) = emitted(&store, &builder, 43);
        let (_, share) = parts(
            store
                .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
                .unwrap(),
        );
        drop(store);
        let database_bytes = std::fs::read(database).unwrap();
        for clear_secret in [share.share_token.as_bytes(), link_secret.as_bytes()] {
            assert!(
                !database_bytes
                    .windows(clear_secret.len())
                    .any(|window| window == clear_secret),
                "clear secret appeared in the SQLite file"
            );
        }
    }

    #[test]
    fn injected_emission_failure_rolls_back_and_retains_workspace() {
        let (store, builder) = setup();
        let (session, emission, handoff) = emitted(&store, &builder, 41);
        let failed = store.emit_builder_artifact_with_hook(
            &builder,
            &session,
            WorkspaceCas {
                revision: 1,
                storage_generation: 1,
            },
            &emission,
            &handoff,
            |_| Err(BuilderStoreError::Storage("injected failure".to_owned())),
        );
        assert!(matches!(failed, Err(BuilderStoreError::Storage(_))));
        assert!(store
            .load_builder_workspace(&builder, session.session_id())
            .is_ok());
        let connection = store.connection.lock().unwrap();
        let artifacts: i64 = connection
            .query_row("SELECT COUNT(*) FROM builder_artifacts", [], |row| {
                row.get(0)
            })
            .unwrap();
        let tombstones: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM builder_session_tombstones",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!((artifacts, tombstones), (0, 0));
    }

    #[test]
    fn emission_rejects_content_or_handoff_mismatch_and_keeps_workspace() {
        let (store, builder) = setup();
        let (session, mut emission, handoff) = emitted(&store, &builder, 42);
        emission.artifact_json.push(' ');
        assert!(matches!(
            store.emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff),
            Err(BuilderStoreError::InvalidInput(_))
        ));
        assert!(store
            .load_builder_workspace(&builder, session.session_id())
            .is_ok());
    }

    #[test]
    fn persisted_artifact_tampering_is_never_replayed_or_shared() {
        let (store, builder) = setup();
        let (session, emission, handoff) = emitted(&store, &builder, 44);
        let (artifact, share) = parts(
            store
                .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
                .unwrap(),
        );
        let mut tampered = artifact.artifact_json.clone();
        let marker = b"\"name\":\"";
        let position = tampered
            .windows(marker.len())
            .position(|window| window == marker)
            .expect("artifact profile name")
            + marker.len();
        tampered[position] = if tampered[position] == b'X' {
            b'Y'
        } else {
            b'X'
        };
        assert_eq!(tampered.len(), artifact.artifact_json.len());
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE builder_artifacts SET artifact_json = ?1 WHERE artifact_id = ?2",
                rusqlite::params![tampered, artifact.artifact_id],
            )
            .unwrap();
        assert!(matches!(
            store.emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff),
            Err(BuilderStoreError::CorruptData(_))
        ));
        assert!(store
            .lookup_builder_share(&share.artifact_id, &share.share_token)
            .unwrap()
            .is_none());
    }

    #[test]
    fn oversized_corrupt_share_row_is_rejected_from_metadata_before_decode() {
        let (store, builder) = setup();
        let (session, emission, handoff) = emitted(&store, &builder, 62);
        let (artifact, share) = parts(
            store
                .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
                .unwrap(),
        );
        let oversized = MAXIMUM_BUILDER_ARTIFACT_BYTES as i64 + 1;
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE builder_artifacts SET artifact_json = zeroblob(?1), byte_count = ?1 \
                 WHERE artifact_id = ?2",
                rusqlite::params![oversized, artifact.artifact_id],
            )
            .unwrap();
        assert!(store
            .lookup_builder_share(&share.artifact_id, &share.share_token)
            .unwrap()
            .is_none());
    }

    #[test]
    fn share_tokens_cannot_be_swapped_between_artifacts() {
        let (store, builder) = setup();
        let (first_session, first_emission, first_handoff) = emitted(&store, &builder, 45);
        let (second_session, second_emission, second_handoff) = emitted(&store, &builder, 46);
        let (first_artifact, first_share) = parts(
            store
                .emit_builder_artifact(
                    &builder,
                    &first_session,
                    1,
                    1,
                    &first_emission,
                    &first_handoff,
                )
                .unwrap(),
        );
        let (second_artifact, second_share) = parts(
            store
                .emit_builder_artifact(
                    &builder,
                    &second_session,
                    1,
                    1,
                    &second_emission,
                    &second_handoff,
                )
                .unwrap(),
        );
        assert!(store
            .lookup_builder_share(&first_artifact.artifact_id, &second_share.share_token)
            .unwrap()
            .is_none());
        assert!(store
            .lookup_builder_share(&second_artifact.artifact_id, &first_share.share_token)
            .unwrap()
            .is_none());
    }

    #[test]
    fn builder_debug_output_redacts_tokens_and_artifact_json() {
        let (store, builder) = setup();
        let (session, emission, handoff) = emitted(&store, &builder, 47);
        let result = store
            .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
            .unwrap();
        let (artifact, share) = parts(result.clone());
        for debug in [
            format!("{artifact:?}"),
            format!("{share:?}"),
            format!("{result:?}"),
            format!(
                "{:?}",
                store
                    .lookup_builder_share(&share.artifact_id, &share.share_token)
                    .unwrap()
                    .unwrap()
            ),
        ] {
            assert!(!debug.contains(&share.share_token));
            assert!(!debug.contains(&emission.artifact_json));
        }
        assert!(format!("{share:?}").contains("REDACTED"));
    }

    #[test]
    fn builder_derivation_version_and_current_key_output_are_stable() {
        assert_eq!(BUILDER_DOMAIN_DERIVATION_VERSION, 1);
        let store = Store::open_in_memory().unwrap();
        let (artifact_id, share_token) = artifact_identifiers(
            &store,
            "bld_fixed",
            "00000000-0000-4000-8000-000000000001",
            7,
            &"a".repeat(64),
        );
        assert_eq!(
            artifact_id,
            "bar_a3c309800f79b914eea356985e92dcfd48b81edcc5055591adea44a6c5329bf2"
        );
        assert_eq!(
            share_token,
            "3a3ec3f6301a0cc000d4137946ce9fd22711b590e0b899ed6ef9ecaabb7c1a1e"
        );
    }

    #[test]
    fn prune_builder_storage_is_idempotent_for_expired_rows() {
        let (store, builder) = setup();
        let workspace = session(48);
        store
            .create_builder_workspace(&builder, &workspace)
            .unwrap();
        let (session, emission, handoff) = emitted(&store, &builder, 49);
        store
            .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
            .unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute_batch(&format!(
                "UPDATE builder_workspaces SET expires_at = {now};
                 UPDATE builder_shares SET expires_at = {now};
                 UPDATE builder_artifacts SET expires_at = {now};
                 UPDATE builder_session_tombstones SET expires_at = {now};",
                now = Store::now()
            ))
            .unwrap();
        store.prune_builder_storage().unwrap();
        store.prune_builder_storage().unwrap();
        let connection = store.connection.lock().unwrap();
        for table in [
            "builder_workspaces",
            "builder_shares",
            "builder_artifacts",
            "builder_session_tombstones",
        ] {
            let count: i64 = connection
                .query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |row| {
                    row.get(0)
                })
                .unwrap();
            assert_eq!(count, 0, "expired rows remain in {table}");
        }
    }

    #[test]
    fn share_lookup_is_exact_reusable_and_uniformly_hidden() {
        let (store, builder) = setup();
        let (session, emission, handoff) = emitted(&store, &builder, 50);
        let (artifact, share) = parts(
            store
                .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
                .unwrap(),
        );
        let first = store
            .lookup_builder_share(&artifact.artifact_id, &share.share_token)
            .unwrap()
            .unwrap();
        let second = store
            .lookup_builder_share(&artifact.artifact_id, &share.share_token)
            .unwrap()
            .unwrap();
        assert_eq!(first, second);
        assert_eq!(first.artifact_json, emission.artifact_json.as_bytes());
        assert!(store
            .lookup_builder_share(&artifact.artifact_id, "wrong")
            .unwrap()
            .is_none());
        assert!(store
            .lookup_builder_share("bar_unknown", &share.share_token)
            .unwrap()
            .is_none());
        let other = store.create_builder_principal("Other").unwrap();
        assert_eq!(
            store
                .revoke_builder_share(&other, &artifact.artifact_id)
                .unwrap_err(),
            BuilderStoreError::NotFound
        );
        store
            .revoke_builder_share(&builder, &artifact.artifact_id)
            .unwrap();
        assert!(store
            .lookup_builder_share(&artifact.artifact_id, &share.share_token)
            .unwrap()
            .is_none());
    }

    #[test]
    fn expired_and_principal_revoked_shares_are_not_found() {
        let (store, builder) = setup();
        let (session, emission, handoff) = emitted(&store, &builder, 51);
        let (artifact, share) = parts(
            store
                .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
                .unwrap(),
        );
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE builder_shares SET expires_at = ?1 WHERE artifact_id = ?2",
                rusqlite::params![Store::now(), artifact.artifact_id],
            )
            .unwrap();
        assert!(store
            .lookup_builder_share(&artifact.artifact_id, &share.share_token)
            .unwrap()
            .is_none());

        let (session, emission, handoff) = emitted(&store, &builder, 52);
        let (artifact, share) = parts(
            store
                .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
                .unwrap(),
        );
        store.revoke_builder_principal(&builder).unwrap();
        assert!(store
            .lookup_builder_share(&artifact.artifact_id, &share.share_token)
            .unwrap()
            .is_none());
        assert_eq!(
            store
                .revoke_builder_share(&builder, &artifact.artifact_id)
                .unwrap_err(),
            BuilderStoreError::InactivePrincipal
        );
    }
}
