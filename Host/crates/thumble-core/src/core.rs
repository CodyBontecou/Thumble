use crate::gamepad::{AnalogAxis, AnalogTarget};
use crate::resolver::element_part_name;
use crate::{
    KeyBinding, KeyStroke, OutputBinding, PersistentState, StateError, TrustedClient,
    VirtualGamepadButton,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::error::Error;
use std::fmt;
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType, ControllerPointerButton,
    ControllerPointerEventKind, ControllerWireCodec, KeypadElementID, KeypadElementInputPart,
    VirtualGamepadStick, VirtualGamepadTrigger,
};

pub type ConnectionId = u64;
const PAIRING_REQUEST_LIFETIME_MILLIS: i64 = 120_000;

/// Injected wall-clock and monotonic times for one deterministic core turn.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CoreTime {
    pub unix_millis: i64,
    pub monotonic_millis: i64,
}

impl CoreTime {
    pub const fn new(unix_millis: i64, monotonic_millis: i64) -> Self {
        Self {
            unix_millis,
            monotonic_millis,
        }
    }

    pub const fn uniform(millis: i64) -> Self {
        Self::new(millis, millis)
    }
}

pub trait TokenSource {
    fn next_pairing_code(&mut self) -> String;
    fn next_auth_token(&mut self) -> String;
}

#[derive(Clone, PartialEq)]
pub enum Effect {
    SendMessage {
        connection_id: ConnectionId,
        message: Box<ControllerMessage>,
    },
    CloseConnection {
        connection_id: ConnectionId,
        reason: String,
    },
    Diagnostic {
        connection_id: ConnectionId,
        message: String,
    },
    PersistState,
    KeyDown(KeyBinding),
    KeyUp(KeyBinding),
    PulseKey(KeyBinding),
    TapSequence(Vec<KeyStroke>),
    PointerMove {
        delta_x: f64,
        delta_y: f64,
    },
    PointerScroll {
        delta_x: f64,
        delta_y: f64,
    },
    PointerButton {
        button: ControllerPointerButton,
        pressed: bool,
    },
    GamepadButton {
        button: VirtualGamepadButton,
        pressed: bool,
    },
    GamepadStick {
        stick: VirtualGamepadStick,
        x: f64,
        y: f64,
    },
    GamepadTrigger {
        trigger: VirtualGamepadTrigger,
        value: f64,
    },
    GamepadReset,
    StatusChanged(Box<StatusSnapshot>),
}

