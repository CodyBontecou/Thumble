mod common;

use serde_json::json;

const ELEMENT: &str = "ab765b39-dfa7-4b24-a30f-bcc05bf85f3a";
const JOYSTICK: &str = "25a4f41a-7c43-4d12-b7c0-51e0f259c695";
const PROFILE: &str = "B16C0A67-B9EA-42CA-966B-9F23A09CDE8B";
use std::collections::{BTreeMap, BTreeSet};
use thumble_core::{
    ButtonBindings, KeyBinding, KeyStroke, OutputBinding, PersistentState, StateError,
    TrustedClient, CURRENT_SCHEMA_VERSION, DEFAULT_PROFILE_ID, INITIAL_CONFIGURATION_REVISION,
};
use thumble_protocol::{KeypadElementID, KeypadElementInputPart};

#[test]
fn key_bindings_accept_legacy_mac_and_direct_shared_json_shapes() {
    let legacy: KeyBinding = serde_json::from_value(json!({
        "keyCode": 40,
        "modifiers": 9,
        "sequence": [
            {"keyCode": 11, "modifiers": 8},
            {"keyCode": 4, "modifiers": 0}
        ]
    }))
    .unwrap();
    assert_eq!(legacy.key_code, 40);
    assert_eq!(legacy.modifiers, 9);
    assert_eq!(legacy.strokes()[0], KeyStroke::new(11, 8));

    let direct: KeyBinding = serde_json::from_value(json!({
        "keyCode": 40,
        "modifiersRawValue": 3,
        "sequence": [
            {"keyCode": 12, "modifiersRawValue": 1},
            {"keyCode": 13, "modifiersRawValue": 2}
        ]
    }))
    .unwrap();
    assert_eq!(direct.modifiers, 3);
    assert_eq!(direct.strokes()[1], KeyStroke::new(13, 2));

    let serialized = serde_json::to_value(direct).unwrap();
    assert_eq!(serialized["modifiers"], 3);
    assert!(serialized.get("modifiersRawValue").is_none());
    assert_eq!(serialized["sequence"][0]["modifiers"], 1);
}

#[test]
fn portable_state_round_trips_tokens_profiles_and_binding_layers_losslessly() {
    let mut state = PersistentState::minimal("stable-server").unwrap();
    state.trusted_clients.insert(
        "opaque-token".to_owned(),
        TrustedClient {
            name: "Phone".to_owned(),
            created_at: 10,
            last_seen_at: 20,
        },
    );
    state.profiles[0]["futureProfileField"] = json!({"kept": [1, true, null]});
    state.profiles[0]["customization"]["futureCustomizationField"] = json!("kept");
    state
        .profile_key_bindings
        .get_mut(DEFAULT_PROFILE_ID)
        .unwrap()
        .insert(KeypadElementID::preset(18), KeyBinding::new(99, 4));

    let bytes = serde_json::to_vec(&state).unwrap();
    let decoded: PersistentState = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(decoded, state);
    assert_eq!(
        decoded.profiles[0]["futureProfileField"],
        json!({"kept": [1, true, null]})
    );
    assert_eq!(
        decoded.profiles[0]["customization"]["futureCustomizationField"],
        "kept"
    );
    assert_eq!(decoded.trusted_clients["opaque-token"].last_seen_at, 20);
}

#[test]
fn unsupported_output_modes_reject_without_normalization_or_runtime_construction() {
    for mode in [
        json!("gamepad"),
        json!("future-mode"),
        json!(""),
        json!(true),
        json!(1),
        json!([]),
        json!({}),
    ] {
        let mut state = PersistentState::minimal("mode-rejection").unwrap();
        state.profiles[0]["outputMode"] = mode.clone();
        let before = state.clone();
        assert!(
            state.validate().is_err(),
            "invalid mode was accepted: {mode}"
        );
        assert!(
            state.normalize().is_err(),
            "invalid mode was normalized: {mode}"
        );
        assert_eq!(state, before);
        assert!(thumble_core::ConfigurationDocument::from_state(&state).is_err());
        assert!(thumble_core::HostCore::new(state, "111111").is_err());
    }
    for mode in [
        None,
        Some(json!(null)),
        Some(json!("keyboard")),
        Some(json!("controller")),
        Some(json!("custom")),
    ] {
        let mut state = PersistentState::minimal("valid-mode").unwrap();
        if let Some(mode) = mode {
            state.profiles[0]["outputMode"] = mode;
        } else {
            state.profiles[0].as_object_mut().unwrap().remove("outputMode");
        }
        state.profiles[0]["futureProfileField"] = json!({"outputMode":"future-mode"});
        state.normalize().unwrap();
        assert_eq!(
            state.profiles[0]["futureProfileField"],
            json!({"outputMode":"future-mode"})
        );
        thumble_core::ConfigurationDocument::from_state(&state).unwrap();
        thumble_core::HostCore::new(state, "111111").unwrap();
    }
}

#[test]
fn explicit_empty_profile_catalog_rejects_without_constructing_a_default_profile() {
    let mut state = PersistentState::minimal("stable-server").unwrap();
    state.profiles.clear();
    let before = state.clone();
    assert!(state.normalize().is_err());
    assert_eq!(state, before);
}

