use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use thumble_gateway::state::AppState;
use thumble_gateway::store::Store;
use thumble_gateway::tunnel::TunnelRegistry;

const BIND_ENV: &str = "THUMBLE_GATEWAY_BIND";
const BASE_URL_ENV: &str = "THUMBLE_GATEWAY_BASE_URL";
const DB_ENV: &str = "THUMBLE_GATEWAY_DB";
const TOKEN_SECRET_ENV: &str = "THUMBLE_GATEWAY_TOKEN_SECRET";

fn environment(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|value| !value.is_empty())
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("thumble-gateway stopped: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let bind = environment(BIND_ENV).unwrap_or_else(|| "0.0.0.0:8080".to_owned());
    let base_url = environment(BASE_URL_ENV)
        .ok_or_else(|| format!("{BASE_URL_ENV} is required (use https:// outside loopback)"))?;
    let parsed_base =
        url::Url::parse(&base_url).map_err(|error| format!("parse {BASE_URL_ENV}: {error}"))?;
    let loopback = matches!(
        parsed_base.host_str(),
        Some("localhost" | "127.0.0.1" | "::1")
    );
    if parsed_base.scheme() != "https" && !(parsed_base.scheme() == "http" && loopback) {
        return Err(format!(
            "{BASE_URL_ENV} must use https:// outside loopback development"
        ));
    }
    let database = environment(DB_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("thumble-gateway.db"));
    let token_secret = environment(TOKEN_SECRET_ENV).ok_or_else(|| {
        format!("{TOKEN_SECRET_ENV} is required and must contain at least 32 characters")
    })?;

    let mut store = Store::open(&database, &token_secret)?;
    if let Some(grace) = environment("THUMBLE_GATEWAY_REFRESH_GRACE_SECONDS") {
        let seconds: i64 = grace
            .parse()
            .map_err(|_| "THUMBLE_GATEWAY_REFRESH_GRACE_SECONDS must be 0-3600")?;
        if !(0..=3600).contains(&seconds) {
            return Err("THUMBLE_GATEWAY_REFRESH_GRACE_SECONDS must be 0-3600".to_owned());
        }
        store = store.with_refresh_grace(seconds);
    }
    let store = Arc::new(store);
    let state = Arc::new(AppState::new(
        store.clone(),
        TunnelRegistry::new(),
        base_url.clone(),
    ));
    // Readiness fails closed until the checked bounded startup prune completes;
    // router construction (and therefore serving) happens only afterward.
    let router = thumble_gateway::app_after_startup_prune(state.clone()).await?;

    let address: SocketAddr = bind
        .parse()
        .map_err(|error| format!("parse bind address {bind}: {error}"))?;
    let listener = tokio::net::TcpListener::bind(address)
        .await
        .map_err(|error| format!("bind {bind}: {error}"))?;

    // Keep bounded periodic maintenance after the checked startup pass. The
    // task is aborted explicitly when the server shuts down.
    let maintenance_store = store.clone();
    let maintenance_work = state.builder_work_semaphore.clone();
    let maintenance = tokio::spawn(async move {
        loop {
            let store = maintenance_store.clone();
            let permit = match maintenance_work.clone().acquire_owned().await {
                Ok(permit) => permit,
                Err(_) => break,
            };
            match tokio::task::spawn_blocking(move || {
                let _permit = permit;
                store.prune_builder_storage()
            })
            .await
            {
                Ok(Ok(())) => {}
                Ok(Err(_)) | Err(_) => {
                    eprintln!("gateway: builder-prune phase=periodic outcome=storage-error")
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(15 * 60)).await;
        }
    });

    eprintln!(
        "thumble-gateway listening on http://{bind} (public base {base_url}, database {})",
        database.display()
    );
    let result = axum::serve(
        listener,
        router.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(async {
        let _ = tokio::signal::ctrl_c().await;
        eprintln!("thumble-gateway shutting down");
    })
    .await
    .map_err(|error| format!("serve gateway: {error}"));
    maintenance.abort();
    result
}
