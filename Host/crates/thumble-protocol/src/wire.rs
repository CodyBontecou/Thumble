use crate::{ButtonPressState, ControllerMessage, ControllerMessageType, GameButton};
use std::error::Error;
use std::fmt;

#[derive(Debug)]
pub enum ControllerWireCodecError {
    InboundPayloadTooLarge {
        actual_bytes: usize,
        maximum_bytes: usize,
    },
    Json(serde_json::Error),
}

impl fmt::Display for ControllerWireCodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InboundPayloadTooLarge {
                actual_bytes,
                maximum_bytes,
            } => write!(
                formatter,
                "controller payload is {actual_bytes} bytes; the maximum is {maximum_bytes} bytes"
            ),
            Self::Json(error) => write!(formatter, "invalid controller JSON: {error}"),
        }
    }
}

impl Error for ControllerWireCodecError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Json(error) => Some(error),
            Self::InboundPayloadTooLarge { .. } => None,
        }
    }
}

impl From<serde_json::Error> for ControllerWireCodecError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

/// Swift-compatible controller wire encoder and decoder.
pub struct ControllerWireCodec;

impl ControllerWireCodec {
    pub const CURRENT_INPUT_PROTOCOL_VERSION: i64 = 2;
    pub const MAXIMUM_INBOUND_PAYLOAD_SIZE: usize = 8 * 1024 * 1024;
    pub const MAXIMUM_BUTTON_SEQUENCE_NUMBER: u64 = (1_u64 << 48) - 1;
    pub const MAXIMUM_BUTTON_PRESS_IDENTIFIER: u64 = (1_u64 << 15) - 1;

    const MAGIC: [u8; 2] = *b"PP";
    const V1: u8 = 1;
    const V2: u8 = Self::CURRENT_INPUT_PROTOCOL_VERSION as u8;
    const EMPTY_FIELD: u8 = u8::MAX;
    const V1_SIZE: usize = 14;
    const V2_SIZE: usize = 32;
    const V2_PRESS_IDENTIFIER_PRESENT: u8 = 1;
    const BUTTON_SEQUENCE_MARKER: u64 = 1_u64 << 63;
    const BUTTON_PRESS_IDENTIFIER_SHIFT: u32 = 48;

    /// Encodes compact-compatible messages as v1 or v2 frames and all other
    /// messages as JSON. As in the Swift codec, only inbound payloads are size
    /// limited.
    pub fn encode(message: &ControllerMessage) -> Result<Vec<u8>, ControllerWireCodecError> {
        if let Some(compact) = Self::compact_data(message) {
            return Ok(compact);
        }
        Ok(serde_json::to_vec(message)?)
    }

    /// Decodes a compact frame when its complete structure is valid, otherwise
    /// falls back to JSON. The size guard runs before either parser.
    pub fn decode(data: &[u8]) -> Result<ControllerMessage, ControllerWireCodecError> {
        if data.len() > Self::MAXIMUM_INBOUND_PAYLOAD_SIZE {
            return Err(ControllerWireCodecError::InboundPayloadTooLarge {
                actual_bytes: data.len(),
                maximum_bytes: Self::MAXIMUM_INBOUND_PAYLOAD_SIZE,
            });
        }

        if let Some(message) = Self::compact_message(data) {
            return Ok(message);
        }

        Ok(serde_json::from_slice(data)?)
    }

    /// Encodes the cached, unsequenced v1 button shape used by the Swift codec.
    pub fn encode_button(button: GameButton, state: ButtonPressState) -> Vec<u8> {
        Self::compact_v1(
            ControllerMessageType::Button.compact_wire_code().unwrap(),
            0,
            Some(button.compact_wire_code()),
            Some(state.compact_wire_code()),
        )
    }

    /// Encodes a sequenced button. Supplying a generation selects the v2 32-byte
    /// frame; omitting it selects the legacy v1 timestamp-packed frame.
    pub fn encode_button_with_sequence(
        button: GameButton,
        state: ButtonPressState,
        sequence_number: u64,
        press_identifier: Option<u64>,
        generation: Option<u64>,
    ) -> Vec<u8> {
        if let Some(generation) = generation {
            return Self::compact_v2(button, state, generation, sequence_number, press_identifier);
        }

        Self::compact_v1(
            ControllerMessageType::Button.compact_wire_code().unwrap(),
            Self::input_sequence_timestamp(sequence_number, press_identifier),
            Some(button.compact_wire_code()),
            Some(state.compact_wire_code()),
        )
    }

    /// Packs the clamped legacy sequence and press identifier into an `i64`
    /// timestamp exactly as `ControllerWireCodec.inputSequenceTimestamp` does.
    pub fn input_sequence_timestamp(sequence_number: u64, press_identifier: Option<u64>) -> i64 {
        let sequence_number = sequence_number.clamp(1, Self::MAXIMUM_BUTTON_SEQUENCE_NUMBER);
        let press_identifier = press_identifier
            .unwrap_or(0)
            .min(Self::MAXIMUM_BUTTON_PRESS_IDENTIFIER);
        let bits = Self::BUTTON_SEQUENCE_MARKER
            | (press_identifier << Self::BUTTON_PRESS_IDENTIFIER_SHIFT)
            | sequence_number;
        bits as i64
    }

