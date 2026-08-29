use crate::authority::{
    prepare_configuration_commit, ConfigurationCommitError, ConfigurationCommitInput,
    PreparedConfigurationCommit,
};
use crate::bonjour::BonjourRegistration;
use crate::bridge::ConfigurationBridge;
use crate::cli_profile::{self, CliProfileRequest, CliProfileResponse, TransactionFailure};
use crate::control::{
    self, AccessibilityAction, ConfigurationDraftSummary, ConfigurationSaveSummary,
    ConfigurationStatusSummary, ConfigurationValidationSummary, ControlHandler, ControlRequest,
    ControlResponse, ControlSummary, HostStatus, ProfileSummary,
};
use crate::draft_operation::ConfigurationOperation;
use crate::drafts::{
    ConfigurationDraft, DraftEditResult, DraftError, DraftStore,
    CONFIGURATION_DRAFT_LIFETIME_MILLIS, MAXIMUM_LIVE_CONFIGURATION_DRAFTS,
};
use crate::output::OutputExecutor;
use crate::paths::HostPaths;
use crate::{platform, storage};
use fs2::FileExt;
use futures_util::{SinkExt, StreamExt};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use socket2::{Domain, Protocol, SockAddr, Socket, Type};
use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddrV4, SocketAddrV6};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use thumble_core::{
    ConnectionId, ControllerSnapshot, CoreTime, Effect, HostCore, KeyBinding, PersistentState,
    TokenSource,
};
use thumble_protocol::{
    ControllerMessage, ControllerMessageType, ControllerWireCodec, GameButton,
    KeypadElementInputPart,
};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch, Semaphore};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::{CloseFrame, WebSocketConfig};
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;

const HOLD_EXPIRY_AGE_MILLIS: i64 = 1_750;
const HOLD_EXPIRY_INTERVAL: Duration = Duration::from_millis(250);
const MAXIMUM_MESSAGE_SIZE: usize = 8 * 1024 * 1024;
const MAXIMUM_CONNECTIONS: usize = 32;
const OUTBOUND_QUEUE_CAPACITY: usize = 64;
const WEBSOCKET_HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const CONNECTION_IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const CONTROL_PRESS_LIMIT: usize = 10;
const CONTROL_PRESS_WINDOW: Duration = Duration::from_secs(1);
const MAXIMUM_CONTROL_SEQUENCE_STROKES: usize = 32;
const MAXIMUM_CONTROL_PROFILES: usize = 256;
const MAXIMUM_INSTALLED_CONTROLS: usize = 512;
const MAXIMUM_DISPLAY_CHARACTERS: usize = 256;
const MAXIMUM_CONTROLLER_SNAPSHOT_BYTES: usize = 48 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeOptions {
    pub port: u16,
    pub bonjour: bool,
    pub input: bool,
    pub configuration_write: bool,
}

