mod common;

use common::{no_tokens, pair};
use serde_json::json;
use thumble_core::{
    Effect, HostCore, KeyBinding, OutputBinding, PersistentState, VirtualGamepadButton,
    DEFAULT_PROFILE_ID,
};
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType, ControllerWireCodec, GameButton,
    KeypadElementInputPart, VirtualGamepadStick, VirtualGamepadTrigger,
};

fn state() -> PersistentState {
    let mut state = PersistentState::minimal("server-1").unwrap();
    state.profiles[0]["outputMode"] = json!("custom");
    let mixed = OutputBinding {
        keyboard: Some(KeyBinding::new(36, 0)),
        gamepad_buttons: ["south", "futureButton"].map(str::to_owned).into(),
    };
    let outputs = state
        .profile_output_bindings
        .get_mut(DEFAULT_PROFILE_ID)
        .unwrap();
    outputs.insert(GameButton::Jump, mixed.clone());
    outputs.insert(GameButton::Attack, mixed);
    state
}

fn core() -> HostCore {
    let mut state = state();
    state
        .profiles
        .push(json!({"id":"next", "outputMode":"keyboard"}));
    let mut core = HostCore::new(state, "111111").unwrap();
    pair(&mut core, 1, "token");
    core
}

fn digital(button: GameButton, pressed: bool, sequence: u64, press: u64) -> ControllerMessage {
    let mut message = ControllerMessage::new(ControllerMessageType::Button, 0);
    message.button = Some(button);
    message.state = Some(if pressed {
        ButtonPressState::Down
    } else {
        ButtonPressState::Up
    });
    message.input_protocol_version = Some(2);
    message.input_generation = Some(1);
    message.input_sequence = Some(sequence);
    message.press_identifier = Some(press);
    message
}

fn stick(stick: VirtualGamepadStick, sequence: u64, x: f64, y: f64) -> ControllerMessage {
    let mut message = ControllerMessage::new(ControllerMessageType::GamepadAnalog, 0);
    message.input_protocol_version = Some(2);
    message.input_generation = Some(1);
    message.analog_sequence = Some(sequence);
    message.analog_stick = Some(stick);
    message.analog_x = Some(x);
    message.analog_y = Some(y);
    message
}

fn trigger(trigger: VirtualGamepadTrigger, sequence: u64, value: f64) -> ControllerMessage {
    let mut message = stick(VirtualGamepadStick::Left, sequence, 0.0, 0.0);
    message.analog_stick = None;
    message.analog_x = None;
    message.analog_y = None;
    message.analog_trigger = Some(trigger);
    message.analog_value = Some(value);
    message
}

fn send(core: &mut HostCore, message: ControllerMessage, time: i64) -> Vec<Effect> {
    core.handle_message(1, message, time, &mut no_tokens())
        .unwrap()
}

fn buttons(effects: &[Effect]) -> Vec<(VirtualGamepadButton, bool)> {
    effects
        .iter()
        .filter_map(|effect| match effect {
            Effect::GamepadButton { button, pressed } => Some((*button, *pressed)),
            _ => None,
        })
        .collect()
}

fn analog(effects: &[Effect]) -> Vec<Effect> {
    effects
        .iter()
        .filter(|effect| {
            matches!(
                effect,
                Effect::GamepadStick { .. } | Effect::GamepadTrigger { .. }
            )
        })
        .cloned()
        .collect()
}

#[test]
fn host_release_all_retires_generation_before_late_analog_can_reassert() {
    let mut core = core();
    send(&mut core, stick(VirtualGamepadStick::Left, 1, 1.0, 0.0), 0);
    let effects = core.release_all_locally();
    let reset = effects
        .iter()
        .find_map(|effect| match effect {
            Effect::SendMessage { message, .. }
                if message.message_type == ControllerMessageType::ReleaseAll =>
            {
                Some(message)
            }
            _ => None,
        })
        .expect("phone must receive generation reset");
    assert_eq!(reset.input_generation, Some(2));
    assert!(analog(&send(
        &mut core,
        stick(VirtualGamepadStick::Left, 2, 1.0, 0.0),
        10
    ))
    .is_empty());
    let mut fresh = stick(VirtualGamepadStick::Left, 1, 0.5, 0.0);
    fresh.input_generation = Some(2);
    assert_eq!(
        analog(&send(&mut core, fresh, 20)),
        vec![Effect::GamepadStick {
            stick: VirtualGamepadStick::Left,
            x: 0.5,
            y: 0.0
        }]
    );
}

