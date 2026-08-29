//! Hosted gateway for remote MCP connectors (ChatGPT and compatible
//! clients).
//!
//! Relay mode is a pure authenticated router: it terminates Streamable HTTP
//! with OAuth 2.1, enforces per-tool scopes, and forwards whole MCP sessions to
//! the user's own `thumble-mcp --relay` over an outbound tunnel. The separate
//! hosted-builder mode stores bounded, expiring pre-adoption workspaces and
//! portable artifacts under resource-isolated builder principals. It has no
//! tunnel, input, phone-sync, or adopted-configuration authority; explicit
//! artifact import into `thumble-host` remains the adoption boundary. OAuth
//! and share credentials are persisted only as digests.

pub mod builder;
pub mod builder_store;
pub mod http;
pub mod oauth;
pub mod principal;
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

/// Complete the checked, bounded startup prune before constructing a router.
/// Errors are deliberately audited without database paths, SQL, or row data
/// and fail readiness closed.
pub async fn app_after_startup_prune(state: Arc<AppState>) -> Result<axum::Router, String> {
    let store = state.store.clone();
    let permit = state
        .builder_work_semaphore
        .clone()
        .acquire_owned()
        .await
        .map_err(|_| "startup builder work limiter unavailable".to_owned())?;
    match tokio::task::spawn_blocking(move || {
        let _permit = permit;
        store.prune_builder_storage()
    })
    .await
    {
        Ok(Ok(())) => Ok(app(state)),
        Ok(Err(_)) | Err(_) => {
            eprintln!("gateway: builder-prune phase=startup outcome=storage-error");
            Err("startup builder storage pruning failed".to_owned())
        }
    }
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
    async fn startup_prune_completes_before_router_readiness_and_is_idempotent() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("startup-prune.db");
        let store =
            Arc::new(store::Store::open(&path, "startup-prune-secret-at-least-32-bytes").unwrap());
        let builder = store.create_builder_principal("Startup prune").unwrap();
        let session = thumble_builder::BuilderSession::begin(
            "00000000-0000-4000-8000-000000000001",
            store::Store::now(),
            3600,
        )
        .unwrap();
        store.create_builder_workspace(&builder, &session).unwrap();
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection
            .execute(
                "UPDATE builder_workspaces SET expires_at = 0 WHERE principal_id = ?1",
                rusqlite::params![builder],
            )
            .unwrap();
        drop(connection);
        let state = Arc::new(AppState::new(
            store.clone(),
            tunnel::TunnelRegistry::new(),
            "https://mcp.thumble.app".to_owned(),
        ));
        let _router = app_after_startup_prune(state.clone()).await.unwrap();
        assert!(matches!(
            store.load_builder_workspace(&builder, session.session_id()),
            Err(builder_store::BuilderStoreError::NotFound)
        ));
        let _router = app_after_startup_prune(state).await.unwrap();
    }

    #[tokio::test]
    async fn startup_prune_fails_closed_with_a_bounded_error() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("startup-prune-error.db");
        let store = Arc::new(
            store::Store::open(&path, "startup-prune-error-secret-at-least-32-bytes").unwrap(),
        );
        let connection = rusqlite::Connection::open(&path).unwrap();
        connection.execute("DROP TABLE builder_shares", []).unwrap();
        drop(connection);
        let state = Arc::new(AppState::new(
            store,
            tunnel::TunnelRegistry::new(),
            "https://mcp.thumble.app".to_owned(),
        ));
        assert_eq!(
            app_after_startup_prune(state).await.unwrap_err(),
            "startup builder storage pruning failed"
        );
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
