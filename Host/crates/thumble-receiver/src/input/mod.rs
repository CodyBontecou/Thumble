//! Translate wire-format Mac key codes at the OS boundary. Never send them
//! directly to SendInput/evdev. Chords share physical modifier reference counts.
mod keys;
#[cfg(target_os = "linux")]
mod linux;
#[cfg(windows)]
mod windows;

pub use keys::{key, NativeKey};
use std::collections::{BTreeMap, BTreeSet};
use thumble_core::{Effect, KeyStroke};
use thumble_protocol::ControllerPointerButton;

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    Key(NativeKey, bool),
    Move(i32, i32),
    Scroll(i32, i32),
    Button(u16, bool),
}

pub trait Sink: Send {
    fn emit(&mut self, event: Event) -> Result<(), String>;
}

struct Disabled;
impl Sink for Disabled {
    fn emit(&mut self, _: Event) -> Result<(), String> {
        Ok(())
    }
}

pub struct Input {
    sink: Box<dyn Sink>,
    chords: BTreeMap<KeyStroke, Vec<NativeKey>>,
    keys: BTreeSet<NativeKey>,
    buttons: BTreeSet<u16>,
    pointer_x: f64,
    pointer_y: f64,
    wheel_x: f64,
    wheel_y: f64,
}

impl Input {
    pub fn open(enabled: bool) -> Result<Self, String> {
        let sink: Box<dyn Sink> = if !enabled {
            Box::new(Disabled)
        } else {
            #[cfg(target_os = "linux")]
            {
                Box::new(linux::Linux::open()?)
            }
            #[cfg(windows)]
            {
                Box::new(windows::Windows)
            }
            #[cfg(not(any(target_os = "linux", windows)))]
            {
                return Err(
                    "Native input is supported on Windows/Linux; use the Mac host on macOS".into(),
                );
            }
        };
        Ok(Self::with_sink(sink))
    }

    pub fn with_sink(sink: Box<dyn Sink>) -> Self {
        Self {
            sink,
            chords: BTreeMap::new(),
            keys: BTreeSet::new(),
            buttons: BTreeSet::new(),
            pointer_x: 0.0,
            pointer_y: 0.0,
            wheel_x: 0.0,
            wheel_y: 0.0,
        }
    }

    fn chord(stroke: &KeyStroke) -> Result<Vec<NativeKey>, String> {
        if stroke.modifiers & !15 != 0 {
            return Err("Unsupported modifier bits".into());
        }
        let primary = key(stroke.key_code)
            .ok_or_else(|| format!("Unsupported physical key code {}", stroke.key_code))?;
        let mut chord = Vec::new();
        for (bit, code) in [(1, 55), (2, 56), (4, 58), (8, 59)] {
            if stroke.modifiers & bit != 0 {
                chord.push(key(code).unwrap());
            }
        }
        if !chord.contains(&primary) {
            chord.push(primary);
        }
        Ok(chord)
    }

    fn reconcile(&mut self) -> Result<(), String> {
        let desired = self
            .chords
            .values()
            .flatten()
            .copied()
            .collect::<BTreeSet<_>>();
        // Release ordinary keys before their modifiers; press modifiers first.
        let mut releases = self.keys.difference(&desired).copied().collect::<Vec<_>>();
        releases.sort_by_key(|key| key.modifier);
        let mut presses = desired.difference(&self.keys).copied().collect::<Vec<_>>();
        presses.sort_by_key(|key| !key.modifier);
        let mut failure = None;
        for key in releases {
            match self.sink.emit(Event::Key(key, false)) {
                Ok(()) => {
                    self.keys.remove(&key);
                }
                Err(error) => {
                    failure = Some(error);
                }
            }
        }
        if let Some(error) = failure {
            return Err(error);
        }
        for key in presses {
            // A backend can fail after a partial write. Track the attempted
            // down conservatively so retirement always attempts its key-up.
            self.keys.insert(key);
            self.sink.emit(Event::Key(key, true))?;
        }
        Ok(())
    }