#[test]
fn local_held_tests_share_phone_ownership_and_expire_when_the_cli_exits() {
    let mut core = core();
    let binding = core
        .persistent_state()
        .resolve_button_output(GameButton::Jump)
        .unwrap();
    let local = core
        .set_local_output_binding("button:jump", Some(binding), true, 0)
        .unwrap();
    assert_eq!(buttons(&local), vec![(VirtualGamepadButton::South, true)]);
    assert!(buttons(&send(&mut core, digital(GameButton::Jump, true, 1, 42), 10)).is_empty());
    let up = core
        .set_local_output_binding("button:jump", None, false, 20)
        .unwrap();
    assert!(buttons(&up).is_empty());
    assert_eq!(
        buttons(&send(
            &mut core,
            digital(GameButton::Jump, false, 2, 42),
            30
        )),
        vec![(VirtualGamepadButton::South, false)]
    );
    let binding = core
        .persistent_state()
        .resolve_button_output(GameButton::Jump)
        .unwrap();
    core.set_local_output_binding("button:jump", Some(binding), true, 100)
        .unwrap();
    assert!(buttons(&core.expire_holds(30_099, 1_750)).is_empty());
    assert_eq!(
        buttons(&core.expire_holds(30_100, 1_750)),
        vec![(VirtualGamepadButton::South, false)]
    );
}

#[test]
fn keyboard_sequences_do_not_skip_gamepad_holds_and_digital_triggers_are_independent() {
    let mut state = state();
    let keyboard = KeyBinding::from_strokes(vec![
        thumble_core::KeyStroke::new(36, 0),
        thumble_core::KeyStroke::new(48, 0),
    ])
    .unwrap();
    state
        .profile_output_bindings
        .get_mut(DEFAULT_PROFILE_ID)
        .unwrap()
        .insert(
            GameButton::Jump,
            OutputBinding {
                keyboard: Some(keyboard.clone()),
                gamepad_buttons: ["leftTriggerButton".to_owned()].into(),
            },
        );
    let mut core = HostCore::new(state, "111111").unwrap();
    pair(&mut core, 1, "token");
    let down = send(&mut core, digital(GameButton::Jump, true, 1, 10), 0);
    assert!(down.contains(&Effect::TapSequence(keyboard.strokes())));
    assert_eq!(
        buttons(&down),
        vec![(VirtualGamepadButton::LeftTriggerButton, true)]
    );
    assert!(analog(&down).is_empty());
    let duplicate = send(&mut core, digital(GameButton::Jump, true, 2, 10), 40);
    assert!(buttons(&duplicate).is_empty());
    assert!(!duplicate.contains(&Effect::TapSequence(keyboard.strokes())));
    let overlap = send(&mut core, digital(GameButton::Jump, true, 3, 11), 50);
    assert!(overlap.contains(&Effect::TapSequence(keyboard.strokes())));
    assert!(buttons(&overlap).is_empty());
    assert!(buttons(&core.expire_holds(100, 60)).is_empty());
    assert_eq!(
        buttons(&core.expire_holds(110, 60)),
        vec![(VirtualGamepadButton::LeftTriggerButton, false)]
    );
}

