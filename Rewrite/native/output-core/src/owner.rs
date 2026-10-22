use crate::Report;
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    mpsc, Arc, Mutex,
};
use std::thread;
use std::time::{Duration, Instant};
const QUEUE: usize = 8;
const POLL: Duration = Duration::from_millis(10);
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fault {
    MissingEntitlement,
    UnsupportedPlatform,
    Creation,
    Report,
    Cancellation,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Busy,
    Closed,
    InvalidScope,
    StaleGeneration,
    WrongScope,
    Expired,
    InvalidDeadline,
    NotReady,
    RetirementPending,
    InvalidReport,
    ReceiptExhausted,
    WaitBudget,
    Backend(Fault),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Scope {
    pub owner: [u8; 16],
    pub generation: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Inactive,
    Starting,
    Ready,
    Retiring,
    Failed,
    Stopped,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Snapshot {
    pub phase: Phase,
    pub scope: Option<Scope>,
    pub highest_generation: u64,
    pub valid_until: Option<Instant>,
    pub fault: Option<Fault>,
}
impl Snapshot {
    /// Ready is the last worker-confirmed device phase. Admission additionally
    /// requires the caller-supplied deadline to remain live, even if IO stalls.
    pub fn admits_at(&self, now: Instant) -> bool {
        self.phase == Phase::Ready
            && self.scope.is_some()
            && self.valid_until.is_some_and(|d| now < d)
    }
}
impl Default for Snapshot {
    fn default() -> Self {
        Self {
            phase: Phase::Inactive,
            scope: None,
            highest_generation: 0,
            valid_until: None,
            fault: None,
        }
    }
}
#[derive(Clone, Copy, Debug)]
pub enum Operation {
    Activate { scope: Scope, valid_until: Instant },
    RenewDeadline { scope: Scope, valid_until: Instant },
    Submit { scope: Scope, report: Report },
    Release { scope: Scope },
    Shutdown,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Receipt {
    pub id: u64,
    pub phase: Phase,
}
type Reply = mpsc::SyncSender<Result<Receipt, Error>>;
/// Implementations are created and used on the output thread, without Send.
/// Retirement must preserve every device/callback resource until confirmation.
pub trait Device {
    fn submit(&mut self, report: Report) -> Result<(), Fault>;
    fn begin_retirement(&mut self) -> Result<(), Fault>;
    fn retirement_confirmed(&mut self) -> Result<bool, Fault>;
}
pub trait Factory: Send + 'static {
    /// Signed authorization check only; no prompt or device creation.
    fn authorization(&mut self) -> Result<(), Fault>;
    fn create(&mut self) -> Result<Box<dyn Device>, Fault>;
}
/// There is intentionally no Windows virtual-gamepad implementation.
pub struct UnsupportedFactory;
impl Factory for UnsupportedFactory {
    fn authorization(&mut self) -> Result<(), Fault> {
        Err(Fault::UnsupportedPlatform)
    }
    fn create(&mut self) -> Result<Box<dyn Device>, Fault> {
        Err(Fault::UnsupportedPlatform)
    }
}
struct Command {
    id: u64,
    operation: Operation,
    reply: Reply,
}
/// A timeout means uncertain completion, never canceled work. The same receipt
/// can be waited on again. Results remain cached in this bounded caller handle.
pub struct Pending {
    pub id: u64,
    receiver: mpsc::Receiver<Result<Receipt, Error>>,
    result: Option<Result<Receipt, Error>>,
}
impl Pending {
    pub fn wait(&mut self, budget: Duration) -> Result<Option<Receipt>, Error> {
        if budget.is_zero() || budget > Duration::from_secs(1) {
            return Err(Error::WaitBudget);
        }
        if let Some(result) = self.result {
            return result.map(Some);
        }
        match self.receiver.recv_timeout(budget) {
            Ok(result) => {
                self.result = Some(result);
                result.map(Some)
            }
            Err(mpsc::RecvTimeoutError::Timeout) => Ok(None),
            Err(mpsc::RecvTimeoutError::Disconnected) => Err(Error::Closed),
        }
    }
}
/// One thread, one device, eight queued requests. Drop requests shutdown and
/// detaches the thread; it never frees another thread's unconfirmed CF context.
pub struct OutputOwner {
    sender: Option<mpsc::SyncSender<Command>>,
    closing: Arc<AtomicBool>,
    shared: Arc<Mutex<Snapshot>>,
    next: AtomicU64,
}
impl OutputOwner {
    pub fn spawn(factory: impl Factory) -> Result<Self, Error> {
        Self::with_clock(factory, Arc::new(Instant::now))
    }
    fn with_clock(
        factory: impl Factory,
        clock: Arc<dyn Fn() -> Instant + Send + Sync>,
    ) -> Result<Self, Error> {
        let (sender, receiver) = mpsc::sync_channel(QUEUE);
        let shared = Arc::new(Mutex::new(Snapshot::default()));
        let closing = Arc::new(AtomicBool::new(false));
        let state = shared.clone();
        let stopped = closing.clone();
        thread::Builder::new()
            .name("thumble-output-owner".into())
            .spawn(move || Worker::new(factory, receiver, state, stopped, clock).run())
            .map_err(|_| Error::Closed)?;
        Ok(Self {
            sender: Some(sender),
            closing,
            shared,
            next: AtomicU64::new(1),
        })
    }
    pub fn request(&self, operation: Operation) -> Result<Pending, Error> {
        if self.closing.load(Ordering::Acquire) && !matches!(operation, Operation::Shutdown) {
            return Err(Error::Closed);
        }
        let id = self
            .next
            .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
            .map_err(|_| Error::ReceiptExhausted)?;
        if matches!(operation, Operation::Shutdown) {
            self.closing.store(true, Ordering::Release);
        }
        let (reply, receiver) = mpsc::sync_channel(1);
        self.sender
            .as_ref()
            .ok_or(Error::Closed)?
            .try_send(Command {
                id,
                operation,
                reply,
            })
            .map_err(|e| match e {
                mpsc::TrySendError::Full(_) => Error::Busy,
                mpsc::TrySendError::Disconnected(_) => Error::Closed,
            })?;
        Ok(Pending {
            id,
            receiver,
            result: None,
        })
    }
    pub fn snapshot(&self) -> Snapshot {
        let mut snapshot = *self.shared.lock().unwrap_or_else(|p| p.into_inner());
        if self.closing.load(Ordering::Acquire) && snapshot.phase != Phase::Stopped {
            snapshot.scope = None;
            snapshot.valid_until = None;
            if matches!(snapshot.phase, Phase::Ready | Phase::Starting) {
                snapshot.phase = Phase::Retiring;
            }
        }
        snapshot
    }
}
impl Drop for OutputOwner {
    fn drop(&mut self) {
        self.closing.store(true, Ordering::Release);
        self.sender.take();
    }
}
struct Retirement {
    after: After,
    fault: Option<Fault>,
}
enum After {
    Activate(Command),
    Reply(Command),
    Expired,
    Failure(Command, Fault),
    Rejected(Command, Error),
}
struct Worker<F> {
    factory: F,
    receiver: mpsc::Receiver<Command>,
    shared: Arc<Mutex<Snapshot>>,
    closing: Arc<AtomicBool>,
    clock: Arc<dyn Fn() -> Instant + Send + Sync>,
    state: Snapshot,
    device: Option<Box<dyn Device>>,
    retirement: Option<Retirement>,
    shutdown: Option<Command>,
}
impl<F: Factory> Worker<F> {
    fn new(
        factory: F,
        receiver: mpsc::Receiver<Command>,
        shared: Arc<Mutex<Snapshot>>,
        closing: Arc<AtomicBool>,
        clock: Arc<dyn Fn() -> Instant + Send + Sync>,
    ) -> Self {
        Self {
            factory,
            receiver,
            shared,
            closing,
            clock,
            state: Snapshot::default(),
            device: None,
            retirement: None,
            shutdown: None,
        }
    }
    fn publish(&self) {
        *self.shared.lock().unwrap_or_else(|p| p.into_inner()) = self.state;
    }
    fn reply(&self, c: Command, result: Result<(), Error>) {
        let _ = c.reply.try_send(result.map(|()| Receipt {
            id: c.id,
            phase: self.state.phase,
        }));
    }
    fn retire(&mut self, after: After, fault: Option<Fault>) {
        self.state.scope = None;
        self.state.valid_until = None;
        self.state.phase = Phase::Retiring;
        self.state.fault = fault;
        self.publish();
        let mut retirement = Retirement { after, fault };
        if let Some(device) = self.device.as_mut() {
            if device.submit(Report::NEUTRAL).is_err() {
                retirement.fault = Some(Fault::Report);
            }
            if device.begin_retirement().is_err() {
                retirement.fault = Some(Fault::Cancellation);
            }
        }
        self.state.fault = retirement.fault;
        self.retirement = Some(retirement);
        self.publish();
    }
    fn poll_retirement(&mut self) {
        let confirmed = match self.device.as_mut() {
            None => true,
            Some(d) => match d.retirement_confirmed() {
                Ok(v) => v,
                Err(_) => {
                    self.state.fault = Some(Fault::Cancellation);
                    self.retirement.as_mut().unwrap().fault = Some(Fault::Cancellation);
                    self.publish();
                    false
                }
            },
        };
        if !confirmed {
            return;
        }
        self.device.take();
        let retirement = self.retirement.take().unwrap();
        self.state.phase = if retirement.fault.is_some() {
            Phase::Failed
        } else {
            Phase::Inactive
        };
        self.state.fault = retirement.fault;
        self.publish();
        match retirement.after {
            After::Activate(c)
                if !self.closing.load(Ordering::Acquire) && retirement.fault.is_none() =>
            {
                self.activate(c)
            }
            After::Activate(c) => self.reply(
                c,
                Err(if self.closing.load(Ordering::Acquire) {
                    Error::Closed
                } else {
                    Error::Backend(retirement.fault.unwrap())
                }),
            ),
            After::Reply(c) => self.reply(
                c,
                retirement.fault.map_or(Ok(()), |f| Err(Error::Backend(f))),
            ),
            After::Failure(c, f) => self.reply(c, Err(Error::Backend(f))),
            After::Rejected(c, e) => self.reply(c, Err(e)),
            After::Expired => (),
        }
    }
    fn activate(&mut self, c: Command) {
        let Operation::Activate { scope, valid_until } = c.operation else {
            unreachable!()
        };
        if valid_until <= (self.clock)() {
            self.reply(c, Err(Error::Expired));
            return;
        }
        self.state.phase = Phase::Starting;
        self.state.scope = None;
        self.state.valid_until = None;
        self.state.fault = None;
        self.publish();
        if let Err(f) = self.factory.authorization() {
            self.state.phase = Phase::Failed;
            self.state.fault = Some(f);
            self.publish();
            self.reply(c, Err(Error::Backend(f)));
            return;
        }
        if self.closing.load(Ordering::Acquire) || valid_until <= (self.clock)() {
            self.state.phase = Phase::Inactive;
            self.publish();
            self.reply(
                c,
                Err(if self.closing.load(Ordering::Acquire) {
                    Error::Closed
                } else {
                    Error::Expired
                }),
            );
            return;
        }
        match self.factory.create() {
            Err(f) => {
                self.state.phase = Phase::Failed;
                self.state.fault = Some(f);
                self.publish();
                self.reply(c, Err(Error::Backend(f)));
            }
            Ok(device) => {
                self.device = Some(device);
                if let Err(f) = self.device.as_mut().unwrap().submit(Report::NEUTRAL) {
                    self.retire(After::Failure(c, f), Some(f));
                    return;
                }
                if self.closing.load(Ordering::Acquire) || valid_until <= (self.clock)() {
                    self.retire(
                        After::Rejected(
                            c,
                            if self.closing.load(Ordering::Acquire) {
                                Error::Closed
                            } else {
                                Error::Expired
                            },
                        ),
                        None,
                    );
                    return;
                }
                self.state.phase = Phase::Ready;
                self.state.scope = Some(scope);
                self.state.valid_until = Some(valid_until);
                self.publish();
                self.reply(c, Ok(()));
            }
        }
    }
    fn apply(&mut self, c: Command) {
        if self.state.valid_until.is_some_and(|d| (self.clock)() >= d) && self.retirement.is_none()
        {
            self.retire(After::Expired, None);
            if !matches!(c.operation, Operation::Shutdown) {
                self.reply(c, Err(Error::Expired));
                return;
            }
        }
        if matches!(c.operation, Operation::Shutdown) {
            if self.shutdown.is_some() {
                self.reply(c, Err(Error::Busy));
            } else {
                self.shutdown = Some(c);
            }
            return;
        }
        if self.closing.load(Ordering::Acquire) {
            self.reply(c, Err(Error::Closed));
            return;
        }
        if self.retirement.is_some() {
            self.reply(c, Err(Error::RetirementPending));
            return;
        }
        if let Operation::Activate { scope, valid_until } = c.operation {
            if scope.generation == 0 || scope.owner == [0; 16] {
                self.reply(c, Err(Error::InvalidScope));
                return;
            }
            if scope.generation <= self.state.highest_generation {
                self.reply(c, Err(Error::StaleGeneration));
                return;
            }
            if valid_until <= (self.clock)() {
                self.reply(c, Err(Error::InvalidDeadline));
                return;
            }
            self.state.highest_generation = scope.generation;
            if self.device.is_some() {
                self.retire(After::Activate(c), None);
            } else {
                self.activate(c);
            }
            return;
        }
        let scope = match c.operation {
            Operation::Submit { scope, .. }
            | Operation::Release { scope }
            | Operation::RenewDeadline { scope, .. } => scope,
            _ => unreachable!(),
        };
        if self.state.scope != Some(scope) {
            self.reply(
                c,
                Err(if self.state.phase == Phase::Ready {
                    Error::WrongScope
                } else {
                    Error::NotReady
                }),
            );
            return;
        }
        match c.operation {
            Operation::Submit { report, .. } => {
                if let Err(f) = self.device.as_mut().unwrap().submit(report) {
                    self.retire(After::Failure(c, f), Some(f));
                } else if self.state.valid_until.is_some_and(|d| (self.clock)() >= d) {
                    self.retire(After::Rejected(c, Error::Expired), None);
                } else {
                    self.reply(c, Ok(()));
                }
            }
            Operation::Release { .. } => self.retire(After::Reply(c), None),
            Operation::RenewDeadline { valid_until, .. } => {
                if valid_until <= self.state.valid_until.unwrap() || valid_until <= (self.clock)() {
                    self.reply(c, Err(Error::InvalidDeadline));
                    return;
                }
                self.state.valid_until = Some(valid_until);
                self.publish();
                self.reply(c, Ok(()));
            }
            _ => unreachable!(),
        }
    }
    fn run(mut self) {
        loop {
            if self.retirement.is_some() {
                self.poll_retirement();
            }
            if self.state.valid_until.is_some_and(|d| (self.clock)() >= d)
                && self.retirement.is_none()
            {
                self.retire(After::Expired, None);
            }
            if self.closing.load(Ordering::Acquire) && self.retirement.is_none() {
                if self.device.is_some() {
                    self.retire(After::Expired, None);
                } else {
                    self.state.phase = Phase::Stopped;
                    self.state.scope = None;
                    self.state.valid_until = None;
                    self.publish();
                    if let Some(c) = self.shutdown.take() {
                        self.reply(c, Ok(()));
                    }
                    while let Ok(c) = self.receiver.try_recv() {
                        let result = if matches!(c.operation, Operation::Shutdown) {
                            Ok(())
                        } else {
                            Err(Error::Closed)
                        };
                        self.reply(c, result);
                    }
                    return;
                }
            }
            match self.receiver.recv_timeout(POLL) {
                Ok(c) => self.apply(c),
                Err(mpsc::RecvTimeoutError::Timeout) => (),
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    self.closing.store(true, Ordering::Release);
                    if self.retirement.is_some() {
                        thread::sleep(POLL);
                    }
                }
            }
        }
    }
}
#[cfg(test)]
mod tests;
