// Generated from gamepad-state-v1.schema.json; do not edit. DTO only: validate before activation.
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GamepadButton {
    South,
    East,
    West,
    North,
    LeftShoulder,
    RightShoulder,
    LeftTriggerButton,
    RightTriggerButton,
    Select,
    Start,
    Home,
    LeftStickPress,
    RightStickPress,
    DpadUp,
    DpadDown,
    DpadLeft,
    DpadRight,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GamepadState {
    pub buttons: Vec<GamepadButton>,
    pub left_stick_x: f64,
    pub left_stick_y: f64,
    pub right_stick_x: f64,
    pub right_stick_y: f64,
    pub left_trigger: f64,
    pub right_trigger: f64,
}
