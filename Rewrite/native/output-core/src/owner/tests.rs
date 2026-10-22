use super::*;
use std::{
    cell::Cell,
    rc::Rc,
    sync::{atomic::AtomicUsize, Condvar},
};
struct State {
    events: Mutex<Vec<(&'static str, Option<Report>)>>,
    changed: Condvar,
    canceled: AtomicBool,
    fail: AtomicBool,
    fail_neutral: AtomicBool,
    cancel_error: AtomicBool,
    held: Mutex<bool>,
    release: Condvar,
    devices: AtomicUsize,
    authorization: AtomicBool,
}
impl State {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            events: Mutex::new(vec![]),
            changed: Condvar::new(),
            canceled: AtomicBool::new(true),
            fail: AtomicBool::new(false),
            fail_neutral: AtomicBool::new(false),
            cancel_error: AtomicBool::new(false),
            held: Mutex::new(false),
            release: Condvar::new(),
            devices: AtomicUsize::new(0),
            authorization: AtomicBool::new(true),
        })
    }
    fn event(&self, event: &'static str, report: Option<Report>) {
        self.events.lock().unwrap().push((event, report));
        self.changed.notify_all();
    }
    fn await_event(&self, event: &str) {
        let events = self.events.lock().unwrap();
        let (events, timeout) = self
            .changed
            .wait_timeout_while(events, Duration::from_secs(2), |v| {
                !v.iter().any(|(e, _)| *e == event)
            })
            .unwrap();
        assert!(!timeout.timed_out(), "missing {event}; {events:?}");
    }
    fn unblock(&self) {
        *self.held.lock().unwrap() = false;
        self.release.notify_all();
    }
}
struct FakeFactory(Arc<State>);
impl Factory for FakeFactory {
    fn authorization(&mut self) -> Result<(), Fault> {
        self.0.event("authorize", None);
        if self.0.authorization.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(Fault::MissingEntitlement)
        }
    }
    fn create(&mut self) -> Result<Box<dyn Device>, Fault> {
        assert_eq!(self.0.devices.fetch_add(1, Ordering::AcqRel), 0);
        self.0.event("create", None);
        Ok(Box::new(FakeDevice {
            state: self.0.clone(),
            thread: thread::current().id(),
            confirmed: Cell::new(false),
            _not_send: Rc::new(()),
        }))
    }
}
struct FakeDevice {
    state: Arc<State>,
    thread: thread::ThreadId,
    confirmed: Cell<bool>,
    _not_send: Rc<()>,
}
impl Device for FakeDevice {
    fn submit(&mut self, report: Report) -> Result<(), Fault> {
        assert_eq!(thread::current().id(), self.thread);
        self.state.event("report", Some(report));
        if report == Report::NEUTRAL && self.state.fail_neutral.load(Ordering::Acquire) {
            return Err(Fault::Report);
        }
        if report != Report::NEUTRAL {
            self.state.event("nonneutral", None);
            let guard = self.state.held.lock().unwrap();
            drop(self.state.release.wait_while(guard, |held| *held).unwrap());
            if self.state.fail.load(Ordering::Acquire) {
                return Err(Fault::Report);
            }
        }
        Ok(())
    }
    fn begin_retirement(&mut self) -> Result<(), Fault> {
        assert_eq!(thread::current().id(), self.thread);
        self.state.event("cancel", None);
        Ok(())
    }
    fn retirement_confirmed(&mut self) -> Result<bool, Fault> {
        if self.state.cancel_error.load(Ordering::Acquire) {
            self.state.event("cancel-error", None);
            return Err(Fault::Cancellation);
        }
        let done = self.state.canceled.load(Ordering::Acquire);
        if done {
            self.confirmed.set(true);
        }
        Ok(done)
    }
}
impl Drop for FakeDevice {
    fn drop(&mut self) {
        assert_eq!(thread::current().id(), self.thread);
        assert!(self.confirmed.get());
        self.state.event("drop", None);
        self.state.devices.fetch_sub(1, Ordering::AcqRel);
    }
}
fn scope(generation: u64) -> Scope {
    Scope {
        owner: [1; 16],
        generation,
    }
}
fn report() -> Report {
    let mut b = Report::NEUTRAL.bytes();
    b[3] = 0x10;
    Report::try_from(b).unwrap()
}
fn owner() -> (OutputOwner, Arc<State>, Arc<Mutex<u64>>) {
    let state = State::new();
    let time = Arc::new(Mutex::new(1000u64));
    let clock = time.clone();
    (
        OutputOwner::spawn(
            FakeFactory(state.clone()),
            Arc::new(move || Ok(*clock.lock().unwrap())),
        )
        .unwrap(),
        state,
        time,
    )
}
fn done(mut pending: Pending) -> Result<Receipt, Error> {
    pending.wait(Duration::from_secs(1))?.ok_or(Error::NotReady)
}
fn now(time: &Mutex<u64>) -> u64 {
    *time.lock().unwrap()
}
fn start(owner: &OutputOwner, time: &Mutex<u64>, generation: u64) {
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(generation),
                    valid_until: now(time) + 60_000
                })
                .unwrap()
        )
        .unwrap()
        .phase,
        Phase::Ready
    );
}
fn stop(owner: &OutputOwner) {
    assert_eq!(
        done(owner.request(Operation::Shutdown).unwrap())
            .unwrap()
            .phase,
        Phase::Stopped
    );
}
#[test]
fn spawn_is_dormant_and_ready_requires_initial_neutral_with_thread_confined_device() {
    let (owner, state, time) = owner();
    assert_eq!(owner.snapshot().phase, Phase::Inactive);
    assert!(state.events.lock().unwrap().is_empty());
    start(&owner, &time, 1);
    assert_eq!(
        &*state.events.lock().unwrap(),
        &[
            ("authorize", None),
            ("create", None),
            ("report", Some(Report::NEUTRAL))
        ]
    );
    done(
        owner
            .request(Operation::Submit {
                scope: scope(1),
                report: report(),
            })
            .unwrap(),
    )
    .unwrap();
    stop(&owner);
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
}
#[test]
fn owner_generation_barriers_and_confirmed_replacement_do_not_overlap_devices() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    let other = Scope {
        owner: [2; 16],
        generation: 1,
    };
    assert_eq!(
        done(
            owner
                .request(Operation::Submit {
                    scope: other,
                    report: report()
                })
                .unwrap()
        ),
        Err(Error::WrongScope)
    );
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: other,
                    valid_until: now(&time) + 1000
                })
                .unwrap()
        ),
        Err(Error::StaleGeneration)
    );
    start(&owner, &time, 2);
    assert_eq!(
        done(
            owner
                .request(Operation::Submit {
                    scope: scope(1),
                    report: report()
                })
                .unwrap()
        ),
        Err(Error::WrongScope)
    );
    let events = state.events.lock().unwrap();
    let dropped = events.iter().position(|(e, _)| *e == "drop").unwrap();
    let creates = events
        .iter()
        .enumerate()
        .filter(|(_, (e, _))| *e == "create")
        .map(|(i, _)| i)
        .collect::<Vec<_>>();
    assert!(dropped < creates[1]);
    drop(events);
    stop(&owner);
}
#[test]
fn failed_report_latches_until_explicit_fresh_activation_and_neutral_retirement() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    state.fail.store(true, Ordering::Release);
    assert_eq!(
        done(
            owner
                .request(Operation::Submit {
                    scope: scope(1),
                    report: report()
                })
                .unwrap()
        ),
        Err(Error::Backend(Fault::Report))
    );
    assert_eq!(owner.snapshot().phase, Phase::Failed);
    assert_eq!(
        done(
            owner
                .request(Operation::Submit {
                    scope: scope(1),
                    report: report()
                })
                .unwrap()
        ),
        Err(Error::NotReady)
    );
    state.fail.store(false, Ordering::Release);
    start(&owner, &time, 2);
    stop(&owner);
    let events = state.events.lock().unwrap();
    let cancel = events.iter().position(|(e, _)| *e == "cancel").unwrap();
    assert_eq!(events[cancel - 1], ("report", Some(Report::NEUTRAL)));
}
#[test]
fn deadline_renewal_cannot_revive_expired_scope_using_controllable_clock() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    let previous = owner.snapshot().valid_until.unwrap();
    done(
        owner
            .request(Operation::RenewDeadline {
                scope: scope(1),
                valid_until: previous + 1000,
            })
            .unwrap(),
    )
    .unwrap();
    *time.lock().unwrap() = previous + 1000;
    let result = done(
        owner
            .request(Operation::RenewDeadline {
                scope: scope(1),
                valid_until: previous + 2000,
            })
            .unwrap(),
    );
    assert!(matches!(
        result,
        Err(Error::Expired | Error::RetirementPending | Error::NotReady)
    ));
    state.await_event("drop");
    assert_ne!(owner.snapshot().phase, Phase::Ready);
    assert_eq!(
        done(
            owner
                .request(Operation::Submit {
                    scope: scope(1),
                    report: report()
                })
                .unwrap()
        ),
        Err(Error::NotReady)
    );
    stop(&owner);
}
#[test]
fn release_timeout_is_uncertain_and_no_replacement_or_shutdown_ack_precedes_cancel_confirmation() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    state.canceled.store(false, Ordering::Release);
    let mut release = owner
        .request(Operation::Release { scope: scope(1) })
        .unwrap();
    state.await_event("cancel");
    assert_eq!(owner.snapshot().phase, Phase::Retiring);
    assert_eq!(state.devices.load(Ordering::Acquire), 1);
    assert_eq!(release.wait(Duration::from_millis(1)), Ok(None));
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(2),
                    valid_until: now(&time) + 1000
                })
                .unwrap()
        ),
        Err(Error::RetirementPending)
    );
    let mut shutdown = owner.request(Operation::Shutdown).unwrap();
    assert_eq!(shutdown.wait(Duration::from_millis(1)), Ok(None));
    state.canceled.store(true, Ordering::Release);
    assert_eq!(
        release.wait(Duration::from_secs(1)).unwrap().unwrap().phase,
        Phase::Inactive
    );
    assert_eq!(
        shutdown
            .wait(Duration::from_secs(1))
            .unwrap()
            .unwrap()
            .phase,
        Phase::Stopped
    );
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
}
#[test]
fn bounded_queue_rejects_backpressure_and_drop_retires_after_blocked_operation() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    *state.held.lock().unwrap() = true;
    let mut in_flight = owner
        .request(Operation::Submit {
            scope: scope(1),
            report: report(),
        })
        .unwrap();
    state.await_event("nonneutral");
    let mut queued = Vec::new();
    for _ in 0..QUEUE {
        queued.push(
            owner
                .request(Operation::Submit {
                    scope: scope(1),
                    report: report(),
                })
                .unwrap(),
        );
    }
    assert!(matches!(
        owner.request(Operation::Submit {
            scope: scope(1),
            report: report()
        }),
        Err(Error::Busy)
    ));
    assert_eq!(in_flight.wait(Duration::from_millis(1)), Ok(None));
    drop(owner);
    state.unblock();
    state.await_event("drop");
    assert_eq!(
        state
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|(e, _)| *e == "nonneutral")
            .count(),
        1
    );
    for pending in queued {
        assert_eq!(done(pending), Err(Error::Closed));
    }
}
#[test]
fn no_authorization_no_device_and_invalid_scope_deadline_wait_bounds_fail_closed() {
    let (owner, state, time) = owner();
    state.authorization.store(false, Ordering::Release);
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(0),
                    valid_until: now(&time) + 1000
                })
                .unwrap()
        ),
        Err(Error::InvalidScope)
    );
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(1),
                    valid_until: now(&time)
                })
                .unwrap()
        ),
        Err(Error::InvalidDeadline)
    );
    let mut pending = owner
        .request(Operation::Activate {
            scope: scope(1),
            valid_until: now(&time) + 1000,
        })
        .unwrap();
    assert_eq!(pending.wait(Duration::ZERO), Err(Error::WaitBudget));
    assert_eq!(
        done(pending),
        Err(Error::Backend(Fault::MissingEntitlement))
    );
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
    stop(&owner);
    let unsupported = OutputOwner::spawn(UnsupportedFactory, Arc::new(|| Ok(1000))).unwrap();
    assert_eq!(
        done(
            unsupported
                .request(Operation::Activate {
                    scope: scope(1),
                    valid_until: 2000
                })
                .unwrap()
        ),
        Err(Error::Backend(Fault::UnsupportedPlatform))
    );
    stop(&unsupported);
}
#[test]
fn failed_initial_neutral_never_acknowledges_ready_and_retains_failure() {
    let (owner, state, time) = owner();
    state.fail_neutral.store(true, Ordering::Release);
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(1),
                    valid_until: now(&time) + 1000
                })
                .unwrap()
        ),
        Err(Error::Backend(Fault::Report))
    );
    assert_eq!(owner.snapshot().phase, Phase::Failed);
    assert!(owner.snapshot().scope.is_none());
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
    stop(&owner);
}
#[test]
fn deadline_expiring_during_inflight_report_retires_before_reply_and_cannot_acknowledge_live() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    *state.held.lock().unwrap() = true;
    let mut pending = owner
        .request(Operation::Submit {
            scope: scope(1),
            report: report(),
        })
        .unwrap();
    state.await_event("nonneutral");
    *time.lock().unwrap() = owner.snapshot().valid_until.unwrap();
    assert!(!owner.snapshot().admits_at(now(&time)));
    state.unblock();
    assert_eq!(pending.wait(Duration::from_secs(1)), Err(Error::Expired));
    assert!(owner.snapshot().scope.is_none());
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
    stop(&owner);
}
#[test]
fn cancellation_failure_retains_context_until_confirmation_and_never_reports_false_release() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    state.cancel_error.store(true, Ordering::Release);
    let mut pending = owner
        .request(Operation::Release { scope: scope(1) })
        .unwrap();
    state.await_event("cancel-error");
    assert_eq!(owner.snapshot().phase, Phase::Retiring);
    assert_eq!(state.devices.load(Ordering::Acquire), 1);
    assert_eq!(pending.wait(Duration::from_millis(1)), Ok(None));
    state.cancel_error.store(false, Ordering::Release);
    assert_eq!(
        pending.wait(Duration::from_secs(1)),
        Err(Error::Backend(Fault::Cancellation))
    );
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
    assert_eq!(owner.snapshot().phase, Phase::Failed);
    stop(&owner);
}

