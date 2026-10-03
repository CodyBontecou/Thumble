use crate::gamepad::{GamepadOutput, GamepadSnapshot};
use crate::platform;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;
use std::time::{Duration, Instant};
use thumble_core::{Effect, KeyBinding, KeyStroke, VirtualGamepadButton};
use thumble_protocol::ControllerPointerButton;

const RECENT_EVENT_LIMIT: usize = 64;
const MINIMUM_TAP_DURATION: Duration = Duration::from_millis(22);
const MINIMUM_INTER_TAP_GAP: Duration = Duration::from_millis(18);

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputSnapshot {
    pub mode: String,
    pub events_executed: u64,
    pub held_key_count: usize,
    pub pending_key_release_count: usize,
    pub held_pointer_buttons: Vec<String>,
    pub pending_pointer_releases: Vec<String>,
    pub recent_events: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub virtual_gamepad_status: Option<GamepadSnapshot>,
}

pub struct OutputExecutor {
    input_enabled: bool,
    held_keys: BTreeSet<KeyBinding>,
    held_key_started: BTreeMap<KeyBinding, Instant>,
    last_key_release: BTreeMap<KeyBinding, Instant>,
    pending_key_releases: BTreeSet<KeyBinding>,
    held_pointer_buttons: BTreeSet<String>,
    pending_pointer_releases: BTreeSet<String>,
    events_executed: u64,
    recent_events: Vec<String>,
    recording_path: Option<PathBuf>,
    gamepad: GamepadOutput,
    held_gamepad_started: BTreeMap<VirtualGamepadButton, Instant>,
}

impl OutputExecutor {
    pub fn new(input_enabled: bool, recording_path: Option<PathBuf>) -> Self {
        Self {
            input_enabled,
            held_keys: BTreeSet::new(),
            held_key_started: BTreeMap::new(),
            last_key_release: BTreeMap::new(),
            pending_key_releases: BTreeSet::new(),
            held_pointer_buttons: BTreeSet::new(),
            pending_pointer_releases: BTreeSet::new(),
            events_executed: 0,
            recent_events: Vec::new(),
            recording_path: (!input_enabled).then_some(recording_path).flatten(),
            gamepad: GamepadOutput::new(input_enabled),
            held_gamepad_started: BTreeMap::new(),
        }
    }

    #[cfg(test)]
    pub(crate) fn with_test_gamepad(gamepad: GamepadOutput) -> Self {
        let mut output = Self::new(false, None);
        output.gamepad = gamepad;
        output
    }

    pub fn set_gamepad_enabled(&mut self, enabled: bool) -> Result<(), String> {
        let before = self.gamepad.snapshot().phase;
        let result = self.gamepad.set_enabled(enabled);
        if !enabled {
            self.held_gamepad_started.clear();
        }
        result?;
        if before != self.gamepad.snapshot().phase {
            self.record(format!(
                "gamepad_{}",
                if enabled { "enabled" } else { "disabled" }
            ))?;
        }
        Ok(())
    }

    pub fn gamepad_status(&self) -> GamepadSnapshot {
        self.gamepad.snapshot()
    }

    pub fn retry_gamepad(&mut self) -> Result<(), String> {
        self.held_gamepad_started.clear();
        self.gamepad.retry()?;
        self.record("gamepad_retry".to_owned())
    }

