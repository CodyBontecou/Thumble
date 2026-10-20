//! Portable profile adoption v1, matching the native Swift control-plane contract.
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use uuid::Uuid;

pub const ADOPTION_MAX_BYTES: usize = 8 * 1024 * 1024;
pub const ADOPTION_CHUNK_BYTES: usize = 256 * 1024;
pub const ADOPTION_UPLOAD_LIFETIME: i64 = 30_000;
pub const ADOPTION_LEDGER_LIFETIME: i64 = 7 * 24 * 60 * 60 * 1000;
pub const ADOPTION_LEDGER_ENTRIES: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum AdoptionConflictPolicy {
    #[serde(rename = "append_as_copies")]
    AppendAsCopies,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AdoptionError {
    Unsupported,
    Unauthenticated,
    InvalidEnvelope,
    WrongServer,
    InvalidHash,
    InvalidSize,
    InvalidChunk,
    OutOfOrder,
    UploadBusy,
    UploadExpired,
    OperationConflict,
    OperationMissing,
    ArtifactInvalid,
    ImportFailed,
    Disconnected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AdoptionStatus {
    Accepted,
    Succeeded,
    Failed,
    Replayed,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdoptionMetadata {
    #[serde(rename = "operationID")]
    pub operation_id: Uuid,
    #[serde(rename = "recordID")]
    pub record_id: Uuid,
    #[serde(rename = "intendedServerID")]
    pub intended_server_id: String,
    pub content_hash: String,
    #[serde(rename = "rawSHA256")]
    pub raw_sha256: String,
    pub byte_count: usize,
    pub chunk_count: usize,
    pub conflict_policy: AdoptionConflictPolicy,
}

pub fn valid_adoption_server(value: &str) -> bool {
    !value.is_empty() && value.chars().count() <= 128 && !value.chars().any(char::is_control)
}
pub fn valid_adoption_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
impl AdoptionMetadata {
    pub fn validate(&self, server: &str) -> Result<(), AdoptionError> {
        if !valid_adoption_server(&self.intended_server_id) {
            return Err(AdoptionError::InvalidEnvelope);
        }
        if self.intended_server_id != server {
            return Err(AdoptionError::WrongServer);
        }
        if !valid_adoption_hash(&self.content_hash) || !valid_adoption_hash(&self.raw_sha256) {
            return Err(AdoptionError::InvalidHash);
        }
        if self.byte_count == 0
            || self.byte_count > ADOPTION_MAX_BYTES
            || self.chunk_count != self.byte_count.div_ceil(ADOPTION_CHUNK_BYTES)
        {
            return Err(AdoptionError::InvalidSize);
        }
        Ok(())
    }
    pub fn expected_chunk_bytes(&self, index: usize) -> Option<usize> {
        (index < self.chunk_count)
            .then(|| (self.byte_count - index * ADOPTION_CHUNK_BYTES).min(ADOPTION_CHUNK_BYTES))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdoptionResult {
    #[serde(rename = "operationID")]
    pub operation_id: Uuid,
    #[serde(rename = "recordID")]
    pub record_id: Uuid,
    #[serde(rename = "serverID")]
    pub server_id: String,
    pub content_hash: String,
    #[serde(rename = "rawSHA256")]
    pub raw_sha256: String,
    pub status: AdoptionStatus,
    pub error_code: Option<AdoptionError>,
    #[serde(rename = "destinationProfileIDs")]
    pub destination_profile_ids: Vec<Uuid>,
}
impl AdoptionResult {
    pub fn new(
        metadata: &AdoptionMetadata,
        server: &str,
        status: AdoptionStatus,
        error_code: Option<AdoptionError>,
        destination_profile_ids: Vec<Uuid>,
    ) -> Self {
        Self {
            operation_id: metadata.operation_id,
            record_id: metadata.record_id,
            server_id: server.into(),
            content_hash: metadata.content_hash.clone(),
            raw_sha256: metadata.raw_sha256.clone(),
            status,
            error_code,
            destination_profile_ids,
        }
    }
    pub fn validates(&self, metadata: &AdoptionMetadata) -> bool {
        metadata.validate(&metadata.intended_server_id).is_ok()
            && self.operation_id == metadata.operation_id
            && self.record_id == metadata.record_id
            && self.server_id == metadata.intended_server_id
            && self.content_hash == metadata.content_hash
            && self.raw_sha256 == metadata.raw_sha256
            && match self.status {
                AdoptionStatus::Accepted => {
                    self.error_code.is_none() && self.destination_profile_ids.is_empty()
                }
                AdoptionStatus::Succeeded | AdoptionStatus::Replayed => {
                    self.error_code.is_none()
                        && (1..=256).contains(&self.destination_profile_ids.len())
                        && self
                            .destination_profile_ids
                            .iter()
                            .collect::<HashSet<_>>()
                            .len()
                            == self.destination_profile_ids.len()
                }
                AdoptionStatus::Failed => {
                    self.error_code.is_some() && self.destination_profile_ids.is_empty()
                }
            }
    }
}

/// Saved in the same atomic authority write as the imported profiles.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdoptionReceipt {
    pub metadata: AdoptionMetadata,
    pub result: AdoptionResult,
    pub completed_at_milliseconds: i64,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn metadata() -> AdoptionMetadata {
        AdoptionMetadata {
            operation_id: Uuid::from_u128(1),
            record_id: Uuid::from_u128(2),
            intended_server_id: "fixture-server".into(),
            content_hash: "a".repeat(64),
            raw_sha256: "b".repeat(64),
            byte_count: ADOPTION_CHUNK_BYTES + 1,
            chunk_count: 2,
            conflict_policy: AdoptionConflictPolicy::AppendAsCopies,
        }
    }
    #[test]
    fn metadata_limits_and_native_json_names_are_exact() {
        let mut m = metadata();
        assert_eq!(m.validate("fixture-server"), Ok(()));
        assert_eq!(m.expected_chunk_bytes(0), Some(ADOPTION_CHUNK_BYTES));
        assert_eq!(m.expected_chunk_bytes(1), Some(1));
        assert_eq!(m.expected_chunk_bytes(2), None);
        assert_eq!(m.validate("other"), Err(AdoptionError::WrongServer));
        let json = serde_json::to_value(&m).unwrap();
        for key in [
            "operationID",
            "recordID",
            "intendedServerID",
            "contentHash",
            "rawSHA256",
            "byteCount",
            "chunkCount",
            "conflictPolicy",
        ] {
            assert!(json.get(key).is_some());
        }
        assert_eq!(json["conflictPolicy"], "append_as_copies");
        m.raw_sha256 = "B".repeat(64);
        assert_eq!(
            m.validate("fixture-server"),
            Err(AdoptionError::InvalidHash)
        );
        m = metadata();
        m.byte_count = ADOPTION_MAX_BYTES + 1;
        assert_eq!(
            m.validate("fixture-server"),
            Err(AdoptionError::InvalidSize)
        );
        m = metadata();
        m.chunk_count = 1;
        assert_eq!(
            m.validate("fixture-server"),
            Err(AdoptionError::InvalidSize)
        );
        m = metadata();
        m.intended_server_id = "bad\nserver".into();
        assert_eq!(
            m.validate(&m.intended_server_id),
            Err(AdoptionError::InvalidEnvelope)
        );
    }
    #[test]
    fn results_bind_every_identity_and_only_accept_unique_destination_ids() {
        let m = metadata();
        let result = AdoptionResult::new(
            &m,
            &m.intended_server_id,
            AdoptionStatus::Succeeded,
            None,
            vec![Uuid::from_u128(3)],
        );
        assert!(result.validates(&m));
        let mut invalid = result.clone();
        invalid.raw_sha256 = "c".repeat(64);
        assert!(!invalid.validates(&m));
        invalid = result.clone();
        invalid
            .destination_profile_ids
            .push(invalid.destination_profile_ids[0]);
        assert!(!invalid.validates(&m));
        invalid = result.clone();
        invalid.server_id = "other".into();
        assert!(!invalid.validates(&m));
        invalid = result.clone();
        invalid.status = AdoptionStatus::Accepted;
        assert!(!invalid.validates(&m));
        assert!(AdoptionResult::new(
            &m,
            &m.intended_server_id,
            AdoptionStatus::Failed,
            Some(AdoptionError::Disconnected),
            vec![]
        )
        .validates(&m));
    }
}