#[test]
fn first_submit_installs_shorter_deadline_before_io_and_never_acknowledges_expired_output() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    *state.held.lock().unwrap() = true;
    let deadline = now(&time) + 350;
    let mut held = owner
        .request(Operation::SubmitUntil {
            scope: scope(1),
            report: report(),
            valid_until: deadline,
        })
        .unwrap();
    state.await_event("nonneutral");
    assert_eq!(owner.snapshot().valid_until, Some(deadline));
    assert!(owner.snapshot().admits_at(deadline - 1));
    assert!(!owner.snapshot().admits_at(deadline));
    *time.lock().unwrap() = deadline;
    state.unblock();
    assert_eq!(held.wait(Duration::from_secs(1)), Err(Error::Expired));
    assert!(owner.snapshot().scope.is_none());
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
    stop(&owner);
}

#[test]
fn exact_deadline_can_shorten_or_remain_equal_without_changing_legacy_renewal_rules() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    let input_deadline = now(&time) + 350;
    done(
        owner
            .request(Operation::SubmitUntil {
                scope: scope(1),
                report: report(),
                valid_until: input_deadline,
            })
            .unwrap(),
    )
    .unwrap();
    // Receiver renews the owner but still supplies min(owner, unchanged input TTL).
    done(
        owner
            .request(Operation::SetDeadline {
                scope: scope(1),
                valid_until: input_deadline,
            })
            .unwrap(),
    )
    .unwrap();
    assert_eq!(owner.snapshot().valid_until, Some(input_deadline));
    assert_eq!(
        done(
            owner
                .request(Operation::RenewDeadline {
                    scope: scope(1),
                    valid_until: input_deadline
                })
                .unwrap()
        ),
        Err(Error::InvalidDeadline)
    );
    done(
        owner
            .request(Operation::SetDeadline {
                scope: scope(1),
                valid_until: input_deadline - 10,
            })
            .unwrap(),
    )
    .unwrap();
    assert_eq!(owner.snapshot().valid_until, Some(input_deadline - 10));
    assert_eq!(
        state
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|(kind, _)| *kind == "nonneutral")
            .count(),
        1
    );
    stop(&owner);
}

