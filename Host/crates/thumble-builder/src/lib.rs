//! Deterministic, credential-free hosted builder sessions.
//!
//! The session machine owns no clock, randomness, storage, sockets, processes,
//! or input APIs. Callers supply opaque UUIDs and timestamps and are responsible
//! for principal-scoped storage outside this crate.

#![forbid(unsafe_code)]

mod templates;

pub use templates::{validate_builder_template_fixtures, BuilderTemplate, BuilderTemplateMetadata};

use serde::{de, Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::error::Error;
use std::fmt;
use thumble_core::{
    generated_modifier_mask, generated_semantic_key_code, plan_generation_spec, ButtonBindings,
    ConfigurationDocument, ControllerLayoutQualitySnapshot, ControllerSnapshot,
    GenerationSpecError, KeyBinding, OutputBinding, PersistentState, ProfileArtifact,
    ProfileArtifactSelection,
};
use thumble_protocol::GameButton;
use uuid::Uuid;

pub const BUILDER_SESSION_VERSION: u32 = 1;
pub const MAXIMUM_BUILDER_SESSION_TTL_SECONDS: i64 = 24 * 60 * 60;
pub const MAXIMUM_BUILDER_OPERATIONS: usize = 256;
pub const MAXIMUM_BUILDER_SESSION_JSON_BYTES: usize = 18 * 1024 * 1024;
pub const MAXIMUM_BUILDER_CHANGED_PATHS: usize = 16;
pub const MAXIMUM_BUILDER_STATUS_PROFILES: usize = 64;
pub const MAXIMUM_I_JSON_SAFE_INTEGER: i64 = 9_007_199_254_740_991;
const MAXIMUM_OPERATION_ID_BYTES: usize = 36;
const MAXIMUM_ELEMENT_ID_BYTES: usize = 128;
const MAXIMUM_PROFILE_NAME_CHARACTERS: usize = 256;
const SHA256_HEX_BYTES: usize = 64;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum BuilderEdit {
    #[serde(rename = "profile.rename")]
    ProfileRename { name: String },
    #[serde(rename = "control.layout")]
    ControlLayout {
        #[serde(rename = "elementID")]
        element_id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        x: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        y: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        width: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        height: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        hidden: Option<bool>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        locked: Option<bool>,
    },
    #[serde(rename = "control.remove")]
    ControlRemove {
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "binding.set")]
    BindingSet {
        button: String,
        key: String,
        #[serde(default)]
        modifiers: Vec<String>,
    },
    #[serde(rename = "binding.clear")]
    BindingClear { button: String },
    #[serde(rename = "output.mode")]
    OutputMode { mode: BuilderOutputMode },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BuilderOutputMode {
    Keyboard,
    Controller,
    Custom,
}

impl BuilderOutputMode {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Keyboard => "keyboard",
            Self::Controller => "controller",
            Self::Custom => "custom",
        }
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderOperationRecord {
    #[serde(rename = "operationID")]
    pub operation_id: String,
    #[serde(rename = "descriptor")]
    descriptor: Value,
    pub descriptor_digest: String,
    pub base_revision: u64,
    pub result_revision: u64,
    pub changed: bool,
    pub changed_paths: Vec<String>,
    pub applied_at: i64,
}

impl fmt::Debug for BuilderOperationRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BuilderOperationRecord")
            .field("operation_id", &self.operation_id)
            .field("descriptor_digest", &self.descriptor_digest)
            .field("base_revision", &self.base_revision)
            .field("result_revision", &self.result_revision)
            .field("changed", &self.changed)
            .field("changed_paths", &self.changed_paths)
            .field("applied_at", &self.applied_at)
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderArtifactReceipt {
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub revision: u64,
    pub content_hash: String,
    pub document_digest: String,
    pub emitted_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderArtifactEmission {
    #[serde(rename = "artifactJSON")]
    pub artifact_json: String,
    pub receipt: BuilderArtifactReceipt,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderEmissionHandoff {
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub revision: u64,
    pub content_hash: String,
    pub delete_session: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderDiscardReceipt {
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub revision: u64,
    pub discarded_at: i64,
    pub operation_count: usize,
    pub had_emitted_artifact: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BuilderSessionState {
    Active,
    Expired,
    Discarded,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderStatusProfile {
    #[serde(rename = "profileID")]
    pub profile_id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderSessionStatus {
    #[serde(rename = "sessionID")]
    pub session_id: String,
    pub revision: u64,
    pub created_at: i64,
    pub updated_at: i64,
    pub expires_at: i64,
    pub state: BuilderSessionState,
    pub profile_count: usize,
    pub profiles: Vec<BuilderStatusProfile>,
    pub omitted_profile_count: usize,
    pub operation_count: usize,
    pub emitted_revision: Option<u64>,
    pub emitted_content_hash: Option<String>,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderValidation {
    pub valid: bool,
    pub layout_quality: ControllerLayoutQualitySnapshot,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderGenerationWarning {
    pub code: String,
    pub source_ordinal: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderGenerationAssignment {
    pub source_ordinal: usize,
    pub button: String,
    #[serde(rename = "elementID")]
    pub element_id: String,
    pub kind: String,
    pub used_explicit_button: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderGenerationDrop {
    pub source_ordinal: usize,
    pub reason: String,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderGenerationSummary {
    pub descriptor_digest: String,
    pub base_revision: u64,
    pub result_revision: u64,
    pub changed: bool,
    pub warnings: Vec<BuilderGenerationWarning>,
    pub omitted_warning_count: usize,
    pub assigned_controls: Vec<BuilderGenerationAssignment>,
    pub dropped_controls: Vec<BuilderGenerationDrop>,
    pub layout_quality: ControllerLayoutQualitySnapshot,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    pub profile_name: String,
    pub artifact_content_hash: String,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderTemplateSummary {
    #[serde(rename = "templateID")]
    pub template_id: String,
    pub template_revision: u32,
    pub base_revision: u64,
    pub result_revision: u64,
    pub changed: bool,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    pub profile_name: String,
    pub custom_element_count: usize,
    pub layout_quality: ControllerLayoutQualitySnapshot,
}

impl fmt::Debug for BuilderTemplateSummary {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BuilderTemplateSummary")
            .field("template_id", &self.template_id)
            .field("template_revision", &self.template_revision)
            .field("base_revision", &self.base_revision)
            .field("result_revision", &self.result_revision)
            .field("changed", &self.changed)
            .field("profile_id", &self.profile_id)
            .field("profile_name", &self.profile_name)
            .field("custom_element_count", &self.custom_element_count)
            .field("layout_issue_count", &self.layout_quality.issue_count)
            .finish()
    }
}

/// Serializable session state. Principal ownership is deliberately external.
/// All invariant-bearing fields are private; deserialization always validates
/// the complete persisted history before constructing a public session.
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BuilderSession {
    version: u32,
    #[serde(rename = "sessionID")]
    session_id: String,
    revision: u64,
    document: ConfigurationDocument,
    document_digest: String,
    created_at: i64,
    updated_at: i64,
    expires_at: i64,
    operations: Vec<BuilderOperationRecord>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    emitted_artifact_receipt: Option<BuilderArtifactReceipt>,
    discarded: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    discarded_at: Option<i64>,
    #[serde(skip, default)]
    cached_artifact_json: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BuilderSessionWire {
    version: u32,
    #[serde(rename = "sessionID")]
    session_id: String,
    revision: u64,
    document: ConfigurationDocument,
    document_digest: String,
    created_at: i64,
    updated_at: i64,
    expires_at: i64,
    operations: Vec<BuilderOperationRecord>,
    #[serde(default)]
    emitted_artifact_receipt: Option<BuilderArtifactReceipt>,
    discarded: bool,
    #[serde(default)]
    discarded_at: Option<i64>,
}

impl<'de> Deserialize<'de> for BuilderSession {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let wire = BuilderSessionWire::deserialize(deserializer)?;
        let session = Self {
            version: wire.version,
            session_id: wire.session_id,
            revision: wire.revision,
            document: wire.document,
            document_digest: wire.document_digest,
            created_at: wire.created_at,
            updated_at: wire.updated_at,
            expires_at: wire.expires_at,
            operations: wire.operations,
            emitted_artifact_receipt: wire.emitted_artifact_receipt,
            discarded: wire.discarded,
            discarded_at: wire.discarded_at,
            cached_artifact_json: None,
        };
        session.revalidate().map_err(de::Error::custom)?;
        Ok(session)
    }
}

impl PartialEq for BuilderSession {
    fn eq(&self, other: &Self) -> bool {
        self.version == other.version
            && self.session_id == other.session_id
            && self.revision == other.revision
            && self.document == other.document
            && self.document_digest == other.document_digest
            && self.created_at == other.created_at
            && self.updated_at == other.updated_at
            && self.expires_at == other.expires_at
            && self.operations == other.operations
            && self.emitted_artifact_receipt == other.emitted_artifact_receipt
            && self.discarded == other.discarded
            && self.discarded_at == other.discarded_at
    }
}

impl fmt::Debug for BuilderSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BuilderSession")
            .field("version", &self.version)
            .field("session_id", &self.session_id)
            .field("revision", &self.revision)
            .field("profile_count", &self.document.profiles.len())
            .field("created_at", &self.created_at)
            .field("updated_at", &self.updated_at)
            .field("expires_at", &self.expires_at)
            .field("operation_count", &self.operations.len())
            .field(
                "has_emitted_artifact",
                &self.emitted_artifact_receipt.is_some(),
            )
            .field("discarded", &self.discarded)
            .finish()
    }
}

impl BuilderSession {
    /// Start from core's canonical, credential-empty minimal configuration.
    pub fn begin(
        session_id: impl Into<String>,
        created_at: i64,
        ttl_seconds: i64,
    ) -> Result<Self, BuilderError> {
        let session_id = session_id.into();
        validate_uuid(&session_id, BuilderError::InvalidSessionId)?;
        validate_nonnegative_timestamp(created_at)?;
        if !(1..=MAXIMUM_BUILDER_SESSION_TTL_SECONDS).contains(&ttl_seconds) {
            return Err(BuilderError::InvalidTtl(ttl_seconds));
        }
        let expires_at = created_at
            .checked_add(ttl_seconds)
            .filter(|value| *value <= MAXIMUM_I_JSON_SAFE_INTEGER)
            .ok_or(BuilderError::TimestampOverflow)?;
        let state = PersistentState::minimal("credential-free-builder")
            .map_err(|_| BuilderError::InvalidDocument)?;
        let document =
            ConfigurationDocument::from_state(&state).map_err(|_| BuilderError::InvalidDocument)?;
        let document_digest = canonical_digest(&document)?;
        let session = Self {
            version: BUILDER_SESSION_VERSION,
            session_id,
            revision: 1,
            document,
            document_digest,
            created_at,
            updated_at: created_at,
            expires_at,
            operations: Vec::new(),
            emitted_artifact_receipt: None,
            discarded: false,
            discarded_at: None,
            cached_artifact_json: None,
        };
        session.revalidate()?;
        Ok(session)
    }

    pub const fn version(&self) -> u32 {
        self.version
    }

    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    pub const fn revision(&self) -> u64 {
        self.revision
    }

    /// Digest of the trusted persisted configuration. This is safe metadata;
    /// the underlying configuration document is intentionally not exposed.
    pub fn configuration_digest(&self) -> &str {
        &self.document_digest
    }

    pub const fn created_at(&self) -> i64 {
        self.created_at
    }

    pub const fn updated_at(&self) -> i64 {
        self.updated_at
    }

    pub const fn expires_at(&self) -> i64 {
        self.expires_at
    }

    /// Number of persisted idempotency records, without exposing operation
    /// descriptors or the raw trusted persistence document.
    pub const fn operation_count(&self) -> usize {
        self.operations.len()
    }

    pub fn emitted_artifact_receipt(&self) -> Option<&BuilderArtifactReceipt> {
        self.emitted_artifact_receipt.as_ref()
    }

    pub const fn discarded(&self) -> bool {
        self.discarded
    }

    pub const fn discarded_at(&self) -> Option<i64> {
        self.discarded_at
    }

    pub fn status(&self, now: i64) -> Result<BuilderSessionStatus, BuilderError> {
        self.revalidate()?;
        validate_nonnegative_timestamp(now)?;
        if now < self.created_at {
            return Err(BuilderError::InvalidTimestamp);
        }
        let profiles = self
            .document
            .profiles
            .iter()
            .take(MAXIMUM_BUILDER_STATUS_PROFILES)
            .map(|profile| BuilderStatusProfile {
                profile_id: bounded_string(
                    profile.get("id").and_then(Value::as_str).unwrap_or(""),
                    128,
                ),
                name: bounded_chars(
                    profile
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("Unnamed"),
                    MAXIMUM_PROFILE_NAME_CHARACTERS,
                ),
            })
            .collect::<Vec<_>>();
        let state = if self.discarded {
            BuilderSessionState::Discarded
        } else if now >= self.expires_at {
            BuilderSessionState::Expired
        } else {
            BuilderSessionState::Active
        };
        Ok(BuilderSessionStatus {
            session_id: self.session_id.clone(),
            revision: self.revision,
            created_at: self.created_at,
            updated_at: self.updated_at,
            expires_at: self.expires_at,
            state,
            profile_count: self.document.profiles.len(),
            omitted_profile_count: self.document.profiles.len().saturating_sub(profiles.len()),
            profiles,
            operation_count: self.operations.len(),
            emitted_revision: self
                .emitted_artifact_receipt
                .as_ref()
                .map(|receipt| receipt.revision),
            emitted_content_hash: self
                .emitted_artifact_receipt
                .as_ref()
                .map(|receipt| receipt.content_hash.clone()),
        })
    }

    pub fn apply_edit(
        &mut self,
        operation_id: &str,
        expected_revision: u64,
        edit: BuilderEdit,
        now: i64,
    ) -> Result<BuilderOperationRecord, BuilderError> {
        self.ensure_active(now)?;
        validate_uuid(operation_id, BuilderError::InvalidOperationId)?;
        validate_edit(&edit)?;
        let descriptor =
            serde_json::to_value(&edit).map_err(|_| BuilderError::CanonicalizationFailed)?;
        let descriptor_digest = canonical_digest(&descriptor)?;
        if let Some(record) = self.replay(operation_id, &descriptor_digest, expected_revision)? {
            return Ok(record);
        }
        self.ensure_new_operation(expected_revision)?;

        let mut candidate = self.document.clone();
        canonicalize_active_profile(&mut candidate)?;
        let changed_paths = apply_edit_to_document(&mut candidate, &edit, now)?;
        candidate
            .validate()
            .map_err(|_| BuilderError::InvalidDocument)?;
        ProfileArtifact::validate_configuration_portability(&candidate)
            .map_err(|_| BuilderError::DocumentNotPortable)?;
        let changed = candidate != self.document;
        let result_revision = if changed {
            expected_revision
                .checked_add(1)
                .ok_or(BuilderError::RevisionOverflow)?
        } else {
            expected_revision
        };
        let record = BuilderOperationRecord {
            operation_id: operation_id.to_owned(),
            descriptor,
            descriptor_digest,
            base_revision: expected_revision,
            result_revision,
            changed,
            changed_paths: if changed { changed_paths } else { Vec::new() },
            applied_at: now,
        };
        if changed {
            self.document_digest = canonical_digest(&candidate)?;
            self.document = candidate;
            self.revision = result_revision;
            self.invalidate_emission();
        }
        self.updated_at = now;
        self.operations.push(record.clone());
        Ok(record)
    }

    pub fn generate_from_spec(
        &mut self,
        operation_id: &str,
        expected_revision: u64,
        spec_json: &[u8],
        requested_game_name: Option<&str>,
        now: i64,
    ) -> Result<BuilderGenerationSummary, BuilderError> {
        self.ensure_active(now)?;
        validate_uuid(operation_id, BuilderError::InvalidOperationId)?;
        let plan = plan_generation_spec(spec_json, requested_game_name)
            .map_err(|error| BuilderError::Generation(map_generation_error(&error)))?;
        let generation_descriptor = serde_json::json!({
            "type": "generate.from_spec",
            "descriptorDigest": plan.descriptor_digest,
            "requestedGameName": requested_game_name
        });
        let descriptor_digest = canonical_digest(&generation_descriptor)?;
        if let Some(record) = self.replay(operation_id, &descriptor_digest, expected_revision)? {
            let candidate = plan
                .artifact
                .to_configuration_document()
                .map_err(|_| BuilderError::InvalidGeneratedArtifact)?;
            return generation_summary(&plan, &candidate, &record);
        }
        self.ensure_new_operation(expected_revision)?;
        let candidate = plan
            .artifact
            .to_configuration_document()
            .map_err(|_| BuilderError::InvalidGeneratedArtifact)?;
        candidate
            .validate()
            .map_err(|_| BuilderError::InvalidGeneratedArtifact)?;
        ProfileArtifact::validate_configuration_portability(&candidate)
            .map_err(|_| BuilderError::InvalidGeneratedArtifact)?;
        let changed = candidate != self.document;
        let result_revision = if changed {
            expected_revision
                .checked_add(1)
                .ok_or(BuilderError::RevisionOverflow)?
        } else {
            expected_revision
        };
        let record = BuilderOperationRecord {
            operation_id: operation_id.to_owned(),
            descriptor: generation_descriptor,
            descriptor_digest,
            base_revision: expected_revision,
            result_revision,
            changed,
            changed_paths: if changed {
                vec!["/document".to_owned()]
            } else {
                Vec::new()
            },
            applied_at: now,
        };
        let summary = generation_summary(&plan, &candidate, &record)?;
        if changed {
            self.document_digest = canonical_digest(&candidate)?;
            self.document = candidate;
            self.revision = result_revision;
            self.invalidate_emission();
        }
        self.updated_at = now;
        self.operations.push(record);
        Ok(summary)
    }

    pub fn install_template(
        &mut self,
        operation_id: &str,
        expected_revision: u64,
        template: BuilderTemplate,
        name: Option<&str>,
        now: i64,
    ) -> Result<BuilderTemplateSummary, BuilderError> {
        self.ensure_active(now)?;
        validate_uuid(operation_id, BuilderError::InvalidOperationId)?;
        validate_builder_template_fixtures()?;
        let (candidate, profile_id, profile_name, custom_element_count) =
            templates::materialize_template_document(
                &self.session_id,
                operation_id,
                template,
                name,
            )?;
        let descriptor = serde_json::json!({
            "type": "template.install",
            "templateID": template.template_id(),
            "templateRevision": template.revision(),
            "name": profile_name,
        });
        let descriptor_digest = canonical_digest(&descriptor)?;
        if let Some(record) = self.replay(operation_id, &descriptor_digest, expected_revision)? {
            return template_summary(
                template,
                &candidate,
                profile_id,
                profile_name,
                custom_element_count,
                &record,
            );
        }
        self.ensure_new_operation(expected_revision)?;
        candidate
            .validate()
            .map_err(|_| BuilderError::InvalidTemplateFixtures)?;
        ProfileArtifact::validate_configuration_portability(&candidate)
            .map_err(|_| BuilderError::InvalidTemplateFixtures)?;
        ProfileArtifact::from_configuration(&candidate, ProfileArtifactSelection::All, 0)
            .map_err(|_| BuilderError::InvalidTemplateFixtures)?;
        let changed = candidate != self.document;
        let result_revision = if changed {
            expected_revision
                .checked_add(1)
                .ok_or(BuilderError::RevisionOverflow)?
        } else {
            expected_revision
        };
        let record = BuilderOperationRecord {
            operation_id: operation_id.to_owned(),
            descriptor,
            descriptor_digest,
            base_revision: expected_revision,
            result_revision,
            changed,
            changed_paths: if changed {
                vec!["/document".to_owned()]
            } else {
                Vec::new()
            },
            applied_at: now,
        };
        let summary = template_summary(
            template,
            &candidate,
            profile_id,
            profile_name,
            custom_element_count,
            &record,
        )?;
        if changed {
            self.document_digest = canonical_digest(&candidate)?;
            self.document = candidate;
            self.revision = result_revision;
            self.invalidate_emission();
        }
        self.updated_at = now;
        self.operations.push(record);
        Ok(summary)
    }

    pub fn validate(&self, now: i64) -> Result<BuilderValidation, BuilderError> {
        self.ensure_active_read(now)?;
        self.document
            .validate()
            .map_err(|_| BuilderError::InvalidDocument)?;
        let snapshot = snapshot_document(&self.document)?;
        Ok(BuilderValidation {
            valid: true,
            layout_quality: snapshot.layout_quality,
        })
    }

    pub fn preview(&self, now: i64) -> Result<ControllerSnapshot, BuilderError> {
        self.ensure_active_read(now)?;
        snapshot_document(&self.document)
    }

    pub fn emit_artifact(
        &mut self,
        expected_revision: u64,
        now: i64,
    ) -> Result<BuilderArtifactEmission, BuilderError> {
        self.ensure_active(now)?;
        if expected_revision != self.revision {
            return Err(BuilderError::RevisionConflict {
                expected: expected_revision,
                actual: self.revision,
            });
        }
        if let Some(receipt) = self.emitted_artifact_receipt.clone() {
            let (regenerated, content_hash) = self.artifact_json_and_hash()?;
            if content_hash != receipt.content_hash {
                return Err(BuilderError::InvalidArtifactReceipt);
            }
            let json = self.cached_artifact_json.clone().unwrap_or(regenerated);
            self.cached_artifact_json = Some(json.clone());
            return Ok(BuilderArtifactEmission {
                artifact_json: json,
                receipt,
            });
        }
        let (artifact_json, content_hash) = self.artifact_json_and_hash()?;
        let receipt = BuilderArtifactReceipt {
            session_id: self.session_id.clone(),
            revision: self.revision,
            content_hash,
            document_digest: self.document_digest.clone(),
            emitted_at: now,
        };
        self.updated_at = now;
        self.cached_artifact_json = Some(artifact_json.clone());
        self.emitted_artifact_receipt = Some(receipt.clone());
        Ok(BuilderArtifactEmission {
            artifact_json,
            receipt,
        })
    }

    /// Return the explicit deletion handoff after successful downstream use.
    /// This method does not delete or persist anything itself.
    pub fn mark_emitted(
        &self,
        expected_revision: u64,
        now: i64,
    ) -> Result<BuilderEmissionHandoff, BuilderError> {
        self.ensure_active_read(now)?;
        if expected_revision != self.revision {
            return Err(BuilderError::RevisionConflict {
                expected: expected_revision,
                actual: self.revision,
            });
        }
        let receipt = self
            .emitted_artifact_receipt
            .as_ref()
            .filter(|receipt| receipt.revision == expected_revision)
            .ok_or(BuilderError::ArtifactNotEmitted)?;
        Ok(BuilderEmissionHandoff {
            session_id: self.session_id.clone(),
            revision: receipt.revision,
            content_hash: receipt.content_hash.clone(),
            delete_session: true,
        })
    }

    pub fn discard(
        &mut self,
        expected_revision: u64,
        now: i64,
    ) -> Result<BuilderDiscardReceipt, BuilderError> {
        self.ensure_active(now)?;
        if expected_revision != self.revision {
            return Err(BuilderError::RevisionConflict {
                expected: expected_revision,
                actual: self.revision,
            });
        }
        self.discarded = true;
        self.discarded_at = Some(now);
        self.updated_at = now;
        Ok(BuilderDiscardReceipt {
            session_id: self.session_id.clone(),
            revision: self.revision,
            discarded_at: now,
            operation_count: self.operations.len(),
            had_emitted_artifact: self.emitted_artifact_receipt.is_some(),
        })
    }

    /// Encode the complete trusted persistence representation.
    ///
    /// This codec is for bounded, principal-scoped storage and trusted test
    /// fixtures only. Its output must never be used as an MCP/tool projection;
    /// use status, validation, preview, generation summaries, and artifact
    /// emission for untrusted clients.
    pub fn encode_json(&self) -> Result<Vec<u8>, BuilderError> {
        self.revalidate()?;
        let bytes = serde_json::to_vec(self).map_err(|_| BuilderError::EncodingFailed)?;
        if bytes.len() > MAXIMUM_BUILDER_SESSION_JSON_BYTES {
            return Err(BuilderError::SessionJsonTooLarge(bytes.len()));
        }
        Ok(bytes)
    }

    /// Decode and fully validate the trusted persistence representation.
    /// This is not an untrusted tool input codec or a tool result projection.
    pub fn decode_json(bytes: &[u8]) -> Result<Self, BuilderError> {
        if bytes.len() > MAXIMUM_BUILDER_SESSION_JSON_BYTES {
            return Err(BuilderError::SessionJsonTooLarge(bytes.len()));
        }
        serde_json::from_slice(bytes).map_err(|_| BuilderError::DecodingFailed)
    }

    fn replay(
        &self,
        operation_id: &str,
        digest: &str,
        base_revision: u64,
    ) -> Result<Option<BuilderOperationRecord>, BuilderError> {
        let Some(existing) = self
            .operations
            .iter()
            .find(|record| record.operation_id == operation_id)
        else {
            return Ok(None);
        };
        if existing.descriptor_digest == digest && existing.base_revision == base_revision {
            return Ok(Some(existing.clone()));
        }
        Err(BuilderError::OperationConflict)
    }

    fn ensure_new_operation(&self, expected_revision: u64) -> Result<(), BuilderError> {
        if expected_revision != self.revision {
            return Err(BuilderError::RevisionConflict {
                expected: expected_revision,
                actual: self.revision,
            });
        }
        if self.operations.len() >= MAXIMUM_BUILDER_OPERATIONS {
            return Err(BuilderError::OperationLimitReached);
        }
        Ok(())
    }

    fn ensure_active(&self, now: i64) -> Result<(), BuilderError> {
        self.ensure_active_read(now)
    }

    fn ensure_active_read(&self, now: i64) -> Result<(), BuilderError> {
        self.revalidate()?;
        validate_nonnegative_timestamp(now)?;
        if self.discarded {
            return Err(BuilderError::SessionDiscarded);
        }
        if now < self.updated_at || now < self.created_at {
            return Err(BuilderError::InvalidTimestamp);
        }
        if now >= self.expires_at {
            return Err(BuilderError::SessionExpired);
        }
        Ok(())
    }

    fn invalidate_emission(&mut self) {
        self.emitted_artifact_receipt = None;
        self.cached_artifact_json = None;
    }

    fn artifact_json_and_hash(&self) -> Result<(String, String), BuilderError> {
        let artifact =
            ProfileArtifact::from_configuration(&self.document, ProfileArtifactSelection::All, 0)
                .map_err(|_| BuilderError::ArtifactEncodingFailed)?;
        let content_hash = artifact.content_hash.value.clone();
        let bytes = artifact
            .encode_compact_json()
            .map_err(|_| BuilderError::ArtifactEncodingFailed)?;
        let json = String::from_utf8(bytes).map_err(|_| BuilderError::ArtifactEncodingFailed)?;
        Ok((json, content_hash))
    }

    fn revalidate(&self) -> Result<(), BuilderError> {
        if self.version != BUILDER_SESSION_VERSION {
            return Err(BuilderError::UnsupportedVersion(self.version));
        }
        validate_uuid(&self.session_id, BuilderError::InvalidSessionId)?;
        validate_nonnegative_timestamp(self.created_at)?;
        validate_nonnegative_timestamp(self.updated_at)?;
        validate_nonnegative_timestamp(self.expires_at)?;
        if self.updated_at < self.created_at
            || self.expires_at <= self.created_at
            || self.expires_at - self.created_at > MAXIMUM_BUILDER_SESSION_TTL_SECONDS
            || self.updated_at >= self.expires_at
        {
            return Err(BuilderError::InvalidTimestamp);
        }
        self.document
            .validate()
            .map_err(|_| BuilderError::InvalidDocument)?;
        ProfileArtifact::validate_configuration_portability(&self.document)
            .map_err(|_| BuilderError::DocumentNotPortable)?;
        let expected_document_digest = canonical_digest(&self.document)?;
        if self.document_digest != expected_document_digest {
            return Err(BuilderError::InvalidDocumentDigest);
        }
        if self.operations.len() > MAXIMUM_BUILDER_OPERATIONS {
            return Err(BuilderError::OperationLimitReached);
        }
        let mut revision = 1u64;
        let mut last_applied_at = self.created_at;
        let mut operation_ids = std::collections::BTreeSet::new();
        for record in &self.operations {
            validate_uuid(&record.operation_id, BuilderError::InvalidOperationId)?;
            validate_nonnegative_timestamp(record.applied_at)?;
            let expected_descriptor_digest = canonical_digest(&record.descriptor)?;
            if !operation_ids.insert(record.operation_id.as_str())
                || !valid_sha256(&record.descriptor_digest)
                || record.descriptor_digest != expected_descriptor_digest
                || record.base_revision != revision
                || !valid_changed_paths(record)
                || record.applied_at < last_applied_at
                || record.applied_at >= self.expires_at
            {
                return Err(BuilderError::InvalidOperationLog);
            }
            let expected_result = if record.changed {
                revision
                    .checked_add(1)
                    .ok_or(BuilderError::RevisionOverflow)?
            } else {
                revision
            };
            if record.result_revision != expected_result
                || (record.changed && record.changed_paths.is_empty())
                || (!record.changed && !record.changed_paths.is_empty())
            {
                return Err(BuilderError::InvalidOperationLog);
            }
            revision = record.result_revision;
            last_applied_at = record.applied_at;
        }
        if self.revision != revision || self.updated_at < last_applied_at {
            return Err(BuilderError::InvalidOperationLog);
        }
        match (self.discarded, self.discarded_at) {
            (true, Some(at)) => {
                validate_nonnegative_timestamp(at)?;
                if at != self.updated_at || at >= self.expires_at {
                    return Err(BuilderError::InvalidDiscardState);
                }
            }
            (false, None) => {}
            _ => return Err(BuilderError::InvalidDiscardState),
        }
        if let Some(receipt) = &self.emitted_artifact_receipt {
            validate_nonnegative_timestamp(receipt.emitted_at)?;
            let latest_changed_at = self
                .operations
                .iter()
                .filter(|record| record.changed)
                .map(|record| record.applied_at)
                .max()
                .unwrap_or(self.created_at);
            if receipt.session_id != self.session_id
                || receipt.revision != self.revision
                || receipt.document_digest != self.document_digest
                || receipt.emitted_at < self.created_at
                || receipt.emitted_at < latest_changed_at
                || receipt.emitted_at > self.updated_at
                || receipt.emitted_at >= self.expires_at
                || !valid_sha256(&receipt.content_hash)
                || !valid_sha256(&receipt.document_digest)
            {
                return Err(BuilderError::InvalidArtifactReceipt);
            }
            let (_, expected_hash) = self.artifact_json_and_hash()?;
            if expected_hash != receipt.content_hash {
                return Err(BuilderError::InvalidArtifactReceipt);
            }
        }
        Ok(())
    }
}

fn validate_edit(edit: &BuilderEdit) -> Result<(), BuilderError> {
    match edit {
        BuilderEdit::ProfileRename { name } => {
            if name.trim().is_empty()
                || name.chars().count() > MAXIMUM_PROFILE_NAME_CHARACTERS
                || name.chars().any(char::is_control)
            {
                return Err(BuilderError::InvalidProfileName);
            }
        }
        BuilderEdit::ControlLayout {
            element_id,
            x,
            y,
            width,
            height,
            hidden,
            locked,
        } => {
            validate_element_id(element_id)?;
            if [
                x.is_some(),
                y.is_some(),
                width.is_some(),
                height.is_some(),
                hidden.is_some(),
                locked.is_some(),
            ]
            .into_iter()
            .all(|present| !present)
            {
                return Err(BuilderError::EmptyLayoutEdit);
            }
            for value in [x, y].into_iter().flatten() {
                if !value.is_finite() || !(0.0..=1.0).contains(value) {
                    return Err(BuilderError::InvalidLayoutValue);
                }
            }
            for value in [width, height].into_iter().flatten() {
                if !value.is_finite() || !(0.001..=12.0).contains(value) {
                    return Err(BuilderError::InvalidLayoutValue);
                }
            }
        }
        BuilderEdit::ControlRemove { element_id } => validate_element_id(element_id)?,
        BuilderEdit::BindingSet {
            button,
            key,
            modifiers,
        } => {
            parse_button(button)?;
            if generated_semantic_key_code(key).is_none() {
                return Err(BuilderError::InvalidSemanticKey);
            }
            if modifiers.len() > 16 || generated_modifier_mask(modifiers).is_none() {
                return Err(BuilderError::InvalidModifier);
            }
        }
        BuilderEdit::BindingClear { button } => {
            parse_button(button)?;
        }
        BuilderEdit::OutputMode { .. } => {}
    }
    Ok(())
}

fn canonicalize_active_profile(document: &mut ConfigurationDocument) -> Result<(), BuilderError> {
    let canonical_id = document
        .profiles
        .iter()
        .filter_map(|profile| profile.get("id").and_then(Value::as_str))
        .find(|id| id.eq_ignore_ascii_case(&document.active_profile_id))
        .map(str::to_owned)
        .ok_or(BuilderError::InvalidDocument)?;
    canonicalize_binding_map_key(&mut document.profile_key_bindings, &canonical_id)?;
    canonicalize_binding_map_key(&mut document.profile_output_bindings, &canonical_id)?;
    document.active_profile_id = canonical_id;
    Ok(())
}

fn canonicalize_binding_map_key<T>(
    maps: &mut std::collections::BTreeMap<String, T>,
    canonical_id: &str,
) -> Result<(), BuilderError> {
    let matching = maps
        .keys()
        .filter(|key| key.eq_ignore_ascii_case(canonical_id))
        .cloned()
        .collect::<Vec<_>>();
    if matching.len() > 1 {
        return Err(BuilderError::InvalidDocument);
    }
    if let Some(existing) = matching.first() {
        if existing != canonical_id {
            let value = maps.remove(existing).ok_or(BuilderError::InvalidDocument)?;
            maps.insert(canonical_id.to_owned(), value);
        }
    }
    Ok(())
}

fn apply_edit_to_document(
    document: &mut ConfigurationDocument,
    edit: &BuilderEdit,
    now: i64,
) -> Result<Vec<String>, BuilderError> {
    let active_id = document.active_profile_id.clone();
    let profile = document
        .profiles
        .iter_mut()
        .find(|profile| {
            profile
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| id.eq_ignore_ascii_case(&active_id))
        })
        .and_then(Value::as_object_mut)
        .ok_or(BuilderError::InvalidDocument)?;
    let mut paths = Vec::new();
    match edit {
        BuilderEdit::ProfileRename { name } => {
            if profile.get("name").and_then(Value::as_str) != Some(name) {
                profile.insert("name".to_owned(), Value::String(name.clone()));
                paths.push("/profiles/active/name".to_owned());
            }
        }
        BuilderEdit::ControlLayout {
            element_id,
            x,
            y,
            width,
            height,
            hidden,
            locked,
        } => {
            let customization = profile
                .get_mut("customization")
                .and_then(Value::as_object_mut)
                .ok_or(BuilderError::InvalidDocument)?;
            let metadata = find_element_metadata(customization, element_id)?;
            let changes = [
                ("centerX", *x),
                ("centerY", *y),
                ("widthScale", *width),
                ("heightScale", *height),
            ];
            let mut changed = false;
            changed |=
                update_element_layout(customization, element_id, &changes, *hidden, *locked)?;
            changed |= update_layout_mirrors(customization, &metadata, &changes, *hidden, *locked);
            if changed {
                for (field, value) in changes {
                    if value.is_some() {
                        paths.push(format!(
                            "/profiles/active/customization/elements/layout/{field}"
                        ));
                    }
                }
                if hidden.is_some() {
                    paths
                        .push("/profiles/active/customization/elements/layout/isHidden".to_owned());
                }
                if locked.is_some() {
                    paths.push(
                        "/profiles/active/customization/elements/layout/isLocationLocked"
                            .to_owned(),
                    );
                }
            }
        }
        BuilderEdit::ControlRemove { element_id } => {
            let customization = profile
                .get_mut("customization")
                .and_then(Value::as_object_mut)
                .ok_or(BuilderError::InvalidDocument)?;
            let metadata = find_element_metadata(customization, element_id)?;
            let elements = customization
                .get_mut("elements")
                .and_then(Value::as_array_mut)
                .ok_or(BuilderError::ControlNotFound)?;
            let before = elements.len();
            elements
                .retain(|element| element.get("id").and_then(Value::as_str) != Some(element_id));
            if elements.len() == before {
                return Err(BuilderError::ControlNotFound);
            }
            if let Some(button) = metadata.built_in_button {
                set_pair_hidden(customization, "buttonCustomizations", &button);
            }
            if let Some(customs) = customization
                .get_mut("customButtons")
                .and_then(Value::as_array_mut)
            {
                customs.retain(|element| {
                    element.get("id").and_then(Value::as_str) != Some(element_id)
                });
            }
            paths.push("/profiles/active/customization/elements".to_owned());
        }
        BuilderEdit::BindingSet {
            button,
            key,
            modifiers,
        } => {
            let button_value = parse_button(button)?;
            let code = generated_semantic_key_code(key).ok_or(BuilderError::InvalidSemanticKey)?;
            let mask = generated_modifier_mask(modifiers).ok_or(BuilderError::InvalidModifier)?;
            let binding = KeyBinding::new(code, mask);
            let mut changed = document.key_bindings.get(&button_value) != Some(&binding);
            document.key_bindings.insert(button_value, binding.clone());
            let profile_keys = document
                .profile_key_bindings
                .entry(active_id.clone())
                .or_default();
            changed |= profile_keys.get(&button_value) != Some(&binding);
            profile_keys.insert(button_value, binding.clone());
            changed |= set_keyboard_output(
                &mut document.output_bindings,
                button_value,
                Some(binding.clone()),
            );
            let profile_outputs = document
                .profile_output_bindings
                .entry(active_id.clone())
                .or_default();
            changed |= set_keyboard_output(profile_outputs, button_value, Some(binding));
            let semantic_output = profile_outputs.get(&button_value).cloned();
            let elements_changed =
                sync_mapped_element_outputs(profile, button_value, semantic_output.as_ref())?;
            changed |= elements_changed;
            if changed {
                paths.extend([
                    "/keyBindings".to_owned(),
                    "/outputBindings".to_owned(),
                    "/profileKeyBindings/active".to_owned(),
                    "/profileOutputBindings/active".to_owned(),
                ]);
                if elements_changed {
                    paths.push("/profiles/active/customizations/elements/output".to_owned());
                }
            }
        }
        BuilderEdit::BindingClear { button } => {
            let button_value = parse_button(button)?;
            let mut changed = document.key_bindings.remove(button_value).is_some();
            if let Some(bindings) = document.profile_key_bindings.get_mut(&active_id) {
                changed |= bindings.remove(button_value).is_some();
            }
            changed |= set_keyboard_output(&mut document.output_bindings, button_value, None);
            let semantic_output =
                if let Some(outputs) = document.profile_output_bindings.get_mut(&active_id) {
                    changed |= set_keyboard_output(outputs, button_value, None);
                    outputs.get(&button_value).cloned()
                } else {
                    None
                };
            let elements_changed =
                sync_mapped_element_outputs(profile, button_value, semantic_output.as_ref())?;
            changed |= elements_changed;
            if changed {
                paths.extend([
                    "/keyBindings".to_owned(),
                    "/outputBindings".to_owned(),
                    "/profileKeyBindings/active".to_owned(),
                    "/profileOutputBindings/active".to_owned(),
                ]);
                if elements_changed {
                    paths.push("/profiles/active/customizations/elements/output".to_owned());
                }
            }
        }
        BuilderEdit::OutputMode { mode } => {
            if profile.get("outputMode").and_then(Value::as_str) != Some(mode.as_str()) {
                profile.insert(
                    "outputMode".to_owned(),
                    Value::String(mode.as_str().to_owned()),
                );
                paths.push("/profiles/active/outputMode".to_owned());
            }
        }
    }
    if !paths.is_empty() {
        profile.insert("updatedAt".to_owned(), Value::from(now));
        paths.push("/profiles/active/updatedAt".to_owned());
    }
    paths.sort();
    paths.dedup();
    if paths.len() > MAXIMUM_BUILDER_CHANGED_PATHS {
        paths.truncate(MAXIMUM_BUILDER_CHANGED_PATHS);
    }
    Ok(paths)
}

#[derive(Clone)]
struct ElementMetadata {
    element_id: String,
    built_in_button: Option<String>,
}

fn find_element_metadata(
    customization: &Map<String, Value>,
    element_id: &str,
) -> Result<ElementMetadata, BuilderError> {
    let element = customization
        .get("elements")
        .and_then(Value::as_array)
        .and_then(|elements| {
            elements
                .iter()
                .find(|element| element.get("id").and_then(Value::as_str) == Some(element_id))
        })
        .ok_or(BuilderError::ControlNotFound)?;
    Ok(ElementMetadata {
        element_id: element_id.to_owned(),
        built_in_button: element
            .get("builtInButton")
            .and_then(Value::as_str)
            .map(str::to_owned),
    })
}

fn update_element_layout(
    customization: &mut Map<String, Value>,
    element_id: &str,
    number_changes: &[(&str, Option<f64>); 4],
    hidden: Option<bool>,
    locked: Option<bool>,
) -> Result<bool, BuilderError> {
    let element = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
        .and_then(|elements| {
            elements
                .iter_mut()
                .find(|element| element.get("id").and_then(Value::as_str) == Some(element_id))
        })
        .and_then(Value::as_object_mut)
        .ok_or(BuilderError::ControlNotFound)?;
    let layout = element
        .entry("layout")
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .ok_or(BuilderError::InvalidDocument)?;
    Ok(update_layout(layout, number_changes, hidden, locked))
}

fn update_layout_mirrors(
    customization: &mut Map<String, Value>,
    metadata: &ElementMetadata,
    number_changes: &[(&str, Option<f64>); 4],
    hidden: Option<bool>,
    locked: Option<bool>,
) -> bool {
    let mut changed = false;
    if let Some(button) = &metadata.built_in_button {
        if let Some(values) = customization
            .get_mut("buttonCustomizations")
            .and_then(Value::as_array_mut)
        {
            let mut index = 0;
            while index + 1 < values.len() {
                let (key, tail) = values.split_at_mut(index + 1);
                if key[index].as_str() == Some(button) {
                    if let Some(layout) = tail[0].as_object_mut() {
                        changed |= update_layout(layout, number_changes, hidden, locked);
                    }
                }
                index += 2;
            }
        }
    }
    if let Some(customs) = customization
        .get_mut("customButtons")
        .and_then(Value::as_array_mut)
    {
        for custom in customs {
            if custom.get("id").and_then(Value::as_str) == Some(&metadata.element_id) {
                if let Some(layout) = custom.get_mut("layout").and_then(Value::as_object_mut) {
                    changed |= update_layout(layout, number_changes, hidden, locked);
                }
            }
        }
    }
    changed
}

fn update_layout(
    layout: &mut Map<String, Value>,
    number_changes: &[(&str, Option<f64>); 4],
    hidden: Option<bool>,
    locked: Option<bool>,
) -> bool {
    let mut changed = false;
    for (field, value) in number_changes {
        if let Some(value) = value {
            let next = Value::from(*value);
            if layout.get(*field) != Some(&next) {
                layout.insert((*field).to_owned(), next);
                changed = true;
            }
        }
    }
    for (field, value) in [("isHidden", hidden), ("isLocationLocked", locked)] {
        if let Some(value) = value {
            let next = Value::Bool(value);
            if layout.get(field) != Some(&next) {
                layout.insert(field.to_owned(), next);
                changed = true;
            }
        }
    }
    changed
}

fn set_pair_hidden(customization: &mut Map<String, Value>, field: &str, button: &str) {
    if let Some(values) = customization.get_mut(field).and_then(Value::as_array_mut) {
        let mut index = 0;
        while index + 1 < values.len() {
            let (key, tail) = values.split_at_mut(index + 1);
            if key[index].as_str() == Some(button) {
                if let Some(layout) = tail[0].as_object_mut() {
                    layout.insert("isHidden".to_owned(), Value::Bool(true));
                }
            }
            index += 2;
        }
    }
}

fn sync_mapped_element_outputs(
    profile: &mut Map<String, Value>,
    button: GameButton,
    output: Option<&OutputBinding>,
) -> Result<bool, BuilderError> {
    let mut changed = false;
    for customization_key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let Some(elements) = profile
            .get_mut(customization_key)
            .and_then(Value::as_object_mut)
            .and_then(|customization| customization.get_mut("elements"))
            .and_then(Value::as_array_mut)
        else {
            continue;
        };
        for element in elements {
            let mapped = element
                .get("legacySlot")
                .or_else(|| element.get("builtInButton"))
                .and_then(|value| serde_json::from_value::<GameButton>(value.clone()).ok());
            if mapped != Some(button) {
                continue;
            }
            let object = element
                .as_object_mut()
                .ok_or(BuilderError::InvalidDocument)?;
            let mut next = output.cloned();
            if next.is_none() {
                if let Some(mut existing) = object
                    .get("output")
                    .and_then(|value| serde_json::from_value::<OutputBinding>(value.clone()).ok())
                {
                    existing.keyboard = None;
                    if !existing.gamepad_buttons.is_empty() {
                        next = Some(existing);
                    }
                }
            }
            let next_value = next.as_ref().map(element_output_value);
            if object.get("output") != next_value.as_ref() {
                match next_value {
                    Some(value) => {
                        object.insert("output".to_owned(), value);
                    }
                    None => {
                        object.remove("output");
                    }
                }
                changed = true;
            }
        }
    }
    Ok(changed)
}

fn element_output_value(output: &OutputBinding) -> Value {
    let keyboard = output.keyboard.as_ref().map(|binding| {
        let mut value = Map::new();
        value.insert("keyCode".to_owned(), Value::from(binding.key_code));
        value.insert(
            "modifiersRawValue".to_owned(),
            Value::from(binding.modifiers),
        );
        if let Some(sequence) = &binding.sequence {
            value.insert(
                "sequence".to_owned(),
                Value::Array(
                    sequence
                        .iter()
                        .map(|stroke| {
                            serde_json::json!({
                                "keyCode": stroke.key_code,
                                "modifiersRawValue": stroke.modifiers,
                            })
                        })
                        .collect(),
                ),
            );
        }
        Value::Object(value)
    });
    let mut value = Map::new();
    if let Some(keyboard) = keyboard {
        value.insert("keyboard".to_owned(), keyboard);
    }
    value.insert(
        "gamepadButtons".to_owned(),
        serde_json::to_value(&output.gamepad_buttons).unwrap_or_else(|_| Value::Array(Vec::new())),
    );
    Value::Object(value)
}

fn set_keyboard_output(
    outputs: &mut ButtonBindings<OutputBinding>,
    button: GameButton,
    keyboard: Option<KeyBinding>,
) -> bool {
    let previous = outputs.get(&button).cloned();
    let mut next = previous.clone().unwrap_or_default();
    next.keyboard = keyboard;
    if next.keyboard.is_none() && next.gamepad_buttons.is_empty() {
        outputs.remove(button);
    } else {
        outputs.insert(button, next);
    }
    outputs.get(&button) != previous.as_ref()
}

fn generation_summary(
    plan: &thumble_core::GenerationSpecPlan,
    document: &ConfigurationDocument,
    record: &BuilderOperationRecord,
) -> Result<BuilderGenerationSummary, BuilderError> {
    let artifact = ProfileArtifact::from_configuration(document, ProfileArtifactSelection::All, 0)
        .map_err(|_| BuilderError::InvalidGeneratedArtifact)?;
    let profile_name = document
        .profiles
        .first()
        .and_then(|profile| profile.get("name"))
        .and_then(Value::as_str)
        .unwrap_or("Unnamed")
        .to_owned();
    Ok(BuilderGenerationSummary {
        descriptor_digest: plan.descriptor_digest.clone(),
        base_revision: record.base_revision,
        result_revision: record.result_revision,
        changed: record.changed,
        warnings: plan
            .warnings
            .iter()
            .map(|warning| BuilderGenerationWarning {
                code: bounded_string(&warning.code, 128),
                source_ordinal: warning.source_ordinal,
            })
            .collect(),
        omitted_warning_count: plan.omitted_warning_count,
        assigned_controls: plan
            .assigned_controls
            .iter()
            .map(|control| BuilderGenerationAssignment {
                source_ordinal: control.source_ordinal,
                button: bounded_string(&control.button, 32),
                element_id: bounded_string(&control.element_id, MAXIMUM_ELEMENT_ID_BYTES),
                kind: bounded_string(&control.kind, 32),
                used_explicit_button: control.used_explicit_button,
            })
            .collect(),
        dropped_controls: plan
            .dropped_controls
            .iter()
            .map(|control| BuilderGenerationDrop {
                source_ordinal: control.source_ordinal,
                reason: bounded_string(&control.reason, 128),
            })
            .collect(),
        layout_quality: plan.layout_quality.clone(),
        profile_id: plan.profile_id.clone(),
        profile_name,
        artifact_content_hash: artifact.content_hash.value,
    })
}

fn template_summary(
    template: BuilderTemplate,
    document: &ConfigurationDocument,
    profile_id: String,
    profile_name: String,
    custom_element_count: usize,
    record: &BuilderOperationRecord,
) -> Result<BuilderTemplateSummary, BuilderError> {
    Ok(BuilderTemplateSummary {
        template_id: template.template_id().to_owned(),
        template_revision: template.revision(),
        base_revision: record.base_revision,
        result_revision: record.result_revision,
        changed: record.changed,
        profile_id,
        profile_name,
        custom_element_count,
        layout_quality: snapshot_document(document)?.layout_quality,
    })
}

fn snapshot_document(document: &ConfigurationDocument) -> Result<ControllerSnapshot, BuilderError> {
    document
        .validate()
        .map_err(|_| BuilderError::InvalidDocument)?;
    let mut state =
        PersistentState::minimal("builder-preview").map_err(|_| BuilderError::PreviewFailed)?;
    document
        .install_into(&mut state)
        .map_err(|_| BuilderError::InvalidDocument)?;
    debug_assert!(state.trusted_clients.is_empty());
    state
        .controller_snapshot()
        .map_err(|_| BuilderError::PreviewFailed)
}

fn canonical_digest<T: Serialize>(descriptor: &T) -> Result<String, BuilderError> {
    let bytes = serde_json_canonicalizer::to_vec(descriptor)
        .map_err(|_| BuilderError::CanonicalizationFailed)?;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    Ok(format!("{:x}", hasher.finalize()))
}

fn validate_nonnegative_timestamp(value: i64) -> Result<(), BuilderError> {
    if value < 0 {
        Err(BuilderError::InvalidTimestamp)
    } else if value > MAXIMUM_I_JSON_SAFE_INTEGER {
        Err(BuilderError::TimestampOverflow)
    } else {
        Ok(())
    }
}

fn validate_uuid(value: &str, error: BuilderError) -> Result<(), BuilderError> {
    if value.len() != MAXIMUM_OPERATION_ID_BYTES {
        return Err(error);
    }
    let parsed = Uuid::parse_str(value).map_err(|_| error.clone())?;
    if parsed.hyphenated().to_string() != value {
        return Err(error);
    }
    Ok(())
}

fn validate_element_id(value: &str) -> Result<(), BuilderError> {
    if value.is_empty()
        || value.len() > MAXIMUM_ELEMENT_ID_BYTES
        || value.chars().any(char::is_control)
    {
        return Err(BuilderError::InvalidElementId);
    }
    Ok(())
}

fn valid_changed_paths(record: &BuilderOperationRecord) -> bool {
    if record.changed_paths.len() > MAXIMUM_BUILDER_CHANGED_PATHS
        || record.changed_paths.iter().any(|path| path.len() > 256)
        || record
            .changed_paths
            .windows(2)
            .any(|pair| pair[0] >= pair[1])
    {
        return false;
    }
    if !record.changed {
        return record.changed_paths.is_empty() && valid_operation_descriptor(&record.descriptor);
    }
    if record.changed_paths.is_empty() || !valid_operation_descriptor(&record.descriptor) {
        return false;
    }
    if matches!(
        record.descriptor.get("type").and_then(Value::as_str),
        Some("generate.from_spec" | "template.install")
    ) {
        return record.changed_paths == ["/document"];
    }
    let Ok(edit) = serde_json::from_value::<BuilderEdit>(record.descriptor.clone()) else {
        return false;
    };
    let (mut expected, element_output_optional): (Vec<&str>, bool) = match edit {
        BuilderEdit::ProfileRename { .. } => (
            vec!["/profiles/active/name", "/profiles/active/updatedAt"],
            false,
        ),
        BuilderEdit::ControlLayout {
            x,
            y,
            width,
            height,
            hidden,
            locked,
            ..
        } => {
            let mut paths = vec!["/profiles/active/updatedAt"];
            if x.is_some() {
                paths.push("/profiles/active/customization/elements/layout/centerX");
            }
            if y.is_some() {
                paths.push("/profiles/active/customization/elements/layout/centerY");
            }
            if width.is_some() {
                paths.push("/profiles/active/customization/elements/layout/widthScale");
            }
            if height.is_some() {
                paths.push("/profiles/active/customization/elements/layout/heightScale");
            }
            if hidden.is_some() {
                paths.push("/profiles/active/customization/elements/layout/isHidden");
            }
            if locked.is_some() {
                paths.push("/profiles/active/customization/elements/layout/isLocationLocked");
            }
            (paths, false)
        }
        BuilderEdit::ControlRemove { .. } => (
            vec![
                "/profiles/active/customization/elements",
                "/profiles/active/updatedAt",
            ],
            false,
        ),
        BuilderEdit::BindingSet { .. } | BuilderEdit::BindingClear { .. } => (
            vec![
                "/keyBindings",
                "/outputBindings",
                "/profileKeyBindings/active",
                "/profileOutputBindings/active",
                "/profiles/active/updatedAt",
            ],
            true,
        ),
        BuilderEdit::OutputMode { .. } => (
            vec!["/profiles/active/outputMode", "/profiles/active/updatedAt"],
            false,
        ),
    };
    expected.sort_unstable();
    let expected = expected.into_iter().map(str::to_owned).collect::<Vec<_>>();
    if record.changed_paths == expected {
        return true;
    }
    if element_output_optional {
        let mut with_elements = expected;
        with_elements.push("/profiles/active/customizations/elements/output".to_owned());
        with_elements.sort();
        return record.changed_paths == with_elements;
    }
    false
}

fn valid_operation_descriptor(descriptor: &Value) -> bool {
    if descriptor.get("type").and_then(Value::as_str) == Some("template.install") {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct TemplateDescriptor {
            #[serde(rename = "type")]
            kind: String,
            #[serde(rename = "templateID")]
            template_id: String,
            template_revision: u32,
            name: String,
        }
        return serde_json::from_value::<TemplateDescriptor>(descriptor.clone()).is_ok_and(
            |value| {
                value.kind == "template.install"
                    && BuilderTemplate::ALL.iter().any(|template| {
                        template.template_id() == value.template_id
                            && template.revision() == value.template_revision
                    })
                    && !value.name.trim().is_empty()
                    && value.name.chars().count() <= MAXIMUM_PROFILE_NAME_CHARACTERS
                    && !value.name.chars().any(char::is_control)
            },
        );
    }
    if descriptor.get("type").and_then(Value::as_str) == Some("generate.from_spec") {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct GenerationDescriptor {
            #[serde(rename = "type")]
            kind: String,
            descriptor_digest: String,
            requested_game_name: Option<String>,
        }
        return serde_json::from_value::<GenerationDescriptor>(descriptor.clone()).is_ok_and(
            |value| {
                value.kind == "generate.from_spec"
                    && valid_sha256(&value.descriptor_digest)
                    && value
                        .requested_game_name
                        .as_ref()
                        .is_none_or(|name| name.chars().count() <= MAXIMUM_PROFILE_NAME_CHARACTERS)
            },
        );
    }
    serde_json::from_value::<BuilderEdit>(descriptor.clone())
        .is_ok_and(|edit| validate_edit(&edit).is_ok())
}

fn valid_sha256(value: &str) -> bool {
    value.len() == SHA256_HEX_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

fn bounded_string(value: &str, maximum_bytes: usize) -> String {
    if value.len() <= maximum_bytes {
        return value.to_owned();
    }
    let mut end = maximum_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_owned()
}

fn bounded_chars(value: &str, maximum: usize) -> String {
    value.chars().take(maximum).collect()
}

fn parse_button(value: &str) -> Result<GameButton, BuilderError> {
    match value {
        "up" => Ok(GameButton::Up),
        "down" => Ok(GameButton::Down),
        "left" => Ok(GameButton::Left),
        "right" => Ok(GameButton::Right),
        "jump" => Ok(GameButton::Jump),
        "attack" => Ok(GameButton::Attack),
        "dash" => Ok(GameButton::Dash),
        "focus" => Ok(GameButton::Focus),
        "map" => Ok(GameButton::Map),
        "pause" => Ok(GameButton::Pause),
        "custom1" => Ok(GameButton::Custom1),
        "custom2" => Ok(GameButton::Custom2),
        "custom3" => Ok(GameButton::Custom3),
        "custom4" => Ok(GameButton::Custom4),
        "custom5" => Ok(GameButton::Custom5),
        "custom6" => Ok(GameButton::Custom6),
        "custom7" => Ok(GameButton::Custom7),
        "custom8" => Ok(GameButton::Custom8),
        _ => Err(BuilderError::InvalidButton),
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuilderGenerationFailure {
    pub code: &'static str,
    pub path: Option<&'static str>,
    pub source_ordinal: Option<usize>,
}

fn map_generation_error(error: &GenerationSpecError) -> BuilderGenerationFailure {
    let (code, raw_path, source_ordinal) = match error {
        GenerationSpecError::TooLarge(_) => ("spec_too_large", None, None),
        GenerationSpecError::DecodingFailed => ("decoding_failed", None, None),
        GenerationSpecError::TopLevelMustBeObject => ("invalid_top_level", Some("$"), None),
        GenerationSpecError::UnknownField { path, .. } => {
            ("unknown_field", Some(path.as_str()), None)
        }
        GenerationSpecError::UnsafeField { path, .. } => {
            ("unsafe_field", Some(path.as_str()), None)
        }
        GenerationSpecError::MissingControls => ("missing_controls", Some("$.controls"), None),
        GenerationSpecError::TooManyControls(_) => ("too_many_controls", Some("$.controls"), None),
        GenerationSpecError::InvalidType { path, .. } => {
            ("invalid_type", Some(path.as_str()), None)
        }
        GenerationSpecError::InvalidRevision { .. } => ("unsupported_revision", Some("$"), None),
        GenerationSpecError::InvalidEnum { path, .. } => {
            ("invalid_enum", Some(path.as_str()), None)
        }
        GenerationSpecError::InvalidNumber { path } => {
            ("invalid_number", Some(path.as_str()), None)
        }
        GenerationSpecError::NumberOutOfBounds { path } => {
            ("number_out_of_bounds", Some(path.as_str()), None)
        }
        GenerationSpecError::StringTooLong { path } => {
            ("string_too_long", Some(path.as_str()), None)
        }
        GenerationSpecError::ControlCharacter { path } => {
            ("control_character", Some(path.as_str()), None)
        }
        GenerationSpecError::TooManyNotes(_) => ("too_many_notes", Some("$.notes"), None),
        GenerationSpecError::InvalidKey { source_ordinal, .. } => {
            ("invalid_key", Some("$.controls[]"), Some(*source_ordinal))
        }
        GenerationSpecError::InvalidModifier { source_ordinal, .. } => (
            "invalid_modifier",
            Some("$.controls[]"),
            Some(*source_ordinal),
        ),
        GenerationSpecError::CanonicalizationFailed => ("canonicalization_failed", None, None),
        GenerationSpecError::EncodingFailed => ("encoding_failed", None, None),
        GenerationSpecError::OutputTooLarge(_) => ("output_too_large", None, None),
        GenerationSpecError::Artifact(_) => ("invalid_artifact", None, None),
        GenerationSpecError::LayoutEvaluationFailed => ("layout_evaluation_failed", None, None),
    };
    BuilderGenerationFailure {
        code,
        path: raw_path.map(safe_generation_path),
        source_ordinal,
    }
}

fn safe_generation_path(path: &str) -> &'static str {
    if path.starts_with("$.controls[") || path.starts_with("$.controls.") {
        "$.controls[]"
    } else if path == "$.controls" {
        "$.controls"
    } else if path.starts_with("$.notes[") || path.starts_with("$.notes.") {
        "$.notes[]"
    } else if path == "$.notes" {
        "$.notes"
    } else if path.starts_with("$.style") || path.starts_with("$.visual") {
        "$.style"
    } else {
        "$"
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuilderError {
    InvalidSessionId,
    InvalidOperationId,
    InvalidElementId,
    InvalidTimestamp,
    TimestampOverflow,
    InvalidTtl(i64),
    SessionExpired,
    SessionDiscarded,
    RevisionConflict { expected: u64, actual: u64 },
    RevisionOverflow,
    OperationConflict,
    OperationLimitReached,
    InvalidProfileName,
    EmptyLayoutEdit,
    InvalidLayoutValue,
    ControlNotFound,
    InvalidButton,
    InvalidSemanticKey,
    InvalidModifier,
    InvalidDocument,
    DocumentNotPortable,
    InvalidDocumentDigest,
    InvalidGeneratedArtifact,
    InvalidTemplateFixtures,
    Generation(BuilderGenerationFailure),
    PreviewFailed,
    ArtifactEncodingFailed,
    ArtifactNotEmitted,
    CanonicalizationFailed,
    EncodingFailed,
    DecodingFailed,
    SessionJsonTooLarge(usize),
    UnsupportedVersion(u32),
    InvalidOperationLog,
    InvalidDiscardState,
    InvalidArtifactReceipt,
}

impl fmt::Display for BuilderError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidSessionId => {
                formatter.write_str("builder session ID must be a canonical UUID")
            }
            Self::InvalidOperationId => {
                formatter.write_str("builder operation ID must be a canonical UUID")
            }
            Self::InvalidElementId => formatter.write_str("builder element ID is invalid"),
            Self::InvalidTimestamp => formatter.write_str("builder timestamp ordering is invalid"),
            Self::TimestampOverflow => formatter.write_str("builder timestamp overflowed"),
            Self::InvalidTtl(ttl) => write!(
                formatter,
                "builder TTL {ttl} is outside the supported range"
            ),
            Self::SessionExpired => formatter.write_str("builder session is expired"),
            Self::SessionDiscarded => formatter.write_str("builder session is discarded"),
            Self::RevisionConflict { expected, actual } => write!(
                formatter,
                "builder revision conflict: expected {expected}, actual {actual}"
            ),
            Self::RevisionOverflow => formatter.write_str("builder revision overflowed"),
            Self::OperationConflict => formatter.write_str(
                "builder operation ID was reused with different content or base revision",
            ),
            Self::OperationLimitReached => formatter.write_str("builder operation limit reached"),
            Self::InvalidProfileName => formatter.write_str("builder profile name is invalid"),
            Self::EmptyLayoutEdit => formatter.write_str("builder layout edit has no changes"),
            Self::InvalidLayoutValue => {
                formatter.write_str("builder layout value is out of bounds")
            }
            Self::ControlNotFound => formatter.write_str("builder control was not found"),
            Self::InvalidButton => formatter.write_str("builder button name is not canonical"),
            Self::InvalidSemanticKey => formatter.write_str("builder semantic key is invalid"),
            Self::InvalidModifier => formatter.write_str("builder key modifier is invalid"),
            Self::InvalidDocument => {
                formatter.write_str("builder configuration document is invalid")
            }
            Self::DocumentNotPortable => {
                formatter.write_str("builder configuration is not portable")
            }
            Self::InvalidDocumentDigest => {
                formatter.write_str("builder configuration digest is invalid")
            }
            Self::InvalidGeneratedArtifact => {
                formatter.write_str("builder generated artifact is invalid")
            }
            Self::InvalidTemplateFixtures => {
                formatter.write_str("builder controller template fixtures are invalid")
            }
            Self::Generation(failure) => {
                write!(formatter, "builder generation failed [{}]", failure.code)?;
                if let Some(path) = failure.path {
                    write!(formatter, " at {path}")?;
                }
                if let Some(ordinal) = failure.source_ordinal {
                    write!(formatter, " for control {ordinal}")?;
                }
                Ok(())
            }
            Self::PreviewFailed => formatter.write_str("builder preview could not be produced"),
            Self::ArtifactEncodingFailed => {
                formatter.write_str("builder artifact could not be encoded")
            }
            Self::ArtifactNotEmitted => {
                formatter.write_str("builder artifact has not been emitted at this revision")
            }
            Self::CanonicalizationFailed => {
                formatter.write_str("builder operation descriptor canonicalization failed")
            }
            Self::EncodingFailed => formatter.write_str("builder session encoding failed"),
            Self::DecodingFailed => formatter.write_str("builder session decoding failed"),
            Self::SessionJsonTooLarge(size) => write!(
                formatter,
                "builder session JSON is too large ({size} bytes)"
            ),
            Self::UnsupportedVersion(version) => {
                write!(formatter, "unsupported builder session version {version}")
            }
            Self::InvalidOperationLog => {
                formatter.write_str("builder operation log invariants are invalid")
            }
            Self::InvalidDiscardState => formatter.write_str("builder discard state is invalid"),
            Self::InvalidArtifactReceipt => {
                formatter.write_str("builder artifact receipt is invalid")
            }
        }
    }
}

impl Error for BuilderError {}