    pub fn button_sequence_number(message: &ControllerMessage) -> Option<u64> {
        Self::input_sequence_number(message)
    }

    pub fn input_sequence_number(message: &ControllerMessage) -> Option<u64> {
        if let Some(sequence) = message.input_sequence {
            return Some(sequence);
        }
        if !matches!(
            message.message_type,
            ControllerMessageType::Button | ControllerMessageType::ElementInput
        ) {
            return None;
        }

        let bits = message.timestamp as u64;
        if bits & Self::BUTTON_SEQUENCE_MARKER == 0 {
            return None;
        }
        let sequence = bits & Self::MAXIMUM_BUTTON_SEQUENCE_NUMBER;
        (sequence != 0).then_some(sequence)
    }

    pub fn button_press_identifier(message: &ControllerMessage) -> Option<u64> {
        Self::input_press_identifier(message)
    }

    pub fn input_press_identifier(message: &ControllerMessage) -> Option<u64> {
        if let Some(identifier) = message.press_identifier {
            return Some(identifier);
        }
        if !matches!(
            message.message_type,
            ControllerMessageType::Button | ControllerMessageType::ElementInput
        ) {
            return None;
        }

        let bits = message.timestamp as u64;
        if bits & Self::BUTTON_SEQUENCE_MARKER == 0 {
            return None;
        }
        let identifier =
            (bits >> Self::BUTTON_PRESS_IDENTIFIER_SHIFT) & Self::MAXIMUM_BUTTON_PRESS_IDENTIFIER;
        (identifier != 0).then_some(identifier)
    }

    fn compact_data(message: &ControllerMessage) -> Option<Vec<u8>> {
        if Self::has_json_only_field(message) {
            return None;
        }
        let type_code = message.message_type.compact_wire_code()?;

        let has_input_protocol_fields = message.input_protocol_version.is_some()
            || message.input_generation.is_some()
            || message.input_sequence.is_some()
            || message.press_identifier.is_some();
        if has_input_protocol_fields {
            if message.message_type != ControllerMessageType::Button
                || message.input_protocol_version != Some(Self::CURRENT_INPUT_PROTOCOL_VERSION)
            {
                return None;
            }
            return Some(Self::compact_v2(
                message.button?,
                message.state?,
                message.input_generation?,
                message.input_sequence?,
                message.press_identifier,
            ));
        }

        if message.message_type == ControllerMessageType::Button
            && (message.button.is_none() || message.state.is_none())
        {
            return None;
        }

        Some(Self::compact_v1(
            type_code,
            message.timestamp,
            message.button.map(GameButton::compact_wire_code),
            message.state.map(ButtonPressState::compact_wire_code),
        ))
    }

    fn has_json_only_field(message: &ControllerMessage) -> bool {
        message.pairing_code.is_some()
            || message.client_name.is_some()
            || message.message.is_some()
            || message.realtime_token.is_some()
            || message.auth_token.is_some()
            || message.server_id.is_some()
            || message.element_id.is_some()
            || message.element_part.is_some()
            || message.gamepad_customization.is_some()
            || message.gamepad_profiles.is_some()
            || message.virtual_gamepad_status.is_some()
            || message.skin_packages.is_some()
            || message.skin_reference.is_some()
            || message.binding_presentations.is_some()
            || message.gamepad_profile_id.is_some()
            || message.default_gamepad_profile_id.is_some()
            || message.capabilities.is_some()
            || message
                .gamepad_profile_orientation_preference_mutation
                .is_some()
            || message.client_device_info.is_some()
            || message.pointer_event.is_some()
            || message.pointer_button.is_some()
            || message.delta_x.is_some()
            || message.delta_y.is_some()
            || message.analog_stick.is_some()
            || message.analog_trigger.is_some()
            || message.analog_x.is_some()
            || message.analog_y.is_some()
            || message.analog_value.is_some()
            || message.analog_sequence.is_some()
    }

    fn compact_v1(
        type_code: u8,
        timestamp: i64,
        button_code: Option<u8>,
        state_code: Option<u8>,
    ) -> Vec<u8> {
        let mut data = vec![0; Self::V1_SIZE];
        data[0..2].copy_from_slice(&Self::MAGIC);
        data[2] = Self::V1;
        data[3] = type_code;
        data[4..12].copy_from_slice(&timestamp.to_le_bytes());
        data[12] = button_code.unwrap_or(Self::EMPTY_FIELD);
        data[13] = state_code.unwrap_or(Self::EMPTY_FIELD);
        data
    }