#[test]
fn missing_legacy_mode_keeps_mixed_outputs_and_keyboard_gates_direct_elements() {
    let mut state = state();
    state.profiles[0]
        .as_object_mut()
        .unwrap()
        .remove("outputMode");
    assert!(state.needs_virtual_gamepad());
    state.profiles[0]["customization"] = json!({"elements":[
        {"id":"e", "output":{"keyboard":{"keyCode":48}, "gamepadButtons":["east"]}}
    ]});
    let mut core = HostCore::new(state, "111111").unwrap();
    pair(&mut core, 1, "token");
    assert_eq!(
        buttons(&send(&mut core, digital(GameButton::Jump, true, 1, 1), 0)),
        vec![(VirtualGamepadButton::South, true)]
    );
    let mut replacement = core.persistent_state().clone();
    replacement.profiles[0]["outputMode"] = json!("keyboard");
    core.install_validated_persisted_state(replacement);
    let mut element = digital(GameButton::Jump, true, 2, 2);
    element.input_generation = core.status().active_generation;
    element.message_type = ControllerMessageType::ElementInput;
    element.button = None;
    element.element_id = Some("e".into());
    let effects = send(&mut core, element, 1);
    assert!(buttons(&effects).is_empty());
    assert!(effects.contains(&Effect::KeyDown(KeyBinding::new(48, 0))));
    assert!(
        core.persistent_state().profiles[0]["customization"]["elements"][0]["output"]
            ["gamepadButtons"]
            .as_array()
            .unwrap()
            .contains(&json!("east"))
    );
}

#[test]
fn materialization_scans_custom_buttons_part_outputs_and_resolved_global_fallback() {
    let base = PersistentState::minimal("server-1").unwrap();
    for customization in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        for control in [
            json!({"controlKind":"trigger"}),
            json!({"controlKind":"joystick", "joystickOutputSettings":{"analogTarget":"right_stick"}}),
            json!({"controlKind":"button", "partOutputs":{"primary":{"gamepadButtons":["south"]}}}),
            json!({"controlKind":"button", "partOutputs":["primary", {"gamepadButtons":["south"]}]}),
        ] {
            let mut state = base.clone();
            state.profiles[0]["outputMode"] = json!("custom");
            state.profiles[0][customization] = json!({"customButtons":[control]});
            assert!(state.needs_virtual_gamepad());
            state.profiles[0]["outputMode"] = json!("keyboard");
            assert!(!state.needs_virtual_gamepad());
        }
    }
    let mut state = base;
    state.profiles[0]["outputMode"] = json!("custom");
    state.profile_output_bindings.clear();
    state.profile_key_bindings.clear();
    state.output_bindings.insert(
        GameButton::Jump,
        OutputBinding {
            keyboard: None,
            gamepad_buttons: ["south".to_owned()].into(),
        },
    );
    assert!(state.needs_virtual_gamepad());
    state.output_bindings.insert(
        GameButton::Jump,
        OutputBinding {
            keyboard: None,
            gamepad_buttons: ["futureButton".to_owned()].into(),
        },
    );
    assert!(!state.needs_virtual_gamepad());
}

#[test]
fn mixed_outputs_refcount_each_button_and_capture_complete_binding() {
    let mut core = core();
    let first = send(&mut core, digital(GameButton::Jump, true, 1, 10), 0);
    assert_eq!(buttons(&first), vec![(VirtualGamepadButton::South, true)]);
    assert!(first.contains(&Effect::KeyDown(KeyBinding::new(36, 0))));
    let overlap = send(&mut core, digital(GameButton::Jump, true, 2, 11), 10);
    assert!(buttons(&overlap).is_empty());
    assert!(overlap.contains(&Effect::PulseKey(KeyBinding::new(36, 0))));
    assert!(buttons(&send(
        &mut core,
        digital(GameButton::Attack, true, 3, 20),
        20
    ))
    .is_empty());
    assert!(buttons(&send(
        &mut core,
        digital(GameButton::Jump, false, 4, 10),
        30
    ))
    .is_empty());
    assert!(buttons(&send(
        &mut core,
        digital(GameButton::Jump, false, 5, 11),
        40
    ))
    .is_empty());
    let last = send(&mut core, digital(GameButton::Attack, false, 6, 20), 50);
    assert_eq!(buttons(&last), vec![(VirtualGamepadButton::South, false)]);
    assert!(last.contains(&Effect::KeyUp(KeyBinding::new(36, 0))));
    // A replacement releases the captured old binding, never the new mapping.
    send(&mut core, digital(GameButton::Jump, true, 7, 30), 60);
    let mut replacement = core.persistent_state().clone();
    replacement
        .profile_output_bindings
        .get_mut(DEFAULT_PROFILE_ID)
        .unwrap()
        .insert(
            GameButton::Jump,
            OutputBinding {
                keyboard: Some(KeyBinding::new(48, 0)),
                gamepad_buttons: ["east".to_owned()].into(),
            },
        );
    let released = core.install_validated_persisted_state(replacement);
    assert_eq!(
        buttons(&released),
        vec![(VirtualGamepadButton::South, false)]
    );
    assert!(released.contains(&Effect::KeyUp(KeyBinding::new(36, 0))));
    assert!(released.contains(&Effect::GamepadReset));
    assert!(buttons(&send(
        &mut core,
        digital(GameButton::Jump, false, 8, 30),
        70
    ))
    .is_empty());
}

