mod common;

use common::{diagnostic_text, no_tokens, pair, sent_message};
use serde_json::json;
use thumble_core::{profile_owned_outputs, Effect, HostCore, PersistentState};
use thumble_protocol::{ButtonPressState, ControllerMessage, ControllerMessageType, KeypadElementID, KeypadElementInputPart};

const PROFILE_A: &str = "1a8f30de-6a53-4f28-98f7-d58e5311bdf9";
const PROFILE_B: &str = "c27e5dfa-b767-4c5f-ab06-b7e12d80d9d1";
const BUTTON_A: &str = "29e3aa7d-198f-48e5-83ad-ad5b6a4caf51";
const BUTTON_B: &str = "9bc5b91d-2c6c-4358-806e-5fd3a895452a";
const SEQUENCE_B: &str = "af6b26c1-903d-4833-bb71-cd93ab075a8b";
const PORTRAIT_B: &str = "34ab8967-89b1-4d4d-865f-79639d2942af";
const REPLACEMENT_A: &str = "bf256560-af9b-4aee-a844-6c763ef43f56";

fn profile_state() -> PersistentState {
    let mut state = PersistentState::minimal("server-1").unwrap();
    state.profiles = vec![
        json!({"id": PROFILE_A, "name": "A", "outputMode":"keyboard", "customization": {
            "elements": [{"id": BUTTON_A, "kind":"button", "label":"Action", "output":{"keyboard":{"keyCode":36}}, "future":{"keep":true}}],
            "unknownCustomization": "preserve-a"
        }, "futureProfile": [1, 2, 3]}),
        json!({"id": PROFILE_B, "name": "B", "outputMode":"keyboard", "customization": {
            "elements": [
                {"id": BUTTON_B, "kind":"button", "label":"Action", "output":{"keyboard":{"keyCode":49}}},
                {"id": SEQUENCE_B, "kind":"button", "output":{"keyboard":{"keyCode":11,"modifiersRawValue":8,"sequence":[
                    {"keyCode":11,"modifiersRawValue":8}, {"keyCode":4,"modifiersRawValue":0}
                ]}}, "future":"keep"}
            ]
        }, "portraitCustomization":{"elements":[{"id":PORTRAIT_B,"kind":"button","output":{"keyboard":{"keyCode":49}}}]}, "unknownB":true}),
    ];
    state.active_profile_id = PROFILE_A.to_owned();
    state.default_profile_id = PROFILE_A.to_owned();
    state.profile_output_bindings.clear();
    state.profile_key_bindings.clear();
    for profile in &state.profiles {
        state.profile_output_bindings.insert(profile["id"].as_str().unwrap().to_owned(), profile_owned_outputs(profile));
    }
    state.key_bindings = Default::default();
    state.output_bindings = state.profile_output_bindings[PROFILE_A].clone();
    state.normalize().unwrap();
    state
}

fn paired_core() -> HostCore {
    let mut core = HostCore::new(profile_state(), "111111").unwrap();
    pair(&mut core, 1, "token");
    core
}

fn down(core: &HostCore, id: &str, sequence: u64) -> ControllerMessage {
    let mut message = ControllerMessage::new(ControllerMessageType::Button, 0);
    message.button = Some(KeypadElementID::parse(id).unwrap());
    message.state = Some(ButtonPressState::Down);
    message.input_protocol_version = Some(3);
    message.input_generation = core.status().active_generation.or(Some(1));
    message.input_sequence = Some(sequence);
    message.press_identifier = Some(sequence);
    message
}

#[test]
fn profile_selection_default_and_request_emit_complete_raw_state() {
    let mut core = paired_core();
    let mut select = ControllerMessage::new(ControllerMessageType::GamepadProfileSelection, 0);
    select.gamepad_profile_id = Some(PROFILE_B.to_owned());
    let effects = core.handle_message(1, select, 0, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect, Effect::PersistState)));
    let response = sent_message(&effects, ControllerMessageType::GamepadProfiles);
    assert_eq!(response.gamepad_profile_id.as_deref(), Some(PROFILE_B));
    assert_eq!(core.status().configuration_revision, 2);
    assert_eq!(response.default_gamepad_profile_id.as_deref(), Some(PROFILE_A));
    assert_eq!(response.binding_presentations, Some(Vec::new()));
    assert_eq!(response.capabilities, Some(Vec::new()));
    assert_eq!(response.gamepad_profiles.as_ref().unwrap()[1]["unknownB"], true);
    let mut set_default = ControllerMessage::new(ControllerMessageType::GamepadDefaultProfile, 0);
    set_default.default_gamepad_profile_id = Some(PROFILE_B.to_owned());
    let effects = core.handle_message(1, set_default, 0, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect, Effect::PersistState)));
    assert_eq!(core.status().default_profile_id, PROFILE_B);
    assert_eq!(core.status().configuration_revision, 3);
    let effects = core.handle_message(1, ControllerMessage::new(ControllerMessageType::GamepadProfiles, 0), 0, &mut no_tokens()).unwrap();
    let response = sent_message(&effects, ControllerMessageType::GamepadProfiles);
    assert_eq!(response.gamepad_profiles.as_ref().unwrap().len(), 2);
    assert_eq!(response.gamepad_profiles.as_ref().unwrap()[0]["futureProfile"], json!([1,2,3]));
}

