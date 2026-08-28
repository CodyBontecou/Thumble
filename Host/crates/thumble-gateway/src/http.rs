//! HTTP surface: OAuth endpoints, well-known metadata, device tunnels, and
//! the authenticated Streamable-HTTP `/mcp` endpoint backed by
//! [`crate::proxy::RelayProxy`].

use std::net::SocketAddr;
use std::sync::Arc;

use axum::extract::ws::{Message as WsMessage, WebSocket};
use axum::extract::{ConnectInfo, Path, State, WebSocketUpgrade};
use axum::http::{header, Request, StatusCode};
use axum::middleware::Next;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};

use rmcp::service::{RxJsonRpcMessage, TxJsonRpcMessage};
use rmcp::transport::sink_stream::SinkStreamTransport;
use rmcp::transport::streamable_http_server::session::local::{LocalSessionManager, SessionConfig};
use rmcp::transport::streamable_http_server::tower::StreamableHttpServerConfig;
use rmcp::transport::streamable_http_server::StreamableHttpService;
use rmcp::RoleClient;

use crate::oauth;
use crate::proxy::RelayProxy;
use crate::state::{AppState, TokenIdentity};

use crate::tunnel::{serve_control_frames, serve_link_frames, serve_revoke_frames};

/// Extract the bearer token from an Authorization header.
pub(crate) fn client_source_key(
    headers: &axum::http::HeaderMap,
    connect_info: Option<&ConnectInfo<SocketAddr>>,
) -> String {
    let trust_fly_header = std::env::var_os("FLY_APP_NAME").is_some()
        || std::env::var("THUMBLE_GATEWAY_TRUST_FLY_CLIENT_IP").as_deref() == Ok("1");
    client_source_key_with_trust(headers, connect_info, trust_fly_header)
}

fn client_source_key_with_trust(
    headers: &axum::http::HeaderMap,
    connect_info: Option<&ConnectInfo<SocketAddr>>,
    trust_fly_header: bool,
) -> String {
    if trust_fly_header {
        if let Some(address) = headers
            .get("Fly-Client-IP")
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.parse::<std::net::IpAddr>().ok())
        {
            return address.to_string();
        }
    }
    connect_info
        .map(|info| info.0.ip().to_string())
        .unwrap_or_else(|| "unknown-source".to_owned())
}

pub fn bearer_token(headers: &axum::http::HeaderMap) -> Option<String> {
    let value = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let token = value.strip_prefix("Bearer ")?.trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_owned())
    }
}

async fn auth_mcp(
    State(state): State<Arc<AppState>>,
    mut request: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let token = match bearer_token(request.headers()) {
        Some(token) => token,
        None => return unauthorized(&state.base_url()),
    };
    let record = match state.store.access_token(&token) {
        Ok(Some(record)) => record,
        Ok(None) => return unauthorized(&state.base_url()),
        Err(error) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": "server_error", "detail": error})),
            )
                .into_response()
        }
    };
    let access_token_digest = thumble_tunnel::token_digest(&token);
    let requested_session_id = match request.headers().get("mcp-session-id") {
        Some(value) => match value.to_str() {
            Ok(value) if !value.is_empty() => Some(value.to_owned()),
            _ => {
                return (
                    StatusCode::BAD_REQUEST,
                    Json(serde_json::json!({"error": "invalid_mcp_session_id"})),
                )
                    .into_response()
            }
        },
        None => None,
    };
    if requested_session_id.as_deref().is_some_and(|session_id| {
        !state
            .mcp_session_bindings
            .owns(session_id, &access_token_digest)
    }) {
        return (
            StatusCode::FORBIDDEN,
            Json(serde_json::json!({
                "error": "mcp_session_identity_mismatch",
                "detail": "the MCP session is bound to a different token identity"
            })),
        )
            .into_response();
    }

    let method = request.method().clone();
    request.extensions_mut().insert(Arc::new(TokenIdentity {
        device_id: record.device_id,
        scope: record.scope,
    }));
    let response = next.run(request).await;

    if response.status().is_success() {
        if let Some(session_id) = response
            .headers()
            .get("mcp-session-id")
            .and_then(|value| value.to_str().ok())
        {
            if !state
                .mcp_session_bindings
                .bind(session_id, &access_token_digest)
            {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({"error": "mcp_session_binding_conflict"})),
                )
                    .into_response();
            }
        }
    }
    if method == axum::http::Method::DELETE {
        if let Some(session_id) = requested_session_id {
            state
                .mcp_session_bindings
                .remove(&session_id, &access_token_digest);
        }
    }
    response
}

