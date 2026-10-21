//! Authenticated packet admission into the native safety owner. No network listener or trust store.
use crate::{
    gamepad::hex,
    input_packet::{PacketGrant, PacketReceiver},
    runtime::{Command, Output, Runtime, Snapshot},
};
const GRANT_LIFETIME_MS: u64 = 600_000;
struct Admission {
    packets: PacketReceiver,
    generation: u64,
    session: [u8; 16],
    expires: u64,
}
#[derive(Default)]
pub struct PacketRuntime {
    core: Runtime,
    admission: Option<Admission>,
    last_time: Option<u64>,
}
impl PacketRuntime {
    pub fn snapshot(&self) -> Snapshot {
        self.core.snapshot()
    }
    /// Trusted configuration operation only; the caller must have authenticated the grant owner.
    pub fn activate(
        &mut self,
        grant: PacketGrant,
        revision: u64,
        profile_id: String,
        now: u64,
        output: &mut impl Output,
    ) -> Result<(), &'static str> {
        self.tick(now, output)?;
        let expires = now.checked_add(GRANT_LIFETIME_MS).ok_or("invalid_clock")?;
        let generation = grant.generation();
        let session = grant.session();
        let activated = self.core.apply(
            Command::Activate {
                generation: generation.to_string(),
                revision: revision.to_string(),
                profile_id,
                session_id: hex(&session),
                lease_ms: 750,
                input_ttl_ms: 350,
            },
            now,
            output,
        );
        if activated.is_err() && !self.core.is_active() {
            self.admission = None;
        }
        activated?;
        self.admission = Some(Admission {
            packets: PacketReceiver::new(grant),
            generation,
            session,
            expires,
        });
        Ok(())
    }
    pub fn tick(&mut self, now: u64, output: &mut impl Output) -> Result<(), &'static str> {
        if self.last_time.is_some_and(|last| now < last) {
            self.admission = None;
            self.core.release(output, "clock_rollback")?;
            return Err("clock_rollback");
        }
        self.last_time = Some(now);
        if self.admission.as_ref().is_some_and(|a| now >= a.expires) {
            self.admission = None;
            self.core.release(output, "grant_expired")?;
        }
        let result = self.core.tick(now, output);
        if !self.core.is_active() {
            self.admission = None;
        }
        result
    }
    /// Either UDP or reliable fallback passes the identical sealed packet here.
    pub fn receive(
        &mut self,
        packet: &[u8],
        now: u64,
        output: &mut impl Output,
    ) -> Result<(), &'static str> {
        self.tick(now, output)?;
        let a = self.admission.as_mut().ok_or("input_session_closed")?;
        let state = a
            .packets
            .open(packet)
            .map_err(|_| "input_packet_rejected")?;
        let sequence = a.packets.newest_sequence().ok_or("input_packet_rejected")?;
        let result = self.core.apply(
            Command::Sample {
                generation: a.generation.to_string(),
                session_id: hex(&a.session),
                sequence: sequence.to_string(),
                state,
            },
            now,
            output,
        );
        if result.is_err() {
            self.admission = None;
        }
        result.map(|_| ())
    }
    pub fn renew_owner(
        &mut self,
        generation: u64,
        session: [u8; 16],
        now: u64,
        output: &mut impl Output,
    ) -> Result<(), &'static str> {
        self.tick(now, output)?;
        let a = self
            .admission
            .as_ref()
            .filter(|a| a.generation == generation && a.session == session)
            .ok_or("input_session_closed")?;
        self.core
            .apply(
                Command::Renew {
                    generation: a.generation.to_string(),
                    session_id: hex(&a.session),
                },
                now,
                output,
            )
            .map(|_| ())
    }
    /// Revocation/disconnect/configuration replacement retires keys before output cleanup.
    pub fn release(&mut self, output: &mut impl Output) -> Result<(), &'static str> {
        self.admission = None;
        self.core.release(output, "packet_session_released")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        gamepad::NEUTRAL,
        generated::GamepadState,
        input_packet::{PacketSender, PACKET_LIMIT},
    };
    const SESSION: [u8; 16] = [7; 16];
    #[derive(Default)]
    struct Sink {
        report: [u8; 20],
        failed: bool,
    }
    impl Output for Sink {
        fn submit(&mut self, report: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            if self.failed {
                Err("mock_output_failed")
            } else {
                self.report = report;
                Ok(())
            }
        }
    }
    fn grant(generation: u64) -> PacketGrant {
        PacketGrant::new(&[5; 32], SESSION, [9; 4], generation).unwrap()
    }
    fn state(held: bool) -> GamepadState {
        serde_json::from_value(serde_json::json!({"buttons":if held {vec!["south"]} else {vec![]},"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":if held {1} else {0},"rightTrigger":if held {1} else {0}})).unwrap()
    }
    #[test]
    fn encrypted_full_states_repair_loss_but_replays_cannot_refresh_expiry() {
        let mut r = PacketRuntime::default();
        let mut o = Sink::default();
        let mut s = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        r.activate(grant(1), 1, "profile".into(), 0, &mut o)
            .unwrap();
        let hold = s.seal(&state(true)).unwrap();
        r.receive(&hold, 1, &mut o).unwrap();
        assert_ne!(o.report, NEUTRAL);
        let _lost_release = s.seal(&state(false)).unwrap();
        let repair = s.seal(&state(false)).unwrap();
        r.receive(&repair, 100, &mut o).unwrap();
        assert_eq!(o.report, NEUTRAL);
        let hold = s.seal(&state(true)).unwrap();
        r.receive(&hold, 200, &mut o).unwrap();
        assert_eq!(r.receive(&hold, 500, &mut o), Err("input_packet_rejected"));
        r.renew_owner(1, SESSION, 500, &mut o).unwrap();
        r.tick(550, &mut o).unwrap();
        assert!(!r.snapshot().active);
        assert_eq!(o.report, NEUTRAL);
        assert_eq!(r.snapshot().last_release_reason, "input_expired");
        assert_eq!(
            r.receive(&s.seal(&state(true)).unwrap(), 551, &mut o),
            Err("input_session_closed")
        );
    }
    #[test]
    fn owner_lease_generation_release_and_restart_retire_authenticated_packets() {
        let mut r = PacketRuntime::default();
        let mut o = Sink::default();
        let mut old = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        r.activate(grant(1), 1, "profile".into(), 0, &mut o)
            .unwrap();
        r.receive(&old.seal(&state(true)).unwrap(), 0, &mut o)
            .unwrap();
        r.receive(&old.seal(&state(true)).unwrap(), 300, &mut o)
            .unwrap();
        r.receive(&old.seal(&state(true)).unwrap(), 600, &mut o)
            .unwrap();
        r.tick(750, &mut o).unwrap();
        assert_eq!(r.snapshot().last_release_reason, "lease_expired");
        assert_eq!(o.report, NEUTRAL);
        r.activate(grant(2), 2, "profile".into(), 751, &mut o)
            .unwrap();
        assert_eq!(
            r.receive(&old.seal(&state(true)).unwrap(), 752, &mut o),
            Err("input_packet_rejected")
        );
        assert_eq!(
            r.renew_owner(1, SESSION, 752, &mut o),
            Err("input_session_closed")
        );
        let mut new = PacketSender::new(grant(2), PACKET_LIMIT).unwrap();
        r.receive(&new.seal(&state(true)).unwrap(), 753, &mut o)
            .unwrap();
        r.release(&mut o).unwrap();
        assert_eq!(o.report, NEUTRAL);
        assert_eq!(
            r.receive(&new.seal(&state(true)).unwrap(), 754, &mut o),
            Err("input_session_closed")
        );
        let mut restarted = PacketRuntime::default();
        assert!(!restarted.snapshot().active);
        assert_eq!(
            restarted.receive(&old.seal(&state(true)).unwrap(), 755, &mut o),
            Err("input_session_closed")
        );
    }
    #[test]
    fn authenticated_grants_expire_despite_continued_input_and_owner_renewals() {
        let mut r = PacketRuntime::default();
        let mut o = Sink::default();
        let mut s = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        r.activate(grant(1), 1, "profile".into(), 0, &mut o)
            .unwrap();
        for now in (0..GRANT_LIFETIME_MS).step_by(200) {
            r.renew_owner(1, SESSION, now, &mut o).unwrap();
            r.receive(&s.seal(&state(true)).unwrap(), now, &mut o)
                .unwrap();
        }
        r.tick(GRANT_LIFETIME_MS, &mut o).unwrap();
        assert_eq!(o.report, NEUTRAL);
        assert_eq!(r.snapshot().last_release_reason, "grant_expired");
        assert_eq!(
            r.receive(
                &s.seal(&state(true)).unwrap(),
                GRANT_LIFETIME_MS + 1,
                &mut o
            ),
            Err("input_session_closed")
        );
    }
    #[test]
    fn output_failure_and_clock_rollback_fail_closed() {
        let mut r = PacketRuntime::default();
        let mut o = Sink::default();
        let mut s = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        r.activate(grant(1), 1, "profile".into(), 100, &mut o)
            .unwrap();
        r.receive(&s.seal(&state(true)).unwrap(), 101, &mut o)
            .unwrap();
        assert_eq!(r.tick(100, &mut o), Err("clock_rollback"));
        assert_eq!(o.report, NEUTRAL);
        assert!(!r.snapshot().active);
        r.activate(grant(2), 2, "profile".into(), 102, &mut o)
            .unwrap();
        let mut s = PacketSender::new(grant(2), PACKET_LIMIT).unwrap();
        o.failed = true;
        assert_eq!(
            r.receive(&s.seal(&state(true)).unwrap(), 103, &mut o),
            Err("output_failed")
        );
        assert!(!r.snapshot().active);
        o.failed = false;
        assert_eq!(
            r.receive(&s.seal(&state(true)).unwrap(), 104, &mut o),
            Err("input_session_closed")
        );
    }
}

