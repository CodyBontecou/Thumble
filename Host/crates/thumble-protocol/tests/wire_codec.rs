use serde_json::json;
use thumble_protocol::{
    ButtonPressState, ControllerCapability, ControllerMessage, ControllerMessageType,
    ControllerPointerButton, ControllerPointerEventKind, ControllerWireCodec,
    ControllerWireCodecError, KeypadElementID, GamepadProfileOrientationPreference,
    KeypadElementInputPart, VirtualGamepadStick, VirtualGamepadTrigger,
};

#[test]
fn uuid_inputs_encode_unbounded_identities_and_both_states() {
    for number in 1..=128 {
        let id = KeypadElementID::parse(&format!("A74530D9-83A9-41AB-A82D-{number:012X}")).unwrap();
        for state in ButtonPressState::ALL {
            let frame = ControllerWireCodec::encode_button(id, state);
            assert_eq!(frame.len(), 56);
            assert_eq!(&frame[..4], &[b'P', b'P', 3, 1]);
            assert_eq!(&frame[4..20], &id.0);
            assert_eq!(frame[20], 0);
            assert_eq!(frame[21], state.compact_wire_code());
            let decoded = ControllerWireCodec::decode(&frame).unwrap();
            assert_eq!(decoded.button, Some(id));
            assert_eq!(decoded.state, Some(state));
            assert_eq!(decoded.input_protocol_version, None);
        }
    }
}

#[test]
fn v3_metadata_layout_preserves_uuid_generation_sequence_and_press() {
    for number in 1..=128 {
        let id = KeypadElementID::parse(&format!("A74530D9-83A9-41AB-A82D-{number:012X}")).unwrap();
        for state in ButtonPressState::ALL {
            let generation = u64::MAX - number;
            let sequence = 0x0102_0304_0506_0708;
            let press = 0x8877_6655_4433_2211;
            let frame = ControllerWireCodec::encode_button_with_sequence(id, state, sequence, Some(press), Some(generation));
            assert_eq!(frame.len(), 56);
            assert_eq!(&frame[..4], &[b'P', b'P', 3, 1]);
            assert_eq!(&frame[4..20], &id.0);
            assert_eq!(frame[22], 15);
            assert_eq!(&frame[24..32], &generation.to_le_bytes());
            assert_eq!(&frame[32..40], &sequence.to_le_bytes());
            assert_eq!(&frame[40..48], &press.to_le_bytes());
            let decoded = ControllerWireCodec::decode(&frame).unwrap();
            assert_eq!(decoded.button, Some(id));
            assert_eq!(decoded.state, Some(state));
            assert_eq!(decoded.input_protocol_version, Some(3));
            assert_eq!(decoded.input_generation, Some(generation));
            assert_eq!(decoded.input_sequence, Some(sequence));
            assert_eq!(decoded.press_identifier, Some(press));
        }
    }
}

#[test]
fn generic_encoding_preserves_v3_timestamp_and_metadata() {
    let mut message = ControllerMessage::new(ControllerMessageType::Button, i64::MIN);
    message.button = Some(KeypadElementID::preset(6));
    message.state = Some(ButtonPressState::Up);
    message.input_protocol_version = Some(3);
    message.input_generation = Some(u64::MAX - 10);
    message.input_sequence = Some(u64::MAX - 20);
    message.press_identifier = Some(u64::MAX - 30);
    let frame = ControllerWireCodec::encode(&message).unwrap();
    assert_eq!(&frame[..4], &[b'P', b'P', 3, 1]);
    assert_eq!(&frame[48..56], &i64::MIN.to_le_bytes());
    assert_eq!(ControllerWireCodec::decode(&frame).unwrap(), message);
}

