//! Portable v1 gamepad codec and lifecycle. Readiness means successful HID report
//! submission, not recognition by any game or controller framework.
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use thumble_core::VirtualGamepadButton;
use thumble_protocol::{VirtualGamepadStick, VirtualGamepadTrigger};

pub const REPORT_ID: u8 = 1;
pub const NEUTRAL_REPORT: [u8; 10] = [1, 0, 0, 8, 0, 0, 0, 0, 0, 0];
pub const REPORT_DESCRIPTOR: &[u8] = &[
    0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x85, 0x01, 0x05, 0x09, 0x19, 0x01, 0x29, 0x0d, 0x15, 0x00,
    0x25, 0x01, 0x75, 0x01, 0x95, 0x0d, 0x81, 0x02, 0x95, 0x03, 0x81, 0x03, 0x05, 0x01, 0x09, 0x39,
    0x15, 0x00, 0x25, 0x07, 0x35, 0x00, 0x46, 0x3b, 0x01, 0x65, 0x14, 0x75, 0x04, 0x95, 0x01, 0x81,
    0x42, 0x75, 0x04, 0x95, 0x01, 0x81, 0x03, 0x35, 0x00, 0x45, 0x00, 0x65, 0x00, 0x55, 0x00, 0x09,
    0x30, 0x09, 0x31, 0x09, 0x33, 0x09, 0x34, 0x15, 0x81, 0x25, 0x7f, 0x75, 0x08, 0x95, 0x04, 0x81,
    0x02, 0x09, 0x32, 0x09, 0x35, 0x15, 0x00, 0x26, 0xff, 0x00, 0x75, 0x08, 0x95, 0x02, 0x81, 0x02,
    0xc0,
];

/// Pure encoder accepts arbitrary floats: nonfinite values encode as neutral.
/// Public output setters instead reject nonfinite and out-of-range values.
#[derive(Debug, Clone, Default)]
pub struct GamepadReportState {
    pub buttons: BTreeSet<VirtualGamepadButton>,
    pub left_stick_x: f64,
    pub left_stick_y: f64,
    pub right_stick_x: f64,
    pub right_stick_y: f64,
    pub left_trigger: f64,
    pub right_trigger: f64,
}

impl GamepadReportState {
    pub fn report_bytes(&self) -> [u8; 10] {
        use VirtualGamepadButton::*;
        let order = [
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
        ];
        let mask = order.iter().enumerate().fold(0u16, |mask, (bit, button)| {
            mask | if self.buttons.contains(button) {
                1 << bit
            } else {
                0
            }
        });
        let has = |button| self.buttons.contains(&button);
        let hat = match (has(DpadUp), has(DpadDown), has(DpadLeft), has(DpadRight)) {
            (true, false, false, false) => 0,
            (true, false, false, true) => 1,
            (false, false, false, true) => 2,
            (false, true, false, true) => 3,
            (false, true, false, false) => 4,
            (false, true, true, false) => 5,
            (false, false, true, false) => 6,
            (true, false, true, false) => 7,
            _ => 8,
        };
        let finite = |v: f64| if v.is_finite() { v } else { 0.0 };
        let axis = |v| (finite(v).clamp(-1.0, 1.0) * 127.0).round() as i8 as u8;
        let trigger = |v| (finite(v).clamp(0.0, 1.0) * 255.0).round() as u8;
        [
            REPORT_ID,
            mask as u8,
            (mask >> 8) as u8,
            hat,
            axis(self.left_stick_x),
            axis(self.left_stick_y),
            axis(self.right_stick_x),
            axis(self.right_stick_y),
            trigger(if has(LeftTriggerButton) {
                1.0
            } else {
                self.left_trigger
            }),
            trigger(if has(RightTriggerButton) {
                1.0
            } else {
                self.right_trigger
            }),
        ]
    }
}