#[cfg(test)]
mod activation_failure_tests {
    use super::*;
    use crate::{
        generated::GamepadState,
        input_packet::{PacketSender, PACKET_LIMIT},
    };
    const SESSION: [u8; 16] = [3; 16];
    struct Sink {
        fail: bool,
    }
    impl Output for Sink {
        fn submit(&mut self, _: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            if self.fail {
                Err("failed")
            } else {
                Ok(())
            }
        }
    }
    fn grant(generation: u64) -> PacketGrant {
        PacketGrant::new(&[8; 32], SESSION, [6; 4], generation).unwrap()
    }
    #[test]
    fn invalid_configuration_preserves_old_grant_but_failed_activation_barrier_retires_it() {
        let mut r = PacketRuntime::default();
        let mut sink = Sink { fail: false };
        r.activate(grant(1), 1, "valid".into(), 0, &mut sink)
            .unwrap();
        let mut sender = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        let neutral:GamepadState=serde_json::from_value(serde_json::json!({"buttons":[],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":0,"rightTrigger":0})).unwrap();
        assert_eq!(
            r.activate(grant(1), 2, "valid".into(), 1, &mut sink),
            Err("stale_activation")
        );
        assert_eq!(
            r.activate(grant(2), 2, "bad profile".into(), 2, &mut sink),
            Err("invalid_activation")
        );
        r.receive(&sender.seal(&neutral).unwrap(), 3, &mut sink)
            .unwrap();
        sink.fail = true;
        assert!(r
            .activate(grant(2), 2, "valid".into(), 4, &mut sink)
            .is_err());
        assert!(!r.snapshot().active);
        sink.fail = false;
        assert_eq!(
            r.receive(&sender.seal(&neutral).unwrap(), 5, &mut sink),
            Err("input_session_closed")
        );
    }
}