impl Default for RuntimeOptions {
    fn default() -> Self {
        Self {
            port: 8765,
            bonjour: true,
            input: true,
            configuration_write: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeMetadata {
    pub pid: u32,
    pub version: String,
    pub requested_port: u16,
    pub actual_port: u16,
    pub bonjour_enabled: bool,
    pub input_enabled: bool,
    #[serde(default)]
    pub configuration_write_enabled: bool,
    pub service_name: String,
}

#[derive(Debug)]
enum Outbound {
    Binary(Vec<u8>),
    Close(String),
}

struct SecureTokens;

impl TokenSource for SecureTokens {
    fn next_pairing_code(&mut self) -> String {
        let code = rand::rng().random_range(0_u32..1_000_000);
        format!("{code:06}")
    }

    fn next_auth_token(&mut self) -> String {
        format!("{}{}", Uuid::new_v4().simple(), Uuid::new_v4().simple())
    }
}

struct RuntimeInner {
    core: HostCore,
    tokens: SecureTokens,
    connections: HashMap<ConnectionId, mpsc::Sender<Outbound>>,
    output: OutputExecutor,
    control_press_times: VecDeque<Instant>,
}

struct SharedRuntime {
    inner: Mutex<RuntimeInner>,
    paths: HostPaths,
    requested_port: u16,
    actual_port: u16,
    service_name: String,
    input_enabled: bool,
    configuration_write_enabled: bool,
    bonjour: Arc<BonjourRegistration>,
    shutdown: watch::Sender<bool>,
    started_at: Instant,
}

impl SharedRuntime {
    fn register_connection(&self, connection_id: ConnectionId, sender: mpsc::Sender<Outbound>) {
        self.inner
            .lock()
            .expect("runtime mutex poisoned")
            .connections
            .insert(connection_id, sender);
    }

    fn handle_message(
        &self,
        connection_id: ConnectionId,
        message: ControllerMessage,
    ) -> Result<(), String> {
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        let time = CoreTime::new(unix_millis(), self.monotonic_millis());
        let RuntimeInner { core, tokens, .. } = &mut *inner;
        let effects = core
            .handle_message_at(connection_id, message, time, tokens)
            .map_err(|error| format!("core rejected controller turn: {error}"))?;
        self.execute_effects(&mut inner, effects)
    }

    fn disconnect(&self, connection_id: ConnectionId) {
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        inner.connections.remove(&connection_id);
        let was_paired = inner.core.status().paired;
        let effects = inner.core.disconnect(connection_id);
        if let Err(error) = self.execute_effects(&mut inner, effects) {
            self.log(&format!("disconnect effects failed: {error}"));
        }
        if was_paired && !inner.core.status().paired {
            if let Err(error) = inner.output.release_tracked() {
                self.log(&format!(
                    "disconnect output release remains pending: {error}"
                ));
            }
        }
    }

    fn expire_holds(&self) {
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        let effects = inner
            .core
            .expire_holds(self.monotonic_millis(), HOLD_EXPIRY_AGE_MILLIS);
        if let Err(error) = self.execute_effects(&mut inner, effects) {
            self.log(&format!("hold expiry effects failed: {error}"));
        }
        if let Err(error) = inner.output.retry_pending_releases() {
            self.log(&format!("pending output release retry failed: {error}"));
        }
    }

    fn release_all(&self) -> Result<(), String> {
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        let effects = inner.core.release_all();
        self.execute_effects(&mut inner, effects)?;
        inner.output.release_tracked()
    }

    fn stop_core(&self) {
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        let effects = inner.core.set_running(false);
        if let Err(error) = self.execute_effects(&mut inner, effects) {
            self.log(&format!("shutdown effects failed: {error}"));
        }
        for sender in inner.connections.values() {
            let _ = sender.try_send(Outbound::Close("Host shutting down".to_owned()));
        }
        inner.connections.clear();
        if let Err(error) = inner.output.release_tracked() {
            self.log(&format!("shutdown output release failed: {error}"));
        }
    }

    fn rotate_pairing_code(&self) -> Result<String, String> {
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        let RuntimeInner { core, tokens, .. } = &mut *inner;
        core.rotate_pairing_code(tokens)
            .map_err(|error| format!("rotate pairing code: {error}"))?;
        Ok(core.pairing_code().to_owned())
    }

    fn pairing_code(&self) -> String {
        self.inner
            .lock()
            .expect("runtime mutex poisoned")
            .core
            .pairing_code()
            .to_owned()
    }

    fn profile_summaries(&self) -> (Vec<ProfileSummary>, String, u64) {
        let inner = self.inner.lock().expect("runtime mutex poisoned");
        let state = inner.core.persistent_state();
        let auth_tokens = state
            .trusted_clients
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let profiles = state
            .profiles
            .iter()
            .filter_map(|profile| {
                let id = profile.get("id")?.as_str()?;
                if id.is_empty() || id.len() > 512 {
                    return None;
                }
                let name = profile
                    .get("name")
                    .and_then(Value::as_str)
                    .unwrap_or("Unnamed profile");
                Some(ProfileSummary {
                    id: redacted(id, &auth_tokens),
                    name: bounded_redacted(name, &auth_tokens, MAXIMUM_DISPLAY_CHARACTERS),
                    active: id.eq_ignore_ascii_case(&state.active_profile_id),
                    default: id.eq_ignore_ascii_case(&state.default_profile_id),
                })
            })
            .take(MAXIMUM_CONTROL_PROFILES)
            .collect();
        (
            profiles,
            bounded_redacted(&state.active_profile_id, &auth_tokens, 512),
            state.configuration_revision,
        )
    }

    fn control_summaries(&self) -> (Vec<ControlSummary>, String, u64) {
        let inner = self.inner.lock().expect("runtime mutex poisoned");
        let state = inner.core.persistent_state();
        let auth_tokens = state
            .trusted_clients
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let controls = installed_controls(state)
            .into_iter()
            .take(MAXIMUM_INSTALLED_CONTROLS)
            .map(|installed| ControlSummary {
                control_id: redacted(&installed.summary.control_id, &auth_tokens),
                label: bounded_redacted(
                    &installed.summary.label,
                    &auth_tokens,
                    MAXIMUM_DISPLAY_CHARACTERS,
                ),
                kind: installed.summary.kind,
                part: installed.summary.part,
            })
            .collect();
        (
            controls,
            bounded_redacted(&state.active_profile_id, &auth_tokens, 512),
            state.configuration_revision,
        )
    }

    fn controller_snapshot(&self) -> Result<(ControllerSnapshot, u64), String> {
        let state = self
            .inner
            .lock()
            .expect("runtime mutex poisoned")
            .core
            .persistent_state()
            .clone();
        let configuration_revision = state.configuration_revision;
        Ok((bounded_controller_snapshot(&state)?, configuration_revision))
    }

    fn select_profile(&self, profile_id: &str) -> Result<(String, bool, u64), String> {
        if profile_id.is_empty() || profile_id.len() > 512 {
            return Err("profile ID must contain between 1 and 512 bytes".to_owned());
        }
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        let previous = inner.core.persistent_state().active_profile_id.clone();
        let previous_revision = inner.core.persistent_state().configuration_revision;
        let effects = inner
            .core
            .select_profile_locally(profile_id)
            .map_err(|error| error.to_string())?;
        if let Err(error) = self.execute_effects(&mut inner, effects) {
            inner
                .core
                .restore_profile_after_failed_local_selection(&previous, previous_revision)
                .map_err(|rollback| {
                    format!("{error}; failed to roll back profile selection: {rollback}")
                })?;
            return Err(error);
        }
        let state = inner.core.persistent_state();
        let selected = state.active_profile_id.clone();
        let auth_tokens = state
            .trusted_clients
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        Ok((
            redacted(&selected, &auth_tokens),
            !selected.eq_ignore_ascii_case(&previous),
            state.configuration_revision,
        ))
    }

    fn press_control(&self, control_id: &str) -> Result<String, String> {
        if !self.input_enabled {
            return Err("host input is disabled".to_owned());
        }
        if !platform::accessibility_trusted() {
            return Err("macOS Accessibility permission is required".to_owned());
        }
        if control_id.is_empty() || control_id.len() > 512 {
            return Err("control ID must contain between 1 and 512 bytes".to_owned());
        }

        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        let installed = installed_controls(inner.core.persistent_state())
            .into_iter()
            .find(|installed| installed.summary.control_id == control_id)
            .ok_or_else(|| "control is not installed in the active profile".to_owned())?;
        if installed.binding.strokes().len() > MAXIMUM_CONTROL_SEQUENCE_STROKES {
            return Err("control sequence exceeds the 32-stroke safety limit".to_owned());
        }

        allow_control_press(&mut inner.control_press_times, Instant::now())?;

        inner
            .output
            .execute(&Effect::TapSequence(installed.binding.strokes()))?;
        let auth_tokens = inner
            .core
            .persistent_state()
            .trusted_clients
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        Ok(redacted(&installed.summary.control_id, &auth_tokens))
    }

    fn status(&self) -> HostStatus {
        let inner = self.inner.lock().expect("runtime mutex poisoned");
        let auth_tokens = inner
            .core
            .persistent_state()
            .trusted_clients
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        let mut bonjour = self.bonjour.info();
        bonjour.service_name = redacted(&bonjour.service_name, &auth_tokens);
        bonjour.error = bonjour
            .error
            .as_deref()
            .map(|error| redacted(error, &auth_tokens));
        HostStatus {
            pid: std::process::id(),
            version: env!("CARGO_PKG_VERSION").to_owned(),
            port: self.actual_port,
            requested_port: self.requested_port,
            bonjour,
            service_name: redacted(&self.service_name, &auth_tokens),
            urls: websocket_urls(self.actual_port),
            accessibility_trusted: platform::accessibility_trusted(),
            input_enabled: self.input_enabled,
            configuration_write_enabled: self.configuration_write_enabled,
            state_path: redacted(&self.paths.state_file.to_string_lossy(), &auth_tokens),
            control_socket: redacted(&self.paths.control_socket.to_string_lossy(), &auth_tokens),
            server_id: redacted(&inner.core.persistent_state().server_id, &auth_tokens),
            pairing_code: inner.core.pairing_code().to_owned(),
            core: inner.core.status(),
            output: inner.output.snapshot(),
        }
    }

    fn execute_effects(
        &self,
        inner: &mut RuntimeInner,
        effects: Vec<Effect>,
    ) -> Result<(), String> {
        for effect in effects {
            match &effect {
                Effect::SendMessage {
                    connection_id,
                    message,
                } => {
                    let encoded = ControllerWireCodec::encode(message)
                        .map_err(|error| format!("encode controller response: {error}"))?;
                    if let Some(sender) = inner.connections.get(connection_id) {
                        if sender.try_send(Outbound::Binary(encoded)).is_err() {
                            inner.connections.remove(connection_id);
                        }
                    }
                }
                Effect::CloseConnection {
                    connection_id,
                    reason,
                } => {
                    if let Some(sender) = inner.connections.get(connection_id) {
                        if sender.try_send(Outbound::Close(reason.clone())).is_err() {
                            inner.connections.remove(connection_id);
                        }
                    }
                }
                Effect::Diagnostic {
                    connection_id,
                    message,
                } => self.log(&format!(
                    "controller diagnostic connection={connection_id}: {message}"
                )),
                Effect::PersistState => {
                    storage::save_atomic(&self.paths.state_file, inner.core.persistent_state())?;
                }
                Effect::KeyDown(_)
                | Effect::KeyUp(_)
                | Effect::PulseKey(_)
                | Effect::TapSequence(_)
                | Effect::PointerMove { .. }
                | Effect::PointerScroll { .. }
                | Effect::PointerButton { .. } => {
                    if let Err(error) = inner.output.execute(&effect) {
                        self.log(&format!(
                            "output effect remains pending or was skipped: {error}"
                        ));
                    }
                }
                Effect::StatusChanged(_) => {}
            }
        }
        Ok(())
    }

    fn monotonic_millis(&self) -> i64 {
        i64::try_from(self.started_at.elapsed().as_millis()).unwrap_or(i64::MAX)
    }

    fn log(&self, line: &str) {
        let line = storage::redact_known_auth_tokens(&self.paths.state_file, line);
        append_log(&self.paths.log_file, &line);
    }
}

fn allow_control_press(press_times: &mut VecDeque<Instant>, now: Instant) -> Result<(), String> {
    while press_times
        .front()
        .is_some_and(|pressed| now.duration_since(*pressed) >= CONTROL_PRESS_WINDOW)
    {
        press_times.pop_front();
    }
    if press_times.len() >= CONTROL_PRESS_LIMIT {
        return Err("control press rate limit exceeded; retry shortly".to_owned());
    }
    press_times.push_back(now);
    Ok(())
}

struct InstalledControl {
    summary: ControlSummary,
    binding: KeyBinding,
}

fn installed_controls(state: &thumble_core::PersistentState) -> Vec<InstalledControl> {
    let mut controls = BTreeMap::<String, InstalledControl>::new();

    for button in GameButton::ALL {
        let Some(binding) = state
            .resolve_button_output(button)
            .and_then(|output| output.keyboard)
        else {
            continue;
        };
        if binding.strokes().len() > MAXIMUM_CONTROL_SEQUENCE_STROKES {
            continue;
        }
        let name = game_button_name(button);
        let control_id = format!("button:{name}");
        controls.insert(
            control_id.clone(),
            InstalledControl {
                summary: ControlSummary {
                    control_id,
                    label: game_button_label(button),
                    kind: "button".to_owned(),
                    part: KeypadElementInputPart::Primary,
                },
                binding,
            },
        );
    }

    let Some(profile) = state.active_profile() else {
        return controls.into_values().collect();
    };
    for customization_name in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let Some(elements) = profile
            .get(customization_name)
            .and_then(|customization| customization.get("elements"))
            .and_then(Value::as_array)
        else {
            continue;
        };
        for element in elements {
            let Some(element_id) = element.get("id").and_then(Value::as_str) else {
                continue;
            };
            if element_id.is_empty() || element_id.len() > 256 {
                continue;
            }
            let Some(kind) = element.get("kind").and_then(Value::as_str) else {
                continue;
            };
            let parts: &[KeypadElementInputPart] = match kind {
                "button" => &[KeypadElementInputPart::Primary],
                "joystick" => &[
                    KeypadElementInputPart::JoystickUp,
                    KeypadElementInputPart::JoystickDown,
                    KeypadElementInputPart::JoystickLeft,
                    KeypadElementInputPart::JoystickRight,
                ],
                "trigger" => &[KeypadElementInputPart::TriggerDigital],
                _ => continue,
            };
            let label = element
                .get("label")
                .and_then(Value::as_str)
                .filter(|label| !label.is_empty())
                .unwrap_or("Unnamed control");
            for part in parts {
                let Some(binding) = state
                    .resolve_element_output(element_id, *part)
                    .and_then(|output| output.keyboard)
                else {
                    continue;
                };
                if binding.strokes().len() > MAXIMUM_CONTROL_SEQUENCE_STROKES {
                    continue;
                }
                let suffix = match part {
                    KeypadElementInputPart::Primary => String::new(),
                    _ => format!("#{}", element_part_name(*part)),
                };
                let control_id = format!("element:{element_id}{suffix}");
                controls
                    .entry(control_id.to_ascii_lowercase())
                    .or_insert_with(|| InstalledControl {
                        summary: ControlSummary {
                            control_id,
                            label: label.to_owned(),
                            kind: kind.to_owned(),
                            part: *part,
                        },
                        binding,
                    });
            }
        }
    }

    let mut controls = controls.into_values().collect::<Vec<_>>();
    controls.sort_by(|left, right| {
        left.summary
            .control_id
            .to_ascii_lowercase()
            .cmp(&right.summary.control_id.to_ascii_lowercase())
    });
    controls
}

const fn game_button_name(button: GameButton) -> &'static str {
    match button {
        GameButton::Up => "up",
        GameButton::Down => "down",
        GameButton::Left => "left",
        GameButton::Right => "right",
        GameButton::Jump => "jump",
        GameButton::Attack => "attack",
        GameButton::Dash => "dash",
        GameButton::Focus => "focus",
        GameButton::Map => "map",
        GameButton::Pause => "pause",
        GameButton::Custom1 => "custom1",
        GameButton::Custom2 => "custom2",
        GameButton::Custom3 => "custom3",
        GameButton::Custom4 => "custom4",
        GameButton::Custom5 => "custom5",
        GameButton::Custom6 => "custom6",
        GameButton::Custom7 => "custom7",
        GameButton::Custom8 => "custom8",
    }
}

fn game_button_label(button: GameButton) -> String {
    match button {
        GameButton::Custom1 => "Custom 1".to_owned(),
        GameButton::Custom2 => "Custom 2".to_owned(),
        GameButton::Custom3 => "Custom 3".to_owned(),
        GameButton::Custom4 => "Custom 4".to_owned(),
        GameButton::Custom5 => "Custom 5".to_owned(),
        GameButton::Custom6 => "Custom 6".to_owned(),
        GameButton::Custom7 => "Custom 7".to_owned(),
        GameButton::Custom8 => "Custom 8".to_owned(),
        _ => {
            let name = game_button_name(button);
            let mut chars = name.chars();
            match chars.next() {
                Some(first) => first.to_uppercase().chain(chars).collect(),
                None => String::new(),
            }
        }
    }
}

const fn element_part_name(part: KeypadElementInputPart) -> &'static str {
    match part {
        KeypadElementInputPart::Primary => "primary",
        KeypadElementInputPart::JoystickUp => "joystick_up",
        KeypadElementInputPart::JoystickDown => "joystick_down",
        KeypadElementInputPart::JoystickLeft => "joystick_left",
        KeypadElementInputPart::JoystickRight => "joystick_right",
        KeypadElementInputPart::TriggerDigital => "trigger_digital",
    }
}