#[derive(Debug, Serialize, Deserialize, PartialEq, Clone)]
#[serde(rename_all = "camelCase")]
pub struct GamepadSnapshot {
    pub phase: String,
    pub entitlement_granted: Option<bool>,
    pub last_error: Option<String>,
    pub last_report_result: Option<u32>,
    pub last_report_uptime_nanoseconds: Option<u64>,
    pub report_count: u64,
    pub pressed_buttons: Vec<VirtualGamepadButton>,
    pub left_stick_x: f64,
    pub left_stick_y: f64,
    pub right_stick_x: f64,
    pub right_stick_y: f64,
    /// Effective level, including any held digital trigger button.
    pub left_trigger: f64,
    pub right_trigger: f64,
}

/// Only this message-level handle crosses threads. macOS CF objects never do.
pub(crate) trait HidBackend: Send {
    fn entitlement(&mut self) -> Result<bool, String>;
    fn start(&mut self) -> Result<(), String>;
    fn report(&mut self, bytes: [u8; 10]) -> Result<(u32, u64), String>;
    /// Requests neutralization/retirement. The OS owner retains the device through
    /// cancel completion, even when the caller's bounded wait times out.
    fn stop(&mut self);
}

pub struct GamepadOutput {
    input_enabled: bool,
    enabled: bool,
    backend: Option<Box<dyn HidBackend>>,
    state: GamepadReportState,
    status: GamepadSnapshot,
}

impl GamepadOutput {
    pub fn new(input_enabled: bool) -> Self {
        Self {
            input_enabled,
            enabled: false,
            backend: None,
            state: GamepadReportState::default(),
            status: GamepadSnapshot {
                phase: "inactive".into(),
                entitlement_granted: None,
                last_error: None,
                last_report_result: None,
                last_report_uptime_nanoseconds: None,
                report_count: 0,
                pressed_buttons: vec![],
                left_stick_x: 0.0,
                left_stick_y: 0.0,
                right_stick_x: 0.0,
                right_stick_y: 0.0,
                left_trigger: 0.0,
                right_trigger: 0.0,
            },
        }
    }

    #[cfg(test)]
    pub(crate) fn with_backend(backend: Box<dyn HidBackend>) -> Self {
        let mut output = Self::new(true);
        output.backend = Some(backend);
        output
    }

    pub fn set_enabled(&mut self, enabled: bool) -> Result<(), String> {
        if self.enabled == enabled {
            return self.current_result(); // Failures latch; reconciliation never retries.
        }
        self.enabled = enabled;
        if enabled {
            self.start()
        } else {
            self.stop();
            self.status.phase = "inactive".into();
            self.status.last_error = None;
            Ok(())
        }
    }

    pub fn retry(&mut self) -> Result<(), String> {
        self.stop();
        if self.enabled {
            self.start()
        } else {
            Ok(())
        }
    }

    fn start(&mut self) -> Result<(), String> {
        self.state = GamepadReportState::default();
        self.status.last_error = None;
        self.status.last_report_result = None;
        self.status.last_report_uptime_nanoseconds = None;
        if !self.input_enabled {
            self.status.phase = "recording".into();
            return self.submit();
        }
        if self.backend.is_none() {
            #[cfg(target_os = "macos")]
            {
                self.backend = Some(Box::new(
                    crate::platform::gamepad_macos::MacHidBackend::new(),
                ));
            }
            #[cfg(not(target_os = "macos"))]
            {
                return self.fail(
                    "creation-failed",
                    "Virtual HID output requires macOS".into(),
                );
            }
        }
        let claim = self.backend.as_mut().unwrap().entitlement();
        match claim {
            Ok(granted) => {
                self.status.entitlement_granted = Some(granted);
                if !granted {
                    return self.fail("missing-entitlement", "Signed Boolean com.apple.developer.hid.virtual.device entitlement is not granted".into());
                }
            }
            Err(error) => {
                self.status.entitlement_granted = None;
                return self.fail("creation-failed", error);
            }
        }
        if let Err(error) = self.backend.as_mut().unwrap().start() {
            return self.fail("creation-failed", error);
        }
        // Do not publish ready until the initial neutral submission succeeds.
        self.submit()?;
        self.status.phase = "ready".into();
        Ok(())
    }

