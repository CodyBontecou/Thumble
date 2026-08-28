//! Hosted gateway for remote MCP connectors (ChatGPT and compatible
//! clients).
//!
//! The gateway is a pure authenticated router: it terminates Streamable
//! HTTP with OAuth 2.1, enforces per-tool scopes, and forwards whole MCP
//! sessions to the user's own `thumble-mcp --relay` over an outbound
//! tunnel. It never receives host `ControlResponse` payloads directly,
//! never stores profiles or credentials, and never becomes a configuration
//! authority — the Rust host on the user's Mac keeps that role.

pub mod http;
pub mod oauth;
pub mod proxy;
pub mod rate_limit;
pub mod scopes;
pub mod state;
pub mod store;
pub mod tunnel;

pub use state::AppState;

use std::sync::Arc;

/// Build the complete gateway router over a store and tunnel registry.
pub fn app(state: Arc<AppState>) -> axum::Router {
    http::router(state)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn app_builds_with_an_in_memory_store() {
        let state = Arc::new(AppState::new(
            Arc::new(store::Store::open_in_memory().unwrap()),
            tunnel::TunnelRegistry::new(),
            "https://mcp.thumble.app".to_owned(),
        ));
        let _router = app(state);
    }

    #[tokio::test]
    async fn https_deployments_emit_hsts_and_browser_security_headers() {
        use tower::ServiceExt as _;
        let state = Arc::new(AppState::new(
            Arc::new(store::Store::open_in_memory().unwrap()),
            tunnel::TunnelRegistry::new(),
            "https://mcp.thumble.app".to_owned(),
        ));
        let response = app(state)
            .oneshot(
                axum::http::Request::builder()
                    .uri("/healthz")
                    .body(axum::body::Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), axum::http::StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get(axum::http::header::STRICT_TRANSPORT_SECURITY)
                .unwrap(),
            "max-age=31536000; includeSubDomains"
        );
        assert!(response
            .headers()
            .contains_key(axum::http::header::CONTENT_SECURITY_POLICY));
    }
}