impl SharedRuntime {
    fn cli_profile_transaction(&self, request: &CliProfileRequest) -> CliProfileResponse {
        let state = self
            .inner
            .lock()
            .expect("runtime mutex poisoned")
            .core
            .persistent_state()
            .clone();
        cli_profile::execute_profile_transaction(
            &self.paths,
            &state,
            request,
            "online",
            |draft_id, draft_revision, base_revision, commit_id, request_digest| {
                self.save_configuration_draft(
                    draft_id,
                    draft_revision,
                    base_revision,
                    commit_id,
                    Some(request_digest),
                )
                .map_err(save_transaction_failure)
            },
        )
    }

    fn configuration_status(&self) -> ConfigurationStatusSummary {
        let bridge_available = self.configuration_bridge_available();
        let inner = self.inner.lock().expect("runtime mutex poisoned");
        let state = inner.core.persistent_state();
        let auth_tokens = state
            .trusted_clients
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        ConfigurationStatusSummary {
            configuration_revision: state.configuration_revision,
            profile_count: state.profiles.len(),
            active_profile_id: bounded_redacted(
                &state.active_profile_id,
                &auth_tokens,
                MAXIMUM_DISPLAY_CHARACTERS,
            ),
            default_profile_id: bounded_redacted(
                &state.default_profile_id,
                &auth_tokens,
                MAXIMUM_DISPLAY_CHARACTERS,
            ),
            maximum_live_drafts: MAXIMUM_LIVE_CONFIGURATION_DRAFTS,
            draft_lifetime_millis: CONFIGURATION_DRAFT_LIFETIME_MILLIS,
            operation_schema_version: 1,
            bridge_available,
            configuration_write_enabled: self.configuration_write_enabled,
        }
    }

    fn begin_configuration_draft(
        &self,
        expected_configuration_revision: u64,
    ) -> Result<ConfigurationDraftSummary, DraftError> {
        let state = self
            .inner
            .lock()
            .expect("runtime mutex poisoned")
            .core
            .persistent_state()
            .clone();
        let draft = DraftStore::new(&self.paths).begin(
            &state,
            expected_configuration_revision,
            unix_millis(),
        )?;
        Ok(self.configuration_draft_summary(&draft))
    }

    fn get_configuration_draft(
        &self,
        draft_id: &str,
    ) -> Result<ConfigurationDraftSummary, DraftError> {
        let draft = DraftStore::new(&self.paths).get(draft_id, unix_millis())?;
        Ok(self.configuration_draft_summary(&draft))
    }

    fn edit_configuration_draft(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
        operation_id: &str,
        operation: &ConfigurationOperation,
    ) -> Result<
        (
            ConfigurationDraftSummary,
            crate::draft_operation::ConfigurationOperationOutcome,
            bool,
        ),
        DraftError,
    > {
        let now_millis = unix_millis();
        let store = DraftStore::new(&self.paths);
        let edit = if operation.requires_bridge() {
            let bridge = ConfigurationBridge::discover().map_err(DraftError::Bridge)?;
            store.edit_with(
                draft_id,
                expected_draft_revision,
                operation_id,
                operation,
                now_millis,
                |document| {
                    bridge
                        .apply(document, operation, now_millis)
                        .map_err(DraftError::Bridge)
                },
            )
        } else {
            store.edit(
                draft_id,
                expected_draft_revision,
                operation_id,
                operation,
                now_millis,
            )
        }?;
        let DraftEditResult {
            draft,
            operation,
            idempotent_replay,
        } = edit;
        Ok((
            self.configuration_draft_summary(&draft),
            operation,
            idempotent_replay,
        ))
    }

    fn rebase_configuration_draft(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
        expected_configuration_revision: u64,
        rebase_id: &str,
    ) -> Result<
        (
            ConfigurationDraftSummary,
            crate::draft_operation::ConfigurationOperationOutcome,
            bool,
        ),
        DraftError,
    > {
        let state = self
            .inner
            .lock()
            .expect("runtime mutex poisoned")
            .core
            .persistent_state()
            .clone();
        if state.configuration_revision != expected_configuration_revision {
            return Err(DraftError::ConfigurationRevisionConflict {
                expected: expected_configuration_revision,
                actual: state.configuration_revision,
            });
        }
        let current_document = thumble_core::ConfigurationDocument::from_state(&state)
            .map_err(DraftError::Document)?;
        let DraftEditResult {
            draft,
            operation,
            idempotent_replay,
        } = DraftStore::new(&self.paths).rebase(
            draft_id,
            expected_draft_revision,
            rebase_id,
            expected_configuration_revision,
            &current_document,
            unix_millis(),
        )?;
        Ok((
            self.configuration_draft_summary(&draft),
            operation,
            idempotent_replay,
        ))
    }

    fn validate_configuration_draft(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
    ) -> Result<ConfigurationValidationSummary, DraftError> {
        let draft = DraftStore::new(&self.paths).get_at_revision(
            draft_id,
            expected_draft_revision,
            unix_millis(),
        )?;
        draft
            .working_document
            .validate()
            .map_err(DraftError::Document)?;
        Ok(ConfigurationValidationSummary {
            draft_id: draft.draft_id,
            draft_revision: draft.draft_revision,
            valid: true,
            error_count: 0,
            warning_count: u32::from(!self.configuration_bridge_available()),
            validator: if self.configuration_bridge_available() {
                "rust-structural-v1+swift-bridge-v1"
            } else {
                "rust-structural-v1"
            }
            .to_owned(),
        })
    }

    fn preview_configuration_draft(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
    ) -> Result<(ConfigurationDraftSummary, ControllerSnapshot, String), DraftError> {
        let draft = DraftStore::new(&self.paths).get_at_revision(
            draft_id,
            expected_draft_revision,
            unix_millis(),
        )?;
        let mut candidate = self
            .inner
            .lock()
            .expect("runtime mutex poisoned")
            .core
            .persistent_state()
            .clone();
        draft
            .working_document
            .install_into(&mut candidate)
            .map_err(DraftError::Document)?;
        let snapshot = bounded_controller_snapshot(&candidate)
            .map_err(|error| DraftError::Preview(error.to_owned()))?;
        let orientation_variant = format!("{}Customization", snapshot.orientation.as_str());
        let editable_variant = draft
            .working_document
            .profiles
            .iter()
            .find(|profile| {
                profile.get("id").and_then(Value::as_str).is_some_and(|id| {
                    id.eq_ignore_ascii_case(&draft.working_document.active_profile_id)
                })
            })
            .and_then(|profile| profile.get(&orientation_variant))
            .filter(|customization| customization.is_object())
            .map_or_else(
                || "primary".to_owned(),
                |_| snapshot.orientation.as_str().to_owned(),
            );
        Ok((
            self.configuration_draft_summary(&draft),
            snapshot,
            editable_variant,
        ))
    }

    fn save_configuration_draft(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
        expected_configuration_revision: u64,
        commit_id: &str,
        client_request_digest: Option<&str>,
    ) -> Result<ConfigurationSaveSummary, SaveConfigurationError> {
        if !self.configuration_write_enabled {
            return Err(SaveConfigurationError::Disabled);
        }
        let now_millis = unix_millis();
        let store = DraftStore::new(&self.paths);
        let mut inner = self.inner.lock().expect("runtime mutex poisoned");
        let PreparedConfigurationCommit {
            candidate,
            mut summary,
        } = prepare_configuration_commit(
            inner.core.persistent_state(),
            &store,
            ConfigurationCommitInput {
                draft_id,
                expected_draft_revision,
                expected_configuration_revision,
                commit_id,
                client_request_digest,
                now_millis,
            },
        )
        .map_err(SaveConfigurationError::Commit)?;
        let Some(candidate) = candidate else {
            return Ok(summary);
        };

        if summary.changed {
            let release_effects = inner.core.release_all();
            self.execute_effects(&mut inner, release_effects)
                .map_err(SaveConfigurationError::ReleaseFailed)?;
        }
        storage::save_atomic(&self.paths.state_file, &candidate)
            .map_err(SaveConfigurationError::PersistenceFailed)?;
        let install_effects = inner.core.install_validated_persisted_state(candidate);
        summary.phone_sync_queued = install_effects
            .iter()
            .any(|effect| matches!(effect, Effect::SendMessage { .. }));
        if let Err(error) = self.execute_effects(&mut inner, install_effects) {
            self.log(&format!(
                "configuration committed but phone delivery was deferred: {error}"
            ));
        }
        drop(inner);
        if let Err(error) = store.discard(draft_id, expected_draft_revision, now_millis) {
            self.log(&format!(
                "configuration committed but draft cleanup was deferred: {error}"
            ));
        }
        Ok(summary)
    }

    fn configuration_bridge_available(&self) -> bool {
        ConfigurationBridge::is_available()
    }

    fn discard_configuration_draft(
        &self,
        draft_id: &str,
        expected_draft_revision: u64,
    ) -> Result<String, DraftError> {
        DraftStore::new(&self.paths).discard(draft_id, expected_draft_revision, unix_millis())?;
        Uuid::parse_str(draft_id)
            .map(|id| id.hyphenated().to_string())
            .map_err(|_| DraftError::InvalidDraftId)
    }