    pub fn execute(&mut self, effect: &Effect) -> Result<(), String> {
        match effect {
            Effect::KeyDown(binding) => {
                if self.input_enabled {
                    self.wait_for_inter_tap_gap(binding);
                    platform::key_event(&first_stroke(binding), true)?;
                }
                self.pending_key_releases.remove(binding);
                if self.held_keys.insert(binding.clone()) {
                    self.held_key_started
                        .insert(binding.clone(), Instant::now());
                }
                self.record(format!(
                    "key_down:{}:{}",
                    binding.key_code, binding.modifiers
                ))
            }
            Effect::KeyUp(binding) => {
                if self.input_enabled && self.held_keys.contains(binding) {
                    self.wait_for_minimum_hold(binding);
                    if let Err(error) = platform::key_event(&first_stroke(binding), false) {
                        self.pending_key_releases.insert(binding.clone());
                        return Err(error);
                    }
                }
                self.pending_key_releases.remove(binding);
                if self.held_keys.remove(binding) {
                    self.held_key_started.remove(binding);
                    self.last_key_release
                        .insert(binding.clone(), Instant::now());
                }
                self.record(format!("key_up:{}:{}", binding.key_code, binding.modifiers))
            }
            Effect::PulseKey(binding) => {
                if !self.held_keys.contains(binding) {
                    return Ok(());
                }
                if self.input_enabled {
                    self.wait_for_minimum_hold(binding);
                    platform::key_event(&first_stroke(binding), false)?;
                }
                self.held_keys.remove(binding);
                self.held_key_started.remove(binding);
                self.last_key_release
                    .insert(binding.clone(), Instant::now());
                self.record(format!(
                    "key_pulse_up:{}:{}",
                    binding.key_code, binding.modifiers
                ))?;
                if self.input_enabled {
                    std::thread::sleep(MINIMUM_INTER_TAP_GAP);
                    platform::key_event(&first_stroke(binding), true)?;
                }
                self.held_keys.insert(binding.clone());
                self.held_key_started
                    .insert(binding.clone(), Instant::now());
                self.record(format!(
                    "key_pulse_down:{}:{}",
                    binding.key_code, binding.modifiers
                ))
            }
            Effect::TapSequence(strokes) => {
                for stroke in strokes {
                    let tracked = KeyBinding::new(stroke.key_code, stroke.modifiers);
                    if self.input_enabled {
                        self.wait_for_inter_tap_gap(&tracked);
                        platform::key_event(stroke, true)?;
                        self.held_keys.insert(tracked.clone());
                        self.held_key_started
                            .insert(tracked.clone(), Instant::now());
                        self.wait_for_minimum_hold(&tracked);
                        if let Err(error) = platform::key_event(stroke, false) {
                            self.pending_key_releases.insert(tracked);
                            return Err(error);
                        }
                        self.pending_key_releases.remove(&tracked);
                        self.held_keys.remove(&tracked);
                        self.held_key_started.remove(&tracked);
                        self.last_key_release.insert(tracked, Instant::now());
                    }
                    self.record(format!("key_tap:{}:{}", stroke.key_code, stroke.modifiers))?;
                }
                Ok(())
            }
            Effect::PointerMove { delta_x, delta_y } => {
                if self.input_enabled {
                    platform::pointer_move(*delta_x, *delta_y, &self.held_pointer_buttons)?;
                }
                self.record(format!("pointer_move:{delta_x:.3}:{delta_y:.3}"))
            }
            Effect::PointerScroll { delta_x, delta_y } => {
                if self.input_enabled {
                    platform::pointer_scroll(*delta_x, *delta_y)?;
                }
                self.record(format!("pointer_scroll:{delta_x:.3}:{delta_y:.3}"))
            }
            Effect::PointerButton { button, pressed } => {
                let name = pointer_button_name(*button).to_owned();
                let should_post = *pressed || self.held_pointer_buttons.contains(&name);
                if self.input_enabled && should_post {
                    if let Err(error) = platform::pointer_button(*button, *pressed) {
                        if !pressed && self.held_pointer_buttons.contains(&name) {
                            self.pending_pointer_releases.insert(name);
                        }
                        return Err(error);
                    }
                }
                if *pressed {
                    self.pending_pointer_releases.remove(&name);
                    self.held_pointer_buttons.insert(name.clone());
                } else {
                    self.pending_pointer_releases.remove(&name);
                    self.held_pointer_buttons.remove(&name);
                }
                self.record(format!(
                    "pointer_{}:{name}",
                    if *pressed { "down" } else { "up" }
                ))
            }
            Effect::GamepadButton { button, pressed } => {
                if !pressed && self.input_enabled {
                    if let Some(started) = self.held_gamepad_started.get(button) {
                        if let Some(remaining) = MINIMUM_TAP_DURATION.checked_sub(started.elapsed())
                        {
                            std::thread::sleep(remaining);
                        }
                    }
                }
                self.gamepad.set_button(*button, *pressed)?;
                if *pressed {
                    self.held_gamepad_started
                        .entry(*button)
                        .or_insert_with(Instant::now);
                } else {
                    self.held_gamepad_started.remove(button);
                }
                self.record(format!("gamepad_button:{button:?}:{pressed}"))
            }
            Effect::GamepadStick { stick, x, y } => {
                self.gamepad.set_stick(*stick, *x, *y)?;
                self.record(format!("gamepad_stick:{stick:?}:{x:.3}:{y:.3}"))
            }
            Effect::GamepadTrigger { trigger, value } => {
                self.gamepad.set_trigger(*trigger, *value)?;
                self.record(format!("gamepad_trigger:{trigger:?}:{value:.3}"))
            }
            Effect::GamepadReset => {
                self.held_gamepad_started.clear();
                self.gamepad.reset()?;
                self.record("gamepad_reset".to_owned())
            }
            _ => Ok(()),
        }
    }

