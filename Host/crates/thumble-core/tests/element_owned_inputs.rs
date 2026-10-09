use serde_json::{json, Value};

#[test]
fn repeated_part_output_entries_are_not_collapsed_into_a_binding() {
    let mut state = thumble_core::PersistentState::minimal("server").unwrap();
    state.profiles[0]["customization"] = json!({"elements":[{
        "id":"B6FD297D-7508-4FF4-AFF7-97B3831F6AD0","kind":"joystick",
        "partOutputs":["joystick_up",{"keyboard":{"keyCode":49}},"joystick_up",{"keyboard":{"keyCode":48}}]
    }]});
    state.key_bindings = Default::default();
    state.output_bindings = Default::default();
    state.profile_key_bindings.clear();
    state.profile_output_bindings.clear();
    let before = state.clone();
    assert!(state.normalize().is_err());
    assert_eq!(state, before);
}
use thumble_core::{ButtonBindings, KeyBinding, OutputBinding, PersistentState};
use thumble_protocol::{KeypadElementID, KeypadElementInputPart};

const FIRST: &str = "A0123456-1111-2222-3333-444444444444";
const SECOND: &str = "B0123456-1111-2222-3333-444444444444";

fn state(elements: Value) -> PersistentState {
    let mut state = PersistentState::minimal("test").unwrap();
    state.profiles[0]["outputMode"] = json!("custom");
    state.profiles[0]["customization"] = json!({"elements":elements});
    state.profile_key_bindings.clear();
    state.profile_output_bindings.clear();
    state.key_bindings = ButtonBindings::default();
    state.output_bindings = ButtonBindings::default();
    state.normalize().unwrap();
    state
}

#[test]
fn imported_declarations_enforce_total_and_specialized_capacities() {
    let profile = |kind: &str, count: usize| {
        let elements = (1..=count)
            .map(|ordinal| {
                json!({
                    "id": format!("1A939AE0-3E1E-440B-9162-{ordinal:012X}"),
                    "label": "Same", "kind": kind, "layout": {}
                })
            })
            .collect::<Vec<_>>();
        json!({"customization": {"elements": elements}})
    };
    assert!(thumble_core::validate_element_identities(&profile(
        "button", 128
    )));
    for (kind, count) in [
        ("button", 129),
        ("joystick", 3),
        ("trigger", 3),
        ("trackpad", 2),
    ] {
        assert!(
            !thumble_core::validate_element_identities(&profile(kind, count)),
            "{kind}"
        );
    }
}

#[test]
fn imported_appearance_and_design_references_reject_before_normalization() {
    let identity = json!({"kind":"custom", "id":FIRST});
    let group = json!({"id":"63C0723C-F6C4-42B1-ADE8-18CC07020EEB", "name":"Owned", "children":[identity], "isLocked":false, "isHidden":false});
    let metadata = json!({"schemaVersion":1, "layerOrder":[identity, {"kind":"system","system":"top_bar_activation"}], "groups":[group], "grid":{}, "guides":[], "tags":[]});
    let source = json!({"customization":{"elements":[{"id":FIRST,"kind":"button"}], "designMetadata":metadata}});
    assert!(thumble_core::validate_element_identities(&source));
    let mut invalid = Vec::new();
    for field in ["labelOverrides", "buttonCustomizations"] {
        let value = if field == "labelOverrides" {
            json!("Orphan")
        } else {
            json!({})
        };
        for map in [
            json!([SECOND, value]),
            json!([FIRST, value, FIRST.to_lowercase(), value]),
            json!({SECOND:value}),
        ] {
            let mut candidate = source.clone();
            candidate["customization"][field] = map;
            invalid.push(candidate);
        }
    }
    for order in [
        json!([{"kind":"custom","id":SECOND}]),
        json!(["builtin.jump"]),
        json!([identity, identity]),
    ] {
        let mut candidate = source.clone();
        candidate["customization"]["designMetadata"]["layerOrder"] = order;
        invalid.push(candidate);
    }
    for children in [
        json!([{"kind":"custom","id":SECOND}]),
        json!([identity, identity]),
    ] {
        let mut candidate = source.clone();
        candidate["customization"]["designMetadata"]["groups"][0]["children"] = children;
        invalid.push(candidate);
    }
    let mut candidate = source.clone();
    candidate["customization"]["designMetadata"]["groups"] = json!([group, group]);
    invalid.push(candidate);
    let mut candidate = source.clone();
    candidate["customization"]["customButtons"] =
        json!([{"id":FIRST, "controlKind":"joystick", "layout":{}}]);
    invalid.push(candidate);
    for (index, candidate) in invalid.iter().enumerate() {
        assert!(
            !thumble_core::validate_element_identities(candidate),
            "case {index}"
        );
    }
}