    fn configuration_draft_summary(&self, draft: &ConfigurationDraft) -> ConfigurationDraftSummary {
        let inner = self.inner.lock().expect("runtime mutex poisoned");
        let auth_tokens = inner
            .core
            .persistent_state()
            .trusted_clients
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        ConfigurationDraftSummary {
            draft_id: draft.draft_id.clone(),
            base_configuration_revision: draft.base_configuration_revision,
            draft_revision: draft.draft_revision,
            profile_count: draft.working_document.profiles.len(),
            active_profile_id: bounded_redacted(
                &draft.working_document.active_profile_id,
                &auth_tokens,
                MAXIMUM_DISPLAY_CHARACTERS,
            ),
            default_profile_id: bounded_redacted(
                &draft.working_document.default_profile_id,
                &auth_tokens,
                MAXIMUM_DISPLAY_CHARACTERS,
            ),
            operation_count: draft.operation_log.len(),
            created_at: draft.created_at,
            updated_at: draft.updated_at,
            expires_at: draft.expires_at,
        }
    }
}

fn draft_error_response(error: DraftError) -> ControlResponse {
    match error {
        DraftError::ConfigurationRevisionConflict { expected, actual } => {
            ControlResponse::revision_conflict(
                "configuration_revision_conflict",
                "configuration changed; begin a draft from the current revision",
                expected,
                actual,
            )
        }
        DraftError::DraftRevisionConflict { expected, actual } => {
            ControlResponse::revision_conflict(
                "draft_revision_conflict",
                "configuration draft changed; refresh it before continuing",
                expected,
                actual,
            )
        }
        DraftError::InvalidDraftId => {
            ControlResponse::coded_error("invalid_draft_id", error.to_string())
        }
        DraftError::InvalidOperationId => {
            ControlResponse::coded_error("invalid_operation_id", error.to_string())
        }
        DraftError::OperationIdConflict => {
            ControlResponse::coded_error("operation_id_conflict", error.to_string())
        }
        DraftError::DraftIdConflict => {
            ControlResponse::coded_error("draft_id_conflict", error.to_string())
        }
        DraftError::DraftRevisionExhausted => {
            ControlResponse::coded_error("draft_revision_exhausted", error.to_string())
        }
        DraftError::NotFound => ControlResponse::coded_error("draft_not_found", error.to_string()),
        DraftError::Expired => ControlResponse::coded_error("draft_expired", error.to_string()),
        DraftError::TooManyLiveDrafts => {
            ControlResponse::coded_error("draft_limit_reached", error.to_string())
        }
        DraftError::TooManyOperations => {
            ControlResponse::coded_error("draft_operation_limit_reached", error.to_string())
        }
        DraftError::Document(_)
        | DraftError::Operation(_)
        | DraftError::InvalidOperationOutcome => {
            ControlResponse::coded_error("invalid_configuration_operation", error.to_string())
        }
        DraftError::Bridge(_) => {
            ControlResponse::coded_error("configuration_bridge_failed", error.to_string())
        }
        DraftError::Preview(_) => {
            ControlResponse::coded_error("draft_preview_failed", error.to_string())
        }
        DraftError::MergeConflict(paths) => {
            let mut response = ControlResponse::coded_error(
                "configuration_merge_conflict",
                "draft and authoritative configuration changed the same semantic paths",
            );
            response.conflict_paths = Some(paths);
            response
        }
        DraftError::InsecureDirectory | DraftError::InsecureFile => {
            ControlResponse::coded_error("insecure_draft_storage", error.to_string())
        }
        DraftError::UnsupportedVersion => {
            ControlResponse::coded_error("unsupported_draft_version", error.to_string())
        }
        DraftError::TooLarge(_) => {
            ControlResponse::coded_error("draft_too_large", error.to_string())
        }
        DraftError::Malformed | DraftError::EncodingFailed | DraftError::Io(_) => {
            ControlResponse::coded_error("draft_storage_failed", error.to_string())
        }
    }
}

#[derive(Debug)]
enum SaveConfigurationError {
    Disabled,
    Commit(ConfigurationCommitError),
    ReleaseFailed(String),
    PersistenceFailed(String),
}

fn save_transaction_failure(error: SaveConfigurationError) -> TransactionFailure {
    match error {
        SaveConfigurationError::Disabled => TransactionFailure::new(
            "configuration_write_disabled",
            "live host configuration writes are disabled; restart it with explicit configuration-write approval",
        ),
        SaveConfigurationError::Commit(error) => cli_profile::commit_failure(error),
        SaveConfigurationError::ReleaseFailed(_) => TransactionFailure::new(
            "input_release_failed",
            "held input could not be released before configuration persistence",
        ),
        SaveConfigurationError::PersistenceFailed(_) => TransactionFailure::new(
            "configuration_persistence_failed",
            "authoritative configuration could not be persisted atomically",
        ),
    }
}

fn save_error_response(error: SaveConfigurationError) -> ControlResponse {
    match error {
        SaveConfigurationError::Disabled => ControlResponse::coded_error(
            "configuration_write_disabled",
            "host configuration writes are disabled; restart thumble-host with --allow-config-write after explicit approval",
        ),
        SaveConfigurationError::Commit(ConfigurationCommitError::InvalidCommitIdentity) => {
            ControlResponse::coded_error(
                "invalid_commit_identity",
                "draft ID and commit ID must be exact UUIDs",
            )
        }
        SaveConfigurationError::Commit(ConfigurationCommitError::InvalidRequestDigest) => {
            ControlResponse::coded_error(
                "invalid_request_digest",
                "configuration request digest is invalid",
            )
        }
        SaveConfigurationError::Commit(ConfigurationCommitError::CommitIdConflict) => {
            ControlResponse::coded_error(
                "commit_id_conflict",
                "commit ID was already used for different draft content",
            )
        }
        SaveConfigurationError::Commit(
            ConfigurationCommitError::ConfigurationRevisionConflict { expected, actual },
        ) => ControlResponse::revision_conflict(
            "configuration_revision_conflict",
            "authoritative configuration changed; explicitly rebase or begin a new draft",
            expected,
            actual,
        ),
        SaveConfigurationError::Commit(ConfigurationCommitError::Draft(error)) => {
            draft_error_response(error)
        }
        SaveConfigurationError::Commit(ConfigurationCommitError::InvalidConfiguration(error)) => {
            ControlResponse::coded_error("invalid_configuration", error)
        }
        SaveConfigurationError::ReleaseFailed(error) => {
            ControlResponse::coded_error("input_release_failed", error)
        }
        SaveConfigurationError::PersistenceFailed(error) => {
            ControlResponse::coded_error("configuration_persistence_failed", error)
        }
    }
}

impl ControlHandler for SharedRuntime {
    fn handle(&self, request: ControlRequest) -> ControlResponse {
        match request {
            ControlRequest::Status => {
                let mut response = ControlResponse::success();
                response.status = Some(self.status());
                response
            }
            ControlRequest::PairingCode { rotate } => {
                let result = if rotate {
                    self.rotate_pairing_code()
                } else {
                    Ok(self.pairing_code())
                };
                match result {
                    Ok(code) => {
                        let mut response = ControlResponse::success();
                        response.pairing_code = Some(code);
                        response.rotated = Some(rotate);
                        response
                    }
                    Err(error) => ControlResponse::error(error),
                }
            }
            ControlRequest::Accessibility { action } => match action {
                AccessibilityAction::Status => {
                    accessibility_response(platform::accessibility_trusted())
                }
                AccessibilityAction::Prompt => {
                    accessibility_response(platform::prompt_accessibility())
                }
                AccessibilityAction::Open => match platform::open_accessibility_settings() {
                    Ok(()) => accessibility_response(platform::accessibility_trusted()),
                    Err(error) => ControlResponse::error(error),
                },
            },
            ControlRequest::ListProfiles => {
                let (profiles, active_profile_id, configuration_revision) =
                    self.profile_summaries();
                let mut response = ControlResponse::success();
                response.profiles = Some(profiles);
                response.active_profile_id = Some(active_profile_id);
                response.configuration_revision = Some(configuration_revision);
                response
            }
            ControlRequest::ListControls => {
                let (controls, active_profile_id, configuration_revision) =
                    self.control_summaries();
                let mut response = ControlResponse::success();
                response.controls = Some(controls);
                response.active_profile_id = Some(active_profile_id);
                response.configuration_revision = Some(configuration_revision);
                response
            }
            ControlRequest::CliProfileTransaction { request } => {
                let mut response = ControlResponse::success();
                response.cli_profile = Some(self.cli_profile_transaction(&request));
                response
            }
            ControlRequest::ConfigurationStatus => {
                let mut response = ControlResponse::success();
                response.configuration = Some(self.configuration_status());
                response
            }
            ControlRequest::BeginConfigurationDraft {
                expected_configuration_revision,
            } => match self.begin_configuration_draft(expected_configuration_revision) {
                Ok(draft) => {
                    let mut response = ControlResponse::success();
                    response.draft = Some(draft);
                    response
                }
                Err(error) => draft_error_response(error),
            },
            ControlRequest::GetConfigurationDraft { draft_id } => {
                match self.get_configuration_draft(&draft_id) {
                    Ok(draft) => {
                        let mut response = ControlResponse::success();
                        response.draft = Some(draft);
                        response
                    }
                    Err(error) => draft_error_response(error),
                }
            }
            ControlRequest::EditConfigurationDraft {
                draft_id,
                expected_draft_revision,
                operation_id,
                operation,
            } => match self.edit_configuration_draft(
                &draft_id,
                expected_draft_revision,
                &operation_id,
                &operation,
            ) {
                Ok((draft, outcome, idempotent_replay)) => {
                    let mut response = ControlResponse::success();
                    response.draft = Some(draft);
                    response.draft_operation = Some(outcome);
                    response.idempotent_replay = Some(idempotent_replay);
                    response
                }
                Err(error) => draft_error_response(error),
            },
            ControlRequest::RebaseConfigurationDraft {
                draft_id,
                expected_draft_revision,
                expected_configuration_revision,
                rebase_id,
            } => match self.rebase_configuration_draft(
                &draft_id,
                expected_draft_revision,
                expected_configuration_revision,
                &rebase_id,
            ) {
                Ok((draft, outcome, idempotent_replay)) => {
                    let mut response = ControlResponse::success();
                    response.draft = Some(draft);
                    response.draft_operation = Some(outcome);
                    response.idempotent_replay = Some(idempotent_replay);
                    response
                }
                Err(error) => draft_error_response(error),
            },
            ControlRequest::ValidateConfigurationDraft {
                draft_id,
                expected_draft_revision,
            } => match self.validate_configuration_draft(&draft_id, expected_draft_revision) {
                Ok(validation) => {
                    let mut response = ControlResponse::success();
                    response.validation = Some(validation);
                    response
                }
                Err(error) => draft_error_response(error),
            },
            ControlRequest::PreviewConfigurationDraft {
                draft_id,
                expected_draft_revision,
            } => match self.preview_configuration_draft(&draft_id, expected_draft_revision) {
                Ok((draft, controller, editable_variant)) => {
                    let mut response = ControlResponse::success();
                    response.draft = Some(draft);
                    response.controller = Some(controller);
                    response.editable_variant = Some(editable_variant);
                    response
                }
                Err(error) => draft_error_response(error),
            },
            ControlRequest::SaveConfigurationDraft {
                draft_id,
                expected_draft_revision,
                expected_configuration_revision,
                commit_id,
            } => match self.save_configuration_draft(
                &draft_id,
                expected_draft_revision,
                expected_configuration_revision,
                &commit_id,
                None,
            ) {
                Ok(save) => {
                    let mut response = ControlResponse::success();
                    response.configuration_revision = Some(save.configuration_revision);
                    response.save = Some(save);
                    response
                }
                Err(error) => save_error_response(error),
            },
            ControlRequest::DiscardConfigurationDraft {
                draft_id,
                expected_draft_revision,
            } => match self.discard_configuration_draft(&draft_id, expected_draft_revision) {
                Ok(discarded_draft_id) => {
                    let mut response = ControlResponse::success();
                    response.discarded_draft_id = Some(discarded_draft_id);
                    response
                }
                Err(error) => draft_error_response(error),
            },
            ControlRequest::RenderController => match self.controller_snapshot() {
                Ok((controller, configuration_revision)) => {
                    let mut response = ControlResponse::success();
                    response.controller = Some(controller);
                    response.configuration_revision = Some(configuration_revision);
                    response
                }
                Err(error) => ControlResponse::error(error),
            },
            ControlRequest::SelectProfile { profile_id } => {
                match self.select_profile(&profile_id) {
                    Ok((selected, changed, configuration_revision)) => {
                        let mut response = ControlResponse::success();
                        response.selected_profile_id = Some(selected);
                        response.profile_changed = Some(changed);
                        response.configuration_revision = Some(configuration_revision);
                        response
                    }
                    Err(error) => ControlResponse::error(error),
                }
            }
            ControlRequest::PressControl { control_id } => match self.press_control(&control_id) {
                Ok(pressed) => {
                    let mut response = ControlResponse::success();
                    response.pressed_control_id = Some(pressed);
                    response
                }
                Err(error) => ControlResponse::error(error),
            },
            ControlRequest::ReleaseAll => match self.release_all() {
                Ok(()) => {
                    let mut response = ControlResponse::success();
                    response.released = Some(true);
                    response
                }
                Err(error) => ControlResponse::error(error),
            },
            ControlRequest::Stop => {
                let mut response = ControlResponse::success();
                response.stopping = Some(true);
                let _ = self.shutdown.send(true);
                response
            }
        }
    }
}