#[test]
fn queued_extensions_and_reports_cannot_revive_a_scope_after_sleep_inclusive_jump() {
    let (owner, state, time) = owner();
    start(&owner, &time, 1);
    *state.held.lock().unwrap() = true;
    let mut in_flight = owner
        .request(Operation::SubmitUntil {
            scope: scope(1),
            report: report(),
            valid_until: 1350,
        })
        .unwrap();
    state.await_event("nonneutral");
    let queued = [
        Operation::SetDeadline {
            scope: scope(1),
            valid_until: 3_602_000,
        },
        Operation::SubmitUntil {
            scope: scope(1),
            report: report(),
            valid_until: 3_602_000,
        },
        Operation::RenewDeadline {
            scope: scope(1),
            valid_until: 3_602_000,
        },
    ]
    .map(|op| owner.request(op).unwrap());
    // Simulates a one-hour suspend in the injected receiver domain; no real sleep.
    *time.lock().unwrap() = 3_601_000;
    state.unblock();
    assert_eq!(in_flight.wait(Duration::from_secs(1)), Err(Error::Expired));
    for p in queued {
        assert_eq!(done(p), Err(Error::NotReady));
    }
    assert_eq!(
        state
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|(kind, _)| *kind == "nonneutral")
            .count(),
        1
    );
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
    stop(&owner);
}

