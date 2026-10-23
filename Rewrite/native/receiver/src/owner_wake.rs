//! Coalesced work notification; never an authority clock or an I/O lock.
use std::sync::{Condvar, Mutex};
use std::time::Duration;
#[derive(Default)]
pub struct OwnerWake {
    pending: Mutex<bool>,
    ready: Condvar,
}
impl OwnerWake {
    pub fn notify(&self) -> Result<(), &'static str> {
        let mut pending = self.pending.lock().map_err(|_| "owner_wake_failed")?;
        *pending = true;
        self.ready.notify_one();
        Ok(())
    }
    pub fn wait(&self, timeout: Duration) -> Result<(), &'static str> {
        let pending = self.pending.lock().map_err(|_| "owner_wake_failed")?;
        let (mut pending, _) = self
            .ready
            .wait_timeout_while(pending, timeout, |pending| !*pending)
            .map_err(|_| "owner_wake_failed")?;
        *pending = false;
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn notifications_before_wait_coalesce_without_lost_work() {
        let wake = OwnerWake::default();
        for _ in 0..1000 {
            wake.notify().unwrap();
        }
        wake.wait(Duration::from_secs(10)).unwrap();
        assert!(!*wake.pending.lock().unwrap());
    }
    #[test]
    fn poisoned_notification_is_fail_closed() {
        let wake = OwnerWake::default();
        let _ = std::panic::catch_unwind(|| {
            let _guard = wake.pending.lock().unwrap();
            panic!("poison");
        });
        assert_eq!(wake.notify(), Err("owner_wake_failed"));
        assert_eq!(wake.wait(Duration::ZERO), Err("owner_wake_failed"));
    }
}
