//! Gateway-level per-device tool-call token bucket.
//!
//! This is deliberately independent of every device-side limiter. It bounds
//! remote connector abuse before a call enters the tunnel; local input and
//! host gates remain additional fail-closed checks.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

const TOKENS_PER_SECOND: f64 = 10.0;
const BURST_CAPACITY: f64 = 20.0;
const IDLE_EVICTION: Duration = Duration::from_secs(15 * 60);
const MAXIMUM_BUCKETS: usize = 10_000;

#[derive(Debug)]
struct Bucket {
    tokens: f64,
    last_refill: Instant,
    last_seen: Instant,
}

impl Bucket {
    fn new(now: Instant) -> Self {
        Self {
            tokens: BURST_CAPACITY,
            last_refill: now,
            last_seen: now,
        }
    }

    fn allow(&mut self, now: Instant) -> bool {
        let elapsed = now.duration_since(self.last_refill).as_secs_f64();
        self.tokens = (self.tokens + elapsed * TOKENS_PER_SECOND).min(BURST_CAPACITY);
        self.last_refill = now;
        self.last_seen = now;
        if self.tokens < 1.0 {
            return false;
        }
        self.tokens -= 1.0;
        true
    }
}

#[derive(Debug, Default)]
pub struct GatewayRateLimiter {
    buckets: Mutex<HashMap<String, Bucket>>,
}

impl GatewayRateLimiter {
    pub fn allow(&self, device_id: &str) -> Result<(), String> {
        self.allow_at(device_id, Instant::now())
    }

    fn allow_at(&self, device_id: &str, now: Instant) -> Result<(), String> {
        let mut buckets = self.buckets.lock().unwrap();
        if buckets.len() >= MAXIMUM_BUCKETS && !buckets.contains_key(device_id) {
            buckets.retain(|_, bucket| now.duration_since(bucket.last_seen) < IDLE_EVICTION);
            if buckets.len() >= MAXIMUM_BUCKETS {
                return Err("gateway rate-limit capacity reached; retry shortly".to_owned());
            }
        }
        let bucket = buckets
            .entry(device_id.to_owned())
            .or_insert_with(|| Bucket::new(now));
        if bucket.allow(now) {
            Ok(())
        } else {
            Err("gateway tool-call rate limit exceeded; retry shortly".to_owned())
        }
    }
}

#[derive(Debug)]
struct FixedWindow {
    started: Instant,
    count: u32,
}

impl FixedWindow {
    fn new(now: Instant) -> Self {
        Self {
            started: now,
            count: 0,
        }
    }

    fn allow(&mut self, now: Instant, duration: Duration, maximum: u32) -> bool {
        if now.duration_since(self.started) >= duration {
            self.started = now;
            self.count = 0;
        }
        if self.count >= maximum {
            return false;
        }
        self.count += 1;
        true
    }
}

/// Brute-force and anonymous-connection bounds for the six-digit link flow.
#[derive(Debug)]
pub struct LinkRateLimiter {
    confirm_sources: Mutex<HashMap<String, FixedWindow>>,
    confirm_global: Mutex<FixedWindow>,
    connection_sources: Mutex<HashMap<String, FixedWindow>>,
    connection_global: Mutex<FixedWindow>,
}

impl Default for LinkRateLimiter {
    fn default() -> Self {
        let now = Instant::now();
        Self {
            confirm_sources: Mutex::new(HashMap::new()),
            confirm_global: Mutex::new(FixedWindow::new(now)),
            connection_sources: Mutex::new(HashMap::new()),
            connection_global: Mutex::new(FixedWindow::new(now)),
        }
    }
}

impl LinkRateLimiter {
    const WINDOW: Duration = Duration::from_secs(5 * 60);
    const SOURCE_CONFIRM_MAXIMUM: u32 = 10;
    const GLOBAL_CONFIRM_MAXIMUM: u32 = 100;
    const SOURCE_CONNECTION_MAXIMUM: u32 = 3;
    const GLOBAL_CONNECTION_MAXIMUM: u32 = 32;

    pub fn allow_confirmation(&self, source: &str) -> Result<(), String> {
        self.allow_confirmation_at(source, Instant::now())
    }