#[test]
fn input_sent_at_uses_json_instead_of_being_discarded() {
    let mut message = ControllerMessage::new(ControllerMessageType::ElementInput, i64::MIN);
    message.element_id = Some("992A6272-A934-462D-8DC7-3058F80363F7".into());
    message.element_part = Some(KeypadElementInputPart::JoystickRight);
    message.state = Some(ButtonPressState::Down);
    message.input_protocol_version = Some(3);
    message.input_sequence = Some(u64::MAX);
    message.sent_at = Some(123456);
    let encoded = ControllerWireCodec::encode(&message).unwrap();
    assert_eq!(encoded.first(), Some(&b'{'));
    assert_eq!(ControllerWireCodec::decode(&encoded).unwrap(), message);
}

#[test]
fn absent_press_identifier_is_not_inferred_from_storage_bytes() {
    let mut frame = ControllerWireCodec::encode_button_with_sequence(KeypadElementID::preset(9), ButtonPressState::Down, 4, None, Some(3));
    assert_eq!(frame[22] & 1, 0);
    assert_eq!(&frame[40..48], &[0; 8]);
    frame[40..48].copy_from_slice(&u64::MAX.to_le_bytes());
    assert_eq!(ControllerWireCodec::decode(&frame).unwrap().press_identifier, None);
}

#[test]
fn v1_control_message_codes_and_signed_timestamp_layout_match_swift() {
    let cases = [
        (ControllerMessageType::ReleaseAll, 2),
        (ControllerMessageType::Heartbeat, 3),
        (ControllerMessageType::Ping, 4),
        (ControllerMessageType::Pong, 5),
    ];
    for (message_type, code) in cases {
        let message = ControllerMessage::new(message_type, i64::MIN + i64::from(code));
        let frame = ControllerWireCodec::encode(&message).unwrap();
        assert_eq!(frame.len(), 14);
        assert_eq!(&frame[0..4], &[b'P', b'P', 1, code]);
        assert_eq!(&frame[4..12], &message.timestamp.to_le_bytes());
        assert_eq!(&frame[12..14], &[u8::MAX, u8::MAX]);
        assert_eq!(ControllerWireCodec::decode(&frame).unwrap(), message);
    }
}

#[test]
fn v1_sequence_packing_matches_swift_clamping_and_helpers() {
    let frame = ControllerWireCodec::encode_button_with_sequence(
        KeypadElementID::preset(7),
        ButtonPressState::Down,
        42,
        Some(1_234),
        None,
    );
    assert_eq!(frame.len(), 56);
    let decoded = ControllerWireCodec::decode(&frame).unwrap();
    assert_eq!(
        ControllerWireCodec::button_sequence_number(&decoded),
        Some(42)
    );
    assert_eq!(
        ControllerWireCodec::button_press_identifier(&decoded),
        Some(1_234)
    );

    let mut message = ControllerMessage::new(ControllerMessageType::Button, ControllerWireCodec::input_sequence_timestamp(0, Some(u64::MAX)));
    message.button = Some(KeypadElementID::preset(7)); message.state = Some(ButtonPressState::Up);
    let clamped = ControllerWireCodec::encode(&message).unwrap();
    let decoded = ControllerWireCodec::decode(&clamped).unwrap();
    assert_eq!(
        ControllerWireCodec::input_sequence_number(&decoded),
        Some(1)
    );
    assert_eq!(
        ControllerWireCodec::input_press_identifier(&decoded),
        Some(ControllerWireCodec::MAXIMUM_BUTTON_PRESS_IDENTIFIER)
    );

    let maximum = ControllerWireCodec::input_sequence_timestamp(u64::MAX, None);
    let bits = maximum as u64;
    assert_eq!(
        bits & ControllerWireCodec::MAXIMUM_BUTTON_SEQUENCE_NUMBER,
        ControllerWireCodec::MAXIMUM_BUTTON_SEQUENCE_NUMBER
    );
}