#[test]
fn imported_mirrors_never_declare_or_override_executable_settings() {
    let mapping =
        |key| json!({"up":{"keyboard":{"keyCode":key}}, "down":{}, "left":{}, "right":{}});
    let joystick = |target| json!({"analogTarget":target, "sendsDigitalDirections":false, "deadZone":0.12, "sensitivity":1, "invertX":false,"invertY":false,"snapToCardinal":false});
    let trigger = |target| json!({"target":target,"orientation":"vertical","deadZone":0.03,"sensitivity":1,"sendsDigitalButton":false,"digitalThreshold":0.5});
    let trackpad = |tap| json!({"sensitivity":1.2,"scrollSensitivity":0.85,"naturalScrolling":true,"tapToClick":tap,"twoFingerScroll":true});
    for (kind, field, owned, injected) in [
        ("joystick", "joystickMapping", Value::Null, mapping(126)),
        ("joystick", "joystickMapping", mapping(126), mapping(13)),
        (
            "joystick",
            "joystickOutputSettings",
            joystick("right_stick"),
            joystick("left_stick"),
        ),
        (
            "trigger",
            "triggerSettings",
            trigger("left"),
            trigger("right"),
        ),
        (
            "trackpad",
            "trackpadSettings",
            trackpad(false),
            trackpad(true),
        ),
    ] {
        let mut source = json!({"customization":{"elements":[{"id":FIRST,"kind":kind}],"customButtons":[{"id":FIRST,"controlKind":kind,"layout":{}}]}});
        source["customization"]["elements"][0][field] = owned;
        assert!(
            thumble_core::validate_element_identities(&source),
            "omitted mirror settings must preserve declaration: {field}"
        );
        source["customization"]["customButtons"][0][field] = injected;
        assert!(
            !thumble_core::validate_element_identities(&source),
            "mirror must not redefine {field}"
        );
    }
}

#[test]
fn arbitrary_controls_with_identical_labels_have_independent_outputs() {
    let state = state(json!([
        {"id":FIRST,"label":"Jump","output":{"keyboard":{"keyCode":36,"modifiersRawValue":0},"gamepadButtons":["west"]}},
        {"id":SECOND,"label":"Jump","output":{"keyboard":{"keyCode":48,"modifiersRawValue":0},"gamepadButtons":["east"]}}
    ]));
    assert_eq!(
        state
            .resolve_button_output(KeypadElementID::parse(FIRST).unwrap())
            .unwrap()
            .keyboard,
        Some(KeyBinding::new(36, 0))
    );
    assert_eq!(
        state
            .resolve_button_output(KeypadElementID::parse(SECOND).unwrap())
            .unwrap()
            .keyboard,
        Some(KeyBinding::new(48, 0))
    );
    assert!(state
        .resolve_button_output(KeypadElementID::preset(5))
        .is_none());
    assert!(state.needs_virtual_gamepad());
}

#[test]
fn explicit_empty_binding_does_not_restore_a_default_or_global_map() {
    let mut state = state(
        json!([{ "id":FIRST,"output":{"gamepadButtons":[]},"defaultOutput":{"keyboard":{"keyCode":36},"gamepadButtons":["south"]} }]),
    );
    let id = KeypadElementID::parse(FIRST).unwrap();
    state
        .output_bindings
        .insert(id, OutputBinding::keyboard(KeyBinding::new(48, 0)));
    let output = state.resolve_button_output(id).unwrap();
    assert!(output.keyboard.is_none());
    assert!(output.gamepad_buttons.is_empty());
}

