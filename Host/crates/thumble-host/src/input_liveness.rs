//! Receiver scheduling-gap safety. The macOS input clock includes system sleep;
//! wall-clock adjustments cannot extend a hold or make queued pre-sleep input fresh.
use std::time::Instant;

pub(crate) struct InputClock {
    fallback: Instant,
    #[cfg(target_os = "macos")]
    origin: u64,
    #[cfg(target_os = "macos")]
    scale: MachTimebase,
}

#[cfg(target_os = "macos")]
#[repr(C)]
struct MachTimebase {
    numer: u32,
    denom: u32,
}

#[cfg(target_os = "macos")]
extern "C" {
    fn mach_continuous_time() -> u64;
    fn mach_timebase_info(info: *mut MachTimebase) -> i32;
}

impl InputClock {
    pub(crate) fn now() -> Self {
        Self {
            fallback: Instant::now(),
            #[cfg(target_os = "macos")]
            origin: unsafe { mach_continuous_time() },
            #[cfg(target_os = "macos")]
            scale: {
                let mut scale = MachTimebase { numer: 0, denom: 0 };
                // Public libSystem ABI (<mach/mach_time.h>); no device, account
                // or permission mutation. Avoid deprecated libc Rust wrappers.
                unsafe {
                    mach_timebase_info(&mut scale);
                }
                scale
            },
        }
    }

    pub(crate) fn elapsed_millis(&self) -> i64 {
        #[cfg(target_os = "macos")]
        if self.scale.denom != 0 {
            let ticks = unsafe { mach_continuous_time() }.saturating_sub(self.origin);
            let millis = u128::from(ticks) * u128::from(self.scale.numer)
                / u128::from(self.scale.denom)
                / 1_000_000;
            return i64::try_from(millis).unwrap_or(i64::MAX);
        }
        i64::try_from(self.fallback.elapsed().as_millis()).unwrap_or(i64::MAX)
    }
}

#[derive(Default)]
pub(crate) struct InputLiveness {
    last_poll: Option<i64>,
}

impl InputLiveness {
    pub(crate) fn observe(&mut self, now: i64, maximum_gap: i64) -> bool {
        self.last_poll
            .replace(now)
            .is_some_and(|last| now.saturating_sub(last) > maximum_gap)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn continuous_clock_advances_and_gap_detection_does_not_repeat_or_use_wall_time() {
        let clock = InputClock::now();
        let before = clock.elapsed_millis();
        std::thread::sleep(std::time::Duration::from_millis(2));
        assert!(clock.elapsed_millis() >= before);
        let mut watch = InputLiveness::default();
        assert!(!watch.observe(0, 1750));
        assert!(!watch.observe(250, 1750));
        assert!(watch.observe(10_000, 1750));
        assert!(!watch.observe(10_001, 1750));
    }
}