pub async fn run_runtime(paths: HostPaths, options: RuntimeOptions) -> Result<(), String> {
    let instance = InstanceGuard::acquire(&paths)?;
    let state = storage::load_or_migrate(&paths)?;
    let listener = bind_listener(options.port)?;
    let actual_port = listener
        .local_addr()
        .map_err(|error| format!("read listener address: {error}"))?
        .port();
    let control_listener = control::bind_control_socket(&paths.control_socket).await?;
    let service_name = default_service_name();
    let bonjour = if options.bonjour {
        BonjourRegistration::register(service_name.clone(), state.server_id.clone(), actual_port)?
    } else {
        BonjourRegistration::disabled(service_name.clone())
    };
    let mut tokens = SecureTokens;
    let core = HostCore::new_with_tokens(state, &mut tokens)
        .map_err(|error| format!("initialize host core: {error}"))?;
    let (shutdown_tx, shutdown_rx) = watch::channel(false);
    let shared = Arc::new(SharedRuntime {
        inner: Mutex::new(RuntimeInner {
            core,
            tokens,
            connections: HashMap::new(),
            output: OutputExecutor::new(options.input, Some(paths.output_recording_file.clone())),
            control_press_times: VecDeque::new(),
        }),
        paths: paths.clone(),
        requested_port: options.port,
        actual_port,
        service_name: service_name.clone(),
        input_enabled: options.input,
        configuration_write_enabled: options.configuration_write,
        bonjour: Arc::new(bonjour),
        shutdown: shutdown_tx.clone(),
        started_at: Instant::now(),
    });

    let metadata = RuntimeMetadata {
        pid: std::process::id(),
        version: env!("CARGO_PKG_VERSION").to_owned(),
        requested_port: options.port,
        actual_port,
        bonjour_enabled: options.bonjour,
        input_enabled: options.input,
        configuration_write_enabled: options.configuration_write,
        service_name,
    };
    write_runtime_files(&paths, &metadata)?;
    shared.log(&format!(
        "Thumble Host {} listening on port {}",
        env!("CARGO_PKG_VERSION"),
        actual_port
    ));
    println!("Thumble Host listening on port {actual_port}");

    let control_handler: Arc<dyn ControlHandler> = shared.clone();
    let control_task = tokio::spawn(control::serve_control(
        control_listener,
        control_handler,
        shutdown_rx.clone(),
    ));
    let accept_task = tokio::spawn(accept_loop(
        listener,
        Arc::clone(&shared),
        shutdown_rx.clone(),
    ));
    let expiry_task = tokio::spawn(expiry_loop(Arc::clone(&shared), shutdown_rx.clone()));
    let signal_shutdown = shutdown_tx.clone();
    let signal_task = tokio::spawn(async move {
        wait_for_shutdown_signal().await;
        let _ = signal_shutdown.send(true);
    });

    let mut wait_for_shutdown = shutdown_rx;
    while !*wait_for_shutdown.borrow() {
        if wait_for_shutdown.changed().await.is_err() {
            break;
        }
    }
    shared.stop_core();
    let _ = shutdown_tx.send(true);
    let _ = tokio::time::timeout(Duration::from_secs(1), accept_task).await;
    let _ = tokio::time::timeout(Duration::from_secs(1), control_task).await;
    let _ = tokio::time::timeout(Duration::from_secs(1), expiry_task).await;
    signal_task.abort();
    control::remove_control_socket(&paths.control_socket);
    instance.cleanup_runtime_files();
    shared.log("Thumble Host stopped");
    Ok(())
}

async fn accept_loop(
    listener: TcpListener,
    shared: Arc<SharedRuntime>,
    mut shutdown: watch::Receiver<bool>,
) {
    let next_connection = Arc::new(AtomicU64::new(1));
    let connection_limit = Arc::new(Semaphore::new(MAXIMUM_CONNECTIONS));
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
            accepted = listener.accept() => {
                match accepted {
                    Ok((stream, _)) => {
                        let Ok(permit) = Arc::clone(&connection_limit).try_acquire_owned() else {
                            shared.log("connection limit reached; dropping TCP peer");
                            continue;
                        };
                        let connection_id = next_connection.fetch_add(1, Ordering::Relaxed);
                        let shared = Arc::clone(&shared);
                        tokio::spawn(async move {
                            let _permit = permit;
                            if let Err(error) = connection_task(connection_id, stream, Arc::clone(&shared)).await {
                                shared.log(&format!("WebSocket connection ended: {error}"));
                            }
                        });
                    }
                    Err(error) => shared.log(&format!("TCP accept failed: {error}")),
                }
            }
        }
    }
}

async fn connection_task(
    connection_id: ConnectionId,
    stream: TcpStream,
    shared: Arc<SharedRuntime>,
) -> Result<(), String> {
    stream
        .set_nodelay(true)
        .map_err(|error| format!("enable TCP_NODELAY: {error}"))?;
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAXIMUM_MESSAGE_SIZE))
        .max_frame_size(Some(MAXIMUM_MESSAGE_SIZE));
    let websocket = tokio::time::timeout(
        WEBSOCKET_HANDSHAKE_TIMEOUT,
        tokio_tungstenite::accept_async_with_config(stream, Some(config)),
    )
    .await
    .map_err(|_| "WebSocket handshake timed out".to_owned())?
    .map_err(|error| format!("WebSocket handshake failed: {error}"))?;
    let (mut sink, mut stream) = websocket.split();
    let (outbound_tx, mut outbound_rx) = mpsc::channel(OUTBOUND_QUEUE_CAPACITY);
    shared.register_connection(connection_id, outbound_tx);

    let result = loop {
        tokio::select! {
            inbound = stream.next() => {
                match inbound {
                    Some(Ok(Message::Binary(data))) => {
                        if let Err(error) = decode_and_handle(connection_id, data.as_ref(), &shared) {
                            break Err(error);
                        }
                    }
                    Some(Ok(Message::Text(text))) => {
                        if let Err(error) = decode_and_handle(connection_id, text.as_bytes(), &shared) {
                            break Err(error);
                        }
                    }
                    Some(Ok(Message::Ping(payload))) => {
                        if let Err(error) = sink.send(Message::Pong(payload)).await {
                            break Err(format!("send WebSocket pong: {error}"));
                        }
                    }
                    Some(Ok(Message::Pong(_))) => {}
                    Some(Ok(Message::Close(frame))) => {
                        let _ = sink.send(Message::Close(frame)).await;
                        break Ok(());
                    }
                    Some(Ok(Message::Frame(_))) => {}
                    Some(Err(error)) => break Err(format!("read WebSocket: {error}")),
                    None => break Ok(()),
                }
            }
            _ = tokio::time::sleep(CONNECTION_IDLE_TIMEOUT) => {
                break Err("WebSocket connection was idle for 60 seconds".to_owned());
            }
            outbound = outbound_rx.recv() => {
                match outbound {
                    Some(Outbound::Binary(data)) => {
                        if let Err(error) = sink.send(Message::Binary(data.into())).await {
                            break Err(format!("send WebSocket response: {error}"));
                        }
                    }
                    Some(Outbound::Close(reason)) => {
                        let reason = reason.chars().take(120).collect::<String>();
                        let _ = sink
                            .send(Message::Close(Some(CloseFrame {
                                code: CloseCode::Away,
                                reason: reason.into(),
                            })))
                            .await;
                        break Ok(());
                    }
                    None => break Ok(()),
                }
            }
        }
    };
    shared.disconnect(connection_id);
    result
}

