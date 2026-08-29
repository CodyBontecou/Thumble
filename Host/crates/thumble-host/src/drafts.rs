use crate::bridge::ConfigurationBridgeError;
use crate::draft_operation::{
    ConfigurationOperation, ConfigurationOperationError, ConfigurationOperationOutcome,
};
use crate::paths::HostPaths;
use crate::three_way_merge::merge_configuration_documents;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::error::Error;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use thumble_core::{ConfigurationDocument, ConfigurationDocumentError, PersistentState};
use uuid::Uuid;

pub const CONFIGURATION_DRAFT_SCHEMA: &str = "com.codybontecou.thumble.configuration-draft";
pub const CONFIGURATION_DRAFT_VERSION: u32 = 1;
pub const MAXIMUM_LIVE_CONFIGURATION_DRAFTS: usize = 8;
pub const MAXIMUM_CONFIGURATION_DRAFT_OPERATIONS: usize = 256;
pub const CONFIGURATION_DRAFT_LIFETIME_MILLIS: i64 = 24 * 60 * 60 * 1000;
const MAXIMUM_CONFIGURATION_DRAFT_BYTES: u64 = 18 * 1024 * 1024;

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConfigurationDraft {
    pub schema: String,
    pub version: u32,
    #[serde(rename = "draftID")]
    pub draft_id: String,
    pub base_configuration_revision: u64,
    pub draft_revision: u64,
    pub base_document: ConfigurationDocument,
    pub working_document: ConfigurationDocument,
    pub operation_log: Vec<DraftOperationRecord>,
    pub created_at: i64,
    pub updated_at: i64,
    pub expires_at: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_validation: Option<DraftValidationRecord>,
}