#[test]
fn element_and_button_counts_share_typed_outputs_and_ignore_future_names_losslessly() {
    let mut state = state();
    state.profiles[0]["customization"] = json!({"elements": [{"id":"element", "partOutputs": ["trigger_digital", {"gamepadButtons":["south", "east", "futureButton"]}]}]});
    let roundtrip: PersistentState =
        serde_json::from_value(serde_json::to_value(&state).unwrap()).unwrap();
    assert!(roundtrip
        .resolve_button_output(GameButton::Jump)
        .unwrap()
        .gamepad_buttons
        .contains("futureButton"));
    let mut core = HostCore::new(roundtrip, "111111").unwrap();
    pair(&mut core, 1, "token");
    send(&mut core, digital(GameButton::Jump, true, 1, 1), 0);
    let mut element = digital(GameButton::Jump, true, 2, 2);
    element.message_type = ControllerMessageType::ElementInput;
    element.button = None;
    element.element_id = Some("ELEMENT".into());
    element.element_part = Some(KeypadElementInputPart::TriggerDigital);
    assert_eq!(
        buttons(&send(&mut core, element, 1)),
        vec![(VirtualGamepadButton::East, true)]
    );
    assert_eq!(
        buttons(&core.release_all()),
        vec![
            (VirtualGamepadButton::South, false),
            (VirtualGamepadButton::East, false)
        ]
    );
}

#[test]
fn analog_sequences_are_per_target_stale_filtered_and_compact_wrap_aware() {
    let mut core = core();
    let max = ControllerWireCodec::MAXIMUM_BUTTON_SEQUENCE_NUMBER;
    assert_eq!(
        analog(&send(
            &mut core,
            stick(VirtualGamepadStick::Left, max - 1, 0.5, -0.5),
            0
        )),
        vec![Effect::GamepadStick {
            stick: VirtualGamepadStick::Left,
            x: 0.5,
            y: -0.5
        }]
    );
    for sequence in [max - 1, max - 2] {
        assert!(analog(&send(
            &mut core,
            stick(VirtualGamepadStick::Left, sequence, 0.0, 0.0),
            1
        ))
        .is_empty());
    }
    assert_eq!(
        analog(&send(
            &mut core,
            stick(VirtualGamepadStick::Left, 1, 2.0, -2.0),
            2
        )),
        vec![Effect::GamepadStick {
            stick: VirtualGamepadStick::Left,
            x: 1.0,
            y: -1.0
        }]
    );
    assert_eq!(
        analog(&send(
            &mut core,
            trigger(VirtualGamepadTrigger::Left, 1, 2.0),
            2
        )),
        vec![Effect::GamepadTrigger {
            trigger: VirtualGamepadTrigger::Left,
            value: 1.0
        }]
    );
    assert_eq!(
        analog(&send(
            &mut core,
            trigger(VirtualGamepadTrigger::Right, 1, -1.0),
            2
        )),
        vec![Effect::GamepadTrigger {
            trigger: VirtualGamepadTrigger::Right,
            value: 0.0
        }]
    );
    assert_eq!(
        analog(&send(
            &mut core,
            stick(VirtualGamepadStick::Right, 1, 0.1, 0.2),
            2
        ))
        .len(),
        1
    );
    assert_eq!(core.status().counters.duplicate_sequences, 2);
}

