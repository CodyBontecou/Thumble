use super::*;
use crate::{gamepad::NEUTRAL, generated::GamepadState, input_packet::PacketSender};
use serde_json::{json, Value};
const PROFILE: &str = "11111111-1111-1111-1111-111111111111";
#[derive(Default)]
struct Sink {
    fail: bool,
    reports: Vec<[u8; 20]>,
}
impl Output for Sink {
    fn submit(&mut self, report: [u8; 20], _: &'static str) -> Result<(), &'static str> {
        self.reports.push(report);
        if self.fail {
            Err("test_output_failed")
        } else {
            Ok(())
        }
    }
}
fn activation(generation: u64) -> Value {
    json!({"command":"activateSaved","generation":generation.to_string(),"revision":generation.to_string(),"profileId":PROFILE,"sessionId":"owner","leaseMs":750,"inputTtlMs":350,"configurationRevision":"7","sourceHash":"a".repeat(64)})
}
fn command(value: Value) -> Command {
    serde_json::from_value(value).unwrap()
}
fn activate(runtime: &mut PacketRuntime, output: &mut Sink, generation: u64, now: u64) {
    runtime
        .apply_owner(command(activation(generation)), now, output)
        .unwrap();
}
fn held() -> GamepadState {
    serde_json::from_value(json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":1,"rightTrigger":0})).unwrap()
}
#[test]
fn source_pin_is_exact_read_only_and_does_not_extend_owner_lease() {
    let mut runtime = PacketRuntime::default();
    let mut output = Sink::default();
    assert!(runtime.saved_binding().is_none());
    activate(&mut runtime, &mut output, 1, 0);
    let saved = runtime.saved_binding().unwrap().clone();
    assert_eq!(
        saved,
        SavedBinding {
            configuration_revision: "7".into(),
            source_hash: "a".repeat(64),
            profile_id: PROFILE.into(),
            generation: "1".into(),
            revision: "1".into()
        }
    );
    runtime
        .apply_owner(Command::SavedBindingStatus {}, 749, &mut output)
        .unwrap();
    assert_eq!(runtime.saved_binding(), Some(&saved));
    let snapshot = serde_json::to_value(runtime.snapshot()).unwrap();
    assert_eq!(snapshot["backend"], "recording");
    assert_eq!(snapshot["inputEnabled"], false);
    assert!(snapshot.get("savedBinding").is_none());
    assert_eq!(output.reports, vec![NEUTRAL]);
    runtime.tick(750, &mut output).unwrap();
    assert!(runtime.saved_binding().is_none());
    assert!(!runtime.snapshot().active);
    assert_eq!(runtime.snapshot().last_release_reason, "lease_expired");
}
#[test]
fn invalid_or_stale_saved_activation_preserves_current_pin_and_held_report() {
    let mut runtime = PacketRuntime::default();
    let mut output = Sink::default();
    activate(&mut runtime, &mut output, 1, 0);
    runtime
        .apply_owner(
            Command::Sample {
                generation: "1".into(),
                session_id: "owner".into(),
                sequence: "0".into(),
                state: held(),
            },
            1,
            &mut output,
        )
        .unwrap();
    let saved = runtime.saved_binding().cloned();
    let report = runtime.snapshot().report_hex;
    let count = output.reports.len();
    for (key, value) in [
        ("configurationRevision", json!("0")),
        ("configurationRevision", json!("01")),
        ("configurationRevision", json!("18446744073709551616")),
        ("sourceHash", json!("A".repeat(64))),
        ("sourceHash", json!("g".repeat(64))),
        ("sourceHash", json!("a".repeat(63))),
        ("profileId", json!("ABCDEF01-1111-1111-1111-111111111111")),
        ("profileId", json!("fixture")),
    ] {
        let mut request = activation(2);
        request[key] = value;
        assert_eq!(
            runtime.apply_owner(command(request), 2, &mut output),
            Err("invalid_saved_activation")
        );
        assert_eq!(runtime.saved_binding().cloned(), saved);
        assert_eq!(runtime.snapshot().report_hex, report);
    }
    assert_eq!(
        runtime.apply_owner(command(activation(1)), 3, &mut output),
        Err("stale_activation")
    );
    let mut stale_revision = activation(2);
    stale_revision["revision"] = json!("1");
    assert_eq!(
        runtime.apply_owner(command(stale_revision), 4, &mut output),
        Err("stale_activation")
    );
    assert_eq!(runtime.saved_binding().cloned(), saved);
    assert_eq!(output.reports.len(), count);
}
#[test]
fn replacement_and_all_configuration_retirement_paths_clear_without_resurrection() {
    let mut runtime = PacketRuntime::default();
    let mut output = Sink::default();
    activate(&mut runtime, &mut output, 1, 0);
    let mut next = activation(2);
    next["configurationRevision"] = json!("8");
    next["sourceHash"] = json!("b".repeat(64));
    runtime.apply_owner(command(next), 1, &mut output).unwrap();
    assert_eq!(runtime.saved_binding().unwrap().configuration_revision, "8");
    assert_eq!(runtime.snapshot().report_hex, crate::gamepad::hex(&NEUTRAL));
    let mut ordinary = activation(3);
    ordinary["command"] = json!("activate");
    ordinary
        .as_object_mut()
        .unwrap()
        .remove("configurationRevision");
    ordinary.as_object_mut().unwrap().remove("sourceHash");
    runtime
        .apply_owner(command(ordinary), 2, &mut output)
        .unwrap();
    assert!(runtime.saved_binding().is_none());
    for retirement in [Command::Release {}, Command::Shutdown {}] {
        let mut runtime = PacketRuntime::default();
        activate(&mut runtime, &mut output, 1, 0);
        runtime.apply_owner(retirement, 1, &mut output).unwrap();
        assert!(runtime.saved_binding().is_none());
        assert!(!runtime.snapshot().active);
    }
    let mut runtime = PacketRuntime::default();
    activate(&mut runtime, &mut output, 1, 0);
    runtime
        .release_reason(&mut output, "owner_disconnected")
        .unwrap();
    assert!(runtime.saved_binding().is_none());
    assert!(PacketRuntime::default().saved_binding().is_none());
}
#[test]
fn phone_attachment_samples_and_renewal_preserve_pin_until_configuration_ends() {
    let mut runtime = PacketRuntime::default();
    let mut output = Sink::default();
    activate(&mut runtime, &mut output, 1, 0);
    let saved = runtime.saved_binding().cloned();
    let grant = PacketGrant::new(&[5; 32], [7; 16], [9; 4], 1).unwrap();
    let mut sender = PacketSender::new(
        PacketGrant::new(&[5; 32], [7; 16], [9; 4], 1).unwrap(),
        crate::input_packet::PACKET_LIMIT,
    )
    .unwrap();
    runtime.attach(grant, 1, 1000, 1, &mut output).unwrap();
    assert_eq!(runtime.saved_binding().cloned(), saved);
    runtime
        .receive(&sender.seal(&held()).unwrap(), 2, &mut output)
        .unwrap();
    assert_eq!(runtime.saved_binding().cloned(), saved);
    runtime
        .apply_owner(
            Command::Renew {
                generation: "1".into(),
                session_id: "owner".into(),
            },
            300,
            &mut output,
        )
        .unwrap();
    assert_eq!(runtime.saved_binding().cloned(), saved);
    // Existing core semantics retire configuration itself at input expiry. Do not
    // silently change that behavior merely to retain source metadata.
    runtime.tick(352, &mut output).unwrap();
    assert_eq!(runtime.snapshot().last_release_reason, "input_expired");
    assert!(runtime.saved_binding().is_none());
    assert!(!runtime.snapshot().active);
    assert_eq!(
        runtime.receive(&sender.seal(&held()).unwrap(), 353, &mut output),
        Err("input_session_closed")
    );
    assert!(runtime.saved_binding().is_none());
}
#[test]
fn failed_neutral_barrier_cannot_acknowledge_a_new_source_pin() {
    let mut runtime = PacketRuntime::default();
    let mut output = Sink::default();
    activate(&mut runtime, &mut output, 1, 0);
    output.fail = true;
    assert_eq!(
        runtime.apply_owner(command(activation(2)), 1, &mut output),
        Err("test_output_failed")
    );
    assert!(runtime.saved_binding().is_none());
    assert!(!runtime.snapshot().active);
}
#[test]
fn strict_private_commands_are_not_accepted_by_bare_runtime() {
    let mut runtime = Runtime::default();
    let mut output = Sink::default();
    assert_eq!(
        runtime.apply(command(activation(1)), 0, &mut output),
        Err("saved_binding_owner_required")
    );
    assert_eq!(
        runtime.apply(Command::SavedBindingStatus {}, 0, &mut output),
        Err("saved_binding_owner_required")
    );
    for value in [json!({"command":"savedBindingStatus","extra":true}), {
        let mut value = activation(1);
        value["token"] = json!("forbidden");
        value
    }] {
        assert!(serde_json::from_value::<Command>(value).is_err());
    }
}

#[test]
fn clean_release_retains_exact_local_rearm_proof_but_other_retirements_clear_it() {
    let mut runtime = PacketRuntime::default();
    let mut output = Sink::default();
    activate(&mut runtime, &mut output, 1, 0);
    runtime
        .release_reason(&mut output, "native_input_released")
        .unwrap();
    let (released, ready) = runtime.rearm_status();
    assert_eq!(released.unwrap().generation, "1");
    assert_eq!(released.unwrap().configuration_revision, "7");
    assert!(!ready, "recording sink cannot prove physical retirement");
    runtime
        .apply_owner(Command::SavedRearmStatus {}, 1, &mut output)
        .unwrap();
    assert!(runtime.rearm_status().0.is_some());
    runtime
        .apply_owner(Command::Release {}, 2, &mut output)
        .unwrap();
    assert!(runtime.rearm_status().0.is_none());
    activate(&mut runtime, &mut output, 2, 3);
    assert!(runtime.rearm_status().0.is_none());
    runtime
        .release_reason(&mut output, "lease_expired")
        .unwrap();
    assert!(runtime.rearm_status().0.is_none());
}

#[test]
fn first_termination_survives_cleanup_and_resets_only_after_successful_activation() {
    let mut runtime = PacketRuntime::default();
    let mut output = Sink::default();
    assert!(runtime.first_termination().is_none());
    activate(&mut runtime, &mut output, 1, 0);
    runtime
        .apply_owner(
            Command::Sample {
                generation: "1".into(),
                session_id: "owner".into(),
                sequence: "0".into(),
                state: held(),
            },
            1,
            &mut output,
        )
        .unwrap();
    runtime.tick(351, &mut output).unwrap();
    let first = runtime.first_termination().unwrap();
    assert_eq!(
        (
            first.reason,
            first.generation.as_str(),
            first.revision.as_str()
        ),
        ("input_expired", "1", "1")
    );
    runtime
        .release_reason(&mut output, "native_input_released")
        .unwrap();
    assert_eq!(
        runtime.snapshot().last_release_reason,
        "native_input_released"
    );
    assert_eq!(runtime.first_termination().unwrap().reason, "input_expired");
    activate(&mut runtime, &mut output, 2, 352);
    assert!(runtime.first_termination().is_none());
    runtime
        .release_reason(&mut output, "native_input_released")
        .unwrap();
    let first = runtime.first_termination().unwrap();
    assert_eq!(
        (first.reason, first.generation.as_str()),
        ("native_input_released", "2")
    );
    runtime
        .release_reason(&mut output, "owner_disconnected")
        .unwrap();
    assert_eq!(
        runtime.first_termination().unwrap().reason,
        "native_input_released"
    );
}

#[test]
fn first_termination_records_output_failure_and_never_exports_unknown_reason_text() {
    let mut runtime = PacketRuntime::default();
    let mut output = Sink::default();
    activate(&mut runtime, &mut output, 1, 0);
    output.fail = true;
    assert!(runtime
        .apply_owner(
            Command::Sample {
                generation: "1".into(),
                session_id: "owner".into(),
                sequence: "0".into(),
                state: held(),
            },
            1,
            &mut output
        )
        .is_err());
    assert_eq!(runtime.first_termination().unwrap().reason, "output_failed");
    output.fail = false;
    runtime
        .release_reason(&mut output, "native_input_released")
        .unwrap();
    assert_eq!(runtime.first_termination().unwrap().reason, "output_failed");
    activate(&mut runtime, &mut output, 2, 2);
    runtime
        .release_reason(&mut output, "unrecognized_private_test_reason")
        .unwrap();
    assert_eq!(
        runtime.first_termination().unwrap().reason,
        "other_terminal"
    );
}