    fn allow_confirmation_at(&self, source: &str, now: Instant) -> Result<(), String> {
        let mut sources = self.confirm_sources.lock().unwrap();
        prune_windows(&mut sources, now, Self::WINDOW);
        let window = sources
            .entry(source.to_owned())
            .or_insert_with(|| FixedWindow::new(now));
        if !window.allow(now, Self::WINDOW, Self::SOURCE_CONFIRM_MAXIMUM) {
            return Err("too many link attempts from this source; retry later".to_owned());
        }
        drop(sources);
        if !self.confirm_global.lock().unwrap().allow(
            now,
            Self::WINDOW,
            Self::GLOBAL_CONFIRM_MAXIMUM,
        ) {
            return Err("link confirmation capacity reached; retry later".to_owned());
        }
        Ok(())
    }

    pub fn allow_connection(&self, source: &str) -> Result<(), String> {
        let now = Instant::now();
        let mut sources = self.connection_sources.lock().unwrap();
        prune_windows(&mut sources, now, Self::WINDOW);
        let window = sources
            .entry(source.to_owned())
            .or_insert_with(|| FixedWindow::new(now));
        if !window.allow(now, Self::WINDOW, Self::SOURCE_CONNECTION_MAXIMUM) {
            return Err("too many link connections from this source; retry later".to_owned());
        }
        drop(sources);
        if !self.connection_global.lock().unwrap().allow(
            now,
            Self::WINDOW,
            Self::GLOBAL_CONNECTION_MAXIMUM,
        ) {
            return Err("pending link connection capacity reached; retry later".to_owned());
        }
        Ok(())
    }
}

#[derive(Debug)]
struct WindowClass {
    sources: Mutex<HashMap<String, FixedWindow>>,
    global: Mutex<FixedWindow>,
    source_maximum: u32,
    global_maximum: u32,
}

impl WindowClass {
    fn new(source_maximum: u32, global_maximum: u32) -> Self {
        Self {
            sources: Mutex::new(HashMap::new()),
            global: Mutex::new(FixedWindow::new(Instant::now())),
            source_maximum,
            global_maximum,
        }
    }