    fn compact_v2(
        button: GameButton,
        state: ButtonPressState,
        generation: u64,
        sequence_number: u64,
        press_identifier: Option<u64>,
    ) -> Vec<u8> {
        let mut data = vec![0; Self::V2_SIZE];
        data[0..2].copy_from_slice(&Self::MAGIC);
        data[2] = Self::V2;
        data[3] = ControllerMessageType::Button.compact_wire_code().unwrap();
        data[4] = button.compact_wire_code();
        data[5] = state.compact_wire_code();
        data[6] = u8::from(press_identifier.is_some()) * Self::V2_PRESS_IDENTIFIER_PRESENT;
        data[7] = 0;
        data[8..16].copy_from_slice(&generation.to_le_bytes());
        data[16..24].copy_from_slice(&sequence_number.to_le_bytes());
        data[24..32].copy_from_slice(&press_identifier.unwrap_or(0).to_le_bytes());
        data
    }

    fn compact_message(data: &[u8]) -> Option<ControllerMessage> {
        match data.len() {
            Self::V2_SIZE => Self::compact_v2_message(data),
            Self::V1_SIZE => Self::compact_v1_message(data),
            _ => None,
        }
    }

    fn compact_v1_message(data: &[u8]) -> Option<ControllerMessage> {
        if data[0..2] != Self::MAGIC
            || data[2] != Self::V1
            || ControllerMessageType::from_compact_wire_code(data[3]).is_none()
        {
            return None;
        }

        let message_type = ControllerMessageType::from_compact_wire_code(data[3]).unwrap();
        let timestamp = i64::from_le_bytes(data[4..12].try_into().unwrap());
        let button = (data[12] != Self::EMPTY_FIELD)
            .then(|| GameButton::from_compact_wire_code(data[12]))
            .flatten();
        let state = (data[13] != Self::EMPTY_FIELD)
            .then(|| ButtonPressState::from_compact_wire_code(data[13]))
            .flatten();

        if message_type == ControllerMessageType::Button && (button.is_none() || state.is_none()) {
            return None;
        }

        let mut message = ControllerMessage::new(message_type, timestamp);
        message.button = button;
        message.state = state;
        Some(message)
    }

    fn compact_v2_message(data: &[u8]) -> Option<ControllerMessage> {
        if data[0..2] != Self::MAGIC
            || data[2] != Self::V2
            || data[3] != ControllerMessageType::Button.compact_wire_code().unwrap()
            || data[6] & !Self::V2_PRESS_IDENTIFIER_PRESENT != 0
            || data[7] != 0
        {
            return None;
        }

        let button = GameButton::from_compact_wire_code(data[4])?;
        let state = ButtonPressState::from_compact_wire_code(data[5])?;
        let generation = u64::from_le_bytes(data[8..16].try_into().unwrap());
        let sequence = u64::from_le_bytes(data[16..24].try_into().unwrap());
        let has_press_identifier = data[6] & Self::V2_PRESS_IDENTIFIER_PRESENT != 0;
        let press_identifier =
            has_press_identifier.then(|| u64::from_le_bytes(data[24..32].try_into().unwrap()));

        let mut message = ControllerMessage::new(ControllerMessageType::Button, 0);
        message.button = Some(button);
        message.state = Some(state);
        message.input_protocol_version = Some(Self::CURRENT_INPUT_PROTOCOL_VERSION);
        message.input_generation = Some(generation);
        message.input_sequence = Some(sequence);
        message.press_identifier = press_identifier;
        Some(message)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sequence_timestamp_clamps_both_components() {
        let timestamp = ControllerWireCodec::input_sequence_timestamp(0, Some(u64::MAX));
        let mut message = ControllerMessage::new(ControllerMessageType::Button, timestamp);
        message.button = Some(GameButton::Up);
        message.state = Some(ButtonPressState::Down);

        assert_eq!(
            ControllerWireCodec::input_sequence_number(&message),
            Some(1)
        );
        assert_eq!(
            ControllerWireCodec::input_press_identifier(&message),
            Some(ControllerWireCodec::MAXIMUM_BUTTON_PRESS_IDENTIFIER)
        );

        message.timestamp = ControllerWireCodec::input_sequence_timestamp(u64::MAX, None);
        assert_eq!(
            ControllerWireCodec::input_sequence_number(&message),
            Some(ControllerWireCodec::MAXIMUM_BUTTON_SEQUENCE_NUMBER)
        );
        assert_eq!(ControllerWireCodec::input_press_identifier(&message), None);
    }

    #[test]
    fn explicit_input_values_take_precedence_even_for_non_input_types() {
        let mut message = ControllerMessage::new(ControllerMessageType::Hello, 0);
        message.input_sequence = Some(0);
        message.press_identifier = Some(0);
        assert_eq!(
            ControllerWireCodec::input_sequence_number(&message),
            Some(0)
        );
        assert_eq!(
            ControllerWireCodec::input_press_identifier(&message),
            Some(0)
        );
    }
}