#[test]
fn past_explicit_effective_deadline_neutralizes_instead_of_retaining_older_longer_authority() {
    for submit in [false, true] {
        let (owner, state, time) = owner();
        start(&owner, &time, 1);
        let op = if submit {
            Operation::SubmitUntil {
                scope: scope(1),
                report: report(),
                valid_until: now(&time),
            }
        } else {
            Operation::SetDeadline {
                scope: scope(1),
                valid_until: now(&time),
            }
        };
        assert_eq!(done(owner.request(op).unwrap()), Err(Error::Expired));
        assert!(owner.snapshot().scope.is_none());
        assert_eq!(
            state
                .events
                .lock()
                .unwrap()
                .iter()
                .filter(|(kind, _)| *kind == "nonneutral")
                .count(),
            0
        );
        stop(&owner);
    }
}

type FaultTime = Arc<Mutex<Result<u64, ClockFault>>>;
fn fault_owner() -> (OutputOwner, Arc<State>, FaultTime) {
    let state = State::new();
    let time = Arc::new(Mutex::new(Ok(1000)));
    let clock = time.clone();
    (
        OutputOwner::spawn(
            FakeFactory(state.clone()),
            Arc::new(move || *clock.lock().unwrap()),
        )
        .unwrap(),
        state,
        time,
    )
}
#[test]
fn clock_fault_during_io_retires_and_latches_until_explicit_fresh_generation_and_valid_high_water()
{
    for fault in [ClockFault::Unavailable, ClockFault::Regressed] {
        let (owner, state, time) = fault_owner();
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(1),
                    valid_until: 2000,
                })
                .unwrap(),
        )
        .unwrap();
        *state.held.lock().unwrap() = true;
        let mut in_flight = owner
            .request(Operation::SubmitUntil {
                scope: scope(1),
                report: report(),
                valid_until: 1500,
            })
            .unwrap();
        state.await_event("nonneutral");
        *time.lock().unwrap() = if fault == ClockFault::Unavailable {
            Err(fault)
        } else {
            Ok(999)
        };
        state.unblock();
        assert_eq!(
            in_flight.wait(Duration::from_secs(1)),
            Err(Error::Backend(Fault::Clock(fault)))
        );
        assert_eq!(owner.snapshot().clock_fault, Some(fault));
        assert!(owner.snapshot().scope.is_none());
        assert!(!owner.snapshot().admits_at(1000));
        *time.lock().unwrap() = Ok(1000);
        assert_eq!(
            done(
                owner
                    .request(Operation::SubmitUntil {
                        scope: scope(1),
                        report: report(),
                        valid_until: 2000
                    })
                    .unwrap()
            ),
            Err(Error::Backend(Fault::Clock(fault)))
        );
        assert_eq!(
            done(
                owner
                    .request(Operation::Activate {
                        scope: scope(1),
                        valid_until: 2000
                    })
                    .unwrap()
            ),
            Err(Error::StaleGeneration)
        );
        assert_eq!(owner.snapshot().clock_fault, Some(fault));
        if fault == ClockFault::Regressed {
            *time.lock().unwrap() = Ok(999);
            assert_eq!(
                done(
                    owner
                        .request(Operation::Activate {
                            scope: scope(2),
                            valid_until: 2000
                        })
                        .unwrap()
                ),
                Err(Error::Backend(Fault::Clock(ClockFault::Regressed)))
            );
            *time.lock().unwrap() = Ok(1000);
        }
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(if fault == ClockFault::Regressed { 3 } else { 2 }),
                    valid_until: 2000,
                })
                .unwrap(),
        )
        .unwrap();
        assert!(owner.snapshot().admits_at(1000));
        assert_eq!(owner.snapshot().clock_fault, None);
        stop(&owner);
    }
}

