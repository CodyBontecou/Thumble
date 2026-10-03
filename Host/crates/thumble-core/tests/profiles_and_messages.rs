mod common;

use common::{diagnostic_text, no_tokens, pair, sent_message};
use serde_json::json;
use thumble_core::{ButtonBindings, Effect, HostCore, KeyBinding, OutputBinding, PersistentState};
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType, GameButton, KeypadElementInputPart,
};

fn profile_state() -> PersistentState {
    let mut state = PersistentState::minimal("server-1").unwrap();
    state.profiles = vec![
        json!({
            "id": "profile-a",
            "name": "A",
            "customization": {
                "elements": [{
                    "id": "element-a",
                    "legacySlot": "jump",
                    "future": {"keep": true}
                }],
                "unknownCustomization": "preserve-a"
            },
            "futureProfile": [1, 2, 3]
        }),
        json!({
            "id": "profile-b",
            "name": "B",
            "customization": {
                "elements": [{
                    "id": "element-b",
                    "output": {
                        "keyboard": {
                            "keyCode": 11,
                            "modifiersRawValue": 8,
                            "sequence": [
                                {"keyCode": 11, "modifiersRawValue": 8},
                                {"keyCode": 4, "modifiersRawValue": 0}
                            ]
                        }
                    },
                    "future": "keep"
                }]
            },
            "portraitCustomization": {
                "elements": [{
                    "id": "portrait-direct",
                    "output": {"keyboard": {"keyCode": 49, "modifiersRawValue": 0}}
                }]
            },
            "unknownB": true
        }),
    ];
    state.active_profile_id = "profile-a".to_owned();
    state.default_profile_id = "profile-a".to_owned();

    let mut a = ButtonBindings::default();
    a.insert(
        GameButton::Jump,
        OutputBinding::keyboard(KeyBinding::new(36, 0)),
    );
    let mut b = ButtonBindings::default();
    b.insert(
        GameButton::Jump,
        OutputBinding::keyboard(KeyBinding::new(49, 0)),
    );
    state.profile_output_bindings.clear();
    state
        .profile_output_bindings
        .insert("profile-a".to_owned(), a);
    state
        .profile_output_bindings
        .insert("profile-b".to_owned(), b);
    state.normalize().unwrap();
    state
}

fn paired_core() -> HostCore {
    let mut core = HostCore::new(profile_state(), "111111").unwrap();
    pair(&mut core, 1, "token");
    core
}

#[test]
fn profile_selection_default_and_request_emit_complete_raw_state() {
    let mut core = paired_core();
    let mut select = ControllerMessage::new(ControllerMessageType::GamepadProfileSelection, 0);
    select.gamepad_profile_id = Some("profile-b".to_owned());
    let effects = core.handle_message(1, select, 0, &mut no_tokens()).unwrap();
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, Effect::PersistState)));
    let response = sent_message(&effects, ControllerMessageType::GamepadProfiles);
    assert_eq!(response.gamepad_profile_id.as_deref(), Some("profile-b"));
    assert_eq!(core.status().configuration_revision, 2);
    assert_eq!(
        response.default_gamepad_profile_id.as_deref(),
        Some("profile-a")
    );
    assert_eq!(response.binding_presentations, Some(Vec::new()));
    assert_eq!(response.capabilities, Some(Vec::new()));
    assert_eq!(
        response.gamepad_profiles.as_ref().unwrap()[1]["unknownB"],
        true
    );

    let mut set_default = ControllerMessage::new(ControllerMessageType::GamepadDefaultProfile, 0);
    set_default.default_gamepad_profile_id = Some("profile-b".to_owned());
    let effects = core
        .handle_message(1, set_default, 0, &mut no_tokens())
        .unwrap();
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, Effect::PersistState)));
    assert_eq!(core.status().default_profile_id, "profile-b");
    assert_eq!(core.status().configuration_revision, 3);

    let request = ControllerMessage::new(ControllerMessageType::GamepadProfiles, 0);
    let effects = core
        .handle_message(1, request, 0, &mut no_tokens())
        .unwrap();
    let response = sent_message(&effects, ControllerMessageType::GamepadProfiles);
    assert_eq!(response.gamepad_profiles.as_ref().unwrap().len(), 2);
    assert_eq!(
        response.gamepad_profiles.as_ref().unwrap()[0]["futureProfile"],
        json!([1, 2, 3])
    );
}