#[test]
fn profile_selection_changes_owned_binding_and_releases_previous_profile_hold() {
    let mut core = paired_core();
    let message = down(&core, BUTTON_A, 1);
    let effects = core.handle_message(1, message, 0, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect, Effect::KeyDown(binding) if binding.key_code == 36)));
    let mut select = ControllerMessage::new(ControllerMessageType::GamepadProfileSelection, 0);
    select.gamepad_profile_id = Some(PROFILE_B.to_owned());
    let effects = core.handle_message(1, select, 1, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect, Effect::KeyUp(binding) if binding.key_code == 36)));
    assert_eq!(core.status().active_generation, Some(2));
    let absent = down(&core, BUTTON_A, 2);
    let effects = core.handle_message(1, absent, 2, &mut no_tokens()).unwrap();
    assert!(!effects.iter().any(|effect| matches!(effect, Effect::KeyDown(_))));
    let next = down(&core, BUTTON_B, 3);
    let effects = core.handle_message(1, next, 3, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect, Effect::KeyDown(binding) if binding.key_code == 49)));
}

#[test]
fn local_profile_selection_releases_persists_and_notifies_active_client() {
    let mut core = paired_core();
    let message = down(&core, BUTTON_A, 1);
    core.handle_message(1, message, 0, &mut no_tokens()).unwrap();
    let effects = core.select_profile_locally(&PROFILE_B.to_uppercase()).unwrap();
    let release = effects.iter().position(|effect| matches!(effect, Effect::KeyUp(binding) if binding.key_code == 36)).unwrap();
    let persist = effects.iter().position(|effect| matches!(effect, Effect::PersistState)).unwrap();
    assert!(release < persist);
    assert_eq!(core.status().active_profile_id, PROFILE_B);
    assert_eq!(core.status().configuration_revision, 2);
    assert_eq!(sent_message(&effects, ControllerMessageType::GamepadProfiles).gamepad_profile_id.as_deref(), Some(PROFILE_B));
    assert!(core.select_profile_locally("missing").is_err());
    assert_eq!(core.status().active_profile_id, PROFILE_B);
    assert_eq!(core.status().configuration_revision, 2);
    let mut saved = core.persistent_state().clone();
    saved.normalize().unwrap();
    assert!(saved.output_bindings.get_raw(BUTTON_A).is_none());
    assert_eq!(saved.key_bindings.get_raw(BUTTON_B).unwrap().key_code, 49);
}

#[test]
fn failed_profile_selection_restores_the_complete_saved_state() {
    let mut core = paired_core();
    let before = core.persistent_state().clone();
    core.select_profile_locally(PROFILE_B).unwrap();
    core.restore_state_after_failed_local_selection(before.clone());
    assert_eq!(core.persistent_state(), &before);
    let mut saved = core.persistent_state().clone();
    saved.normalize().unwrap();
}

#[test]
fn active_customization_replacement_preserves_unknown_profile_fields() {
    let mut core = paired_core();
    let mut update = ControllerMessage::new(ControllerMessageType::GamepadCustomization, 0);
    update.gamepad_customization = Some(json!({"elements":[{"id":REPLACEMENT_A,"kind":"button","output":{"keyboard":{"keyCode":7,"modifiersRawValue":2}},"futureElement":{"retained":true}}],"futureCustomization":["retained"]}));
    update.gamepad_profile_id = Some(PROFILE_A.to_owned());
    let effects = core.handle_message(1, update, 0, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect, Effect::PersistState)));
    assert_eq!(core.status().configuration_revision, 2);
    assert_eq!(core.persistent_state().profiles[0]["futureProfile"], json!([1,2,3]));
    assert_eq!(core.persistent_state().profiles[0]["customization"]["futureCustomization"], json!(["retained"]));
    assert_eq!(sent_message(&effects, ControllerMessageType::GamepadCustomization).gamepad_customization.as_ref().unwrap()["elements"][0]["futureElement"]["retained"], true);
    let mut saved = core.persistent_state().clone();
    saved.normalize().unwrap();
    assert!(saved.profile_output_bindings[PROFILE_A].get_raw(BUTTON_A).is_none());
    assert!(saved.output_bindings.get_raw(BUTTON_A).is_none());
    assert_eq!(saved.key_bindings.get_raw(REPLACEMENT_A).unwrap().key_code, 7);
    assert_eq!(saved.profile_output_bindings[PROFILE_B], profile_state().profile_output_bindings[PROFILE_B]);
}