#[test]
fn delayed_pre_wrap_and_excessive_forward_analog_packets_do_not_refresh_expiry() {
    let mut core = core();
    let max = ControllerWireCodec::MAXIMUM_BUTTON_SEQUENCE_NUMBER;
    send(
        &mut core,
        stick(VirtualGamepadStick::Left, max, 1.0, 0.0),
        0,
    );
    send(&mut core, stick(VirtualGamepadStick::Left, 1, 0.5, 0.0), 10);
    for sequence in [max, max / 2 + 2] {
        assert!(analog(&send(
            &mut core,
            stick(VirtualGamepadStick::Left, sequence, 1.0, 0.0),
            20
        ))
        .is_empty());
    }
    assert!(core
        .expire_holds(1_760, 1_750)
        .contains(&Effect::GamepadStick {
            stick: VirtualGamepadStick::Left,
            x: 0.0,
            y: 0.0
        }));
}

#[test]
fn malformed_analog_is_rejected_without_consuming_target_sequence() {
    let mut core = core();
    let valid = stick(VirtualGamepadStick::Left, 1, 0.5, 0.5);
    let mut invalid = Vec::new();
    let mut message = valid.clone();
    message.analog_x = Some(f64::NAN);
    invalid.push(message);
    let mut message = valid.clone();
    message.analog_y = Some(f64::INFINITY);
    invalid.push(message);
    let mut message = valid.clone();
    message.analog_y = None;
    invalid.push(message);
    let mut message = valid.clone();
    message.analog_trigger = Some(VirtualGamepadTrigger::Left);
    invalid.push(message);
    let mut message = valid.clone();
    message.analog_stick = None;
    invalid.push(message);
    let mut message = valid.clone();
    message.analog_sequence = None;
    message.input_sequence = Some(1);
    invalid.push(message);
    let mut message = valid.clone();
    message.analog_sequence = Some(ControllerWireCodec::MAXIMUM_BUTTON_SEQUENCE_NUMBER + 1);
    invalid.push(message);
    let mut message = trigger(VirtualGamepadTrigger::Right, 1, 1.0);
    message.analog_value = Some(f64::NEG_INFINITY);
    invalid.push(message);
    let mut message = trigger(VirtualGamepadTrigger::Right, 1, 1.0);
    message.analog_value = None;
    invalid.push(message);
    for message in invalid {
        assert!(analog(&send(&mut core, message, 0)).is_empty());
    }
    assert_eq!(core.status().counters.rejected_inputs, 9);
    assert_eq!(analog(&send(&mut core, valid, 1)).len(), 1);
}

#[test]
fn authentication_generation_and_keyboard_mode_gate_all_controller_paths() {
    let mut unpaired = HostCore::new(state(), "111111").unwrap();
    assert!(analog(&send(
        &mut unpaired,
        stick(VirtualGamepadStick::Left, 1, 1.0, 1.0),
        0
    ))
    .is_empty());
    let mut core = core();
    send(&mut core, stick(VirtualGamepadStick::Left, 1, 1.0, 1.0), 0);
    let mut stale = stick(VirtualGamepadStick::Left, 2, 0.0, 0.0);
    stale.input_generation = Some(9);
    assert!(analog(&send(&mut core, stale, 1)).is_empty());
    let mut missing = stick(VirtualGamepadStick::Left, 2, 0.0, 0.0);
    missing.input_generation = None;
    assert!(analog(&send(&mut core, missing, 1)).is_empty());
    let mut state = core.persistent_state().clone();
    state.profiles[0]["outputMode"] = json!("keyboard");
    state.profiles[0]["landscapeCustomization"] =
        json!({"elements":[{"id":"e", "kind":"trigger", "output":{"gamepadButtons":["south"]}}]});
    assert!(!state.needs_virtual_gamepad());
    core.install_validated_persisted_state(state);
    assert!(!core.needs_virtual_gamepad());
    let mut fresh = digital(GameButton::Jump, true, 1, 1);
    fresh.input_generation = core.status().active_generation;
    let effects = send(&mut core, fresh, 2);
    assert!(buttons(&effects).is_empty());
    assert!(effects.contains(&Effect::KeyDown(KeyBinding::new(36, 0))));
    assert!(analog(&send(
        &mut core,
        stick(VirtualGamepadStick::Left, 3, 0.5, 0.5),
        3
    ))
    .is_empty());
    assert!(buttons(&core.tap_output_binding(&OutputBinding {
        keyboard: None,
        gamepad_buttons: ["south".into()].into()
    }))
    .is_empty());
}