    pub fn release_tracked(&mut self) -> Result<(), String> {
        let mut errors = Vec::new();
        let keys = self.held_keys.iter().cloned().collect::<Vec<_>>();
        for binding in keys {
            let release = if self.input_enabled {
                platform::key_event(&first_stroke(&binding), false)
            } else {
                Ok(())
            };
            match release {
                Ok(()) => {
                    self.held_keys.remove(&binding);
                    self.held_key_started.remove(&binding);
                    self.pending_key_releases.remove(&binding);
                    self.last_key_release
                        .insert(binding.clone(), Instant::now());
                    if let Err(error) = self.record(format!(
                        "shutdown_key_up:{}:{}",
                        binding.key_code, binding.modifiers
                    )) {
                        errors.push(error);
                    }
                }
                Err(error) => {
                    self.pending_key_releases.insert(binding);
                    errors.push(error);
                }
            }
        }
        let buttons = self
            .held_pointer_buttons
            .iter()
            .cloned()
            .collect::<Vec<_>>();
        for name in buttons {
            let release = match pointer_button_from_name(&name) {
                Some(button) if self.input_enabled => platform::pointer_button(button, false),
                Some(_) => Ok(()),
                None => Err(format!("unknown tracked pointer button {name}")),
            };
            match release {
                Ok(()) => {
                    self.held_pointer_buttons.remove(&name);
                    self.pending_pointer_releases.remove(&name);
                    if let Err(error) = self.record(format!("shutdown_pointer_up:{name}")) {
                        errors.push(error);
                    }
                }
                Err(error) => {
                    self.pending_pointer_releases.insert(name);
                    errors.push(error);
                }
            }
        }
        self.held_gamepad_started.clear();
        if matches!(
            self.gamepad.snapshot().phase.as_str(),
            "ready" | "recording"
        ) {
            if let Err(error) = self.execute(&Effect::GamepadReset) {
                errors.push(error);
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }

    pub fn retry_pending_releases(&mut self) -> Result<(), String> {
        let mut errors = Vec::new();
        for binding in self.pending_key_releases.clone() {
            let release = if self.input_enabled {
                platform::key_event(&first_stroke(&binding), false)
            } else {
                Ok(())
            };
            match release {
                Ok(()) => {
                    self.pending_key_releases.remove(&binding);
                    self.held_keys.remove(&binding);
                    self.held_key_started.remove(&binding);
                    self.last_key_release
                        .insert(binding.clone(), Instant::now());
                    if let Err(error) = self.record(format!(
                        "retry_key_up:{}:{}",
                        binding.key_code, binding.modifiers
                    )) {
                        errors.push(error);
                    }
                }
                Err(error) => errors.push(error),
            }
        }
        for name in self.pending_pointer_releases.clone() {
            let release = match pointer_button_from_name(&name) {
                Some(button) if self.input_enabled => platform::pointer_button(button, false),
                Some(_) => Ok(()),
                None => Err(format!("unknown tracked pointer button {name}")),
            };
            match release {
                Ok(()) => {
                    self.pending_pointer_releases.remove(&name);
                    self.held_pointer_buttons.remove(&name);
                    if let Err(error) = self.record(format!("retry_pointer_up:{name}")) {
                        errors.push(error);
                    }
                }
                Err(error) => errors.push(error),
            }
        }
        if errors.is_empty() {
            Ok(())
        } else {
            Err(errors.join("; "))
        }
    }

    fn wait_for_minimum_hold(&self, binding: &KeyBinding) {
        if let Some(started) = self.held_key_started.get(binding) {
            if let Some(remaining) = MINIMUM_TAP_DURATION.checked_sub(started.elapsed()) {
                std::thread::sleep(remaining);
            }
        }
    }

    fn wait_for_inter_tap_gap(&self, binding: &KeyBinding) {
        if let Some(released) = self.last_key_release.get(binding) {
            if let Some(remaining) = MINIMUM_INTER_TAP_GAP.checked_sub(released.elapsed()) {
                std::thread::sleep(remaining);
            }
        }
    }

    pub fn snapshot(&self) -> OutputSnapshot {
        OutputSnapshot {
            mode: if self.input_enabled {
                "macos-cgevent".to_owned()
            } else {
                "recording-noop".to_owned()
            },
            events_executed: self.events_executed,
            held_key_count: self.held_keys.len(),
            pending_key_release_count: self.pending_key_releases.len(),
            held_pointer_buttons: self.held_pointer_buttons.iter().cloned().collect(),
            pending_pointer_releases: self.pending_pointer_releases.iter().cloned().collect(),
            recent_events: self.recent_events.clone(),
            virtual_gamepad_status: Some(self.gamepad.snapshot()),
        }
    }

    fn record(&mut self, event: String) -> Result<(), String> {
        self.events_executed = self.events_executed.saturating_add(1);
        self.recent_events.push(event.clone());
        if self.recent_events.len() > RECENT_EVENT_LIMIT {
            self.recent_events.remove(0);
        }
        let Some(path) = &self.recording_path else {
            return Ok(());
        };
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("create output recording directory: {error}"))?;
        }
        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(path)
            .map_err(|error| format!("open output recording: {error}"))?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))
            .map_err(|error| format!("protect output recording: {error}"))?;
        let mut frame = serde_json::json!({"event": event});
        if event.starts_with("gamepad_") {
            frame["gamepadReport"] = serde_json::json!(self.gamepad.report_bytes());
        }
        let json = serde_json::to_string(&frame)
            .map_err(|error| format!("encode output recording: {error}"))?;
        file.write_all(json.as_bytes())
            .and_then(|()| file.write_all(b"\n"))
            .map_err(|error| format!("write output recording: {error}"))
    }
}

