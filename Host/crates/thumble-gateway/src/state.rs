//! Shared gateway application state.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::rate_limit::{GatewayRateLimiter, LinkRateLimiter, OAuthRateLimiter, SessionLimiter};
use crate::store::Store;
use crate::tunnel::TunnelRegistry;

pub struct AppState {
    pub store: Arc<Store>,
    pub tunnels: Arc<TunnelRegistry>,
    pub rate_limiter: GatewayRateLimiter,
    pub link_rate_limiter: LinkRateLimiter,
    pub oauth_rate_limiter: OAuthRateLimiter,
    pub session_limiter: SessionLimiter,
    pub mcp_session_bindings: McpSessionBindings,
    base_url: std::sync::RwLock<String>,
}

impl AppState {
    pub fn new(store: Arc<Store>, tunnels: Arc<TunnelRegistry>, base_url: String) -> Self {
        Self {
            store,
            tunnels,
            rate_limiter: GatewayRateLimiter::default(),
            link_rate_limiter: LinkRateLimiter::default(),
            oauth_rate_limiter: OAuthRateLimiter::default(),
            session_limiter: SessionLimiter::default(),
            mcp_session_bindings: McpSessionBindings::default(),
            base_url: std::sync::RwLock::new(base_url),
        }
    }

    /// Canonical external base URL, e.g. https://mcp.thumble.app
    pub fn base_url(&self) -> String {
        self.base_url.read().unwrap().clone()
    }

    /// Tests bind an ephemeral port and adjust the advertised base URL
    /// before any traffic. Production binaries construct with the final URL.
    pub fn set_base_url(&self, base_url: String) {
        *self.base_url.write().unwrap() = base_url;
    }
}

#[derive(Debug)]
struct McpSessionBinding {
    access_token_digest: String,
    prune_after: i64,
}

#[derive(Debug, Default)]
pub struct McpSessionBindings {
    bindings: Mutex<HashMap<String, McpSessionBinding>>,
}

impl McpSessionBindings {
    fn now() -> i64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|duration| duration.as_secs() as i64)
            .unwrap_or(0)
    }

    fn prune(bindings: &mut HashMap<String, McpSessionBinding>, now: i64) {
        bindings.retain(|_, binding| binding.prune_after >= now);
    }

    pub fn bind(&self, session_id: &str, access_token_digest: &str) -> bool {
        let now = Self::now();
        let mut bindings = self.bindings.lock().unwrap();
        Self::prune(&mut bindings, now);
        match bindings.get(session_id) {
            Some(binding) => binding.access_token_digest == access_token_digest,
            None => {
                bindings.insert(
                    session_id.to_owned(),
                    McpSessionBinding {
                        access_token_digest: access_token_digest.to_owned(),
                        // Access tokens currently live for at most 15 minutes.
                        // Bearer validation still runs first, so a shorter-lived
                        // token cannot use this stale in-memory binding.
                        prune_after: now + 15 * 60,
                    },
                );
                true
            }
        }
    }

    pub fn owns(&self, session_id: &str, access_token_digest: &str) -> bool {
        let now = Self::now();
        let mut bindings = self.bindings.lock().unwrap();
        Self::prune(&mut bindings, now);
        bindings
            .get(session_id)
            .is_some_and(|binding| binding.access_token_digest == access_token_digest)
    }

    pub fn remove(&self, session_id: &str, access_token_digest: &str) {
        let mut bindings = self.bindings.lock().unwrap();
        if bindings
            .get(session_id)
            .is_some_and(|binding| binding.access_token_digest == access_token_digest)
        {
            bindings.remove(session_id);
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TokenIdentity {
    pub device_id: String,
    pub scope: String,
}