#[test]
fn materialization_scans_active_variants_and_legacy_missing_mode_is_custom() {
    let mut state = PersistentState::minimal("server-1").unwrap();
    state.profiles[0]
        .as_object_mut()
        .unwrap()
        .remove("outputMode");
    assert!(!state.needs_virtual_gamepad());
    for customization in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        for control in [
            json!({"kind":"button", "output":{"gamepadButtons":["south"]}}),
            json!({"kind":"joystick", "joystickOutputSettings":{"analogTarget":"left_stick"}}),
            json!({"kind":"trigger"}),
        ] {
            let mut candidate = state.clone();
            candidate.profiles[0][customization] = json!({"elements":[control]});
            assert!(candidate.needs_virtual_gamepad(), "{customization}");
        }
    }
    state.profiles[0]["outputMode"] = json!("controller");
    assert!(state.needs_virtual_gamepad());
    state.profiles[0]["outputMode"] = json!("custom");
    state
        .profiles
        .push(json!({"id":"inactive", "outputMode":"controller"}));
    assert!(!state.needs_virtual_gamepad());
}

#[test]
fn analog_refresh_expiry_is_per_axis_and_heartbeat_does_not_refresh_it() {
    let mut core = core();
    send(&mut core, stick(VirtualGamepadStick::Left, 1, 0.5, 0.5), 0);
    send(&mut core, trigger(VirtualGamepadTrigger::Right, 1, 0.7), 20);
    send(&mut core, stick(VirtualGamepadStick::Left, 2, 0.5, 0.5), 50);
    let mut heartbeat = ControllerMessage::new(ControllerMessageType::Heartbeat, 0);
    heartbeat.input_protocol_version = Some(2);
    heartbeat.input_generation = Some(1);
    send(&mut core, heartbeat, 110);
    assert!(analog(&core.expire_holds(119, 100)).is_empty());
    assert_eq!(
        analog(&core.expire_holds(120, 100)),
        vec![Effect::GamepadTrigger {
            trigger: VirtualGamepadTrigger::Right,
            value: 0.0
        }]
    );
    assert_eq!(
        analog(&core.expire_holds(150, 100)),
        vec![Effect::GamepadStick {
            stick: VirtualGamepadStick::Left,
            x: 0.0,
            y: 0.0
        }]
    );
    assert!(analog(&core.expire_holds(200, 100)).is_empty());
    assert_eq!(core.status().counters.expired_holds, 2);
    // A dropped stale neutral does not refresh an active axis.
    send(
        &mut core,
        stick(VirtualGamepadStick::Left, 3, 0.5, 0.5),
        200,
    );
    send(
        &mut core,
        stick(VirtualGamepadStick::Left, 2, 0.0, 0.0),
        250,
    );
    assert_eq!(analog(&core.expire_holds(300, 100)).len(), 1);
}

#[test]
fn every_lifecycle_boundary_resets_and_generation_reset_precedes_new_analog() {
    for boundary in 0..6 {
        let mut core = core();
        send(&mut core, digital(GameButton::Jump, true, 1, 1), 0);
        send(&mut core, stick(VirtualGamepadStick::Left, 1, 0.5, 0.5), 0);
        send(&mut core, trigger(VirtualGamepadTrigger::Right, 1, 0.7), 0);
        let effects = match boundary {
            0 => core.release_all(),
            1 => core.disconnect(1),
            2 => core.set_running(false),
            3 => {
                let mut next = stick(VirtualGamepadStick::Left, 1, 0.2, 0.3);
                next.input_generation = Some(2);
                send(&mut core, next, 1)
            }
            4 => core.select_profile_locally("next").unwrap(),
            _ => core.install_validated_persisted_state(core.persistent_state().clone()),
        };
        assert!(
            effects.contains(&Effect::GamepadReset),
            "boundary {boundary}"
        );
        assert_eq!(
            buttons(&effects),
            vec![(VirtualGamepadButton::South, false)]
        );
        if boundary == 3 {
            assert!(
                effects
                    .iter()
                    .position(|e| *e == Effect::GamepadReset)
                    .unwrap()
                    < effects
                        .iter()
                        .position(|e| matches!(e, Effect::GamepadStick { .. }))
                        .unwrap()
            );
            let stale = send(&mut core, stick(VirtualGamepadStick::Left, 2, 1.0, 1.0), 2);
            assert!(analog(&stale).is_empty());
        }
        assert_eq!(
            analog(&core.expire_holds(1000, 100)).len(),
            if boundary == 3 { 1 } else { 0 }
        );
    }
}

