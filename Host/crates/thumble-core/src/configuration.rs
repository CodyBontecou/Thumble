use crate::state::profile_id;
use crate::{ButtonBindings, KeyBinding, OutputBinding, PersistentState};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;

pub const MAXIMUM_CONFIGURATION_DOCUMENT_BYTES: usize = 8 * 1024 * 1024;
pub const MAXIMUM_CONFIGURATION_PROFILES: usize = 256;
pub const MAXIMUM_CONFIGURATION_PROFILE_ID_BYTES: usize = 128;
pub const MAXIMUM_CONFIGURATION_PROFILE_NAME_CHARACTERS: usize = 256;
pub const MAXIMUM_CONFIGURATION_BINDING_STROKES: usize = 32;
const MAXIMUM_PROFILE_BINDING_MAPS: usize = 512;
// At most 128 controls in each of the three executable orientations.
const MAXIMUM_PROFILE_BINDINGS: usize = 128 * 3;

/// Credential-free configuration state transformed by drafts and the Swift
/// operation bridge. Server identity and trusted-client data cannot be encoded
/// in this type and therefore cannot enter a draft or bridge request by field.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConfigurationDocument {
    pub profiles: Vec<Value>,
    #[serde(rename = "activeProfileID")]
    pub active_profile_id: String,
    #[serde(rename = "defaultProfileID")]
    pub default_profile_id: String,
    #[serde(default)]
    pub key_bindings: ButtonBindings<KeyBinding>,
    #[serde(default)]
    pub output_bindings: ButtonBindings<OutputBinding>,
    #[serde(default)]
    pub profile_key_bindings: BTreeMap<String, ButtonBindings<KeyBinding>>,
    #[serde(default)]
    pub profile_output_bindings: BTreeMap<String, ButtonBindings<OutputBinding>>,
}

impl fmt::Debug for ConfigurationDocument {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ConfigurationDocument")
            .field("profile_count", &self.profiles.len())
            .field("active_profile_id_bytes", &self.active_profile_id.len())
            .field("default_profile_id_bytes", &self.default_profile_id.len())
            .field("key_binding_count", &self.key_bindings.len())
            .field("output_binding_count", &self.output_bindings.len())
            .field(
                "profile_key_binding_map_count",
                &self.profile_key_bindings.len(),
            )
            .field(
                "profile_output_binding_map_count",
                &self.profile_output_bindings.len(),
            )
            .finish()
    }
}

// Borrowing the stored fields keeps startup validation independent of draft
// credential checks and avoids cloning the complete profile catalog.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConfigurationView<'a> {
    profiles: &'a [Value],
    #[serde(rename = "activeProfileID")]
    active_profile_id: &'a str,
    #[serde(rename = "defaultProfileID")]
    default_profile_id: &'a str,
    key_bindings: &'a ButtonBindings<KeyBinding>,
    output_bindings: &'a ButtonBindings<OutputBinding>,
    profile_key_bindings: &'a BTreeMap<String, ButtonBindings<KeyBinding>>,
    profile_output_bindings: &'a BTreeMap<String, ButtonBindings<OutputBinding>>,
}

impl<'a> From<&'a ConfigurationDocument> for ConfigurationView<'a> {
    fn from(document: &'a ConfigurationDocument) -> Self {
        Self {
            profiles: &document.profiles,
            active_profile_id: &document.active_profile_id,
            default_profile_id: &document.default_profile_id,
            key_bindings: &document.key_bindings,
            output_bindings: &document.output_bindings,
            profile_key_bindings: &document.profile_key_bindings,
            profile_output_bindings: &document.profile_output_bindings,
        }
    }
}

impl<'a> From<&'a PersistentState> for ConfigurationView<'a> {
    fn from(state: &'a PersistentState) -> Self {
        Self {
            profiles: &state.profiles,
            active_profile_id: &state.active_profile_id,
            default_profile_id: &state.default_profile_id,
            key_bindings: &state.key_bindings,
            output_bindings: &state.output_bindings,
            profile_key_bindings: &state.profile_key_bindings,
            profile_output_bindings: &state.profile_output_bindings,
        }
    }
}

pub(crate) fn validate_state(state: &PersistentState) -> Result<(), ConfigurationDocumentError> {
    ConfigurationView::from(state).validate()
}

