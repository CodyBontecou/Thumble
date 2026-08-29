//! Portable profile artifact v1.
//!
//! The artifact retains raw profile and binding JSON so future portable fields
//! survive a Rust decode/re-encode cycle. It intentionally excludes Mac-local
//! launch targets and rejects embedded binary data, local paths, credentials,
//! and authority identity. Importers parse only the currently supported binding
//! subset when converting the validated artifact into a configuration document.

use crate::state::{ids_equal, profile_id};
use crate::{
    ButtonBindings, ConfigurationDocument, ConfigurationDocumentError, KeyBinding, OutputBinding,
    MAXIMUM_CONFIGURATION_DOCUMENT_BYTES,
};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;
use uuid::Uuid;

pub const PROFILE_ARTIFACT_SCHEMA: &str = "com.codybontecou.pocketpad.keypad-configuration";
pub const PROFILE_ARTIFACT_SCHEMA_VERSION: u32 = 4;
pub const PROFILE_ARTIFACT_VERSION: u32 = 1;
pub const MAXIMUM_PROFILE_ARTIFACT_BYTES: usize = MAXIMUM_CONFIGURATION_DOCUMENT_BYTES;
pub const PROFILE_ARTIFACT_CANONICALIZATION: &str = "rfc8785";
pub const PROFILE_ARTIFACT_HASH_ALGORITHM: &str = "sha256";

const MAXIMUM_PORTABLE_JSON_DEPTH: usize = 64;
const MAXIMUM_PORTABLE_STRING_BYTES: usize = 256 * 1024;
const MAXIMUM_PORTABLE_KEY_BYTES: usize = 256;
const MAXIMUM_PORTABLE_CONTAINER_ENTRIES: usize = 4_096;
const MAXIMUM_I_JSON_SAFE_INTEGER: i64 = 9_007_199_254_740_991;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProfileArtifactCatalogRevision {
    pub controller_templates: u32,
    pub device_frames: u32,
    pub generation_spec: u32,
}