#[test]
fn digital_expiry_and_bounded_local_taps_preserve_existing_holds() {
    let mut core = core();
    send(&mut core, digital(GameButton::Jump, true, 1, 1), 0);
    let output = core
        .persistent_state()
        .resolve_button_output(GameButton::Jump)
        .unwrap();
    assert!(buttons(&core.tap_output_binding(&output)).is_empty());
    assert_eq!(
        buttons(&core.expire_holds(100, 100)),
        vec![(VirtualGamepadButton::South, false)]
    );
    assert_eq!(
        buttons(&core.tap_output_binding(&output)),
        vec![
            (VirtualGamepadButton::South, true),
            (VirtualGamepadButton::South, false)
        ]
    );
}

#[test]
fn legacy_analog_retains_expiry_when_v2_establishes_and_neutral_cancels_expiry() {
    let mut core = core();
    let mut legacy = stick(VirtualGamepadStick::Left, 1, 0.2, -0.2);
    legacy.input_protocol_version = None;
    legacy.input_generation = None;
    legacy.analog_sequence = None;
    send(&mut core, legacy, 0);
    send(&mut core, digital(GameButton::Jump, true, 1, 1), 20);
    assert_eq!(
        analog(&core.expire_holds(100, 100)),
        vec![Effect::GamepadStick {
            stick: VirtualGamepadStick::Left,
            x: 0.0,
            y: 0.0
        }]
    );
    send(
        &mut core,
        trigger(VirtualGamepadTrigger::Left, 1, 0.0001),
        100,
    );
    send(&mut core, trigger(VirtualGamepadTrigger::Left, 2, 0.0), 110);
    assert!(analog(&core.expire_holds(300, 100)).is_empty());
}

#[test]
fn local_multi_button_taps_press_the_complete_chord_before_releasing() {
    let core = core();
    let output = OutputBinding {
        keyboard: None,
        gamepad_buttons: ["south".to_owned(), "east".to_owned()].into(),
    };
    let effects = core.tap_output_binding(&output);
    let buttons = buttons(&effects);
    assert_eq!(buttons.len(), 4);
    assert!(buttons[..2].iter().all(|(_, pressed)| *pressed));
    assert!(buttons[2..].iter().all(|(_, pressed)| !*pressed));
}

#[test]
fn legacy_analog_and_all_button_spellings_are_supported() {
    let mut core = core();
    let mut legacy = stick(VirtualGamepadStick::Left, 1, 0.2, -0.2);
    legacy.input_protocol_version = None;
    legacy.input_generation = None;
    legacy.analog_sequence = None;
    assert_eq!(analog(&send(&mut core, legacy, 0)).len(), 1);
    for name in [
        "south",
        "east",
        "west",
        "north",
        "leftShoulder",
        "rightShoulder",
        "leftTriggerButton",
        "rightTriggerButton",
        "select",
        "start",
        "home",
        "leftStickPress",
        "rightStickPress",
        "dpadUp",
        "dpadDown",
        "dpadLeft",
        "dpadRight",
    ] {
        let button: VirtualGamepadButton = serde_json::from_value(json!(name)).unwrap();
        assert_eq!(serde_json::to_value(button).unwrap(), json!(name));
        let output = OutputBinding {
            keyboard: None,
            gamepad_buttons: [name.to_owned()].into(),
        };
        assert_eq!(
            buttons(&core.tap_output_binding(&output)),
            vec![(button, true), (button, false)]
        );
    }
}