#[test]
fn unavailable_clock_blocks_startup_without_factory_work_and_shutdown_still_completes() {
    let state = State::new();
    let owner = OutputOwner::spawn(
        FakeFactory(state.clone()),
        Arc::new(|| Err(ClockFault::Unavailable)),
    )
    .unwrap();
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(1),
                    valid_until: 2000
                })
                .unwrap()
        ),
        Err(Error::Backend(Fault::Clock(ClockFault::Unavailable)))
    );
    assert_eq!(state.events.lock().unwrap().len(), 0);
    assert_eq!(owner.snapshot().clock_fault, Some(ClockFault::Unavailable));
    stop(&owner);
}

#[test]
fn clock_failure_after_creation_never_acknowledges_ready_and_preserves_retirement_confirmation() {
    struct FailAfterCreate(FakeFactory, FaultTime);
    impl Factory for FailAfterCreate {
        fn authorization(&mut self) -> Result<(), Fault> {
            self.0.authorization()
        }
        fn create(&mut self) -> Result<Box<dyn Device>, Fault> {
            let device = self.0.create()?;
            *self.1.lock().unwrap() = Err(ClockFault::Unavailable);
            Ok(device)
        }
    }
    let state = State::new();
    let time = Arc::new(Mutex::new(Ok(1000)));
    let clock = time.clone();
    let owner = OutputOwner::spawn(
        FailAfterCreate(FakeFactory(state.clone()), time),
        Arc::new(move || *clock.lock().unwrap()),
    )
    .unwrap();
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(1),
                    valid_until: 2000
                })
                .unwrap()
        ),
        Err(Error::Backend(Fault::Clock(ClockFault::Unavailable)))
    );
    assert_eq!(owner.snapshot().phase, Phase::Failed);
    assert!(owner.snapshot().scope.is_none());
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
    assert_eq!(
        state
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|(kind, _)| *kind == "nonneutral")
            .count(),
        0
    );
    stop(&owner);
}

