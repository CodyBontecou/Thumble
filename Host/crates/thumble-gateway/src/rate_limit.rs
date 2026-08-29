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
const MAXIMUM_WINDOW_KEYS: usize = 4_096;

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

/// Builder calls use a separate bucket namespace from relay calls even when a
/// deployment happens to reuse a textual principal identifier.
#[derive(Debug, Default)]
pub struct BuilderToolRateLimiter {
    inner: GatewayRateLimiter,
}

impl BuilderToolRateLimiter {
    pub fn allow(&self, principal_id: &str) -> Result<(), String> {
        self.inner.allow(principal_id)
    }
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
    maximum_keys: usize,
}

impl WindowClass {
    fn new(source_maximum: u32, global_maximum: u32) -> Self {
        Self::with_key_cap(source_maximum, global_maximum, MAXIMUM_WINDOW_KEYS)
    }

    fn with_key_cap(source_maximum: u32, global_maximum: u32, maximum_keys: usize) -> Self {
        Self {
            sources: Mutex::new(HashMap::new()),
            global: Mutex::new(FixedWindow::new(Instant::now())),
            source_maximum,
            global_maximum,
            maximum_keys,
        }
    }

    fn allow(&self, source: &str, label: &str) -> Result<(), String> {
        self.allow_at(source, label, Instant::now())
    }