    fn current_result(&self) -> Result<(), String> {
        self.status.last_error.clone().map_or(Ok(()), Err)
    }

    fn fail(&mut self, phase: &str, error: String) -> Result<(), String> {
        self.stop();
        self.status.phase = phase.into();
        self.status.last_error = Some(error.clone());
        Err(error)
    }

    fn stop(&mut self) {
        self.state = GamepadReportState::default();
        if let Some(backend) = &mut self.backend {
            backend.stop();
        }
    }

    fn submit(&mut self) -> Result<(), String> {
        if !self.input_enabled {
            self.status.report_count = self.status.report_count.saturating_add(1);
            return Ok(()); // Recording is not an OS report submission.
        }
        let bytes = self.report_bytes();
        match self.backend.as_mut().unwrap().report(bytes) {
            Ok((result, uptime)) => {
                self.status.last_report_result = Some(result);
                self.status.last_report_uptime_nanoseconds = Some(uptime);
                if result != 0 {
                    return self.fail(
                        "report-failed",
                        format!("IOHID HandleReport failed: 0x{result:08x}"),
                    );
                }
                self.status.report_count = self.status.report_count.saturating_add(1);
                Ok(())
            }
            Err(error) => self.fail("report-failed", error),
        }
    }

    fn writable(&self) -> Result<bool, String> {
        self.current_result()?;
        Ok(self.enabled && matches!(self.status.phase.as_str(), "ready" | "recording"))
    }

    pub fn set_button(
        &mut self,
        button: VirtualGamepadButton,
        pressed: bool,
    ) -> Result<(), String> {
        if !self.writable()? {
            return Ok(());
        }
        if pressed {
            self.state.buttons.insert(button);
        } else {
            self.state.buttons.remove(&button);
        }
        self.submit()
    }

    pub fn set_stick(&mut self, stick: VirtualGamepadStick, x: f64, y: f64) -> Result<(), String> {
        if !x.is_finite()
            || !y.is_finite()
            || !(-1.0..=1.0).contains(&x)
            || !(-1.0..=1.0).contains(&y)
        {
            return Err("Gamepad stick coordinates must be finite and within [-1, 1]".into());
        }
        if !self.writable()? {
            return Ok(());
        }
        match stick {
            VirtualGamepadStick::Left => {
                self.state.left_stick_x = x;
                self.state.left_stick_y = y;
            }
            VirtualGamepadStick::Right => {
                self.state.right_stick_x = x;
                self.state.right_stick_y = y;
            }
        }
        self.submit()
    }

    pub fn set_trigger(
        &mut self,
        trigger: VirtualGamepadTrigger,
        value: f64,
    ) -> Result<(), String> {
        if !value.is_finite() || !(0.0..=1.0).contains(&value) {
            return Err("Gamepad trigger value must be finite and within [0, 1]".into());
        }
        if !self.writable()? {
            return Ok(());
        }
        match trigger {
            VirtualGamepadTrigger::Left => self.state.left_trigger = value,
            VirtualGamepadTrigger::Right => self.state.right_trigger = value,
        }
        self.submit()
    }

    pub fn reset(&mut self) -> Result<(), String> {
        self.state = GamepadReportState::default();
        if !self.writable()? {
            return Ok(());
        }
        self.submit()
    }

