use crate::{ButtonBindings, KeyBinding, OutputBinding};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use thumble_protocol::{KeypadElementID, KeypadElementInputPart};

pub const CURRENT_SCHEMA_VERSION: u32 = 3;
pub const INITIAL_CONFIGURATION_REVISION: u64 = 1;
pub const MAXIMUM_RECENT_CONFIGURATION_COMMITS: usize = 32;
pub const DEFAULT_PROFILE_ID: &str = "00000000-0000-0000-0000-000000000201";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigurationCommitRecord {
    #[serde(rename = "commitID")]
    pub commit_id: String,
    #[serde(rename = "draftID")]
    pub draft_id: String,
    pub base_configuration_revision: u64,
    pub result_configuration_revision: u64,
    pub draft_revision: u64,
    pub draft_digest: String,
    /// Optional digest of a constrained high-level caller request. This lets
    /// deterministic commit IDs reject reuse for different request content
    /// without retaining the request, profile document, or credentials.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_request_digest: Option<String>,
    pub committed_at: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedClient {
    #[serde(alias = "clientName")]
    pub name: String,
    pub created_at: i64,
    pub last_seen_at: i64,
}

/// Portable state owned by the host adapter.
///
/// Profiles remain raw JSON values so fields introduced by a newer Swift app
/// survive storage, profile switching, binding lookup, and customization edits.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersistentState {
    pub schema_version: u32,
    #[serde(rename = "serverID")]
    pub server_id: String,
    pub trusted_clients: BTreeMap<String, TrustedClient>,
    #[serde(default = "initial_configuration_revision")]
    pub configuration_revision: u64,
    #[serde(default)]
    pub configuration_updated_at: i64,
    #[serde(default)]
    pub recent_configuration_commits: Vec<ConfigurationCommitRecord>,
    pub profiles: Vec<Value>,
    #[serde(
        rename = "activeProfileID",
        alias = "activeProfileId",
        alias = "activeGamepadProfileID"
    )]
    pub active_profile_id: String,
    #[serde(
        rename = "defaultProfileID",
        alias = "defaultProfileId",
        alias = "defaultGamepadProfileID"
    )]
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

impl fmt::Debug for PersistentState {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let exposes_token = |value: &str| {
            self.trusted_clients
                .keys()
                .any(|token| !token.is_empty() && value.contains(token))
        };
        let server_id = if exposes_token(&self.server_id) {
            "[REDACTED]"
        } else {
            self.server_id.as_str()
        };
        let active_profile_id = if exposes_token(&self.active_profile_id) {
            "[REDACTED]"
        } else {
            self.active_profile_id.as_str()
        };
        let default_profile_id = if exposes_token(&self.default_profile_id) {
            "[REDACTED]"
        } else {
            self.default_profile_id.as_str()
        };
        formatter
            .debug_struct("PersistentState")
            .field("schema_version", &self.schema_version)
            .field("server_id", &server_id)
            .field("trusted_client_count", &self.trusted_clients.len())
            .field("configuration_revision", &self.configuration_revision)
            .field("configuration_updated_at", &self.configuration_updated_at)
            .field(
                "recent_configuration_commit_count",
                &self.recent_configuration_commits.len(),
            )
            .field("profile_count", &self.profiles.len())
            .field("active_profile_id", &active_profile_id)
            .field("default_profile_id", &default_profile_id)
            .field("key_binding_count", &self.key_bindings.len())
            .field("output_binding_count", &self.output_bindings.len())
            .field(
                "profile_key_binding_count",
                &self.profile_key_bindings.len(),
            )
            .field(
                "profile_output_binding_count",
                &self.profile_output_bindings.len(),
            )
            .finish()
    }
}

impl PersistentState {
    pub fn minimal(server_id: impl Into<String>) -> Result<Self, StateError> {
        let server_id = server_id.into();
        if server_id.trim().is_empty() {
            return Err(StateError::EmptyServerId);
        }

        let profile = minimal_default_profile();
        let key_bindings = canonical_default_profile_key_bindings();
        let output_bindings = crate::profile_owned_outputs(&profile);

        // Keep these maps independent so edits remain profile-scoped.
        let profile_key_bindings =
            BTreeMap::from([(DEFAULT_PROFILE_ID.to_owned(), key_bindings.clone())]);
        let profile_output_bindings =
            BTreeMap::from([(DEFAULT_PROFILE_ID.to_owned(), output_bindings.clone())]);

        Ok(Self {
            schema_version: CURRENT_SCHEMA_VERSION,
            server_id,
            trusted_clients: BTreeMap::new(),
            configuration_revision: INITIAL_CONFIGURATION_REVISION,
            configuration_updated_at: 0,
            recent_configuration_commits: Vec::new(),
            profiles: vec![profile],
            active_profile_id: DEFAULT_PROFILE_ID.to_owned(),
            default_profile_id: DEFAULT_PROFILE_ID.to_owned(),
            key_bindings,
            output_bindings,
            profile_key_bindings,
            profile_output_bindings,
        })
    }