#[test]
fn direct_element_output_in_orientation_variant_beats_primary_sidecar() {
    let mut state = PersistentState::minimal("server").unwrap();
    state.profiles = vec![json!({
        "id": PROFILE,
        "name": "Raw",
        "outputMode": "custom",
        "unknown": {"preserve": true},
        "customization": {
            "elements": [{
                "id": ELEMENT.to_uppercase(),
                "futureElementField": 42
            }]
        },
        "landscapeCustomization": {
            "elements": [{
                "id": ELEMENT,
                "output": {
                    "keyboard": {
                        "keyCode": 7,
                        "modifiersRawValue": 5,
                        "sequence": [
                            {"keyCode": 7, "modifiersRawValue": 5},
                            {"keyCode": 8, "modifiersRawValue": 0}
                        ]
                    },
                    "gamepadButtons": ["south"]
                },
                "unknownLandscapeField": "retained"
            }]
        }
    })];
    state.active_profile_id = PROFILE.to_owned();
    state.default_profile_id = PROFILE.to_owned();
    state.key_bindings = Default::default();
    state.output_bindings = Default::default();
    state.profile_key_bindings.clear();
    state.profile_output_bindings.clear();
    let mut sidecar = ButtonBindings::default();
    sidecar.insert(KeypadElementID::parse(ELEMENT).unwrap(), OutputBinding::keyboard(KeyBinding::new(99, 0)));
    state.profile_output_bindings.insert(PROFILE.to_owned(), sidecar);
    state.normalize().unwrap();

    let output = state
        .resolve_element_output(&ELEMENT.to_uppercase(), KeypadElementInputPart::Primary)
        .unwrap();
    let keyboard = output.keyboard.unwrap();
    assert_eq!(
        keyboard.strokes(),
        vec![KeyStroke::new(7, 5), KeyStroke::new(8, 0)]
    );
    assert_eq!(output.gamepad_buttons, BTreeSet::from(["south".to_owned()]));
    assert_eq!(state.profiles[0]["unknown"]["preserve"], true);
    assert_eq!(
        state.profiles[0]["landscapeCustomization"]["elements"][0]["unknownLandscapeField"],
        "retained"
    );
}

#[test]
fn part_outputs_support_swift_dictionary_arrays_and_owned_joystick_defaults() {
    let mut state = PersistentState::minimal("server").unwrap();
    state.profiles = vec![json!({
        "id": PROFILE,
        "name": "Directional",
        "customization": {
            "elements": [{
                "id": JOYSTICK,
                "kind": "joystick",
                "partOutputs": [
                    "joystick_left",
                    {"keyboard": {"keyCode": 12, "modifiersRawValue": 1}}
                ],
                "joystickMapping": {
                    "up": {"keyboard":{"keyCode":126}},
                    "down": {"keyboard":{"keyCode":125}},
                    "left": {"keyboard":{"keyCode":123}},
                    "right": {"keyboard":{"keyCode":124}}
                }
            }]
        }
    })];
    state.active_profile_id = PROFILE.to_owned();
    state.default_profile_id = PROFILE.to_owned();
    state.key_bindings = Default::default();
    state.output_bindings = Default::default();
    state.profile_key_bindings.clear();
    state.profile_output_bindings.clear();
    let mut profile_outputs = ButtonBindings::default();
    profile_outputs.insert(
        KeypadElementID::parse(JOYSTICK).unwrap(),
        OutputBinding::keyboard(KeyBinding::new(99, 0)),
    );
    state
        .profile_output_bindings
        .insert(PROFILE.to_owned(), profile_outputs);
    state.normalize().unwrap();

    assert_eq!(
        state
            .resolve_element_output(JOYSTICK, KeypadElementInputPart::JoystickLeft)
            .unwrap()
            .keyboard,
        Some(KeyBinding::new(12, 1))
    );
    assert_eq!(
        state
            .resolve_element_output(JOYSTICK, KeypadElementInputPart::JoystickUp)
            .unwrap()
            .keyboard,
        Some(KeyBinding::new(126, 0))
    );
}

#[test]
fn profile_sidecars_apply_to_declared_controls_and_explicit_empty_output_suppresses_key_fallback() {
    let mut state = PersistentState::minimal("server").unwrap();
    let global_jump = state.resolve_button_output(KeypadElementID::preset(5)).unwrap();
    assert_eq!(global_jump.keyboard, Some(KeyBinding::new(36, 0)));

    state.profiles[0]["customization"] = json!({"elements":[
        {"id":KeypadElementID::preset(5), "kind":"button"},
        {"id":KeypadElementID::preset(6), "kind":"button"}
    ]});
    let mut profile_outputs = ButtonBindings::default();
    profile_outputs.insert(
        KeypadElementID::preset(5),
        OutputBinding::keyboard(KeyBinding::new(49, 2)),
    );
    profile_outputs.insert(KeypadElementID::preset(6), OutputBinding::default());
    state
        .profile_output_bindings
        .insert(DEFAULT_PROFILE_ID.to_owned(), profile_outputs);

    assert_eq!(
        state
            .resolve_button_output(KeypadElementID::preset(5))
            .unwrap()
            .keyboard,
        Some(KeyBinding::new(49, 2))
    );
    assert_eq!(
        state.resolve_button_output(KeypadElementID::preset(6)).unwrap(),
        OutputBinding::default()
    );
}