fn decode_and_handle(
    connection_id: ConnectionId,
    data: &[u8],
    shared: &SharedRuntime,
) -> Result<(), String> {
    let message = ControllerWireCodec::decode(data)
        .map_err(|error| format!("decode controller message: {error}"))?;
    shared.handle_message(connection_id, message)
}

async fn wait_for_shutdown_signal() {
    use std::future::pending;
    use tokio::signal::unix::{signal, SignalKind};

    let mut terminate = signal(SignalKind::terminate()).ok();
    let mut hangup = signal(SignalKind::hangup()).ok();
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = async {
            match &mut terminate {
                Some(signal) => { signal.recv().await; }
                None => pending::<()>().await,
            }
        } => {}
        _ = async {
            match &mut hangup {
                Some(signal) => { signal.recv().await; }
                None => pending::<()>().await,
            }
        } => {}
    }
}

async fn expiry_loop(shared: Arc<SharedRuntime>, mut shutdown: watch::Receiver<bool>) {
    let mut interval = tokio::time::interval(HOLD_EXPIRY_INTERVAL);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    break;
                }
            }
            _ = interval.tick() => shared.expire_holds(),
        }
    }
}

fn bind_listener(port: u16) -> Result<TcpListener, String> {
    match dual_stack_listener(port) {
        Ok(listener) => Ok(listener),
        Err(dual_error) => ipv4_listener(port).map_err(|ipv4_error| {
            format!("bind wildcard listener (IPv6: {dual_error}; IPv4: {ipv4_error})")
        }),
    }
}

fn dual_stack_listener(port: u16) -> Result<TcpListener, String> {
    let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP))
        .map_err(|error| error.to_string())?;
    socket
        .set_only_v6(false)
        .map_err(|error| error.to_string())?;
    socket
        .set_reuse_address(true)
        .map_err(|error| error.to_string())?;
    socket
        .bind(&SockAddr::from(SocketAddrV6::new(
            Ipv6Addr::UNSPECIFIED,
            port,
            0,
            0,
        )))
        .map_err(|error| error.to_string())?;
    socket.listen(128).map_err(|error| error.to_string())?;
    socket
        .set_nonblocking(true)
        .map_err(|error| error.to_string())?;
    let listener: std::net::TcpListener = socket.into();
    TcpListener::from_std(listener).map_err(|error| error.to_string())
}

fn ipv4_listener(port: u16) -> Result<TcpListener, String> {
    let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))
        .map_err(|error| error.to_string())?;
    socket
        .set_reuse_address(true)
        .map_err(|error| error.to_string())?;
    socket
        .bind(&SockAddr::from(SocketAddrV4::new(
            Ipv4Addr::UNSPECIFIED,
            port,
        )))
        .map_err(|error| error.to_string())?;
    socket.listen(128).map_err(|error| error.to_string())?;
    socket
        .set_nonblocking(true)
        .map_err(|error| error.to_string())?;
    let listener: std::net::TcpListener = socket.into();
    TcpListener::from_std(listener).map_err(|error| error.to_string())
}

/// Held exclusive authority over the canonical Rust state. The live host and
/// standalone transaction path use this exact lock implementation.
pub struct AuthorityLock {
    lock: File,
}

impl AuthorityLock {
    pub fn try_acquire(paths: &HostPaths) -> Result<Option<Self>, String> {
        paths
            .ensure_state_dir()
            .map_err(|_| "host state directory failed security validation".to_owned())?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&paths.lock_file)
            .map_err(|_| "runtime authority lock could not be opened safely".to_owned())?;
        let metadata = lock
            .metadata()
            .map_err(|_| "runtime authority lock could not be inspected".to_owned())?;
        use std::os::unix::fs::MetadataExt;
        if !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.permissions().mode() & 0o077 != 0
        {
            return Err("runtime authority lock failed ownership or permission checks".to_owned());
        }
        match lock.try_lock_exclusive() {
            Ok(()) => Ok(Some(Self { lock })),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => Ok(None),
            Err(_) => Err("runtime authority lock could not be acquired".to_owned()),
        }
    }
}

impl Drop for AuthorityLock {
    fn drop(&mut self) {
        let _ = FileExt::unlock(&self.lock);
    }
}

struct InstanceGuard {
    authority: AuthorityLock,
    paths: HostPaths,
}

impl InstanceGuard {
    fn acquire(paths: &HostPaths) -> Result<Self, String> {
        let authority = AuthorityLock::try_acquire(paths)?
            .ok_or_else(|| "Thumble Host is already running".to_owned())?;
        remove_regular_file(&paths.pid_file)?;
        remove_regular_file(&paths.runtime_file)?;
        Ok(Self {
            authority,
            paths: paths.clone(),
        })
    }

    fn cleanup_runtime_files(&self) {
        remove_if_owned_pid(&self.paths.pid_file);
        let _ = remove_regular_file(&self.paths.runtime_file);
    }
}

impl Drop for InstanceGuard {
    fn drop(&mut self) {
        self.cleanup_runtime_files();
        let _ = &self.authority;
    }
}

fn write_runtime_files(paths: &HostPaths, metadata: &RuntimeMetadata) -> Result<(), String> {
    write_private_file(
        &paths.pid_file,
        format!("{}\n", std::process::id()).as_bytes(),
    )?;
    let mut encoded = serde_json::to_vec_pretty(metadata)
        .map_err(|error| format!("encode runtime metadata: {error}"))?;
    encoded.push(b'\n');
    write_private_file(&paths.runtime_file, &encoded)
}

fn write_private_file(path: &Path, data: &[u8]) -> Result<(), String> {
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)
        .map_err(|error| format!("open {}: {error}", temporary.display()))?;
    file.write_all(data)
        .and_then(|()| file.sync_all())
        .map_err(|error| format!("write {}: {error}", temporary.display()))?;
    fs::rename(&temporary, path).map_err(|error| format!("install {}: {error}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("protect {}: {error}", path.display()))
}

fn remove_regular_file(path: &Path) -> Result<(), String> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_file() => fs::remove_file(path)
            .map_err(|error| format!("remove stale {}: {error}", path.display())),
        Ok(_) => Err(format!(
            "refusing to replace non-regular runtime path {}",
            path.display()
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("inspect {}: {error}", path.display())),
    }
}

fn remove_if_owned_pid(path: &Path) {
    let expected = std::process::id().to_string();
    if fs::read_to_string(path).is_ok_and(|contents| contents.trim() == expected) {
        let _ = fs::remove_file(path);
    }
}

fn append_log(path: &Path, line: &str) {
    if let Ok(mut file) = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
    {
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(0o600));
        let timestamp = unix_millis();
        let _ = writeln!(file, "{timestamp} {line}");
    }
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| i64::try_from(duration.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

fn default_service_name() -> String {
    let mut buffer = [0_i8; 256];
    // SAFETY: buffer is writable and its length is provided to gethostname.
    let hostname = if unsafe { libc::gethostname(buffer.as_mut_ptr(), buffer.len()) } == 0 {
        // SAFETY: reserve the final byte for a terminator even if the system
        // truncates a maximum-length hostname.
        buffer[buffer.len() - 1] = 0;
        unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) }
            .to_string_lossy()
            .into_owned()
    } else {
        String::new()
    };
    let hostname = hostname.trim();
    if hostname.is_empty() {
        "Thumble Host".to_owned()
    } else {
        format!("Thumble on {hostname}")
    }
}

fn websocket_urls(port: u16) -> Vec<String> {
    let mut addresses = local_ipv4_addresses();
    addresses.insert(Ipv4Addr::LOCALHOST);
    let mut urls = addresses
        .into_iter()
        .map(|address| format!("ws://{address}:{port}"))
        .collect::<Vec<_>>();
    urls.push(format!("ws://[::1]:{port}"));
    urls
}

fn local_ipv4_addresses() -> BTreeSet<Ipv4Addr> {
    let mut addresses = BTreeSet::new();
    let mut interfaces = std::ptr::null_mut::<libc::ifaddrs>();
    // SAFETY: getifaddrs initializes `interfaces` on success. Every pointer is
    // checked before dereference and the list is released exactly once.
    if unsafe { libc::getifaddrs(&mut interfaces) } != 0 || interfaces.is_null() {
        return addresses;
    }
    let first = interfaces;
    let mut current = first;
    while !current.is_null() {
        // SAFETY: `current` belongs to the live getifaddrs list.
        let interface = unsafe { &*current };
        let is_up = interface.ifa_flags & (libc::IFF_UP as u32) != 0;
        let is_loopback = interface.ifa_flags & (libc::IFF_LOOPBACK as u32) != 0;
        if is_up && !is_loopback && !interface.ifa_addr.is_null() {
            // SAFETY: ifa_addr is non-null and its family is read before casting.
            let address = unsafe { &*interface.ifa_addr };
            if i32::from(address.sa_family) == libc::AF_INET {
                // SAFETY: AF_INET guarantees a sockaddr_in payload.
                let address = unsafe { &*(interface.ifa_addr.cast::<libc::sockaddr_in>()) };
                addresses.insert(Ipv4Addr::from(address.sin_addr.s_addr.to_ne_bytes()));
            }
        }
        current = interface.ifa_next;
    }
    // SAFETY: `first` is the successful getifaddrs allocation.
    unsafe { libc::freeifaddrs(first) };
    addresses
}