    pub fn snapshot(&self) -> GamepadSnapshot {
        let mut snapshot = self.status.clone();
        snapshot.pressed_buttons = self.state.buttons.iter().copied().collect();
        snapshot.left_stick_x = self.state.left_stick_x;
        snapshot.left_stick_y = self.state.left_stick_y;
        snapshot.right_stick_x = self.state.right_stick_x;
        snapshot.right_stick_y = self.state.right_stick_y;
        snapshot.left_trigger = if self
            .state
            .buttons
            .contains(&VirtualGamepadButton::LeftTriggerButton)
        {
            1.0
        } else {
            self.state.left_trigger
        };
        snapshot.right_trigger = if self
            .state
            .buttons
            .contains(&VirtualGamepadButton::RightTriggerButton)
        {
            1.0
        } else {
            self.state.right_trigger
        };
        snapshot
    }

    pub fn report_bytes(&self) -> [u8; 10] {
        self.state.report_bytes()
    }
}

impl Drop for GamepadOutput {
    fn drop(&mut self) {
        self.stop();
    }
}

/// IOReturn values represented as unsigned bits, preserving the OS ABI.
#[cfg(any(target_os = "macos", test))]
pub(crate) const BAD_ARGUMENT: u32 = 0xe00002c2;
#[cfg(any(target_os = "macos", test))]
pub(crate) const NO_SPACE: u32 = 0xe00002db;
#[cfg(any(target_os = "macos", test))]
pub(crate) const UNSUPPORTED: u32 = 0xe00002c7;

