//! Sleep-inclusive monotonic clocks; wall-clock changes cannot extend a lease.
#[cfg(target_os = "macos")]
#[repr(C)]
#[derive(Default)]
struct Timebase {
    numer: u32,
    denom: u32,
}
#[cfg(target_os = "macos")]
extern "C" {
    fn mach_continuous_time() -> u64;
    fn mach_timebase_info(info: *mut Timebase) -> i32;
}

pub fn millis() -> Result<u64, &'static str> {
    #[cfg(target_os = "macos")]
    {
        static SCALE: std::sync::OnceLock<Timebase> = std::sync::OnceLock::new();
        let scale = SCALE.get_or_init(|| {
            let mut scale = Timebase::default();
            unsafe {
                mach_timebase_info(&mut scale);
            }
            scale
        });
        if scale.denom == 0 {
            return Err("clock_unavailable");
        }
        // SAFETY: public libSystem monotonic-time ABI, no shared mutable storage.
        let ticks = unsafe { mach_continuous_time() };
        Ok(
            (u128::from(ticks) * u128::from(scale.numer) / u128::from(scale.denom) / 1_000_000)
                .min(u128::from(u64::MAX)) as u64,
        )
    }
    #[cfg(windows)]
    {
        Ok(unsafe { windows_sys::Win32::System::SystemInformation::GetTickCount64() })
    }
    #[cfg(target_os = "linux")]
    {
        let mut time = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        if unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut time) } != 0 || time.tv_sec < 0 {
            return Err("clock_unavailable");
        }
        Ok((time.tv_sec as u64)
            .saturating_mul(1000)
            .saturating_add(time.tv_nsec as u64 / 1_000_000))
    }
    #[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
    {
        Err("unsupported_platform")
    }
}
