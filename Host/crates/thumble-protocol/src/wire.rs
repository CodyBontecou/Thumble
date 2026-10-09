use crate::{ButtonPressState, ControllerMessage, ControllerMessageType, KeypadElementID, KeypadElementInputPart};
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

/// Swift-compatible UUID input wire encoder and decoder. No slot-index frames
/// or named slot aliases are accepted.
pub struct ControllerWireCodec;

impl ControllerWireCodec {
    pub const CURRENT_INPUT_PROTOCOL_VERSION: i64 = 3;
    pub const MAXIMUM_INBOUND_PAYLOAD_SIZE: usize = 8 * 1024 * 1024;
    pub const MAXIMUM_BUTTON_SEQUENCE_NUMBER: u64 = (1_u64 << 48) - 1;
    pub const MAXIMUM_BUTTON_PRESS_IDENTIFIER: u64 = (1_u64 << 15) - 1;
    const MAGIC: [u8; 2] = *b"PP";
    const CONTROL_SIZE: usize = 14;
    const INPUT_SIZE: usize = 56;
    const BUTTON_SEQUENCE_MARKER: u64 = 1_u64 << 63;

    pub fn encode(message: &ControllerMessage) -> Result<Vec<u8>, ControllerWireCodecError> {
        if let Some(data) = Self::compact_data(message) { return Ok(data); }
        Ok(serde_json::to_vec(message)?)
    }

    pub fn decode(data: &[u8]) -> Result<ControllerMessage, ControllerWireCodecError> {
        if data.len() > Self::MAXIMUM_INBOUND_PAYLOAD_SIZE {
            return Err(ControllerWireCodecError::InboundPayloadTooLarge { actual_bytes: data.len(), maximum_bytes: Self::MAXIMUM_INBOUND_PAYLOAD_SIZE });
        }
        if let Some(message) = Self::compact_message(data) { return Ok(message); }
        Ok(crate::decode_unique_json(data)?)
    }

    pub fn encode_button(id: KeypadElementID, state: ButtonPressState) -> Vec<u8> {
        let mut message = ControllerMessage::new(ControllerMessageType::Button, 0);
        message.button = Some(id); message.state = Some(state);
        Self::compact_input(&message).unwrap()
    }

    pub fn encode_button_with_sequence(id: KeypadElementID, state: ButtonPressState, sequence: u64, press: Option<u64>, generation: Option<u64>) -> Vec<u8> {
        let mut message = ControllerMessage::new(ControllerMessageType::Button, Self::input_sequence_timestamp(sequence, press));
        message.button = Some(id); message.state = Some(state);
        message.input_protocol_version = Some(Self::CURRENT_INPUT_PROTOCOL_VERSION);
        message.input_generation = generation; message.input_sequence = Some(sequence); message.press_identifier = press;
        Self::compact_input(&message).unwrap()
    }

    pub fn input_sequence_timestamp(sequence: u64, press: Option<u64>) -> i64 {
        (Self::BUTTON_SEQUENCE_MARKER | (press.unwrap_or(0).min(Self::MAXIMUM_BUTTON_PRESS_IDENTIFIER) << 48) | sequence.clamp(1, Self::MAXIMUM_BUTTON_SEQUENCE_NUMBER)) as i64
    }

    pub fn button_sequence_number(message: &ControllerMessage) -> Option<u64> { Self::input_sequence_number(message) }
    pub fn input_sequence_number(message: &ControllerMessage) -> Option<u64> {
        if let Some(sequence) = message.input_sequence { return Some(sequence); }
        if !matches!(message.message_type, ControllerMessageType::Button | ControllerMessageType::ElementInput) { return None; }
        let bits = message.timestamp as u64;
        let sequence = bits & Self::MAXIMUM_BUTTON_SEQUENCE_NUMBER;
        (bits & Self::BUTTON_SEQUENCE_MARKER != 0 && sequence != 0).then_some(sequence)
    }
    pub fn button_press_identifier(message: &ControllerMessage) -> Option<u64> { Self::input_press_identifier(message) }
    pub fn input_press_identifier(message: &ControllerMessage) -> Option<u64> {
        if let Some(press) = message.press_identifier { return Some(press); }
        if !matches!(message.message_type, ControllerMessageType::Button | ControllerMessageType::ElementInput) { return None; }
        let bits = message.timestamp as u64;
        let press = (bits >> 48) & Self::MAXIMUM_BUTTON_PRESS_IDENTIFIER;
        (bits & Self::BUTTON_SEQUENCE_MARKER != 0 && press != 0).then_some(press)
    }

    fn compact_data(message: &ControllerMessage) -> Option<Vec<u8>> {
        if Self::has_json_only_field(message) { return None; }
        let type_code = message.message_type.compact_wire_code()?;
        if matches!(message.message_type, ControllerMessageType::Button | ControllerMessageType::ElementInput) {
            return Self::compact_input(message);
        }
        if message.button.is_some() || message.element_id.is_some() || message.element_part.is_some() || message.state.is_some()
            || message.input_protocol_version.is_some() || message.input_generation.is_some() || message.input_sequence.is_some() || message.press_identifier.is_some() { return None; }
        let mut data = vec![0; Self::CONTROL_SIZE];
        data[..2].copy_from_slice(&Self::MAGIC); data[2] = 1; data[3] = type_code;
        data[4..12].copy_from_slice(&message.timestamp.to_le_bytes()); data[12] = 255; data[13] = 255;
        Some(data)
    }

