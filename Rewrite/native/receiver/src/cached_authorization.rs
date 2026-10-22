//! Native per-epoch authorization fence. It contains no bearer material.
//!
//! Lock order: packet/status holds scope -> broker sources -> native IPC, with a
//! short clock sample before broker work. Policy changes hold mutation -> store,
//! invalidate scope (waiting for an in-flight forward), release that scope guard,
//! then retire broker sources before durable mutation. The reservation worker
//! holds store -> clock. Clock never waits on scope, broker, storage or IPC, and
//! no scope guard covers filesystem IO or TLS reads/writes.
use crate::authorization_clock::Clock;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex, MutexGuard,
};
pub(crate) struct Scope {
    gate: Mutex<()>,
    live: AtomicBool,
    clock: Arc<Clock>,
}
impl Scope {
    pub fn new(clock: Arc<Clock>) -> Arc<Self> {
        clock.retain();
        Arc::new(Self {
            gate: Mutex::new(()),
            live: AtomicBool::new(true),
            clock,
        })
    }
    pub fn is_live(&self) -> bool {
        self.live.load(Ordering::Acquire)
    }
    pub fn invalidate(&self) -> Result<(), &'static str> {
        let _gate = self
            .gate
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        if self.live.swap(false, Ordering::AcqRel) {
            self.clock.release();
        }
        Ok(())
    }
}
impl Drop for Scope {
    fn drop(&mut self) {
        if self.live.swap(false, Ordering::AcqRel) {
            self.clock.release();
        }
    }
}
#[derive(Clone)]
pub(crate) struct CachedAuthorization {
    scope: Arc<Scope>,
    pub clock: Arc<Clock>,
}
impl CachedAuthorization {
    pub fn new(scope: Arc<Scope>, clock: Arc<Clock>) -> Self {
        Self { scope, clock }
    }
    /// Retire/invalidate waits for an already admitted native forwarding operation;
    /// after it returns no old-epoch forwarding operation can begin.
    pub fn guard(&self) -> Result<MutexGuard<'_, ()>, &'static str> {
        let gate = self
            .scope
            .gate
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        if !self.scope.is_live() {
            return Err("phone_authentication_rejected");
        }
        Ok(gate)
    }
}