fn first_stroke(binding: &KeyBinding) -> KeyStroke {
    binding
        .strokes()
        .into_iter()
        .next()
        .unwrap_or_else(|| KeyStroke::new(binding.key_code, binding.modifiers))
}

fn pointer_button_name(button: ControllerPointerButton) -> &'static str {
    match button {
        ControllerPointerButton::Left => "left",
        ControllerPointerButton::Right => "right",
        ControllerPointerButton::Middle => "middle",
    }
}

fn pointer_button_from_name(name: &str) -> Option<ControllerPointerButton> {
    match name {
        "left" => Some(ControllerPointerButton::Left),
        "right" => Some(ControllerPointerButton::Right),
        "middle" => Some(ControllerPointerButton::Middle),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn recording_backend_tracks_and_safely_releases_without_injection() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("events.jsonl");
        let mut output = OutputExecutor::new(false, Some(path.clone()));
        let binding = KeyBinding::new(49, 2);
        output.execute(&Effect::KeyDown(binding.clone())).unwrap();
        output.execute(&Effect::PulseKey(binding.clone())).unwrap();
        assert_eq!(output.snapshot().held_key_count, 1);
        output
            .execute(&Effect::PointerButton {
                button: ControllerPointerButton::Left,
                pressed: true,
            })
            .unwrap();
        output.release_tracked().unwrap();

        let snapshot = output.snapshot();
        assert_eq!(snapshot.held_key_count, 0);
        assert!(snapshot.held_pointer_buttons.is_empty());
        let contents = fs::read_to_string(path).unwrap();
        assert!(contents.contains("key_down:49:2"));
        assert!(contents.contains("key_pulse_up:49:2"));
        assert!(contents.contains("key_pulse_down:49:2"));
        assert!(contents.contains("shutdown_key_up:49:2"));
        assert!(contents.contains("shutdown_pointer_up:left"));
    }

    #[test]
    fn pending_release_retry_reconciles_executor_tracking() {
        let directory = tempdir().unwrap();
        let path = directory.path().join("retry-events.jsonl");
        let mut output = OutputExecutor::new(false, Some(path.clone()));
        let binding = KeyBinding::new(36, 0);
        output.held_keys.insert(binding.clone());
        output
            .held_key_started
            .insert(binding.clone(), Instant::now());
        output.pending_key_releases.insert(binding);
        output.held_pointer_buttons.insert("left".to_owned());
        output.pending_pointer_releases.insert("left".to_owned());

        output.retry_pending_releases().unwrap();

        let snapshot = output.snapshot();
        assert_eq!(snapshot.held_key_count, 0);
        assert_eq!(snapshot.pending_key_release_count, 0);
        assert!(snapshot.held_pointer_buttons.is_empty());
        assert!(snapshot.pending_pointer_releases.is_empty());
        let contents = fs::read_to_string(path).unwrap();
        assert!(contents.contains("retry_key_up:36:0"));
        assert!(contents.contains("retry_pointer_up:left"));
    }
}