#[test]
fn profile_keyboard_binding_applies_only_to_a_declared_unconfigured_control() {
    let mut state = PersistentState::minimal("server").unwrap();
    state.profiles[0]["customization"] = json!({"elements":[{"id":KeypadElementID::preset(5), "kind":"button"}]});
    state.profile_output_bindings.clear();
    state
        .profile_key_bindings
        .get_mut(DEFAULT_PROFILE_ID)
        .unwrap()
        .insert(KeypadElementID::preset(5), KeyBinding::new(49, 2));

    assert_eq!(
        state
            .resolve_button_output(KeypadElementID::preset(5))
            .unwrap()
            .keyboard,
        Some(KeyBinding::new(49, 2))
    );
}

#[test]
fn trusted_clients_are_keyed_by_token_not_duplicated_inside_values() {
    let value = json!({
        "schemaVersion": CURRENT_SCHEMA_VERSION,
        "serverID": "server",
        "trustedClients": {
            "opaque": {"name": "Phone", "createdAt": 1, "lastSeenAt": 2}
        },
        "profiles": [{"id": "p", "customization": {"elements":[]}}],
        "activeProfileID": "p",
        "defaultProfileID": "p",
        "keyBindings": {},
        "outputBindings": {},
        "profileKeyBindings": {},
        "profileOutputBindings": {}
    });
    let state: PersistentState = serde_json::from_value(value).unwrap();
    assert_eq!(state.trusted_clients["opaque"].name, "Phone");
    let encoded = serde_json::to_value(state).unwrap();
    assert!(encoded["trustedClients"]["opaque"].get("token").is_none());
}

#[test]
fn arbitrary_uuid_binding_keys_survive_deterministic_serialization_and_names_are_rejected() {
    let mut bindings = ButtonBindings::default();
    bindings.insert(KeypadElementID::parse(ELEMENT).unwrap(), KeyBinding::new(1, 0));
    assert!(bindings.get_raw("future-button").is_none());
    assert!(serde_json::from_value::<ButtonBindings<KeyBinding>>(json!({"future-button":{"keyCode":1}})).is_err());
    bindings.insert(KeypadElementID::preset(1), KeyBinding::new(126, 0));
    let value = serde_json::to_value(&bindings).unwrap();
    let keys = value
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect::<Vec<_>>();
    assert_eq!(keys, vec![KeypadElementID::preset(1).to_string(), ELEMENT.to_uppercase()]);
    assert_eq!(bindings.iter_ids().map(|(id, _)| id.to_string()).collect::<Vec<_>>(), keys);

    let round_trip: ButtonBindings<KeyBinding> = serde_json::from_value(value).unwrap();
    assert_eq!(
        round_trip.get_raw(ELEMENT),
        Some(&KeyBinding::new(1, 0))
    );
}

#[test]
fn obsolete_state_schemas_are_rejected_without_migration() {
    for version in [1, 2] {
        let mut encoded = serde_json::to_value(PersistentState::minimal("stable-server").unwrap()).unwrap();
        encoded["schemaVersion"] = json!(version);
        encoded.as_object_mut().unwrap().remove("configurationRevision");
        let mut decoded: PersistentState = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded.configuration_revision, INITIAL_CONFIGURATION_REVISION);
        let before = decoded.clone();
        assert_eq!(decoded.normalize(), Err(StateError::UnsupportedSchemaVersion(version)));
        assert_eq!(decoded, before);
    }
}

#[test]
fn configuration_revisions_are_monotonic_and_fail_on_exhaustion() {
    let mut state = PersistentState::minimal("stable-server").unwrap();
    assert_eq!(state.bump_configuration_revision().unwrap(), 2);
    assert_eq!(state.bump_configuration_revision().unwrap(), 3);
    state.configuration_revision = u64::MAX;
    assert_eq!(
        state.bump_configuration_revision(),
        Err(StateError::ConfigurationRevisionExhausted)
    );
}

#[test]
fn output_binding_retains_unsupported_gamepad_names_without_advertising_them() {
    let binding = OutputBinding {
        keyboard: None,
        gamepad_buttons: BTreeSet::from(["futureGamepadButton".to_owned()]),
    };
    let mut bindings = BTreeMap::new();
    bindings.insert("profile".to_owned(), binding.clone());
    let value = serde_json::to_value(&binding).unwrap();
    assert_eq!(value["gamepadButtons"], json!(["futureGamepadButton"]));
    assert_eq!(
        serde_json::to_value(OutputBinding::keyboard(KeyBinding::new(1, 0))).unwrap()
            ["gamepadButtons"],
        json!([])
    );
    assert_eq!(bindings["profile"], binding);
}
