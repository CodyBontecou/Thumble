//! Explicit version-5 document codec. The live authority and advertised peer
//! formats remain at v4 until transactional migration and transfer are enabled.
use crate::{
    ConfigurationDocument, ConfigurationDocumentError, MAXIMUM_CONFIGURATION_DOCUMENT_BYTES,
};
use serde_json::Value;
use std::{fmt, sync::Arc};

const SCHEMA: &str = "com.codybontecou.pocketpad.keypad-configuration";
const RETIRED_FIELDS: &[&str] = &[
    "skinReference",
    "skinBaselineCustomization",
    "landscapeSkinBaselineCustomization",
    "portraitSkinBaselineCustomization",
    "landscapeCustomization",
    "portraitCustomization",
    "orientationPreference",
];
#[derive(Debug)]
pub enum OwnedConfigurationError {
    TooLarge,
    InvalidJson,
    InvalidEnvelope,
    Configuration(ConfigurationDocumentError),
}
impl fmt::Display for OwnedConfigurationError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLarge => f.write_str("version-5 configuration exceeds 8 MiB"),
            Self::InvalidJson => f.write_str("invalid version-5 configuration JSON"),
            Self::InvalidEnvelope => f.write_str("invalid version-5 configuration envelope"),
            Self::Configuration(error) => error.fmt(f),
        }
    }
}
impl std::error::Error for OwnedConfigurationError {}

/// Original bytes are the interchange authority. Unknown root/profile metadata,
/// numeric spellings, bindings and local launch data never roundtrip through a
/// normalized display projection. All access is immutable or COW.
#[derive(Clone)]
pub struct OwnedConfigurationDocument {
    original: Arc<[u8]>,
    profiles: Arc<[Value]>,
    active_profile_id: String,
    default_profile_id: Option<String>,
}
impl fmt::Debug for OwnedConfigurationDocument {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("OwnedConfigurationDocument")
            .field("bytes", &self.original.len())
            .field("profiles", &self.profiles.len())
            .finish()
    }
}
impl OwnedConfigurationDocument {
    pub const VERSION: i64 = 5;
    pub fn decode(data: &[u8]) -> Result<Self, OwnedConfigurationError> {
        if data.len() > MAXIMUM_CONFIGURATION_DOCUMENT_BYTES {
            return Err(OwnedConfigurationError::TooLarge);
        }
        let value: Value = thumble_protocol::decode_unique_json(data)
            .map_err(|_| OwnedConfigurationError::InvalidJson)?;
        let Value::Object(mut root) = value else {
            return Err(OwnedConfigurationError::InvalidEnvelope);
        };
        if root.get("schema").and_then(Value::as_str) != Some(SCHEMA)
            || root.get("version").and_then(Value::as_f64) != Some(5.0)
            || [
                "serverID",
                "trustedClients",
                "authToken",
                "artifactVersion",
                "contentHash",
                "catalogRevision",
            ]
            .iter()
            .any(|key| root.contains_key(*key))
            || root
                .get("exportedAt")
                .is_some_and(|value| !nonnegative_integer(value))
        {
            return Err(OwnedConfigurationError::InvalidEnvelope);
        }
        let known = [
            "schema",
            "version",
            "exportedAt",
            "profiles",
            "activeProfileID",
            "defaultProfileID",
            "keyBindings",
            "outputBindings",
            "profileKeyBindings",
            "profileOutputBindings",
        ];
        for key in root.keys() {
            let normalized = normalized_field(key);
            if [
                "serverid",
                "trustedclients",
                "authtoken",
                "artifactversion",
                "contenthash",
                "catalogrevision",
            ]
            .contains(&normalized.as_str())
                || known
                    .iter()
                    .any(|name| *name != key && normalized_field(name) == normalized)
            {
                return Err(OwnedConfigurationError::InvalidEnvelope);
            }
        }
        let active = root
            .get("activeProfileID")
            .and_then(Value::as_str)
            .ok_or(OwnedConfigurationError::InvalidEnvelope)?
            .to_owned();
        let default = match root.get("defaultProfileID") {
            Some(Value::Null) => None,
            Some(Value::String(id)) => Some(id.clone()),
            _ => return Err(OwnedConfigurationError::InvalidEnvelope),
        };
        // Only known configuration fields enter semantic validation. The exact
        // original envelope, including unknown metadata, is retained separately.
        let mut fields = serde_json::Map::new();
        for name in [
            "profiles",
            "activeProfileID",
            "keyBindings",
            "outputBindings",
            "profileKeyBindings",
            "profileOutputBindings",
        ] {
            if let Some(value) = root.remove(name) {
                fields.insert(name.into(), value);
            }
        }
        fields.insert(
            "defaultProfileID".into(),
            Value::String(default.clone().unwrap_or_else(|| active.clone())),
        );
        let validation: ConfigurationDocument = serde_json::from_value(Value::Object(fields))
            .map_err(|_| OwnedConfigurationError::InvalidEnvelope)?;
        validation
            .validate_owned_candidate()
            .map_err(OwnedConfigurationError::Configuration)?;
        Ok(Self {
            original: Arc::from(data),
            profiles: Arc::from(validation.profiles),
            active_profile_id: active,
            default_profile_id: default,
        })
    }
    pub fn original_bytes(&self) -> &[u8] {
        &self.original
    }
    pub fn profiles(&self) -> &[Value] {
        &self.profiles
    }
    pub fn active_profile_id(&self) -> &str {
        &self.active_profile_id
    }
    pub fn default_profile_id(&self) -> Option<&str> {
        self.default_profile_id.as_deref()
    }
}
fn normalized_field(value: &str) -> String {
    value
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_lowercase())
        .collect()
}
fn nonnegative_integer(value: &Value) -> bool {
    value.as_i64().is_some_and(|value| value >= 0)
        || value.as_f64().is_some_and(|value| {
            value.is_finite()
                && (0.0..9_223_372_036_854_775_808.0).contains(&value)
                && value.fract() == 0.0
        })
}
pub(crate) fn validate_profile(profile: &Value) -> Result<(), ConfigurationDocumentError> {
    let object = profile
        .as_object()
        .ok_or(ConfigurationDocumentError::InvalidOwnedProfile)?;
    if object.get("profileFormatVersion").and_then(Value::as_f64) != Some(5.0) {
        return Err(ConfigurationDocumentError::UnsupportedProfileFormat);
    }
    let known = [
        "id",
        "name",
        "updatedAt",
        "customization",
        "outputMode",
        "launchTarget",
        "appearanceBank",
        "appearanceResourceVersion",
        "appearanceResources",
        "profileFormatVersion",
    ];
    if object.keys().any(|key| {
        known
            .iter()
            .any(|name| *name != key && normalized_field(name) == normalized_field(key))
    }) {
        return Err(ConfigurationDocumentError::InvalidOwnedProfile);
    }
    if object.keys().any(|key| {
        RETIRED_FIELDS
            .iter()
            .any(|old| normalized_field(key) == normalized_field(old))
    }) || !object.get("updatedAt").is_some_and(nonnegative_integer)
        || !profile["customization"]["deviceCanvas"]["frameID"]
            .as_str()
            .is_some_and(crate::controller_snapshot::is_canonical_landscape_frame_id)
    {
        return Err(ConfigurationDocumentError::InvalidOwnedProfile);
    }
    crate::profile_appearance::validate_canonical_profile_appearance(profile)
        .map_err(|_| ConfigurationDocumentError::InvalidOwnedProfile)
}
