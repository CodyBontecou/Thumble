//! Pure mapping experiment. No SDK, OS calls, driver installation or live output.
//! See README.md for exact upstream API/profile evidence and open acceptance gates.
#![forbid(unsafe_code)]

pub const UPSTREAM_COMMIT: &str = "63cc6481f9e82fc8600bda8aaa65cb3271113a19";
pub const CANDIDATE_VERSION: &str = "2.0.3";
pub const PROFILE_ID: &str = "xbox-360-wired";
pub const PROFILE_PATH: &str = "profiles/microsoft/xbox-360-wired.json";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MappingError {
    InvalidLength,
    InvalidHeader,
    ReservedButtonBit,
    ReservedBytes,
    /// The input bits are known, but this candidate's hat cannot express them.
    UnsupportedDpad,
}

/// HID usage handles named by the pinned HMGamepadState API and profile layout.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u16)]
pub enum Axis {
    X = 0x0130,
    Y = 0x0131,
    Rx = 0x0133,
    Ry = 0x0134,
    Vx = 0x0140,
    Vy = 0x0141,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AxisValue {
    pub axis: Axis,
    pub unit: f32,
}
/// Numeric values name HMButton bit positions, not the canonical report bits.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Button {
    A = 0,
    B = 1,
    X = 2,
    Y = 3,
    LeftBumper = 4,
    RightBumper = 5,
    Back = 6,
    Start = 7,
    LeftStick = 8,
    RightStick = 9,
    Guide = 10,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Buttons(u16);
impl Buttons {
    pub fn contains(self, button: Button) -> bool {
        self.0 & (1 << button as u8) != 0
    }
    /// A value for the pinned API's HMButton field; this does not call that API.
    pub fn api_mask(self) -> u32 {
        u32::from(self.0)
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[repr(u8)]
pub enum Hat {
    Neutral = 0,
    North = 1,
    NorthEast = 2,
    East = 3,
    SouthEast = 4,
    South = 5,
    SouthWest = 6,
    West = 7,
    NorthWest = 8,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CandidateState {
    /// Exact profile usages, ordered X/Y/Rx/Ry/Vx/Vy. Y is SDK-downward.
    axes: [AxisValue; 6],
    pub buttons: Buttons,
    pub hat: Hat,
}
impl CandidateState {
    pub fn axes(&self) -> &[AxisValue; 6] {
        &self.axes
    }
    pub fn axis(&self, axis: Axis) -> f32 {
        self.axes
            .iter()
            .find(|value| value.axis == axis)
            .unwrap()
            .unit
    }
}

/// Interpret Thumble's canonical v2 report, not a HIDMaestro native HID report.
/// No deadzone, clamping, driver-dependent normalization or state is introduced.
pub fn map_report(report: &[u8]) -> Result<CandidateState, MappingError> {
    if report.len() != 20 {
        return Err(MappingError::InvalidLength);
    }
    if report[0..2] != [0, 20] {
        return Err(MappingError::InvalidHeader);
    }
    let source = u16::from_le_bytes([report[2], report[3]]);
    if source & 0x0800 != 0 {
        return Err(MappingError::ReservedButtonBit);
    }
    if report[14..].iter().any(|byte| *byte != 0) {
        return Err(MappingError::ReservedBytes);
    }
    let hat = match source & 0x000f {
        0 => Hat::Neutral,
        1 => Hat::North,
        9 => Hat::NorthEast,
        8 => Hat::East,
        10 => Hat::SouthEast,
        2 => Hat::South,
        6 => Hat::SouthWest,
        4 => Hat::West,
        5 => Hat::NorthWest,
        _ => return Err(MappingError::UnsupportedDpad),
    };
    let mappings = [
        (12, Button::A),
        (13, Button::B),
        (14, Button::X),
        (15, Button::Y),
        (8, Button::LeftBumper),
        (9, Button::RightBumper),
        (5, Button::Back),
        (4, Button::Start),
        (6, Button::LeftStick),
        (7, Button::RightStick),
        (10, Button::Guide),
    ];
    let mut buttons = 0;
    for (bit, target) in mappings {
        if source & (1 << bit) != 0 {
            buttons |= 1 << target as u8;
        }
    }
    let signed = |offset| i16::from_le_bytes([report[offset], report[offset + 1]]);
    // Signed endpoints are asymmetric; preserve both extrema and exact center.
    let centered = |value: i16| 0.5 + f32::from(value) / if value < 0 { 65536.0 } else { 65534.0 };
    Ok(CandidateState {
        axes: [
            AxisValue {
                axis: Axis::X,
                unit: centered(signed(6)),
            },
            AxisValue {
                axis: Axis::Y,
                unit: 1.0 - centered(signed(8)),
            },
            AxisValue {
                axis: Axis::Rx,
                unit: centered(signed(10)),
            },
            AxisValue {
                axis: Axis::Ry,
                unit: 1.0 - centered(signed(12)),
            },
            AxisValue {
                axis: Axis::Vx,
                unit: f32::from(report[4]) / 255.0,
            },
            AxisValue {
                axis: Axis::Vy,
                unit: f32::from(report[5]) / 255.0,
            },
        ],
        buttons: Buttons(buttons),
        hat,
    })
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DriverVerification {
    NotInspected,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Capability {
    pub candidate_version: &'static str,
    pub upstream_commit: &'static str,
    pub profile_id: &'static str,
    pub sdk_linked: bool,
    pub backend_available: bool,
    pub driver: DriverVerification,
    pub reason: &'static str,
    pub gameplay_verified: bool,
}
/// Static evidence only. In particular, false is not a probe for driver absence.
pub const fn capability() -> Capability {
    Capability {
        candidate_version: CANDIDATE_VERSION,
        upstream_commit: UPSTREAM_COMMIT,
        profile_id: PROFILE_ID,
        sdk_linked: false,
        backend_available: false,
        driver: DriverVerification::NotInspected,
        reason: "mapping_only_no_sdk_or_driver_probe",
        gameplay_verified: false,
    }
}

#[cfg(test)]
mod tests;
