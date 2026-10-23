use super::*;
use crate::{
    gamepad::NEUTRAL,
    runtime::{Command, Runtime},
};
use std::sync::{
    atomic::{AtomicU64, AtomicUsize},
    Condvar,
};
use thumble_rewrite_output_core::{Device, Fault};
#[derive(Default)]
struct TestClock {
    now: AtomicU64,
    fail: AtomicBool,
}
impl ClockDomain for TestClock {
    fn now_ms(&self) -> Result<u64, ClockFault> {
        if self.fail.load(Ordering::SeqCst) {
            Err(ClockFault::Unavailable)
        } else {
            Ok(self.now.load(Ordering::SeqCst))
        }
    }
}
#[derive(Default)]
struct State {
    reports: Mutex<Vec<[u8; 20]>>,
    created: AtomicUsize,
    retired: AtomicUsize,
    fail_report: AtomicBool,
    fail_authorization: AtomicBool,
    submitting: AtomicBool,
    advance_on_held: AtomicU64,
    clock: Mutex<Option<Arc<TestClock>>>,
    gates: Mutex<(bool, bool, bool)>, // creation, held report, retirement
    changed: Condvar,
}
impl State {
    fn wait(&self, index: usize) {
        let mut g = self.gates.lock().unwrap();
        while [g.0, g.1, g.2][index] {
            g = self.changed.wait(g).unwrap();
        }
    }
    fn clear(&self) {
        *self.gates.lock().unwrap() = (false, false, false);
        self.changed.notify_all();
    }
}
struct FakeFactory(Arc<State>);
struct FakeDevice(Arc<State>);
impl Factory for FakeFactory {
    fn authorization(&mut self) -> Result<(), Fault> {
        if self.0.fail_authorization.swap(false, Ordering::SeqCst) {
            Err(Fault::MissingEntitlement)
        } else {
            Ok(())
        }
    }
    fn create(&mut self) -> Result<Box<dyn Device>, Fault> {
        self.0.wait(0);
        self.0.created.fetch_add(1, Ordering::SeqCst);
        Ok(Box::new(FakeDevice(self.0.clone())))
    }
}
impl Device for FakeDevice {
    fn submit(&mut self, report: Report) -> Result<(), Fault> {
        if report != Report::NEUTRAL {
            self.0.submitting.store(true, Ordering::SeqCst);
            self.0.wait(1);
            let advance = self.0.advance_on_held.swap(0, Ordering::SeqCst);
            if advance > 0 {
                self.0
                    .clock
                    .lock()
                    .unwrap()
                    .as_ref()
                    .unwrap()
                    .now
                    .store(advance, Ordering::SeqCst);
            }
            if self.0.fail_report.swap(false, Ordering::SeqCst) {
                return Err(Fault::Report);
            }
        }
        self.0.reports.lock().unwrap().push(report.bytes());
        Ok(())
    }
    fn begin_retirement(&mut self) -> Result<(), Fault> {
        self.0.retired.fetch_add(1, Ordering::SeqCst);
        Ok(())
    }
    fn retirement_confirmed(&mut self) -> Result<bool, Fault> {
        Ok(!self.0.gates.lock().unwrap().2)
    }
}
fn setup() -> (Bridge, Arc<TestClock>, Arc<State>) {
    let clock = Arc::new(TestClock::default());
    let state = Arc::new(State::default());
    *state.clock.lock().unwrap() = Some(clock.clone());
    let bridge = Bridge::new(
        FakeFactory(state.clone()),
        clock.clone(),
        [1; 16],
        "fake-hid",
    )
    .unwrap();
    (bridge, clock, state)
}
fn activate(generation: u64) -> Command {
    Command::Activate {
        generation: generation.to_string(),
        revision: generation.to_string(),
        profile_id: "fixture".into(),
        session_id: "owner".into(),
        lease_ms: 750,
        input_ttl_ms: 350,
    }
}
fn sample(sequence: u64) -> Command {
    Command::Sample{generation:"1".into(),session_id:"owner".into(),sequence:sequence.to_string(),state:serde_json::from_value(serde_json::json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":1,"rightTrigger":0})).unwrap()}
}
fn until(mut condition: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_millis(500);
    while !condition() {
        assert!(Instant::now() < end, "fake worker did not settle");
        std::thread::yield_now();
    }
}
#[test]
fn dormant_start_first_sample_shortens_owner_and_heartbeat_cannot_extend_held_ttl() {
    let (mut bridge, clock, state) = setup();
    let mut runtime = Runtime::default();
    runtime.release(&mut bridge, "startup").unwrap();
    assert_eq!(state.created.load(Ordering::SeqCst), 0);
    assert_eq!(runtime.snapshot().backend, "fake-hid");
    assert!(!runtime.snapshot().input_enabled);
    runtime.apply(activate(1), 0, &mut bridge).unwrap();
    assert!(runtime.snapshot().input_enabled);
    assert_eq!(bridge.status.worker.snapshot().valid_until, Some(750));
    clock.now.store(10, Ordering::SeqCst);
    runtime.apply(sample(0), 10, &mut bridge).unwrap();
    assert_eq!(bridge.status.worker.snapshot().valid_until, Some(360));
    clock.now.store(100, Ordering::SeqCst);
    runtime
        .apply(
            Command::Renew {
                generation: "1".into(),
                session_id: "owner".into(),
            },
            100,
            &mut bridge,
        )
        .unwrap();
    assert_eq!(bridge.status.worker.snapshot().valid_until, Some(360));
    // Sleep-inclusive authoritative jump invalidates the status immediately,
    // without waiting for the output thread's periodic poll.
    clock.now.store(360, Ordering::SeqCst);
    assert!(!runtime.snapshot().input_enabled);
    runtime.tick(360, &mut bridge).unwrap();
    assert!(!runtime.snapshot().active);
    assert_eq!(runtime.snapshot().last_release_reason, "input_expired");
    until(|| state.retired.load(Ordering::SeqCst) == 1);
    assert_eq!(*state.reports.lock().unwrap().last().unwrap(), NEUTRAL);
}
#[test]
fn source_barrier_and_continuity_use_exact_owner_and_new_input_deadlines() {
    let (mut bridge, clock, _) = setup();
    let mut runtime = Runtime::default();
    runtime.apply(activate(1), 0, &mut bridge).unwrap();
    clock.now.store(10, Ordering::SeqCst);
    runtime.apply(sample(0), 10, &mut bridge).unwrap();
    clock.now.store(20, Ordering::SeqCst);
    assert_eq!(
        runtime.switch_packet_source(1, 1, 20, &mut bridge).unwrap(),
        "owner"
    );
    assert_eq!(bridge.status.worker.snapshot().valid_until, Some(750));
    assert_eq!(runtime.snapshot().report_hex, crate::gamepad::hex(&NEUTRAL));
    clock.now.store(30, Ordering::SeqCst);
    runtime.apply(sample(0), 30, &mut bridge).unwrap();
    let Command::Sample { state, .. } = sample(1) else {
        unreachable!()
    };
    clock.now.store(40, Ordering::SeqCst);
    runtime
        .continue_packet_source(1, 1, "owner", state, 40, &mut bridge)
        .unwrap();
    assert_eq!(bridge.status.worker.snapshot().valid_until, Some(390));
}
#[test]
fn definite_report_failure_retires_before_fresh_generation_recovers() {
    let (mut bridge, clock, state) = setup();
    let mut runtime = Runtime::default();
    runtime.apply(activate(1), 0, &mut bridge).unwrap();
    state.fail_report.store(true, Ordering::SeqCst);
    clock.now.store(1, Ordering::SeqCst);
    assert_eq!(
        runtime.apply(sample(0), 1, &mut bridge),
        Err("physical_output_failed")
    );
    assert!(!runtime.snapshot().active);
    assert!(!runtime.snapshot().input_enabled);
    assert!(
        !bridge.status.cleanup_ready(1),
        "faulted retirement cannot auto-rearm"
    );
    assert_eq!(
        runtime.apply(activate(1), 1, &mut bridge),
        Err("stale_activation")
    );
    runtime.apply(activate(2), 1, &mut bridge).unwrap();
    assert!(runtime.snapshot().input_enabled);
    assert_eq!(state.created.load(Ordering::SeqCst), 2);
}
#[test]
fn blocked_creation_times_out_burns_cas_and_late_creation_is_never_admitted() {
    let (mut bridge, _, state) = setup();
    state.gates.lock().unwrap().0 = true;
    let mut runtime = Runtime::default();
    let start = Instant::now();
    assert_eq!(
        runtime.apply(activate(1), 0, &mut bridge),
        Err("physical_output_restart_required")
    );
    assert!(start.elapsed() < Duration::from_millis(250));
    assert!(!runtime.snapshot().active);
    assert_eq!(runtime.snapshot().generation, "1");
    assert_eq!(
        runtime.apply(activate(1), 0, &mut bridge),
        Err("stale_activation")
    );
    assert_eq!(
        runtime.apply(activate(2), 0, &mut bridge),
        Err("physical_output_restart_required")
    );
    state.clear();
    until(|| bridge.status.worker.snapshot().phase == Phase::Stopped);
    assert!(
        !bridge.status.cleanup_ready(1),
        "uncertain cleanup stays ineligible"
    );
    assert!(!runtime.snapshot().input_enabled);
    assert_eq!(state.created.load(Ordering::SeqCst), 1);
    assert!(state.reports.lock().unwrap().iter().all(|r| *r == NEUTRAL));
}
#[test]
fn uncertain_sample_closes_admission_and_shutdown_retires_late_report() {
    let (mut bridge, _, state) = setup();
    let mut runtime = Runtime::default();
    runtime.apply(activate(1), 0, &mut bridge).unwrap();
    state.gates.lock().unwrap().1 = true;
    let start = Instant::now();
    assert_eq!(
        runtime.apply(sample(0), 0, &mut bridge),
        Err("physical_output_restart_required")
    );
    assert!(start.elapsed() < Duration::from_millis(100));
    assert!(!runtime.snapshot().active);
    assert!(!runtime.snapshot().input_enabled);
    state.clear();
    until(|| bridge.status.worker.snapshot().phase == Phase::Stopped);
    assert!(
        !bridge.status.cleanup_ready(1),
        "uncertain cleanup stays ineligible"
    );
    assert_eq!(*state.reports.lock().unwrap().last().unwrap(), NEUTRAL);
    assert_eq!(
        runtime.apply(activate(2), 0, &mut bridge),
        Err("physical_output_restart_required")
    );
}
#[test]
fn replacement_cannot_acknowledge_pending_old_retirement() {
    let (mut bridge, _, state) = setup();
    let mut runtime = Runtime::default();
    runtime.apply(activate(1), 0, &mut bridge).unwrap();
    state.gates.lock().unwrap().2 = true;
    // A wall-clock elapsed assertion includes unrelated runner suspension. Keep
    // a generous hang watchdog, but prove the exact receipt budget separately.
    let (finished, completion) = std::sync::mpsc::sync_channel(1);
    let call = std::thread::spawn(move || {
        let result = runtime.apply(activate(2), 0, &mut bridge);
        finished.send((runtime, bridge, result)).unwrap();
    });
    let (mut runtime, mut bridge, result) = completion
        .recv_timeout(Duration::from_secs(1))
        .expect("fake retirement call did not finish within the hang watchdog");
    call.join().unwrap();
    assert_eq!(result, Err("physical_output_restart_required"));
    {
        let waits = bridge.wait_observations.lock().unwrap();
        assert_eq!(
            waits.len(),
            2,
            "replacement must not issue another activation"
        );
        assert!(matches!(
            waits[0].operation,
            Operation::Activate {
                scope: Scope { generation: 1, .. },
                ..
            }
        ));
        assert_eq!(waits[0].budget, Duration::from_millis(100));
        assert!(matches!(waits[0].result, Ok(Some(_))));
        assert!(matches!(
            waits[1].operation,
            Operation::Release {
                scope: Scope { generation: 1, .. }
            }
        ));
        assert_eq!(waits[1].budget, Duration::from_millis(50));
        assert!(
            matches!(waits[1].result, Ok(None)),
            "pending cancellation must time out, never acknowledge release"
        );
    }
    assert_eq!(runtime.snapshot().generation, "2");
    assert_eq!(runtime.snapshot().revision, "2");
    assert!(!runtime.snapshot().active);
    assert!(!runtime.snapshot().input_enabled);
    assert!(bridge.status.uncertain.load(Ordering::Acquire));
    assert_eq!(state.created.load(Ordering::SeqCst), 1);
    until(|| state.retired.load(Ordering::SeqCst) == 1);
    assert_eq!(state.retired.load(Ordering::SeqCst), 1);
    assert_eq!(*state.reports.lock().unwrap().last().unwrap(), NEUTRAL);
    assert_eq!(
        runtime.apply(activate(2), 0, &mut bridge),
        Err("stale_activation")
    );
    assert_eq!(
        runtime.apply(activate(3), 0, &mut bridge),
        Err("physical_output_restart_required")
    );
    assert_eq!(state.created.load(Ordering::SeqCst), 1);
    assert_eq!(bridge.wait_observations.lock().unwrap().len(), 2);
    state.clear();
    until(|| bridge.status.worker.snapshot().phase == Phase::Stopped);
    assert!(
        !bridge.status.cleanup_ready(3),
        "uncertain cleanup stays ineligible"
    );
}

#[test]
fn status_observed_clock_fault_is_latched_and_only_fresh_retired_generation_recovers() {
    let (mut bridge, clock, _) = setup();
    let mut runtime = Runtime::default();
    clock.now.store(100, Ordering::SeqCst);
    runtime.apply(activate(1), 100, &mut bridge).unwrap();
    clock.fail.store(true, Ordering::SeqCst);
    assert!(!runtime.snapshot().input_enabled);
    clock.fail.store(false, Ordering::SeqCst);
    assert!(!runtime.snapshot().input_enabled);
    assert_eq!(
        runtime.tick(100, &mut bridge),
        Err("physical_output_failed")
    );
    runtime.apply(activate(2), 100, &mut bridge).unwrap();
    assert!(runtime.snapshot().input_enabled);
    clock.now.store(99, Ordering::SeqCst);
    assert!(!runtime.snapshot().input_enabled);
    let _ = runtime.tick(100, &mut bridge);
    assert!(!runtime.snapshot().active);
    assert_eq!(
        runtime.apply(activate(3), 100, &mut bridge),
        Err("physical_output_clock_failed")
    );
    clock.now.store(100, Ordering::SeqCst);
    runtime.apply(activate(4), 100, &mut bridge).unwrap();
    assert!(runtime.snapshot().input_enabled);
    runtime
        .apply(Command::Shutdown {}, 100, &mut bridge)
        .unwrap();
    assert!(!runtime.snapshot().input_enabled);
}

#[test]
fn full_worker_queue_latches_restart_and_queued_reports_cannot_restore_admission() {
    let (mut bridge, _, state) = setup();
    bridge.begin(1, 750).unwrap();
    state.gates.lock().unwrap().1 = true;
    let mut held = NEUTRAL;
    held[3] = 0x10;
    let scope = bridge.scope.unwrap();
    let _inflight = bridge
        .status
        .worker
        .request(Operation::SubmitUntil {
            scope,
            report: Report::try_from(held).unwrap(),
            valid_until: 350,
        })
        .unwrap();
    until(|| state.submitting.load(Ordering::SeqCst));
    let mut queued = Vec::new();
    for _ in 0..8 {
        queued.push(
            bridge
                .status
                .worker
                .request(Operation::SetDeadline {
                    scope,
                    valid_until: 350,
                })
                .unwrap(),
        );
    }
    assert_eq!(
        bridge.set_deadline(350),
        Err("physical_output_restart_required")
    );
    assert!(!bridge.status.enabled(1));
    state.clear();
    until(|| bridge.status.worker.snapshot().phase == Phase::Stopped);
    assert!(
        !bridge.status.cleanup_ready(1),
        "uncertain cleanup stays ineligible"
    );
    assert_eq!(*state.reports.lock().unwrap().last().unwrap(), NEUTRAL);
    assert_eq!(
        bridge.begin(2, 750),
        Err("physical_output_restart_required")
    );
}

#[test]
fn input_deadline_crossed_inside_native_io_never_acknowledges_active_held_state() {
    let (mut bridge, _, state) = setup();
    let mut runtime = Runtime::default();
    runtime.apply(activate(1), 0, &mut bridge).unwrap();
    state.advance_on_held.store(350, Ordering::SeqCst);
    assert_eq!(
        runtime.apply(sample(0), 0, &mut bridge),
        Err("physical_output_failed")
    );
    assert!(!runtime.snapshot().active);
    assert!(!runtime.snapshot().input_enabled);
    assert_eq!(runtime.snapshot().report_hex, crate::gamepad::hex(&NEUTRAL));
    assert_eq!(*state.reports.lock().unwrap().last().unwrap(), NEUTRAL);
}

#[test]
fn failed_saved_activation_consumes_cas_and_retires_old_pin_before_recovery() {
    let (mut bridge, _, state) = setup();
    let mut runtime = crate::packet_runtime::PacketRuntime::default();
    let saved = |generation: u64| Command::ActivateSaved {
        generation: generation.to_string(),
        revision: generation.to_string(),
        profile_id: "11111111-1111-4111-8111-111111111111".into(),
        session_id: "owner".into(),
        lease_ms: 750,
        input_ttl_ms: 350,
        configuration_revision: "1".into(),
        source_hash: "a".repeat(64),
    };
    runtime.apply_owner(saved(1), 0, &mut bridge).unwrap();
    assert!(runtime.saved_binding().is_some());
    state.fail_authorization.store(true, Ordering::SeqCst);
    assert_eq!(
        runtime.apply_owner(saved(2), 0, &mut bridge),
        Err("physical_output_failed")
    );
    assert!(runtime.saved_binding().is_none());
    assert!(!runtime.snapshot().active);
    assert_eq!(runtime.snapshot().generation, "2");
    assert_eq!(runtime.snapshot().revision, "2");
    assert_eq!(
        runtime.apply_owner(saved(2), 0, &mut bridge),
        Err("stale_activation")
    );
    runtime.apply_owner(saved(3), 0, &mut bridge).unwrap();
    assert!(runtime.saved_binding().is_some());
    assert!(runtime.snapshot().input_enabled);
    assert_eq!(state.created.load(Ordering::SeqCst), 2);
}

#[test]
fn local_rearm_requires_confirmed_inactive_exact_generation_and_healthy_clock() {
    let (mut bridge, clock, _) = setup();
    assert!(bridge.status.cleanup_ready(0));
    bridge.begin(1, 750).unwrap();
    assert!(!bridge.status.cleanup_ready(1));
    bridge.retire("native_input_released").unwrap();
    assert!(bridge.status.cleanup_ready(1));
    assert!(!bridge.status.cleanup_ready(0));
    clock.fail.store(true, Ordering::SeqCst);
    assert!(!bridge.status.cleanup_ready(1));
    clock.fail.store(false, Ordering::SeqCst);
    assert!(
        !bridge.status.cleanup_ready(1),
        "clock fault remains latched"
    );
}