    fn allow_at(&self, source: &str, label: &str, now: Instant) -> Result<(), String> {
        let duration = Duration::from_secs(5 * 60);
        // Every WindowClass follows one lock order: source map, then global.
        // Preflight the source and hard map cap without charging either
        // window. Only after both preflights pass do we charge global and then
        // the source while retaining both locks, so a rejected source cannot
        // consume aggregate capacity and concurrent calls remain exact.
        let mut sources = self.sources.lock().unwrap();
        prune_windows(&mut sources, now, duration);
        if !sources.contains_key(source) && sources.len() >= self.maximum_keys {
            return Err(format!("{label} request key capacity reached"));
        }
        if let Some(window) = sources.get_mut(source) {
            if now.duration_since(window.started) >= duration {
                window.started = now;
                window.count = 0;
            }
            if window.count >= self.source_maximum {
                return Err(format!("too many {label} requests from this source"));
            }
        }
        let mut global = self.global.lock().unwrap();
        if !global.allow(now, duration, self.global_maximum) {
            return Err(format!("global {label} request capacity reached"));
        }
        let source_window = sources
            .entry(source.to_owned())
            .or_insert_with(|| FixedWindow::new(now));
        let source_accepted = source_window.allow(now, duration, self.source_maximum);
        debug_assert!(source_accepted);
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

/// Share credentials are bounded independently by network source and token
/// digest. This prevents token swapping from bypassing a source limit and
/// distributed reuse of one credential from bypassing a credential limit.
#[derive(Debug)]
pub struct ShareRateLimiter {
    sources: Mutex<HashMap<String, FixedWindow>>,
    source_global: Mutex<FixedWindow>,
    token_digests: Mutex<HashMap<String, FixedWindow>>,
    token_global: Mutex<FixedWindow>,
    maximum_keys: usize,
    source_global_maximum: u32,
    token_global_maximum: u32,
}

impl Default for ShareRateLimiter {
    fn default() -> Self {
        let now = Instant::now();
        Self {
            sources: Mutex::new(HashMap::new()),
            source_global: Mutex::new(FixedWindow::new(now)),
            token_digests: Mutex::new(HashMap::new()),
            token_global: Mutex::new(FixedWindow::new(now)),
            maximum_keys: MAXIMUM_WINDOW_KEYS,
            source_global_maximum: Self::SOURCE_MAXIMUM * MAXIMUM_WINDOW_KEYS as u32,
            token_global_maximum: Self::TOKEN_MAXIMUM * MAXIMUM_WINDOW_KEYS as u32,
        }
    }
}

impl ShareRateLimiter {
    const WINDOW: Duration = Duration::from_secs(60);
    pub const SOURCE_MAXIMUM: u32 = 60;
    pub const TOKEN_MAXIMUM: u32 = 30;

    /// Charge the network source before parsing any attacker-controlled
    /// artifact or credential value.
    pub fn allow_source(&self, source: &str) -> Result<(), String> {
        Self::allow_keyed(
            &self.source_global,
            &self.sources,
            source,
            Self::SOURCE_MAXIMUM,
            self.source_global_maximum,
            self.maximum_keys,
            Instant::now(),
        )
    }

    /// Charge a validated credential independently, so distributed reuse of
    /// one share token remains bounded.
    pub fn allow_token(&self, token_digest: &str) -> Result<(), String> {
        Self::allow_keyed(
            &self.token_global,
            &self.token_digests,
            token_digest,
            Self::TOKEN_MAXIMUM,
            self.token_global_maximum,
            self.maximum_keys,
            Instant::now(),
        )
    }

    fn allow_keyed(
        global: &Mutex<FixedWindow>,
        windows: &Mutex<HashMap<String, FixedWindow>>,
        key: &str,
        maximum: u32,
        global_maximum: u32,
        maximum_keys: usize,
        now: Instant,
    ) -> Result<(), String> {
        // Reject aggregate overload before an attacker-controlled key can
        // enter either share map.
        if !global
            .lock()
            .unwrap()
            .allow(now, Self::WINDOW, global_maximum)
        {
            return Err("global share read capacity reached".to_owned());
        }
        let mut windows = windows.lock().unwrap();
        prune_windows(&mut windows, now, Self::WINDOW);
        if !windows.contains_key(key) && windows.len() >= maximum_keys {
            return Err("share read rate-limit capacity reached".to_owned());
        }
        let window = windows
            .entry(key.to_owned())
            .or_insert_with(|| FixedWindow::new(now));
        if !window.allow(now, Self::WINDOW, maximum) {
            return Err("share read rate limit exceeded".to_owned());
        }
        Ok(())
    }
}

#[derive(Debug)]
pub struct SessionLimiter {
    counts: Mutex<SessionCounts>,
    per_key_maximum: usize,
    global_maximum: usize,
}

#[derive(Debug, Default)]
struct SessionCounts {
    by_key: HashMap<String, usize>,
    total: usize,
}

impl SessionLimiter {
    pub fn new(per_key_maximum: usize, global_maximum: usize) -> Self {
        assert!(per_key_maximum > 0);
        assert!(global_maximum > 0);
        Self {
            counts: Mutex::new(SessionCounts::default()),
            per_key_maximum,
            global_maximum,
        }
    }

    pub fn acquire(&self, key: &str) -> Result<(), String> {
        let mut counts = self.counts.lock().unwrap();
        if counts.total >= self.global_maximum {
            return Err("gateway MCP global session limit reached".to_owned());
        }
        if counts.by_key.get(key).copied().unwrap_or(0) >= self.per_key_maximum {
            return Err("gateway MCP session limit reached for this identity".to_owned());
        }
        // No key is inserted until both limits have accepted the session.
        *counts.by_key.entry(key.to_owned()).or_default() += 1;
        counts.total += 1;
        Ok(())
    }

    pub fn release(&self, key: &str) {
        let mut counts = self.counts.lock().unwrap();
        if let Some(count) = counts.by_key.get_mut(key) {
            *count -= 1;
            let remove = *count == 0;
            counts.total -= 1;
            if remove {
                counts.by_key.remove(key);
            }
        }
    }

    #[cfg(test)]
    fn count(&self, device_id: &str) -> usize {
        self.counts
            .lock()
            .unwrap()
            .by_key
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
    fn oauth_endpoints_are_source_bounded_without_spending_global_capacity() {
        let limiter = OAuthRateLimiter::default();
        for _ in 0..10 {
            limiter.allow_registration("source-a").unwrap();
        }
        let global_before_denials = limiter.registrations.global.lock().unwrap().count;
        for _ in 0..100 {
            assert!(limiter.allow_registration("source-a").is_err());
        }
        assert_eq!(
            limiter.registrations.global.lock().unwrap().count,
            global_before_denials
        );
        assert!(limiter.allow_registration("source-b").is_ok());
        for _ in 0..30 {
            limiter.allow_authorization("source-c").unwrap();
        }
        assert!(limiter.allow_authorization("source-c").is_err());
    }

    #[test]
    fn oauth_map_cap_rejection_does_not_charge_global_and_global_cap_is_exact() {
        let now = Instant::now();
        let limiter = WindowClass::with_key_cap(2, 3, 2);
        limiter.allow_at("source-a", "test", now).unwrap();
        limiter.allow_at("source-b", "test", now).unwrap();
        let before = limiter.global.lock().unwrap().count;
        assert!(limiter.allow_at("source-c", "test", now).is_err());
        assert_eq!(limiter.global.lock().unwrap().count, before);
        limiter.allow_at("source-a", "test", now).unwrap();
        assert_eq!(limiter.global.lock().unwrap().count, 3);
        assert!(limiter.allow_at("source-b", "test", now).is_err());
        assert_eq!(limiter.global.lock().unwrap().count, 3);
    }

    #[test]
    fn concurrent_oauth_acceptance_never_exceeds_either_window() {
        use std::sync::{Arc, Barrier};

        let limiter = Arc::new(WindowClass::with_key_cap(100, 17, 100));
        let barrier = Arc::new(Barrier::new(65));
        let handles = (0..64)
            .map(|index| {
                let limiter = limiter.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    limiter.allow_at(&format!("source-{index}"), "test", Instant::now())
                })
            })
            .collect::<Vec<_>>();
        barrier.wait();
        let accepted = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .filter(Result::is_ok)
            .count();
        assert_eq!(accepted, 17);
        assert_eq!(limiter.global.lock().unwrap().count, 17);
        assert_eq!(limiter.sources.lock().unwrap().len(), 17);
    }

    #[test]
    fn share_reads_are_independently_bounded() {
        let limiter = ShareRateLimiter::default();
        for _ in 0..ShareRateLimiter::TOKEN_MAXIMUM {
            limiter.allow_source("source-a").unwrap();
            limiter.allow_token("digest-a").unwrap();
        }
        limiter.allow_source("source-b").unwrap();
        assert!(limiter.allow_token("digest-a").is_err());
        limiter.allow_token("digest-b").unwrap();
    }

    #[test]
    fn attacker_keyed_window_maps_are_hard_bounded() {
        let oauth = WindowClass::with_key_cap(10, 100, 2);
        let now = Instant::now();
        oauth.allow_at("source-a", "test", now).unwrap();
        oauth.allow_at("source-b", "test", now).unwrap();
        assert!(oauth.allow_at("source-c", "test", now).is_err());
        assert_eq!(oauth.sources.lock().unwrap().len(), 2);

        let shares = ShareRateLimiter {
            sources: Mutex::new(HashMap::new()),
            source_global: Mutex::new(FixedWindow::new(now)),
            token_digests: Mutex::new(HashMap::new()),
            token_global: Mutex::new(FixedWindow::new(now)),
            maximum_keys: 2,
            source_global_maximum: 100,
            token_global_maximum: 100,
        };
        shares.allow_source("source-a").unwrap();
        shares.allow_source("source-b").unwrap();
        assert!(shares.allow_source("source-c").is_err());
        assert_eq!(shares.sources.lock().unwrap().len(), 2);
    }

    #[test]
    fn global_window_caps_reject_before_inserting_attacker_keys() {
        let now = Instant::now();
        let oauth = WindowClass::with_key_cap(10, 2, 10);
        oauth.allow_at("source-a", "test", now).unwrap();
        oauth.allow_at("source-b", "test", now).unwrap();
        assert!(oauth.allow_at("source-c", "test", now).is_err());
        assert_eq!(oauth.sources.lock().unwrap().len(), 2);

        let shares = ShareRateLimiter {
            sources: Mutex::new(HashMap::new()),
            source_global: Mutex::new(FixedWindow::new(now)),
            token_digests: Mutex::new(HashMap::new()),
            token_global: Mutex::new(FixedWindow::new(now)),
            maximum_keys: 10,
            source_global_maximum: 2,
            token_global_maximum: 2,
        };
        shares.allow_source("source-a").unwrap();
        shares.allow_source("source-b").unwrap();
        assert!(shares.allow_source("source-c").is_err());
        assert_eq!(shares.sources.lock().unwrap().len(), 2);
        shares.allow_token("digest-a").unwrap();
        shares.allow_token("digest-b").unwrap();
        assert!(shares.allow_token("digest-c").is_err());
        assert_eq!(shares.token_digests.lock().unwrap().len(), 2);
    }

    #[test]
    fn mcp_sessions_are_bounded_per_key_and_globally_then_recover() {
        let limiter = SessionLimiter::new(2, 3);
        limiter.acquire("dev_a").unwrap();
        limiter.acquire("dev_a").unwrap();
        assert!(limiter.acquire("dev_a").is_err());
        limiter.acquire("dev_b").unwrap();
        assert!(limiter.acquire("sybil-c").is_err());
        assert!(!limiter
            .counts
            .lock()
            .unwrap()
            .by_key
            .contains_key("sybil-c"));
        limiter.release("dev_a");
        assert_eq!(limiter.count("dev_a"), 1);
        limiter.acquire("sybil-c").unwrap();
        limiter.release("dev_a");
        limiter.release("dev_b");
        limiter.release("sybil-c");
        let counts = limiter.counts.lock().unwrap();
        assert_eq!(counts.total, 0);
        assert!(counts.by_key.is_empty());
    }
}