/// Deliberately omits outbound payloads because pairing responses contain an
/// authentication token. Debugging an effect queue must never disclose it.
impl fmt::Debug for Effect {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SendMessage {
                connection_id,
                message,
            } => formatter
                .debug_struct("SendMessage")
                .field("connection_id", connection_id)
                .field("message_type", &message.message_type)
                .finish(),
            Self::CloseConnection { connection_id, .. } => formatter
                .debug_struct("CloseConnection")
                .field("connection_id", connection_id)
                .finish_non_exhaustive(),
            Self::Diagnostic { connection_id, .. } => formatter
                .debug_struct("Diagnostic")
                .field("connection_id", connection_id)
                .finish_non_exhaustive(),
            Self::PersistState => formatter.write_str("PersistState"),
            Self::KeyDown(binding) => formatter.debug_tuple("KeyDown").field(binding).finish(),
            Self::KeyUp(binding) => formatter.debug_tuple("KeyUp").field(binding).finish(),
            Self::PulseKey(binding) => formatter.debug_tuple("PulseKey").field(binding).finish(),
            Self::TapSequence(strokes) => {
                formatter.debug_tuple("TapSequence").field(strokes).finish()
            }
            Self::PointerMove { delta_x, delta_y } => formatter
                .debug_struct("PointerMove")
                .field("delta_x", delta_x)
                .field("delta_y", delta_y)
                .finish(),
            Self::PointerScroll { delta_x, delta_y } => formatter
                .debug_struct("PointerScroll")
                .field("delta_x", delta_x)
                .field("delta_y", delta_y)
                .finish(),
            Self::PointerButton { button, pressed } => formatter
                .debug_struct("PointerButton")
                .field("button", button)
                .field("pressed", pressed)
                .finish(),
            Self::GamepadButton { button, pressed } => formatter
                .debug_struct("GamepadButton")
                .field("button", button)
                .field("pressed", pressed)
                .finish(),
            Self::GamepadStick { stick, x, y } => formatter
                .debug_struct("GamepadStick")
                .field("stick", stick)
                .field("x", x)
                .field("y", y)
                .finish(),
            Self::GamepadTrigger { trigger, value } => formatter
                .debug_struct("GamepadTrigger")
                .field("trigger", trigger)
                .field("value", value)
                .finish(),
            Self::GamepadReset => formatter.write_str("GamepadReset"),
            Self::StatusChanged(status) => formatter
                .debug_tuple("StatusChanged")
                .field(status)
                .finish(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct StatusCounters {
    pub messages_received: u64,
    pub accepted_inputs: u64,
    pub ignored_inputs: u64,
    pub duplicate_sequences: u64,
    pub rejected_inputs: u64,
    pub stale_generations: u64,
    pub pairing_rejections: u64,
    pub expired_holds: u64,
    pub release_all_events: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StatusSnapshot {
    pub running: bool,
    pub paired: bool,
    pub client_name: Option<String>,
    pub pairing_pending: bool,
    pub active_generation: Option<u64>,
    pub pressed_buttons: Vec<KeypadElementID>,
    pub pressed_elements: Vec<String>,
    pub active_pointer_buttons: Vec<ControllerPointerButton>,
    #[serde(rename = "activeProfileID")]
    pub active_profile_id: String,
    #[serde(rename = "defaultProfileID")]
    pub default_profile_id: String,
    pub configuration_revision: u64,
    pub counters: StatusCounters,
    pub status_text: String,
}

#[derive(Clone)]
struct ActiveClient {
    connection_id: ConnectionId,
    auth_token: String,
    name: String,
}

impl fmt::Debug for ActiveClient {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ActiveClient")
            .field("connection_id", &self.connection_id)
            .field("auth_token", &"[REDACTED]")
            .field("name", &self.name)
            .finish()
    }
}

#[derive(Debug, Clone)]
struct PendingPairing {
    connection_id: ConnectionId,
    name: String,
    expires_at_millis: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum InputIdentity {
    Button(KeypadElementID),
    LocalControl(String),
    Element {
        element_id: String,
        part: KeypadElementInputPart,
    },
}

impl InputIdentity {
    fn sort_key(&self) -> String {
        match self {
            Self::Button(button) => format!("0:{button}"),
            Self::LocalControl(id) => format!("2:{id}"),
            Self::Element { element_id, part } => {
                format!(
                    "1:{}#{}",
                    element_id.to_ascii_lowercase(),
                    element_part_name(*part)
                )
            }
        }
    }

    fn element_storage_key(&self) -> Option<String> {
        match self {
            Self::Button(_) | Self::LocalControl(_) => None,
            Self::Element { element_id, part } => {
                Some(if *part == KeypadElementInputPart::Primary {
                    element_id.clone()
                } else {
                    format!("{element_id}#{}", element_part_name(*part))
                })
            }
        }
    }
}

#[derive(Debug, Clone, Default)]
struct PhysicalHold {
    identified_last_seen: HashMap<u64, i64>,
    anonymous_last_seen: Option<i64>,
    binding: Option<OutputBinding>,
}

impl PhysicalHold {
    fn is_held(&self) -> bool {
        !self.identified_last_seen.is_empty() || self.anonymous_last_seen.is_some()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GenerationAcceptance {
    Legacy,
    Initial,
    Current,
    Transitioned,
    Rejected,
}

#[derive(Debug, Clone, Copy)]
enum SequenceStream {
    Digital,
    Pointer,
}

pub struct HostCore {
    state: PersistentState,
    pairing_code: String,
    running: bool,
    active_client: Option<ActiveClient>,
    pending_pairing: Option<PendingPairing>,
    pairing_failure_count: u32,
    pairing_blocked_until_millis: i64,
    active_generation: Option<u64>,
    retired_generations: VecDeque<u64>,
    last_digital_sequence: Option<u64>,
    last_pointer_sequence: Option<u64>,
    physical_holds: HashMap<InputIdentity, PhysicalHold>,
    held_key_counts: BTreeMap<KeyBinding, u32>,
    held_gamepad_counts: BTreeMap<VirtualGamepadButton, u32>,
    analog_axes: BTreeMap<AnalogTarget, AnalogAxis>,
    pointer_button_last_seen: HashMap<ControllerPointerButton, i64>,
    counters: StatusCounters,
}

impl fmt::Debug for HostCore {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("HostCore")
            .field("state", &self.state)
            .field("pairing_code", &"[REDACTED]")
            .field("running", &self.running)
            .field("active_client", &self.active_client)
            .field("pending_pairing", &self.pending_pairing)
            .field("pairing_failure_count", &self.pairing_failure_count)
            .field("active_generation", &self.active_generation)
            .field("retired_generation_count", &self.retired_generations.len())
            .field("physical_hold_count", &self.physical_holds.len())
            .field("held_key_count", &self.held_key_counts.len())
            .field("held_gamepad_count", &self.held_gamepad_counts.len())
            .field("pointer_button_count", &self.pointer_button_last_seen.len())
            .field("counters", &self.counters)
            .finish()
    }
}

impl HostCore {
    pub fn new(
        mut state: PersistentState,
        initial_pairing_code: impl Into<String>,
    ) -> Result<Self, CoreError> {
        state.normalize()?;
        let pairing_code = initial_pairing_code.into();
        if !is_pairing_code(&pairing_code) {
            return Err(CoreError::InvalidPairingCodeGenerated);
        }
        Ok(Self {
            state,
            pairing_code,
            running: true,
            active_client: None,
            pending_pairing: None,
            pairing_failure_count: 0,
            pairing_blocked_until_millis: 0,
            active_generation: None,
            retired_generations: VecDeque::new(),
            last_digital_sequence: None,
            last_pointer_sequence: None,
            physical_holds: HashMap::new(),
            held_key_counts: BTreeMap::new(),
            held_gamepad_counts: BTreeMap::new(),
            analog_axes: BTreeMap::new(),
            pointer_button_last_seen: HashMap::new(),
            counters: StatusCounters::default(),
        })
    }

    pub fn new_with_tokens(
        state: PersistentState,
        tokens: &mut impl TokenSource,
    ) -> Result<Self, CoreError> {
        Self::new(state, tokens.next_pairing_code())
    }

    pub fn persistent_state(&self) -> &PersistentState {
        &self.state
    }

    pub fn needs_virtual_gamepad(&self) -> bool {
        self.state.needs_virtual_gamepad()
    }

    /// A bounded local-control tap respecting output mode and existing holds.
    /// Gamepad taps never release a button held by a physical input. Adapters
    /// execute the returned press/release effects in order.
    pub fn tap_output_binding(&self, binding: &OutputBinding) -> Vec<Effect> {
        let binding = self.state.filter_output_mode(binding.clone());
        let mut effects = Vec::new();
        if let Some(keyboard) = &binding.keyboard {
            if keyboard.is_sequence()
                || !self
                    .held_key_counts
                    .contains_key(&keyboard.canonical_held_binding())
            {
                effects.push(Effect::TapSequence(keyboard.strokes()));
            } else {
                self.pulse_binding(&OutputBinding::keyboard(keyboard.clone()), &mut effects);
            }
        }
        let buttons = binding
            .supported_gamepad_buttons()
            .filter(|button| !self.held_gamepad_counts.contains_key(button))
            .collect::<Vec<_>>();
        for pressed in [true, false] {
            for button in &buttons {
                effects.push(Effect::GamepadButton {
                    button: *button,
                    pressed,
                });
            }
        }
        effects
    }

    /// Local editor/CLI holds use the same captured binding and reference counts
    /// as phone input. They are receiver-owned and expire even if the caller dies.
    pub fn set_local_output_binding(
        &mut self,
        control_id: &str,
        binding: Option<OutputBinding>,
        pressed: bool,
        now_millis: i64,
    ) -> Result<Vec<Effect>, LocalControlError> {
        if control_id.is_empty() || control_id.len() > 512 {
            return Err(LocalControlError::InvalidControlID);
        }
        let identity = InputIdentity::LocalControl(control_id.to_ascii_lowercase());
        let mut effects = Vec::new();
        if pressed {
            let binding = binding.map(|output| self.state.filter_output_mode(output));
            self.physical_down(identity, None, binding, now_millis, &mut effects);
        } else {
            self.physical_up(&identity, None, &mut effects);
        }
        Ok(effects)
    }

    pub fn pairing_code(&self) -> &str {
        &self.pairing_code
    }

    /// Replace the currently accepted pairing code without restarting the host.
    /// Existing trusted authentication tokens and an in-flight pairing request
    /// are left intact; only the six-digit code that the next `hello` must
    /// submit changes.
    pub fn rotate_pairing_code(&mut self, tokens: &mut impl TokenSource) -> Result<(), CoreError> {
        let pairing_code = tokens.next_pairing_code();
        if !is_pairing_code(&pairing_code) {
            return Err(CoreError::InvalidPairingCodeGenerated);
        }
        self.pairing_code = pairing_code;
        self.pairing_failure_count = 0;
        self.pairing_blocked_until_millis = 0;
        Ok(())
    }

    pub fn status(&self) -> StatusSnapshot {
        let mut pressed_buttons = self.physical_holds.iter().filter_map(|(identity, hold)| {
            match identity {
                InputIdentity::Button(id) if hold.is_held() => Some(*id),
                _ => None,
            }
        }).collect::<Vec<_>>();
        pressed_buttons.sort();

        let mut pressed_elements = self
            .physical_holds
            .iter()
            .filter(|(_, hold)| hold.is_held())
            .filter_map(|(identity, _)| identity.element_storage_key())
            .map(|element| self.safe_status_value(&element))
            .collect::<Vec<_>>();
        pressed_elements.sort_by_key(|element| element.to_ascii_lowercase());

        let active_pointer_buttons = pointer_buttons()
            .into_iter()
            .filter(|button| self.pointer_button_last_seen.contains_key(button))
            .collect();

        let pairing_pending = self.pending_pairing.is_some();
        let client_name = self
            .active_client
            .as_ref()
            .map(|client| self.safe_status_value(&client.name))
            .or_else(|| {
                self.pending_pairing
                    .as_ref()
                    .map(|pending| self.safe_status_value(&pending.name))
            });
        let status_text = if !self.running {
            "Stopped"
        } else if self.active_client.is_some() {
            "Client connected"
        } else if pairing_pending {
            "Waiting for pairing code"
        } else {
            "Waiting for pairing request"
        }
        .to_owned();

        StatusSnapshot {
            running: self.running,
            paired: self.active_client.is_some(),
            client_name,
            pairing_pending,
            active_generation: self.active_generation,
            pressed_buttons,
            pressed_elements,
            active_pointer_buttons,
            active_profile_id: self.safe_status_value(&self.state.active_profile_id),
            default_profile_id: self.safe_status_value(&self.state.default_profile_id),
            configuration_revision: self.state.configuration_revision,
            counters: self.counters.clone(),
            status_text,
        }
    }

    pub fn set_running(&mut self, running: bool) -> Vec<Effect> {
        let before = self.status();
        let mut effects = Vec::new();
        if self.running == running {
            return effects;
        }
        self.running = running;
        if !running {
            self.release_all_internal(&mut effects);
            if let Some(active) = self.active_client.take() {
                effects.push(Effect::CloseConnection {
                    connection_id: active.connection_id,
                    reason: "Host stopped".to_owned(),
                });
            }
            if let Some(pending) = self.pending_pairing.take() {
                effects.push(Effect::CloseConnection {
                    connection_id: pending.connection_id,
                    reason: "Host stopped".to_owned(),
                });
            }
            self.reset_input_session();
        }
        self.append_status_if_changed(before, &mut effects);
        effects
    }

    /// Convenience entry point for tests or clocks where one millisecond value
    /// is appropriate for both persistence and hold expiry.
    pub fn handle_message(
        &mut self,
        connection_id: ConnectionId,
        message: ControllerMessage,
        now_millis: i64,
        tokens: &mut impl TokenSource,
    ) -> Result<Vec<Effect>, CoreError> {
        self.handle_message_at(
            connection_id,
            message,
            CoreTime::uniform(now_millis),
            tokens,
        )
    }

    /// Handle one reliable WebSocket message with separately injected wall and
    /// monotonic timestamps.
    pub fn handle_message_at(
        &mut self,
        connection_id: ConnectionId,
        message: ControllerMessage,
        time: CoreTime,
        tokens: &mut impl TokenSource,
    ) -> Result<Vec<Effect>, CoreError> {
        let before = self.status();
        self.counters.messages_received = self.counters.messages_received.saturating_add(1);
        let mut effects = Vec::new();

        if !self.running {
            self.reject_connection(connection_id, "Host is not running", true, &mut effects);
            self.append_status_if_changed(before, &mut effects);
            return Ok(effects);
        }

        match message.message_type {
            ControllerMessageType::PairingRequest => {
                self.handle_pairing_request(
                    connection_id,
                    &message,
                    time.monotonic_millis,
                    tokens,
                    &mut effects,
                )?;
            }
            ControllerMessageType::Hello => {
                self.handle_hello(connection_id, &message, time, tokens, &mut effects)?;
            }
            _ if !self.is_authenticated(connection_id) => {
                self.reject_connection(
                    connection_id,
                    "Authentication required",
                    true,
                    &mut effects,
                );
            }
            ControllerMessageType::Ping => {
                let mut pong =
                    ControllerMessage::new(ControllerMessageType::Pong, message.timestamp);
                pong.sent_at = message.sent_at;
                effects.push(Effect::SendMessage {
                    connection_id,
                    message: Box::new(pong),
                });
            }
            ControllerMessageType::Pong | ControllerMessageType::Error => {}
            ControllerMessageType::Button | ControllerMessageType::ElementInput => {
                self.handle_digital_input(
                    connection_id,
                    &message,
                    time.monotonic_millis,
                    &mut effects,
                );
            }
            ControllerMessageType::Pointer => {
                self.handle_pointer_input(
                    connection_id,
                    &message,
                    time.monotonic_millis,
                    &mut effects,
                );
            }
            ControllerMessageType::GamepadAnalog => {
                self.handle_gamepad_analog(
                    connection_id,
                    &message,
                    time.monotonic_millis,
                    &mut effects,
                );
            }
            ControllerMessageType::ReleaseAll => {
                self.handle_release_all(connection_id, &message, &mut effects);
            }
            ControllerMessageType::Heartbeat => {
                self.handle_heartbeat(connection_id, &message, time.monotonic_millis, &mut effects);
            }
            ControllerMessageType::GamepadProfileSelection
            | ControllerMessageType::GamepadDefaultProfile
            | ControllerMessageType::GamepadProfiles
            | ControllerMessageType::GamepadCustomization => {
                self.handle_profile_message(connection_id, &message, &mut effects);
            }
            ControllerMessageType::PairingChallenge
            | ControllerMessageType::PairingAccepted
            | ControllerMessageType::SkinPackages
            | ControllerMessageType::SkinPackageRemoval
            | ControllerMessageType::GamepadProfileSkinSelection
            | ControllerMessageType::GamepadProfileOrientationPreferenceMutation
            | ControllerMessageType::LaunchProfileTarget => {
                self.send_diagnostic(
                    connection_id,
                    &format!(
                        "{} is not supported by this host",
                        message_type_name(message.message_type)
                    ),
                    &mut effects,
                );
            }
        }

        self.append_status_if_changed(before, &mut effects);
        Ok(effects)
    }

    /// Release every tracked keyboard, pointer, and gamepad hold without
    /// changing the running or authentication state. Host control adapters use this for a
    /// local emergency release command.
    pub fn release_all(&mut self) -> Vec<Effect> {
        let before = self.status();
        let mut effects = Vec::new();
        self.release_all_internal(&mut effects);
        self.append_status_if_changed(before, &mut effects);
        effects
    }

    /// A receiver-originated safety release also retires the input generation.
    /// Late datagrams cannot reassert a hold before the phone receives the reset.
    pub fn release_all_locally(&mut self) -> Vec<Effect> {
        let before = self.status();
        let mut effects = Vec::new();
        self.release_all_and_notify_client(&mut effects);
        self.append_status_if_changed(before, &mut effects);
        effects
    }

    /// Select an installed profile on behalf of a trusted local control
    /// adapter. The profile ID is canonicalized against persisted state, all
    /// held input is released before a change, and an active iPhone is sent the
    /// same complete profile state it would receive after its own selection.
    pub fn select_profile_locally(
        &mut self,
        profile_id: &str,
    ) -> Result<Vec<Effect>, LocalControlError> {
        let before = self.status();
        let mut effects = Vec::new();
        self.select_profile_internal(profile_id, &mut effects)?;
        self.append_status_if_changed(before, &mut effects);
        Ok(effects)
    }

    /// Restore the complete previously validated state after a failed local
    /// selection save, including its binding mirrors. Released holds are not
    /// recreated and no effects are emitted.
    pub fn restore_state_after_failed_local_selection(&mut self, previous: PersistentState) {
        self.state = previous;
    }

    /// Install a configuration state that the host adapter already validated
    /// and durably persisted. This step is intentionally infallible so disk and
    /// live state cannot diverge after the atomic rename succeeds.
    pub fn install_validated_persisted_state(&mut self, state: PersistentState) -> Vec<Effect> {
        let before = self.status();
        let mut effects = Vec::new();
        self.release_all_and_notify_client(&mut effects);
        self.state = state;
        if let Some(connection_id) = self
            .active_client
            .as_ref()
            .map(|client| client.connection_id)
        {
            effects.push(Effect::SendMessage {
                connection_id,
                message: Box::new(
                    self.profile_state_message(ControllerMessageType::GamepadProfiles),
                ),
            });
        }
        self.append_status_if_changed(before, &mut effects);
        effects
    }

    pub fn disconnect(&mut self, connection_id: ConnectionId) -> Vec<Effect> {
        let before = self.status();
        let mut effects = Vec::new();
        if self
            .active_client
            .as_ref()
            .is_some_and(|active| active.connection_id == connection_id)
        {
            self.release_all_internal(&mut effects);
            self.active_client = None;
            self.reset_input_session();
        }
        if self
            .pending_pairing
            .as_ref()
            .is_some_and(|pending| pending.connection_id == connection_id)
        {
            self.pending_pairing = None;
        }
        self.append_status_if_changed(before, &mut effects);
        effects
    }

    /// Expire individual physical press references, pointer buttons, and analog
    /// axes not refreshed within `maximum_age_millis`.
    pub fn expire_holds(&mut self, now_millis: i64, maximum_age_millis: i64) -> Vec<Effect> {
        let before = self.status();
        let mut effects = Vec::new();
        if self
            .pending_pairing
            .as_ref()
            .is_some_and(|pending| now_millis >= pending.expires_at_millis)
        {
            if let Some(pending) = self.pending_pairing.take() {
                self.send_error(
                    pending.connection_id,
                    "Pairing request expired. Request pairing again.",
                    &mut effects,
                );
                effects.push(Effect::CloseConnection {
                    connection_id: pending.connection_id,
                    reason: "Pairing request expired".to_owned(),
                });
            }
        }
        let mut identities = self.physical_holds.keys().cloned().collect::<Vec<_>>();
        identities.sort_by_key(InputIdentity::sort_key);

        for identity in identities {
            let maximum_age_millis = if matches!(identity, InputIdentity::LocalControl(_)) {
                30_000
            } else {
                maximum_age_millis
            };
            let mut removed_count = 0_u64;
            let mut binding_to_release = None;
            let mut remove_identity = false;
            if let Some(hold) = self.physical_holds.get_mut(&identity) {
                hold.identified_last_seen.retain(|_, last_seen| {
                    let keep = !has_expired(now_millis, *last_seen, maximum_age_millis);
                    if !keep {
                        removed_count = removed_count.saturating_add(1);
                    }
                    keep
                });
                if hold
                    .anonymous_last_seen
                    .is_some_and(|last_seen| has_expired(now_millis, last_seen, maximum_age_millis))
                {
                    hold.anonymous_last_seen = None;
                    removed_count = removed_count.saturating_add(1);
                }
                if !hold.is_held() {
                    binding_to_release = hold.binding.clone();
                    remove_identity = true;
                }
            }
            self.counters.expired_holds = self.counters.expired_holds.saturating_add(removed_count);
            if remove_identity {
                self.physical_holds.remove(&identity);
                if let Some(binding) = binding_to_release {
                    self.deactivate_binding(&binding, &mut effects);
                }
            }
        }

        for button in pointer_buttons() {
            let should_expire = self
                .pointer_button_last_seen
                .get(&button)
                .is_some_and(|last_seen| has_expired(now_millis, *last_seen, maximum_age_millis));
            if should_expire {
                self.pointer_button_last_seen.remove(&button);
                self.counters.expired_holds = self.counters.expired_holds.saturating_add(1);
                effects.push(Effect::PointerButton {
                    button,
                    pressed: false,
                });
            }
        }

        for (target, axis) in &mut self.analog_axes {
            if axis
                .last_seen
                .is_some_and(|last_seen| has_expired(now_millis, last_seen, maximum_age_millis))
            {
                axis.last_seen = None;
                self.counters.expired_holds = self.counters.expired_holds.saturating_add(1);
                effects.push(neutral_analog_effect(*target));
            }
        }

        self.append_status_if_changed(before, &mut effects);
        effects
    }

    fn handle_pairing_request(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        now_millis: i64,
        tokens: &mut impl TokenSource,
        effects: &mut Vec<Effect>,
    ) -> Result<(), CoreError> {
        if self
            .active_client
            .as_ref()
            .is_some_and(|active| active.connection_id != connection_id)
        {
            self.reject_connection(
                connection_id,
                "Another client is already active",
                true,
                effects,
            );
            return Ok(());
        }

        if self
            .pending_pairing
            .as_ref()
            .is_some_and(|pending| now_millis >= pending.expires_at_millis)
        {
            self.pending_pairing = None;
        }
        if let Some(pending) = &self.pending_pairing {
            if pending.connection_id != connection_id {
                self.reject_connection(
                    connection_id,
                    "Another pairing request is already pending",
                    true,
                    effects,
                );
            } else {
                effects.push(Effect::SendMessage {
                    connection_id,
                    message: Box::new(pairing_challenge_message()),
                });
            }
            return Ok(());
        }

        let new_code = tokens.next_pairing_code();
        if !is_pairing_code(&new_code) {
            return Err(CoreError::InvalidPairingCodeGenerated);
        }
        self.pairing_code = new_code;
        let name = self.safe_client_name(message.client_name.as_deref(), None, None);
        self.pending_pairing = Some(PendingPairing {
            connection_id,
            name,
            expires_at_millis: now_millis.saturating_add(PAIRING_REQUEST_LIFETIME_MILLIS),
        });
        effects.push(Effect::SendMessage {
            connection_id,
            message: Box::new(pairing_challenge_message()),
        });
        Ok(())
    }

    fn handle_hello(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        time: CoreTime,
        tokens: &mut impl TokenSource,
        effects: &mut Vec<Effect>,
    ) -> Result<(), CoreError> {
        if let Some(token) = normalized_token(message.auth_token.as_deref()) {
            if message.server_id.as_deref() != Some(self.state.server_id.as_str()) {
                self.reject_connection(connection_id, "Wrong server ID", true, effects);
                return Ok(());
            }

            if self
                .active_client
                .as_ref()
                .is_some_and(|active| active.auth_token != token)
            {
                self.reject_connection(
                    connection_id,
                    "Another client is already active",
                    true,
                    effects,
                );
                return Ok(());
            }

            let Some(existing) = self.state.trusted_clients.get(token).cloned() else {
                self.reject_connection(
                    connection_id,
                    "Trusted pairing expired. Request pairing again from Thumble Host.",
                    true,
                    effects,
                );
                return Ok(());
            };
            let name = self.safe_client_name(
                message.client_name.as_deref(),
                Some(existing.name.as_str()),
                Some(token),
            );
            self.accept_client(
                connection_id,
                token.to_owned(),
                name,
                time.unix_millis,
                true,
                effects,
            );
            return Ok(());
        }

        if self
            .active_client
            .as_ref()
            .is_some_and(|active| active.connection_id != connection_id)
        {
            self.reject_connection(
                connection_id,
                "Another client is already active",
                true,
                effects,
            );
            return Ok(());
        }

        if self
            .pending_pairing
            .as_ref()
            .is_some_and(|pending| time.monotonic_millis >= pending.expires_at_millis)
        {
            let expired = self.pending_pairing.take();
            if expired
                .as_ref()
                .is_some_and(|pending| pending.connection_id == connection_id)
            {
                self.reject_connection(
                    connection_id,
                    "Pairing request expired. Request pairing again.",
                    true,
                    effects,
                );
                return Ok(());
            }
        }

        if time.monotonic_millis < self.pairing_blocked_until_millis {
            self.reject_connection(
                connection_id,
                "Pairing is temporarily rate limited. Try again shortly.",
                true,
                effects,
            );
            return Ok(());
        }

        let Some(submitted_code) = normalized_pairing_code(message.pairing_code.as_deref()) else {
            self.reject_connection(connection_id, "Pairing code is required", true, effects);
            return Ok(());
        };
        if submitted_code != self.pairing_code {
            self.record_pairing_failure(time.monotonic_millis);
            self.reject_connection(connection_id, "Wrong pairing code", true, effects);
            if self
                .pending_pairing
                .as_ref()
                .is_some_and(|pending| pending.connection_id == connection_id)
            {
                self.pending_pairing = None;
            }
            return Ok(());
        }
        if self
            .pending_pairing
            .as_ref()
            .is_some_and(|pending| pending.connection_id != connection_id)
        {
            self.reject_connection(
                connection_id,
                "Pairing code belongs to another connection",
                true,
                effects,
            );
            return Ok(());
        }

        self.pairing_failure_count = 0;
        self.pairing_blocked_until_millis = 0;
        let token = self.generate_unique_auth_token(tokens)?;
        let name = self.safe_client_name(message.client_name.as_deref(), None, Some(&token));
        self.accept_client(connection_id, token, name, time.unix_millis, false, effects);
        Ok(())
    }

    fn accept_client(
        &mut self,
        connection_id: ConnectionId,
        token: String,
        name: String,
        now_millis: i64,
        trusted_reconnect: bool,
        effects: &mut Vec<Effect>,
    ) {
        if let Some(previous) = self.active_client.take() {
            self.release_all_internal(effects);
            self.reset_input_session();
            if previous.connection_id != connection_id {
                effects.push(Effect::CloseConnection {
                    connection_id: previous.connection_id,
                    reason: "Replaced by trusted reconnect".to_owned(),
                });
            }
        }
        if let Some(previous) = self.pending_pairing.take() {
            if previous.connection_id != connection_id {
                self.send_error(
                    previous.connection_id,
                    "Pairing request was superseded by a trusted client",
                    effects,
                );
                effects.push(Effect::CloseConnection {
                    connection_id: previous.connection_id,
                    reason: "Pairing superseded".to_owned(),
                });
            }
        }

        let created_at = self
            .state
            .trusted_clients
            .get(&token)
            .map_or(now_millis, |client| client.created_at);
        self.state.trusted_clients.insert(
            token.clone(),
            TrustedClient {
                name: name.clone(),
                created_at,
                last_seen_at: now_millis,
            },
        );
        self.active_client = Some(ActiveClient {
            connection_id,
            auth_token: token.clone(),
            name,
        });
        self.reset_input_session();

        // Persistence precedes acceptance so an adapter can durably save a new
        // token before the client receives it.
        effects.push(Effect::PersistState);
        effects.push(Effect::SendMessage {
            connection_id,
            message: Box::new(self.pairing_accepted_message(
                token,
                if trusted_reconnect {
                    "Trusted reconnect complete"
                } else {
                    "Pairing complete"
                },
            )),
        });
    }

    fn pairing_accepted_message(&self, token: String, text: &str) -> ControllerMessage {
        let mut accepted = ControllerMessage::new(ControllerMessageType::PairingAccepted, 0);
        accepted.message = Some(text.to_owned());
        accepted.auth_token = Some(token);
        accepted.server_id = Some(self.state.server_id.clone());
        accepted.gamepad_customization = Some(self.state.active_customization());
        accepted.gamepad_profiles = Some(self.state.profiles.clone());
        accepted.binding_presentations = Some(Vec::new());
        accepted.gamepad_profile_id = Some(self.state.active_profile_id.clone());
        accepted.default_gamepad_profile_id = Some(self.state.default_profile_id.clone());
        accepted.capabilities = Some(Vec::new());
        accepted.input_protocol_version = Some(ControllerWireCodec::CURRENT_INPUT_PROTOCOL_VERSION);
        // No realtime token: the current iOS client intentionally falls back to
        // reliable WebSocket input for this milestone.
        accepted
    }

    fn handle_digital_input(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        now_millis: i64,
        effects: &mut Vec<Effect>,
    ) {
        if self.accept_generation(connection_id, message, effects) == GenerationAcceptance::Rejected
        {
            return;
        }
        if !self.accept_sequence(connection_id, message, SequenceStream::Digital, effects) {
            return;
        }

        let Some(state) = message.state else {
            self.reject_input(connection_id, "Input state is required", effects);
            return;
        };
        let press_identifier = ControllerWireCodec::input_press_identifier(message);
        let (identity, binding) = match message.message_type {
            ControllerMessageType::Button => {
                let Some(button) = message.button else {
                    self.reject_input(connection_id, "Button is required", effects);
                    return;
                };
                (
                    InputIdentity::Button(button),
                    self.state.resolve_button_output(button),
                )
            }
            ControllerMessageType::ElementInput => {
                let Some(element_id) = message.element_id.as_deref() else {
                    self.reject_input(connection_id, "Element ID is required", effects);
                    return;
                };
                if element_id.trim().is_empty() {
                    self.reject_input(connection_id, "Element ID is required", effects);
                    return;
                }
                let part = message
                    .element_part
                    .unwrap_or(KeypadElementInputPart::Primary);
                (
                    InputIdentity::Element {
                        element_id: element_id.to_owned(),
                        part,
                    },
                    self.state.resolve_element_output(element_id, part),
                )
            }
            _ => return,
        };

        self.counters.accepted_inputs = self.counters.accepted_inputs.saturating_add(1);
        match state {
            ButtonPressState::Down => {
                self.physical_down(identity, press_identifier, binding, now_millis, effects)
            }
            ButtonPressState::Up => {
                self.physical_up(&identity, press_identifier, effects);
            }
        }
    }

    fn handle_gamepad_analog(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        now_millis: i64,
        effects: &mut Vec<Effect>,
    ) {
        if self.accept_generation(connection_id, message, effects) == GenerationAcceptance::Rejected
        {
            return;
        }
        let (target, effect, active) = match (message.analog_stick, message.analog_trigger) {
            (Some(stick), None) => {
                let (Some(x), Some(y)) = (message.analog_x, message.analog_y) else {
                    self.reject_input(
                        connection_id,
                        "Analog stick coordinates are required",
                        effects,
                    );
                    return;
                };
                if !x.is_finite() || !y.is_finite() || message.analog_value.is_some() {
                    self.reject_input(connection_id, "Malformed analog stick coordinates", effects);
                    return;
                }
                let (x, y) = (x.clamp(-1.0, 1.0), y.clamp(-1.0, 1.0));
                (
                    AnalogTarget::from(stick),
                    Effect::GamepadStick { stick, x, y },
                    x != 0.0 || y != 0.0,
                )
            }
            (None, Some(trigger)) => {
                let Some(value) = message.analog_value else {
                    self.reject_input(connection_id, "Analog trigger value is required", effects);
                    return;
                };
                if !value.is_finite() || message.analog_x.is_some() || message.analog_y.is_some() {
                    self.reject_input(connection_id, "Malformed analog trigger value", effects);
                    return;
                }
                let value = value.clamp(0.0, 1.0);
                (
                    AnalogTarget::from(trigger),
                    Effect::GamepadTrigger { trigger, value },
                    value != 0.0,
                )
            }
            _ => {
                self.reject_input(
                    connection_id,
                    "Exactly one analog target is required",
                    effects,
                );
                return;
            }
        };
        if self.active_generation.is_some() && message.analog_sequence.is_none() {
            self.reject_input(connection_id, "Analog sequence is required", effects);
            return;
        }
        if message.analog_sequence.is_some_and(|sequence| {
            sequence == 0 || sequence > ControllerWireCodec::MAXIMUM_BUTTON_SEQUENCE_NUMBER
        }) {
            self.reject_input(
                connection_id,
                "Analog sequence is outside the compact range",
                effects,
            );
            return;
        }
        if self.state.gamepad_output_disabled() {
            self.counters.ignored_inputs = self.counters.ignored_inputs.saturating_add(1);
            return;
        }
        let axis = self.analog_axes.entry(target).or_default();
        if let Some(sequence) = message.analog_sequence {
            // Only a positive modular forward distance of at most half a cycle
            // is newer. Delayed pre-wrap packets must not restore old movement.
            if axis.last_sequence.is_some_and(|last| {
                let maximum = ControllerWireCodec::MAXIMUM_BUTTON_SEQUENCE_NUMBER;
                let distance = if sequence >= last {
                    sequence - last
                } else {
                    maximum - last + sequence
                };
                distance == 0 || distance > maximum / 2
            }) {
                self.counters.duplicate_sequences =
                    self.counters.duplicate_sequences.saturating_add(1);
                return;
            }
            axis.last_sequence = Some(sequence);
        }
        // Analog heartbeat repeats arrive as separate GamepadAnalog messages;
        // a general heartbeat must not prolong a lost final-neutral packet.
        axis.last_seen = active.then_some(now_millis);
        self.counters.accepted_inputs = self.counters.accepted_inputs.saturating_add(1);
        effects.push(effect);
    }

    fn handle_pointer_input(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        now_millis: i64,
        effects: &mut Vec<Effect>,
    ) {
        if self.accept_generation(connection_id, message, effects) == GenerationAcceptance::Rejected
        {
            return;
        }
        if !self.accept_sequence(connection_id, message, SequenceStream::Pointer, effects) {
            return;
        }
        let Some(event) = message.pointer_event else {
            self.reject_input(connection_id, "Pointer event kind is required", effects);
            return;
        };
        let delta_x = message.delta_x.unwrap_or(0.0);
        let delta_y = message.delta_y.unwrap_or(0.0);
        if !delta_x.is_finite() || !delta_y.is_finite() {
            self.reject_input(connection_id, "Pointer deltas must be finite", effects);
            return;
        }

        match event {
            ControllerPointerEventKind::Move => {
                effects.push(Effect::PointerMove { delta_x, delta_y });
            }
            ControllerPointerEventKind::Scroll => {
                effects.push(Effect::PointerScroll { delta_x, delta_y });
            }
            ControllerPointerEventKind::Button => {
                let (Some(button), Some(state)) = (message.pointer_button, message.state) else {
                    self.reject_input(
                        connection_id,
                        "Pointer button and state are required",
                        effects,
                    );
                    return;
                };
                match state {
                    ButtonPressState::Down => {
                        let was_held = self
                            .pointer_button_last_seen
                            .insert(button, now_millis)
                            .is_some();
                        if was_held {
                            self.counters.ignored_inputs =
                                self.counters.ignored_inputs.saturating_add(1);
                        } else {
                            effects.push(Effect::PointerButton {
                                button,
                                pressed: true,
                            });
                        }
                    }
                    ButtonPressState::Up => {
                        if self.pointer_button_last_seen.remove(&button).is_some() {
                            effects.push(Effect::PointerButton {
                                button,
                                pressed: false,
                            });
                        } else {
                            self.counters.ignored_inputs =
                                self.counters.ignored_inputs.saturating_add(1);
                        }
                    }
                }
            }
        }
        self.counters.accepted_inputs = self.counters.accepted_inputs.saturating_add(1);
    }

    fn handle_release_all(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        effects: &mut Vec<Effect>,
    ) {
        match self.accept_generation(connection_id, message, effects) {
            GenerationAcceptance::Rejected | GenerationAcceptance::Transitioned => {}
            GenerationAcceptance::Legacy
            | GenerationAcceptance::Initial
            | GenerationAcceptance::Current => self.release_all_internal(effects),
        }
    }

    fn handle_heartbeat(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        now_millis: i64,
        effects: &mut Vec<Effect>,
    ) {
        if self.accept_generation(connection_id, message, effects) != GenerationAcceptance::Rejected
        {
            for last_seen in self.pointer_button_last_seen.values_mut() {
                *last_seen = now_millis;
            }
        }
    }

    fn handle_profile_message(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        effects: &mut Vec<Effect>,
    ) {
        match message.message_type {
            ControllerMessageType::GamepadProfileSelection => {
                let Some(profile_id) = message.gamepad_profile_id.as_deref() else {
                    self.send_diagnostic(connection_id, "Profile ID is required", effects);
                    return;
                };
                if self.select_profile_internal(profile_id, effects).is_err() {
                    self.send_diagnostic(connection_id, "Selected profile does not exist", effects);
                }
            }
            ControllerMessageType::GamepadDefaultProfile => {
                let Some(profile_id) = message
                    .default_gamepad_profile_id
                    .as_deref()
                    .or(message.gamepad_profile_id.as_deref())
                else {
                    self.send_diagnostic(connection_id, "Default profile ID is required", effects);
                    return;
                };
                let Some(profile_id) = self
                    .state
                    .canonical_profile_id(profile_id)
                    .map(str::to_owned)
                else {
                    self.send_diagnostic(connection_id, "Default profile does not exist", effects);
                    return;
                };
                if self.state.default_profile_id != profile_id {
                    if self.state.bump_configuration_revision().is_err() {
                        self.send_diagnostic(
                            connection_id,
                            "Configuration revision is exhausted",
                            effects,
                        );
                        return;
                    }
                    self.state.default_profile_id = profile_id;
                    effects.push(Effect::PersistState);
                }
                effects.push(Effect::SendMessage {
                    connection_id,
                    message: Box::new(
                        self.profile_state_message(ControllerMessageType::GamepadProfiles),
                    ),
                });
            }
            ControllerMessageType::GamepadProfiles => {
                if message.gamepad_profiles.is_some() {
                    self.send_diagnostic(
                        connection_id,
                        "Replacing the profile array is not supported by this host",
                        effects,
                    );
                    return;
                }
                effects.push(Effect::SendMessage {
                    connection_id,
                    message: Box::new(
                        self.profile_state_message(ControllerMessageType::GamepadProfiles),
                    ),
                });
            }
            ControllerMessageType::GamepadCustomization => {
                let Some(customization) = message.gamepad_customization.as_ref() else {
                    effects.push(Effect::SendMessage {
                        connection_id,
                        message: Box::new(
                            self.profile_state_message(ControllerMessageType::GamepadCustomization),
                        ),
                    });
                    return;
                };
                if !customization.is_object() {
                    self.send_diagnostic(
                        connection_id,
                        "Customization must be a JSON object",
                        effects,
                    );
                    return;
                }
                if message
                    .gamepad_profile_id
                    .as_deref()
                    .is_some_and(|profile_id| {
                        !self
                            .state
                            .active_profile_id
                            .eq_ignore_ascii_case(profile_id)
                    })
                {
                    self.send_diagnostic(
                        connection_id,
                        "Only the active profile customization can be replaced",
                        effects,
                    );
                    return;
                }

                let active_profile_id = self.state.active_profile_id.clone();
                if self
                    .state
                    .profile(&active_profile_id)
                    .and_then(Value::as_object)
                    .is_none()
                {
                    self.send_diagnostic(connection_id, "Active profile is malformed", effects);
                    return;
                }
                let mut candidate_profile = self.state.profile(&active_profile_id).unwrap().clone();
                candidate_profile["customization"] = customization.clone();
                if !crate::validate_element_identities(&candidate_profile) {
                    self.send_diagnostic(
                        connection_id,
                        "Customization must declare unique element UUIDs and valid references; obsolete input-slot setups are not supported",
                        effects,
                    );
                    return;
                }
                if self.state.bump_configuration_revision().is_err() {
                    self.send_diagnostic(
                        connection_id,
                        "Configuration revision is exhausted",
                        effects,
                    );
                    return;
                }
                self.release_all_internal(effects);
                let profile = self
                    .state
                    .profile_mut(&active_profile_id)
                    .and_then(Value::as_object_mut)
                    .expect("active profile shape was validated above");
                profile.insert("customization".to_owned(), customization.clone());
                self.state.reconcile_active_profile_binding_maps();
                effects.push(Effect::PersistState);
                effects.push(Effect::SendMessage {
                    connection_id,
                    message: Box::new(
                        self.profile_state_message(ControllerMessageType::GamepadCustomization),
                    ),
                });
            }
            _ => {}
        }
    }

    fn select_profile_internal(
        &mut self,
        profile_id: &str,
        effects: &mut Vec<Effect>,
    ) -> Result<(), LocalControlError> {
        let profile_id = self
            .state
            .canonical_profile_id(profile_id)
            .map(str::to_owned)
            .ok_or(LocalControlError::ProfileNotFound)?;
        if self.state.active_profile_id != profile_id {
            self.state
                .bump_configuration_revision()
                .map_err(|_| LocalControlError::ConfigurationRevisionExhausted)?;
            self.release_all_and_notify_client(effects);
            self.state.active_profile_id = profile_id;
            self.state.refresh_global_binding_mirrors();
            effects.push(Effect::PersistState);
        }
        if let Some(connection_id) = self
            .active_client
            .as_ref()
            .map(|client| client.connection_id)
        {
            effects.push(Effect::SendMessage {
                connection_id,
                message: Box::new(
                    self.profile_state_message(ControllerMessageType::GamepadProfiles),
                ),
            });
        }
        Ok(())
    }

    fn profile_state_message(&self, message_type: ControllerMessageType) -> ControllerMessage {
        let mut response = ControllerMessage::new(message_type, 0);
        response.gamepad_customization = Some(self.state.active_customization());
        response.gamepad_profiles = Some(self.state.profiles.clone());
        response.binding_presentations = Some(Vec::new());
        response.gamepad_profile_id = Some(self.state.active_profile_id.clone());
        response.default_gamepad_profile_id = Some(self.state.default_profile_id.clone());
        response.capabilities = Some(Vec::new());
        response
    }

    fn accept_generation(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        effects: &mut Vec<Effect>,
    ) -> GenerationAcceptance {
        let Some(generation) = message.input_generation else {
            if self.active_generation.is_some()
                || message.input_protocol_version
                    == Some(ControllerWireCodec::CURRENT_INPUT_PROTOCOL_VERSION)
            {
                self.reject_generation(connection_id, "Missing input generation", effects);
                return GenerationAcceptance::Rejected;
            }
            if message
                .input_protocol_version
                .is_some_and(|version| version != 1)
            {
                self.reject_generation(connection_id, "Unsupported input protocol", effects);
                return GenerationAcceptance::Rejected;
            }
            return GenerationAcceptance::Legacy;
        };

        if message.input_protocol_version
            != Some(ControllerWireCodec::CURRENT_INPUT_PROTOCOL_VERSION)
        {
            self.reject_generation(connection_id, "Unsupported input protocol", effects);
            return GenerationAcceptance::Rejected;
        }

        let Some(current) = self.active_generation else {
            self.active_generation = Some(generation);
            self.retired_generations
                .retain(|retired| *retired != generation);
            self.reset_sequences();
            return GenerationAcceptance::Initial;
        };
        if current == generation {
            return GenerationAcceptance::Current;
        }
        if self.retired_generations.contains(&generation) {
            self.counters.stale_generations = self.counters.stale_generations.saturating_add(1);
            self.reject_generation(connection_id, "Retired input generation", effects);
            return GenerationAcceptance::Rejected;
        }

        let expected = if current == u64::MAX { 1 } else { current + 1 };
        if generation != expected {
            self.counters.stale_generations = self.counters.stale_generations.saturating_add(1);
            self.reject_generation(connection_id, "Unexpected input generation", effects);
            return GenerationAcceptance::Rejected;
        }

        self.retired_generations.push_back(current);
        if self.retired_generations.len() > 64 {
            self.retired_generations.pop_front();
        }
        self.active_generation = Some(generation);
        self.release_all_internal(effects);
        self.reset_sequences();
        GenerationAcceptance::Transitioned
    }

    fn accept_sequence(
        &mut self,
        connection_id: ConnectionId,
        message: &ControllerMessage,
        stream: SequenceStream,
        effects: &mut Vec<Effect>,
    ) -> bool {
        let sequence = ControllerWireCodec::input_sequence_number(message);
        if self.active_generation.is_some() && sequence.is_none() {
            self.reject_input(connection_id, "Input sequence is required", effects);
            return false;
        }
        let Some(sequence) = sequence else {
            return true;
        };
        let last = match stream {
            SequenceStream::Digital => &mut self.last_digital_sequence,
            SequenceStream::Pointer => &mut self.last_pointer_sequence,
        };
        if last.is_some_and(|last| sequence <= last) {
            self.counters.duplicate_sequences = self.counters.duplicate_sequences.saturating_add(1);
            return false;
        }
        *last = Some(sequence);
        true
    }

    fn reject_generation(
        &mut self,
        connection_id: ConnectionId,
        reason: &str,
        effects: &mut Vec<Effect>,
    ) {
        self.counters.rejected_inputs = self.counters.rejected_inputs.saturating_add(1);
        self.send_diagnostic(connection_id, reason, effects);
    }

    fn reject_input(
        &mut self,
        connection_id: ConnectionId,
        reason: &str,
        effects: &mut Vec<Effect>,
    ) {
        self.counters.rejected_inputs = self.counters.rejected_inputs.saturating_add(1);
        self.send_diagnostic(connection_id, reason, effects);
    }

    fn physical_down(
        &mut self,
        identity: InputIdentity,
        press_identifier: Option<u64>,
        binding: Option<OutputBinding>,
        now_millis: i64,
        effects: &mut Vec<Effect>,
    ) {
        let was_held = self
            .physical_holds
            .get(&identity)
            .is_some_and(PhysicalHold::is_held);
        let hold = self.physical_holds.entry(identity).or_default();
        let was_reference_present = match press_identifier {
            Some(identifier) => hold
                .identified_last_seen
                .insert(identifier, now_millis)
                .is_some(),
            None => hold.anonymous_last_seen.replace(now_millis).is_some(),
        };
        let active_binding = hold.binding.clone();
        if was_reference_present {
            self.counters.ignored_inputs = self.counters.ignored_inputs.saturating_add(1);
            return;
        }
        if was_held {
            if let Some(binding) = active_binding {
                self.pulse_binding(&binding, effects);
            }
            return;
        }
        hold.binding = binding.clone();
        if let Some(binding) = binding {
            self.activate_binding(&binding, effects);
        }
    }

    fn physical_up(
        &mut self,
        identity: &InputIdentity,
        press_identifier: Option<u64>,
        effects: &mut Vec<Effect>,
    ) {
        let mut removed_reference = false;
        let mut binding_to_release = None;
        let mut remove_identity = false;
        if let Some(hold) = self.physical_holds.get_mut(identity) {
            removed_reference = match press_identifier {
                Some(identifier) => hold.identified_last_seen.remove(&identifier).is_some(),
                None => hold.anonymous_last_seen.take().is_some(),
            };
            if removed_reference && !hold.is_held() {
                binding_to_release = hold.binding.clone();
                remove_identity = true;
            }
        }
        if !removed_reference {
            self.counters.ignored_inputs = self.counters.ignored_inputs.saturating_add(1);
            return;
        }
        if remove_identity {
            self.physical_holds.remove(identity);
            if let Some(binding) = binding_to_release {
                self.deactivate_binding(&binding, effects);
            }
        }
    }

    fn activate_binding(&mut self, binding: &OutputBinding, effects: &mut Vec<Effect>) {
        if let Some(keyboard) = &binding.keyboard {
            if keyboard.is_sequence() {
                effects.push(Effect::TapSequence(keyboard.strokes()));
            } else {
                let held = keyboard.canonical_held_binding();
                let count = self.held_key_counts.entry(held.clone()).or_default();
                if *count == 0 {
                    effects.push(Effect::KeyDown(held));
                }
                *count = count.saturating_add(1);
            }
        }
        for button in binding.supported_gamepad_buttons() {
            let count = self.held_gamepad_counts.entry(button).or_default();
            if *count == 0 {
                effects.push(Effect::GamepadButton {
                    button,
                    pressed: true,
                });
            }
            *count = count.saturating_add(1);
        }
    }

    fn pulse_binding(&self, binding: &OutputBinding, effects: &mut Vec<Effect>) {
        let Some(keyboard) = &binding.keyboard else {
            return;
        };
        if keyboard.is_sequence() {
            effects.push(Effect::TapSequence(keyboard.strokes()));
            return;
        }
        let held = keyboard.canonical_held_binding();
        if self.held_key_counts.get(&held) == Some(&1) {
            effects.push(Effect::PulseKey(held));
        }
    }

    fn deactivate_binding(&mut self, binding: &OutputBinding, effects: &mut Vec<Effect>) {
        if let Some(keyboard) = binding
            .keyboard
            .as_ref()
            .filter(|keyboard| !keyboard.is_sequence())
        {
            let held = keyboard.canonical_held_binding();
            if let Some(count) = self.held_key_counts.get_mut(&held) {
                if *count <= 1 {
                    self.held_key_counts.remove(&held);
                    effects.push(Effect::KeyUp(held));
                } else {
                    *count -= 1;
                }
            }
        }
        for button in binding.supported_gamepad_buttons() {
            if let Some(count) = self.held_gamepad_counts.get_mut(&button) {
                if *count <= 1 {
                    self.held_gamepad_counts.remove(&button);
                    effects.push(Effect::GamepadButton {
                        button,
                        pressed: false,
                    });
                } else {
                    *count -= 1;
                }
            }
        }
    }

    fn release_all_and_notify_client(&mut self, effects: &mut Vec<Effect>) {
        self.release_all_internal(effects);
        let Some(connection_id) = self
            .active_client
            .as_ref()
            .map(|client| client.connection_id)
        else {
            return;
        };
        let mut message = ControllerMessage::new(ControllerMessageType::ReleaseAll, 0);
        if let Some(generation) = self.active_generation {
            let next = if generation == u64::MAX {
                1
            } else {
                generation + 1
            };
            self.retired_generations.push_back(generation);
            if self.retired_generations.len() > 64 {
                self.retired_generations.pop_front();
            }
            self.active_generation = Some(next);
            self.reset_sequences();
            message.input_protocol_version =
                Some(ControllerWireCodec::CURRENT_INPUT_PROTOCOL_VERSION);
            message.input_generation = Some(next);
        }
        effects.push(Effect::SendMessage {
            connection_id,
            message: Box::new(message),
        });
    }

    fn release_all_internal(&mut self, effects: &mut Vec<Effect>) {
        self.counters.release_all_events = self.counters.release_all_events.saturating_add(1);
        for binding in self.held_key_counts.keys().cloned().collect::<Vec<_>>() {
            effects.push(Effect::KeyUp(binding));
        }
        for button in pointer_buttons() {
            if self.pointer_button_last_seen.contains_key(&button) {
                effects.push(Effect::PointerButton {
                    button,
                    pressed: false,
                });
            }
        }
        for button in self.held_gamepad_counts.keys() {
            effects.push(Effect::GamepadButton {
                button: *button,
                pressed: false,
            });
        }
        if !self.held_gamepad_counts.is_empty()
            || self
                .analog_axes
                .values()
                .any(|axis| axis.last_seen.is_some())
            || self.needs_virtual_gamepad()
        {
            effects.push(Effect::GamepadReset);
        }
        self.physical_holds.clear();
        self.held_key_counts.clear();
        self.held_gamepad_counts.clear();
        for axis in self.analog_axes.values_mut() {
            axis.last_seen = None;
        }
        self.pointer_button_last_seen.clear();
    }

    fn reset_input_session(&mut self) {
        self.active_generation = None;
        self.retired_generations.clear();
        self.reset_sequences();
    }

    fn reset_sequences(&mut self) {
        self.last_digital_sequence = None;
        self.last_pointer_sequence = None;
        // Establishing v2 must not forget an unexpired legacy analog hold.
        // Lifecycle releases neutralize axes separately from sequence resets.
        for axis in self.analog_axes.values_mut() {
            axis.last_sequence = None;
        }
    }

    fn is_authenticated(&self, connection_id: ConnectionId) -> bool {
        self.active_client
            .as_ref()
            .is_some_and(|active| active.connection_id == connection_id)
    }

    fn reject_connection(
        &mut self,
        connection_id: ConnectionId,
        reason: &str,
        close: bool,
        effects: &mut Vec<Effect>,
    ) {
        self.counters.pairing_rejections = self.counters.pairing_rejections.saturating_add(1);
        self.send_error(connection_id, reason, effects);
        if close {
            effects.push(Effect::CloseConnection {
                connection_id,
                reason: reason.to_owned(),
            });
        }
    }

    fn send_diagnostic(
        &self,
        connection_id: ConnectionId,
        message: &str,
        effects: &mut Vec<Effect>,
    ) {
        effects.push(Effect::Diagnostic {
            connection_id,
            message: message.to_owned(),
        });
    }

    fn send_error(&self, connection_id: ConnectionId, reason: &str, effects: &mut Vec<Effect>) {
        let mut error = ControllerMessage::new(ControllerMessageType::Error, 0);
        error.message = Some(reason.to_owned());
        effects.push(Effect::SendMessage {
            connection_id,
            message: Box::new(error),
        });
    }

    fn record_pairing_failure(&mut self, now_millis: i64) {
        self.pairing_failure_count = self.pairing_failure_count.saturating_add(1);
        let exponent = self.pairing_failure_count.saturating_sub(1).min(5);
        let multiplier = 1_i64 << exponent;
        let delay_millis = 250_i64.saturating_mul(multiplier);
        self.pairing_blocked_until_millis = self
            .pairing_blocked_until_millis
            .max(now_millis.saturating_add(delay_millis));
    }

    fn generate_unique_auth_token(
        &self,
        tokens: &mut impl TokenSource,
    ) -> Result<String, CoreError> {
        for _ in 0..16 {
            let raw_token = tokens.next_auth_token();
            let Some(token) = normalized_token(Some(&raw_token)).map(str::to_owned) else {
                return Err(CoreError::InvalidAuthTokenGenerated);
            };
            if !self.state.trusted_clients.contains_key(&token) {
                return Ok(token);
            }
        }
        Err(CoreError::AuthTokenCollision)
    }

    fn safe_status_value(&self, value: &str) -> String {
        if self
            .state
            .trusted_clients
            .keys()
            .any(|token| !token.is_empty() && value.contains(token))
        {
            "[REDACTED]".to_owned()
        } else {
            value.to_owned()
        }
    }

    fn safe_client_name(
        &self,
        proposed: Option<&str>,
        fallback: Option<&str>,
        additional_token: Option<&str>,
    ) -> String {
        let candidate = proposed
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .or(fallback.map(str::trim))
            .filter(|name| !name.is_empty())
            .unwrap_or("Client");
        let exposes_known_token = self
            .state
            .trusted_clients
            .keys()
            .any(|token| !token.is_empty() && candidate.contains(token));
        let exposes_additional_token = additional_token
            .filter(|token| !token.is_empty())
            .is_some_and(|token| candidate.contains(token));
        if exposes_known_token || exposes_additional_token {
            "Client".to_owned()
        } else {
            candidate.to_owned()
        }
    }

    fn append_status_if_changed(&self, before: StatusSnapshot, effects: &mut Vec<Effect>) {
        let after = self.status();
        if after != before {
            effects.push(Effect::StatusChanged(Box::new(after)));
        }
    }
}

fn pairing_challenge_message() -> ControllerMessage {
    let mut challenge = ControllerMessage::new(ControllerMessageType::PairingChallenge, 0);
    challenge.message =
        Some("Pairing request accepted. Enter the code shown on the host.".to_owned());
    challenge
}

fn pointer_buttons() -> [ControllerPointerButton; 3] {
    [
        ControllerPointerButton::Left,
        ControllerPointerButton::Right,
        ControllerPointerButton::Middle,
    ]
}

fn neutral_analog_effect(target: AnalogTarget) -> Effect {
    match target {
        AnalogTarget::LeftStick => Effect::GamepadStick {
            stick: VirtualGamepadStick::Left,
            x: 0.0,
            y: 0.0,
        },
        AnalogTarget::RightStick => Effect::GamepadStick {
            stick: VirtualGamepadStick::Right,
            x: 0.0,
            y: 0.0,
        },
        AnalogTarget::LeftTrigger => Effect::GamepadTrigger {
            trigger: VirtualGamepadTrigger::Left,
            value: 0.0,
        },
        AnalogTarget::RightTrigger => Effect::GamepadTrigger {
            trigger: VirtualGamepadTrigger::Right,
            value: 0.0,
        },
    }
}

fn has_expired(now_millis: i64, last_seen: i64, maximum_age_millis: i64) -> bool {
    maximum_age_millis <= 0 || now_millis.saturating_sub(last_seen) >= maximum_age_millis
}

fn is_pairing_code(value: &str) -> bool {
    value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_digit())
}

fn normalized_pairing_code(value: Option<&str>) -> Option<String> {
    let digits = value?
        .chars()
        .filter(char::is_ascii_digit)
        .collect::<String>();
    is_pairing_code(&digits).then_some(digits)
}

fn normalized_token(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|token| !token.is_empty())
}

fn message_type_name(message_type: ControllerMessageType) -> &'static str {
    match message_type {
        ControllerMessageType::Hello => "hello",
        ControllerMessageType::PairingRequest => "pairing_request",
        ControllerMessageType::PairingChallenge => "pairing_challenge",
        ControllerMessageType::PairingAccepted => "pairing_accepted",
        ControllerMessageType::Button => "button",
        ControllerMessageType::ElementInput => "element_input",
        ControllerMessageType::Pointer => "pointer",
        ControllerMessageType::GamepadAnalog => "gamepad_analog",
        ControllerMessageType::ReleaseAll => "release_all",
        ControllerMessageType::Heartbeat => "heartbeat",
        ControllerMessageType::Ping => "ping",
        ControllerMessageType::Pong => "pong",
        ControllerMessageType::GamepadCustomization => "gamepad_customization",
        ControllerMessageType::GamepadProfiles => "gamepad_profiles",
        ControllerMessageType::SkinPackages => "skin_packages",
        ControllerMessageType::SkinPackageRemoval => "skin_package_removal",
        ControllerMessageType::GamepadProfileSkinSelection => "gamepad_profile_skin_selection",
        ControllerMessageType::GamepadProfileSelection => "gamepad_profile_selection",
        ControllerMessageType::GamepadDefaultProfile => "gamepad_default_profile",
        ControllerMessageType::GamepadProfileOrientationPreferenceMutation => {
            "gamepad_profile_orientation_preference_mutation"
        }
        ControllerMessageType::LaunchProfileTarget => "launch_profile_target",
        ControllerMessageType::Error => "error",
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LocalControlError {
    InvalidControlID,
    ProfileNotFound,
    ConfigurationRevisionExhausted,
}

impl fmt::Display for LocalControlError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidControlID => formatter.write_str("control ID must contain 1 to 512 bytes"),
            Self::ProfileNotFound => formatter.write_str("selected profile does not exist"),
            Self::ConfigurationRevisionExhausted => {
                formatter.write_str("configuration revision is exhausted")
            }
        }
    }
}

impl Error for LocalControlError {}

#[derive(Debug)]
pub enum CoreError {
    State(StateError),
    InvalidPairingCodeGenerated,
    InvalidAuthTokenGenerated,
    AuthTokenCollision,
}

impl fmt::Display for CoreError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::State(error) => error.fmt(formatter),
            Self::InvalidPairingCodeGenerated => {
                formatter.write_str("token source produced an invalid six-digit pairing code")
            }
            Self::InvalidAuthTokenGenerated => {
                formatter.write_str("token source produced an invalid authentication token")
            }
            Self::AuthTokenCollision => {
                formatter.write_str("token source repeatedly produced an authentication collision")
            }
        }
    }
}

impl Error for CoreError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::State(error) => Some(error),
            Self::InvalidPairingCodeGenerated
            | Self::InvalidAuthTokenGenerated
            | Self::AuthTokenCollision => None,
        }
    }
}

impl From<StateError> for CoreError {
    fn from(error: StateError) -> Self {
        Self::State(error)
    }
}