#[test]
fn profile_selection_changes_button_binding_and_releases_previous_profile_hold() {
    let mut core = paired_core();
    let mut down = ControllerMessage::new(ControllerMessageType::Button, 0);
    down.button = Some(GameButton::Jump);
    down.state = Some(ButtonPressState::Down);
    down.input_protocol_version = Some(2);
    down.input_generation = Some(1);
    down.input_sequence = Some(1);
    down.press_identifier = Some(1);
    let effects = core.handle_message(1, down, 0, &mut no_tokens()).unwrap();
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, Effect::KeyDown(binding) if binding.key_code == 36)));

    let mut select = ControllerMessage::new(ControllerMessageType::GamepadProfileSelection, 0);
    select.gamepad_profile_id = Some("profile-b".to_owned());
    let effects = core.handle_message(1, select, 1, &mut no_tokens()).unwrap();
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, Effect::KeyUp(binding) if binding.key_code == 36)));

    let mut next = ControllerMessage::new(ControllerMessageType::Button, 0);
    next.button = Some(GameButton::Jump);
    next.state = Some(ButtonPressState::Down);
    next.input_protocol_version = Some(2);
    next.input_generation = core.status().active_generation;
    assert_eq!(next.input_generation, Some(2));
    next.input_sequence = Some(2);
    next.press_identifier = Some(2);
    let effects = core.handle_message(1, next, 2, &mut no_tokens()).unwrap();
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, Effect::KeyDown(binding) if binding.key_code == 49)));
}

#[test]
fn local_profile_selection_releases_persists_and_notifies_active_client() {
    let mut core = paired_core();
    let mut down = ControllerMessage::new(ControllerMessageType::Button, 0);
    down.button = Some(GameButton::Jump);
    down.state = Some(ButtonPressState::Down);
    down.input_protocol_version = Some(2);
    down.input_generation = Some(1);
    down.input_sequence = Some(1);
    down.press_identifier = Some(1);
    core.handle_message(1, down, 0, &mut no_tokens()).unwrap();

    let effects = core.select_profile_locally("PROFILE-B").unwrap();
    let release = effects
        .iter()
        .position(|effect| matches!(effect, Effect::KeyUp(binding) if binding.key_code == 36))
        .unwrap();
    let persist = effects
        .iter()
        .position(|effect| matches!(effect, Effect::PersistState))
        .unwrap();
    assert!(release < persist);
    assert_eq!(core.status().active_profile_id, "profile-b");
    assert_eq!(core.status().configuration_revision, 2);
    assert_eq!(
        sent_message(&effects, ControllerMessageType::GamepadProfiles)
            .gamepad_profile_id
            .as_deref(),
        Some("profile-b")
    );

    assert!(core.select_profile_locally("missing").is_err());
    assert_eq!(core.status().active_profile_id, "profile-b");
    assert_eq!(core.status().configuration_revision, 2);
}

#[test]
fn active_customization_replacement_preserves_unknown_profile_fields() {
    let mut core = paired_core();
    let mut update = ControllerMessage::new(ControllerMessageType::GamepadCustomization, 0);
    update.gamepad_customization = Some(json!({
        "elements": [{
            "id": "new-element",
            "output": {"keyboard": {"keyCode": 7, "modifiersRawValue": 2}},
            "futureElement": {"retained": true}
        }],
        "futureCustomization": ["retained"]
    }));
    update.gamepad_profile_id = Some("profile-a".to_owned());
    let effects = core.handle_message(1, update, 0, &mut no_tokens()).unwrap();
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, Effect::PersistState)));
    assert_eq!(core.status().configuration_revision, 2);
    assert_eq!(
        core.persistent_state().profiles[0]["futureProfile"],
        json!([1, 2, 3])
    );
    assert_eq!(
        core.persistent_state().profiles[0]["customization"]["futureCustomization"],
        json!(["retained"])
    );
    let response = sent_message(&effects, ControllerMessageType::GamepadCustomization);
    assert_eq!(
        response.gamepad_customization.as_ref().unwrap()["elements"][0]["futureElement"]
            ["retained"],
        true
    );
}