impl ConfigurationDocument {
    pub fn from_state(state: &PersistentState) -> Result<Self, ConfigurationDocumentError> {
        let document = Self {
            profiles: state.profiles.clone(),
            active_profile_id: state.active_profile_id.clone(),
            default_profile_id: state.default_profile_id.clone(),
            key_bindings: state.key_bindings.clone(),
            output_bindings: state.output_bindings.clone(),
            profile_key_bindings: state.profile_key_bindings.clone(),
            profile_output_bindings: state.profile_output_bindings.clone(),
        };
        document.validate()?;

        let encoded = serde_json::to_vec(&document)
            .map_err(|_| ConfigurationDocumentError::EncodingFailed)?;
        if state
            .trusted_clients
            .keys()
            .any(|token| !token.is_empty() && contains_subslice(&encoded, token.as_bytes()))
        {
            return Err(ConfigurationDocumentError::ContainsTrustedCredential);
        }
        Ok(document)
    }

    pub fn validate(&self) -> Result<(), ConfigurationDocumentError> {
        ConfigurationView::from(self).validate()
    }

    /// Refresh mirrors after an explicit authoring/selection transaction. The
    /// original and incoming domains must be validated before this is called;
    /// this is not a saved-data/import recovery path.
    pub fn refresh_global_binding_mirrors(&mut self) -> Result<(), ConfigurationDocumentError> {
        let profile = self
            .profiles
            .iter()
            .find(|profile| {
                profile_id(profile)
                    .is_some_and(|id| id.eq_ignore_ascii_case(&self.active_profile_id))
            })
            .ok_or(ConfigurationDocumentError::ActiveProfileMissing)?;
        let keys = self
            .profile_key_bindings
            .iter()
            .find(|(id, _)| id.eq_ignore_ascii_case(&self.active_profile_id))
            .map(|(_, value)| value);
        let outputs = self
            .profile_output_bindings
            .iter()
            .find(|(id, _)| id.eq_ignore_ascii_case(&self.active_profile_id))
            .map(|(_, value)| value);
        let outputs = crate::resolver::profile_primary_binding_mirrors(profile, keys, outputs);
        self.key_bindings = crate::resolver::keyboard_projection(&outputs);
        self.output_bindings = outputs;
        Ok(())
    }

    /// Install an already validated document without touching credentials or
    /// the authoritative configuration revision. The commit layer owns the
    /// compare-and-swap revision update and atomic persistence ordering.
    pub fn install_into(
        &self,
        state: &mut PersistentState,
    ) -> Result<(), ConfigurationDocumentError> {
        self.validate()?;
        state.profiles.clone_from(&self.profiles);
        state.active_profile_id.clone_from(&self.active_profile_id);
        state
            .default_profile_id
            .clone_from(&self.default_profile_id);
        state.key_bindings.clone_from(&self.key_bindings);
        state.output_bindings.clone_from(&self.output_bindings);
        state
            .profile_key_bindings
            .clone_from(&self.profile_key_bindings);
        state
            .profile_output_bindings
            .clone_from(&self.profile_output_bindings);
        Ok(())
    }
}

impl ConfigurationView<'_> {
    fn validate(&self) -> Result<(), ConfigurationDocumentError> {
        let encoded =
            serde_json::to_vec(self).map_err(|_| ConfigurationDocumentError::EncodingFailed)?;
        if encoded.len() > MAXIMUM_CONFIGURATION_DOCUMENT_BYTES {
            return Err(ConfigurationDocumentError::TooLarge(encoded.len()));
        }
        if self.profiles.is_empty() || self.profiles.len() > MAXIMUM_CONFIGURATION_PROFILES {
            return Err(ConfigurationDocumentError::InvalidProfileCount(
                self.profiles.len(),
            ));
        }
        if self.profile_key_bindings.len() > MAXIMUM_PROFILE_BINDING_MAPS
            || self.profile_output_bindings.len() > MAXIMUM_PROFILE_BINDING_MAPS
        {
            return Err(ConfigurationDocumentError::TooManyProfileBindingMaps);
        }
        let mut declarations = BTreeMap::new();
        for profile in self.profiles {
            let object = profile
                .as_object()
                .ok_or(ConfigurationDocumentError::MalformedProfile)?;
            if object.get("outputMode").is_some_and(|mode| {
                !mode.is_null()
                    && !matches!(mode.as_str(), Some("keyboard" | "controller" | "custom"))
            }) {
                return Err(ConfigurationDocumentError::MalformedProfile);
            }
            let id = profile_id(profile)
                .and_then(parse_profile_id)
                .ok_or(ConfigurationDocumentError::InvalidProfileId)?;
            let name = object
                .get("name")
                .and_then(Value::as_str)
                .ok_or(ConfigurationDocumentError::MalformedProfile)?;
            if name.trim().is_empty()
                || name.chars().count() > MAXIMUM_CONFIGURATION_PROFILE_NAME_CHARACTERS
            {
                return Err(ConfigurationDocumentError::InvalidProfileName);
            }
            if !crate::validate_element_identities(profile) {
                return Err(ConfigurationDocumentError::MalformedCustomization);
            }
            let elements = declared_element_ids(profile);
            if declarations.insert(id, elements).is_some() {
                return Err(ConfigurationDocumentError::DuplicateProfileId);
            }
        }
        let active = parse_profile_id(self.active_profile_id)
            .and_then(|id| declarations.get(&id))
            .ok_or(ConfigurationDocumentError::ActiveProfileMissing)?;
        if parse_profile_id(self.default_profile_id)
            .is_none_or(|id| !declarations.contains_key(&id))
        {
            return Err(ConfigurationDocumentError::DefaultProfileMissing);
        }
        validate_binding_owners(self.key_bindings, active)?;
        validate_binding_owners(self.output_bindings, active)?;
        validate_profile_binding_owners(self.profile_key_bindings, &declarations)?;
        validate_profile_binding_owners(self.profile_output_bindings, &declarations)?;
        validate_key_bindings(self.key_bindings)?;
        validate_output_bindings(self.output_bindings)?;
        for bindings in self.profile_key_bindings.values() {
            validate_key_bindings(bindings)?;
        }
        for bindings in self.profile_output_bindings.values() {
            validate_output_bindings(bindings)?;
        }
        Ok(())
    }
}