    /// Check the complete configuration without canonicalizing or trimming it.
    /// Borrowed transaction sources must pass this before reads or cached replay.
    pub fn validate(&self) -> Result<(), StateError> {
        match self.schema_version {
            CURRENT_SCHEMA_VERSION => {
                if self.configuration_revision == 0 {
                    return Err(StateError::InvalidConfigurationRevision);
                }
            }
            version => return Err(StateError::UnsupportedSchemaVersion(version)),
        }
        if self.server_id.trim().is_empty() {
            return Err(StateError::EmptyServerId);
        }
        if self.profiles.iter().any(|profile| !crate::validate_element_identities(profile)) {
            return Err(StateError::UnsupportedInputSlots);
        }

        crate::configuration::validate_state(self).map_err(StateError::InvalidConfiguration)
    }

    pub fn normalize(&mut self) -> Result<(), StateError> {
        // Invalid storage must not be repaired into another setup.
        self.validate()?;
        let active = self.canonical_profile_id(&self.active_profile_id).unwrap().to_owned();
        let default = self.canonical_profile_id(&self.default_profile_id).unwrap().to_owned();
        self.active_profile_id = active;
        self.default_profile_id = default;
        if self.recent_configuration_commits.len() > MAXIMUM_RECENT_CONFIGURATION_COMMITS {
            let remove = self.recent_configuration_commits.len() - MAXIMUM_RECENT_CONFIGURATION_COMMITS;
            self.recent_configuration_commits.drain(..remove);
        }
        Ok(())
    }

    pub fn profile(&self, id: &str) -> Option<&Value> {
        self.profiles
            .iter()
            .find(|profile| profile_id(profile).is_some_and(|candidate| ids_equal(candidate, id)))
    }

    pub fn profile_mut(&mut self, id: &str) -> Option<&mut Value> {
        self.profiles
            .iter_mut()
            .find(|profile| profile_id(profile).is_some_and(|candidate| ids_equal(candidate, id)))
    }

    pub fn active_profile(&self) -> Option<&Value> {
        self.profile(&self.active_profile_id)
    }

    pub(crate) fn gamepad_output_disabled(&self) -> bool {
        self.active_profile()
            .and_then(|profile| profile.get("outputMode"))
            .and_then(Value::as_str)
            .unwrap_or("keyboard")
            == "keyboard"
    }

    /// Whether the active profile requests a controller. Keyboard mode gates
    /// every path, including direct element bindings and orientation variants.
    /// A missing outputMode has the same keyboard default as native profiles.
    pub fn needs_virtual_gamepad(&self) -> bool {
        if self.gamepad_output_disabled() {
            return false;
        }
        if self
            .active_profile()
            .and_then(|profile| profile.get("outputMode"))
            .and_then(Value::as_str)
            == Some("controller")
        {
            return true;
        }
        if self.active_profile().is_some_and(|profile| {
            ["customization", "landscapeCustomization", "portraitCustomization"]
                .into_iter().filter_map(|name| profile.get(name))
                .filter_map(|customization| customization.get("elements").and_then(Value::as_array))
                .flatten().filter_map(|element| element.get("id").and_then(Value::as_str).and_then(KeypadElementID::parse))
                .any(|id| [KeypadElementInputPart::Primary, KeypadElementInputPart::JoystickUp,
                    KeypadElementInputPart::JoystickDown, KeypadElementInputPart::JoystickLeft,
                    KeypadElementInputPart::JoystickRight, KeypadElementInputPart::TriggerDigital]
                    .into_iter().any(|part| self.resolve_element_output(&id.to_string(), part)
                        .is_some_and(|output| output.supported_gamepad_buttons().next().is_some())))
        }) {
            return true;
        }
        self.active_profile().is_some_and(|profile| {
            [
                "customization",
                "landscapeCustomization",
                "portraitCustomization",
            ]
            .into_iter()
            .filter_map(|name| profile.get(name))
            .any(customization_needs_gamepad)
        })
    }

    pub fn active_customization(&self) -> Value {
        self.active_profile()
            .and_then(Value::as_object)
            .and_then(|profile| profile.get("customization"))
            .cloned()
            .unwrap_or_else(|| json!({}))
    }

    pub fn contains_profile(&self, id: &str) -> bool {
        self.profile(id).is_some()
    }

    pub fn canonical_profile_id(&self, id: &str) -> Option<&str> {
        self.profile(id).and_then(profile_id)
    }

    pub fn recent_configuration_commit(
        &self,
        commit_id: &str,
    ) -> Option<&ConfigurationCommitRecord> {
        self.recent_configuration_commits
            .iter()
            .find(|record| record.commit_id == commit_id)
    }

    pub fn record_configuration_commit(&mut self, record: ConfigurationCommitRecord) {
        self.recent_configuration_commits.push(record);
        if self.recent_configuration_commits.len() > MAXIMUM_RECENT_CONFIGURATION_COMMITS {
            self.recent_configuration_commits.remove(0);
        }
    }