impl fmt::Debug for ConfigurationDraft {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ConfigurationDraft")
            .field("draft_id", &self.draft_id)
            .field(
                "base_configuration_revision",
                &self.base_configuration_revision,
            )
            .field("draft_revision", &self.draft_revision)
            .field("profile_count", &self.working_document.profiles.len())
            .field("operation_count", &self.operation_log.len())
            .field("created_at", &self.created_at)
            .field("updated_at", &self.updated_at)
            .field("expires_at", &self.expires_at)
            .field("has_validation", &self.last_validation.is_some())
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DraftOperationRecord {
    #[serde(rename = "operationID")]
    pub operation_id: String,
    pub operation_digest: String,
    pub base_draft_revision: u64,
    pub result_draft_revision: u64,
    pub changed: bool,
    pub changed_paths: Vec<String>,
    pub applied_at: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DraftEditResult {
    pub draft: ConfigurationDraft,
    pub operation: ConfigurationOperationOutcome,
    pub idempotent_replay: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DraftValidationRecord {
    pub draft_revision: u64,
    pub valid: bool,
    pub error_count: u32,
    pub warning_count: u32,
    pub validated_at: i64,
}

#[derive(Debug, Clone)]
pub struct DraftStore {
    directory: PathBuf,
}

impl DraftStore {
    pub fn new(paths: &HostPaths) -> Self {
        Self {
            directory: paths.drafts_dir.clone(),
        }
    }

    #[cfg(test)]
    fn in_directory(directory: PathBuf) -> Self {
        Self { directory }
    }

    pub fn begin(
        &self,
        state: &PersistentState,
        expected_configuration_revision: u64,
        now_millis: i64,
    ) -> Result<ConfigurationDraft, DraftError> {
        self.begin_with_id(
            state,
            expected_configuration_revision,
            &Uuid::new_v4().hyphenated().to_string(),
            now_millis,
        )
    }

    /// Begin a draft using a caller-derived UUID. Repeating the same begin is
    /// idempotent only when the existing draft has the exact same base
    /// revision and credential-free base document.
    pub fn begin_with_id(
        &self,
        state: &PersistentState,
        expected_configuration_revision: u64,
        draft_id: &str,
        now_millis: i64,
    ) -> Result<ConfigurationDraft, DraftError> {
        if state.configuration_revision != expected_configuration_revision {
            return Err(DraftError::ConfigurationRevisionConflict {
                expected: expected_configuration_revision,
                actual: state.configuration_revision,
            });
        }
        let draft_id = canonical_draft_id(draft_id)?;
        let document = ConfigurationDocument::from_state(state).map_err(DraftError::Document)?;
        self.ensure_directory()?;
        self.prune_expired(now_millis)?;

        match self.read(&self.path(&draft_id)) {
            Ok(existing) => {
                self.validate_loaded(&existing, &draft_id)?;
                if existing.base_configuration_revision != expected_configuration_revision
                    || existing.base_document != document
                {
                    return Err(DraftError::DraftIdConflict);
                }
                return Ok(existing);
            }
            Err(DraftError::NotFound) => {}
            Err(error) => return Err(error),
        }

        if self.draft_file_count()? >= MAXIMUM_LIVE_CONFIGURATION_DRAFTS {
            return Err(DraftError::TooManyLiveDrafts);
        }
        let draft = ConfigurationDraft {
            schema: CONFIGURATION_DRAFT_SCHEMA.to_owned(),
            version: CONFIGURATION_DRAFT_VERSION,
            draft_id,
            base_configuration_revision: state.configuration_revision,
            draft_revision: 1,
            base_document: document.clone(),
            working_document: document,
            operation_log: Vec::new(),
            created_at: now_millis,
            updated_at: now_millis,
            expires_at: now_millis.saturating_add(CONFIGURATION_DRAFT_LIFETIME_MILLIS),
            last_validation: None,
        };
        self.save(&draft)?;
        Ok(draft)
    }

    pub fn get(&self, draft_id: &str, now_millis: i64) -> Result<ConfigurationDraft, DraftError> {
        let canonical_id = canonical_draft_id(draft_id)?;
        self.ensure_directory()?;
        let path = self.path(&canonical_id);
        let draft = self.read(&path)?;
        self.validate_loaded(&draft, &canonical_id)?;
        if now_millis >= draft.expires_at {
            self.remove_file(&path)?;
            return Err(DraftError::Expired);
        }
        Ok(draft)
    }

    pub fn get_at_revision(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
        now_millis: i64,
    ) -> Result<ConfigurationDraft, DraftError> {
        let draft = self.get(draft_id, now_millis)?;
        if draft.draft_revision != expected_draft_revision {
            return Err(DraftError::DraftRevisionConflict {
                expected: expected_draft_revision,
                actual: draft.draft_revision,
            });
        }
        Ok(draft)
    }

    pub fn edit(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
        operation_id: &str,
        operation: &ConfigurationOperation,
        now_millis: i64,
    ) -> Result<DraftEditResult, DraftError> {
        self.edit_with(
            draft_id,
            expected_draft_revision,
            operation_id,
            operation,
            now_millis,
            |document| {
                let mut candidate = document.clone();
                let outcome = operation
                    .apply(&mut candidate, now_millis)
                    .map_err(DraftError::Operation)?;
                Ok((candidate, outcome))
            },
        )
    }

    pub fn edit_with<F>(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
        operation_id: &str,
        operation: &ConfigurationOperation,
        now_millis: i64,
        apply: F,
    ) -> Result<DraftEditResult, DraftError>
    where
        F: FnOnce(
            &ConfigurationDocument,
        )
            -> Result<(ConfigurationDocument, ConfigurationOperationOutcome), DraftError>,
    {
        self.edit_with_descriptor(
            draft_id,
            expected_draft_revision,
            operation_id,
            operation,
            now_millis,
            apply,
        )
    }

    /// Apply a native closure while recording the digest of an explicit,
    /// credential-free semantic descriptor. This keeps non-general-purpose
    /// authority transforms on the same bounded draft log and replay path as
    /// ordinary typed operations.
    pub fn edit_with_descriptor<D, F>(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
        operation_id: &str,
        descriptor: &D,
        now_millis: i64,
        apply: F,
    ) -> Result<DraftEditResult, DraftError>
    where
        D: Serialize,
        F: FnOnce(
            &ConfigurationDocument,
        )
            -> Result<(ConfigurationDocument, ConfigurationOperationOutcome), DraftError>,
    {
        let operation_id = canonical_operation_id(operation_id)?;
        let operation_digest = Self::operation_digest(descriptor)?;
        let mut draft = self.get(draft_id, now_millis)?;

        if let Some(record) = draft
            .operation_log
            .iter()
            .find(|record| record.operation_id == operation_id)
        {
            if record.operation_digest != operation_digest {
                return Err(DraftError::OperationIdConflict);
            }
            if record.base_draft_revision != expected_draft_revision {
                return Err(DraftError::DraftRevisionConflict {
                    expected: expected_draft_revision,
                    actual: record.base_draft_revision,
                });
            }
            return Ok(DraftEditResult {
                operation: ConfigurationOperationOutcome {
                    changed: record.changed,
                    changed_paths: record.changed_paths.clone(),
                },
                draft,
                idempotent_replay: true,
            });
        }
        if draft.draft_revision != expected_draft_revision {
            return Err(DraftError::DraftRevisionConflict {
                expected: expected_draft_revision,
                actual: draft.draft_revision,
            });
        }
        if draft.operation_log.len() >= MAXIMUM_CONFIGURATION_DRAFT_OPERATIONS {
            return Err(DraftError::TooManyOperations);
        }

        let (candidate, outcome) = apply(&draft.working_document)?;
        candidate.validate().map_err(DraftError::Document)?;
        if outcome.changed != (candidate != draft.working_document) {
            return Err(DraftError::InvalidOperationOutcome);
        }
        let result_revision = if outcome.changed {
            draft
                .draft_revision
                .checked_add(1)
                .ok_or(DraftError::DraftRevisionExhausted)?
        } else {
            draft.draft_revision
        };
        if outcome.changed {
            draft.working_document = candidate;
            draft.draft_revision = result_revision;
            draft.updated_at = now_millis;
            draft.last_validation = None;
        }
        draft.operation_log.push(DraftOperationRecord {
            operation_id,
            operation_digest,
            base_draft_revision: expected_draft_revision,
            result_draft_revision: result_revision,
            changed: outcome.changed,
            changed_paths: outcome.changed_paths.clone(),
            applied_at: now_millis,
        });
        self.save(&draft)?;
        Ok(DraftEditResult {
            draft,
            operation: outcome,
            idempotent_replay: false,
        })
    }

    pub fn rebase(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
        rebase_id: &str,
        current_configuration_revision: u64,
        current_document: &ConfigurationDocument,
        now_millis: i64,
    ) -> Result<DraftEditResult, DraftError> {
        let rebase_id = canonical_operation_id(rebase_id)?;
        let rebase_digest = Self::operation_digest(&serde_json::json!({
            "type": "draft.rebase",
            "configurationRevision": current_configuration_revision,
            "documentDigest": Self::operation_digest(current_document)?,
        }))?;
        let mut draft = self.get(draft_id, now_millis)?;
        if let Some(record) = draft
            .operation_log
            .iter()
            .find(|record| record.operation_id == rebase_id)
        {
            if record.operation_digest != rebase_digest {
                return Err(DraftError::OperationIdConflict);
            }
            if record.base_draft_revision != expected_draft_revision {
                return Err(DraftError::DraftRevisionConflict {
                    expected: expected_draft_revision,
                    actual: record.base_draft_revision,
                });
            }
            return Ok(DraftEditResult {
                operation: ConfigurationOperationOutcome {
                    changed: record.changed,
                    changed_paths: record.changed_paths.clone(),
                },
                draft,
                idempotent_replay: true,
            });
        }
        if draft.draft_revision != expected_draft_revision {
            return Err(DraftError::DraftRevisionConflict {
                expected: expected_draft_revision,
                actual: draft.draft_revision,
            });
        }
        if draft.operation_log.len() >= MAXIMUM_CONFIGURATION_DRAFT_OPERATIONS {
            return Err(DraftError::TooManyOperations);
        }
        current_document.validate().map_err(DraftError::Document)?;
        let merge = merge_configuration_documents(
            &draft.base_document,
            &draft.working_document,
            current_document,
        )
        .map_err(|conflict| DraftError::MergeConflict(conflict.paths))?;
        let changed = draft.base_configuration_revision != current_configuration_revision
            || draft.working_document != merge.document;
        let result_revision = if changed {
            draft
                .draft_revision
                .checked_add(1)
                .ok_or(DraftError::DraftRevisionExhausted)?
        } else {
            draft.draft_revision
        };
        if changed {
            draft.base_configuration_revision = current_configuration_revision;
            draft.base_document = current_document.clone();
            draft.working_document = merge.document;
            draft.draft_revision = result_revision;
            draft.updated_at = now_millis;
            draft.last_validation = None;
        }
        draft.operation_log.push(DraftOperationRecord {
            operation_id: rebase_id,
            operation_digest: rebase_digest,
            base_draft_revision: expected_draft_revision,
            result_draft_revision: result_revision,
            changed,
            changed_paths: merge.changed_paths.clone(),
            applied_at: now_millis,
        });
        self.save(&draft)?;
        Ok(DraftEditResult {
            draft,
            operation: ConfigurationOperationOutcome {
                changed,
                changed_paths: merge.changed_paths,
            },
            idempotent_replay: false,
        })
    }

    pub fn save(&self, draft: &ConfigurationDraft) -> Result<(), DraftError> {
        let canonical_id = canonical_draft_id(&draft.draft_id)?;
        self.validate_loaded(draft, &canonical_id)?;
        self.ensure_directory()?;
        let data = serde_json::to_vec_pretty(draft).map_err(|_| DraftError::EncodingFailed)?;
        if data.len() as u64 > MAXIMUM_CONFIGURATION_DRAFT_BYTES {
            return Err(DraftError::TooLarge(data.len() as u64));
        }
        atomic_write(&self.path(&canonical_id), &data).map_err(DraftError::Io)
    }

    pub fn discard(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
        now_millis: i64,
    ) -> Result<(), DraftError> {
        let draft = self.get(draft_id, now_millis)?;
        if draft.draft_revision != expected_draft_revision {
            return Err(DraftError::DraftRevisionConflict {
                expected: expected_draft_revision,
                actual: draft.draft_revision,
            });
        }
        self.remove_file(&self.path(&draft.draft_id))
    }

    pub fn operation_digest<T: Serialize>(operation: &T) -> Result<String, DraftError> {
        let encoded = serde_json::to_vec(operation).map_err(|_| DraftError::EncodingFailed)?;
        Ok(hex_digest(&encoded))
    }

    fn ensure_directory(&self) -> Result<(), DraftError> {
        if let Ok(metadata) = fs::symlink_metadata(&self.directory) {
            if metadata.file_type().is_symlink() || !metadata.is_dir() {
                return Err(DraftError::InsecureDirectory);
            }
            if metadata.uid() != unsafe { libc::geteuid() } {
                return Err(DraftError::InsecureDirectory);
            }
        }
        fs::create_dir_all(&self.directory).map_err(DraftError::Io)?;
        fs::set_permissions(&self.directory, fs::Permissions::from_mode(0o700))
            .map_err(DraftError::Io)
    }

    fn prune_expired(&self, now_millis: i64) -> Result<(), DraftError> {
        for entry in fs::read_dir(&self.directory).map_err(DraftError::Io)? {
            let entry = entry.map_err(DraftError::Io)?;
            let path = entry.path();
            if path.extension().and_then(|extension| extension.to_str()) != Some("json") {
                continue;
            }
            let Ok(draft) = self.read(&path) else {
                continue;
            };
            if now_millis >= draft.expires_at {
                self.remove_file(&path)?;
            }
        }
        Ok(())
    }

    fn draft_file_count(&self) -> Result<usize, DraftError> {
        let mut count = 0usize;
        for entry in fs::read_dir(&self.directory).map_err(DraftError::Io)? {
            let entry = entry.map_err(DraftError::Io)?;
            if entry.path().extension().and_then(|value| value.to_str()) == Some("json") {
                count = count.saturating_add(1);
            }
        }
        Ok(count)
    }

    fn read(&self, path: &Path) -> Result<ConfigurationDraft, DraftError> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map_err(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    DraftError::NotFound
                } else if error.raw_os_error() == Some(libc::ELOOP) {
                    DraftError::InsecureFile
                } else {
                    DraftError::Io(error)
                }
            })?;
        let metadata = file.metadata().map_err(DraftError::Io)?;
        if !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err(DraftError::InsecureFile);
        }
        if metadata.len() > MAXIMUM_CONFIGURATION_DRAFT_BYTES {
            return Err(DraftError::TooLarge(metadata.len()));
        }
        let mut data = Vec::with_capacity(usize::try_from(metadata.len()).unwrap_or(0));
        file.take(MAXIMUM_CONFIGURATION_DRAFT_BYTES.saturating_add(1))
            .read_to_end(&mut data)
            .map_err(DraftError::Io)?;
        if u64::try_from(data.len()).unwrap_or(u64::MAX) > MAXIMUM_CONFIGURATION_DRAFT_BYTES {
            return Err(DraftError::TooLarge(
                u64::try_from(data.len()).unwrap_or(u64::MAX),
            ));
        }
        serde_json::from_slice(&data).map_err(|_| DraftError::Malformed)
    }

    fn validate_loaded(
        &self,
        draft: &ConfigurationDraft,
        expected_id: &str,
    ) -> Result<(), DraftError> {
        if draft.schema != CONFIGURATION_DRAFT_SCHEMA
            || draft.version != CONFIGURATION_DRAFT_VERSION
        {
            return Err(DraftError::UnsupportedVersion);
        }
        if draft.draft_id != expected_id || draft.draft_revision == 0 {
            return Err(DraftError::Malformed);
        }
        if draft.operation_log.len() > MAXIMUM_CONFIGURATION_DRAFT_OPERATIONS {
            return Err(DraftError::TooManyOperations);
        }
        for record in &draft.operation_log {
            if !canonical_operation_id(&record.operation_id)
                .is_ok_and(|canonical| canonical == record.operation_id)
                || record.operation_digest.len() != 64
                || !record
                    .operation_digest
                    .bytes()
                    .all(|byte| byte.is_ascii_hexdigit())
                || record.changed_paths.len() > 64
                || record.changed_paths.iter().any(|path| path.len() > 512)
            {
                return Err(DraftError::Malformed);
            }
        }
        draft
            .base_document
            .validate()
            .map_err(DraftError::Document)?;
        draft
            .working_document
            .validate()
            .map_err(DraftError::Document)?;
        Ok(())
    }

    fn path(&self, draft_id: &str) -> PathBuf {
        self.directory.join(format!("{draft_id}.json"))
    }

    fn remove_file(&self, path: &Path) -> Result<(), DraftError> {
        fs::remove_file(path).map_err(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                DraftError::NotFound
            } else {
                DraftError::Io(error)
            }
        })?;
        File::open(&self.directory)
            .and_then(|directory| directory.sync_all())
            .map_err(DraftError::Io)
    }
}