fn parse_profile_id(id: &str) -> Option<uuid::Uuid> {
    let parsed = uuid::Uuid::parse_str(id).ok()?;
    parsed
        .hyphenated()
        .to_string()
        .eq_ignore_ascii_case(id)
        .then_some(parsed)
}

pub(crate) fn declared_element_ids(profile: &Value) -> BTreeSet<thumble_protocol::KeypadElementID> {
    [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ]
    .into_iter()
    .filter_map(|name| profile.get(name))
    .filter_map(|customization| customization.get("elements").and_then(Value::as_array))
    .flatten()
    .filter_map(|element| element.get("id").and_then(Value::as_str))
    .filter_map(thumble_protocol::KeypadElementID::parse)
    .collect()
}

fn validate_binding_owners<T>(
    bindings: &ButtonBindings<T>,
    declared: &BTreeSet<thumble_protocol::KeypadElementID>,
) -> Result<(), ConfigurationDocumentError> {
    if bindings.iter_ids().any(|(id, _)| !declared.contains(&id)) {
        return Err(ConfigurationDocumentError::UndeclaredBindingElement);
    }
    Ok(())
}

fn validate_profile_binding_owners<T>(
    maps: &BTreeMap<String, ButtonBindings<T>>,
    declarations: &BTreeMap<uuid::Uuid, BTreeSet<thumble_protocol::KeypadElementID>>,
) -> Result<(), ConfigurationDocumentError> {
    let mut seen = BTreeSet::new();
    for (profile, bindings) in maps {
        let id =
            parse_profile_id(profile).ok_or(ConfigurationDocumentError::BindingProfileMissing)?;
        let declared = declarations
            .get(&id)
            .ok_or(ConfigurationDocumentError::BindingProfileMissing)?;
        if !seen.insert(id) {
            return Err(ConfigurationDocumentError::DuplicateProfileBindingMap);
        }
        validate_binding_owners(bindings, declared)?;
    }
    Ok(())
}

fn validate_key_bindings(
    bindings: &ButtonBindings<KeyBinding>,
) -> Result<(), ConfigurationDocumentError> {
    if bindings.len() > MAXIMUM_PROFILE_BINDINGS {
        return Err(ConfigurationDocumentError::TooManyBindings);
    }
    if bindings.iter().any(|(_, binding)| {
        let count = binding.strokes().len();
        count == 0 || count > MAXIMUM_CONFIGURATION_BINDING_STROKES
    }) {
        return Err(ConfigurationDocumentError::InvalidBindingSequence);
    }
    Ok(())
}

fn validate_output_bindings(
    bindings: &ButtonBindings<OutputBinding>,
) -> Result<(), ConfigurationDocumentError> {
    if bindings.len() > MAXIMUM_PROFILE_BINDINGS {
        return Err(ConfigurationDocumentError::TooManyBindings);
    }
    for (_, binding) in bindings.iter() {
        if binding.gamepad_buttons.len() > 32 {
            return Err(ConfigurationDocumentError::TooManyGamepadOutputs);
        }
        if let Some(keyboard) = &binding.keyboard {
            let count = keyboard.strokes().len();
            if count == 0 || count > MAXIMUM_CONFIGURATION_BINDING_STROKES {
                return Err(ConfigurationDocumentError::InvalidBindingSequence);
            }
        }
    }
    Ok(())
}

