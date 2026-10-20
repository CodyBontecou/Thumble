//! Shared-build upload assembly and read-only native artifact validation.
use crate::bridge::ConfigurationBridge;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use thumble_protocol::{
    AdoptionError, AdoptionMetadata, ADOPTION_MAX_BYTES, ADOPTION_UPLOAD_LIFETIME,
};
use uuid::Uuid;

pub(crate) fn raw_hash(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

pub(crate) struct NativeArtifactBridge(ConfigurationBridge);
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Response {
    schema_version: u32,
    #[serde(rename = "invocationID")]
    invocation_id: Uuid,
    content_hash: Option<String>,
    #[serde(rename = "rawSHA256")]
    raw_sha256: Option<String>,
    #[serde(rename = "activeProfileID")]
    active_profile_id: Option<Uuid>,
    #[serde(rename = "defaultProfileID")]
    default_profile_id: Option<Uuid>,
    profiles: Option<Vec<Value>>,
}
impl NativeArtifactBridge {
    pub(crate) fn discover() -> Result<Self, AdoptionError> {
        let bridge = Self(ConfigurationBridge::discover().map_err(|_| AdoptionError::Unsupported)?);
        let response = bridge.invoke(None)?;
        if response.profiles.is_some()
            || response.content_hash.is_some()
            || response.raw_sha256.is_some()
            || response.active_profile_id.is_some()
            || response.default_profile_id.is_some()
        {
            return Err(AdoptionError::Unsupported);
        }
        Ok(bridge)
    }
    fn invoke(&self, bytes: Option<&[u8]>) -> Result<Response, AdoptionError> {
        if bytes.is_some_and(|b| b.is_empty() || b.len() > ADOPTION_MAX_BYTES) {
            return Err(AdoptionError::InvalidSize);
        }
        let nonce = Uuid::new_v4();
        let mut request = json!({"schemaVersion":1,"invocationID":nonce,"profileArtifactCommand":if bytes.is_some() { "validate" } else { "capabilities" }});
        if let Some(bytes) = bytes {
            request["artifactBase64"] = Value::String(STANDARD.encode(bytes));
        }
        let mut input = serde_json::to_vec(&request).map_err(|_| AdoptionError::InvalidEnvelope)?;
        input.push(b'\n');
        let output = self
            .0
            .execute_with_limits(input, 12 * 1024 * 1024, 24 * 1024 * 1024)
            .map_err(|_| AdoptionError::ArtifactInvalid)?;
        let response: Response = thumble_protocol::decode_unique_json(&output)
            .map_err(|_| AdoptionError::ArtifactInvalid)?;
        if response.schema_version != 1 || response.invocation_id != nonce {
            return Err(AdoptionError::ArtifactInvalid);
        }
        Ok(response)
    }
    pub(crate) fn validate(
        &self,
        bytes: &[u8],
        metadata: &AdoptionMetadata,
    ) -> Result<Vec<Value>, AdoptionError> {
        if bytes.len() != metadata.byte_count {
            return Err(AdoptionError::InvalidSize);
        }
        if raw_hash(bytes) != metadata.raw_sha256 {
            return Err(AdoptionError::InvalidHash);
        }
        let artifact = thumble_core::ProfileArtifact::decode_json(bytes)
            .map_err(|_| AdoptionError::ArtifactInvalid)?;
        if artifact.content_hash.value != metadata.content_hash {
            return Err(AdoptionError::InvalidHash);
        }
        let response = self.invoke(Some(bytes))?;
        let profiles = response.profiles.ok_or(AdoptionError::ArtifactInvalid)?;
        if response.content_hash.as_deref() != Some(metadata.content_hash.as_str())
            || response.raw_sha256.as_deref() != Some(metadata.raw_sha256.as_str())
            || profiles.len() != artifact.profiles.len()
            || !(1..=256).contains(&profiles.len())
            || response.active_profile_id.map(|id| id.to_string())
                != artifact
                    .active_profile_id
                    .as_ref()
                    .map(|id| id.to_ascii_lowercase())
            || response.default_profile_id.map(|id| id.to_string())
                != artifact
                    .default_profile_id
                    .as_ref()
                    .map(|id| id.to_ascii_lowercase())
            || profiles.iter().zip(&artifact.profiles).any(|(typed, raw)| {
                typed
                    .get("id")
                    .and_then(Value::as_str)
                    .and_then(|id| Uuid::parse_str(id).ok())
                    != raw
                        .get("id")
                        .and_then(Value::as_str)
                        .and_then(|id| Uuid::parse_str(id).ok())
            })
        {
            return Err(AdoptionError::ArtifactInvalid);
        }
        Ok(profiles)
    }
}

/// Carry forward safe unknown metadata while installing native normalized model
/// fields. UUID arrays and keyed-pair dictionaries retain their original owners.
pub(crate) fn normalized_profile(raw: &Value, typed: &Value) -> Value {
    fn merge(raw: &Value, typed: &Value, field: &str) -> Value {
        match (raw, typed) {
            (Value::Object(before), Value::Object(after)) => {
                let mut result = before.clone();
                let known = if after.contains_key("customization") {
                    &[
                        "id",
                        "name",
                        "customization",
                        "landscapeCustomization",
                        "portraitCustomization",
                        "skinReference",
                        "skinBaselineCustomization",
                        "landscapeSkinBaselineCustomization",
                        "portraitSkinBaselineCustomization",
                        "orientationPreference",
                        "outputMode",
                        "updatedAt",
                    ][..]
                } else if after.contains_key("kind") && after.contains_key("layout") {
                    &[
                        "label",
                        "kind",
                        "layout",
                        "visualRole",
                        "output",
                        "defaultOutput",
                        "partOutputs",
                        "presentation",
                        "joystickMapping",
                        "joystickOutputSettings",
                        "triggerSettings",
                        "trackpadSettings",
                    ][..]
                } else {
                    &[][..]
                };
                for key in known {
                    if !after.contains_key(*key) {
                        result.remove(*key);
                    }
                }
                for (key, value) in after {
                    result.insert(
                        key.clone(),
                        merge(before.get(key).unwrap_or(&Value::Null), value, key),
                    );
                }
                Value::Object(result)
            }
            (Value::Array(before), Value::Array(after)) => {
                if matches!(
                    field,
                    "labelOverrides" | "buttonCustomizations" | "partOutputs"
                ) && before.len() % 2 == 0
                    && after.len() % 2 == 0
                {
                    let mut result = Vec::with_capacity(after.len());
                    for pair in after.chunks_exact(2) {
                        let old = before.chunks_exact(2).find(|old| {
                            match (old[0].as_str(), pair[0].as_str()) {
                                (Some(a), Some(b)) => a.eq_ignore_ascii_case(b),
                                _ => false,
                            }
                        });
                        result.push(pair[0].clone());
                        result.push(merge(
                            old.map(|p| &p[1]).unwrap_or(&Value::Null),
                            &pair[1],
                            "",
                        ));
                    }
                    return Value::Array(result);
                }
                Value::Array(
                    after
                        .iter()
                        .map(|value| {
                            let id = value.get("id").and_then(Value::as_str);
                            let old = id.and_then(|id| {
                                before.iter().find(|old| {
                                    old.get("id")
                                        .and_then(Value::as_str)
                                        .is_some_and(|other| other.eq_ignore_ascii_case(id))
                                })
                            });
                            old.map_or_else(|| value.clone(), |old| merge(old, value, ""))
                        })
                        .collect(),
                )
            }
            _ => typed.clone(),
        }
    }
    merge(raw, typed, "")
}

pub(crate) struct Upload {
    pub(crate) metadata: AdoptionMetadata,
    expires_at: i64,
    next: usize,
    bytes: Vec<u8>,
}
impl Upload {
    pub(crate) fn begin(metadata: AdoptionMetadata, now: i64) -> Self {
        Self {
            expires_at: now.saturating_add(ADOPTION_UPLOAD_LIFETIME),
            bytes: Vec::with_capacity(metadata.byte_count),
            metadata,
            next: 0,
        }
    }
    pub(crate) fn expired(&self, now: i64) -> bool {
        now >= self.expires_at
    }
    pub(crate) fn append(
        &mut self,
        index: i64,
        encoded: &str,
        now: i64,
    ) -> Result<(), AdoptionError> {
        if self.expired(now) {
            return Err(AdoptionError::UploadExpired);
        }
        if index < 0 || index as usize != self.next {
            return Err(AdoptionError::OutOfOrder);
        }
        let expected = self
            .metadata
            .expected_chunk_bytes(self.next)
            .ok_or(AdoptionError::InvalidChunk)?;
        if encoded.len() != expected.div_ceil(3) * 4 {
            return Err(AdoptionError::InvalidChunk);
        }
        let chunk = STANDARD
            .decode(encoded)
            .map_err(|_| AdoptionError::InvalidChunk)?;
        if chunk.len() != expected || self.bytes.len() > self.metadata.byte_count - expected {
            return Err(AdoptionError::InvalidChunk);
        }
        self.bytes.extend_from_slice(&chunk);
        self.next += 1;
        Ok(())
    }
    pub(crate) fn complete(self, now: i64) -> Result<(AdoptionMetadata, Vec<u8>), AdoptionError> {
        self.ready(now)?;
        Ok((self.metadata, self.bytes))
    }
    pub(crate) fn ready(&self, now: i64) -> Result<(), AdoptionError> {
        if self.expired(now) {
            return Err(AdoptionError::UploadExpired);
        }
        if self.next != self.metadata.chunk_count || self.bytes.len() != self.metadata.byte_count {
            return Err(AdoptionError::OutOfOrder);
        }
        if raw_hash(&self.bytes) != self.metadata.raw_sha256 {
            return Err(AdoptionError::InvalidHash);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use thumble_protocol::{AdoptionConflictPolicy, ADOPTION_CHUNK_BYTES};
    fn metadata(bytes: &[u8]) -> AdoptionMetadata {
        AdoptionMetadata {
            operation_id: Uuid::from_u128(1),
            record_id: Uuid::from_u128(2),
            intended_server_id: "fixture".into(),
            content_hash: "a".repeat(64),
            raw_sha256: raw_hash(bytes),
            byte_count: bytes.len(),
            chunk_count: bytes.len().div_ceil(ADOPTION_CHUNK_BYTES),
            conflict_policy: AdoptionConflictPolicy::AppendAsCopies,
        }
    }
    #[test]
    fn ordered_chunks_are_bounded_complete_and_exact() {
        let bytes = vec![7; ADOPTION_CHUNK_BYTES + 3];
        let m = metadata(&bytes);
        let mut u = Upload::begin(m.clone(), 0);
        assert_eq!(
            u.append(1, &STANDARD.encode(&bytes[..3]), 1),
            Err(AdoptionError::OutOfOrder)
        );
        u.append(0, &STANDARD.encode(&bytes[..ADOPTION_CHUNK_BYTES]), 1)
            .unwrap();
        assert_eq!(u.ready(1), Err(AdoptionError::OutOfOrder));
        assert_eq!(u.append(1, "AA==", 1), Err(AdoptionError::InvalidChunk));
        u.append(1, &STANDARD.encode(&bytes[ADOPTION_CHUNK_BYTES..]), 1)
            .unwrap();
        assert_eq!(u.complete(2).unwrap(), (m, bytes));
    }
    #[test]
    fn expiry_bad_base64_and_raw_hash_cannot_become_completed_uploads() {
        let bytes = b"fixture";
        let m = metadata(bytes);
        let mut u = Upload::begin(m.clone(), 0);
        assert_eq!(
            u.append(0, "!!!!!!!!!!!!", 1),
            Err(AdoptionError::InvalidChunk)
        );
        assert_eq!(
            u.append(0, &STANDARD.encode(bytes), ADOPTION_UPLOAD_LIFETIME),
            Err(AdoptionError::UploadExpired)
        );
        let mut u = Upload::begin(m, 0);
        u.append(0, &STANDARD.encode(b"changed"), 1).unwrap();
        assert_eq!(u.complete(1).err(), Some(AdoptionError::InvalidHash));
    }
}
