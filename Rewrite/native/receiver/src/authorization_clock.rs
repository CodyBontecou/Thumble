//! Bounded durable clock reservations for native authorization. No filesystem IO
//! occurs while checking a previously reserved input observation.
use std::{
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex,
    },
    time::{Duration, Instant},
};
pub(crate) const RESERVATION_MS: u64 = 1_000;
pub(crate) const RENEW_BEFORE: Duration = Duration::from_millis(500);
pub(crate) struct Observation {
    pub now: u64,
    pub started: Instant,
}
struct State {
    observed: u64,
    reserved: u64,
    deadline: Instant,
    failed: bool,
}
pub(crate) struct Clock {
    state: Mutex<State>,
    demand: AtomicU64,
}
impl Clock {
    pub fn new(last: u64, reserved: u64) -> Result<Self, &'static str> {
        if last > reserved || reserved > i64::MAX as u64 || reserved - last > RESERVATION_MS {
            return Err("phone_trust_storage_invalid");
        }
        Ok(Self {
            state: Mutex::new(State {
                observed: reserved,
                reserved,
                deadline: Instant::now(),
                failed: false,
            }),
            demand: AtomicU64::new(0),
        })
    }
    /// A fresh native clock is read under the short in-memory observation lock,
    /// so parallel transports cannot invert timestamps captured before waiting.
    pub fn prepare(
        &self,
        now: &mut impl FnMut() -> Result<u64, &'static str>,
        revoking: bool,
    ) -> Result<Observation, &'static str> {
        let state = self
            .state
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        if state.failed && !revoking {
            return Err("phone_trust_reservation_failed");
        }
        let started = Instant::now();
        let now = now()?;
        if now > i64::MAX as u64 {
            return Err("phone_trust_clock_invalid");
        }
        if now < state.observed && !revoking {
            return Err("phone_trust_clock_rollback");
        }
        let accepted = now.max(state.observed);
        Ok(Observation {
            now: accepted,
            started,
        })
    }
    /// Publication occurs only after the ceiling commits with synchronous=EXTRA.
    /// Time spent writing consumes the reservation; it never resets its deadline.
    pub fn publish(&self, observation: &Observation, reserved: u64) -> Result<(), &'static str> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        if state.failed {
            return Err("phone_trust_reservation_failed");
        }
        if reserved < state.observed
            || reserved < state.reserved
            || reserved
                > observation
                    .now
                    .checked_add(RESERVATION_MS)
                    .ok_or("phone_trust_clock_invalid")?
        {
            return Err("phone_trust_storage_invalid");
        }
        state.observed = state.observed.max(observation.now);
        state.reserved = reserved;
        state.deadline = observation.started + Duration::from_millis(RESERVATION_MS);
        Ok(())
    }
    pub fn sample(
        &self,
        now: &mut impl FnMut() -> Result<u64, &'static str>,
    ) -> Result<u64, &'static str> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        if state.failed {
            return Err("phone_trust_reservation_failed");
        }
        if Instant::now() >= state.deadline {
            state.failed = true;
            return Err("phone_trust_reservation_expired");
        }
        let now = now()?;
        if Instant::now() >= state.deadline {
            state.failed = true;
            return Err("phone_trust_reservation_expired");
        }
        if now < state.observed {
            return Err("phone_trust_clock_rollback");
        }
        if now > state.reserved {
            return Err("phone_trust_clock_unreserved");
        }
        state.observed = now;
        Ok(now)
    }
    pub fn needs_reservation(&self) -> bool {
        self.demand.load(Ordering::Acquire) != 0
            && self
                .state
                .lock()
                .map(|state| {
                    !state.failed
                        && state.deadline.saturating_duration_since(Instant::now()) <= RENEW_BEFORE
                })
                .unwrap_or(false)
    }
    pub fn fail(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.failed = true;
        }
    }
    pub fn retain(&self) {
        self.demand.fetch_add(1, Ordering::AcqRel);
    }
    pub fn release(&self) {
        self.demand.fetch_sub(1, Ordering::AcqRel);
    }
    #[cfg(test)]
    pub fn ceiling(&self) -> u64 {
        self.state.lock().unwrap().reserved
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_durable_reservations_admit_observations_and_restart_refuses_the_reserved_past() {
        let unreserved = Clock::new(100, 100).unwrap();
        assert_eq!(
            unreserved.sample(&mut || Ok(100)),
            Err("phone_trust_reservation_expired")
        );
        let clock = Clock::new(100, 100).unwrap();
        let observation = clock.prepare(&mut || Ok(100), false).unwrap();
        clock.publish(&observation, 1100).unwrap();
        assert_eq!(clock.sample(&mut || Ok(101)), Ok(101));
        assert_eq!(
            clock.sample(&mut || Ok(100)),
            Err("phone_trust_clock_rollback")
        );
        assert_eq!(
            clock.sample(&mut || Ok(1101)),
            Err("phone_trust_clock_unreserved")
        );
        let restarted = Clock::new(100, 1100).unwrap();
        assert_eq!(
            restarted.prepare(&mut || Ok(1099), false).err(),
            Some("phone_trust_clock_rollback")
        );
        assert_eq!(
            restarted.prepare(&mut || Ok(1100), false).unwrap().now,
            1100
        );
    }
    #[test]
    fn delayed_or_failed_durable_reservations_never_extend_authorization() {
        let clock = Clock::new(100, 100).unwrap();
        let mut observation = clock.prepare(&mut || Ok(100), false).unwrap();
        observation.started -= Duration::from_millis(RESERVATION_MS + 1);
        clock.publish(&observation, 1100).unwrap();
        assert_eq!(
            clock.sample(&mut || Ok(101)),
            Err("phone_trust_reservation_expired")
        );
        assert_eq!(
            clock.prepare(&mut || Ok(101), false).err(),
            Some("phone_trust_reservation_failed")
        );
        let clock = Clock::new(100, 100).unwrap();
        let observation = clock.prepare(&mut || Ok(101), false).unwrap();
        clock.publish(&observation, 1101).unwrap();
        assert_eq!(clock.sample(&mut || Ok(102)), Ok(102));
        clock.fail();
        assert_eq!(
            clock.sample(&mut || Ok(103)),
            Err("phone_trust_reservation_failed")
        );
        assert_eq!(
            clock.prepare(&mut || Ok(103), false).err(),
            Some("phone_trust_reservation_failed")
        );
        assert_eq!(clock.prepare(&mut || Ok(99), true).unwrap().now, 102);
    }
}
