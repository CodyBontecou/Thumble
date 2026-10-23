use crate::generated::{GamepadButton::*, GamepadState};
use std::collections::HashSet;

pub const NEUTRAL: [u8; 20] = [0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
impl GamepadState {
    pub fn validate(&self) -> bool {
        self.buttons.len() <= 17
            && self.buttons.iter().collect::<HashSet<_>>().len() == self.buttons.len()
            && [
                self.left_stick_x,
                self.left_stick_y,
                self.right_stick_x,
                self.right_stick_y,
            ]
            .iter()
            .all(|v| v.is_finite() && (-1.0..=1.0).contains(v))
            && [self.left_trigger, self.right_trigger]
                .iter()
                .all(|v| v.is_finite() && (0.0..=1.0).contains(v))
    }
    pub fn report(&self) -> [u8; 20] {
        let mut bytes = NEUTRAL;
        let mut mask = 0u16;
        let has = |button| self.buttons.contains(&button);
        for button in &self.buttons {
            let bit = match button {
                DpadUp => Some(0),
                DpadDown => Some(1),
                DpadLeft => Some(2),
                DpadRight => Some(3),
                Start => Some(4),
                Select => Some(5),
                LeftStickPress => Some(6),
                RightStickPress => Some(7),
                LeftShoulder => Some(8),
                RightShoulder => Some(9),
                Home => Some(10),
                South => Some(12),
                East => Some(13),
                West => Some(14),
                North => Some(15),
                LeftTriggerButton | RightTriggerButton => None,
            };
            if let Some(bit) = bit {
                mask |= 1 << bit;
            }
        }
        if has(DpadUp) && has(DpadDown) {
            mask &= !3;
        }
        if has(DpadLeft) && has(DpadRight) {
            mask &= !12;
        }
        bytes[2..4].copy_from_slice(&mask.to_le_bytes());
        let finite = |v: f64| if v.is_finite() { v } else { 0.0 };
        let trigger = |v: f64| (finite(v).clamp(0.0, 1.0) * 255.0).round() as u8;
        bytes[4] = trigger(if has(LeftTriggerButton) {
            1.0
        } else {
            self.left_trigger
        });
        bytes[5] = trigger(if has(RightTriggerButton) {
            1.0
        } else {
            self.right_trigger
        });
        for (index, v) in [
            self.left_stick_x,
            -self.left_stick_y,
            self.right_stick_x,
            -self.right_stick_y,
        ]
        .into_iter()
        .enumerate()
        {
            let v = finite(v).clamp(-1.0, 1.0);
            let axis = (v * if v < 0.0 { 32768.0 } else { 32767.0 }).round() as i16;
            bytes[6 + index * 2..8 + index * 2].copy_from_slice(&axis.to_le_bytes());
        }
        bytes
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|v| format!("{v:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn retained_native_vectors() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../../../Host/fixtures/gamepad/v2.json"))
                .unwrap();
        for value in fixture["vectors"].as_array().unwrap() {
            let state = GamepadState {
                buttons: serde_json::from_value(
                    value
                        .get("buttons")
                        .cloned()
                        .unwrap_or_else(|| serde_json::json!([])),
                )
                .unwrap(),
                left_stick_x: value["leftStickX"].as_f64().unwrap_or(0.0),
                left_stick_y: value["leftStickY"].as_f64().unwrap_or(0.0),
                right_stick_x: value["rightStickX"].as_f64().unwrap_or(0.0),
                right_stick_y: value["rightStickY"].as_f64().unwrap_or(0.0),
                left_trigger: value["leftTrigger"].as_f64().unwrap_or(0.0),
                right_trigger: value["rightTrigger"].as_f64().unwrap_or(0.0),
            };
            assert_eq!(
                hex(&state.report()),
                value["hex"].as_str().unwrap(),
                "{}",
                value["name"]
            );
        }
    }
}
