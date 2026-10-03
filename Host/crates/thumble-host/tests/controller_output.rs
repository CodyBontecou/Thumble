use std::fs;
use tempfile::tempdir;
use thumble_core::{Effect, KeyBinding, VirtualGamepadButton};
use thumble_host::output::OutputExecutor;
use thumble_protocol::{ControllerPointerButton, VirtualGamepadStick, VirtualGamepadTrigger};

#[test]
fn recording_controller_reports_preserve_mixed_outputs_and_release_to_neutral() {
    let directory = tempdir().unwrap();
    let path = directory.path().join("controller.jsonl");
    let mut output = OutputExecutor::new(false, Some(path.clone()));
    output.set_gamepad_enabled(true).unwrap();
    output
        .execute(&Effect::KeyDown(KeyBinding::new(49, 0)))
        .unwrap();
    output
        .execute(&Effect::PointerButton {
            button: ControllerPointerButton::Left,
            pressed: true,
        })
        .unwrap();
    for button in [
        VirtualGamepadButton::South,
        VirtualGamepadButton::DpadUp,
        VirtualGamepadButton::DpadRight,
        VirtualGamepadButton::LeftTriggerButton,
    ] {
        output
            .execute(&Effect::GamepadButton {
                button,
                pressed: true,
            })
            .unwrap();
    }
    output
        .execute(&Effect::GamepadStick {
            stick: VirtualGamepadStick::Left,
            x: -1.0,
            y: 1.0,
        })
        .unwrap();
    output
        .execute(&Effect::GamepadStick {
            stick: VirtualGamepadStick::Right,
            x: 0.5,
            y: -0.5,
        })
        .unwrap();
    output
        .execute(&Effect::GamepadTrigger {
            trigger: VirtualGamepadTrigger::Left,
            value: 0.25,
        })
        .unwrap();
    assert_eq!(output.gamepad_status().left_trigger, 1.0);
    output
        .execute(&Effect::GamepadButton {
            button: VirtualGamepadButton::LeftTriggerButton,
            pressed: false,
        })
        .unwrap();
    assert_eq!(output.gamepad_status().left_trigger, 0.25);
    output.release_tracked().unwrap();
    let status = output.snapshot();
    assert_eq!(status.held_key_count, 0);
    assert!(status.held_pointer_buttons.is_empty());
    let gamepad = status.virtual_gamepad_status.unwrap();
    assert_eq!(gamepad.phase, "recording");
    assert!(gamepad.pressed_buttons.is_empty());
    assert_eq!(gamepad.left_stick_x, 0.0);
    let frames: Vec<serde_json::Value> = fs::read_to_string(path)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert!(frames.iter().any(|frame| frame["event"] == "key_down:49:0"));
    assert!(frames
        .iter()
        .any(|frame| frame["event"] == "pointer_down:left"));
    assert!(frames
        .iter()
        .any(|frame| frame["gamepadReport"]
            == serde_json::json!([1, 1, 0, 1, 129, 127, 64, 192, 64, 0])));
    assert_eq!(
        frames.last().unwrap()["gamepadReport"],
        serde_json::json!([1, 0, 0, 8, 0, 0, 0, 0, 0, 0])
    );
}