#[test]
fn noncompact_types_and_rich_compact_types_fall_back_to_json() {
    for message_type in ControllerMessageType::ALL {
        let mut message = ControllerMessage::new(message_type, 1);
        if message_type == ControllerMessageType::Button {
            message.button = Some(KeypadElementID::preset(5));
            message.state = Some(ButtonPressState::Down);
        }
        message.client_name = Some("forces JSON without changing the kind".into());
        let data = ControllerWireCodec::encode(&message).unwrap();
        assert_eq!(data.first(), Some(&b'{'), "{message_type:?}");
        assert_eq!(ControllerWireCodec::decode(&data).unwrap(), message);
    }

    let missing_state = ControllerMessage::new(ControllerMessageType::Button, 1);
    assert_eq!(
        ControllerWireCodec::encode(&missing_state).unwrap().first(),
        Some(&b'{')
    );

    let mut wrong_v2 = ControllerMessage::new(ControllerMessageType::Button, 1);
    wrong_v2.button = Some(KeypadElementID::preset(5));
    wrong_v2.state = Some(ButtonPressState::Down);
    wrong_v2.input_protocol_version = Some(1);
    wrong_v2.input_generation = Some(2);
    wrong_v2.input_sequence = Some(3);
    assert_eq!(
        ControllerWireCodec::encode(&wrong_v2).unwrap().first(),
        Some(&b'{')
    );
}

#[test]
fn every_swift_json_only_field_prevents_lossy_compact_encoding() {
    let base = || ControllerMessage::new(ControllerMessageType::Heartbeat, 1);
    let mut messages = Vec::new();

    let mut value = base();
    value.sent_at = Some(123456);
    messages.push(value);
    let mut value = base();
    value.pairing_code = Some("1".into());
    messages.push(value);
    let mut value = base();
    value.message = Some("x".into());
    messages.push(value);
    let mut value = base();
    value.realtime_token = Some("x".into());
    messages.push(value);
    let mut value = base();
    value.auth_token = Some("x".into());
    messages.push(value);
    let mut value = base();
    value.server_id = Some("x".into());
    messages.push(value);
    let mut value = base();
    value.element_id = Some("729B071A-B5BB-4A91-B2A7-F644C61E5920".into());
    messages.push(value);
    let mut value = base();
    value.element_part = Some(KeypadElementInputPart::Primary);
    messages.push(value);
    let mut value = base();
    value.gamepad_customization = Some(json!({"future": true}));
    messages.push(value);
    let mut value = base();
    value.gamepad_profiles = Some(vec![json!({"future": true})]);
    messages.push(value);
    let mut value = base();
    value.skin_packages = Some(vec!["AA==".into()]);
    messages.push(value);
    let mut value = base();
    value.skin_reference = Some(json!({"identifier": "x"}));
    messages.push(value);
    let mut value = base();
    value.binding_presentations = Some(vec![json!({"future": true})]);
    messages.push(value);
    let mut value = base();
    value.gamepad_profile_id = Some("id".into());
    messages.push(value);
    let mut value = base();
    value.default_gamepad_profile_id = Some("id".into());
    messages.push(value);
    let mut value = base();
    value.capabilities = Some(vec![ControllerCapability::SkinPackages]);
    messages.push(value);
    let mut value = base();
    value.gamepad_profile_orientation_preference_mutation =
        Some(GamepadProfileOrientationPreference::Portrait);
    messages.push(value);
    let mut value = base();
    value.client_device_info = Some(json!({"future": true}));
    messages.push(value);
    let mut value = base();
    value.pointer_event = Some(ControllerPointerEventKind::Move);
    messages.push(value);
    let mut value = base();
    value.pointer_button = Some(ControllerPointerButton::Right);
    messages.push(value);
    let mut value = base();
    value.delta_x = Some(1.0);
    messages.push(value);
    let mut value = base();
    value.delta_y = Some(1.0);
    messages.push(value);
    let mut value = base();
    value.analog_stick = Some(VirtualGamepadStick::Left);
    messages.push(value);
    let mut value = base();
    value.analog_trigger = Some(VirtualGamepadTrigger::Right);
    messages.push(value);
    let mut value = base();
    value.analog_x = Some(1.0);
    messages.push(value);
    let mut value = base();
    value.analog_y = Some(1.0);
    messages.push(value);
    let mut value = base();
    value.analog_value = Some(1.0);
    messages.push(value);
    let mut value = base();
    value.analog_sequence = Some(1);
    messages.push(value);

    for message in messages {
        let data = ControllerWireCodec::encode(&message).unwrap();
        assert_eq!(data.first(), Some(&b'{'), "{message:?}");
        assert_eq!(ControllerWireCodec::decode(&data).unwrap(), message);
    }
}

