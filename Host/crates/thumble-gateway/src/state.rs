//! Shared gateway application state.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::rate_limit::{
    BuilderToolRateLimiter, GatewayRateLimiter, LinkRateLimiter, OAuthRateLimiter, SessionLimiter,
    ShareRateLimiter,
};
use crate::store::Store;
use crate::tunnel::TunnelRegistry;

pub struct AppState {
    pub store: Arc<Store>,
    pub tunnels: Arc<TunnelRegistry>,
    pub rate_limiter: GatewayRateLimiter,
    pub link_rate_limiter: LinkRateLimiter,
    pub oauth_rate_limiter: OAuthRateLimiter,
    pub session_limiter: SessionLimiter,
    pub builder_session_limiter: SessionLimiter,
    pub builder_tool_rate_limiter: BuilderToolRateLimiter,
    pub share_rate_limiter: ShareRateLimiter,
    /// Process-wide bound for every blocking builder decode/database job.
    pub builder_work_semaphore: Arc<tokio::sync::Semaphore>,
    /// Stricter subset bound for builder mutations; work is always acquired first.
    pub builder_mutation_semaphore: Arc<tokio::sync::Semaphore>,
    pub mcp_session_bindings: McpSessionBindings,
    pub builder_mcp_session_bindings: McpSessionBindings,
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
            // Relay keeps its existing per-device bound and gains a
            // conservative process-wide ceiling. Builder sessions are
            // independently bounded by stable principal identity.
            session_limiter: SessionLimiter::new(crate::tunnel::MAXIMUM_REMOTE_SESSIONS, 256),
            builder_session_limiter: SessionLimiter::new(4, 100),
            builder_tool_rate_limiter: BuilderToolRateLimiter::default(),
            share_rate_limiter: ShareRateLimiter::default(),
            builder_work_semaphore: Arc::new(tokio::sync::Semaphore::new(8)),
            builder_mutation_semaphore: Arc::new(tokio::sync::Semaphore::new(4)),
            mcp_session_bindings: McpSessionBindings::default(),
            builder_mcp_session_bindings: McpSessionBindings::default(),
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
    owner_key: String,
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

    /// Bind a transport session to a caller-selected stable ownership key.
    /// Relay passes its access-token digest for compatibility; Builder passes
    /// its validated principal ID so access-token refresh can continue.
    pub fn bind(&self, session_id: &str, owner_key: &str) -> bool {
        let now = Self::now();
        let mut bindings = self.bindings.lock().unwrap();
        Self::prune(&mut bindings, now);
        match bindings.get(session_id) {
            Some(binding) => binding.owner_key == owner_key,
            None => {
                bindings.insert(
                    session_id.to_owned(),
                    McpSessionBinding {
                        owner_key: owner_key.to_owned(),
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

    pub fn owns(&self, session_id: &str, owner_key: &str) -> bool {
        let now = Self::now();
        let mut bindings = self.bindings.lock().unwrap();
        Self::prune(&mut bindings, now);
        bindings
            .get(session_id)
            .is_some_and(|binding| binding.owner_key == owner_key)
    }

    pub fn remove(&self, session_id: &str, owner_key: &str) {
        let mut bindings = self.bindings.lock().unwrap();
        if bindings
            .get(session_id)
            .is_some_and(|binding| binding.owner_key == owner_key)
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BuilderTokenIdentity {
    pub builder_id: String,
    pub scope: String,
}
