use crate::{
    gamepad::{hex, NEUTRAL},
    generated::GamepadState,
};
use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub version: u8,
    pub request_id: String,
    pub body: Command,
}
#[derive(Debug, Deserialize)]
#[serde(
    tag = "command",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Command {
    Status {},
    Activate {
        generation: String,
        revision: String,
        profile_id: String,
        session_id: String,
        lease_ms: u64,
        input_ttl_ms: u64,
    },
    Renew {
        generation: String,
        session_id: String,
    },
    Sample {
        generation: String,
        session_id: String,
        sequence: String,
        state: GamepadState,
    },
    Release {},
    Shutdown {},
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub backend: &'static str,
    pub input_enabled: bool,
    pub active: bool,
    pub generation: String,
    pub revision: String,
    pub profile_id: Option<String>,
    pub sequence: Option<String>,
    pub report_hex: String,
    pub last_release_reason: &'static str,
}
struct Active {
    generation: u64,
    session_id: String,
    lease_ms: u64,
    input_ttl_ms: u64,
    owner_deadline: u64,
    input_deadline: Option<u64>,
    sequence: Option<u64>,
}
pub struct Runtime {
    active: Option<Active>,
    generation: u64,
    revision: u64,
    profile_id: Option<String>,
    report: [u8; 20],
    reason: &'static str,
}
pub trait Output {
    fn submit(&mut self, report: [u8; 20], reason: &'static str) -> Result<(), &'static str>;
}

pub fn decimal(value: &str) -> Result<u64, &'static str> {
    if value.is_empty()
        || value.len() > 20
        || (value.len() > 1 && value.starts_with('0'))
        || !value.bytes().all(|b| b.is_ascii_digit())
    {
        return Err("invalid_counter");
    }
    value.parse().map_err(|_| "invalid_counter")
}
pub fn identity(value: &str) -> bool {
    (1..=64).contains(&value.len())
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
impl Default for Runtime {
    fn default() -> Self {
        Self {
            active: None,
            generation: 0,
            revision: 0,
            profile_id: None,
            report: NEUTRAL,
            reason: "startup",
        }
    }
}
impl Runtime {
    pub fn is_active(&self) -> bool {
        self.active.is_some()
    }
    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            backend: "recording",
            input_enabled: false,
            active: self.active.is_some(),
            generation: self.generation.to_string(),
            revision: self.revision.to_string(),
            profile_id: self.profile_id.clone(),
            sequence: self
                .active
                .as_ref()
                .and_then(|a| a.sequence)
                .map(|n| n.to_string()),
            report_hex: hex(&self.report),
            last_release_reason: self.reason,
        }
    }
    pub fn release(
        &mut self,
        output: &mut impl Output,
        reason: &'static str,
    ) -> Result<(), &'static str> {
        // Retire session before touching output. Failures cannot restore input.
        self.active = None;
        self.report = NEUTRAL;
        self.reason = reason;
        output.submit(NEUTRAL, reason)
    }
    pub fn tick(&mut self, now: u64, output: &mut impl Output) -> Result<(), &'static str> {
        if let Some(active) = &self.active {
            if now >= active.owner_deadline {
                self.release(output, "lease_expired")?;
            } else if active
                .input_deadline
                .is_some_and(|deadline| now >= deadline)
            {
                self.release(output, "input_expired")?;
            }
        }
        Ok(())
    }
    fn matching(&mut self, generation: &str, session: &str) -> Result<&mut Active, &'static str> {
        let generation = decimal(generation)?;
        self.active
            .as_mut()
            .filter(|a| a.generation == generation && a.session_id == session)
            .ok_or("inactive_generation")
    }
    /// Attach a native packet source to this acknowledged configuration without changing its owner lease.
    pub(crate) fn switch_packet_source(
        &mut self,
        generation: u64,
        revision: u64,
        now: u64,
        output: &mut impl Output,
    ) -> Result<String, &'static str> {
        self.tick(now, output)?;
        let owner = self
            .active
            .as_ref()
            .filter(|a| a.generation == generation && self.revision == revision)
            .ok_or("inactive_generation")?
            .session_id
            .clone();
        self.report = NEUTRAL;
        self.reason = "packet_source_barrier";
        if let Err(error) = output.submit(NEUTRAL, self.reason) {
            let _ = self.release(output, "output_failed");
            return Err(error);
        }
        if let Some(active) = self.active.as_mut() {
            active.sequence = None;
            active.input_deadline = None;
        }
        Ok(owner)
    }
    pub fn apply(
        &mut self,
        command: Command,
        now: u64,
        output: &mut impl Output,
    ) -> Result<bool, &'static str> {
        self.tick(now, output)?;
        match command {
            Command::Status {} => (),
            Command::Activate {
                generation,
                revision,
                profile_id,
                session_id,
                lease_ms,
                input_ttl_ms,
            } => {
                let generation = decimal(&generation)?;
                let revision = decimal(&revision)?;
                if generation <= self.generation || revision <= self.revision {
                    return Err("stale_activation");
                }
                if !identity(&profile_id)
                    || !identity(&session_id)
                    || !(100..=1750).contains(&lease_ms)
                    || !(50..=lease_ms).contains(&input_ttl_ms)
                {
                    return Err("invalid_activation");
                }
                self.release(output, "activation_barrier")?;
                self.generation = generation;
                self.revision = revision;
                self.profile_id = Some(profile_id);
                self.active = Some(Active {
                    generation,
                    session_id,
                    lease_ms,
                    input_ttl_ms,
                    owner_deadline: now.saturating_add(lease_ms),
                    input_deadline: None,
                    sequence: None,
                });
            }
            Command::Renew {
                generation,
                session_id,
            } => {
                let a = self.matching(&generation, &session_id)?;
                a.owner_deadline = now.saturating_add(a.lease_ms);
            }
            Command::Sample {
                generation,
                session_id,
                sequence,
                state,
            } => {
                if !state.validate() {
                    return Err("invalid_state");
                }
                let sequence = decimal(&sequence)?;
                let a = self.matching(&generation, &session_id)?;
                if a.sequence.is_some_and(|last| sequence <= last) {
                    return Err("replayed_sample");
                }
                let report = state.report();
                // If output fails, latch neutral/inactive; do not acknowledge partial input.
                if output.submit(report, "sample").is_err() {
                    let _ = self.release(output, "output_failed");
                    return Err("output_failed");
                }
                let a = self.active.as_mut().ok_or("inactive_generation")?;
                a.sequence = Some(sequence);
                a.input_deadline = Some(now.saturating_add(a.input_ttl_ms));
                self.report = report;
            }
            Command::Release {} => self.release(output, "explicit_release")?,
            Command::Shutdown {} => {
                self.release(output, "shutdown")?;
                return Ok(false);
            }
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Default)]
    struct Sink(Vec<[u8; 20]>);
    impl Output for Sink {
        fn submit(&mut self, report: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            self.0.push(report);
            Ok(())
        }
    }
    fn activate(generation: u64) -> Command {
        Command::Activate {
            generation: generation.to_string(),
            revision: generation.to_string(),
            profile_id: "fixture".into(),
            session_id: format!("session-{generation}"),
            lease_ms: 500,
            input_ttl_ms: 200,
        }
    }
    fn sample(generation: u64, sequence: u64) -> Command {
        Command::Sample { generation:generation.to_string(),session_id:format!("session-{generation}"),sequence:sequence.to_string(),state:serde_json::from_value(serde_json::json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":1,"rightTrigger":1})).unwrap() }
    }
    #[test]
    fn barriers_replay_and_release_retire_old_packets() {
        let mut r = Runtime::default();
        let mut o = Sink::default();
        r.apply(activate(1), 0, &mut o).unwrap();
        r.apply(sample(1, 0), 1, &mut o).unwrap();
        assert_ne!(r.report, NEUTRAL);
        assert_eq!(r.apply(sample(1, 0), 2, &mut o), Err("replayed_sample"));
        r.apply(activate(2), 3, &mut o).unwrap();
        assert_eq!(r.report, NEUTRAL);
        assert_eq!(r.apply(sample(1, 1), 4, &mut o), Err("inactive_generation"));
        r.apply(sample(2, 0), 5, &mut o).unwrap();
        r.apply(Command::Release {}, 6, &mut o).unwrap();
        assert_eq!(r.apply(sample(2, 1), 7, &mut o), Err("inactive_generation"));
    }
    #[test]
    fn renewal_does_not_keep_stale_physical_state_alive() {
        let mut r = Runtime::default();
        let mut o = Sink::default();
        r.apply(activate(1), 0, &mut o).unwrap();
        r.apply(sample(1, 0), 1, &mut o).unwrap();
        r.apply(
            Command::Renew {
                generation: "1".into(),
                session_id: "session-1".into(),
            },
            150,
            &mut o,
        )
        .unwrap();
        r.tick(201, &mut o).unwrap();
        assert_eq!(r.reason, "input_expired");
        assert_eq!(r.report, NEUTRAL);
        assert_eq!(
            r.apply(sample(1, 1), 202, &mut o),
            Err("inactive_generation")
        );
    }
    #[test]
    fn owner_lease_expires_even_without_samples() {
        let mut r = Runtime::default();
        let mut o = Sink::default();
        r.apply(activate(1), 0, &mut o).unwrap();
        r.tick(500, &mut o).unwrap();
        assert!(!r.snapshot().active);
        assert_eq!(r.reason, "lease_expired");
    }
    #[test]
    fn failed_output_retires_session_and_latches_neutral() {
        struct Failing;
        impl Output for Failing {
            fn submit(&mut self, report: [u8; 20], _: &'static str) -> Result<(), &'static str> {
                if report == NEUTRAL {
                    Ok(())
                } else {
                    Err("device_lost")
                }
            }
        }
        let mut r = Runtime::default();
        let mut output = Failing;
        r.apply(activate(1), 0, &mut output).unwrap();
        assert_eq!(r.apply(sample(1, 0), 1, &mut output), Err("output_failed"));
        assert!(!r.snapshot().active);
        assert_eq!(r.report, NEUTRAL);
        assert_eq!(r.reason, "output_failed");
        assert_eq!(
            r.apply(sample(1, 1), 2, &mut output),
            Err("inactive_generation")
        );
    }
    #[test]
    fn malformed_requests_and_precise_counter_bounds() {
        assert!(serde_json::from_str::<Request>(
            r#"{"version":1,"requestId":"x","body":{"command":"status","unexpected":true}}"#
        )
        .is_err());
        assert!(serde_json::from_str::<Request>(
            r#"{"version":1,"version":1,"requestId":"x","body":{"command":"status"}}"#
        )
        .is_err());
        assert_eq!(decimal("18446744073709551615"), Ok(u64::MAX));
        for value in ["18446744073709551616", "01", "-1", "1e2", ""] {
            assert!(decimal(value).is_err());
        }
    }
}