    fn stroke(&mut self, stroke: KeyStroke, down: bool) -> Result<(), String> {
        if down {
            self.chords.insert(stroke.clone(), Self::chord(&stroke)?);
        } else {
            self.chords.remove(&stroke);
        }
        self.reconcile()
    }

    pub fn execute(&mut self, effect: &Effect) -> Result<(), String> {
        match effect {
            Effect::KeyDown(binding) => self.stroke(KeyStroke::new(binding.key_code, binding.modifiers), true),
            Effect::KeyUp(binding) => self.stroke(KeyStroke::new(binding.key_code, binding.modifiers), false),
            Effect::PulseKey(binding) => {
                let key = key(binding.key_code).ok_or("Unsupported pulse key")?;
                if self.keys.contains(&key) {
                    self.sink.emit(Event::Key(key, false))?;
                    self.keys.remove(&key);
                    std::thread::sleep(std::time::Duration::from_millis(18));
                    self.reconcile()?;
                }
                Ok(())
            }
            Effect::TapSequence(strokes) => {
                for stroke in strokes {
                    self.stroke(stroke.clone(), true)?;
                    std::thread::sleep(std::time::Duration::from_millis(22));
                    self.stroke(stroke.clone(), false)?;
                    std::thread::sleep(std::time::Duration::from_millis(18));
                }
                Ok(())
            }
            Effect::PointerMove { delta_x, delta_y } => {
                let x = pixel_delta(&mut self.pointer_x, *delta_x);
                let y = pixel_delta(&mut self.pointer_y, *delta_y);
                self.sink.emit(Event::Move(x,y))
            }
            // Wire deltas are pixels, native wheels use 120 units/notch.
            // Preserve fractional movement across frames; 40 pixels = 1 notch.
            Effect::PointerScroll { delta_x, delta_y } => {
                let x = wheel_delta(&mut self.wheel_x, -*delta_x);
                let y = wheel_delta(&mut self.wheel_y, -*delta_y);
                self.sink.emit(Event::Scroll(x,y))
            }
            Effect::PointerButton { button, pressed } => {
                let code = match button { ControllerPointerButton::Left => 272, ControllerPointerButton::Right => 273, ControllerPointerButton::Middle => 274 };
                if *pressed { self.buttons.insert(code); }
                self.sink.emit(Event::Button(code, *pressed))?;
                if !pressed { self.buttons.remove(&code); }
                Ok(())
            }
            Effect::GamepadButton { .. } | Effect::GamepadStick { .. } | Effect::GamepadTrigger { .. } => Err("Virtual gamepad output is not supported by this receiver; use keyboard/mouse bindings".into()),
            _ => Ok(()),
        }
    }

    /// Keep unsuccessful releases tracked so the safety timer can retry them.
    pub fn release_all(&mut self) -> Result<(), String> {
        self.chords.clear();
        let mut failure = self.reconcile().err();
        for button in self.buttons.clone() {
            match self.sink.emit(Event::Button(button, false)) {
                Ok(()) => {
                    self.buttons.remove(&button);
                }
                Err(error) => {
                    failure = Some(error);
                }
            }
        }
        failure.map_or(Ok(()), Err)
    }
}
impl Drop for Input {
    fn drop(&mut self) {
        let _ = self.release_all();
    }
}

fn wheel_delta(remainder: &mut f64, pixels: f64) -> i32 {
    if !pixels.is_finite() {
        return 0;
    }
    *remainder += pixels.clamp(-32767.0, 32767.0) * 3.0;
    let units = remainder.trunc() as i32;
    *remainder -= f64::from(units);
    units
}