fn bounded_controller_snapshot(state: &PersistentState) -> Result<ControllerSnapshot, String> {
    let mut snapshot = state
        .controller_snapshot()
        .map_err(|error| error.to_string())?;
    let auth_tokens = state
        .trusted_clients
        .keys()
        .map(String::as_str)
        .collect::<Vec<_>>();
    snapshot.profile.id = bounded_redacted(
        &snapshot.profile.id,
        &auth_tokens,
        MAXIMUM_DISPLAY_CHARACTERS,
    );
    snapshot.profile.name = bounded_redacted(
        &snapshot.profile.name,
        &auth_tokens,
        MAXIMUM_DISPLAY_CHARACTERS,
    );
    snapshot.canvas.frame_id = bounded_redacted(
        &snapshot.canvas.frame_id,
        &auth_tokens,
        MAXIMUM_DISPLAY_CHARACTERS,
    );
    for element in &mut snapshot.elements {
        element.id = bounded_redacted(&element.id, &auth_tokens, MAXIMUM_DISPLAY_CHARACTERS);
        element.label = bounded_redacted(&element.label, &auth_tokens, MAXIMUM_DISPLAY_CHARACTERS);
    }
    for item in &mut snapshot.control_bar_items {
        item.target_id =
            bounded_redacted(&item.target_id, &auth_tokens, MAXIMUM_DISPLAY_CHARACTERS);
    }
    for issue in &mut snapshot.layout_quality.issues {
        issue.code = bounded_redacted(&issue.code, &auth_tokens, MAXIMUM_DISPLAY_CHARACTERS);
        issue.severity =
            bounded_redacted(&issue.severity, &auth_tokens, MAXIMUM_DISPLAY_CHARACTERS);
        for control_id in &mut issue.control_ids {
            *control_id = bounded_redacted(control_id, &auth_tokens, MAXIMUM_DISPLAY_CHARACTERS);
        }
    }
    while !snapshot.layout_quality.issues.is_empty()
        && serde_json::to_vec(&snapshot)
            .is_ok_and(|encoded| encoded.len() > MAXIMUM_CONTROLLER_SNAPSHOT_BYTES)
    {
        snapshot.layout_quality.issues.pop();
        snapshot.layout_quality.omitted_issue_count = snapshot
            .layout_quality
            .issue_count
            .saturating_sub(snapshot.layout_quality.issues.len());
    }
    while !snapshot.styles.is_empty()
        && serde_json::to_vec(&snapshot)
            .is_ok_and(|encoded| encoded.len() > MAXIMUM_CONTROLLER_SNAPSHOT_BYTES)
    {
        snapshot.styles.pop();
    }
    while !snapshot.groups.is_empty()
        && serde_json::to_vec(&snapshot)
            .is_ok_and(|encoded| encoded.len() > MAXIMUM_CONTROLLER_SNAPSHOT_BYTES)
    {
        snapshot.groups.pop();
    }
    while snapshot.layers.len() > 1
        && serde_json::to_vec(&snapshot)
            .is_ok_and(|encoded| encoded.len() > MAXIMUM_CONTROLLER_SNAPSHOT_BYTES)
    {
        snapshot.layers.pop();
    }
    while snapshot.elements.len() > 1
        && serde_json::to_vec(&snapshot)
            .is_ok_and(|encoded| encoded.len() > MAXIMUM_CONTROLLER_SNAPSHOT_BYTES)
    {
        snapshot.elements.pop();
    }
    while snapshot.control_bar_items.len() > 1
        && serde_json::to_vec(&snapshot)
            .is_ok_and(|encoded| encoded.len() > MAXIMUM_CONTROLLER_SNAPSHOT_BYTES)
    {
        snapshot.control_bar_items.pop();
    }
    Ok(snapshot)
}

fn redacted(value: &str, auth_tokens: &[&str]) -> String {
    if auth_tokens
        .iter()
        .any(|token| !token.is_empty() && value.contains(token))
    {
        "[REDACTED]".to_owned()
    } else {
        value.to_owned()
    }
}

fn bounded_redacted(value: &str, auth_tokens: &[&str], maximum_characters: usize) -> String {
    let value = redacted(value, auth_tokens);
    if value == "[REDACTED]" || value.chars().count() <= maximum_characters {
        value
    } else {
        value.chars().take(maximum_characters).collect()
    }
}

fn accessibility_response(trusted: bool) -> ControlResponse {
    let mut response = ControlResponse::success();
    response.accessibility_trusted = Some(trusted);
    response
}

pub fn read_runtime_metadata(path: &Path) -> Result<RuntimeMetadata, String> {
    let data = fs::read(path).map_err(|error| format!("read runtime metadata: {error}"))?;
    serde_json::from_slice(&data).map_err(|error| format!("decode runtime metadata: {error}"))
}

pub fn instance_lock_held(paths: &HostPaths) -> Result<bool, String> {
    AuthorityLock::try_acquire(paths).map(|guard| guard.is_none())
}