fn unauthorized(base_url: &str) -> Response {
    let challenge = format!(
        "Bearer error=\"invalid_token\", resource_metadata=\"{}/.well-known/oauth-protected-resource\", scope=\"thumble.read thumble.draft thumble.config offline_access\"",
        base_url.trim_end_matches('/')
    );
    (
        StatusCode::UNAUTHORIZED,
        [(header::WWW_AUTHENTICATE, challenge)],
        Json(serde_json::json!({"error": "invalid_token"})),
    )
        .into_response()
}

fn mcp_service(state: Arc<AppState>) -> StreamableHttpService<RelayProxy, LocalSessionManager> {
    let base_url = state.base_url();
    let parsed_base = url::Url::parse(&base_url).ok();
    let allowed_hosts = parsed_base
        .as_ref()
        .and_then(|url| url.host_str())
        .map(|host| {
            let mut hosts = vec![host.to_owned()];
            if let Some(port) = parsed_base.as_ref().and_then(url::Url::port) {
                hosts.push(format!("{host}:{port}"));
            }
            hosts
        })
        .unwrap_or_else(|| vec!["localhost".to_owned(), "127.0.0.1".to_owned()]);
    let mut session_config = SessionConfig::default();
    session_config.keep_alive = Some(std::time::Duration::from_secs(300));
    let mut manager = LocalSessionManager::default();
    manager.session_config = session_config;
    let config = StreamableHttpServerConfig::default()
        .with_legacy_session_mode(true)
        .with_json_response(true)
        .with_allowed_hosts(allowed_hosts)
        .with_allowed_origins([
            base_url,
            "https://chatgpt.com".to_owned(),
            "https://chat.openai.com".to_owned(),
        ]);
    StreamableHttpService::new(
        move || Ok(RelayProxy::new(state.clone())),
        Arc::new(manager),
        config,
    )
}

// ---- Axum WebSocket plumbing ----------------------------------------------
//
// The tunnel crate speaks tokio-tungstenite; axum has its own WebSocket
// type. Rather than bridging sockets, we implement the same rmcp
// Sink/Stream adapters directly over the axum WebSocket: one JSON-RPC
// message per WebSocket frame, and control frames as Text messages.

pub struct AxumRpcSink {
    inner: futures::stream::SplitSink<WebSocket, WsMessage>,
}

pub struct AxumRpcStream {
    inner: futures::stream::SplitStream<WebSocket>,
}

fn split_axum_ws(websocket: WebSocket) -> (AxumRpcSink, AxumRpcStream) {
    use futures::StreamExt as _;
    let (sink, stream) = websocket.split();
    (AxumRpcSink { inner: sink }, AxumRpcStream { inner: stream })
}

impl futures::Sink<TxJsonRpcMessage<RoleClient>> for AxumRpcSink {
    type Error = axum::Error;

    fn poll_ready(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), Self::Error>> {
        futures::Sink::poll_ready(std::pin::Pin::new(&mut self.get_mut().inner), cx)
    }

    fn start_send(
        self: std::pin::Pin<&mut Self>,
        item: TxJsonRpcMessage<RoleClient>,
    ) -> Result<(), Self::Error> {
        let encoded = serde_json::to_vec(&item).map_err(|error| {
            axum::Error::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("encode JSON-RPC message: {error}"),
            ))
        })?;
        if encoded.len() > thumble_tunnel::MAXIMUM_FRAME_BYTES {
            return Err(axum::Error::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "outbound JSON-RPC message exceeds the tunnel frame cap",
            )));
        }
        futures::Sink::start_send(
            std::pin::Pin::new(&mut self.get_mut().inner),
            WsMessage::Binary(encoded.into()),
        )
    }

    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), Self::Error>> {
        futures::Sink::poll_flush(std::pin::Pin::new(&mut self.get_mut().inner), cx)
    }

    fn poll_close(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Result<(), Self::Error>> {
        futures::Sink::poll_close(std::pin::Pin::new(&mut self.get_mut().inner), cx)
    }
}

impl futures::Stream for AxumRpcStream {
    type Item = RxJsonRpcMessage<RoleClient>;

