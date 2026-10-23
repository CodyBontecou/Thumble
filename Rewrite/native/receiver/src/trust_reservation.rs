//! Exactly one bounded clock-reservation owner per native trust owner.
use crate::phone_trust::PhoneTrustStore;
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
pub(crate) struct Owner {
    stop: Arc<AtomicBool>,
    worker: Option<thread::JoinHandle<()>>,
}
fn now() -> Result<u64, &'static str> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|duration| u64::try_from(duration.as_millis()).ok())
        .ok_or("phone_trust_clock_invalid")
}
impl Owner {
    pub fn start(store: Arc<Mutex<PhoneTrustStore>>) -> Result<Self, &'static str> {
        let clock = store
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?
            .clock();
        Self::start_clock(store, clock)
    }
    fn start_clock(
        store: Arc<Mutex<PhoneTrustStore>>,
        clock: Arc<crate::authorization_clock::Clock>,
    ) -> Result<Self, &'static str> {
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let worker = thread::Builder::new()
            .name("thumble-trust-clock".into())
            .spawn(move || {
                while !stopped.load(Ordering::Acquire) {
                    if clock.needs_reservation() {
                        let result = store
                            .lock()
                            .map_err(|_| "phone_trust_owner_unavailable")
                            .and_then(|mut store| store.reserve_clock(&mut now));
                        if result.is_err() {
                            clock.fail();
                            break;
                        }
                    }
                    thread::sleep(Duration::from_millis(20));
                }
            })
            .map_err(|_| "phone_trust_owner_unavailable")?;
        Ok(Self {
            stop,
            worker: Some(worker),
        })
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{path::PathBuf, sync::atomic::AtomicU64};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn owned_renewal_stalled_behind_storage_cannot_rearm_an_exhausted_reservation() {
        let root = Root(std::env::temp_dir().canonicalize().unwrap().join(format!(
            "thumble-reservation-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )));
        crate::host_identity::load_or_create(&root.0).unwrap();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        let issued = store
            .enroll_after_pairing("clock-phone", "Clock", now().unwrap())
            .unwrap();
        let authorization = store.cached_authorization(issued.phone()).unwrap();
        let clock = store.clock();
        let ceiling = clock.ceiling();
        let store = Arc::new(Mutex::new(store));
        // The one owned worker may wait on this existing operation; there is no
        // queued task per packet and no detached writer surviving owner shutdown.
        let storage = store.lock().unwrap();
        let owner = Owner::start_clock(store.clone(), clock.clone()).unwrap();
        thread::sleep(Duration::from_millis(1_050));
        assert_eq!(
            clock.sample(&mut now),
            Err("phone_trust_reservation_expired")
        );
        drop(storage);
        drop(owner);
        assert_eq!(clock.ceiling(), ceiling);
        assert_eq!(
            clock.sample(&mut now),
            Err("phone_trust_reservation_failed")
        );
        {
            let mut trust = store.lock().unwrap();
            assert_eq!(
                trust
                    .authorize_epoch("clock-phone", "1", now().unwrap())
                    .err(),
                Some("phone_trust_reservation_failed")
            );
            assert_eq!(
                trust
                    .enroll_after_pairing("clock-phone", "New", now().unwrap())
                    .err(),
                Some("phone_trust_reservation_failed")
            );
        }
        assert!(
            authorization.guard().is_ok(),
            "clock failure is separate from epoch identity"
        );
    }
}
