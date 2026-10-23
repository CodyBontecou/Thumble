//! Read-only XInput consumer witness for M1. Never creates a device or sends input.
//! XInput slots do not identify a device: establish Thumble ownership separately.
use clap::Parser;
#[cfg(any(windows, test))]
use serde::Serialize;

#[derive(Debug, Parser)]
#[command(
    about = "Read-only XInput gamepad observation; never injects input or certifies gameplay"
)]
struct Options {
    /// XInput user index. XInput does not expose a device identity for this slot.
    #[arg(long, default_value_t = 0, value_parser = clap::value_parser!(u32).range(0..=3))]
    slot: u32,
    #[arg(long, default_value_t = 1000, value_parser = clap::value_parser!(u32).range(0..=30000))]
    duration_ms: u32,
    #[arg(long, default_value_t = 20, value_parser = clap::value_parser!(u32).range(10..=1000))]
    interval_ms: u32,
}

#[cfg(any(windows, test))]
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Gamepad {
    buttons: u16,
    left_trigger: u8,
    right_trigger: u8,
    left_x: i16,
    left_y: i16,
    right_x: i16,
    right_y: i16,
}

#[cfg(any(windows, test))]
impl Gamepad {
    fn neutral(&self) -> bool {
        self.buttons == 0
            && self.left_trigger == 0
            && self.right_trigger == 0
            && self.left_x == 0
            && self.left_y == 0
            && self.right_x == 0
            && self.right_y == 0
    }
}

#[cfg(any(windows, test))]
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Sample {
    elapsed_microseconds: u64,
    result: u32,
    packet_number: Option<u32>,
    gamepad: Option<Gamepad>,
    neutral: Option<bool>,
}

#[cfg(windows)]
fn sample(slot: u32, elapsed_microseconds: u64) -> Sample {
    use windows_sys::Win32::UI::Input::XboxController::{XInputGetState, XINPUT_STATE};
    let mut state = XINPUT_STATE::default();
    // SAFETY: slot is bounded by clap; state points to writable initialized storage.
    // This API reads the consumer's current state. No producer API is invoked.
    let result = unsafe { XInputGetState(slot, &mut state) };
    if result != 0 {
        return Sample {
            elapsed_microseconds,
            result,
            packet_number: None,
            gamepad: None,
            neutral: None,
        };
    }
    let pad = state.Gamepad;
    let gamepad = Gamepad {
        buttons: pad.wButtons,
        left_trigger: pad.bLeftTrigger,
        right_trigger: pad.bRightTrigger,
        left_x: pad.sThumbLX,
        left_y: pad.sThumbLY,
        right_x: pad.sThumbRX,
        right_y: pad.sThumbRY,
    };
    let neutral = gamepad.neutral();
    Sample {
        elapsed_microseconds,
        result,
        packet_number: Some(state.dwPacketNumber),
        gamepad: Some(gamepad),
        neutral: Some(neutral),
    }
}

#[cfg(windows)]
fn observe(options: Options) -> std::process::ExitCode {
    use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
    let began = Instant::now();
    let mut samples = Vec::new();
    loop {
        samples.push(sample(
            options.slot,
            began.elapsed().as_micros().min(u64::MAX as u128) as u64,
        ));
        let remaining =
            Duration::from_millis(options.duration_ms.into()).saturating_sub(began.elapsed());
        if remaining.is_zero() || samples.len() == 3001 {
            break;
        }
        std::thread::sleep(remaining.min(Duration::from_millis(options.interval_ms.into())));
    }
    let report = serde_json::json!({
        "schemaVersion": 1,
        "provider": "XInput 1.4 / XInputGetState",
        "observedAtUnixSeconds": SystemTime::now().duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs()),
        "slot": options.slot,
        "durationMs": options.duration_ms,
        "intervalMs": options.interval_ms,
        "deviceIdentityVerified": false,
        "gameplayVerified": false,
        "units": {"sticks": "raw signed 16-bit; positive Y means up", "triggers": "independent 0...255", "elapsedMicroseconds": "same-process monotonic observation offsets, not physical latency"},
        "samples": samples,
        "remainingGates": ["bind slot to independently identified Thumble device", "driver/package/signing identity", "both physical phones", "both game clients", "disconnect/reconnect", "physical latency", "live capture"],
    });
    // A valid observation may contain no connected controller. Read the result
    // code; process success does not indicate a published or working device.
    println!(
        "{}",
        serde_json::to_string_pretty(&report).expect("bounded serializable witness")
    );
    std::process::ExitCode::SUCCESS
}

fn main() -> std::process::ExitCode {
    let options = Options::parse();
    #[cfg(windows)]
    {
        observe(options)
    }
    #[cfg(not(windows))]
    {
        let _ = options;
        println!("{{\"schemaVersion\":1,\"available\":false,\"reason\":\"XInput observation requires Windows\",\"gameplayVerified\":false}}");
        std::process::ExitCode::from(2)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn neutral() -> Gamepad {
        Gamepad {
            buttons: 0,
            left_trigger: 0,
            right_trigger: 0,
            left_x: 0,
            left_y: 0,
            right_x: 0,
            right_y: 0,
        }
    }

    #[test]
    fn either_trigger_or_axis_prevents_false_neutral() {
        assert!(neutral().neutral());
        for state in [
            Gamepad {
                left_trigger: 255,
                right_trigger: 255,
                ..neutral()
            },
            Gamepad {
                right_trigger: 1,
                ..neutral()
            },
            Gamepad {
                left_x: i16::MIN,
                ..neutral()
            },
            Gamepad {
                left_y: i16::MAX,
                ..neutral()
            },
            Gamepad {
                right_x: -1,
                ..neutral()
            },
            Gamepad {
                right_y: 1,
                ..neutral()
            },
            Gamepad {
                buttons: 0x1000,
                ..neutral()
            },
        ] {
            assert!(!state.neutral());
        }
    }

    #[test]
    fn raw_witness_preserves_both_triggers_and_axis_extremes() {
        let state = Gamepad {
            left_trigger: 255,
            right_trigger: 255,
            left_x: i16::MIN,
            right_y: i16::MAX,
            ..neutral()
        };
        let json = serde_json::to_value(&state).unwrap();
        assert_eq!(json["leftTrigger"], 255);
        assert_eq!(json["rightTrigger"], 255);
        assert_eq!(json["leftX"], -32768);
        assert_eq!(json["rightY"], 32767);
    }

    #[test]
    fn bounds_reject_unbounded_observations_and_invalid_slots() {
        for arguments in [
            vec!["probe", "--slot", "4"],
            vec!["probe", "--duration-ms", "30001"],
            vec!["probe", "--interval-ms", "0"],
        ] {
            assert!(Options::try_parse_from(arguments).is_err());
        }
        assert!(Options::try_parse_from(["probe", "--duration-ms", "0"]).is_ok());
    }

    #[test]
    fn failed_read_is_not_neutral_or_connected() {
        let json = serde_json::to_value(Sample {
            elapsed_microseconds: 0,
            result: 1167,
            packet_number: None,
            gamepad: None,
            neutral: None,
        })
        .unwrap();
        assert!(json["gamepad"].is_null());
        assert!(json["neutral"].is_null());
    }
}
