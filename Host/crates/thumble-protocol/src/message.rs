use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Identity of an actual keypad element, with no action semantics or slot pool.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct KeypadElementID(pub [u8; 16]);

impl KeypadElementID {
    pub fn parse(raw: &str) -> Option<Self> {
        let raw = raw.as_bytes();
        if raw.len() != 36 || [8, 13, 18, 23].into_iter().any(|i| raw[i] != b'-') {
            return None;
        }
        let mut bytes = [0; 16];
        let mut index = 0;
        let mut high = None;
        for (position, byte) in raw.iter().copied().enumerate() {
            if [8, 13, 18, 23].contains(&position) { continue; }
            let nibble = match byte {
                b'0'..=b'9' => byte - b'0',
                b'a'..=b'f' => byte - b'a' + 10,
                b'A'..=b'F' => byte - b'A' + 10,
                _ => return None,
            };
            if let Some(value) = high.take() {
                bytes[index] = value * 16 + nibble;
                index += 1;
            } else {
                high = Some(nibble);
            }
        }
        Some(Self(bytes))
    }

    /// Stable identities for the starter layout only. Never used as an allocator.
    pub const fn preset(number: u16) -> Self {
        let mut bytes = [0; 16];
        let suffix = 0x100 + number;
        bytes[14] = (suffix >> 8) as u8;
        bytes[15] = suffix as u8;
        Self(bytes)
    }

    pub fn starter_index(self) -> Option<usize> {
        (1..=10).find(|number| self == Self::preset(*number)).map(usize::from)
    }
}

impl std::fmt::Display for KeypadElementID {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        for (i, byte) in self.0.iter().enumerate() {
            if [4, 6, 8, 10].contains(&i) { formatter.write_str("-")?; }
            write!(formatter, "{byte:02X}")?;
        }
        Ok(())
    }
}

impl Serialize for KeypadElementID {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_string())
    }
}

impl<'de> Deserialize<'de> for KeypadElementID {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Self::parse(&raw).ok_or_else(|| serde::de::Error::custom("expected an element UUID; named input slots are no longer supported"))
    }
}