impl Default for ProfileArtifactCatalogRevision {
    fn default() -> Self {
        Self {
            controller_templates: 1,
            device_frames: 1,
            generation_spec: 1,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ProfileArtifactContentHash {
    pub algorithm: String,
    pub canonicalization: String,
    pub value: String,
}

impl ProfileArtifactContentHash {
    fn placeholder() -> Self {
        Self {
            algorithm: PROFILE_ARTIFACT_HASH_ALGORITHM.to_owned(),
            canonicalization: PROFILE_ARTIFACT_CANONICALIZATION.to_owned(),
            value: "0".repeat(64),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileArtifactSelection {
    All,
    ProfileId(String),
}

/// Lossless raw JSON keyed first by profile ID and then, within each value, by
/// button name. Known binding fields are parsed only during validation/import.
pub type ProfileArtifactBindingMaps = BTreeMap<String, Value>;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProfileArtifact {
    pub schema: String,
    pub version: u32,
    pub artifact_version: u32,
    pub exported_at: i64,
    pub profiles: Vec<Value>,
    #[serde(rename = "activeProfileID")]
    pub active_profile_id: Option<String>,
    #[serde(rename = "defaultProfileID")]
    pub default_profile_id: Option<String>,
    #[serde(default)]
    pub profile_key_bindings: ProfileArtifactBindingMaps,
    #[serde(default)]
    pub profile_output_bindings: ProfileArtifactBindingMaps,
    pub catalog_revision: ProfileArtifactCatalogRevision,
    pub content_hash: ProfileArtifactContentHash,
    #[serde(flatten, default)]
    pub extensions: BTreeMap<String, Value>,
}

impl ProfileArtifact {
    /// Validate that a configuration is safe to persist at a portable-artifact
    /// trust boundary without silently dropping host-only fields.
    pub fn validate_configuration_portability(
        document: &ConfigurationDocument,
    ) -> Result<(), ProfileArtifactError> {
        document
            .validate()
            .map_err(ProfileArtifactError::InvalidConfiguration)?;
        for profile in &document.profiles {
            validate_portable_value(profile, 0)?;
        }
        let profile_ids = canonical_profile_ids(&document.profiles)?;
        let key_bindings = filtered_binding_maps(&document.profile_key_bindings, &profile_ids)?;
        let output_bindings =
            filtered_binding_maps(&document.profile_output_bindings, &profile_ids)?;
        parse_binding_maps::<KeyBinding>(&key_bindings, &profile_ids)?;
        parse_binding_maps::<OutputBinding>(&output_bindings, &profile_ids)?;
        Ok(())
    }

    pub fn from_configuration(
        document: &ConfigurationDocument,
        selection: ProfileArtifactSelection,
        exported_at: i64,
    ) -> Result<Self, ProfileArtifactError> {
        let portable_profiles = document
            .profiles
            .iter()
            .map(portable_profile)
            .collect::<Result<Vec<_>, _>>()?;
        let all_profile_ids = canonical_profile_ids(&portable_profiles)?;

        // Persistent state can retain stale per-profile maps. Match the Swift
        // exporter by filtering those maps rather than making unrelated stale
        // entries prevent export.
        let all_key_bindings =
            filtered_binding_maps(&document.profile_key_bindings, &all_profile_ids)?;
        let all_output_bindings =
            filtered_binding_maps(&document.profile_output_bindings, &all_profile_ids)?;
        validation_document(
            portable_profiles.clone(),
            canonical_selected_id(&all_profile_ids, &document.active_profile_id)
                .map_err(|_| ProfileArtifactError::ActiveProfileMissing)?,
            canonical_selected_id(&all_profile_ids, &document.default_profile_id)
                .map_err(|_| ProfileArtifactError::DefaultProfileMissing)?,
            parse_binding_maps(&all_key_bindings, &all_profile_ids)?,
            parse_binding_maps(&all_output_bindings, &all_profile_ids)?,
        )
        .validate()
        .map_err(ProfileArtifactError::InvalidConfiguration)?;

        let selected_profiles = match selection {
            ProfileArtifactSelection::All => portable_profiles,
            ProfileArtifactSelection::ProfileId(requested_id) => {
                let profile = portable_profiles
                    .iter()
                    .find(|profile| {
                        profile_id(profile)
                            .is_some_and(|candidate| ids_equal(candidate, &requested_id))
                    })
                    .cloned()
                    .ok_or(ProfileArtifactError::SelectedProfileMissing)?;
                vec![profile]
            }
        };
        let selected_ids = canonical_profile_ids(&selected_profiles)?;
        let single_selection = selected_profiles.len() == 1;
        let selected_first_id = profile_id(&selected_profiles[0])
            .ok_or(ProfileArtifactError::MalformedProfile)?
            .to_owned();

        let active_profile_id = if single_selection {
            Some(selected_first_id.clone())
        } else {
            Some(
                canonical_selected_id(&selected_ids, &document.active_profile_id)
                    .map_err(|_| ProfileArtifactError::ActiveProfileMissing)?,
            )
        };
        let default_profile_id = if single_selection {
            ids_equal(&selected_first_id, &document.default_profile_id)
                .then_some(selected_first_id.clone())
        } else {
            Some(
                canonical_selected_id(&selected_ids, &document.default_profile_id)
                    .map_err(|_| ProfileArtifactError::DefaultProfileMissing)?,
            )
        };

        let mut artifact = Self {
            schema: PROFILE_ARTIFACT_SCHEMA.to_owned(),
            version: PROFILE_ARTIFACT_SCHEMA_VERSION,
            artifact_version: PROFILE_ARTIFACT_VERSION,
            exported_at,
            profiles: selected_profiles,
            active_profile_id,
            default_profile_id,
            profile_key_bindings: filter_raw_binding_maps(&all_key_bindings, &selected_ids)?,
            profile_output_bindings: filter_raw_binding_maps(&all_output_bindings, &selected_ids)?,
            catalog_revision: ProfileArtifactCatalogRevision::default(),
            content_hash: ProfileArtifactContentHash::placeholder(),
            extensions: BTreeMap::new(),
        };
        artifact.refresh_content_hash()?;
        artifact.validate()?;
        Ok(artifact)
    }

    pub fn decode_json(data: &[u8]) -> Result<Self, ProfileArtifactError> {
        if data.len() > MAXIMUM_PROFILE_ARTIFACT_BYTES {
            return Err(ProfileArtifactError::TooLarge(data.len()));
        }
        let artifact: Self =
            serde_json::from_slice(data).map_err(|_| ProfileArtifactError::DecodingFailed)?;
        artifact.validate()?;
        Ok(artifact)
    }

    /// Decodes either a current hashed artifact or upgrades a legacy keypad
    /// configuration envelope to the current portable artifact format.
    ///
    /// The top-level value is parsed only after applying the artifact byte
    /// bound. Presence of `artifactVersion` is authoritative: such input is
    /// always validated as a hashed artifact and never retried as legacy data.
    pub fn decode_import_json(data: &[u8]) -> Result<Self, ProfileArtifactError> {
        if data.len() > MAXIMUM_PROFILE_ARTIFACT_BYTES {
            return Err(ProfileArtifactError::TooLarge(data.len()));
        }
        let value: Value =
            serde_json::from_slice(data).map_err(|_| ProfileArtifactError::DecodingFailed)?;
        let object = value
            .as_object()
            .ok_or(ProfileArtifactError::DecodingFailed)?;
        if object.contains_key("artifactVersion") {
            let artifact: Self =
                serde_json::from_value(value).map_err(|_| ProfileArtifactError::DecodingFailed)?;
            artifact.validate()?;
            return Ok(artifact);
        }
        Self::upgrade_legacy_envelope(object)
    }

    fn upgrade_legacy_envelope(object: &Map<String, Value>) -> Result<Self, ProfileArtifactError> {
        let schema: String = legacy_required_field(object, "schema")?;
        if schema != PROFILE_ARTIFACT_SCHEMA {
            return Err(ProfileArtifactError::UnsupportedSchema);
        }
        let version: u32 =
            legacy_optional_field(object, "version")?.unwrap_or(PROFILE_ARTIFACT_SCHEMA_VERSION);
        if !(1..=PROFILE_ARTIFACT_SCHEMA_VERSION).contains(&version) {
            return Err(ProfileArtifactError::UnsupportedSchemaVersion(version));
        }

        for key in object.keys() {
            match normalize_field_name(key).as_str() {
                "contenthash" | "keybindings" | "outputbindings" => {
                    return Err(ProfileArtifactError::ReservedExtensionField(key.clone()));
                }
                _ => {}
            }
        }

        let profiles: Vec<Value> = legacy_required_field(object, "profiles")?;
        let profiles = profiles
            .iter()
            .map(portable_profile)
            .collect::<Result<Vec<_>, _>>()?;
        let profile_ids = canonical_profile_ids(&profiles)?;
        let first_id = profile_id(&profiles[0])
            .ok_or(ProfileArtifactError::MalformedProfile)?
            .to_owned();
        let requested_active: Option<String> = legacy_optional_field(object, "activeProfileID")?;
        let active_profile_id = Some(match requested_active {
            Some(id) => canonical_selected_id(&profile_ids, &id)
                .map_err(|_| ProfileArtifactError::ActiveProfileMissing)?,
            None => first_id,
        });
        let requested_default: Option<String> = legacy_optional_field(object, "defaultProfileID")?;
        let default_profile_id = requested_default
            .map(|id| {
                canonical_selected_id(&profile_ids, &id)
                    .map_err(|_| ProfileArtifactError::DefaultProfileMissing)
            })
            .transpose()?;
        let raw_key_bindings: ProfileArtifactBindingMaps =
            legacy_optional_field(object, "profileKeyBindings")?.unwrap_or_default();
        let raw_output_bindings: ProfileArtifactBindingMaps =
            legacy_optional_field(object, "profileOutputBindings")?.unwrap_or_default();

        const LEGACY_FIELDS: &[&str] = &[
            "schema",
            "version",
            "exportedAt",
            "profiles",
            "activeProfileID",
            "defaultProfileID",
            "profileKeyBindings",
            "profileOutputBindings",
        ];
        let extensions = object
            .iter()
            .filter(|(key, _)| !LEGACY_FIELDS.contains(&key.as_str()))
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();

        let mut artifact = Self {
            schema: PROFILE_ARTIFACT_SCHEMA.to_owned(),
            version: PROFILE_ARTIFACT_SCHEMA_VERSION,
            artifact_version: PROFILE_ARTIFACT_VERSION,
            exported_at: legacy_optional_field(object, "exportedAt")?.unwrap_or(0),
            profiles,
            active_profile_id,
            default_profile_id,
            profile_key_bindings: filter_raw_binding_maps(&raw_key_bindings, &profile_ids)?,
            profile_output_bindings: filter_raw_binding_maps(&raw_output_bindings, &profile_ids)?,
            catalog_revision: ProfileArtifactCatalogRevision::default(),
            content_hash: ProfileArtifactContentHash::placeholder(),
            extensions,
        };
        artifact.refresh_content_hash()?;
        artifact.validate()?;
        Ok(artifact)
    }

    pub fn encode_compact_json(&self) -> Result<Vec<u8>, ProfileArtifactError> {
        self.validate()?;
        let encoded = serde_json::to_vec(self).map_err(|_| ProfileArtifactError::EncodingFailed)?;
        ensure_artifact_size(encoded.len())?;
        Ok(encoded)
    }

    pub fn encode_pretty_json(&self) -> Result<Vec<u8>, ProfileArtifactError> {
        self.validate()?;
        let encoded =
            serde_json::to_vec_pretty(self).map_err(|_| ProfileArtifactError::EncodingFailed)?;
        ensure_artifact_size(encoded.len())?;
        Ok(encoded)
    }

    pub fn canonical_content_bytes(&self) -> Result<Vec<u8>, ProfileArtifactError> {
        self.validate_structure()?;
        serde_json_canonicalizer::to_vec(&self.semantic_content())
            .map_err(|_| ProfileArtifactError::CanonicalizationFailed)
    }

    pub fn refresh_content_hash(&mut self) -> Result<(), ProfileArtifactError> {
        let canonical = self.canonical_content_bytes()?;
        self.content_hash = ProfileArtifactContentHash {
            algorithm: PROFILE_ARTIFACT_HASH_ALGORITHM.to_owned(),
            canonicalization: PROFILE_ARTIFACT_CANONICALIZATION.to_owned(),
            value: sha256_hex(&canonical),
        };
        Ok(())
    }

    pub fn validate(&self) -> Result<(), ProfileArtifactError> {
        self.validate_structure()?;
        validate_hash_metadata(&self.content_hash)?;
        let expected = sha256_hex(&self.canonical_content_bytes()?);
        if self.content_hash.value != expected {
            return Err(ProfileArtifactError::ContentHashMismatch);
        }
        Ok(())
    }

    /// Converts a valid artifact to the authority's typed configuration subset.
    ///
    /// Binding-map keys are remapped to the spelling of their profile IDs.
    /// Artifact v1 requires an active profile. A null default is the only
    /// reference that falls back to the first profile.
    pub fn to_configuration_document(&self) -> Result<ConfigurationDocument, ProfileArtifactError> {
        self.validate()?;
        self.configuration_document()
    }

    fn validate_structure(&self) -> Result<(), ProfileArtifactError> {
        if self.schema != PROFILE_ARTIFACT_SCHEMA {
            return Err(ProfileArtifactError::UnsupportedSchema);
        }
        if self.version != PROFILE_ARTIFACT_SCHEMA_VERSION {
            return Err(ProfileArtifactError::UnsupportedSchemaVersion(self.version));
        }
        if self.artifact_version != PROFILE_ARTIFACT_VERSION {
            return Err(ProfileArtifactError::UnsupportedArtifactVersion(
                self.artifact_version,
            ));
        }
        if self.catalog_revision != ProfileArtifactCatalogRevision::default() {
            return Err(ProfileArtifactError::UnsupportedCatalogRevision);
        }
        validate_extensions(&self.extensions)?;
        for profile in &self.profiles {
            validate_portable_value(profile, 0)?;
            if profile
                .as_object()
                .is_some_and(|object| object.contains_key("launchTarget"))
            {
                return Err(ProfileArtifactError::ForbiddenField(
                    "launchTarget".to_owned(),
                ));
            }
        }
        for value in self.extensions.values() {
            validate_portable_value(value, 0)?;
        }
        for value in self
            .profile_key_bindings
            .values()
            .chain(self.profile_output_bindings.values())
        {
            validate_portable_value(value, 0)?;
        }

        let document = self.configuration_document()?;
        document
            .validate()
            .map_err(ProfileArtifactError::InvalidConfiguration)?;

        let encoded = serde_json::to_vec(self).map_err(|_| ProfileArtifactError::EncodingFailed)?;
        ensure_artifact_size(encoded.len())
    }

    fn configuration_document(&self) -> Result<ConfigurationDocument, ProfileArtifactError> {
        let profile_ids = canonical_profile_ids(&self.profiles)?;
        let active = self
            .active_profile_id
            .as_deref()
            .ok_or(ProfileArtifactError::ActiveProfileMissing)
            .and_then(|id| {
                canonical_selected_id(&profile_ids, id)
                    .map_err(|_| ProfileArtifactError::ActiveProfileMissing)
            })?;
        let first_id = profile_id(&self.profiles[0])
            .ok_or(ProfileArtifactError::MalformedProfile)?
            .to_owned();
        let default = self
            .default_profile_id
            .as_deref()
            .map(|id| {
                canonical_selected_id(&profile_ids, id)
                    .map_err(|_| ProfileArtifactError::DefaultProfileMissing)
            })
            .transpose()?
            .unwrap_or(first_id);
        let key_bindings = parse_binding_maps(&self.profile_key_bindings, &profile_ids)?;
        let output_bindings = parse_binding_maps(&self.profile_output_bindings, &profile_ids)?;
        Ok(validation_document(
            self.profiles.clone(),
            active,
            default,
            key_bindings,
            output_bindings,
        ))
    }

    fn semantic_content(&self) -> Value {
        let mut object = Map::new();
        object.insert("schema".to_owned(), Value::String(self.schema.clone()));
        object.insert("version".to_owned(), Value::from(self.version));
        object.insert(
            "artifactVersion".to_owned(),
            Value::from(self.artifact_version),
        );
        object.insert("profiles".to_owned(), Value::Array(self.profiles.clone()));
        object.insert(
            "activeProfileID".to_owned(),
            self.active_profile_id
                .clone()
                .map(Value::String)
                .unwrap_or(Value::Null),
        );
        object.insert(
            "defaultProfileID".to_owned(),
            self.default_profile_id
                .clone()
                .map(Value::String)
                .unwrap_or(Value::Null),
        );
        object.insert(
            "profileKeyBindings".to_owned(),
            serde_json::to_value(&self.profile_key_bindings).unwrap_or(Value::Null),
        );
        object.insert(
            "profileOutputBindings".to_owned(),
            serde_json::to_value(&self.profile_output_bindings).unwrap_or(Value::Null),
        );
        object.insert(
            "catalogRevision".to_owned(),
            serde_json::to_value(self.catalog_revision).unwrap_or(Value::Null),
        );
        object.extend(
            self.extensions
                .iter()
                .map(|(key, value)| (key.clone(), value.clone())),
        );
        Value::Object(object)
    }
}

fn legacy_required_field<T: DeserializeOwned>(
    object: &Map<String, Value>,
    key: &str,
) -> Result<T, ProfileArtifactError> {
    let value = object
        .get(key)
        .cloned()
        .ok_or(ProfileArtifactError::DecodingFailed)?;
    serde_json::from_value(value).map_err(|_| ProfileArtifactError::DecodingFailed)
}

fn legacy_optional_field<T: DeserializeOwned>(
    object: &Map<String, Value>,
    key: &str,
) -> Result<Option<T>, ProfileArtifactError> {
    match object.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => serde_json::from_value(value.clone())
            .map(Some)
            .map_err(|_| ProfileArtifactError::DecodingFailed),
    }
}

fn portable_profile(profile: &Value) -> Result<Value, ProfileArtifactError> {
    let mut profile = profile.clone();
    let object = profile
        .as_object_mut()
        .ok_or(ProfileArtifactError::MalformedProfile)?;
    object.remove("launchTarget");
    validate_portable_value(&profile, 0)?;
    Ok(profile)
}

fn validation_document(
    profiles: Vec<Value>,
    active_profile_id: String,
    default_profile_id: String,
    profile_key_bindings: BTreeMap<String, ButtonBindings<KeyBinding>>,
    profile_output_bindings: BTreeMap<String, ButtonBindings<OutputBinding>>,
) -> ConfigurationDocument {
    let key_bindings = profile_key_bindings
        .get(&active_profile_id)
        .cloned()
        .unwrap_or_default();
    let output_bindings = profile_output_bindings
        .get(&active_profile_id)
        .cloned()
        .unwrap_or_default();
    ConfigurationDocument {
        profiles,
        active_profile_id,
        default_profile_id,
        key_bindings,
        output_bindings,
        profile_key_bindings,
        profile_output_bindings,
    }
}

fn canonical_profile_ids(
    profiles: &[Value],
) -> Result<BTreeMap<String, String>, ProfileArtifactError> {
    if profiles.is_empty() {
        return Err(ProfileArtifactError::InvalidProfileCount(0));
    }
    let mut result = BTreeMap::new();
    for profile in profiles {
        let id = profile_id(profile).ok_or(ProfileArtifactError::MalformedProfile)?;
        let parsed = Uuid::parse_str(id).map_err(|_| ProfileArtifactError::InvalidProfileId)?;
        if !parsed.hyphenated().to_string().eq_ignore_ascii_case(id) {
            return Err(ProfileArtifactError::InvalidProfileId);
        }
        let normalized = id.to_ascii_lowercase();
        if result.insert(normalized, id.to_owned()).is_some() {
            return Err(ProfileArtifactError::DuplicateProfileId);
        }
    }
    Ok(result)
}

fn canonical_selected_id(
    selected_ids: &BTreeMap<String, String>,
    requested_id: &str,
) -> Result<String, ProfileArtifactError> {
    selected_ids
        .get(&requested_id.to_ascii_lowercase())
        .cloned()
        .ok_or(ProfileArtifactError::SelectedProfileMissing)
}

fn filtered_binding_maps<T: Serialize>(
    source: &BTreeMap<String, ButtonBindings<T>>,
    selected_ids: &BTreeMap<String, String>,
) -> Result<ProfileArtifactBindingMaps, ProfileArtifactError> {
    let mut result = BTreeMap::new();
    for (profile_id, bindings) in source {
        if let Some(canonical_id) = selected_ids.get(&profile_id.to_ascii_lowercase()) {
            let value =
                serde_json::to_value(bindings).map_err(|_| ProfileArtifactError::EncodingFailed)?;
            if result.insert(canonical_id.clone(), value).is_some() {
                return Err(ProfileArtifactError::DuplicateBindingProfileId);
            }
        }
    }
    Ok(result)
}

fn filter_raw_binding_maps(
    source: &ProfileArtifactBindingMaps,
    selected_ids: &BTreeMap<String, String>,
) -> Result<ProfileArtifactBindingMaps, ProfileArtifactError> {
    let mut result = BTreeMap::new();
    for (profile_id, bindings) in source {
        if let Some(canonical_id) = selected_ids.get(&profile_id.to_ascii_lowercase()) {
            if result
                .insert(canonical_id.clone(), bindings.clone())
                .is_some()
            {
                return Err(ProfileArtifactError::DuplicateBindingProfileId);
            }
        }
    }
    Ok(result)
}

fn parse_binding_maps<T: DeserializeOwned>(
    maps: &ProfileArtifactBindingMaps,
    profile_ids: &BTreeMap<String, String>,
) -> Result<BTreeMap<String, ButtonBindings<T>>, ProfileArtifactError> {
    let mut normalized_keys = BTreeSet::new();
    let mut result = BTreeMap::new();
    for (key, raw_bindings) in maps {
        let normalized = key.to_ascii_lowercase();
        if !normalized_keys.insert(normalized.clone()) {
            return Err(ProfileArtifactError::DuplicateBindingProfileId);
        }
        let canonical_id = profile_ids
            .get(&normalized)
            .ok_or(ProfileArtifactError::BindingProfileMissing)?;
        let bindings = serde_json::from_value(raw_bindings.clone())
            .map_err(|_| ProfileArtifactError::InvalidBindingMap)?;
        result.insert(canonical_id.clone(), bindings);
    }
    Ok(result)
}

fn validate_extensions(extensions: &BTreeMap<String, Value>) -> Result<(), ProfileArtifactError> {
    const RESERVED: &[&str] = &[
        "schema",
        "version",
        "artifactversion",
        "exportedat",
        "profiles",
        "activeprofileid",
        "defaultprofileid",
        "profilekeybindings",
        "profileoutputbindings",
        "catalogrevision",
        "contenthash",
        "keybindings",
        "outputbindings",
    ];
    for (key, value) in extensions {
        let normalized = normalize_field_name(key);
        if RESERVED.contains(&normalized.as_str()) {
            return Err(ProfileArtifactError::ReservedExtensionField(key.clone()));
        }
        if is_forbidden_field_name(key) && !value.is_null() {
            return Err(ProfileArtifactError::ForbiddenField(key.clone()));
        }
    }
    Ok(())
}

fn validate_portable_value(value: &Value, depth: usize) -> Result<(), ProfileArtifactError> {
    if depth > MAXIMUM_PORTABLE_JSON_DEPTH {
        return Err(ProfileArtifactError::PortableDepthExceeded);
    }
    match value {
        Value::String(string) => {
            if string.len() > MAXIMUM_PORTABLE_STRING_BYTES {
                return Err(ProfileArtifactError::PortableStringTooLarge(string.len()));
            }
        }
        Value::Object(object) => {
            if object.len() > MAXIMUM_PORTABLE_CONTAINER_ENTRIES {
                return Err(ProfileArtifactError::PortableContainerTooLarge(
                    object.len(),
                ));
            }
            for (key, child) in object {
                if key.len() > MAXIMUM_PORTABLE_KEY_BYTES {
                    return Err(ProfileArtifactError::PortableKeyTooLarge(key.len()));
                }
                if is_forbidden_field_name(key) && !child.is_null() {
                    return Err(ProfileArtifactError::ForbiddenField(key.clone()));
                }
                validate_portable_value(child, depth + 1)?;
            }
        }
        Value::Array(values) => {
            if values.len() > MAXIMUM_PORTABLE_CONTAINER_ENTRIES {
                return Err(ProfileArtifactError::PortableContainerTooLarge(
                    values.len(),
                ));
            }
            for child in values {
                validate_portable_value(child, depth + 1)?;
            }
        }
        Value::Number(number) => {
            let out_of_range = number
                .as_i64()
                .is_some_and(|integer| integer.abs_diff(0) > MAXIMUM_I_JSON_SAFE_INTEGER as u64)
                || number
                    .as_u64()
                    .is_some_and(|integer| integer > MAXIMUM_I_JSON_SAFE_INTEGER as u64);
            if out_of_range {
                return Err(ProfileArtifactError::PortableIntegerOutOfRange(
                    number.to_string(),
                ));
            }
        }
        _ => {}
    }
    Ok(())
}

fn is_forbidden_field_name(value: &str) -> bool {
    const FORBIDDEN: &[&str] = &[
        "accountid",
        "apikey",
        "authorization",
        "bookmarkdata",
        "clientid",
        "clientsecret",
        "cookie",
        "credential",
        "credentials",
        "data",
        "deviceid",
        "deviceidentifier",
        "devicename",
        "filepath",
        "hostname",
        "iconpngdata",
        "launchtarget",
        "pairingcode",
        "password",
        "path",
        "process",
        "processid",
        "processidentifier",
        "privatekey",
        "secret",
        "serveraddress",
        "serverid",
        "sessionkey",
        "thumbnaildata",
        "trustedclient",
        "trustedclients",
    ];
    let normalized = normalize_field_name(value);
    FORBIDDEN.contains(&normalized.as_str())
        || normalized.ends_with("token")
        || normalized.ends_with("secret")
        || normalized.ends_with("password")
        || normalized.ends_with("privatekey")
        || normalized.ends_with("filepath")
        || normalized.ends_with("url")
        || normalized.contains("authorization")
        || normalized.ends_with("bookmarkdata")
        || normalized.ends_with("iconpngdata")
        || normalized.ends_with("imagedata")
        || normalized.ends_with("thumbnaildata")
        || normalized.ends_with("binarydata")
}

fn normalize_field_name(value: &str) -> String {
    value
        .chars()
        .filter(|character| character.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

fn validate_hash_metadata(hash: &ProfileArtifactContentHash) -> Result<(), ProfileArtifactError> {
    if hash.algorithm != PROFILE_ARTIFACT_HASH_ALGORITHM
        || hash.canonicalization != PROFILE_ARTIFACT_CANONICALIZATION
        || hash.value.len() != 64
        || !hash
            .value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(ProfileArtifactError::InvalidContentHash);
    }
    Ok(())
}

fn ensure_artifact_size(size: usize) -> Result<(), ProfileArtifactError> {
    if size > MAXIMUM_PROFILE_ARTIFACT_BYTES {
        return Err(ProfileArtifactError::TooLarge(size));
    }
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut result = String::with_capacity(64);
    for byte in digest {
        use std::fmt::Write;
        let _ = write!(result, "{byte:02x}");
    }
    result
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileArtifactError {
    EncodingFailed,
    DecodingFailed,
    CanonicalizationFailed,
    TooLarge(usize),
    UnsupportedSchema,
    UnsupportedSchemaVersion(u32),
    UnsupportedArtifactVersion(u32),
    UnsupportedCatalogRevision,
    InvalidContentHash,
    ContentHashMismatch,
    InvalidProfileCount(usize),
    MalformedProfile,
    InvalidProfileId,
    DuplicateProfileId,
    SelectedProfileMissing,
    ActiveProfileMissing,
    DefaultProfileMissing,
    BindingProfileMissing,
    DuplicateBindingProfileId,
    InvalidBindingMap,
    ReservedExtensionField(String),
    ForbiddenField(String),
    PortableDepthExceeded,
    PortableStringTooLarge(usize),
    PortableKeyTooLarge(usize),
    PortableContainerTooLarge(usize),
    PortableIntegerOutOfRange(String),
    InvalidConfiguration(ConfigurationDocumentError),
}

impl fmt::Display for ProfileArtifactError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EncodingFailed => formatter.write_str("profile artifact encoding failed"),
            Self::DecodingFailed => formatter.write_str("profile artifact decoding failed"),
            Self::CanonicalizationFailed => {
                formatter.write_str("profile artifact canonicalization failed")
            }
            Self::TooLarge(size) => {
                write!(formatter, "profile artifact is too large ({size} bytes)")
            }
            Self::UnsupportedSchema => {
                formatter.write_str("profile artifact schema is unsupported")
            }
            Self::UnsupportedSchemaVersion(version) => {
                write!(
                    formatter,
                    "profile artifact schema version {version} is unsupported"
                )
            }
            Self::UnsupportedArtifactVersion(version) => {
                write!(
                    formatter,
                    "profile artifact version {version} is unsupported"
                )
            }
            Self::UnsupportedCatalogRevision => {
                formatter.write_str("profile artifact catalog revision is unsupported")
            }
            Self::InvalidContentHash => {
                formatter.write_str("profile artifact hash metadata is invalid")
            }
            Self::ContentHashMismatch => {
                formatter.write_str("profile artifact content hash does not match")
            }
            Self::InvalidProfileCount(count) => write!(
                formatter,
                "profile artifact contains an invalid profile count ({count})"
            ),
            Self::MalformedProfile => {
                formatter.write_str("profile artifact contains a malformed profile")
            }
            Self::InvalidProfileId => {
                formatter.write_str("profile artifact contains a non-UUID profile ID")
            }
            Self::DuplicateProfileId => {
                formatter.write_str("profile artifact contains duplicate profile IDs")
            }
            Self::SelectedProfileMissing => {
                formatter.write_str("selected profile is missing from the artifact source")
            }
            Self::ActiveProfileMissing => formatter.write_str("artifact active profile is missing"),
            Self::DefaultProfileMissing => {
                formatter.write_str("artifact default profile is missing")
            }
            Self::BindingProfileMissing => {
                formatter.write_str("artifact binding map references a missing profile")
            }
            Self::DuplicateBindingProfileId => {
                formatter.write_str("artifact binding maps contain duplicate profile IDs")
            }
            Self::InvalidBindingMap => {
                formatter.write_str("artifact contains an invalid binding map")
            }
            Self::ReservedExtensionField(field) => {
                write!(formatter, "artifact extension field {field:?} is reserved")
            }
            Self::ForbiddenField(field) => {
                write!(formatter, "artifact contains forbidden field {field:?}")
            }
            Self::PortableDepthExceeded => {
                formatter.write_str("artifact portable JSON nesting is too deep")
            }
            Self::PortableStringTooLarge(size) => {
                write!(
                    formatter,
                    "artifact portable string is too large ({size} bytes)"
                )
            }
            Self::PortableKeyTooLarge(size) => {
                write!(
                    formatter,
                    "artifact portable object key is too large ({size} bytes)"
                )
            }
            Self::PortableContainerTooLarge(size) => write!(
                formatter,
                "artifact portable JSON container is too large ({size} entries)"
            ),
            Self::PortableIntegerOutOfRange(integer) => write!(
                formatter,
                "artifact portable JSON integer {integer} exceeds I-JSON safe integer bounds"
            ),
            Self::InvalidConfiguration(error) => {
                write!(formatter, "invalid artifact configuration: {error}")
            }
        }
    }
}

impl Error for ProfileArtifactError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::InvalidConfiguration(error) => Some(error),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{KeyStroke, MAXIMUM_CONFIGURATION_PROFILES};
    use serde_json::json;

    const FIRST_ID: &str = "aaaaaaaa-0000-0000-0000-000000000201";
    const SECOND_ID: &str = "bbbbbbbb-0000-0000-0000-000000000202";

    fn profile(id: &str, name: &str) -> Value {
        json!({
            "id": id,
            "name": name,
            "updatedAt": 42,
            "orientationPreference": "automatic",
            "outputMode": "keyboard",
            "customization": {
                "elements": [],
                "futureTuning": {"gain": 0.125, "label": "未来 🎛️"}
            },
            "futureProfileField": {"nested": [true, null, 3.5]}
        })
    }

    fn document() -> ConfigurationDocument {
        let mut first_keys = ButtonBindings::default();
        first_keys.insert_raw(
            "futureButton",
            KeyBinding::from_strokes(vec![KeyStroke::new(12, 1), KeyStroke::new(13, 0)]).unwrap(),
        );
        let mut first_outputs = ButtonBindings::default();
        first_outputs.insert_raw(
            "futureButton",
            OutputBinding::keyboard(KeyBinding::new(12, 1)),
        );
        ConfigurationDocument {
            profiles: vec![profile(FIRST_ID, "未来 Pad"), profile(SECOND_ID, "Second")],
            active_profile_id: FIRST_ID.to_owned(),
            default_profile_id: SECOND_ID.to_owned(),
            key_bindings: ButtonBindings::default(),
            output_bindings: ButtonBindings::default(),
            profile_key_bindings: BTreeMap::from([(FIRST_ID.to_ascii_uppercase(), first_keys)]),
            profile_output_bindings: BTreeMap::from([(
                FIRST_ID.to_ascii_uppercase(),
                first_outputs,
            )]),
        }
    }

    fn artifact() -> ProfileArtifact {
        ProfileArtifact::from_configuration(&document(), ProfileArtifactSelection::All, 10).unwrap()
    }

    fn legacy_envelope(version: u32) -> Value {
        let mut value = serde_json::to_value(artifact()).unwrap();
        let object = value.as_object_mut().unwrap();
        object.remove("artifactVersion");
        object.remove("catalogRevision");
        object.remove("contentHash");
        object.insert("version".to_owned(), Value::from(version));
        value
    }

    #[test]
    fn legacy_versions_one_and_four_upgrade_to_the_same_deterministic_artifact() {
        let version_one = serde_json::to_vec(&legacy_envelope(1)).unwrap();
        let version_four = serde_json::to_vec(&legacy_envelope(4)).unwrap();
        let upgraded_one = ProfileArtifact::decode_import_json(&version_one).unwrap();
        let upgraded_four = ProfileArtifact::decode_import_json(&version_four).unwrap();

        assert_eq!(upgraded_one, upgraded_four);
        assert_eq!(upgraded_one.version, PROFILE_ARTIFACT_SCHEMA_VERSION);
        assert_eq!(upgraded_one.artifact_version, PROFILE_ARTIFACT_VERSION);
        assert_eq!(
            upgraded_one.catalog_revision,
            ProfileArtifactCatalogRevision::default()
        );
        assert_eq!(
            upgraded_one.encode_compact_json().unwrap(),
            upgraded_four.encode_compact_json().unwrap()
        );
        ProfileArtifact::decode_json(&upgraded_one.encode_compact_json().unwrap()).unwrap();
    }

    #[test]
    fn legacy_upgrade_defaults_missing_version_to_current_schema_version() {
        let mut legacy = legacy_envelope(1);
        legacy.as_object_mut().unwrap().remove("version");

        let upgraded =
            ProfileArtifact::decode_import_json(&serde_json::to_vec(&legacy).unwrap()).unwrap();
        assert_eq!(upgraded.schema, PROFILE_ARTIFACT_SCHEMA);
        assert_eq!(upgraded.version, PROFILE_ARTIFACT_SCHEMA_VERSION);
        assert_eq!(upgraded.exported_at, 10);
    }

    #[test]
    fn legacy_upgrade_defaults_missing_export_timestamp_to_zero() {
        let mut legacy = legacy_envelope(1);
        legacy.as_object_mut().unwrap().remove("exportedAt");

        let upgraded =
            ProfileArtifact::decode_import_json(&serde_json::to_vec(&legacy).unwrap()).unwrap();
        assert_eq!(upgraded.schema, PROFILE_ARTIFACT_SCHEMA);
        assert_eq!(upgraded.version, PROFILE_ARTIFACT_SCHEMA_VERSION);
        assert_eq!(upgraded.exported_at, 0);
    }

    #[test]
    fn legacy_upgrade_defaults_missing_version_and_export_timestamp() {
        let mut legacy = legacy_envelope(1);
        let object = legacy.as_object_mut().unwrap();
        object.remove("version");
        object.remove("exportedAt");

        let upgraded =
            ProfileArtifact::decode_import_json(&serde_json::to_vec(&legacy).unwrap()).unwrap();
        assert_eq!(upgraded.schema, PROFILE_ARTIFACT_SCHEMA);
        assert_eq!(upgraded.version, PROFILE_ARTIFACT_SCHEMA_VERSION);
        assert_eq!(upgraded.exported_at, 0);
    }

    #[test]
    fn legacy_upgrade_preserves_safe_json_and_filters_and_remaps_binding_maps() {
        let orphan = "00000000-0000-0000-0000-000000000999";
        let mut legacy = legacy_envelope(4);
        let object = legacy.as_object_mut().unwrap();
        object.remove("activeProfileID");
        object.insert("defaultProfileID".to_owned(), Value::Null);
        object.insert(
            "futureTopLevel".to_owned(),
            json!({"nested": [true, null, "kept"]}),
        );
        legacy["profiles"][0]["launchTarget"] = json!({
            "filePath": "/Users/example/Local.app",
            "bookmarkData": "removed-with-target"
        });
        legacy["profiles"][0]["futureProfileField"]["upgrade"] = json!("kept");
        let keys = legacy["profileKeyBindings"].as_object_mut().unwrap();
        let mut first_bindings = keys.remove(FIRST_ID).unwrap();
        first_bindings["futureButton"]["futureLegacyBinding"] = json!({"kept": 1});
        keys.insert(FIRST_ID.to_ascii_uppercase(), first_bindings);
        keys.insert(orphan.to_owned(), json!({"futureButton": {"keyCode": 1}}));
        legacy["profileOutputBindings"][orphan] = json!({"futureButton": {}});

        let upgraded =
            ProfileArtifact::decode_import_json(&serde_json::to_vec(&legacy).unwrap()).unwrap();
        assert_eq!(upgraded.active_profile_id.as_deref(), Some(FIRST_ID));
        assert_eq!(upgraded.default_profile_id, None);
        assert!(upgraded.profiles[0].get("launchTarget").is_none());
        assert_eq!(
            upgraded.profiles[0]["futureProfileField"]["upgrade"],
            "kept"
        );
        assert_eq!(upgraded.extensions["futureTopLevel"]["nested"][2], "kept");
        assert_eq!(
            upgraded.profile_key_bindings[FIRST_ID]["futureButton"]["futureLegacyBinding"]["kept"],
            1
        );
        assert!(!upgraded.profile_key_bindings.contains_key(orphan));
        assert!(!upgraded.profile_output_bindings.contains_key(orphan));
        let document = upgraded.to_configuration_document().unwrap();
        assert_eq!(document.active_profile_id, FIRST_ID);
        assert_eq!(document.default_profile_id, FIRST_ID);
    }

    #[test]
    fn legacy_upgrade_rejects_nonportable_globals_references_schema_and_versions() {
        let mut embedded = legacy_envelope(1);
        embedded["profiles"][0]["customization"]["asset"] = json!({"data": "embedded"});
        assert!(matches!(
            ProfileArtifact::decode_import_json(&serde_json::to_vec(&embedded).unwrap()),
            Err(ProfileArtifactError::ForbiddenField(field)) if field == "data"
        ));

        let mut missing_active_target = legacy_envelope(1);
        missing_active_target["activeProfileID"] = json!("00000000-0000-0000-0000-000000000999");
        assert_eq!(
            ProfileArtifact::decode_import_json(
                &serde_json::to_vec(&missing_active_target).unwrap()
            ),
            Err(ProfileArtifactError::ActiveProfileMissing)
        );
        let mut missing_default_target = legacy_envelope(1);
        missing_default_target["defaultProfileID"] = json!("00000000-0000-0000-0000-000000000999");
        assert_eq!(
            ProfileArtifact::decode_import_json(
                &serde_json::to_vec(&missing_default_target).unwrap()
            ),
            Err(ProfileArtifactError::DefaultProfileMissing)
        );

        for field in ["keyBindings", "outputBindings", "contentHash"] {
            let mut forbidden = legacy_envelope(1);
            forbidden[field] = Value::Null;
            assert!(
                ProfileArtifact::decode_import_json(&serde_json::to_vec(&forbidden).unwrap())
                    .is_err()
            );
        }
        let mut wrong_schema = legacy_envelope(1);
        wrong_schema["schema"] = json!("wrong");
        assert_eq!(
            ProfileArtifact::decode_import_json(&serde_json::to_vec(&wrong_schema).unwrap()),
            Err(ProfileArtifactError::UnsupportedSchema)
        );
        for version in [0, 5] {
            let unsupported = legacy_envelope(version);
            assert_eq!(
                ProfileArtifact::decode_import_json(&serde_json::to_vec(&unsupported).unwrap()),
                Err(ProfileArtifactError::UnsupportedSchemaVersion(version))
            );
        }
    }

    #[test]
    fn import_decode_never_falls_back_when_artifact_version_is_present() {
        let mut tampered = serde_json::to_value(artifact()).unwrap();
        tampered["profiles"][0]["name"] = json!("Tampered");
        assert_eq!(
            ProfileArtifact::decode_import_json(&serde_json::to_vec(&tampered).unwrap()),
            Err(ProfileArtifactError::ContentHashMismatch)
        );

        let mut bad_version = serde_json::to_value(artifact()).unwrap();
        bad_version["artifactVersion"] = json!(2);
        assert_eq!(
            ProfileArtifact::decode_import_json(&serde_json::to_vec(&bad_version).unwrap()),
            Err(ProfileArtifactError::UnsupportedArtifactVersion(2))
        );
    }

    #[test]
    fn artifact_round_trip_preserves_raw_unknown_fields_and_is_deterministic() {
        let mut artifact = artifact();
        let raw_keys = artifact.profile_key_bindings.get_mut(FIRST_ID).unwrap();
        raw_keys["futureButton"]["futureBinding"] = json!({"label": "値"});
        raw_keys["futureButton"]["sequence"][1]["futureStroke"] = json!(true);
        let raw_outputs = artifact.profile_output_bindings.get_mut(FIRST_ID).unwrap();
        raw_outputs["futureButton"]["futureOutput"] = json!(7);
        raw_outputs["futureButton"]["keyboard"]["futureKeyboard"] = json!("kept");
        raw_outputs["futureButton"]["gamepadButtons"] = json!(["futureButton", "south"]);
        artifact.extensions.insert(
            "futureTopLevel".to_owned(),
            json!({"ratio": 0.25, "nullable": null}),
        );
        artifact.refresh_content_hash().unwrap();

        let first = artifact.encode_compact_json().unwrap();
        assert_eq!(first, artifact.encode_compact_json().unwrap());
        let decoded = ProfileArtifact::decode_json(&first).unwrap();
        assert_eq!(decoded, artifact);
        assert_eq!(
            decoded.profile_key_bindings[FIRST_ID]["futureButton"]["futureBinding"]["label"],
            "値"
        );
        assert_eq!(
            decoded.profile_key_bindings[FIRST_ID]["futureButton"]["sequence"][1]["futureStroke"],
            true
        );
        assert_eq!(
            decoded.profile_output_bindings[FIRST_ID]["futureButton"]["futureOutput"],
            7
        );
        let converted = decoded.to_configuration_document().unwrap();
        assert!(converted.profile_key_bindings[FIRST_ID]
            .get_raw("futureButton")
            .is_some());
        assert!(converted.profile_output_bindings[FIRST_ID]
            .get_raw("futureButton")
            .unwrap()
            .gamepad_buttons
            .contains("futureButton"));
    }

    #[test]
    fn all_selection_preserves_order_references_and_canonical_maps() {
        let artifact = artifact();
        assert_eq!(artifact.profiles.len(), 2);
        assert_eq!(profile_id(&artifact.profiles[0]), Some(FIRST_ID));
        assert_eq!(profile_id(&artifact.profiles[1]), Some(SECOND_ID));
        assert_eq!(artifact.active_profile_id.as_deref(), Some(FIRST_ID));
        assert_eq!(artifact.default_profile_id.as_deref(), Some(SECOND_ID));
        assert_eq!(
            artifact.profile_key_bindings.keys().collect::<Vec<_>>(),
            vec![FIRST_ID]
        );
        assert_eq!(
            artifact.profile_output_bindings.keys().collect::<Vec<_>>(),
            vec![FIRST_ID]
        );
    }

    #[test]
    fn content_hash_detects_semantic_tampering_but_excludes_export_timestamp() {
        let artifact = artifact();
        let expected_hash = artifact.content_hash.value.clone();
        let mut timestamp_only = artifact.clone();
        timestamp_only.exported_at = 11;
        assert_eq!(timestamp_only.content_hash.value, expected_hash);
        timestamp_only.validate().unwrap();

        let mut tampered = artifact;
        tampered.profiles[0]["name"] = Value::String("Tampered".to_owned());
        assert_eq!(
            tampered.validate(),
            Err(ProfileArtifactError::ContentHashMismatch)
        );
    }

    #[test]
    fn single_selection_filters_and_null_default_falls_back_on_conversion() {
        let artifact = ProfileArtifact::from_configuration(
            &document(),
            ProfileArtifactSelection::ProfileId(FIRST_ID.to_ascii_uppercase()),
            99,
        )
        .unwrap();
        assert_eq!(artifact.profiles.len(), 1);
        assert_eq!(artifact.active_profile_id.as_deref(), Some(FIRST_ID));
        assert_eq!(artifact.default_profile_id, None);
        let converted = artifact.to_configuration_document().unwrap();
        assert_eq!(converted.active_profile_id, FIRST_ID);
        assert_eq!(converted.default_profile_id, FIRST_ID);
        assert_eq!(
            converted.profile_key_bindings.keys().collect::<Vec<_>>(),
            vec![FIRST_ID]
        );
        assert_eq!(
            converted.key_bindings,
            converted.profile_key_bindings[FIRST_ID]
        );
        assert_eq!(
            converted.output_bindings,
            converted.profile_output_bindings[FIRST_ID]
        );
    }

    #[test]
    fn conversion_hydrates_global_mirrors_only_from_the_active_profile() {
        let mut source = document();
        source.active_profile_id = SECOND_ID.to_owned();
        let mut second_keys = ButtonBindings::default();
        second_keys.insert_raw("secondButton", KeyBinding::new(14, 0));
        let mut second_outputs = ButtonBindings::default();
        second_outputs.insert_raw(
            "secondButton",
            OutputBinding::keyboard(KeyBinding::new(14, 0)),
        );
        source
            .profile_key_bindings
            .insert(SECOND_ID.to_owned(), second_keys.clone());
        source
            .profile_output_bindings
            .insert(SECOND_ID.to_owned(), second_outputs.clone());

        let artifact =
            ProfileArtifact::from_configuration(&source, ProfileArtifactSelection::All, 10)
                .unwrap();
        let converted = artifact.to_configuration_document().unwrap();
        assert_eq!(converted.active_profile_id, SECOND_ID);
        assert_eq!(converted.key_bindings, second_keys);
        assert_eq!(converted.output_bindings, second_outputs);
        assert_ne!(
            converted.key_bindings,
            converted.profile_key_bindings[FIRST_ID]
        );
    }

    #[test]
    fn stale_orphan_maps_are_ignored_but_decoded_orphans_are_rejected() {
        let orphan = "00000000-0000-0000-0000-000000000999";
        let mut source = document();
        source
            .profile_key_bindings
            .insert(orphan.to_owned(), ButtonBindings::default());
        let artifact = ProfileArtifact::from_configuration(
            &source,
            ProfileArtifactSelection::ProfileId(FIRST_ID.to_owned()),
            10,
        )
        .unwrap();
        assert!(!artifact.profile_key_bindings.contains_key(orphan));

        let mut decoded = artifact;
        decoded
            .profile_key_bindings
            .insert(orphan.to_owned(), json!({}));
        assert_eq!(
            decoded.refresh_content_hash(),
            Err(ProfileArtifactError::BindingProfileMissing)
        );
    }

    #[test]
    fn export_removes_launch_target_and_rejects_embedded_or_local_content() {
        let mut source = document();
        source.profiles[0]["launchTarget"] = json!({
            "filePath": "/Users/example/Secret.app",
            "bookmarkData": "base64",
            "iconPNGData": "base64"
        });
        let artifact =
            ProfileArtifact::from_configuration(&source, ProfileArtifactSelection::All, 10)
                .unwrap();
        assert!(artifact.profiles[0].get("launchTarget").is_none());

        let mut external = artifact.clone();
        external.profiles[0]["launchTarget"] = json!({"bundleIdentifier": "example.app"});
        assert!(matches!(
            external.refresh_content_hash(),
            Err(ProfileArtifactError::ForbiddenField(field)) if field == "launchTarget"
        ));

        for (field, value) in [
            ("data", json!("embedded-image")),
            ("bookmarkData", json!("bookmark")),
            ("iconPNGData", json!("png")),
            ("filePath", json!("/Users/example/file")),
        ] {
            let mut source = document();
            source.profiles[0]["customization"]["assetLibrary"] =
                json!({"assets": [{field: value}]});
            assert!(matches!(
                ProfileArtifact::from_configuration(
                    &source,
                    ProfileArtifactSelection::All,
                    10
                ),
                Err(ProfileArtifactError::ForbiddenField(found)) if found == field
            ));
        }

        let mut source = document();
        source.profiles[0]["customization"]["background"] =
            json!({"image": {"data": "inline-image"}});
        assert!(matches!(
            ProfileArtifact::from_configuration(&source, ProfileArtifactSelection::All, 10),
            Err(ProfileArtifactError::ForbiddenField(field)) if field == "data"
        ));
    }

    #[test]
    fn standard_secrets_are_rejected_while_null_local_fields_are_allowed() {
        for field in [
            "password",
            "apiKey",
            "privateKey",
            "authorization",
            "authorizationHeader",
            "cookie",
            "sessionKey",
            "refresh_token",
            "bearerToken",
            "oauthAccessToken",
            "idToken",
            "deviceID",
            "path",
            "fileURL",
            "serverURL",
            "thumbnailData",
        ] {
            let mut artifact = artifact();
            artifact
                .extensions
                .insert(field.to_owned(), json!("secret"));
            assert!(matches!(
                artifact.refresh_content_hash(),
                Err(ProfileArtifactError::ForbiddenField(found)) if found == field
            ));
        }
        let mut reserved = artifact();
        reserved
            .extensions
            .insert("keyBindings".to_owned(), json!({}));
        assert!(matches!(
            reserved.refresh_content_hash(),
            Err(ProfileArtifactError::ReservedExtensionField(field)) if field == "keyBindings"
        ));

        let mut artifact = artifact();
        artifact.profiles[0]["future"]["data"] = Value::Null;
        artifact
            .extensions
            .insert("serverURL".to_owned(), Value::Null);
        artifact.refresh_content_hash().unwrap();
        artifact.validate().unwrap();
    }

    #[test]
    fn structure_versions_references_ids_and_binding_keys_fail_closed() {
        let mut wrong_schema = artifact();
        wrong_schema.schema = "wrong".to_owned();
        assert_eq!(
            wrong_schema.validate(),
            Err(ProfileArtifactError::UnsupportedSchema)
        );

        let mut wrong_version = artifact();
        wrong_version.version += 1;
        assert_eq!(
            wrong_version.validate(),
            Err(ProfileArtifactError::UnsupportedSchemaVersion(5))
        );
        let mut wrong_artifact = artifact();
        wrong_artifact.artifact_version += 1;
        assert_eq!(
            wrong_artifact.validate(),
            Err(ProfileArtifactError::UnsupportedArtifactVersion(2))
        );
        let mut wrong_catalog = artifact();
        wrong_catalog.catalog_revision.generation_spec += 1;
        assert_eq!(
            wrong_catalog.validate(),
            Err(ProfileArtifactError::UnsupportedCatalogRevision)
        );

        let mut missing_active = artifact();
        missing_active.active_profile_id = None;
        assert_eq!(
            missing_active.refresh_content_hash(),
            Err(ProfileArtifactError::ActiveProfileMissing)
        );
        let mut missing_default = artifact();
        missing_default.default_profile_id = Some("00000000-0000-0000-0000-000000000999".into());
        assert_eq!(
            missing_default.refresh_content_hash(),
            Err(ProfileArtifactError::DefaultProfileMissing)
        );

        let mut invalid_id = artifact();
        invalid_id.profiles[0]["id"] = json!("not-a-uuid");
        assert_eq!(
            invalid_id.refresh_content_hash(),
            Err(ProfileArtifactError::InvalidProfileId)
        );

        let mut duplicate_ids = artifact();
        duplicate_ids.profiles[0]["id"] = json!("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        duplicate_ids.profiles[1]["id"] = json!("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA");
        assert_eq!(
            duplicate_ids.refresh_content_hash(),
            Err(ProfileArtifactError::DuplicateProfileId)
        );

        let mut case_collision = artifact();
        case_collision.profiles[0]["id"] = json!("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
        case_collision.active_profile_id = Some("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".into());
        let raw = case_collision
            .profile_key_bindings
            .remove(FIRST_ID)
            .unwrap();
        case_collision
            .profile_key_bindings
            .insert("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".into(), raw.clone());
        case_collision
            .profile_key_bindings
            .insert("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA".into(), raw);
        assert_eq!(
            case_collision.refresh_content_hash(),
            Err(ProfileArtifactError::DuplicateBindingProfileId)
        );
    }

    #[test]
    fn explicit_decode_selection_hash_and_bound_failures_are_covered() {
        assert_eq!(
            ProfileArtifact::decode_json(b"{not-json"),
            Err(ProfileArtifactError::DecodingFailed)
        );
        assert_eq!(
            ProfileArtifact::from_configuration(
                &document(),
                ProfileArtifactSelection::ProfileId("00000000-0000-0000-0000-000000000999".into()),
                10
            ),
            Err(ProfileArtifactError::SelectedProfileMissing)
        );
        let mut invalid_hash = artifact();
        invalid_hash.content_hash.value = "A".repeat(64);
        assert_eq!(
            invalid_hash.validate(),
            Err(ProfileArtifactError::InvalidContentHash)
        );
        let oversized = vec![b' '; MAXIMUM_PROFILE_ARTIFACT_BYTES + 1];
        assert!(matches!(
            ProfileArtifact::decode_json(&oversized),
            Err(ProfileArtifactError::TooLarge(size)) if size == oversized.len()
        ));
    }

    #[test]
    fn portable_json_depth_string_and_container_bounds_are_enforced() {
        let mut nested = Value::Null;
        for _ in 0..=MAXIMUM_PORTABLE_JSON_DEPTH {
            nested = json!([nested]);
        }
        let mut too_deep = artifact();
        too_deep.extensions.insert("future".to_owned(), nested);
        assert_eq!(
            too_deep.refresh_content_hash(),
            Err(ProfileArtifactError::PortableDepthExceeded)
        );

        let mut long_string = artifact();
        long_string.extensions.insert(
            "future".to_owned(),
            Value::String("x".repeat(MAXIMUM_PORTABLE_STRING_BYTES + 1)),
        );
        assert!(matches!(
            long_string.refresh_content_hash(),
            Err(ProfileArtifactError::PortableStringTooLarge(_))
        ));

        let mut large_array = artifact();
        large_array.extensions.insert(
            "future".to_owned(),
            Value::Array(vec![Value::Null; MAXIMUM_PORTABLE_CONTAINER_ENTRIES + 1]),
        );
        assert!(matches!(
            large_array.refresh_content_hash(),
            Err(ProfileArtifactError::PortableContainerTooLarge(_))
        ));
    }

    #[test]
    fn portable_json_integers_enforce_i_json_safe_bounds_without_rejecting_floats() {
        for boundary in [
            json!(MAXIMUM_I_JSON_SAFE_INTEGER),
            json!(-MAXIMUM_I_JSON_SAFE_INTEGER),
        ] {
            let mut artifact = artifact();
            artifact
                .extensions
                .insert("futureInteger".to_owned(), boundary);
            artifact.refresh_content_hash().unwrap();
            artifact.validate().unwrap();
        }

        for out_of_range in [
            MAXIMUM_I_JSON_SAFE_INTEGER + 1,
            -MAXIMUM_I_JSON_SAFE_INTEGER - 1,
        ] {
            let mut artifact = artifact();
            artifact
                .extensions
                .insert("futureInteger".to_owned(), json!(out_of_range));
            assert_eq!(
                artifact.refresh_content_hash(),
                Err(ProfileArtifactError::PortableIntegerOutOfRange(
                    out_of_range.to_string()
                ))
            );
        }

        let mut floating = artifact();
        floating.extensions.insert(
            "futureFloatingPoint".to_owned(),
            Value::Number(serde_json::Number::from_f64(9_007_199_254_740_992.0).unwrap()),
        );
        floating.refresh_content_hash().unwrap();
        floating.validate().unwrap();
    }

    #[test]
    fn configuration_profile_bound_is_reused() {
        let mut repeated = vec![profile(FIRST_ID, "First"), profile(SECOND_ID, "Second")];
        repeated.extend((0..(MAXIMUM_CONFIGURATION_PROFILES - 1)).map(|index| {
            profile(
                &format!("cccccccc-0000-0000-0000-{index:012}"),
                &format!("Profile {index}"),
            )
        }));
        let mut artifact = artifact();
        artifact.profiles = repeated;
        assert!(matches!(
            artifact.refresh_content_hash(),
            Err(ProfileArtifactError::InvalidConfiguration(
                ConfigurationDocumentError::InvalidProfileCount(_)
            ))
        ));
    }

    #[test]
    fn rfc8785_numbers_key_order_and_escaping_match_the_standard_vector() {
        let value: Value = serde_json::from_str(
            r#"{
                "numbers": [333333333.33333329, 1E30, 4.50, 2e-3, 0.000000000000000000000000001],
                "string": "€$\u000f\nA'B\"\\\"/",
                "literals": [null, true, false]
            }"#,
        )
        .unwrap();
        let canonical = serde_json_canonicalizer::to_string(&value).unwrap();
        assert_eq!(
            canonical,
            "{\"literals\":[null,true,false],\"numbers\":[333333333.3333333,1e+30,4.5,0.002,1e-27],\"string\":\"€$\\u000f\\nA'B\\\"\\\\\\\"/\"}"
        );
    }
}