fn pixel_delta(remainder: &mut f64, pixels: f64) -> i32 {
    if !pixels.is_finite() {
        return 0;
    }
    *remainder += pixels.clamp(-32767.0, 32767.0);
    let whole = remainder.round() as i32;
    *remainder -= f64::from(whole);
    whole
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use thumble_core::KeyBinding;
    struct Record(Arc<Mutex<Vec<Event>>>);
    impl Sink for Record {
        fn emit(&mut self, e: Event) -> Result<(), String> {
            self.0.lock().unwrap().push(e);
            Ok(())
        }
    }
    #[test]
    fn overlapping_chords_keep_shared_modifiers_until_last_release() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut input = Input::with_sink(Box::new(Record(events.clone())));
        for code in [0, 1] {
            input
                .execute(&Effect::KeyDown(KeyBinding::new(code, 8)))
                .unwrap();
        }
        input
            .execute(&Effect::KeyUp(KeyBinding::new(0, 8)))
            .unwrap();
        assert!(!events
            .lock()
            .unwrap()
            .contains(&Event::Key(key(59).unwrap(), false)));
        input.release_all().unwrap();
        let events = events.lock().unwrap();
        assert_eq!(events.first(), Some(&Event::Key(key(59).unwrap(), true)));
        assert_eq!(events.last(), Some(&Event::Key(key(59).unwrap(), false)));
    }
    #[test]
    fn unknown_key_and_gamepad_fail_instead_of_silently_succeeding() {
        let mut input = Input::open(false).unwrap();
        assert!(input
            .execute(&Effect::KeyDown(KeyBinding::new(65535, 0)))
            .is_err());
        assert!(input.execute(&Effect::GamepadReset).is_ok());
        assert_eq!(pixel_delta(&mut 0.0, f64::NAN), 0);
    }
}

#[cfg(test)]
mod failure_tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    struct PartialFailure {
        events: Arc<Mutex<Vec<Event>>>,
        fail_down: bool,
        fail_release: bool,
    }
    impl Sink for PartialFailure {
        fn emit(&mut self, event: Event) -> Result<(), String> {
            self.events.lock().unwrap().push(event.clone());
            if self.fail_down && matches!(event, Event::Key(_, true)) {
                self.fail_down = false;
                return Err("partial write".into());
            }
            if self.fail_release && matches!(event, Event::Key(_, false)) {
                self.fail_release = false;
                return Err("release failed".into());
            }
            Ok(())
        }
    }
    #[test]
    fn partial_down_still_gets_released_and_failed_releases_are_retried() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut input = Input::with_sink(Box::new(PartialFailure {
            events: events.clone(),
            fail_down: true,
            fail_release: true,
        }));
        assert!(input.stroke(KeyStroke::new(0, 8), true).is_err());
        assert!(input.release_all().is_err());
        input.release_all().unwrap();
        let control = key(59).unwrap();
        assert_eq!(
            *events.lock().unwrap(),
            vec![
                Event::Key(control, true),
                Event::Key(control, false),
                Event::Key(control, false)
            ]
        );
    }
    #[test]
    fn release_failure_does_not_prevent_other_keys_from_releasing() {
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut input = Input::with_sink(Box::new(PartialFailure {
            events: events.clone(),
            fail_down: false,
            fail_release: true,
        }));
        input.stroke(KeyStroke::new(0, 8), true).unwrap();
        assert!(input.release_all().is_err());
        assert!(events
            .lock()
            .unwrap()
            .contains(&Event::Key(key(59).unwrap(), false)));
        input.release_all().unwrap();
        assert!(input.keys.is_empty());
    }
    #[test]
    fn fractional_scroll_preserves_total_distance_across_frames() {
        let mut remainder = 0.0;
        let sum = (0..400)
            .map(|_| wheel_delta(&mut remainder, 0.1))
            .sum::<i32>();
        assert!((sum - 120).abs() <= 1);
        assert_eq!(wheel_delta(&mut 0.0, 40.0), 120);
        let mut position = 0.0;
        assert_eq!(
            (0..100)
                .map(|_| pixel_delta(&mut position, 0.1))
                .sum::<i32>(),
            10
        );
    }
}