#[test]
fn invalid_network_customization_rejects_before_releasing_holds_or_writing_state() {
    let mut core = paired_core();
    let message = down(&core, BUTTON_A, 1);
    core.handle_message(1, message, 0, &mut no_tokens()).unwrap();
    let before = core.persistent_state().clone();
    let invalid = [
        json!({}),
        json!({"elements":[{"id":"jump","kind":"button"}]}),
        json!({"elements":[{"id":BUTTON_A,"kind":"button","mappedButton":null}]}),
        json!({"elements":[{"id":BUTTON_A},{"id":BUTTON_A.to_uppercase()}]}),
        json!({"elements":[],"customButtons":[{"id":BUTTON_A,"controlKind":"button"}]}),
        json!({"elements":[],"buttonCustomizations":[BUTTON_A,{}]}),
        json!({"elements":[{"id":BUTTON_A}],"designMetadata":{"layerOrder":["builtin.jump"]}}),
    ];
    for customization in invalid {
        let mut update = ControllerMessage::new(ControllerMessageType::GamepadCustomization, 0);
        update.gamepad_customization = Some(customization.clone());
        update.gamepad_profile_id = Some(PROFILE_A.to_owned());
        let effects = core.handle_message(1, update, 1, &mut no_tokens()).unwrap();
        assert!(!diagnostic_text(&effects).is_empty(), "invalid customization was accepted: {customization}");
        assert!(!effects.iter().any(|effect| matches!(effect, Effect::PersistState | Effect::KeyUp(_))));
        assert_eq!(core.persistent_state(), &before);
    }
    let mut up = down(&core, BUTTON_A, 2);
    up.state = Some(ButtonPressState::Up);
    up.press_identifier = Some(1);
    let effects = core.handle_message(1, up, 2, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect, Effect::KeyUp(binding) if binding.key_code == 36)));
}

#[test]
fn nonactive_customization_and_profile_array_mutations_return_clear_errors() {
    let mut core = paired_core();
    let mut update = ControllerMessage::new(ControllerMessageType::GamepadCustomization, 0);
    update.gamepad_customization = Some(json!({"elements":[]}));
    update.gamepad_profile_id = Some(PROFILE_B.to_owned());
    let effects = core.handle_message(1, update, 0, &mut no_tokens()).unwrap();
    assert_eq!(diagnostic_text(&effects), "Only the active profile customization can be replaced");
    let mut replace = ControllerMessage::new(ControllerMessageType::GamepadProfiles, 0);
    replace.gamepad_profiles = Some(Vec::new());
    let effects = core.handle_message(1, replace, 0, &mut no_tokens()).unwrap();
    assert_eq!(diagnostic_text(&effects), "Replacing the profile array is not supported by this host");
}

#[test]
fn direct_element_sequence_and_portrait_output_are_executed() {
    let mut core = paired_core();
    let mut select = ControllerMessage::new(ControllerMessageType::GamepadProfileSelection, 0);
    select.gamepad_profile_id = Some(PROFILE_B.to_owned());
    core.handle_message(1, select, 0, &mut no_tokens()).unwrap();
    let mut sequence = down(&core, SEQUENCE_B, 1);
    sequence.message_type = ControllerMessageType::ElementInput;
    sequence.button = None;
    sequence.element_id = Some(SEQUENCE_B.to_owned());
    sequence.element_part = Some(KeypadElementInputPart::Primary);
    let effects = core.handle_message(1, sequence, 0, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect, Effect::TapSequence(strokes) if strokes.len()==2 && strokes[0].key_code==11 && strokes[1].key_code==4)));
    let mut portrait = down(&core, PORTRAIT_B, 2);
    portrait.message_type = ControllerMessageType::ElementInput;
    portrait.button = None;
    portrait.element_id = Some(PORTRAIT_B.to_uppercase());
    let effects = core.handle_message(1, portrait, 1, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect, Effect::KeyDown(binding) if binding.key_code==49)));
    assert!(core.status().pressed_elements.iter().any(|id| id.eq_ignore_ascii_case(PORTRAIT_B)));
}

#[test]
fn ping_pong_and_unsupported_capability_mutations_are_handled_reliably() {
    let mut core = paired_core();
    let effects = core.handle_message(1, ControllerMessage::new(ControllerMessageType::Ping, 1234), 0, &mut no_tokens()).unwrap();
    assert_eq!(sent_message(&effects, ControllerMessageType::Pong).timestamp, 1234);
    let effects = core.handle_message(1, ControllerMessage::new(ControllerMessageType::GamepadAnalog, 0), 0, &mut no_tokens()).unwrap();
    assert_eq!(diagnostic_text(&effects), "Exactly one analog target is required");
    assert!(!effects.iter().any(|effect| matches!(effect, Effect::SendMessage {message,..} if message.message_type==ControllerMessageType::Error)));
    let effects = core.handle_message(1, ControllerMessage::new(ControllerMessageType::SkinPackages, 0), 0, &mut no_tokens()).unwrap();
    assert_eq!(diagnostic_text(&effects), "skin_packages is not supported by this host");
}

#[test]
fn invalid_profile_ids_are_rejected_without_state_changes() {
    let mut core = paired_core();
    let mut select = ControllerMessage::new(ControllerMessageType::GamepadProfileSelection, 0);
    select.gamepad_profile_id = Some("missing".to_owned());
    let effects = core.handle_message(1, select, 0, &mut no_tokens()).unwrap();
    assert_eq!(diagnostic_text(&effects), "Selected profile does not exist");
    assert_eq!(core.status().active_profile_id, PROFILE_A);
}