fn canonical_operation_id(operation_id: &str) -> Result<String, DraftError> {
    Uuid::parse_str(operation_id)
        .map(|id| id.hyphenated().to_string())
        .map_err(|_| DraftError::InvalidOperationId)
}

fn canonical_draft_id(draft_id: &str) -> Result<String, DraftError> {
    Uuid::parse_str(draft_id)
        .map(|id| id.hyphenated().to_string())
        .map_err(|_| DraftError::InvalidDraftId)
}

fn atomic_write(path: &Path, data: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "draft path has no parent"))?;
    let temporary = parent.join(format!(".draft-{}.tmp", Uuid::new_v4().simple()));
    let result = (|| -> io::Result<()> {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(data)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        fs::rename(&temporary, path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn hex_digest(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[derive(Debug)]
pub enum DraftError {
    InvalidDraftId,
    InvalidOperationId,
    OperationIdConflict,
    DraftIdConflict,
    DraftRevisionExhausted,
    NotFound,
    Expired,
    TooManyLiveDrafts,
    TooManyOperations,
    TooLarge(u64),
    Malformed,
    UnsupportedVersion,
    InsecureDirectory,
    InsecureFile,
    EncodingFailed,
    ConfigurationRevisionConflict { expected: u64, actual: u64 },
    DraftRevisionConflict { expected: u64, actual: u64 },
    Document(ConfigurationDocumentError),
    Operation(ConfigurationOperationError),
    Bridge(ConfigurationBridgeError),
    InvalidOperationOutcome,
    Preview(String),
    MergeConflict(Vec<String>),
    Io(io::Error),
}

impl fmt::Display for DraftError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidDraftId => formatter.write_str("draft ID is invalid"),
            Self::InvalidOperationId => formatter.write_str("operation ID is invalid"),
            Self::OperationIdConflict => formatter
                .write_str("operation ID was already used with different operation content"),
            Self::DraftIdConflict => {
                formatter.write_str("draft ID was already used for a different configuration base")
            }
            Self::DraftRevisionExhausted => {
                formatter.write_str("configuration draft revision is exhausted")
            }
            Self::NotFound => formatter.write_str("configuration draft does not exist"),
            Self::Expired => formatter.write_str("configuration draft expired"),
            Self::TooManyLiveDrafts => {
                formatter.write_str("maximum live configuration drafts reached")
            }
            Self::TooManyOperations => {
                formatter.write_str("configuration draft operation limit reached")
            }
            Self::TooLarge(bytes) => write!(
                formatter,
                "configuration draft is too large ({bytes} bytes)"
            ),
            Self::Malformed => formatter.write_str("configuration draft is malformed"),
            Self::UnsupportedVersion => {
                formatter.write_str("configuration draft version is unsupported")
            }
            Self::InsecureDirectory => {
                formatter.write_str("configuration draft directory is insecure")
            }
            Self::InsecureFile => formatter.write_str("configuration draft file is insecure"),
            Self::EncodingFailed => formatter.write_str("configuration draft could not be encoded"),
            Self::ConfigurationRevisionConflict { expected, actual } => write!(
                formatter,
                "configuration revision conflict: expected {expected}, current {actual}"
            ),
            Self::DraftRevisionConflict { expected, actual } => write!(
                formatter,
                "draft revision conflict: expected {expected}, current {actual}"
            ),
            Self::Document(error) => error.fmt(formatter),
            Self::Operation(error) => error.fmt(formatter),
            Self::Bridge(error) => error.fmt(formatter),
            Self::InvalidOperationOutcome => formatter
                .write_str("configuration operation outcome did not match its candidate document"),
            Self::Preview(error) => {
                write!(formatter, "configuration draft preview failed: {error}")
            }
            Self::MergeConflict(paths) => write!(
                formatter,
                "configuration draft conflicts at {}",
                paths.join(", ")
            ),
            Self::Io(error) => write!(formatter, "configuration draft storage failed: {error}"),
        }
    }
}

impl Error for DraftError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use tempfile::tempdir;

    fn store() -> (tempfile::TempDir, DraftStore) {
        let directory = tempdir().unwrap();
        let store = DraftStore::in_directory(directory.path().join("drafts"));
        (directory, store)
    }

    #[test]
    fn begin_persists_private_credential_free_revisioned_draft() {
        let (_directory, store) = store();
        let state = PersistentState::minimal("server-id").unwrap();
        let draft = store
            .begin(&state, state.configuration_revision, 1_000)
            .unwrap();
        assert_eq!(draft.base_configuration_revision, 1);
        assert_eq!(draft.draft_revision, 1);
        assert_eq!(
            draft.expires_at,
            1_000 + CONFIGURATION_DRAFT_LIFETIME_MILLIS
        );

        let path = store.path(&draft.draft_id);
        let metadata = fs::metadata(&path).unwrap();
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
        let encoded = fs::read_to_string(path).unwrap();
        assert!(!encoded.contains("server-id"));
        assert!(!encoded.contains("trustedClients"));
        assert!(!encoded.contains("serverID"));
        assert_eq!(store.get(&draft.draft_id, 2_000).unwrap(), draft);
    }

    #[test]
    fn expected_revisions_and_expiry_fail_without_deleting_live_work() {
        let (_directory, store) = store();
        let state = PersistentState::minimal("server-id").unwrap();
        assert!(matches!(
            store.begin(&state, 99, 0),
            Err(DraftError::ConfigurationRevisionConflict {
                expected: 99,
                actual: 1
            })
        ));
        let draft = store.begin(&state, 1, 0).unwrap();
        assert!(matches!(
            store.discard(&draft.draft_id, 2, 1),
            Err(DraftError::DraftRevisionConflict {
                expected: 2,
                actual: 1
            })
        ));
        assert!(store.get(&draft.draft_id, 1).is_ok());
        assert!(matches!(
            store.get(&draft.draft_id, CONFIGURATION_DRAFT_LIFETIME_MILLIS),
            Err(DraftError::Expired)
        ));
        assert!(matches!(
            store.get(&draft.draft_id, 1),
            Err(DraftError::NotFound)
        ));
    }

    #[test]
    fn edits_compare_revisions_and_replay_operation_ids_idempotently() {
        let (_directory, store) = store();
        let mut state = PersistentState::minimal("server-id").unwrap();
        state.profiles[0]["futureField"] = serde_json::json!({"survives": true});
        let draft = store.begin(&state, 1, 0).unwrap();
        let operation_id = "00000000-0000-0000-0000-000000000401";
        let operation = ConfigurationOperation::ProfileRename {
            profile_id: state.active_profile_id.clone(),
            name: "Arcade".to_owned(),
        };
        let edited = store
            .edit(&draft.draft_id, 1, operation_id, &operation, 10)
            .unwrap();
        assert_eq!(edited.draft.draft_revision, 2);
        assert!(edited.operation.changed);
        assert!(!edited.idempotent_replay);
        assert_eq!(edited.draft.working_document.profiles[0]["name"], "Arcade");
        assert_eq!(
            edited.draft.working_document.profiles[0]["futureField"]["survives"],
            true
        );

        let replay = store
            .edit(&draft.draft_id, 1, operation_id, &operation, 20)
            .unwrap();
        assert_eq!(replay.draft.draft_revision, 2);
        assert!(replay.idempotent_replay);
        assert!(matches!(
            store.edit(&draft.draft_id, 2, operation_id, &operation, 25),
            Err(DraftError::DraftRevisionConflict {
                expected: 2,
                actual: 1
            })
        ));
        let conflicting_content = ConfigurationOperation::ProfileRename {
            profile_id: state.active_profile_id.clone(),
            name: "Different".to_owned(),
        };
        assert!(matches!(
            store.edit(&draft.draft_id, 1, operation_id, &conflicting_content, 30),
            Err(DraftError::OperationIdConflict)
        ));
        assert!(matches!(
            store.edit(
                &draft.draft_id,
                1,
                "00000000-0000-0000-0000-000000000402",
                &conflicting_content,
                30
            ),
            Err(DraftError::DraftRevisionConflict {
                expected: 1,
                actual: 2
            })
        ));
    }

    #[test]
    fn explicit_descriptor_closure_edits_replay_and_conflict_by_semantics() {
        let (_directory, store) = store();
        let state = PersistentState::minimal("server-id").unwrap();
        let draft = store.begin(&state, 1, 0).unwrap();
        let operation_id = "00000000-0000-0000-0000-000000000499";
        let descriptor = serde_json::json!({"type":"native.test","contentHash":"abc"});
        let edited = store
            .edit_with_descriptor(
                &draft.draft_id,
                1,
                operation_id,
                &descriptor,
                10,
                |document| {
                    let mut candidate = document.clone();
                    candidate.profiles[0]["name"] = serde_json::json!("Native");
                    Ok((
                        candidate,
                        ConfigurationOperationOutcome {
                            changed: true,
                            changed_paths: vec!["/profiles".to_owned()],
                        },
                    ))
                },
            )
            .unwrap();
        assert_eq!(edited.draft.draft_revision, 2);
        let replay = store
            .edit_with_descriptor(&draft.draft_id, 1, operation_id, &descriptor, 20, |_| {
                panic!("replay must not execute the closure")
            })
            .unwrap();
        assert!(replay.idempotent_replay);
        assert!(matches!(
            store.edit_with_descriptor(
                &draft.draft_id,
                1,
                operation_id,
                &serde_json::json!({"type":"native.test","contentHash":"changed"}),
                30,
                |_| panic!("conflict must not execute the closure"),
            ),
            Err(DraftError::OperationIdConflict)
        ));
    }

    #[test]
    fn no_op_edit_is_recorded_without_incrementing_the_draft_revision() {
        let (_directory, store) = store();
        let state = PersistentState::minimal("server-id").unwrap();
        let draft = store.begin(&state, 1, 0).unwrap();
        let operation = ConfigurationOperation::ProfileRename {
            profile_id: state.active_profile_id.clone(),
            name: "Default".to_owned(),
        };
        let result = store
            .edit(
                &draft.draft_id,
                1,
                "00000000-0000-0000-0000-000000000403",
                &operation,
                10,
            )
            .unwrap();
        assert_eq!(result.draft.draft_revision, 1);
        assert!(!result.operation.changed);
        assert_eq!(result.draft.operation_log.len(), 1);
    }

    #[test]
    fn rebase_merges_disjoint_authoritative_changes_and_replays_exact_id() {
        let (_directory, store) = store();
        let state = PersistentState::minimal("server-id").unwrap();
        let draft = store.begin(&state, 1, 0).unwrap();
        let edited = store
            .edit(
                &draft.draft_id,
                1,
                "00000000-0000-0000-0000-000000000404",
                &ConfigurationOperation::ProfileRename {
                    profile_id: state.active_profile_id.clone(),
                    name: "Draft Name".to_owned(),
                },
                10,
            )
            .unwrap();
        let mut current = ConfigurationDocument::from_state(&state).unwrap();
        current.profiles[0]["futureField"] = serde_json::json!({"newer": true});
        let rebase_id = "00000000-0000-0000-0000-000000000405";
        let rebased = store
            .rebase(
                &draft.draft_id,
                edited.draft.draft_revision,
                rebase_id,
                2,
                &current,
                20,
            )
            .unwrap();
        assert!(rebased.operation.changed);
        assert_eq!(rebased.draft.base_configuration_revision, 2);
        assert_eq!(rebased.draft.draft_revision, 3);
        assert_eq!(
            rebased.draft.working_document.profiles[0]["name"],
            "Draft Name"
        );
        assert_eq!(
            rebased.draft.working_document.profiles[0]["futureField"]["newer"],
            true
        );

        let replay = store
            .rebase(
                &draft.draft_id,
                edited.draft.draft_revision,
                rebase_id,
                2,
                &current,
                30,
            )
            .unwrap();
        assert!(replay.idempotent_replay);
        assert_eq!(replay.draft.draft_revision, 3);
        assert!(matches!(
            store.rebase(
                &draft.draft_id,
                rebased.draft.draft_revision,
                rebase_id,
                2,
                &current,
                40,
            ),
            Err(DraftError::DraftRevisionConflict {
                expected: 3,
                actual: 2
            })
        ));
    }

    #[test]
    fn rebase_conflict_keeps_persisted_draft_unchanged() {
        let (_directory, store) = store();
        let state = PersistentState::minimal("server-id").unwrap();
        let draft = store.begin(&state, 1, 0).unwrap();
        let edited = store
            .edit(
                &draft.draft_id,
                1,
                "00000000-0000-0000-0000-000000000406",
                &ConfigurationOperation::ProfileRename {
                    profile_id: state.active_profile_id.clone(),
                    name: "Draft Name".to_owned(),
                },
                10,
            )
            .unwrap();
        let mut current = ConfigurationDocument::from_state(&state).unwrap();
        current.profiles[0]["name"] = serde_json::Value::String("Current Name".to_owned());
        let error = store
            .rebase(
                &draft.draft_id,
                edited.draft.draft_revision,
                "00000000-0000-0000-0000-000000000407",
                2,
                &current,
                20,
            )
            .unwrap_err();
        assert!(matches!(error, DraftError::MergeConflict(_)));
        assert_eq!(
            store.get(&draft.draft_id, 30).unwrap().draft_revision,
            edited.draft.draft_revision
        );
    }

    #[test]
    fn operation_digests_are_deterministic_and_do_not_use_debug_output() {
        let operation = serde_json::json!({"type":"profile.rename","name":"Arcade"});
        let first = DraftStore::operation_digest(&operation).unwrap();
        let second = DraftStore::operation_digest(&operation).unwrap();
        assert_eq!(first, second);
        assert_eq!(first.len(), 64);
    }

    #[test]
    fn draft_reads_reject_symlink_replacement_and_insecure_mode() {
        let (root, store) = store();
        let state = PersistentState::minimal("server-id").unwrap();
        let draft = store.begin(&state, 1, 0).unwrap();
        let path = store.path(&draft.draft_id);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(matches!(
            store.get(&draft.draft_id, 1),
            Err(DraftError::InsecureFile)
        ));

        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        let replacement = root.path().join("replacement.json");
        fs::rename(&path, &replacement).unwrap();
        symlink(&replacement, &path).unwrap();
        assert!(matches!(
            store.get(&draft.draft_id, 1),
            Err(DraftError::InsecureFile)
        ));
    }

    #[test]
    fn symlinked_draft_directory_is_rejected() {
        let root = tempdir().unwrap();
        let target = root.path().join("target");
        fs::create_dir(&target).unwrap();
        let linked = root.path().join("drafts");
        symlink(&target, &linked).unwrap();
        let store = DraftStore::in_directory(linked);
        let state = PersistentState::minimal("server-id").unwrap();
        assert!(matches!(
            store.begin(&state, 1, 0),
            Err(DraftError::InsecureDirectory)
        ));
    }
}