#[test]
fn clock_failure_between_deadline_install_and_native_submission_prevents_held_report() {
    use std::collections::VecDeque;
    let state = State::new();
    let readings = Arc::new(Mutex::new(VecDeque::<Result<u64, ClockFault>>::new()));
    let clock = readings.clone();
    let (_sender, receiver) = mpsc::sync_channel(QUEUE);
    let shared = Arc::new(Mutex::new(Snapshot::default()));
    let mut worker = Worker::new(
        FakeFactory(state.clone()),
        receiver,
        shared,
        Arc::new(AtomicBool::new(false)),
        Arc::new(move || clock.lock().unwrap().pop_front().unwrap_or(Ok(1000))),
    );
    let (reply, result) = mpsc::sync_channel(1);
    worker.apply(Command {
        id: 1,
        operation: Operation::Activate {
            scope: scope(1),
            valid_until: 2000,
        },
        reply,
    });
    assert_eq!(result.recv().unwrap().unwrap().phase, Phase::Ready);
    readings
        .lock()
        .unwrap()
        .extend([Ok(1000), Err(ClockFault::Unavailable)]);
    let (reply, result) = mpsc::sync_channel(1);
    worker.apply(Command {
        id: 2,
        operation: Operation::SubmitUntil {
            scope: scope(1),
            report: report(),
            valid_until: 1350,
        },
        reply,
    });
    assert_eq!(worker.state.phase, Phase::Retiring);
    assert_eq!(worker.state.clock_fault, Some(ClockFault::Unavailable));
    assert_eq!(
        state
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|(kind, _)| *kind == "nonneutral")
            .count(),
        0
    );
    worker.poll_retirement();
    assert_eq!(
        result.recv().unwrap(),
        Err(Error::Backend(Fault::Clock(ClockFault::Unavailable)))
    );
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
}

