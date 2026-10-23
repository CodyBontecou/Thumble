//! Explicit, bounded bridge to the confined native output owner. No device is
//! created until an activation is acknowledged by the worker.
use crate::runtime::{Output, OutputStatus};
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use thumble_rewrite_output_core::{
    ClockDomain, ClockFault, Error, Factory, Operation, OutputOwner, Phase, Report, Scope,
};

pub struct KernelClock;
impl ClockDomain for KernelClock {
    fn now_ms(&self) -> Result<u64, ClockFault> {
        crate::clock::millis().map_err(|_| ClockFault::Unavailable)
    }
}
// Status and worker reads share a high-water/fault latch. Only a fresh
// activation after confirmed retirement can clear it; elapsed wait clocks are
// never used as authorization clocks.
struct CheckedClock {
    source: Arc<dyn ClockDomain>,
    state: Mutex<(u64, Option<ClockFault>)>,
}
impl ClockDomain for CheckedClock {
    fn now_ms(&self) -> Result<u64, ClockFault> {
        let mut state = self.state.lock().map_err(|_| ClockFault::Unavailable)?;
        if let Some(fault) = state.1 {
            return Err(fault);
        }
        match self.source.now_ms() {
            Ok(now) if now >= state.0 => {
                state.0 = now;
                Ok(now)
            }
            Ok(_) => {
                state.1 = Some(ClockFault::Regressed);
                Err(ClockFault::Regressed)
            }
            Err(fault) => {
                state.1 = Some(fault);
                Err(fault)
            }
        }
    }
}
impl CheckedClock {
    fn recover(&self) -> Result<(), &'static str> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "physical_output_clock_failed")?;
        let now = self
            .source
            .now_ms()
            .map_err(|_| "physical_output_clock_failed")?;
        if now < state.0 {
            return Err("physical_output_clock_failed");
        }
        *state = (now, None);
        Ok(())
    }
}
struct Status {
    worker: Arc<OutputOwner>,
    clock: Arc<CheckedClock>,
    owner: [u8; 16],
    uncertain: AtomicBool,
    backend: &'static str,
}
impl OutputStatus for Status {
    fn backend(&self) -> &'static str {
        self.backend
    }
    fn cleanup_ready(&self, generation: u64) -> bool {
        if self.uncertain.load(Ordering::Acquire) || self.clock.now_ms().is_err() {
            return false;
        }
        let state = self.worker.snapshot();
        state.phase == Phase::Inactive
            && state.highest_generation == generation
            && state.scope.is_none()
            && state.valid_until.is_none()
            && state.fault.is_none()
            && state.clock_fault.is_none()
    }
    fn enabled(&self, generation: u64) -> bool {
        if self.uncertain.load(Ordering::Acquire) {
            return false;
        }
        let Ok(now) = self.clock.now_ms() else {
            return false;
        };
        let state = self.worker.snapshot();
        state.scope
            == Some(Scope {
                owner: self.owner,
                generation,
            })
            && state.admits_at(now)
    }
}
#[cfg(test)]
#[derive(Clone, Copy, Debug)]
struct WaitObservation {
    operation: Operation,
    budget: Duration,
    result: Result<Option<thumble_rewrite_output_core::Receipt>, Error>,
}
#[cfg(test)]
struct ObservedWait<'a> {
    pending: &'a mut thumble_rewrite_output_core::Pending,
    observations: &'a Mutex<Vec<WaitObservation>>,
    operation: Operation,
}
#[cfg(test)]
impl ObservedWait<'_> {
    fn wait(
        &mut self,
        budget: Duration,
    ) -> Result<Option<thumble_rewrite_output_core::Receipt>, Error> {
        let result = self.pending.wait(budget);
        self.observations.lock().unwrap().push(WaitObservation {
            operation: self.operation,
            budget,
            result,
        });
        result
    }
}
pub struct Bridge {
    #[cfg(test)]
    wait_observations: Mutex<Vec<WaitObservation>>,
    status: Arc<Status>,
    scope: Option<Scope>,
}
impl Bridge {
    /// The owner nonce identifies this process instance, never a phone credential.
    pub fn new(
        factory: impl Factory,
        clock: Arc<dyn ClockDomain>,
        owner: [u8; 16],
        backend: &'static str,
    ) -> Result<Self, &'static str> {
        if owner == [0; 16] {
            return Err("physical_output_invalid_owner");
        }
        let clock = Arc::new(CheckedClock {
            source: clock,
            state: Mutex::new((0, None)),
        });
        let worker = Arc::new(
            OutputOwner::spawn(factory, clock.clone())
                .map_err(|_| "physical_output_unavailable")?,
        );
        Ok(Self {
            #[cfg(test)]
            wait_observations: Mutex::new(Vec::new()),
            status: Arc::new(Status {
                worker,
                clock,
                owner,
                uncertain: AtomicBool::new(false),
                backend,
            }),
            scope: None,
        })
    }
    fn uncertain(&self) -> &'static str {
        // Shutdown sets the worker's closing flag synchronously, even if its
        // queue is full. Late creation/IO can never restore admission.
        self.status.uncertain.store(true, Ordering::Release);
        let _ = self.status.worker.request(Operation::Shutdown);
        "physical_output_restart_required"
    }
    fn perform(&self, operation: Operation, ms: u64) -> Result<(), &'static str> {
        if self.status.uncertain.load(Ordering::Acquire) {
            return Err("physical_output_restart_required");
        }
        let mut pending = self
            .status
            .worker
            .request(operation)
            .map_err(|error| match error {
                Error::Busy | Error::Closed | Error::ReceiptExhausted => self.uncertain(),
                _ => "physical_output_failed",
            })?;
        #[cfg(test)]
        let mut pending = ObservedWait {
            pending: &mut pending,
            observations: &self.wait_observations,
            operation,
        };
        match pending.wait(Duration::from_millis(ms)) {
            Ok(Some(_)) => Ok(()),
            Ok(None) | Err(Error::Closed) => Err(self.uncertain()),
            Err(_) => Err("physical_output_failed"),
        }
    }
    fn scope(&self) -> Result<Scope, &'static str> {
        self.scope.ok_or("physical_output_not_ready")
    }
}
impl Output for Bridge {
    fn submit(&mut self, _: [u8; 20], _: &'static str) -> Result<(), &'static str> {
        Err("physical_output_deadline_required")
    }
    fn begin(&mut self, generation: u64, deadline: u64) -> Result<(), &'static str> {
        let previous = self.status.worker.snapshot();
        if matches!(previous.phase, Phase::Inactive | Phase::Failed)
            && generation > previous.highest_generation
        {
            self.status.clock.recover()?;
        }
        let scope = Scope {
            owner: self.status.owner,
            generation,
        };
        self.perform(
            Operation::Activate {
                scope,
                valid_until: deadline,
            },
            100,
        )?;
        self.scope = Some(scope);
        if !self.status.enabled(generation) {
            return Err("physical_output_not_ready");
        }
        Ok(())
    }
    fn submit_until(
        &mut self,
        report: [u8; 20],
        _: &'static str,
        deadline: u64,
    ) -> Result<(), &'static str> {
        let report = Report::try_from(report).map_err(|_| "physical_output_invalid_report")?;
        self.perform(
            Operation::SubmitUntil {
                scope: self.scope()?,
                report,
                valid_until: deadline,
            },
            10,
        )
    }
    fn set_deadline(&mut self, deadline: u64) -> Result<(), &'static str> {
        self.perform(
            Operation::SetDeadline {
                scope: self.scope()?,
                valid_until: deadline,
            },
            10,
        )
    }
    fn retire(&mut self, _: &'static str) -> Result<(), &'static str> {
        if self.status.uncertain.load(Ordering::Acquire) {
            self.scope = None;
            return Err("physical_output_restart_required");
        }
        let end = Instant::now() + Duration::from_millis(50);
        let state = self.status.worker.snapshot();
        if matches!(
            state.phase,
            Phase::Inactive | Phase::Failed | Phase::Stopped
        ) {
            self.scope = None;
            return Ok(());
        }
        if state.phase == Phase::Ready {
            let scope = self.scope.take().ok_or("physical_output_not_ready")?;
            match self.perform(Operation::Release { scope }, 50) {
                Ok(()) => return Ok(()),
                Err("physical_output_failed") => (), // expiry/clock fault can start retirement before Release
                Err(error) => return Err(error),
            }
        }
        // A definite failed operation may already be retiring asynchronously.
        // Wait only for cleanup; never enqueue another activation over it.
        self.scope = None;
        while Instant::now() < end {
            if matches!(
                self.status.worker.snapshot().phase,
                Phase::Inactive | Phase::Failed | Phase::Stopped
            ) {
                return Ok(());
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        Err(self.uncertain())
    }
    fn health(&self, generation: u64) -> Result<(), &'static str> {
        if self.status.uncertain.load(Ordering::Acquire) {
            Err("physical_output_restart_required")
        } else if self.status.enabled(generation) {
            Ok(())
        } else {
            Err("physical_output_failed")
        }
    }
    fn status(&self) -> Option<Arc<dyn OutputStatus>> {
        Some(self.status.clone())
    }
}
impl Drop for Bridge {
    fn drop(&mut self) {
        self.status.uncertain.store(true, Ordering::Release);
        let _ = self.status.worker.request(Operation::Shutdown);
    }
}

#[cfg(test)]
mod tests;