#[test]
fn nonactive_customization_and_profile_array_mutations_return_clear_errors() {
    let mut core = paired_core();
    let mut update = ControllerMessage::new(ControllerMessageType::GamepadCustomization, 0);
    update.gamepad_customization = Some(json!({}));
    update.gamepad_profile_id = Some("profile-b".to_owned());
    let effects = core.handle_message(1, update, 0, &mut no_tokens()).unwrap();
    assert_eq!(
        diagnostic_text(&effects),
        "Only the active profile customization can be replaced"
    );

    let mut replace = ControllerMessage::new(ControllerMessageType::GamepadProfiles, 0);
    replace.gamepad_profiles = Some(Vec::new());
    let effects = core
        .handle_message(1, replace, 0, &mut no_tokens())
        .unwrap();
    assert_eq!(
        diagnostic_text(&effects),
        "Replacing the profile array is not supported by this host"
    );
}

#[test]
fn direct_element_sequence_and_portrait_output_are_executed() {
    let mut core = paired_core();
    let mut select = ControllerMessage::new(ControllerMessageType::GamepadProfileSelection, 0);
    select.gamepad_profile_id = Some("profile-b".to_owned());
    core.handle_message(1, select, 0, &mut no_tokens()).unwrap();

    let mut sequence = ControllerMessage::new(ControllerMessageType::ElementInput, 0);
    sequence.element_id = Some("element-b".to_owned());
    sequence.element_part = Some(KeypadElementInputPart::Primary);
    sequence.state = Some(ButtonPressState::Down);
    sequence.input_protocol_version = Some(2);
    sequence.input_generation = Some(2);
    sequence.input_sequence = Some(1);
    sequence.press_identifier = Some(1);
    let effects = core
        .handle_message(1, sequence, 0, &mut no_tokens())
        .unwrap();
    assert!(effects.iter().any(|effect| matches!(effect,
        Effect::TapSequence(strokes) if strokes.len() == 2 && strokes[0].key_code == 11 && strokes[1].key_code == 4
    )));

    let mut portrait = ControllerMessage::new(ControllerMessageType::ElementInput, 0);
    portrait.element_id = Some("portrait-direct".to_owned());
    portrait.state = Some(ButtonPressState::Down);
    portrait.input_protocol_version = Some(2);
    portrait.input_generation = Some(2);
    portrait.input_sequence = Some(2);
    portrait.press_identifier = Some(2);
    let effects = core
        .handle_message(1, portrait, 1, &mut no_tokens())
        .unwrap();
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, Effect::KeyDown(binding) if binding.key_code == 49)));
    assert!(core
        .status()
        .pressed_elements
        .contains(&"portrait-direct".to_owned()));
}

#[test]
fn ping_pong_and_unsupported_capability_mutations_are_handled_reliably() {
    let mut core = paired_core();
    let ping = ControllerMessage::new(ControllerMessageType::Ping, 1234);
    let effects = core.handle_message(1, ping, 0, &mut no_tokens()).unwrap();
    assert_eq!(
        sent_message(&effects, ControllerMessageType::Pong).timestamp,
        1234
    );

    let analog = ControllerMessage::new(ControllerMessageType::GamepadAnalog, 0);
    let effects = core.handle_message(1, analog, 0, &mut no_tokens()).unwrap();
    assert_eq!(
        diagnostic_text(&effects),
        "Exactly one analog target is required"
    );
    assert!(!effects.iter().any(|effect| matches!(
        effect,
        Effect::SendMessage { message, .. }
            if message.message_type == ControllerMessageType::Error
    )));

    let skin = ControllerMessage::new(ControllerMessageType::SkinPackages, 0);
    let effects = core.handle_message(1, skin, 0, &mut no_tokens()).unwrap();
    assert_eq!(
        diagnostic_text(&effects),
        "skin_packages is not supported by this host"
    );
}

#[test]
fn invalid_profile_ids_are_rejected_without_state_changes() {
    let mut core = paired_core();
    let mut select = ControllerMessage::new(ControllerMessageType::GamepadProfileSelection, 0);
    select.gamepad_profile_id = Some("missing".to_owned());
    let effects = core.handle_message(1, select, 0, &mut no_tokens()).unwrap();
    assert_eq!(diagnostic_text(&effects), "Selected profile does not exist");
    assert_eq!(core.status().active_profile_id, "profile-a");
}
