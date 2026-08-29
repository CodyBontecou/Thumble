use crate::{ButtonBindings, KeyBinding, OutputBinding};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::error::Error;
use std::fmt;
use thumble_protocol::GameButton;

pub const CURRENT_SCHEMA_VERSION: u32 = 2;
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

        let key_bindings = canonical_default_profile_key_bindings();
        let mut output_bindings = ButtonBindings::default();
        for button in GameButton::ALL {
            if let Some(binding) = key_bindings.get(&button).cloned() {
                output_bindings.insert(button, OutputBinding::keyboard(binding));
            }
        }

        // Keep these maps independent: callers may replace only the global
        // output map while retaining the migration-compatible keyboard map.
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
            profiles: vec![minimal_default_profile()],
            active_profile_id: DEFAULT_PROFILE_ID.to_owned(),
            default_profile_id: DEFAULT_PROFILE_ID.to_owned(),
            key_bindings,
            output_bindings,
            profile_key_bindings,
            profile_output_bindings,
        })
    }

    pub fn normalize(&mut self) -> Result<(), StateError> {
        match self.schema_version {
            1 => {
                self.schema_version = CURRENT_SCHEMA_VERSION;
                self.configuration_revision = self.configuration_revision.max(1);
            }
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

        if self.recent_configuration_commits.len() > MAXIMUM_RECENT_CONFIGURATION_COMMITS {
            let remove =
                self.recent_configuration_commits.len() - MAXIMUM_RECENT_CONFIGURATION_COMMITS;
            self.recent_configuration_commits.drain(..remove);
        }

        let mut profile_ids = self
            .profiles
            .iter()
            .filter_map(profile_id)
            .map(str::to_owned)
            .collect::<Vec<_>>();
        if profile_ids.is_empty() {
            self.profiles.push(minimal_default_profile());
            profile_ids.push(DEFAULT_PROFILE_ID.to_owned());
        }

        if let Some(canonical) = profile_ids
            .iter()
            .find(|profile_id| ids_equal(profile_id, &self.active_profile_id))
        {
            self.active_profile_id.clone_from(canonical);
        } else {
            self.active_profile_id.clone_from(&profile_ids[0]);
        }
        if let Some(canonical) = profile_ids
            .iter()
            .find(|profile_id| ids_equal(profile_id, &self.default_profile_id))
        {
            self.default_profile_id.clone_from(canonical);
        } else {
            self.default_profile_id.clone_from(&self.active_profile_id);
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

/// Smallest useful customization that both the current Swift decoder and the
/// Rust resolver understand without relying on a migration pass. The fixed IDs
/// are the canonical built-in IDs from `KeypadElement.builtInID(for:)`.
pub fn minimal_default_customization() -> Value {
    let elements = [
        ("00000000-0000-0000-0000-000000000101", "Up", "up"),
        ("00000000-0000-0000-0000-000000000102", "Down", "down"),
        ("00000000-0000-0000-0000-000000000103", "Left", "left"),
        ("00000000-0000-0000-0000-000000000104", "Right", "right"),
        ("00000000-0000-0000-0000-000000000105", "Action 1", "jump"),
        ("00000000-0000-0000-0000-000000000106", "Action 2", "attack"),
        ("00000000-0000-0000-0000-000000000107", "Action 3", "dash"),
        ("00000000-0000-0000-0000-000000000108", "Action 4", "focus"),
        ("00000000-0000-0000-0000-000000000109", "Menu", "map"),
        ("00000000-0000-0000-0000-000000000110", "Pause", "pause"),
    ]
    .into_iter()
    .map(|(id, label, button)| {
        json!({
            "id": id,
            "label": label,
            "kind": "button",
            "layout": {},
            "builtInButton": button,
            "legacySlot": button,
            "partOutputs": []
        })
    })
    .collect::<Vec<_>>();
    json!({"elements": elements})
}

pub(crate) fn profile_id(profile: &Value) -> Option<&str> {
    profile.as_object()?.get("id")?.as_str()
}

pub(crate) fn ids_equal(left: &str, right: &str) -> bool {
    left.eq_ignore_ascii_case(right)
}

/// Canonical bindings installed for a newly imported profile that does not
/// supply its own per-profile key map.
pub fn canonical_default_profile_key_bindings() -> ButtonBindings<KeyBinding> {
    let mut bindings = ButtonBindings::default();
    for (button, key_code, modifiers) in [
        (GameButton::Left, 123, 0),
        (GameButton::Right, 124, 0),
        (GameButton::Up, 126, 0),
        (GameButton::Down, 125, 0),
        (GameButton::Jump, 36, 0),
        (GameButton::Attack, 48, 0),
        (GameButton::Dash, 40, 1),
        (GameButton::Focus, 11, 8),
        (GameButton::Map, 35, 3),
        (GameButton::Pause, 53, 0),
    ] {
        bindings.insert(button, KeyBinding::new(key_code, modifiers));
    }
    bindings
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StateError {
    EmptyServerId,
    InvalidConfigurationRevision,
    ConfigurationRevisionExhausted,
    UnsupportedSchemaVersion(u32),
}

impl fmt::Display for StateError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptyServerId => {
                formatter.write_str("the persistent server ID must not be empty")
            }
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
