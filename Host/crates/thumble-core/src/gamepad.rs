use serde::{Deserialize, Serialize};
use thumble_protocol::{VirtualGamepadStick, VirtualGamepadTrigger};

/// Semantic controller outputs. Persisted bindings retain raw strings so newer
/// button names survive round trips; only these known names reach an adapter.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum VirtualGamepadButton {
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

impl VirtualGamepadButton {
    pub fn from_name(name: &str) -> Option<Self> {
        Some(match name {
            "south" => Self::South,
            "east" => Self::East,
            "west" => Self::West,
            "north" => Self::North,
            "leftShoulder" => Self::LeftShoulder,
            "rightShoulder" => Self::RightShoulder,
            "leftTriggerButton" => Self::LeftTriggerButton,
            "rightTriggerButton" => Self::RightTriggerButton,
            "select" => Self::Select,
            "start" => Self::Start,
            "home" => Self::Home,
            "leftStickPress" => Self::LeftStickPress,
            "rightStickPress" => Self::RightStickPress,
            "dpadUp" => Self::DpadUp,
            "dpadDown" => Self::DpadDown,
            "dpadLeft" => Self::DpadLeft,
            "dpadRight" => Self::DpadRight,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum AnalogTarget {
    LeftStick,
    RightStick,
    LeftTrigger,
    RightTrigger,
}

impl From<VirtualGamepadStick> for AnalogTarget {
    fn from(stick: VirtualGamepadStick) -> Self {
        match stick {
            VirtualGamepadStick::Left => Self::LeftStick,
            VirtualGamepadStick::Right => Self::RightStick,
        }
    }
}

impl From<VirtualGamepadTrigger> for AnalogTarget {
    fn from(trigger: VirtualGamepadTrigger) -> Self {
        match trigger {
            VirtualGamepadTrigger::Left => Self::LeftTrigger,
            VirtualGamepadTrigger::Right => Self::RightTrigger,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub(crate) struct AnalogAxis {
    pub last_sequence: Option<u64>,
    pub last_seen: Option<i64>,
}