fn deserialize_optional_element_id<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<String>, D::Error> {
    let raw = Option::<String>::deserialize(deserializer)?;
    if raw.as_deref().is_some_and(|value| KeypadElementID::parse(value).is_none()) {
        return Err(serde::de::Error::custom("elementID must be a UUID; named input slots are not supported"));
    }
    Ok(raw)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum KeypadElementInputPart {
    #[serde(rename = "primary")]
    Primary,
    #[serde(rename = "joystick_up")]
    JoystickUp,
    #[serde(rename = "joystick_down")]
    JoystickDown,
    #[serde(rename = "joystick_left")]
    JoystickLeft,
    #[serde(rename = "joystick_right")]
    JoystickRight,
    #[serde(rename = "trigger_digital")]
    TriggerDigital,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ButtonPressState {
    Down,
    Up,
}

impl ButtonPressState {
    pub const ALL: [Self; 2] = [Self::Down, Self::Up];

    pub const fn compact_wire_code(self) -> u8 {
        match self {
            Self::Down => 1,
            Self::Up => 2,
        }
    }

    pub const fn from_compact_wire_code(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::Down),
            2 => Some(Self::Up),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ControllerPointerEventKind {
    Move,
    Scroll,
    Button,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ControllerPointerButton {
    Left,
    Right,
    Middle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ControllerCapability {
    #[serde(rename = "gamepad_profile_orientation_preference_mutation")]
    GamepadProfileOrientationPreferenceMutation,
    #[serde(rename = "skin_packages")]
    SkinPackages,
    #[serde(rename = "gamepad_profile_skin_selection")]
    GamepadProfileSkinSelection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ControllerMessageType {
    #[serde(rename = "hello")]
    Hello,
    #[serde(rename = "pairing_request")]
    PairingRequest,
    #[serde(rename = "pairing_challenge")]
    PairingChallenge,
    #[serde(rename = "pairing_accepted")]
    PairingAccepted,
    #[serde(rename = "button")]
    Button,
    #[serde(rename = "element_input")]
    ElementInput,
    #[serde(rename = "pointer")]
    Pointer,
    #[serde(rename = "gamepad_analog")]
    GamepadAnalog,
    #[serde(rename = "release_all")]
    ReleaseAll,
    #[serde(rename = "heartbeat")]
    Heartbeat,
    #[serde(rename = "ping")]
    Ping,
    #[serde(rename = "pong")]
    Pong,
    #[serde(rename = "gamepad_customization")]
    GamepadCustomization,
    #[serde(rename = "gamepad_profiles")]
    GamepadProfiles,
    #[serde(rename = "skin_packages")]
    SkinPackages,
    #[serde(rename = "skin_package_removal")]
    SkinPackageRemoval,
    #[serde(rename = "gamepad_profile_skin_selection")]
    GamepadProfileSkinSelection,
    #[serde(rename = "gamepad_profile_selection")]
    GamepadProfileSelection,
    #[serde(rename = "gamepad_default_profile")]
    GamepadDefaultProfile,
    #[serde(rename = "gamepad_profile_orientation_preference_mutation")]
    GamepadProfileOrientationPreferenceMutation,
    #[serde(rename = "launch_profile_target")]
    LaunchProfileTarget,
    #[serde(rename = "error")]
    Error,
}

impl ControllerMessageType {
    pub const ALL: [Self; 22] = [
        Self::Hello,
        Self::PairingRequest,
        Self::PairingChallenge,
        Self::PairingAccepted,
        Self::Button,
        Self::ElementInput,
        Self::Pointer,
        Self::GamepadAnalog,
        Self::ReleaseAll,
        Self::Heartbeat,
        Self::Ping,
        Self::Pong,
        Self::GamepadCustomization,
        Self::GamepadProfiles,
        Self::SkinPackages,
        Self::SkinPackageRemoval,
        Self::GamepadProfileSkinSelection,
        Self::GamepadProfileSelection,
        Self::GamepadDefaultProfile,
        Self::GamepadProfileOrientationPreferenceMutation,
        Self::LaunchProfileTarget,
        Self::Error,
    ];

    pub(crate) const fn compact_wire_code(self) -> Option<u8> {
        match self {
            Self::Button => Some(1),
            Self::ElementInput => Some(6),
            Self::ReleaseAll => Some(2),
            Self::Heartbeat => Some(3),
            Self::Ping => Some(4),
            Self::Pong => Some(5),
            _ => None,
        }
    }

    pub(crate) const fn from_compact_wire_code(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::Button),
            6 => Some(Self::ElementInput),
            2 => Some(Self::ReleaseAll),
            3 => Some(Self::Heartbeat),
            4 => Some(Self::Ping),
            5 => Some(Self::Pong),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum GamepadProfileOrientationPreference {
    Automatic,
    Portrait,
    Landscape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VirtualGamepadStick {
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VirtualGamepadTrigger {
    Left,
    Right,
}

/// The JSON message exchanged by Thumble clients and hosts.
///
/// UUIDs use their JSON string representation. Swift `Data` values in
/// `skin_packages` use the base64 strings produced by `JSONEncoder`. The fields
/// containing evolving profile, customization, skin, binding-presentation, and
/// device schemas are `Value`-backed to retain unknown nested fields.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerMessage {
    #[serde(rename = "type")]
    pub message_type: ControllerMessageType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub button: Option<KeypadElementID>,
    #[serde(rename = "elementID", default, deserialize_with = "deserialize_optional_element_id", skip_serializing_if = "Option::is_none")]
    pub element_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub element_part: Option<KeypadElementInputPart>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state: Option<ButtonPressState>,
    pub timestamp: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sent_at: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pairing_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub realtime_token: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub auth_token: Option<String>,
    #[serde(rename = "serverID", skip_serializing_if = "Option::is_none")]
    pub server_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gamepad_customization: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gamepad_profiles: Option<Vec<Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skin_packages: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub skin_reference: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub binding_presentations: Option<Vec<Value>>,
    #[serde(rename = "gamepadProfileID", skip_serializing_if = "Option::is_none")]
    pub gamepad_profile_id: Option<String>,
    #[serde(
        rename = "defaultGamepadProfileID",
        skip_serializing_if = "Option::is_none"
    )]
    pub default_gamepad_profile_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub capabilities: Option<Vec<ControllerCapability>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gamepad_profile_orientation_preference_mutation:
        Option<GamepadProfileOrientationPreference>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub client_device_info: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pointer_event: Option<ControllerPointerEventKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pointer_button: Option<ControllerPointerButton>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delta_x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delta_y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub analog_stick: Option<VirtualGamepadStick>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub analog_trigger: Option<VirtualGamepadTrigger>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub analog_x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub analog_y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub analog_value: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub analog_sequence: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_protocol_version: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_generation: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input_sequence: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub press_identifier: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub virtual_gamepad_status: Option<Box<Value>>,
}

impl ControllerMessage {
    pub fn new(message_type: ControllerMessageType, timestamp: i64) -> Self {
        Self {
            message_type,
            button: None,
            element_id: None,
            element_part: None,
            state: None,
            timestamp,
            sent_at: None,
            pairing_code: None,
            client_name: None,
            message: None,
            realtime_token: None,
            auth_token: None,
            server_id: None,
            gamepad_customization: None,
            gamepad_profiles: None,
            skin_packages: None,
            skin_reference: None,
            binding_presentations: None,
            gamepad_profile_id: None,
            default_gamepad_profile_id: None,
            capabilities: None,
            gamepad_profile_orientation_preference_mutation: None,
            client_device_info: None,
            pointer_event: None,
            pointer_button: None,
            delta_x: None,
            delta_y: None,
            analog_stick: None,
            analog_trigger: None,
            analog_x: None,
            analog_y: None,
            analog_value: None,
            analog_sequence: None,
            input_protocol_version: None,
            input_generation: None,
            input_sequence: None,
            press_identifier: None,
            virtual_gamepad_status: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn arbitrary_element_uuids_round_trip_and_named_slots_are_rejected() {
        for number in 1..=128 {
            let id = KeypadElementID::preset(number);
            let json = serde_json::to_string(&id).unwrap();
            assert_eq!(serde_json::from_str::<KeypadElementID>(&json).unwrap(), id);
            assert_eq!(KeypadElementID::parse(&id.to_string().to_lowercase()), Some(id));
        }
        for name in ["up", "down", "left", "right", "jump", "attack", "dash", "focus", "map", "pause", "custom1", "custom8"] {
            assert!(serde_json::from_value::<KeypadElementID>(serde_json::json!(name)).is_err());
        }
    }

    #[test]
    fn every_button_state_code_is_stable_and_reversible() {
        for (index, state) in ButtonPressState::ALL.into_iter().enumerate() {
            let code = (index + 1) as u8;
            assert_eq!(state.compact_wire_code(), code);
            assert_eq!(ButtonPressState::from_compact_wire_code(code), Some(state));
        }
        assert_eq!(ButtonPressState::from_compact_wire_code(0), None);
        assert_eq!(ButtonPressState::from_compact_wire_code(3), None);
    }

    #[test]
    fn compact_message_type_codes_are_stable() {
        let compact = [
            (ControllerMessageType::Button, 1),
            (ControllerMessageType::ReleaseAll, 2),
            (ControllerMessageType::Heartbeat, 3),
            (ControllerMessageType::Ping, 4),
            (ControllerMessageType::Pong, 5),
            (ControllerMessageType::ElementInput, 6),
        ];
        for (message_type, code) in compact {
            assert_eq!(message_type.compact_wire_code(), Some(code));
            assert_eq!(
                ControllerMessageType::from_compact_wire_code(code),
                Some(message_type)
            );
        }
        assert_eq!(ControllerMessageType::from_compact_wire_code(0), None);
        assert_eq!(ControllerMessageType::from_compact_wire_code(7), None);
    }
}