/// Shared, safe GetReport policy; the FFI wrapper validates capacity before
/// constructing its slice. Invalid requests never modify buffer contents.
#[cfg(any(target_os = "macos", test))]
pub(crate) fn get_report(
    cached: [u8; 10],
    report_type: u32,
    id: u32,
    buffer: &mut [u8],
) -> Result<usize, u32> {
    if report_type != 0 || id != u32::from(REPORT_ID) {
        return Err(UNSUPPORTED);
    }
    if buffer.len() < 10 {
        return Err(NO_SPACE);
    }
    buffer[..10].copy_from_slice(&cached);
    Ok(10)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    fn unhex(hex: &str) -> Vec<u8> {
        (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn canonical_fixtures() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../../fixtures/gamepad/v1.json")).unwrap();
        assert_eq!(
            REPORT_DESCRIPTOR,
            unhex(fixture["descriptorHex"].as_str().unwrap())
        );
        assert_eq!(fixture["reportID"], REPORT_ID);
        assert_eq!(fixture["reportLength"], 10);
        for vector in fixture["vectors"].as_array().unwrap() {
            let mut state = GamepadReportState::default();
            if let Some(buttons) = vector["buttons"].as_array() {
                state.buttons = buttons
                    .iter()
                    .map(|b| serde_json::from_value(b.clone()).unwrap())
                    .collect();
            }
            state.left_stick_x = vector["leftStickX"].as_f64().unwrap_or_default();
            state.left_stick_y = vector["leftStickY"].as_f64().unwrap_or_default();
            state.right_stick_x = vector["rightStickX"].as_f64().unwrap_or_default();
            state.right_stick_y = vector["rightStickY"].as_f64().unwrap_or_default();
            state.left_trigger = vector["leftTrigger"].as_f64().unwrap_or_default();
            state.right_trigger = vector["rightTrigger"].as_f64().unwrap_or_default();
            assert_eq!(
                state.report_bytes().to_vec(),
                unhex(vector["hex"].as_str().unwrap()),
                "{}",
                vector["name"]
            );
        }
    }

    #[test]
    fn nonfinite_codec_and_strict_setters() {
        for value in [f64::NAN, f64::INFINITY, f64::NEG_INFINITY] {
            let state = GamepadReportState {
                left_stick_x: value,
                left_stick_y: value,
                right_stick_x: value,
                right_stick_y: value,
                left_trigger: value,
                right_trigger: value,
                ..Default::default()
            };
            assert_eq!(state.report_bytes(), NEUTRAL_REPORT);
            let mut output = GamepadOutput::new(false);
            output.set_enabled(true).unwrap();
            assert!(output
                .set_stick(VirtualGamepadStick::Left, value, 0.0)
                .is_err());
            assert!(output
                .set_trigger(VirtualGamepadTrigger::Left, value)
                .is_err());
            assert_eq!(output.report_bytes(), NEUTRAL_REPORT);
        }
        let mut output = GamepadOutput::new(false);
        assert!(output
            .set_stick(VirtualGamepadStick::Right, 1.01, 0.0)
            .is_err());
        assert!(output
            .set_trigger(VirtualGamepadTrigger::Right, -0.01)
            .is_err());
    }

    #[test]
    fn recording_trigger_release_and_reset() {
        fn assert_send<T: Send>() {}
        assert_send::<GamepadOutput>();
        let mut output = GamepadOutput::new(false);
        assert_eq!(output.snapshot().phase, "inactive");
        output.set_enabled(true).unwrap();
        output
            .set_trigger(VirtualGamepadTrigger::Left, 0.25)
            .unwrap();
        output
            .set_button(VirtualGamepadButton::LeftTriggerButton, true)
            .unwrap();
        assert_eq!(output.report_bytes()[8], 255);
        output
            .set_trigger(VirtualGamepadTrigger::Left, 0.5)
            .unwrap();
        output
            .set_button(VirtualGamepadButton::LeftTriggerButton, false)
            .unwrap();
        assert_eq!(output.report_bytes()[8], 128);
        output.reset().unwrap();
        assert_eq!(output.report_bytes(), NEUTRAL_REPORT);
        let status = output.snapshot();
        assert_eq!(status.phase, "recording");
        assert_eq!(status.last_report_result, None);
        assert_eq!(status.entitlement_granted, None);
        assert_eq!(
            serde_json::from_value::<GamepadSnapshot>(serde_json::to_value(&status).unwrap())
                .unwrap(),
            status
        );
        output.set_enabled(false).unwrap();
        output
            .set_button(VirtualGamepadButton::South, true)
            .unwrap();
        assert_eq!(output.report_bytes(), NEUTRAL_REPORT);
    }

    #[test]
    fn callback_policy() {
        let mut buffer = [0xaa; 12];
        assert_eq!(get_report(NEUTRAL_REPORT, 0, 1, &mut buffer), Ok(10));
        assert_eq!(&buffer[..10], &NEUTRAL_REPORT);
        assert_eq!(&buffer[10..], &[0xaa; 2]);
        for (kind, id, capacity, error) in [
            (1, 1, 12, UNSUPPORTED),
            (2, 1, 12, UNSUPPORTED),
            (0, 0, 12, UNSUPPORTED),
            (0, 2, 12, UNSUPPORTED),
            (0, 1, 9, NO_SPACE),
        ] {
            let mut buffer = [0xaa; 12];
            assert_eq!(
                get_report(NEUTRAL_REPORT, kind, id, &mut buffer[..capacity]),
                Err(error)
            );
            assert_eq!(buffer, [0xaa; 12]);
        }
        let mut state = GamepadReportState::default();
        state.buttons.insert(VirtualGamepadButton::South);
        assert_eq!(get_report(state.report_bytes(), 0, 1, &mut buffer), Ok(10));
        assert_eq!(buffer[1], 1);
    }

    #[derive(Default)]
    struct FakeState {
        events: Vec<String>,
        denied: bool,
        create_failed: bool,
        result: u32,
        active: bool,
    }
    struct Fake(Arc<Mutex<FakeState>>);
    impl HidBackend for Fake {
        fn entitlement(&mut self) -> Result<bool, String> {
            let mut s = self.0.lock().unwrap();
            s.events.push("claim".into());
            Ok(!s.denied)
        }
        fn start(&mut self) -> Result<(), String> {
            let mut s = self.0.lock().unwrap();
            assert!(!s.active, "overlapping devices");
            s.events.push("create".into());
            if s.create_failed {
                return Err("creation failed".into());
            }
            s.active = true;
            Ok(())
        }
        fn report(&mut self, bytes: [u8; 10]) -> Result<(u32, u64), String> {
            let mut s = self.0.lock().unwrap();
            assert!(s.active);
            s.events.push(
                if bytes == NEUTRAL_REPORT {
                    "neutral"
                } else {
                    "report"
                }
                .into(),
            );
            Ok((s.result, 123))
        }
        fn stop(&mut self) {
            let mut s = self.0.lock().unwrap();
            if s.active {
                s.events
                    .extend(["neutral", "cancel", "cancel-complete", "release"].map(String::from));
                s.active = false;
            }
        }
    }
    fn fake_output() -> (GamepadOutput, Arc<Mutex<FakeState>>) {
        let state = Arc::new(Mutex::new(FakeState::default()));
        let mut output = GamepadOutput::new(true);
        output.backend = Some(Box::new(Fake(state.clone())));
        (output, state)
    }

    #[test]
    fn first_report_failure_latches_and_explicit_retry_waits_for_retirement() {
        let (mut output, state) = fake_output();
        state.lock().unwrap().result = BAD_ARGUMENT;
        assert!(output.set_enabled(true).is_err());
        assert_eq!(output.snapshot().phase, "report-failed");
        assert_eq!(output.snapshot().last_report_result, Some(BAD_ARGUMENT));
        assert_eq!(output.snapshot().report_count, 0);
        let events = state.lock().unwrap().events.clone();
        assert!(output.set_enabled(true).is_err());
        assert!(output
            .set_button(VirtualGamepadButton::South, true)
            .is_err());
        assert_eq!(state.lock().unwrap().events, events);
        state.lock().unwrap().result = 0;
        output.retry().unwrap();
        assert_eq!(output.snapshot().phase, "ready");
        assert_eq!(output.report_bytes(), NEUTRAL_REPORT);
        let events = state.lock().unwrap().events.clone();
        assert_eq!(
            &events[..8],
            [
                "claim",
                "create",
                "neutral",
                "neutral",
                "cancel",
                "cancel-complete",
                "release",
                "claim"
            ]
        );
    }

    #[test]
    fn denied_and_creation_failure_are_distinct() {
        let (mut output, state) = fake_output();
        state.lock().unwrap().denied = true;
        assert!(output.set_enabled(true).is_err());
        assert_eq!(output.snapshot().phase, "missing-entitlement");
        assert_eq!(output.snapshot().entitlement_granted, Some(false));
        assert_eq!(state.lock().unwrap().events, ["claim"]);
        {
            let mut s = state.lock().unwrap();
            s.denied = false;
            s.create_failed = true;
        }
        assert!(output.retry().is_err());
        assert_eq!(output.snapshot().phase, "creation-failed");
        assert_eq!(output.snapshot().entitlement_granted, Some(true));
        assert!(!state.lock().unwrap().active);
    }

    #[test]
    fn later_failure_reset_disable_and_drop_neutralize() {
        let (mut output, state) = fake_output();
        output.set_enabled(true).unwrap();
        output
            .set_button(VirtualGamepadButton::South, true)
            .unwrap();
        output.reset().unwrap();
        assert_eq!(output.report_bytes(), NEUTRAL_REPORT);
        state.lock().unwrap().result = UNSUPPORTED;
        assert!(output
            .set_trigger(VirtualGamepadTrigger::Right, 1.0)
            .is_err());
        assert_eq!(output.report_bytes(), NEUTRAL_REPORT);
        assert!(!state.lock().unwrap().active);
        state.lock().unwrap().result = 0;
        output.retry().unwrap();
        output.set_enabled(false).unwrap();
        assert!(!state.lock().unwrap().active);
        output.set_enabled(true).unwrap();
        output.set_button(VirtualGamepadButton::Home, true).unwrap();
        drop(output);
        let state = state.lock().unwrap();
        assert!(!state.active);
        assert_eq!(
            &state.events[state.events.len() - 4..],
            ["neutral", "cancel", "cancel-complete", "release"]
        );
    }
}