fn contains_subslice(haystack: &[u8], needle: &[u8]) -> bool {
    !needle.is_empty()
        && haystack
            .windows(needle.len())
            .any(|window| window == needle)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConfigurationDocumentError {
    EncodingFailed,
    TooLarge(usize),
    InvalidProfileCount(usize),
    TooManyProfileBindingMaps,
    MalformedProfile,
    InvalidProfileId,
    DuplicateProfileId,
    InvalidProfileName,
    MalformedCustomization,
    ActiveProfileMissing,
    DefaultProfileMissing,
    BindingProfileMissing,
    DuplicateProfileBindingMap,
    UndeclaredBindingElement,
    TooManyBindings,
    InvalidBindingSequence,
    TooManyGamepadOutputs,
    ContainsTrustedCredential,
}

impl fmt::Display for ConfigurationDocumentError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EncodingFailed => formatter.write_str("configuration document could not be encoded"),
            Self::TooLarge(bytes) => write!(
                formatter,
                "configuration document is {bytes} bytes; maximum is {MAXIMUM_CONFIGURATION_DOCUMENT_BYTES}"
            ),
            Self::InvalidProfileCount(count) => write!(
                formatter,
                "configuration contains {count} profiles; expected 1 through {MAXIMUM_CONFIGURATION_PROFILES}"
            ),
            Self::TooManyProfileBindingMaps => formatter.write_str("configuration has too many profile binding maps"),
            Self::MalformedProfile => formatter.write_str("configuration contains a malformed profile"),
            Self::InvalidProfileId => formatter.write_str("configuration contains an invalid profile ID"),
            Self::DuplicateProfileId => formatter.write_str("configuration contains duplicate profile IDs"),
            Self::InvalidProfileName => formatter.write_str("configuration contains an invalid profile name"),
            Self::MalformedCustomization => formatter.write_str("configuration contains a malformed customization"),
            Self::ActiveProfileMissing => formatter.write_str("active profile does not exist in the configuration"),
            Self::DefaultProfileMissing => formatter.write_str("default profile does not exist in the configuration"),
            Self::BindingProfileMissing => formatter.write_str("binding maps must reference declared profile UUIDs"),
            Self::DuplicateProfileBindingMap => formatter.write_str("duplicate profile UUID in binding maps"),
            Self::UndeclaredBindingElement => formatter.write_str("binding maps must reference elements declared by their target profile"),
            Self::TooManyBindings => formatter.write_str("configuration contains too many bindings"),
            Self::InvalidBindingSequence => formatter.write_str("configuration contains an invalid binding sequence"),
            Self::TooManyGamepadOutputs => formatter.write_str("configuration contains too many gamepad outputs"),
            Self::ContainsTrustedCredential => formatter.write_str("configuration contains trusted credential material and cannot enter a draft"),
        }
    }
}

impl Error for ConfigurationDocumentError {}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TrustedClient;

    #[test]
    fn document_round_trip_changes_only_configuration_fields() {
        let mut state = PersistentState::minimal("server-id").unwrap();
        state.trusted_clients.insert(
            "secret-token".to_owned(),
            TrustedClient {
                name: "Phone".to_owned(),
                created_at: 1,
                last_seen_at: 2,
            },
        );
        let mut document = ConfigurationDocument::from_state(&state).unwrap();
        document.profiles[0]["name"] = Value::String("Edited".to_owned());
        document.validate().unwrap();

        let revision = state.configuration_revision;
        document.install_into(&mut state).unwrap();
        assert_eq!(state.profiles[0]["name"], "Edited");
        assert_eq!(state.configuration_revision, revision);
        assert!(state.trusted_clients.contains_key("secret-token"));
        assert_eq!(state.server_id, "server-id");
    }

    #[test]
    fn document_rejects_credentials_even_across_free_form_profile_fields() {
        let mut state = PersistentState::minimal("server-id").unwrap();
        let token = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_";
        state.trusted_clients.insert(
            token.to_owned(),
            TrustedClient {
                name: "Phone".to_owned(),
                created_at: 1,
                last_seen_at: 2,
            },
        );
        state.profiles[0]["futureField"] = Value::String(format!("prefix-{token}-suffix"));
        assert_eq!(
            ConfigurationDocument::from_state(&state),
            Err(ConfigurationDocumentError::ContainsTrustedCredential)
        );
    }

    #[test]
    fn validation_preserves_unknown_fields_but_rejects_duplicate_ids() {
        let state = PersistentState::minimal("server-id").unwrap();
        let mut document = ConfigurationDocument::from_state(&state).unwrap();
        document.profiles[0]["futureNested"] = serde_json::json!({"untouched": [1, 2, 3]});
        document.validate().unwrap();
        document.profiles.push(document.profiles[0].clone());
        assert_eq!(
            document.validate(),
            Err(ConfigurationDocumentError::DuplicateProfileId)
        );
    }
}