    fn allow(&self, source: &str, label: &str) -> Result<(), String> {
        let now = Instant::now();
        let duration = Duration::from_secs(5 * 60);
        let mut sources = self.sources.lock().unwrap();
        prune_windows(&mut sources, now, duration);
        let source_window = sources
            .entry(source.to_owned())
            .or_insert_with(|| FixedWindow::new(now));
        if !source_window.allow(now, duration, self.source_maximum) {
            return Err(format!("too many {label} requests from this source"));
        }
        drop(sources);
        if !self
            .global
            .lock()
            .unwrap()
            .allow(now, duration, self.global_maximum)
        {
            return Err(format!("global {label} request capacity reached"));
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct OAuthRateLimiter {
    registrations: WindowClass,
    authorizations: WindowClass,
    tokens: WindowClass,
    waits: WindowClass,
}

impl Default for OAuthRateLimiter {
    fn default() -> Self {
        Self {
            registrations: WindowClass::new(10, 100),
            authorizations: WindowClass::new(30, 500),
            tokens: WindowClass::new(60, 1_000),
            // The click-to-connect page polls every two seconds for up to
            // five minutes, so waiting polls get a generous per-source budget
            // that still bounds a scripted poller.
            waits: WindowClass::new(600, 12_000),
        }
    }
}

impl OAuthRateLimiter {
    pub fn allow_registration(&self, source: &str) -> Result<(), String> {
        self.registrations.allow(source, "client registration")
    }

    pub fn allow_authorization(&self, source: &str) -> Result<(), String> {
        self.authorizations.allow(source, "authorization")
    }

    pub fn allow_token(&self, source: &str) -> Result<(), String> {
        self.tokens.allow(source, "token")
    }

    pub fn allow_wait(&self, source: &str) -> Result<(), String> {
        self.waits.allow(source, "approval wait poll")
    }
}

#[derive(Debug, Default)]
pub struct SessionLimiter {
    counts: Mutex<HashMap<String, usize>>,
}

impl SessionLimiter {
    pub fn acquire(&self, device_id: &str) -> Result<(), String> {
        let mut counts = self.counts.lock().unwrap();
        let count = counts.entry(device_id.to_owned()).or_default();
        if *count >= crate::tunnel::MAXIMUM_REMOTE_SESSIONS {
            return Err("gateway MCP session limit reached for this device".to_owned());
        }
        *count += 1;
        Ok(())
    }

    pub fn release(&self, device_id: &str) {
        let mut counts = self.counts.lock().unwrap();
        if let Some(count) = counts.get_mut(device_id) {
            *count = count.saturating_sub(1);
            if *count == 0 {
                counts.remove(device_id);
            }
        }
    }

    #[cfg(test)]
    fn count(&self, device_id: &str) -> usize {
        self.counts
            .lock()
            .unwrap()
            .get(device_id)
            .copied()
            .unwrap_or(0)
    }
}

fn prune_windows(windows: &mut HashMap<String, FixedWindow>, now: Instant, duration: Duration) {
    if windows.len() > 1024 {
        windows.retain(|_, window| now.duration_since(window.started) < duration);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allows_burst_then_refills_independently() {
        let limiter = GatewayRateLimiter::default();
        let start = Instant::now();
        for _ in 0..20 {
            limiter.allow_at("dev_a", start).unwrap();
        }
        assert!(limiter.allow_at("dev_a", start).is_err());
        limiter.allow_at("dev_b", start).unwrap();
        limiter
            .allow_at("dev_a", start + Duration::from_millis(100))
            .unwrap();
        assert!(limiter
            .allow_at("dev_a", start + Duration::from_millis(100))
            .is_err());
    }

    #[test]
    fn idle_buckets_are_evictable() {
        let limiter = GatewayRateLimiter::default();
        let start = Instant::now();
        limiter.allow_at("dev_a", start).unwrap();
        let later = start + IDLE_EVICTION + Duration::from_secs(1);
        limiter
            .buckets
            .lock()
            .unwrap()
            .retain(|_, bucket| later.duration_since(bucket.last_seen) < IDLE_EVICTION);
        assert!(limiter.buckets.lock().unwrap().is_empty());
    }

    #[test]
    fn link_confirmations_are_source_and_globally_bounded() {
        let limiter = LinkRateLimiter::default();
        let start = Instant::now();
        for _ in 0..LinkRateLimiter::SOURCE_CONFIRM_MAXIMUM {
            limiter.allow_confirmation_at("source-a", start).unwrap();
        }
        let global_before_denied = limiter.confirm_global.lock().unwrap().count;
        for _ in 0..10 {
            assert!(limiter.allow_confirmation_at("source-a", start).is_err());
        }
        assert_eq!(
            limiter.confirm_global.lock().unwrap().count,
            global_before_denied,
            "source-denied requests must not consume global capacity"
        );
        assert!(limiter.allow_confirmation_at("source-b", start).is_ok());
        assert!(limiter
            .allow_confirmation_at("source-a", start + LinkRateLimiter::WINDOW)
            .is_ok());
    }

    #[test]
    fn link_connections_are_source_bounded() {
        let limiter = LinkRateLimiter::default();
        for _ in 0..LinkRateLimiter::SOURCE_CONNECTION_MAXIMUM {
            limiter.allow_connection("source-a").unwrap();
        }
        assert!(limiter.allow_connection("source-a").is_err());
        assert!(limiter.allow_connection("source-b").is_ok());
    }

    #[test]
    fn oauth_endpoints_are_source_bounded() {
        let limiter = OAuthRateLimiter::default();
        for _ in 0..10 {
            limiter.allow_registration("source-a").unwrap();
        }
        assert!(limiter.allow_registration("source-a").is_err());
        assert!(limiter.allow_registration("source-b").is_ok());
        for _ in 0..30 {
            limiter.allow_authorization("source-c").unwrap();
        }
        assert!(limiter.allow_authorization("source-c").is_err());
    }

    #[test]
    fn mcp_sessions_are_bounded_per_device_and_released() {
        let limiter = SessionLimiter::default();
        for _ in 0..crate::tunnel::MAXIMUM_REMOTE_SESSIONS {
            limiter.acquire("dev_a").unwrap();
        }
        assert!(limiter.acquire("dev_a").is_err());
        limiter.acquire("dev_b").unwrap();
        limiter.release("dev_a");
        assert_eq!(
            limiter.count("dev_a"),
            crate::tunnel::MAXIMUM_REMOTE_SESSIONS - 1
        );
        limiter.acquire("dev_a").unwrap();
    }
}