#[test]
fn joystick_parts_bind_outputs_without_routing_through_another_control() {
    let state = state(json!([{ "id":FIRST,"kind":"joystick","joystickMapping":{
        "up":{"keyboard":{"keyCode":126,"modifiersRawValue":0},"gamepadButtons":["dpadUp"]},
        "down":{"gamepadButtons":[]},"left":{"gamepadButtons":[]},"right":{"gamepadButtons":[]}
    }}]));
    assert_eq!(
        state
            .resolve_element_output(FIRST, KeypadElementInputPart::JoystickUp)
            .unwrap()
            .keyboard,
        Some(KeyBinding::new(126, 0))
    );
    assert!(state
        .resolve_element_output(FIRST, KeypadElementInputPart::JoystickDown)
        .unwrap()
        .keyboard
        .is_none());
}

#[test]
fn named_keys_and_duplicate_uuid_keys_are_rejected() {
    for key in ["jump", "attack", "dash", "focus", "custom1", "up"] {
        assert!(
            serde_json::from_value::<ButtonBindings<KeyBinding>>(json!({key:{"keyCode":36}}))
                .is_err()
        );
    }
    assert!(serde_json::from_value::<ButtonBindings<KeyBinding>>(
        json!({FIRST:{"keyCode":36},FIRST.to_lowercase():{"keyCode":48}})
    )
    .is_err());
}

#[test]
fn routing_fields_and_old_joystick_targets_are_rejected_without_migration() {
    for field in [
        "button",
        "legacySlot",
        "mappedButton",
        "builtInButton",
        "inputID",
        "defaultControlID",
    ] {
        let mut state = PersistentState::minimal("test").unwrap();
        state.profiles[0]["customization"]["elements"][0][field] = Value::Null;
        assert!(state.normalize().is_err(), "{field}");
    }
    let mut state = PersistentState::minimal("test").unwrap();
    state.profiles[0]["customization"]["elements"][0]["joystickMapping"] =
        json!({"up":"jump","down":"down","left":"left","right":"right"});
    assert!(state.normalize().is_err());
    for version in [1, 2] {
        let mut state = PersistentState::minimal("test").unwrap();
        state.schema_version = version;
        assert!(state.normalize().is_err());
    }
}

#[test]
fn imports_reject_undeclared_custom_mirrors() {
    let mut empty = state(json!([]));
    empty.profiles[0]["customization"]["customButtons"] = json!([{
        "id": FIRST, "label": "Undeclared", "controlKind": "button", "layout": {}
    }]);
    assert!(empty.normalize().is_err());
}

#[test]
fn imports_must_declare_controls_and_do_not_reconstruct_starters() {
    for customization in [json!({}), json!({"elements":null})] {
        let mut state = PersistentState::minimal("test").unwrap();
        state.profiles[0]["customization"] = customization;
        assert!(state.normalize().is_err());
    }
    let empty = state(json!([]));
    assert!(empty
        .resolve_button_output(KeypadElementID::preset(5))
        .is_none());
    assert!(!empty.needs_virtual_gamepad());
    let mut missing = PersistentState::minimal("test").unwrap();
    missing.profiles[0]
        .as_object_mut()
        .unwrap()
        .remove("customization");
    assert!(missing.normalize().is_err());
}

#[test]
fn missing_joystick_bindings_do_not_materialize_starter_direction_outputs() {
    let state = state(json!([{"id":FIRST,"kind":"joystick","label":"Unbound"}]));
    assert!(state
        .resolve_element_output(FIRST, KeypadElementInputPart::JoystickUp)
        .is_none());
    assert!(!state.needs_virtual_gamepad());
}

#[test]
fn obsolete_unhashed_configuration_versions_are_rejected_not_upgraded() {
    let mut envelope = json!({
        "schema":thumble_core::PROFILE_ARTIFACT_SCHEMA,
        "version":4, "profiles":[thumble_core::minimal_default_profile()]
    });
    assert!(thumble_core::ProfileArtifact::decode_import_json(
        &serde_json::to_vec(&envelope).unwrap()
    )
    .is_ok());
    for version in [1, 2, 3] {
        envelope["version"] = json!(version);
        assert!(thumble_core::ProfileArtifact::decode_import_json(
            &serde_json::to_vec(&envelope).unwrap()
        )
        .is_err());
    }
    envelope.as_object_mut().unwrap().remove("version");
    assert!(thumble_core::ProfileArtifact::decode_import_json(
        &serde_json::to_vec(&envelope).unwrap()
    )
    .is_err());
}