pub fn protocol_error_message(text: &str) -> ControllerMessage {
    let mut message = ControllerMessage::new(ControllerMessageType::Error, 0);
    message.message = Some(text.to_owned());
    message
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[tokio::test]
    async fn wildcard_listener_reports_an_ephemeral_actual_port() {
        let listener = bind_listener(0).unwrap();
        assert_ne!(listener.local_addr().unwrap().port(), 0);
    }

    #[test]
    fn status_urls_always_include_loopback_and_actual_port() {
        let urls = websocket_urls(43210);
        assert!(urls.contains(&"ws://127.0.0.1:43210".to_owned()));
        assert!(urls.contains(&"ws://[::1]:43210".to_owned()));
        assert!(urls.iter().all(|url| url.ends_with(":43210")));
    }

    #[test]
    fn status_string_redaction_removes_embedded_auth_tokens() {
        assert_eq!(
            redacted("prefix-secret-token-suffix", &["secret-token"]),
            "[REDACTED]"
        );
        assert_eq!(redacted("ordinary", &["secret-token"]), "ordinary");
        assert_eq!(bounded_redacted("áéíó", &["secret-token"], 2), "áé");
        assert_eq!(
            bounded_redacted("prefix-secret-token-suffix", &["secret-token"], 2),
            "[REDACTED]"
        );
    }

    #[test]
    fn installed_controls_are_allowlisted_profile_targets_without_raw_keys() {
        let mut state = thumble_core::PersistentState::minimal("server").unwrap();
        state.profiles = vec![serde_json::json!({
            "id": "profile",
            "name": "Profile",
            "customization": {
                "elements": [
                    {
                        "id": "safe-button",
                        "label": "Safe Button",
                        "kind": "button",
                        "output": {"keyboard": {"keyCode": 77, "modifiersRawValue": 2}}
                    },
                    {
                        "id": "stick",
                        "label": "Stick",
                        "kind": "joystick",
                        "partOutputs": {
                            "joystick_up": {"keyboard": {"keyCode": 13}},
                            "joystick_down": {"keyboard": {"keyCode": 1}}
                        }
                    },
                    {
                        "id": "decoration",
                        "label": "Ignore Me",
                        "kind": "decoration",
                        "output": {"keyboard": {"keyCode": 12}}
                    }
                ]
            }
        })];
        state.active_profile_id = "profile".to_owned();
        state.default_profile_id = "profile".to_owned();
        state.normalize().unwrap();

        let controls = installed_controls(&state);
        let ids = controls
            .iter()
            .map(|control| control.summary.control_id.as_str())
            .collect::<Vec<_>>();
        assert!(ids.contains(&"element:safe-button"));
        assert!(ids.contains(&"element:stick#joystick_up"));
        assert!(ids.contains(&"element:stick#joystick_down"));
        assert!(!ids.iter().any(|id| id.contains("decoration")));
        assert!(!ids.iter().any(|id| id.contains("77")));
        assert!(!ids.iter().any(|id| id.contains("shell")));
    }

    #[test]
    fn editable_controller_snapshot_remains_within_the_48_kib_wire_cap() {
        let mut state = thumble_core::PersistentState::minimal("server").unwrap();
        let customization = state.profiles[0]["customization"].as_object_mut().unwrap();
        let elements = customization
            .get_mut("elements")
            .and_then(Value::as_array_mut)
            .unwrap();
        let sequence = (0..32)
            .map(|_| serde_json::json!({"keyCode":13,"modifiersRawValue":15}))
            .collect::<Vec<_>>();
        for index in 0..128 {
            elements.push(serde_json::json!({
                "id":format!("00000000-0000-0000-0000-{:012}", 2_000 + index),
                "label":"A bounded but deliberately verbose editable control label",
                "kind":"joystick",
                "layout":{"centerX":0.5,"centerY":0.5,"widthScale":1,"heightScale":1},
                "output":{"keyboard":{"sequence":sequence}},
                "partOutputs":{
                    "joystick_up":{"keyboard":{"sequence":sequence}},
                    "joystick_down":{"keyboard":{"sequence":sequence}},
                    "joystick_left":{"keyboard":{"sequence":sequence}},
                    "joystick_right":{"keyboard":{"sequence":sequence}}
                }
            }));
        }
        let snapshot = bounded_controller_snapshot(&state).unwrap();
        let encoded = serde_json::to_vec(&snapshot).unwrap();
        assert!(
            encoded.len() <= MAXIMUM_CONTROLLER_SNAPSHOT_BYTES,
            "{}",
            encoded.len()
        );
        assert!(!snapshot.elements.is_empty());
        assert_eq!(
            snapshot.layout_quality.omitted_issue_count,
            snapshot
                .layout_quality
                .issue_count
                .saturating_sub(snapshot.layout_quality.issues.len())
        );
        let text = String::from_utf8(encoded).unwrap();
        assert!(!text.contains("keyCode"));
        assert!(!text.contains("modifiersRawValue"));
    }

    #[test]
    fn host_side_control_press_limit_recovers_after_window() {
        let start = Instant::now();
        let mut presses = VecDeque::new();
        for _ in 0..CONTROL_PRESS_LIMIT {
            allow_control_press(&mut presses, start).unwrap();
        }
        assert!(allow_control_press(&mut presses, start).is_err());
        allow_control_press(&mut presses, start + CONTROL_PRESS_WINDOW).unwrap();
        assert_eq!(presses.len(), 1);
    }

    #[test]
    fn online_legacy_profile_import_uses_the_same_draft_and_cas_path_as_offline_import() {
        let directory = tempdir().unwrap();
        let paths = HostPaths::new(
            directory.path().join("state"),
            directory.path().join("state/control.sock"),
        );
        let state = thumble_core::PersistentState::minimal("server").unwrap();
        let document = thumble_core::ConfigurationDocument::from_state(&state).unwrap();
        let artifact = thumble_core::ProfileArtifact::from_configuration(
            &document,
            thumble_core::ProfileArtifactSelection::All,
            1,
        )
        .unwrap();
        let mut legacy = serde_json::to_value(artifact).unwrap();
        let object = legacy.as_object_mut().unwrap();
        object.remove("artifactVersion");
        object.remove("catalogRevision");
        object.remove("contentHash");
        object.insert("version".to_owned(), Value::from(1));
        let artifact_json = serde_json::to_string(&legacy).unwrap();
        let core = HostCore::new(state, "123456").unwrap();
        let (shutdown, _) = watch::channel(false);
        let shared = SharedRuntime {
            inner: Mutex::new(RuntimeInner {
                core,
                tokens: SecureTokens,
                connections: HashMap::new(),
                output: OutputExecutor::new(false, None),
                control_press_times: VecDeque::new(),
            }),
            paths: paths.clone(),
            requested_port: 0,
            actual_port: 0,
            service_name: "Test".to_owned(),
            input_enabled: false,
            configuration_write_enabled: true,
            bonjour: Arc::new(BonjourRegistration::disabled("Test".to_owned())),
            shutdown,
            started_at: Instant::now(),
        };
        let response = shared.cli_profile_transaction(&CliProfileRequest {
            schema_version: cli_profile::CLI_PROFILE_SCHEMA_VERSION,
            invocation_id: Some(Uuid::parse_str("abcdefab-cdef-5abc-8def-abcdefabcdef").unwrap()),
            expected_configuration_revision: Some(1),
            command: cli_profile::CliProfileCommand::Import {
                artifact_json,
                append_as_copies: true,
                select: true,
                make_default: false,
            },
        });
        assert!(response.ok, "{:?}", response.error);
        assert_eq!(response.authority_mode, "online");
        assert_eq!(response.outcome.unwrap().profile_names.len(), 1);
        let in_memory = shared.inner.lock().unwrap();
        assert_eq!(in_memory.core.persistent_state().profiles.len(), 2);
        assert_eq!(in_memory.core.persistent_state().configuration_revision, 2);
        drop(in_memory);
        let persisted = storage::load(&paths.state_file).unwrap();
        assert_eq!(persisted.profiles.len(), 2);
        assert_eq!(persisted.configuration_revision, 2);
    }

    #[test]
    fn failed_profile_persistence_rolls_back_in_memory_selection() {
        let directory = tempdir().unwrap();
        let mut paths = HostPaths::new(
            directory.path().to_path_buf(),
            directory.path().join("control.sock"),
        );
        let blocked_state_path = directory.path().join("state-directory");
        fs::create_dir(&blocked_state_path).unwrap();
        paths.state_file = blocked_state_path;

        let mut state = thumble_core::PersistentState::minimal("server").unwrap();
        let second_id = "00000000-0000-4000-8000-000000000602";
        let mut second = state.profiles[0].clone();
        second["id"] = Value::String(second_id.to_owned());
        second["name"] = Value::String("B".to_owned());
        state.profiles.push(second);
        state.normalize().unwrap();
        let core = HostCore::new(state, "123456").unwrap();
        let (shutdown, _) = watch::channel(false);
        let shared = SharedRuntime {
            inner: Mutex::new(RuntimeInner {
                core,
                tokens: SecureTokens,
                connections: HashMap::new(),
                output: OutputExecutor::new(false, None),
                control_press_times: VecDeque::new(),
            }),
            paths,
            requested_port: 0,
            actual_port: 0,
            service_name: "Test".to_owned(),
            input_enabled: false,
            configuration_write_enabled: false,
            bonjour: Arc::new(BonjourRegistration::disabled("Test".to_owned())),
            shutdown,
            started_at: Instant::now(),
        };

        assert!(matches!(
            shared.save_configuration_draft(
                "00000000-0000-0000-0000-000000000301",
                1,
                1,
                "00000000-0000-0000-0000-000000000501",
                None,
            ),
            Err(SaveConfigurationError::Disabled)
        ));
        let transaction = shared.cli_profile_transaction(&CliProfileRequest {
            schema_version: cli_profile::CLI_PROFILE_SCHEMA_VERSION,
            invocation_id: Some(Uuid::parse_str("00000000-0000-5000-8000-000000000601").unwrap()),
            expected_configuration_revision: None,
            command: cli_profile::CliProfileCommand::Rename {
                target: cli_profile::ProfileSelector::Active,
                name: "Blocked".to_owned(),
            },
        });
        assert!(!transaction.ok);
        let failure = transaction.error.unwrap();
        assert_eq!(failure.code, "configuration_write_disabled");
        assert!(failure.draft_id.is_some());
        let orientation = shared.cli_profile_transaction(&CliProfileRequest {
            schema_version: cli_profile::CLI_PROFILE_SCHEMA_VERSION,
            invocation_id: Some(Uuid::parse_str("00000000-0000-5000-8000-000000000603").unwrap()),
            expected_configuration_revision: None,
            command: cli_profile::CliProfileCommand::OrientationGet {
                target: cli_profile::ProfileSelector::Active,
            },
        });
        assert!(orientation.ok, "{:?}", orientation.error);
        assert_eq!(
            orientation.orientation.unwrap().orientation,
            crate::draft_operation::ConfigurationOrientationPreference::Automatic
        );
        assert!(shared.select_profile(second_id).is_err());
        assert_eq!(
            shared
                .inner
                .lock()
                .unwrap()
                .core
                .persistent_state()
                .active_profile_id,
            thumble_core::DEFAULT_PROFILE_ID
        );
    }

    #[test]
    fn failed_draft_persistence_keeps_authoritative_state_and_draft_unchanged() {
        let directory = tempdir().unwrap();
        let mut paths = HostPaths::new(
            directory.path().to_path_buf(),
            directory.path().join("control.sock"),
        );
        let blocked_state_path = directory.path().join("state-directory");
        fs::create_dir(&blocked_state_path).unwrap();
        paths.state_file = blocked_state_path;
        let state = thumble_core::PersistentState::minimal("server").unwrap();
        let core = HostCore::new(state, "123456").unwrap();
        let (shutdown, _) = watch::channel(false);
        let shared = SharedRuntime {
            inner: Mutex::new(RuntimeInner {
                core,
                tokens: SecureTokens,
                connections: HashMap::new(),
                output: OutputExecutor::new(false, None),
                control_press_times: VecDeque::new(),
            }),
            paths,
            requested_port: 0,
            actual_port: 0,
            service_name: "Test".to_owned(),
            input_enabled: false,
            configuration_write_enabled: true,
            bonjour: Arc::new(BonjourRegistration::disabled("Test".to_owned())),
            shutdown,
            started_at: Instant::now(),
        };
        let draft = shared.begin_configuration_draft(1).unwrap();
        let operation = ConfigurationOperation::ProfileRename {
            profile_id: thumble_core::DEFAULT_PROFILE_ID.to_owned(),
            name: "Must Roll Back".to_owned(),
        };
        let (edited, _, _) = shared
            .edit_configuration_draft(
                &draft.draft_id,
                1,
                "00000000-0000-0000-0000-000000000401",
                &operation,
            )
            .unwrap();
        assert_eq!(edited.draft_revision, 2);
        assert!(matches!(
            shared.save_configuration_draft(
                &draft.draft_id,
                2,
                1,
                "00000000-0000-0000-0000-000000000501",
                None,
            ),
            Err(SaveConfigurationError::PersistenceFailed(_))
        ));
        let inner = shared.inner.lock().unwrap();
        assert_eq!(inner.core.persistent_state().configuration_revision, 1);
        assert_eq!(inner.core.persistent_state().profiles[0]["name"], "Default");
        drop(inner);
        assert_eq!(
            DraftStore::new(&shared.paths)
                .get(&draft.draft_id, unix_millis())
                .unwrap()
                .draft_revision,
            2
        );
    }

    #[test]
    fn runtime_metadata_has_no_secret_fields() {
        let metadata = RuntimeMetadata {
            pid: 1,
            version: "test".to_owned(),
            requested_port: 0,
            actual_port: 1234,
            bonjour_enabled: false,
            input_enabled: false,
            configuration_write_enabled: false,
            service_name: "Test".to_owned(),
        };
        let json = serde_json::to_string(&metadata).unwrap();
        assert!(!json.to_ascii_lowercase().contains("token"));
    }

    #[test]
    fn authority_lock_rejects_symlink_replacement() {
        use std::os::unix::fs::symlink;
        let directory = tempdir().unwrap();
        let paths = HostPaths::new(
            directory.path().join("state"),
            directory.path().join("state/control.sock"),
        );
        paths.ensure_state_dir().unwrap();
        let target = directory.path().join("target");
        fs::write(&target, b"").unwrap();
        symlink(&target, &paths.lock_file).unwrap();
        assert!(AuthorityLock::try_acquire(&paths).is_err());
    }

    #[test]
    fn advisory_lock_refuses_a_second_owner() {
        let directory = tempdir().unwrap();
        let paths = HostPaths::new(
            directory.path().to_path_buf(),
            directory.path().join("control.sock"),
        );
        let first = InstanceGuard::acquire(&paths).unwrap();
        assert!(InstanceGuard::acquire(&paths).is_err());
        drop(first);
        assert!(InstanceGuard::acquire(&paths).is_ok());
    }
}
