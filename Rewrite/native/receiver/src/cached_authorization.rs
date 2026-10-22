//! Native per-epoch authorization fence. It contains no bearer material.
//!
//! Lock order: packet/status holds scope -> broker sources -> native IPC, with a
//! short clock sample before broker work. Policy changes hold mutation -> store,
//! invalidate scope (waiting for an in-flight forward), release that scope guard,
//! then retire broker sources before durable mutation. The reservation worker
//! holds store -> clock. Clock never waits on scope, broker, storage or IPC, and
//! no input scope guard covers filesystem IO or TLS reads/writes. Management
//! delivery holds its separate gate -> brief input scope check -> TLS write.
//! Policy coordination detaches and marks dead under the input gate, commits
//! mutation, releases global store/policy locks, then waits for
//! management delivery. Input never takes that gate; neither order forms a cycle.
use crate::authorization_clock::Clock;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex, MutexGuard,
};
pub(crate) struct Scope {
    gate: Mutex<()>,
    management_delivery: Mutex<()>,
    live: AtomicBool,
    clock: Arc<Clock>,
}
impl Scope {
    pub fn new(clock: Arc<Clock>) -> Arc<Self> {
        clock.retain();
        Arc::new(Self {
            gate: Mutex::new(()),
            management_delivery: Mutex::new(()),
            live: AtomicBool::new(true),
            clock,
        })
    }
    pub fn is_live(&self) -> bool {
        self.live.load(Ordering::Acquire)
    }
    pub fn retire(&self) -> Result<(), &'static str> {
        let _gate = self
            .gate
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        if self.live.swap(false, Ordering::AcqRel) {
            self.clock.release();
        }
        Ok(())
    }
    /// Call only after dropping global trust and policy locks.
    pub fn wait_management_delivery(&self) -> Result<(), &'static str> {
        let _delivery = self
            .management_delivery
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
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
    pub fn management_guard(&self) -> Result<MutexGuard<'_, ()>, &'static str> {
        self.scope
            .management_delivery
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")
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

#[cfg(test)]
mod management_tests {
    use super::*;
    use std::{sync::mpsc, thread, time::Duration};
    #[test]
    fn management_delivery_never_blocks_input_and_invalidation_waits_without_input_lock() {
        let clock = Arc::new(Clock::new(100, 1100).unwrap());
        let scope = Scope::new(clock.clone());
        let authorization = CachedAuthorization::new(scope.clone(), clock);
        let delivery = authorization.management_guard().unwrap();
        // A slow management write leaves the input forwarding gate available.
        drop(authorization.guard().unwrap());
        let (done, result) = mpsc::sync_channel(1);
        let invalidating = scope.clone();
        let worker = thread::spawn(move || {
            done.send(
                invalidating
                    .retire()
                    .and_then(|_| invalidating.wait_management_delivery()),
            )
            .unwrap()
        });
        let deadline = std::time::Instant::now() + Duration::from_secs(1);
        while scope.is_live() && std::time::Instant::now() < deadline {
            thread::yield_now();
        }
        assert!(!scope.is_live());
        // The live flag is set before the short input guard is dropped. Wait for
        // that unlock explicitly; observing the atomic flag alone is no barrier.
        let unlocked = std::time::Instant::now() + Duration::from_secs(1);
        while scope.gate.try_lock().is_err() && std::time::Instant::now() < unlocked {
            thread::yield_now();
        }
        // Invalidation has released the input gate while waiting for delivery.
        assert!(scope.gate.try_lock().is_ok());
        assert!(matches!(
            authorization.guard(),
            Err("phone_authentication_rejected")
        ));
        assert!(result.try_recv().is_err());
        drop(delivery);
        assert_eq!(result.recv_timeout(Duration::from_secs(1)).unwrap(), Ok(()));
        worker.join().unwrap();
        assert!(matches!(
            authorization.guard(),
            Err("phone_authentication_rejected")
        ));
        let new_scope = Scope::new(authorization.clock.clone());
        let reenrolled = CachedAuthorization::new(new_scope, authorization.clock.clone());
        drop(reenrolled.guard().unwrap());
        assert!(matches!(
            authorization.guard(),
            Err("phone_authentication_rejected")
        ));
    }
}
