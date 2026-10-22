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
    owner_session: String,
    expires: u64,
}
#[derive(Default)]
pub struct PacketRuntime {
    core: Runtime,
    admission: Option<Admission>,
    last_time: Option<u64>,
    used_sessions: Vec<[u8; 16]>,
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
        let generation = grant.generation();
        let session = grant.session();
        self.apply_owner(
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
        )?;
        self.attach(grant, revision, GRANT_LIFETIME_MS, now, output)
    }
    /// Owner/configuration IPC remains separate from the packet sender's identity and sequence.
    pub fn apply_owner(
        &mut self,
        command: Command,
        now: u64,
        output: &mut impl Output,
    ) -> Result<bool, &'static str> {
        self.tick(now, output)?;
        if matches!(&command, Command::Sample { .. }) && self.admission.is_some() {
            return Err("packet_session_owns_input");
        }
        let activates = matches!(&command, Command::Activate { .. });
        let retires = matches!(
            &command,
            Command::Activate { .. } | Command::Release {} | Command::Shutdown {}
        );
        let result = self.core.apply(command, now, output);
        if activates && result.is_ok() {
            self.used_sessions.clear();
        }
        if (retires && result.is_ok()) || !self.core.is_active() {
            self.admission = None;
        }
        result
    }
    /// Native authenticated handoff only. Exact generation/revision must already be active.
    /// A new key/source starts neutral, resets input sequence and never renews the configuration owner.
    pub fn attach(
        &mut self,
        grant: PacketGrant,
        revision: u64,
        lifetime_ms: u64,
        now: u64,
        output: &mut impl Output,
    ) -> Result<(), &'static str> {
        self.tick(now, output)?;
        if !(100..=GRANT_LIFETIME_MS).contains(&lifetime_ms) {
            return Err("invalid_grant_lifetime");
        }
        let expires = now.checked_add(lifetime_ms).ok_or("invalid_clock")?;
        let generation = grant.generation();
        let session = grant.session();
        if self.used_sessions.contains(&session) {
            return Err("packet_session_reused");
        }
        if self.used_sessions.len() >= 64 {
            return Err("packet_session_budget_exhausted");
        }
        let owner = self
            .core
            .switch_packet_source(generation, revision, now, output);
        if owner.is_err() && !self.core.is_active() {
            self.admission = None;
        }
        let owner_session = owner?;
        self.used_sessions.push(session);
        self.admission = Some(Admission {
            packets: PacketReceiver::new(grant),
            generation,
            session,
            owner_session,
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
                session_id: a.owner_session.clone(),
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
    /// Legacy standalone harness renewal. A packet identity cannot renew a separately configured owner.
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
            .filter(|a| {
                a.generation == generation
                    && a.session == session
                    && a.owner_session == hex(&session)
            })
            .ok_or("input_session_closed")?;
        self.core
            .apply(
                Command::Renew {
                    generation: a.generation.to_string(),
                    session_id: a.owner_session.clone(),
                },
                now,
                output,
            )
            .map(|_| ())
    }
    /// Revocation/disconnect/configuration replacement retires keys before output cleanup.
    pub fn release(&mut self, output: &mut impl Output) -> Result<(), &'static str> {
        self.release_reason(output, "packet_session_released")
    }
    pub fn release_reason(
        &mut self,
        output: &mut impl Output,
        reason: &'static str,
    ) -> Result<(), &'static str> {
        self.admission = None;
        self.core.release(output, reason)
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
    fn owner_activate(r: &mut PacketRuntime, o: &mut Sink, now: u64) {
        r.apply_owner(
            Command::Activate {
                generation: "1".into(),
                revision: "9".into(),
                profile_id: "profile-a".into(),
                session_id: "service-owner".into(),
                lease_ms: 750,
                input_ttl_ms: 350,
            },
            now,
            o,
        )
        .unwrap();
    }
    fn owner_renew(r: &mut PacketRuntime, o: &mut Sink, now: u64) {
        r.apply_owner(
            Command::Renew {
                generation: "1".into(),
                session_id: "service-owner".into(),
            },
            now,
            o,
        )
        .unwrap();
    }
    #[test]
    fn native_packet_source_attaches_to_exact_acknowledged_config_without_replacing_owner_identity()
    {
        let mut r = PacketRuntime::default();
        let mut o = Sink::default();
        owner_activate(&mut r, &mut o, 0);
        r.apply_owner(
            Command::Sample {
                generation: "1".into(),
                session_id: "service-owner".into(),
                sequence: "900".into(),
                state: state(true),
            },
            1,
            &mut o,
        )
        .unwrap();
        assert_ne!(o.report, NEUTRAL);
        assert_eq!(
            r.attach(grant(2), 9, 1000, 2, &mut o),
            Err("inactive_generation")
        );
        assert_eq!(
            r.attach(grant(1), 10, 1000, 2, &mut o),
            Err("inactive_generation")
        );
        assert_ne!(o.report, NEUTRAL);
        r.attach(grant(1), 9, 1000, 3, &mut o).unwrap();
        assert_eq!(o.report, NEUTRAL);
        assert_eq!(r.snapshot().generation, "1");
        assert_eq!(r.snapshot().revision, "9");
        assert_eq!(r.snapshot().profile_id.as_deref(), Some("profile-a"));
        assert!(r.snapshot().sequence.is_none());
        let mut sender = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        let packet = sender.seal(&state(true)).unwrap();
        r.receive(&packet, 4, &mut o).unwrap();
        assert_eq!(r.snapshot().sequence.as_deref(), Some("0"));
        assert_eq!(
            r.apply_owner(
                Command::Sample {
                    generation: "1".into(),
                    session_id: "service-owner".into(),
                    sequence: "901".into(),
                    state: state(false)
                },
                5,
                &mut o
            ),
            Err("packet_session_owns_input")
        );
        assert_eq!(
            r.apply_owner(
                Command::Renew {
                    generation: "1".into(),
                    session_id: hex(&SESSION)
                },
                5,
                &mut o
            ),
            Err("inactive_generation")
        );
        assert_eq!(
            r.renew_owner(1, SESSION, 5, &mut o),
            Err("input_session_closed")
        );
        owner_renew(&mut r, &mut o, 6);
        assert_eq!(
            r.attach(grant(1), 9, 1000, 7, &mut o),
            Err("packet_session_reused")
        );
        assert_eq!(r.receive(&packet, 8, &mut o), Err("input_packet_rejected"));
    }
    #[test]
    fn attaching_or_receiving_packets_never_extends_the_independent_configuration_lease() {
        let mut r = PacketRuntime::default();
        let mut o = Sink::default();
        owner_activate(&mut r, &mut o, 0);
        r.attach(grant(1), 9, 1000, 700, &mut o).unwrap();
        let mut sender = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        r.receive(&sender.seal(&state(true)).unwrap(), 740, &mut o)
            .unwrap();
        r.tick(750, &mut o).unwrap();
        assert!(!r.snapshot().active);
        assert_eq!(o.report, NEUTRAL);
        assert_eq!(r.snapshot().last_release_reason, "lease_expired");
        assert_eq!(
            r.attach(grant(1), 9, 1000, 751, &mut o),
            Err("packet_session_reused")
        );
        assert_eq!(
            r.receive(&sender.seal(&state(true)).unwrap(), 751, &mut o),
            Err("input_session_closed")
        );
    }
    #[test]
    fn source_replacement_is_neutral_and_cannot_restore_any_retired_session_in_the_same_generation()
    {
        let mut r = PacketRuntime::default();
        let mut o = Sink::default();
        owner_activate(&mut r, &mut o, 0);
        r.attach(grant(1), 9, 1000, 1, &mut o).unwrap();
        let mut old = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        r.receive(&old.seal(&state(true)).unwrap(), 2, &mut o)
            .unwrap();
        let fresh = || PacketGrant::new(&[8; 32], [6; 16], [4; 4], 1).unwrap();
        r.attach(fresh(), 9, 1000, 3, &mut o).unwrap();
        assert_eq!(o.report, NEUTRAL);
        assert_eq!(
            r.receive(&old.seal(&state(true)).unwrap(), 4, &mut o),
            Err("input_packet_rejected")
        );
        assert_eq!(
            r.attach(grant(1), 9, 1000, 5, &mut o),
            Err("packet_session_reused")
        );
        let mut sender = PacketSender::new(fresh(), PACKET_LIMIT).unwrap();
        r.receive(&sender.seal(&state(true)).unwrap(), 6, &mut o)
            .unwrap();
        r.apply_owner(Command::Release {}, 7, &mut o).unwrap();
        assert_eq!(o.report, NEUTRAL);
        assert_eq!(
            r.receive(&sender.seal(&state(true)).unwrap(), 8, &mut o),
            Err("input_session_closed")
        );
    }
    #[test]
    fn source_history_is_bounded_per_activation_and_failed_neutralization_retires_all_input() {
        let mut r = PacketRuntime::default();
        let mut o = Sink::default();
        owner_activate(&mut r, &mut o, 0);
        for id in 1..=64u8 {
            let grant = PacketGrant::new(&[id; 32], [id; 16], [id; 4], 1).unwrap();
            r.attach(grant, 9, 1000, u64::from(id), &mut o).unwrap();
        }
        let grant = PacketGrant::new(&[65; 32], [65; 16], [65; 4], 1).unwrap();
        assert_eq!(
            r.attach(grant, 9, 1000, 65, &mut o),
            Err("packet_session_budget_exhausted")
        );
        r.apply_owner(
            Command::Activate {
                generation: "2".into(),
                revision: "10".into(),
                profile_id: "profile-a".into(),
                session_id: "service-owner".into(),
                lease_ms: 750,
                input_ttl_ms: 350,
            },
            66,
            &mut o,
        )
        .unwrap();
        let fresh = || PacketGrant::new(&[99; 32], SESSION, [88; 4], 2).unwrap();
        r.attach(fresh(), 10, 1000, 67, &mut o).unwrap();
        let mut sender = PacketSender::new(fresh(), PACKET_LIMIT).unwrap();
        r.receive(&sender.seal(&state(true)).unwrap(), 68, &mut o)
            .unwrap();
        o.failed = true;
        let grant = PacketGrant::new(&[100; 32], [100; 16], [100; 4], 2).unwrap();
        assert_eq!(
            r.attach(grant, 10, 1000, 69, &mut o),
            Err("mock_output_failed")
        );
        assert!(!r.snapshot().active);
        assert_eq!(r.snapshot().report_hex, hex(&NEUTRAL));
        o.failed = false;
        assert_eq!(
            r.receive(&sender.seal(&state(true)).unwrap(), 70, &mut o),
            Err("input_session_closed")
        );
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
