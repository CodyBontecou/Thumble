use serde_json::{json, Value};
use thumble_protocol::{
    ButtonPressState, ControllerCapability, ControllerMessage, ControllerMessageType,
    ControllerPointerButton, ControllerPointerEventKind, KeypadElementID,
    GamepadProfileOrientationPreference, KeypadElementInputPart, VirtualGamepadStick,
    VirtualGamepadTrigger,
};

#[test]
fn every_controller_message_kind_has_the_swift_wire_name_and_round_trips() {
    let expected_names = [
        "hello",
        "pairing_request",
        "pairing_challenge",
        "pairing_accepted",
        "button",
        "element_input",
        "pointer",
        "gamepad_analog",
        "release_all",
        "heartbeat",
        "ping",
        "pong",
        "gamepad_customization",
        "gamepad_profiles",
        "skin_packages",
        "skin_package_removal",
        "gamepad_profile_skin_selection",
        "gamepad_profile_selection",
        "gamepad_default_profile",
        "gamepad_profile_orientation_preference_mutation",
        "launch_profile_target",
        "error",
    ];

    assert_eq!(ControllerMessageType::ALL.len(), expected_names.len());
    for (message_type, expected_name) in ControllerMessageType::ALL
        .into_iter()
        .zip(expected_names.into_iter())
    {
        let message = ControllerMessage::new(message_type, -1_234_567_890);
        let value = serde_json::to_value(&message).unwrap();
        assert_eq!(value["type"], expected_name);
        assert_eq!(value["timestamp"], -1_234_567_890_i64);
        assert_eq!(
            serde_json::from_value::<ControllerMessage>(value).unwrap(),
            message
        );
    }
}

#[test]
fn full_message_uses_swift_camel_case_keys_and_preserves_complex_unknown_fields() {
    let customization = json!({
        "elements": [],
        "buttonCustomizations": {"00000000-0000-0000-0000-000000000105": {"futureStyle": {"revision": 9}}},
        "unknownCustomizationField": [1, true, null]
    });
    let profiles = vec![json!({
        "id": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "customization": {"elements": [], "newNestedProfileField": {"enabled": true}},
        "unknownProfileField": "retained"
    })];
    let device = json!({
        "deviceName": "Test Phone",
        "systemName": "iOS",
        "systemVersion": "26.0",
        "screenBoundsWidth": 430.0,
        "futureDeviceMetric": {"pixels": 12345}
    });

    let mut message = ControllerMessage::new(ControllerMessageType::GamepadProfiles, 123);
    message.button = Some(KeypadElementID::preset(18));
    message.element_id = Some("729B071A-B5BB-4A91-B2A7-F644C61E5920".into());
    message.element_part = Some(KeypadElementInputPart::TriggerDigital);
    message.state = Some(ButtonPressState::Up);
    message.sent_at = Some(124);
    message.pairing_code = Some("123456".into());
    message.client_name = Some("Cody's iPhone".into());
    message.message = Some("message".into());
    message.realtime_token = Some("realtime".into());
    message.auth_token = Some("auth".into());
    message.server_id = Some("server".into());
    message.gamepad_customization = Some(customization.clone());
    message.gamepad_profiles = Some(profiles.clone());
    message.skin_packages = Some(vec!["AAECAw==".into()]);
    message.skin_reference = Some(json!({"identifier": "skin", "version": "1.0.0"}));
    message.binding_presentations = Some(vec![json!({"profileID": "profile", "new": 1})]);
    message.gamepad_profile_id = Some("11111111-2222-3333-4444-555555555555".into());
    message.default_gamepad_profile_id = Some("66666666-7777-8888-9999-AAAAAAAAAAAA".into());
    message.capabilities = Some(vec![
        ControllerCapability::GamepadProfileOrientationPreferenceMutation,
        ControllerCapability::SkinPackages,
        ControllerCapability::GamepadProfileSkinSelection,
    ]);
    message.gamepad_profile_orientation_preference_mutation =
        Some(GamepadProfileOrientationPreference::Landscape);
    message.client_device_info = Some(device.clone());
    message.pointer_event = Some(ControllerPointerEventKind::Button);
    message.pointer_button = Some(ControllerPointerButton::Middle);
    message.delta_x = Some(-1.25);
    message.delta_y = Some(2.5);
    message.analog_stick = Some(VirtualGamepadStick::Right);
    message.analog_trigger = Some(VirtualGamepadTrigger::Left);
    message.analog_x = Some(-0.5);
    message.analog_y = Some(0.75);
    message.analog_value = Some(0.875);
    message.analog_sequence = Some(u64::MAX);
    message.input_protocol_version = Some(3);
    message.input_generation = Some(u64::MAX - 1);
    message.input_sequence = Some(u64::MAX - 2);
    message.press_identifier = Some(u64::MAX - 3);

    let encoded = serde_json::to_vec(&message).unwrap();
    let value: Value = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(value["elementID"], message.element_id.as_deref().unwrap());
    assert_eq!(value["serverID"], message.server_id.as_deref().unwrap());
    assert_eq!(
        value["gamepadProfileID"],
        message.gamepad_profile_id.as_deref().unwrap()
    );
    assert_eq!(
        value["defaultGamepadProfileID"],
        message.default_gamepad_profile_id.as_deref().unwrap()
    );
    assert_eq!(value["elementPart"], "trigger_digital");
    assert_eq!(value["gamepadCustomization"], customization);
    assert_eq!(value["gamepadProfiles"], json!(profiles));
    assert_eq!(value["clientDeviceInfo"], device);
    assert_eq!(
        value["capabilities"],
        json!([
            "gamepad_profile_orientation_preference_mutation",
            "skin_packages",
            "gamepad_profile_skin_selection"
        ])
    );
    assert_eq!(
        value["gamepadProfileOrientationPreferenceMutation"],
        "landscape"
    );
    assert_eq!(value["analogSequence"], u64::MAX);

    let decoded: ControllerMessage = serde_json::from_slice(&encoded).unwrap();
    assert_eq!(decoded, message);
    assert_eq!(decoded.gamepad_customization, Some(customization));
    assert_eq!(decoded.gamepad_profiles, Some(profiles));
    assert_eq!(decoded.client_device_info, Some(device));
}