    fn poll_next(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<Option<Self::Item>> {
        let this = self.get_mut();
        loop {
            match futures::Stream::poll_next(std::pin::Pin::new(&mut this.inner), cx) {
                std::task::Poll::Ready(Some(Ok(message))) => {
                    let bytes = match message {
                        WsMessage::Binary(bytes) => bytes.to_vec(),
                        WsMessage::Text(text) => text.as_bytes().to_vec(),
                        WsMessage::Ping(_) | WsMessage::Pong(_) => continue,
                        WsMessage::Close(_) => return std::task::Poll::Ready(None),
                    };
                    if bytes.len() > thumble_tunnel::MAXIMUM_FRAME_BYTES {
                        eprintln!("gateway: dropped oversized session frame");
                        return std::task::Poll::Ready(None);
                    }
                    match serde_json::from_slice(&bytes) {
                        Ok(message) => return std::task::Poll::Ready(Some(message)),
                        Err(error) => {
                            eprintln!("gateway: dropped undecodable session frame: {error}");
                            continue;
                        }
                    }
                }
                std::task::Poll::Ready(Some(Err(_))) | std::task::Poll::Ready(None) => {
                    return std::task::Poll::Ready(None)
                }
                std::task::Poll::Pending => return std::task::Poll::Pending,
            }
        }
    }
}

// ---- Route handlers --------------------------------------------------------

async fn device_status_endpoint(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
) -> Response {
    let Some(token) = bearer_token(&headers) else {
        return (StatusCode::UNAUTHORIZED, "device token required").into_response();
    };
    let device = match state.store.device_for_token(&token) {
        Ok(Some(device)) => device,
        _ => return (StatusCode::UNAUTHORIZED, "unknown device token").into_response(),
    };
    Json(serde_json::json!({
        "linked": true,
        "online": state.tunnels.device_online(&device.id),
        "manifestPublished": state.tunnels.manifest(&device.id).is_some(),
        "deviceName": device.name,
    }))
    .into_response()
}

async fn tunnel_endpoint(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    connect_info: ConnectInfo<SocketAddr>,
    upgrade: WebSocketUpgrade,
) -> Response {
    let source = client_source_key(&headers, Some(&connect_info));
    let Some(token) = bearer_token(&headers) else {
        return (StatusCode::UNAUTHORIZED, "device token required").into_response();
    };
    let device = match state.store.device_for_token(&token) {
        Ok(Some(device)) => device,
        _ => return (StatusCode::UNAUTHORIZED, "unknown device token").into_response(),
    };
    upgrade
        .max_message_size(thumble_tunnel::MAXIMUM_FRAME_BYTES)
        .max_frame_size(thumble_tunnel::MAXIMUM_FRAME_BYTES)
        .on_upgrade(move |websocket| async move {
            serve_control_frames(
                state.tunnels.clone(),
                state.store.clone(),
                device,
                source,
                websocket,
            )
            .await;
        })
        .into_response()
}

async fn revoke_tunnel_endpoint(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    let Some(token) = bearer_token(&headers) else {
        return (StatusCode::UNAUTHORIZED, "device token required").into_response();
    };
    let device = match state.store.device_for_token(&token) {
        Ok(Some(device)) => device,
        _ => return (StatusCode::UNAUTHORIZED, "unknown device token").into_response(),
    };
    upgrade
        .max_message_size(thumble_tunnel::MAXIMUM_FRAME_BYTES)
        .max_frame_size(thumble_tunnel::MAXIMUM_FRAME_BYTES)
        .on_upgrade(move |websocket| async move {
            serve_revoke_frames(
                state.tunnels.clone(),
                state.store.clone(),
                device,
                websocket,
            )
            .await;
        })
        .into_response()
}

async fn link_tunnel_endpoint(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    connect_info: ConnectInfo<SocketAddr>,
    upgrade: WebSocketUpgrade,
) -> Response {
    let source = client_source_key(&headers, Some(&connect_info));
    if let Err(error) = state.link_rate_limiter.allow_connection(&source) {
        return (StatusCode::TOO_MANY_REQUESTS, error).into_response();
    }
    // A Bearer token on a link socket means "rotate this device in place".
    // Unknown or revoked tokens fail closed so a stale credential can never
    // silently mint a second device identity for the same Mac.
    let rotating_device = match bearer_token(&headers) {
        Some(token) => match state.store.device_for_token(&token) {
            Ok(Some(device)) => Some(device),
            _ => {
                return (
                    StatusCode::UNAUTHORIZED,
                    "the device token is unknown or revoked; run `thumble relay link` to create a fresh link",
                )
                    .into_response()
            }
        },
        None => None,
    };
    upgrade
        .max_message_size(thumble_tunnel::MAXIMUM_FRAME_BYTES)
        .max_frame_size(thumble_tunnel::MAXIMUM_FRAME_BYTES)
        .on_upgrade(move |websocket| async move {
            serve_link_frames(
                state.tunnels.clone(),
                state.store.clone(),
                state.base_url(),
                source,
                rotating_device,
                websocket,
            )
            .await;
        })
        .into_response()
}

async fn session_tunnel_endpoint(
    State(state): State<Arc<AppState>>,
    headers: axum::http::HeaderMap,
    Path(session_id): Path<String>,
    upgrade: WebSocketUpgrade,
) -> Response {
    let Some(token) = bearer_token(&headers) else {
        return (StatusCode::UNAUTHORIZED, "device token required").into_response();
    };
    let device = match state.store.device_for_token(&token) {
        Ok(Some(device)) => device,
        _ => return (StatusCode::UNAUTHORIZED, "unknown device token").into_response(),
    };
    if !state.tunnels.session_expected(&session_id, &device.id) {
        return (
            StatusCode::NOT_FOUND,
            "no session is waiting for this device",
        )
            .into_response();
    }
    let registry = state.tunnels.clone();
    upgrade
        .max_message_size(thumble_tunnel::MAXIMUM_FRAME_BYTES)
        .max_frame_size(thumble_tunnel::MAXIMUM_FRAME_BYTES)
        .on_upgrade(move |websocket| async move {
            use rmcp::ServiceExt as _;
            let (sink, stream) = split_axum_ws(websocket);
            let transport = SinkStreamTransport::new(sink, stream);
            let session: Result<rmcp::service::RunningService<RoleClient, ()>, String> = ()
                .serve(transport)
                .await
                .map_err(|error| format!("initialize device session: {error}"));
            match session {
                Ok(service) => {
                    if let Err(error) =
                        registry.complete_device_session(&session_id, &device.id, Ok(service))
                    {
                        eprintln!("gateway: session handoff failed: {error}");
                    }
                }
                Err(error) => {
                    let _ = registry.complete_device_session(
                        &session_id,
                        &device.id,
                        Err(error.clone()),
                    );
                    eprintln!("gateway: device session failed: {error} ({})", device.id);
                }
            }
        })
        .into_response()
}

pub async fn healthz(State(state): State<Arc<AppState>>) -> Json<serde_json::Value> {
    let devices = state.tunnels.device_count();
    Json(serde_json::json!({ "ok": true, "devices_online": devices }))
}

pub async fn well_known_protected_resource(State(state): State<Arc<AppState>>) -> Response {
    oauth::protected_resource_metadata(&state.base_url()).into_response()
}

pub async fn well_known_authorization_server(State(state): State<Arc<AppState>>) -> Response {
    oauth::authorization_server_metadata(&state.base_url()).into_response()
}

async fn security_headers(
    State(state): State<Arc<AppState>>,
    request: Request<axum::body::Body>,
    next: Next,
) -> Response {
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(
        header::X_CONTENT_TYPE_OPTIONS,
        axum::http::HeaderValue::from_static("nosniff"),
    );
    headers.insert(
        header::REFERRER_POLICY,
        axum::http::HeaderValue::from_static("no-referrer"),
    );
    headers.insert(
        header::CACHE_CONTROL,
        axum::http::HeaderValue::from_static("no-store"),
    );
    headers.insert(
        header::CONTENT_SECURITY_POLICY,
        axum::http::HeaderValue::from_static(
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
        ),
    );
    if state.base_url().starts_with("https://") {
        headers.insert(
            header::STRICT_TRANSPORT_SECURITY,
            axum::http::HeaderValue::from_static("max-age=31536000; includeSubDomains"),
        );
    }
    response
}

pub fn router(state: Arc<AppState>) -> Router {
    let mcp = Router::new()
        .route_service("/mcp", mcp_service(state.clone()))
        .layer(tower_http::limit::RequestBodyLimitLayer::new(
            thumble_tunnel::MAXIMUM_FRAME_BYTES,
        ))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            auth_mcp,
        ));

    Router::new()
        .merge(mcp)
        .route(
            "/.well-known/oauth-protected-resource",
            get(well_known_protected_resource),
        )
        .route(
            "/.well-known/oauth-authorization-server",
            get(well_known_authorization_server),
        )
        .route("/register", post(oauth::register))
        .route("/authorize", get(oauth::authorize))
        .route("/authorize/code", get(oauth::authorize_code))
        .route("/authorize/confirm", post(oauth::authorize_confirm))
        .route("/authorize/wait", get(oauth::authorize_wait))
        .route("/token", post(oauth::token))
        .route("/link", get(oauth::link_page))
        .route("/healthz", get(healthz))
        .route("/device/status", get(device_status_endpoint))
        .route("/tunnel", get(tunnel_endpoint))
        .route("/tunnel/revoke", get(revoke_tunnel_endpoint))
        .route("/tunnel/link", get(link_tunnel_endpoint))
        .route("/tunnel/session/{session_id}", get(session_tunnel_endpoint))
        .layer(axum::extract::DefaultBodyLimit::max(64 * 1024))
        .layer(axum::middleware::from_fn_with_state(
            state.clone(),
            security_headers,
        ))
        .with_state(state)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn forwarded_source_is_ignored_without_trusted_proxy_configuration() {
        let mut headers = axum::http::HeaderMap::new();
        headers.insert("Fly-Client-IP", "203.0.113.9".parse().unwrap());
        let peer = ConnectInfo("127.0.0.1:4321".parse().unwrap());
        assert_eq!(
            client_source_key_with_trust(&headers, Some(&peer), false),
            "127.0.0.1"
        );
        assert_eq!(
            client_source_key_with_trust(&headers, Some(&peer), true),
            "203.0.113.9"
        );
    }
}