    fn has_json_only_field(message: &ControllerMessage) -> bool {
        message.sent_at.is_some() || message.pairing_code.is_some() || message.client_name.is_some() || message.message.is_some()
            || message.realtime_token.is_some() || message.auth_token.is_some() || message.server_id.is_some()
            || message.gamepad_customization.is_some() || message.gamepad_profiles.is_some() || message.virtual_gamepad_status.is_some()
            || message.skin_packages.is_some() || message.skin_reference.is_some() || message.binding_presentations.is_some()
            || message.gamepad_profile_id.is_some() || message.default_gamepad_profile_id.is_some() || message.capabilities.is_some()
            || message.gamepad_profile_orientation_preference_mutation.is_some() || message.client_device_info.is_some()
            || message.pointer_event.is_some() || message.pointer_button.is_some() || message.delta_x.is_some() || message.delta_y.is_some()
            || message.analog_stick.is_some() || message.analog_trigger.is_some() || message.analog_x.is_some() || message.analog_y.is_some()
            || message.analog_value.is_some() || message.analog_sequence.is_some()
    }

    fn compact_input(message: &ControllerMessage) -> Option<Vec<u8>> {
        if message.input_protocol_version.is_some_and(|version| version != Self::CURRENT_INPUT_PROTOCOL_VERSION) { return None; }
        let state = message.state?;
        let id = match message.message_type {
            ControllerMessageType::Button if message.element_id.is_none() && message.element_part.is_none() => message.button?,
            ControllerMessageType::ElementInput if message.button.is_none() => KeypadElementID::parse(message.element_id.as_ref()?)?,
            _ => return None,
        };
        let part = message.element_part.unwrap_or(KeypadElementInputPart::Primary);
        let part_code = match part { KeypadElementInputPart::Primary => 0, KeypadElementInputPart::JoystickUp => 1, KeypadElementInputPart::JoystickDown => 2, KeypadElementInputPart::JoystickLeft => 3, KeypadElementInputPart::JoystickRight => 4, KeypadElementInputPart::TriggerDigital => 5 };
        let mut data = vec![0; Self::INPUT_SIZE];
        data[..2].copy_from_slice(&Self::MAGIC); data[2] = Self::CURRENT_INPUT_PROTOCOL_VERSION as u8;
        data[3] = message.message_type.compact_wire_code()?; data[4..20].copy_from_slice(&id.0);
        data[20] = part_code; data[21] = state.compact_wire_code();
        data[22] = u8::from(message.press_identifier.is_some()) | (u8::from(message.input_generation.is_some()) << 1)
            | (u8::from(message.input_sequence.is_some()) << 2) | (u8::from(message.input_protocol_version.is_some()) << 3);
        data[24..32].copy_from_slice(&message.input_generation.unwrap_or(0).to_le_bytes());
        data[32..40].copy_from_slice(&message.input_sequence.unwrap_or(0).to_le_bytes());
        data[40..48].copy_from_slice(&message.press_identifier.unwrap_or(0).to_le_bytes());
        data[48..56].copy_from_slice(&message.timestamp.to_le_bytes());
        Some(data)
    }

    fn compact_message(data: &[u8]) -> Option<ControllerMessage> {
        if !matches!(data.len(), Self::CONTROL_SIZE | Self::INPUT_SIZE) || data[..2] != Self::MAGIC { return None; }
        let message_type = ControllerMessageType::from_compact_wire_code(data[3])?;
        if data.len() == Self::CONTROL_SIZE {
            if data[2] != 1 || data[12] != 255 || data[13] != 255 || matches!(message_type, ControllerMessageType::Button | ControllerMessageType::ElementInput) { return None; }
            return Some(ControllerMessage::new(message_type, i64::from_le_bytes(data[4..12].try_into().ok()?)));
        }
        if data[2] != Self::CURRENT_INPUT_PROTOCOL_VERSION as u8 || data[22] & !15 != 0 || data[23] != 0 { return None; }
        if !matches!(message_type, ControllerMessageType::Button | ControllerMessageType::ElementInput) || (message_type == ControllerMessageType::Button && data[20] != 0) { return None; }
        let part = match data[20] { 0 => KeypadElementInputPart::Primary, 1 => KeypadElementInputPart::JoystickUp, 2 => KeypadElementInputPart::JoystickDown, 3 => KeypadElementInputPart::JoystickLeft, 4 => KeypadElementInputPart::JoystickRight, 5 => KeypadElementInputPart::TriggerDigital, _ => return None };
        let id = KeypadElementID(data[4..20].try_into().ok()?);
        let mut message = ControllerMessage::new(message_type, i64::from_le_bytes(data[48..56].try_into().ok()?));
        if message_type == ControllerMessageType::Button { message.button = Some(id); }
        else { message.element_id = Some(id.to_string()); message.element_part = Some(part); }
        message.state = Some(ButtonPressState::from_compact_wire_code(data[21])?);
        message.input_protocol_version = (data[22] & 8 != 0).then_some(Self::CURRENT_INPUT_PROTOCOL_VERSION);
        message.input_generation = (data[22] & 2 != 0).then(|| u64::from_le_bytes(data[24..32].try_into().unwrap()));
        message.input_sequence = (data[22] & 4 != 0).then(|| u64::from_le_bytes(data[32..40].try_into().unwrap()));
        message.press_identifier = (data[22] & 1 != 0).then(|| u64::from_le_bytes(data[40..48].try_into().unwrap()));
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
        message.button = Some(KeypadElementID::preset(1));
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