#[test]
fn malformed_uuid_frames_and_all_slot_index_frames_are_rejected() {
    let valid = ControllerWireCodec::encode_button(KeypadElementID::preset(1), ButtonPressState::Down);
    for (index, byte) in [(0, b'X'), (1, b'X'), (2, 2), (3, 0), (20, 1), (21, 0), (22, 16), (23, 1)] {
        let mut malformed = valid.clone(); malformed[index] = byte;
        assert!(ControllerWireCodec::decode(&malformed).is_err());
    }
    for version in [1, 2] {
        let mut legacy = vec![0; if version == 1 { 14 } else { 32 }];
        legacy[..4].copy_from_slice(&[b'P', b'P', version, 1]);
        assert!(ControllerWireCodec::decode(&legacy).is_err());
    }
    for part in [KeypadElementInputPart::Primary, KeypadElementInputPart::JoystickUp, KeypadElementInputPart::JoystickDown, KeypadElementInputPart::JoystickLeft, KeypadElementInputPart::JoystickRight, KeypadElementInputPart::TriggerDigital] {
        let mut message = ControllerMessage::new(ControllerMessageType::ElementInput, 42);
        message.element_id = Some(KeypadElementID::preset(42).to_string()); message.element_part = Some(part); message.state = Some(ButtonPressState::Down);
        assert_eq!(ControllerWireCodec::decode(&ControllerWireCodec::encode(&message).unwrap()).unwrap(), message);
    }
}

#[test]
fn control_frames_cannot_smuggle_slot_indices() {
    let mut frame = ControllerWireCodec::encode(&ControllerMessage::new(ControllerMessageType::Heartbeat, 5)).unwrap();
    frame[12] = 0; frame[13] = 254;
    assert!(ControllerWireCodec::decode(&frame).is_err());
}

#[test]
fn json_fallback_accepts_uuid_inputs_and_large_messages_up_to_eight_mib() {
    let json = br#"{"type":"element_input","elementID":"A74530D9-83A9-41AB-A82D-000000000001","elementPart":"joystick_left","state":"down","timestamp":1,"inputProtocolVersion":3,"inputGeneration":3,"inputSequence":4,"pressIdentifier":5}"#;
    let decoded = ControllerWireCodec::decode(json).unwrap();
    assert_eq!(decoded.message_type, ControllerMessageType::ElementInput);
    assert_eq!(
        decoded.element_part,
        Some(KeypadElementInputPart::JoystickLeft)
    );
    assert_eq!(decoded.input_sequence, Some(4));

    let mut maximum = br#"{"type":"hello","timestamp":1}"#.to_vec();
    maximum.resize(ControllerWireCodec::MAXIMUM_INBOUND_PAYLOAD_SIZE, b' ');
    assert_eq!(
        ControllerWireCodec::decode(&maximum).unwrap().message_type,
        ControllerMessageType::Hello
    );

    maximum.push(b' ');
    match ControllerWireCodec::decode(&maximum) {
        Err(ControllerWireCodecError::InboundPayloadTooLarge {
            actual_bytes,
            maximum_bytes,
        }) => {
            assert_eq!(actual_bytes, 8 * 1024 * 1024 + 1);
            assert_eq!(maximum_bytes, 8 * 1024 * 1024);
        }
        other => panic!("expected payload-size error, got {other:?}"),
    }
}
