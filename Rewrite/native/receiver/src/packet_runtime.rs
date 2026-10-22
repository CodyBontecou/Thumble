//! Authenticated packet admission into the native safety owner. No network listener or trust store.
use crate::{
    gamepad::hex,
    input_packet::{PacketGrant, PacketReceiver},
    runtime::{Command, Output, Runtime, Snapshot},
};
const GRANT_LIFETIME_MS: u64 = 600_000;
const ROTATION_WAIT_MS: u64 = 2000;
struct Admission {
    packets: PacketReceiver,
    generation: u64,
    session: [u8; 16],
    owner_session: String,
    expires: u64,
}
struct Rotation {
    packets: PacketReceiver,
    session: [u8; 16],
    expires: u64,
    commit_deadline: u64,
}
#[derive(Default)]
pub struct PacketRuntime {
    core: Runtime,
    admission: Option<Admission>,
    rotation: Option<Rotation>,
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
            self.rotation = None;
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
            self.rotation = None;
        }
        let owner_session = owner?;
        self.rotation = None;
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
    /// Stage only for the current live source; the native issuer supplies fresh random key material.
    /// Preparing a grant never changes output, packet sequence, or any existing deadline.
    pub(crate) fn stage_rotation(
        &mut self,
        previous: [u8; 16],
        grant: PacketGrant,
        revision: u64,
        lifetime_ms: u64,
        now: u64,
        output: &mut impl Output,
    ) -> Result<(), &'static str> {
        self.tick(now, output)?;
        if self.rotation.is_some() {
            return Err("input_rotation_pending");
        }
        if !(100..=GRANT_LIFETIME_MS).contains(&lifetime_ms) {
            return Err("invalid_grant_lifetime");
        }
        let active = self
            .admission
            .as_ref()
            .filter(|a| a.session == previous && a.generation == grant.generation())
            .ok_or("input_session_closed")?;
        let snapshot = self.core.snapshot();
        if snapshot.revision != revision.to_string()
            || snapshot.sequence.is_none()
            || grant.session() == active.session
            || self.used_sessions.contains(&grant.session())
        {
            return Err("input_rotation_invalid");
        }
        let expires = now.checked_add(lifetime_ms).ok_or("invalid_clock")?;
        let commit_deadline = now
            .checked_add(ROTATION_WAIT_MS.min(lifetime_ms))
            .ok_or("invalid_clock")?;
        self.rotation = Some(Rotation {
            session: grant.session(),
            packets: PacketReceiver::new(grant),
            expires,
            commit_deadline,
        });
        Ok(())
    }
    pub(crate) fn rotation_session(&self) -> Option<[u8; 16]> {
        self.rotation.as_ref().map(|r| r.session)
    }
    pub(crate) fn cancel_rotation(&mut self, session: [u8; 16]) {
        if self.rotation_session() == Some(session) {
            self.rotation = None;
        }
    }
    pub fn tick(&mut self, now: u64, output: &mut impl Output) -> Result<(), &'static str> {
        if self.last_time.is_some_and(|last| now < last) {
            self.admission = None;
            self.rotation = None;
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
        if self.admission.is_none()
            || self
                .rotation
                .as_ref()
                .is_some_and(|r| now >= r.commit_deadline)
        {
            self.rotation = None;
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
        if self
            .rotation
            .as_ref()
            .is_some_and(|r| packet.get(8..24) == Some(r.session.as_slice()))
        {
            let rotation = self.rotation.as_mut().ok_or("input_session_closed")?;
            let state = rotation
                .packets
                .open(packet)
                .map_err(|_| "input_packet_rejected")?;
            if rotation.packets.newest_sequence() != Some(0) {
                self.rotation = None;
                return Err("input_rotation_requires_first_sample");
            }
            let rotation = self.rotation.take().ok_or("input_session_closed")?;
            let current = self.admission.as_ref().ok_or("input_session_closed")?;
            let generation = current.generation;
            let owner = current.owner_session.clone();
            let revision = crate::runtime::decimal(&self.core.snapshot().revision)?;
            let result = self
                .core
                .continue_packet_source(generation, revision, &owner, state, now, output);
            if result.is_err() {
                if !self.core.is_active() {
                    self.admission = None;
                }
                return result;
            }
            self.admission = Some(Admission {
                packets: rotation.packets,
                generation,
                session: rotation.session,
                owner_session: owner,
                expires: rotation.expires,
            });
            return Ok(());
        }
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
            self.rotation = None;
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
        self.rotation = None;
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
        history: Vec<[u8; 20]>,
    }
    impl Output for Sink {
        fn submit(&mut self, report: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            if self.failed {
                Err("mock_output_failed")
            } else {
                self.report = report;
                self.history.push(report);
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
    fn rotation_grant(id: u8) -> PacketGrant {
        PacketGrant::new(&[id; 32], [id; 16], [id; 4], 1).unwrap()
    }
    fn live_source(lifetime: u64) -> (PacketRuntime, Sink, PacketSender) {
        let mut runtime = PacketRuntime::default();
        let mut sink = Sink::default();
        owner_activate(&mut runtime, &mut sink, 0);
        runtime.attach(grant(1), 9, lifetime, 1, &mut sink).unwrap();
        let mut sender = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        runtime
            .receive(&sender.seal(&state(false)).unwrap(), 2, &mut sink)
            .unwrap();
        runtime
            .receive(&sender.seal(&state(true)).unwrap(), 3, &mut sink)
            .unwrap();
        sink.history.clear();
        (runtime, sink, sender)
    }
    #[test]
    fn staged_key_rotation_keeps_held_output_and_commits_only_authenticated_packet_zero() {
        let (mut runtime, mut sink, mut old) = live_source(1000);
        let held = sink.report;
        runtime
            .stage_rotation(SESSION, rotation_grant(8), 9, 2000, 4, &mut sink)
            .unwrap();
        assert_eq!(runtime.snapshot().sequence.as_deref(), Some("1"));
        assert!(sink.history.is_empty());
        runtime
            .receive(&old.seal(&state(true)).unwrap(), 5, &mut sink)
            .unwrap();
        let mut next = PacketSender::new(rotation_grant(8), PACKET_LIMIT).unwrap();
        let packet = next.seal(&state(true)).unwrap();
        let mut corrupt = packet.clone();
        corrupt[90] ^= 1;
        assert_eq!(
            runtime.receive(&corrupt, 6, &mut sink),
            Err("input_packet_rejected")
        );
        assert_eq!(runtime.rotation_session(), Some([8; 16]));
        runtime.receive(&packet, 7, &mut sink).unwrap();
        assert_eq!(runtime.snapshot().sequence.as_deref(), Some("0"));
        assert_eq!(sink.report, held);
        assert!(sink.history.iter().all(|r| *r == held));
        let publications = sink.history.len();
        assert_eq!(
            runtime.receive(&old.seal(&state(false)).unwrap(), 8, &mut sink),
            Err("input_packet_rejected")
        );
        assert_eq!(
            runtime.receive(&packet, 9, &mut sink),
            Err("input_packet_rejected")
        );
        assert_eq!(sink.history.len(), publications);
        runtime
            .receive(&next.seal(&state(false)).unwrap(), 10, &mut sink)
            .unwrap();
        assert_eq!(sink.report, NEUTRAL);
    }
    #[test]
    fn stage_rejects_foreign_scope_reused_source_and_overlapping_handoffs_without_output() {
        let (mut runtime, mut sink, _) = live_source(1000);
        for (previous, next, revision, lifetime) in [
            ([6; 16], rotation_grant(8), 9, 1000),
            (SESSION, rotation_grant(8), 10, 1000),
            (SESSION, grant(2), 9, 1000),
            (SESSION, grant(1), 9, 1000),
            (SESSION, rotation_grant(8), 9, 99),
        ] {
            assert!(runtime
                .stage_rotation(previous, next, revision, lifetime, 4, &mut sink)
                .is_err());
            assert!(runtime.rotation_session().is_none());
            assert!(sink.history.is_empty());
        }
        runtime
            .stage_rotation(SESSION, rotation_grant(8), 9, 1000, 4, &mut sink)
            .unwrap();
        assert_eq!(
            runtime.stage_rotation(SESSION, rotation_grant(9), 9, 1000, 5, &mut sink),
            Err("input_rotation_pending")
        );
        assert_eq!(runtime.rotation_session(), Some([8; 16]));
        runtime.cancel_rotation([9; 16]);
        assert_eq!(runtime.rotation_session(), Some([8; 16]));
        runtime.cancel_rotation([8; 16]);
        assert!(runtime.rotation_session().is_none());
        assert!(sink.history.is_empty());
    }
    #[test]
    fn rotation_cannot_bypass_initial_admission_or_start_with_a_skipped_packet() {
        let mut runtime = PacketRuntime::default();
        let mut sink = Sink::default();
        owner_activate(&mut runtime, &mut sink, 0);
        runtime.attach(grant(1), 9, 1000, 1, &mut sink).unwrap();
        assert_eq!(
            runtime.stage_rotation(SESSION, rotation_grant(8), 9, 1000, 2, &mut sink),
            Err("input_rotation_invalid")
        );
        let mut old = PacketSender::new(grant(1), PACKET_LIMIT).unwrap();
        runtime
            .receive(&old.seal(&state(true)).unwrap(), 3, &mut sink)
            .unwrap();
        runtime
            .stage_rotation(SESSION, rotation_grant(8), 9, 1000, 4, &mut sink)
            .unwrap();
        let mut next = PacketSender::new(rotation_grant(8), PACKET_LIMIT).unwrap();
        let _ = next.seal(&state(true)).unwrap();
        assert_eq!(
            runtime.receive(&next.seal(&state(false)).unwrap(), 5, &mut sink),
            Err("input_rotation_requires_first_sample")
        );
        assert!(runtime.rotation_session().is_none());
        assert_eq!(sink.report, state(true).report());
        runtime
            .receive(&old.seal(&state(false)).unwrap(), 6, &mut sink)
            .unwrap();
        assert_eq!(sink.report, NEUTRAL);
    }
    #[test]
    fn preparing_or_committing_rotation_never_renews_the_configuration_owner_or_expired_input() {
        let (mut runtime, mut sink, _) = live_source(2000);
        runtime
            .stage_rotation(SESSION, rotation_grant(8), 9, 5000, 4, &mut sink)
            .unwrap();
        let mut next = PacketSender::new(rotation_grant(8), PACKET_LIMIT).unwrap();
        assert_eq!(
            runtime.receive(&next.seal(&state(true)).unwrap(), 353, &mut sink),
            Err("input_session_closed")
        );
        assert_eq!(runtime.snapshot().last_release_reason, "input_expired");
        assert_eq!(sink.report, NEUTRAL);
        let (mut runtime, mut sink, mut old) = live_source(2000);
        for now in [200, 400, 600] {
            runtime
                .receive(&old.seal(&state(true)).unwrap(), now, &mut sink)
                .unwrap();
        }
        runtime
            .stage_rotation(SESSION, rotation_grant(8), 9, 5000, 604, &mut sink)
            .unwrap();
        let mut next = PacketSender::new(rotation_grant(8), PACKET_LIMIT).unwrap();
        runtime
            .receive(&next.seal(&state(true)).unwrap(), 610, &mut sink)
            .unwrap();
        runtime.tick(750, &mut sink).unwrap();
        assert_eq!(runtime.snapshot().last_release_reason, "lease_expired");
        assert_eq!(sink.report, NEUTRAL);
    }
    #[test]
    fn grant_expiry_release_replacement_and_clock_rollback_discard_pending_keys() {
        for reason in ["grant", "release", "replace", "rollback"] {
            let (mut runtime, mut sink, _) =
                live_source(if reason == "grant" { 100 } else { 1000 });
            runtime
                .stage_rotation(SESSION, rotation_grant(8), 9, 5000, 4, &mut sink)
                .unwrap();
            let now = match reason {
                "grant" => 101,
                "release" => {
                    runtime
                        .release_reason(&mut sink, "explicit_release")
                        .unwrap();
                    5
                }
                "replace" => {
                    runtime
                        .apply_owner(
                            Command::Activate {
                                generation: "2".into(),
                                revision: "10".into(),
                                profile_id: "new-profile".into(),
                                session_id: "next-owner".into(),
                                lease_ms: 750,
                                input_ttl_ms: 350,
                            },
                            5,
                            &mut sink,
                        )
                        .unwrap();
                    6
                }
                _ => {
                    assert_eq!(runtime.tick(2, &mut sink), Err("clock_rollback"));
                    5
                }
            };
            let mut next = PacketSender::new(rotation_grant(8), PACKET_LIMIT).unwrap();
            assert!(runtime
                .receive(&next.seal(&state(true)).unwrap(), now, &mut sink)
                .is_err());
            assert!(runtime.rotation_session().is_none());
            assert_eq!(sink.report, NEUTRAL);
        }
    }
    #[test]
    fn pending_handoff_times_out_without_extending_or_disturbing_the_live_source() {
        let (mut runtime, mut sink, mut old) = live_source(5000);
        runtime
            .stage_rotation(SESSION, rotation_grant(8), 9, 5000, 4, &mut sink)
            .unwrap();
        for now in (100..=2000).step_by(100) {
            owner_renew(&mut runtime, &mut sink, now);
            runtime
                .receive(&old.seal(&state(true)).unwrap(), now, &mut sink)
                .unwrap();
        }
        let mut next = PacketSender::new(rotation_grant(8), PACKET_LIMIT).unwrap();
        assert_eq!(
            runtime.receive(&next.seal(&state(false)).unwrap(), 2004, &mut sink),
            Err("input_packet_rejected")
        );
        assert!(runtime.rotation_session().is_none());
        assert_eq!(sink.report, state(true).report());
        runtime
            .stage_rotation(SESSION, rotation_grant(9), 9, 5000, 2005, &mut sink)
            .unwrap();
    }
    #[test]
    fn repeated_continuity_rotations_keep_constant_staging_and_do_not_consume_reconnect_history() {
        let (mut runtime, mut sink, _) = live_source(5000);
        let mut session = SESSION;
        let mut latest = None;
        for id in 8..88 {
            let now = u64::from(id) * 2;
            runtime
                .stage_rotation(session, rotation_grant(id), 9, 5000, now, &mut sink)
                .unwrap();
            let mut sender = PacketSender::new(rotation_grant(id), PACKET_LIMIT).unwrap();
            runtime
                .receive(&sender.seal(&state(true)).unwrap(), now + 1, &mut sink)
                .unwrap();
            assert_eq!(runtime.used_sessions.len(), 1);
            assert!(runtime.rotation_session().is_none());
            assert_eq!(sink.report, state(true).report());
            session = [id; 16];
            latest = Some(sender);
        }
        let mut latest = latest.unwrap();
        for now in [350, 600, 740] {
            runtime
                .receive(&latest.seal(&state(true)).unwrap(), now, &mut sink)
                .unwrap();
        }
        runtime.tick(750, &mut sink).unwrap();
        assert_eq!(runtime.snapshot().last_release_reason, "lease_expired");
        assert_eq!(sink.report, NEUTRAL);
    }
    #[test]
    fn failed_rotation_publication_retires_current_and_pending_material() {
        let (mut runtime, mut sink, mut old) = live_source(1000);
        runtime
            .stage_rotation(SESSION, rotation_grant(8), 9, 1000, 4, &mut sink)
            .unwrap();
        let mut next = PacketSender::new(rotation_grant(8), PACKET_LIMIT).unwrap();
        sink.failed = true;
        assert_eq!(
            runtime.receive(&next.seal(&state(true)).unwrap(), 5, &mut sink),
            Err("output_failed")
        );
        assert!(!runtime.snapshot().active);
        assert!(runtime.rotation_session().is_none());
        sink.failed = false;
        assert_eq!(
            runtime.receive(&old.seal(&state(true)).unwrap(), 6, &mut sink),
            Err("input_session_closed")
        );
        assert_eq!(
            runtime.receive(&next.seal(&state(true)).unwrap(), 7, &mut sink),
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