    pub fn bump_configuration_revision(&mut self) -> Result<u64, StateError> {
        self.configuration_revision = self
            .configuration_revision
            .checked_add(1)
            .ok_or(StateError::ConfigurationRevisionExhausted)?;
        Ok(self.configuration_revision)
    }
}

fn customization_needs_gamepad(customization: &Value) -> bool {
    customization.get("elements").and_then(Value::as_array).is_some_and(|controls| {
        controls.iter().filter(|control| control.get("id").and_then(Value::as_str)
            .and_then(KeypadElementID::parse).is_some()).any(control_needs_gamepad)
    })
}

fn control_needs_gamepad(control: &Value) -> bool {
    let kind = control
        .get("kind")
        .or_else(|| control.get("controlKind"))
        .and_then(Value::as_str);
    if kind == Some("trigger") {
        return true;
    }
    if kind == Some("joystick")
        && matches!(
            control
                .get("joystickOutputSettings")
                .and_then(|settings| settings.get("analogTarget"))
                .and_then(Value::as_str),
            Some("left_stick" | "right_stick")
        )
    {
        return true;
    }
    // Digital outputs, including joystick directions, are checked through the
    // resolver so explicit part clears beat direction defaults and sidecars.
    false
}

const fn initial_configuration_revision() -> u64 {
    INITIAL_CONFIGURATION_REVISION
}

pub fn minimal_default_profile() -> Value {
    json!({
        "id": DEFAULT_PROFILE_ID,
        "name": "Default",
        "customization": minimal_default_customization(),
        "orientationPreference": "automatic",
        "outputMode": "keyboard",
        "updatedAt": 0
    })
}

/// Starter elements own their identities and explicit default outputs.
pub fn minimal_default_customization() -> Value {
    let labels = ["Up", "Down", "Left", "Right", "Action 1", "Action 2", "Action 3", "Action 4", "Menu", "Pause"];
    let keys = canonical_default_profile_key_bindings();
    let gamepad = ["dpadUp", "dpadDown", "dpadLeft", "dpadRight", "south", "east", "west", "north", "select", "start"];
    let elements = (1..=10).map(|number| {
        let id = KeypadElementID::preset(number);
        let output = OutputBinding { keyboard: keys.get(&id).cloned(), gamepad_buttons: std::collections::BTreeSet::from([gamepad[number as usize - 1].to_owned()]) }.element_value();
        let visual_role = match number { 1..=4 => "movement", 5..=6 => "primary_action", 7..=8 => "secondary_action", 9 => "utility", _ => "menu" };
        json!({"id": id, "label": labels[number as usize - 1], "kind": "button", "visualRole": visual_role, "layout": {}, "output": output, "defaultOutput": output, "partOutputs": []})
    }).collect::<Vec<_>>();
    json!({"elements": elements})
}

pub(crate) fn profile_id(profile: &Value) -> Option<&str> {
    profile.as_object()?.get("id")?.as_str()
}

pub(crate) fn ids_equal(left: &str, right: &str) -> bool {
    left.eq_ignore_ascii_case(right)
}

/// Explicit keyboard bindings for constructing the starter layout.
pub fn canonical_default_profile_key_bindings() -> ButtonBindings<KeyBinding> {
    let mut bindings = ButtonBindings::default();
    for (button, key_code, modifiers) in [
        (KeypadElementID::preset(3), 123, 0),
        (KeypadElementID::preset(4), 124, 0),
        (KeypadElementID::preset(1), 126, 0),
        (KeypadElementID::preset(2), 125, 0),
        (KeypadElementID::preset(5), 36, 0),
        (KeypadElementID::preset(6), 48, 0),
        (KeypadElementID::preset(7), 40, 1),
        (KeypadElementID::preset(8), 11, 8),
        (KeypadElementID::preset(9), 35, 3),
        (KeypadElementID::preset(10), 53, 0),
    ] {
        bindings.insert(button, KeyBinding::new(key_code, modifiers));
    }
    bindings
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateError {
    EmptyServerId,
    UnsupportedInputSlots,
    InvalidConfigurationRevision,
    InvalidConfiguration(crate::ConfigurationDocumentError),
    ConfigurationRevisionExhausted,
    UnsupportedSchemaVersion(u32),
}

impl fmt::Display for StateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedInputSlots => formatter.write_str("controls must declare unique element UUIDs; named input slots and routing fields are no longer supported; recreate the setup with element UUIDs"),
            Self::EmptyServerId => {
                formatter.write_str("the persistent server ID must not be empty")
            }
            Self::InvalidConfiguration(error) => write!(formatter, "invalid saved configuration: {error}"),
            Self::InvalidConfigurationRevision => {
                formatter.write_str("configuration revision must be at least one")
            }
            Self::ConfigurationRevisionExhausted => {
                formatter.write_str("configuration revision is exhausted")
            }
            Self::UnsupportedSchemaVersion(version) => {
                write!(
                    formatter,
                    "unsupported persistent-state schema version {version}"
                )
            }
        }
    }
}

impl Error for StateError {}