#[test]
fn clock_fault_retirement_remains_pending_until_confirmation_and_shutdown_can_progress() {
    let (owner, state, time) = fault_owner();
    done(
        owner
            .request(Operation::Activate {
                scope: scope(1),
                valid_until: 2000,
            })
            .unwrap(),
    )
    .unwrap();
    state.canceled.store(false, Ordering::Release);
    *time.lock().unwrap() = Err(ClockFault::Unavailable);
    state.await_event("cancel");
    assert!(owner.snapshot().scope.is_none());
    assert_eq!(owner.snapshot().clock_fault, Some(ClockFault::Unavailable));
    assert_eq!(state.devices.load(Ordering::Acquire), 1);
    let mut shutdown = owner.request(Operation::Shutdown).unwrap();
    assert_eq!(shutdown.wait(Duration::from_millis(1)), Ok(None));
    state.canceled.store(true, Ordering::Release);
    assert_eq!(
        shutdown
            .wait(Duration::from_secs(1))
            .unwrap()
            .unwrap()
            .phase,
        Phase::Stopped
    );
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
}

#[test]
fn startup_clock_fault_cannot_be_recovered_by_replaying_the_failed_activation_generation() {
    let (owner, state, time) = fault_owner();
    *time.lock().unwrap() = Err(ClockFault::Unavailable);
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(1),
                    valid_until: 2000
                })
                .unwrap()
        ),
        Err(Error::Backend(Fault::Clock(ClockFault::Unavailable)))
    );
    assert_eq!(owner.snapshot().highest_generation, 1);
    *time.lock().unwrap() = Ok(1000);
    assert_eq!(
        done(
            owner
                .request(Operation::Activate {
                    scope: scope(1),
                    valid_until: 2000
                })
                .unwrap()
        ),
        Err(Error::StaleGeneration)
    );
    assert_eq!(owner.snapshot().clock_fault, Some(ClockFault::Unavailable));
    assert_eq!(state.devices.load(Ordering::Acquire), 0);
    done(
        owner
            .request(Operation::Activate {
                scope: scope(2),
                valid_until: 2000,
            })
            .unwrap(),
    )
    .unwrap();
    assert_eq!(owner.snapshot().clock_fault, None);
    stop(&owner);
}