#[test]
fn absent_optional_fields_are_omitted_like_swift_json_encoder() {
    let message = ControllerMessage::new(ControllerMessageType::Hello, 42);
    let value = serde_json::to_value(message).unwrap();
    assert_eq!(value, json!({"type": "hello", "timestamp": 42}));
}

#[test]
fn uuid_json_without_generation_metadata_decodes_but_named_inputs_do_not() {
    for name in ["jump", "attack", "up", "custom1", "custom8"] {
        assert!(serde_json::from_value::<ControllerMessage>(json!({
            "type":"button", "button":name, "state":"down", "timestamp":1
        })).is_err());
    }
    let message: ControllerMessage =
        serde_json::from_str(r#"{"type":"button","button":"00000000-0000-0000-0000-000000000105","state":"down","timestamp":1}"#)
            .unwrap();
    assert_eq!(message.message_type, ControllerMessageType::Button);
    assert_eq!(message.button, Some(KeypadElementID::preset(5)));
    assert_eq!(message.state, Some(ButtonPressState::Down));
    assert_eq!(message.input_protocol_version, None);
    assert_eq!(message.input_generation, None);
    assert_eq!(message.input_sequence, None);
    assert_eq!(message.press_identifier, None);
}

#[test]
fn supporting_enum_names_match_swift_raw_values() {
    let cases = [
        (
            serde_json::to_value(KeypadElementInputPart::Primary).unwrap(),
            json!("primary"),
        ),
        (
            serde_json::to_value(KeypadElementInputPart::JoystickUp).unwrap(),
            json!("joystick_up"),
        ),
        (
            serde_json::to_value(KeypadElementInputPart::JoystickDown).unwrap(),
            json!("joystick_down"),
        ),
        (
            serde_json::to_value(KeypadElementInputPart::JoystickLeft).unwrap(),
            json!("joystick_left"),
        ),
        (
            serde_json::to_value(KeypadElementInputPart::JoystickRight).unwrap(),
            json!("joystick_right"),
        ),
        (
            serde_json::to_value(KeypadElementInputPart::TriggerDigital).unwrap(),
            json!("trigger_digital"),
        ),
    ];
    for (actual, expected) in cases {
        assert_eq!(actual, expected);
    }

    for element in (1..=10).map(KeypadElementID::preset) {
        let value = serde_json::to_value(element).unwrap();
        assert_eq!(value, element.to_string());
        assert_eq!(value.as_str().unwrap().len(), 36);
        assert_eq!(KeypadElementID::parse(value.as_str().unwrap()), Some(element));
        assert_eq!(serde_json::from_value::<KeypadElementID>(value).unwrap(), element);
    }
}
