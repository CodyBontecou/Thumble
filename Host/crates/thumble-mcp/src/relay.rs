//! Device-side relay for remote MCP connectors.
//!
//! `thumble-mcp --relay wss://…` keeps one outbound control WebSocket to the
//! hosted gateway and serves the ordinary [`crate::ThumbleMcp`] tool surface
//! over per-session WebSockets that the gateway opens on demand. The relay
//! never terminates TLS itself (the gateway does), never accepts inbound
//! network connections, and never exposes the unix control socket to the
//! network: every host request still goes through the local
//! [`crate::UnixHostChannel`].
//!
//! Fail-closed properties:
//! - No stored device token means the relay can only open a user-approved
//!   link window (with a one-time code as the headless fallback).
//! - The token file is user-only (`0600`) inside the host state directory
//!   (`0700`), mirroring host draft storage.
//! - `--allow-input` / `--allow-config-write` remain the inner gates; remote
//!   sessions additionally pass gateway scope checks.
//! - A per-host lock prevents duplicate long-lived relays from racing over one
//!   device identity; atomic token replacement lets a managed relay reload a
//!   deliberate re-link without a second serving process.

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fs2::FileExt;
use futures::{SinkExt, StreamExt};
use thumble_host::control::{send_request, ControlRequest};
use thumble_tunnel::protocol::{
    CONNECTOR_APPROVAL_TTL_SECONDS, LINK_CODE_TTL_SECONDS, MAXIMUM_DEVICE_SESSIONS,
    MAXIMUM_FRAME_BYTES,
};
use thumble_tunnel::ws_rpc::{split_json_rpc_ws, WsIo};
use thumble_tunnel::TunnelMessage;
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

use crate::server::ThumbleMcp;

const RELAY_BACKOFF_INITIAL: Duration = Duration::from_secs(1);
const RELAY_BACKOFF_MAXIMUM: Duration = Duration::from_secs(60);
#[cfg(test)]
const CONTROL_IDLE_PING: Duration = Duration::from_millis(300);
#[cfg(not(test))]
const CONTROL_IDLE_PING: Duration = Duration::from_secs(30);
#[cfg(test)]
const TOKEN_RELOAD_INTERVAL: Duration = Duration::from_millis(50);
#[cfg(not(test))]
const TOKEN_RELOAD_INTERVAL: Duration = Duration::from_secs(1);
/// How many consecutive idle intervals without any inbound frame (including
/// Pong replies to our probes) may pass before the connection is declared
/// dead. 3 × 30s detects a silently dropped NAT path in ~90 seconds instead
/// of waiting for TCP retransmission to give up (~15 minutes).
const MAXIMUM_MISSED_IDLE_PINGS: u32 = 3;

/// A tunnel control message from the gateway, or a lifecycle signal.
#[derive(Debug)]
enum ControlEvent {
    Message(TunnelMessage),
    Closed,
    /// Protocol-level traffic (WebSocket ping/pong or undecodable frames).
    /// Edge proxies such as Fly's answer protocol pings on behalf of a dead
    /// origin, so this must never reset the application-level liveness
    /// deadline — only a decoded `TunnelMessage` proves the gateway is alive.
    ProtocolNoise,
}

#[derive(Default)]
struct SessionTasks {
    handles: HashMap<String, tokio::task::JoinHandle<()>>,
}

impl SessionTasks {
    fn len(&self) -> usize {
        self.handles.len()
    }

    fn insert(&mut self, session_id: String, handle: tokio::task::JoinHandle<()>) {
        if let Some(previous) = self.handles.insert(session_id, handle) {
            previous.abort();
        }
    }

    fn remove_completed(&mut self, session_id: &str) {
        self.handles.remove(session_id);
    }

    async fn abort_one(&mut self, session_id: &str) {
        if let Some(handle) = self.handles.remove(session_id) {
            handle.abort();
            let _ = handle.await;
        }
    }

    async fn abort_all(&mut self) {
        let handles = self
            .handles
            .drain()
            .map(|(_, handle)| handle)
            .collect::<Vec<_>>();
        for handle in &handles {
            handle.abort();
        }
        for handle in handles {
            let _ = handle.await;
        }
    }
}

impl Drop for SessionTasks {
    fn drop(&mut self) {
        for (_, handle) in self.handles.drain() {
            handle.abort();
        }
    }
}

/// Native approval prompts run independently from WebSocket I/O so the
/// relay can keep answering liveness probes while the user decides. A
/// gateway result closes the matching prompt; dropping the connection closes
/// every remaining prompt.
#[derive(Default)]
struct ApprovalPromptTasks {
    handles: HashMap<String, tokio::task::JoinHandle<()>>,
}

impl ApprovalPromptTasks {
    fn insert(&mut self, request_id: String, handle: tokio::task::JoinHandle<()>) {
        if let Some(previous) = self.handles.insert(request_id, handle) {
            previous.abort();
        }
    }

    async fn abort_one(&mut self, request_id: &str) {
        if let Some(handle) = self.handles.remove(request_id) {
            handle.abort();
            let _ = handle.await;
        }
    }
}

impl Drop for ApprovalPromptTasks {
    fn drop(&mut self) {
        for (_, handle) in self.handles.drain() {
            handle.abort();
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ApprovalPromptOutcome {
    Approved,
    Denied,
    Unavailable,
}

#[derive(Debug, Clone)]
pub struct RelayConfig {
    /// Base control WebSocket URL, e.g. `wss://mcp.thumble.app/tunnel`.
    pub relay_url: String,
    /// Where the device token is persisted (user-only).
    pub token_file: PathBuf,
    /// Friendly device name shown on the link page.
    pub device_name: String,
    /// Local host control socket used by every session.
    pub control_socket: PathBuf,
    pub allow_input: bool,
    pub allow_config_write: bool,
}

struct RelayLock {
    file: std::fs::File,
}

impl Drop for RelayLock {
    fn drop(&mut self) {
        let _ = fs2::FileExt::unlock(&self.file);
    }
}

fn acquire_relay_lock(token_file: &Path) -> Result<RelayLock, String> {
    let Some(parent) = token_file.parent() else {
        return Err("relay token path has no parent directory".to_owned());
    };
    std::fs::create_dir_all(parent).map_err(|error| format!("create relay state dir: {error}"))?;
    let lock_path = parent.join("relay.lock");
    let file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&lock_path)
        .map_err(|error| format!("open relay lock: {error}"))?;
    std::fs::set_permissions(&lock_path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("protect relay lock: {error}"))?;
    file.try_lock_exclusive().map_err(|_| {
        "another Thumble relay is already running for this host; use `thumble relay status` or `relay rotate` instead".to_owned()
    })?;
    Ok(RelayLock { file })
}

async fn ensure_local_host_ready(config: &RelayConfig) -> Result<(), String> {
    let status = send_request(&config.control_socket, &ControlRequest::Status)
        .await
        .map_err(|error| format!("check Thumble Host before linking: {error}"))?;
    if !status.ok {
        return Err(status
            .error
            .unwrap_or_else(|| "Thumble Host rejected its status request".to_owned()));
    }
    let host = status
        .status
        .ok_or_else(|| "Thumble Host returned no status".to_owned())?;
    if config.allow_config_write && !host.configuration_write_enabled {
        return Err(
            "configuration writes are requested but Thumble Host was not started with --allow-config-write"
                .to_owned(),
        );
    }
    if config.allow_config_write {
        let configuration =
            send_request(&config.control_socket, &ControlRequest::ConfigurationStatus)
                .await
                .map_err(|error| format!("check Thumble configuration before linking: {error}"))?;
        if !configuration.ok {
            return Err(configuration.error.unwrap_or_else(|| {
                "Thumble Host rejected its configuration status request".to_owned()
            }));
        }
        let summary = configuration
            .configuration
            .ok_or_else(|| "Thumble Host returned no configuration status".to_owned())?;
        if !summary.configuration_write_enabled {
            return Err(
                "configuration writes are requested but the host configuration gate is disabled"
                    .to_owned(),
            );
        }
        if !summary.bridge_available {
            return Err(
                "configuration writes are requested but the adjacent thumble-bridge is unavailable"
                    .to_owned(),
            );
        }
    }
    Ok(())
}

/// Result of one control-connection attempt.
#[derive(Debug, PartialEq)]
pub enum RelayOutcome {
    /// The control connection ended; the caller should reconnect.
    Disconnected,
    /// The caller asked to stop.
    Stopped,
    /// A one-shot revoke completed.
    Revoked,
}

impl RelayConfig {
    pub fn session_url(&self, session_path: &str) -> String {
        let base = self.relay_url.trim_end_matches('/');
        let root = base
            .strip_suffix("/tunnel")
            .unwrap_or(base)
            .trim_end_matches('/');
        format!("{root}/{session_path}")
    }

    pub fn link_url(&self) -> String {
        let base = self.relay_url.trim_end_matches('/');
        if base.ends_with("/tunnel") {
            format!("{base}/link")
        } else {
            format!("{base}/tunnel/link")
        }
    }

    pub fn revoke_url(&self) -> String {
        let base = self.relay_url.trim_end_matches('/');
        if base.ends_with("/tunnel") {
            format!("{base}/revoke")
        } else {
            format!("{base}/tunnel/revoke")
        }
    }
}

fn validate_websocket_url(url: &str, label: &str) -> Result<(), String> {
    let parsed = url::Url::parse(url).map_err(|error| format!("parse {label} url: {error}"))?;
    match parsed.scheme() {
        "wss" => Ok(()),
        "ws" if matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "::1")) => Ok(()),
        "ws" => Err(format!(
            "{label} must use wss:// outside loopback development"
        )),
        _ => Err(format!("{label} must use ws:// or wss://")),
    }
}

fn same_websocket_origin(control_url: &str, session_url: &str) -> bool {
    let Ok(control) = url::Url::parse(control_url) else {
        return false;
    };
    let Ok(session) = url::Url::parse(session_url) else {
        return false;
    };
    let control_loopback = matches!(control.host_str(), Some("localhost" | "127.0.0.1" | "::1"));
    let session_loopback = matches!(session.host_str(), Some("localhost" | "127.0.0.1" | "::1"));
    if control_loopback && session_loopback {
        return control.scheme() == "ws" && session.scheme() == "ws";
    }
    control.scheme() == session.scheme()
        && control.host_str() == session.host_str()
        && control.port_or_known_default() == session.port_or_known_default()
}

fn websocket_config() -> tokio_tungstenite::tungstenite::protocol::WebSocketConfig {
    tokio_tungstenite::tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(MAXIMUM_FRAME_BYTES))
        .max_frame_size(Some(MAXIMUM_FRAME_BYTES))
}

async fn connect_control(url: &str, token: Option<&str>) -> Result<WebSocketStream<WsIo>, String> {
    validate_websocket_url(url, "relay")?;
    let mut request = url
        .to_owned()
        .into_client_request()
        .map_err(|error| format!("parse relay url: {error}"))?;
    if let Some(token) = token {
        let value = HeaderValue::from_str(&format!("Bearer {token}"))
            .map_err(|error| format!("build relay auth header: {error}"))?;
        request.headers_mut().insert("Authorization", value);
    }
    let (stream, _response) =
        tokio_tungstenite::connect_async_with_config(request, Some(websocket_config()), false)
            .await
            .map_err(|error| format!("connect relay control websocket: {error}"))?;
    Ok(stream)
}

fn read_token_file(path: &Path) -> Result<Option<String>, String> {
    match std::fs::read_to_string(path) {
        Ok(token) if token.len() >= 32 => Ok(Some(token.trim().to_owned())),
        Ok(_) => Err("relay token file is malformed".to_owned()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(format!("read relay token file: {error}")),
    }
}

fn write_token_file(path: &Path, token: &str) -> Result<(), String> {
    let Some(parent) = path.parent() else {
        return Err("relay token path has no parent directory".to_owned());
    };
    std::fs::create_dir_all(parent).map_err(|error| format!("create relay state dir: {error}"))?;
    let metadata =
        std::fs::metadata(parent).map_err(|error| format!("inspect relay state dir: {error}"))?;
    if metadata.permissions().mode() & 0o077 != 0 {
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))
            .map_err(|error| format!("protect relay state dir: {error}"))?;
    }

    // Replace the credential atomically. The long-lived relay watches this
    // path, so a partially written token must never be observable during
    // re-linking or recovery.
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|error| format!("clock before unix epoch: {error}"))?
        .as_nanos();
    let temporary = parent.join(format!(".relay-token.{nonce}.tmp"));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(|error| format!("create temporary relay token file: {error}"))?;
    if let Err(error) = file.set_permissions(std::fs::Permissions::from_mode(0o600)) {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("protect temporary relay token file: {error}"));
    }
    use std::io::Write as _;
    if let Err(error) = file.write_all(token.as_bytes()) {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("write temporary relay token file: {error}"));
    }
    if let Err(error) = file.sync_all() {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("sync temporary relay token file: {error}"));
    }
    drop(file);
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(format!("replace relay token file: {error}"));
    }
    std::fs::File::open(parent)
        .and_then(|directory| directory.sync_all())
        .map_err(|error| format!("sync relay state directory: {error}"))?;
    Ok(())
}

pub fn delete_token_file(path: &Path) {
    let _ = std::fs::remove_file(path);
}

fn approval_prompt_enabled() -> bool {
    std::env::var_os("THUMBLE_RELAY_NO_PROMPT").is_none_or(|value| value.is_empty())
}

fn approval_display_value(value: &str, maximum: usize) -> String {
    value
        .chars()
        .take(maximum)
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .collect()
}

fn parse_approval_prompt_output(output: &str) -> ApprovalPromptOutcome {
    // AppleScript reports the default button even when the dialog times out;
    // `gave up:true` must therefore override an apparent Allow.
    if output.contains("gave up:true") {
        ApprovalPromptOutcome::Unavailable
    } else if output.contains("button returned:Allow") {
        ApprovalPromptOutcome::Approved
    } else if output.contains("button returned:Deny") {
        ApprovalPromptOutcome::Denied
    } else {
        ApprovalPromptOutcome::Unavailable
    }
}

/// Ask the interactive macOS user to approve the connector. User-controlled
/// client metadata is passed through an environment variable read by
/// AppleScript rather than interpolated into script source.
async fn prompt_connector_approval(
    client_name: &str,
    scope: &str,
    expires_in: u64,
) -> ApprovalPromptOutcome {
    let client_name = approval_display_value(
        if client_name.trim().is_empty() {
            "ChatGPT connector"
        } else {
            client_name.trim()
        },
        128,
    );
    let scope = approval_display_value(scope, 256);
    eprintln!(
        "thumble relay: {client_name} is asking to connect (scopes: {scope}); approve only if you just clicked Connect"
    );
    if !cfg!(target_os = "macos") || !approval_prompt_enabled() {
        eprintln!(
            "thumble relay: native approval prompt unavailable; use the six-digit fallback in the browser (`thumble relay rotate` creates a fresh code)"
        );
        return ApprovalPromptOutcome::Unavailable;
    }

    let expires_in = expires_in.clamp(5, CONNECTOR_APPROVAL_TTL_SECONDS);
    let message = format!(
        "{client_name} wants to connect to Thumble on this Mac.\n\nScopes: {scope}\n\nApprove only if you just clicked Connect in ChatGPT."
    );
    let script = format!(
        "set approvalMessage to system attribute \"THUMBLE_APPROVAL_MESSAGE\"\n\
         display dialog approvalMessage with title \"Thumble\" with icon caution \
         buttons {{\"Deny\", \"Allow\"}} default button \"Deny\" giving up after {expires_in}"
    );
    let mut command = tokio::process::Command::new("/usr/bin/osascript");
    command
        .arg("-e")
        .arg(script)
        .env("THUMBLE_APPROVAL_MESSAGE", message)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true);
    let result = tokio::time::timeout(Duration::from_secs(expires_in + 10), command.output()).await;
    match result {
        Ok(Ok(output)) if output.status.success() => {
            parse_approval_prompt_output(&String::from_utf8_lossy(&output.stdout))
        }
        _ => ApprovalPromptOutcome::Unavailable,
    }
}

fn spawn_connector_approval_prompt(
    prompts: &mut ApprovalPromptTasks,
    decisions: mpsc::Sender<TunnelMessage>,
    request_id: String,
    client_name: String,
    scope: String,
    expires_in: u64,
) {
    let prompt_id = request_id.clone();
    let handle = tokio::spawn(async move {
        let approved = match prompt_connector_approval(&client_name, &scope, expires_in).await {
            ApprovalPromptOutcome::Approved => true,
            ApprovalPromptOutcome::Denied => false,
            ApprovalPromptOutcome::Unavailable => return,
        };
        let _ = decisions
            .send(TunnelMessage::ConnectorApprovalDecision {
                request_id,
                approved,
            })
            .await;
    });
    prompts.insert(prompt_id, handle);
}

/// Run the device link flow against the gateway. Clicking Connect in ChatGPT
/// pushes a native approval prompt to this Mac; the one-time code remains a
/// fallback for headless sessions. The link socket keeps pumping liveness
/// frames while the prompt is visible.
async fn link_device(
    config: &RelayConfig,
    mut websocket: WebSocketStream<WsIo>,
) -> Result<String, String> {
    let token_before_link = read_token_file(&config.token_file)?;
    websocket
        .send(Message::text(
            thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::LinkRequest {
                device_name: config.device_name.clone(),
            }),
        ))
        .await
        .map_err(|error| format!("send link request: {error}"))?;

    let (decision_sender, mut decision_receiver) = mpsc::channel::<TunnelMessage>(8);
    let mut prompts = ApprovalPromptTasks::default();
    let mut keepalive = tokio::time::interval(CONTROL_IDLE_PING);
    keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // Consume interval's immediate first tick; probes begin after one idle
    // period instead of immediately after LinkRequest.
    keepalive.tick().await;
    let deadline = tokio::time::sleep(Duration::from_secs(LINK_CODE_TTL_SECONDS + 60));
    tokio::pin!(deadline);

    loop {
        tokio::select! {
            message = websocket.next() => {
                let message = message
                    .ok_or_else(|| "relay closed during device linking".to_owned())?
                    .map_err(|error| format!("read link reply: {error}"))?;
                let bytes = match message {
                    Message::Text(payload) => payload.as_bytes().to_vec(),
                    Message::Binary(payload) => payload.to_vec(),
                    Message::Close(_) => return Err("relay closed during device linking".to_owned()),
                    _ => continue,
                };
                let Some(frame) = thumble_tunnel::ws_rpc::decode_control_message(&bytes) else {
                    continue;
                };
                match frame {
                    TunnelMessage::LinkOffer { code, url, .. } => {
                        offer_browser_assist(&config.relay_url, &code, &url);
                        eprintln!(
                            "thumble relay: ready — click Connect on Thumble in ChatGPT, then click Allow in the Mac prompt; fallback code {code} ({url})"
                        );
                    }
                    TunnelMessage::ConnectorApprovalRequest {
                        request_id,
                        client_name,
                        scope,
                        expires_in,
                    } => {
                        spawn_connector_approval_prompt(
                            &mut prompts,
                            decision_sender.clone(),
                            request_id,
                            client_name,
                            scope,
                            expires_in,
                        );
                    }
                    TunnelMessage::ConnectorApprovalResult {
                        request_id,
                        granted,
                        detail,
                    } => {
                        prompts.abort_one(&request_id).await;
                        eprintln!(
                            "thumble relay: connector approval {}{}",
                            if granted { "completed" } else { "did not complete" },
                            detail.map(|value| format!(": {value}")).unwrap_or_default()
                        );
                    }
                    TunnelMessage::Ping => {
                        websocket
                            .send(Message::text(thumble_tunnel::ws_rpc::encode_control_message(
                                &TunnelMessage::Pong,
                            )))
                            .await
                            .map_err(|error| format!("send link pong: {error}"))?;
                    }
                    TunnelMessage::LinkGranted {
                        device_id,
                        device_token,
                    } => {
                        if let Err(error) = write_token_file(&config.token_file, &device_token) {
                            let _ = websocket
                                .send(Message::text(
                                    thumble_tunnel::ws_rpc::encode_control_message(
                                        &TunnelMessage::LinkPersistFailed { device_id },
                                    ),
                                ))
                                .await;
                            return Err(error);
                        }
                        if let Err(error) = websocket
                            .send(Message::text(
                                thumble_tunnel::ws_rpc::encode_control_message(
                                    &TunnelMessage::LinkPersisted { device_id },
                                ),
                            ))
                            .await
                        {
                            // A first-time token cannot be trusted when its
                            // persistence acknowledgment never left this
                            // socket; the gateway will fail/revoke that grant.
                            // During explicit rotation the new token may
                            // already be authoritative, so retain it for
                            // recovery instead of restoring a stale token.
                            if token_before_link.is_none() {
                                delete_token_file(&config.token_file);
                            }
                            return Err(format!("confirm relay token persistence: {error}"));
                        }
                        return Ok(device_token);
                    }
                    TunnelMessage::LinkDenied { reason } => {
                        delete_token_file(&config.token_file);
                        return Err(format!("device link denied: {reason}"));
                    }
                    _ => continue,
                }
            }
            Some(decision) = decision_receiver.recv() => {
                websocket
                    .send(Message::text(
                        thumble_tunnel::ws_rpc::encode_control_message(&decision),
                    ))
                    .await
                    .map_err(|error| format!("send connector approval decision: {error}"))?;
            }
            _ = keepalive.tick() => {
                websocket
                    .send(Message::text(thumble_tunnel::ws_rpc::encode_control_message(
                        &TunnelMessage::Ping,
                    )))
                    .await
                    .map_err(|error| format!("send link ping: {error}"))?;
            }
            _ = &mut deadline => {
                return Err("timed out waiting for ChatGPT to connect".to_owned());
            }
        }
    }
}

/// Best-effort fallback convenience on macOS: copy the one-time code to the
/// clipboard without opening an extra browser tab. Clicking Connect in
/// ChatGPT is now the primary path; the printed URL and code remain
/// authoritative if the native prompt is unavailable.
fn offer_browser_assist(relay_url: &str, code: &str, offer_url: &str) {
    if !browser_assist_enabled() || !cfg!(target_os = "macos") {
        return;
    }
    // Only trust offers from the configured gateway before acting on them.
    let trusted = url::Url::parse(offer_url).is_ok_and(|offer| {
        matches!(offer.scheme(), "http" | "https")
            && url::Url::parse(relay_url).is_ok_and(|relay| {
                relay.host_str() == offer.host_str()
                    && relay.port_or_known_default() == offer.port_or_known_default()
            })
    });
    if !trusted {
        return;
    }
    let copied = std::process::Command::new("/usr/bin/pbcopy")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()
        .is_some_and(|mut child| {
            if let Some(stdin) = child.stdin.as_mut() {
                use std::io::Write as _;
                if stdin.write_all(code.as_bytes()).is_err() {
                    return false;
                }
            }
            drop(child.stdin.take());
            child.wait().is_ok_and(|status| status.success())
        });
    if copied {
        eprintln!("thumble relay: fallback code {code} copied to the clipboard");
    }
}

fn browser_assist_enabled() -> bool {
    std::env::var_os("THUMBLE_RELAY_NO_BROWSER").is_none_or(|value| value.is_empty())
}

/// Serve one remote MCP session over the given session WebSocket.
async fn serve_session(
    config: RelayConfig,
    session_id: String,
    websocket: WebSocketStream<WsIo>,
    results: mpsc::Sender<TunnelMessage>,
) {
    let (sink, stream) = split_json_rpc_ws::<rmcp::RoleServer>(websocket);
    let service = ThumbleMcp::new(
        config.control_socket.clone(),
        config.allow_input,
        config.allow_config_write,
    );
    let transport = rmcp::transport::sink_stream::SinkStreamTransport::new(sink, stream);
    use rmcp::ServiceExt as _;
    let outcome = match service.serve(transport).await {
        Ok(running) => match running.waiting().await {
            Ok(_reason) => (true, None),
            Err(error) => (false, Some(format!("session ended: {error}"))),
        },
        Err(error) => (false, Some(format!("start session: {error}"))),
    };
    let _ = results
        .send(TunnelMessage::SessionResult {
            session_id,
            ok: outcome.0,
            error: outcome.1,
        })
        .await;
}

/// Collect the sanitized tool/resource manifest by serving one in-process
/// MCP session over a duplex stream.
async fn collect_manifest(
    control_socket: &Path,
) -> Result<
    (
        Vec<serde_json::Value>,
        Vec<serde_json::Value>,
        Option<String>,
    ),
    String,
> {
    let (client_to_server, server_to_client) = tokio::io::duplex(1024 * 1024);
    let socket = control_socket.to_path_buf();
    let server_task = tokio::spawn(async move {
        use rmcp::ServiceExt as _;
        let server = ThumbleMcp::new(socket, false, false);
        let (reader, writer) = tokio::io::split(server_to_client);
        if let Ok(running) = server.serve((reader, writer)).await {
            let _ = running.waiting().await;
        }
    });

    let manifest = async {
        use rmcp::ServiceExt as _;
        let (reader, writer) = tokio::io::split(client_to_server);
        let client: rmcp::service::RunningService<rmcp::RoleClient, ()> = ()
            .serve((reader, writer))
            .await
            .map_err(|error| format!("manifest client: {error}"))?;
        let tools = client
            .peer()
            .list_tools(None)
            .await
            .map_err(|error| format!("list tools for manifest: {error}"))?;
        let resources = client
            .peer()
            .list_resources(None)
            .await
            .map_err(|error| format!("list resources for manifest: {error}"))?;
        let instructions = client
            .peer_info()
            .and_then(|info| info.instructions.clone());
        let tools: Vec<serde_json::Value> = tools
            .tools
            .into_iter()
            .map(|tool| serde_json::to_value(&tool).unwrap_or_default())
            .collect();
        let resources: Vec<serde_json::Value> = resources
            .resources
            .into_iter()
            .map(|resource| serde_json::to_value(&resource).unwrap_or_default())
            .collect();
        client.cancel().await.ok();
        Ok::<_, String>((tools, resources, instructions))
    }
    .await;
    server_task.abort();
    manifest
}

/// One control-connection lifecycle: authenticate (linking if necessary),
/// publish the manifest, then serve `open_session` requests until the socket
/// or the shutdown signal ends the connection.
async fn run_relay_once(
    config: &RelayConfig,
    shutdown: &mut watch::Receiver<bool>,
) -> Result<RelayOutcome, String> {
    let token = match read_token_file(&config.token_file)? {
        Some(token) => token,
        None => {
            let websocket = connect_control(&config.link_url(), None).await?;
            link_device(config, websocket).await?
        }
    };

    let mut websocket = connect_control(&config.relay_url, Some(&token)).await?;
    eprintln!("thumble relay: control channel connected");

    let (tools, resources, instructions) = collect_manifest(&config.control_socket).await?;
    let manifest = TunnelMessage::Manifest {
        tools,
        resources,
        server_instructions: instructions,
    };
    if serde_json::to_vec(&manifest)
        .map_err(|e| format!("encode manifest: {e}"))?
        .len()
        > MAXIMUM_FRAME_BYTES
    {
        return Err("tool manifest exceeds the tunnel frame cap".to_owned());
    }
    websocket
        .send(Message::text(
            thumble_tunnel::ws_rpc::encode_control_message(&manifest),
        ))
        .await
        .map_err(|error| format!("send manifest: {error}"))?;
    eprintln!("thumble relay: MCP manifest published; ready for connector sessions");

    let (result_sender, mut result_receiver) = mpsc::channel::<TunnelMessage>(16);
    let (approval_sender, mut approval_receiver) = mpsc::channel::<TunnelMessage>(8);
    let mut live_sessions = SessionTasks::default();
    let mut approval_prompts = ApprovalPromptTasks::default();
    let mut keepalive = tokio::time::interval(CONTROL_IDLE_PING);
    keepalive.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // Consume the interval's immediate first tick so a healthy connection gets
    // one full idle interval before its first application-level probe.
    keepalive.tick().await;
    let mut token_check = tokio::time::interval(TOKEN_RELOAD_INTERVAL);
    token_check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut missed_inbound: u32 = 0;

    let outcome = loop {
        let next_frame = async {
            match websocket.next().await {
                Some(Ok(Message::Text(text))) => {
                    thumble_tunnel::ws_rpc::decode_control_message(text.as_bytes())
                        .map_or(ControlEvent::ProtocolNoise, ControlEvent::Message)
                }
                Some(Ok(Message::Binary(bytes))) => {
                    thumble_tunnel::ws_rpc::decode_control_message(&bytes)
                        .map_or(ControlEvent::ProtocolNoise, ControlEvent::Message)
                }
                Some(Ok(Message::Close(_))) => ControlEvent::Closed,
                // WebSocket control frames are transport noise regardless of
                // payload. Never parse them as application control messages.
                Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => {
                    ControlEvent::ProtocolNoise
                }
                Some(Err(_)) | None => ControlEvent::Closed,
            }
        };
        let next_result = result_receiver.recv();
        let stopped = shutdown.changed();

        tokio::select! {
            event = next_frame => {
                if matches!(event, ControlEvent::Message(_)) {
                    missed_inbound = 0;
                    // Measure three complete idle periods from the latest
                    // decoded gateway message, independent of other branches.
                    keepalive.reset();
                }
                match event {
                ControlEvent::Closed => break Ok(RelayOutcome::Disconnected),
                // Protocol traffic proves only that a proxy is alive. The
                // independent keepalive interval below continues counting
                // until the gateway returns a decoded control message.
                ControlEvent::ProtocolNoise => {}
                ControlEvent::Message(TunnelMessage::Ping) => {
                    if let Err(error) = websocket
                        .send(Message::text(thumble_tunnel::ws_rpc::encode_control_message(
                            &TunnelMessage::Pong,
                        )))
                        .await
                    {
                        break Err(format!("send pong: {error}"));
                    }
                }
                ControlEvent::Message(TunnelMessage::OpenSession { session_id, session_url }) => {
                    let open_count = live_sessions.len();
                    if open_count >= MAXIMUM_DEVICE_SESSIONS {
                        let _ = result_sender
                            .send(TunnelMessage::SessionResult {
                                session_id: session_id.clone(),
                                ok: false,
                                error: Some("device session limit reached".to_owned()),
                            })
                            .await;
                        continue;
                    }
                    let session_url = if session_url.is_empty() {
                        config.session_url(&format!("tunnel/session/{session_id}"))
                    } else {
                        session_url
                    };
                    if !same_websocket_origin(&config.relay_url, &session_url) {
                        let _ = result_sender
                            .send(TunnelMessage::SessionResult {
                                session_id,
                                ok: false,
                                error: Some("gateway supplied a cross-origin session URL".to_owned()),
                            })
                            .await;
                        continue;
                    }
                    let session = open_session_socket(&session_url, &token).await;
                    match session {
                        Ok(socket) => {
                            let handle = tokio::spawn(serve_session(
                                config.clone(),
                                session_id.clone(),
                                socket,
                                result_sender.clone(),
                            ));
                            live_sessions.insert(session_id, handle);
                        }
                        Err(error) => {
                            let _ = result_sender
                                .send(TunnelMessage::SessionResult {
                                    session_id,
                                    ok: false,
                                    error: Some(error),
                                })
                                .await;
                        }
                    }
                }
                ControlEvent::Message(TunnelMessage::CloseSession { session_id }) => {
                    live_sessions.abort_one(&session_id).await;
                }
                ControlEvent::Message(TunnelMessage::ConnectorApprovalRequest {
                    request_id,
                    client_name,
                    scope,
                    expires_in,
                }) => {
                    spawn_connector_approval_prompt(
                        &mut approval_prompts,
                        approval_sender.clone(),
                        request_id,
                        client_name,
                        scope,
                        expires_in,
                    );
                }
                ControlEvent::Message(TunnelMessage::ConnectorApprovalResult {
                    request_id,
                    granted,
                    detail,
                }) => {
                    approval_prompts.abort_one(&request_id).await;
                    eprintln!(
                        "thumble relay: connector approval {}{}",
                        if granted { "completed" } else { "did not complete" },
                        detail.map(|value| format!(": {value}")).unwrap_or_default()
                    );
                }
                ControlEvent::Message(TunnelMessage::LinkDenied { reason }) => {
                    delete_token_file(&config.token_file);
                    break Err(format!("relay rejected the device token: {reason}"));
                }
                ControlEvent::Message(TunnelMessage::RevokeGranted { .. }) => {
                    delete_token_file(&config.token_file);
                    break Ok(RelayOutcome::Revoked);
                }
                ControlEvent::Message(TunnelMessage::ReconnectRequired { detail }) => {
                    eprintln!(
                        "thumble relay: {}",
                        detail.unwrap_or_else(|| "gateway requested credential reload".to_owned())
                    );
                    break Ok(RelayOutcome::Disconnected);
                }
                ControlEvent::Message(_) => {}
                }
            },
            Some(result) = next_result => {
                if let Err(error) = websocket
                    .send(Message::text(
                        thumble_tunnel::ws_rpc::encode_control_message(&result),
                    ))
                    .await
                {
                    break Err(format!("forward session result: {error}"));
                }
                if let TunnelMessage::SessionResult { session_id, .. } = &result {
                    live_sessions.remove_completed(session_id);
                }
            },
            Some(decision) = approval_receiver.recv() => {
                if let Err(error) = websocket
                    .send(Message::text(
                        thumble_tunnel::ws_rpc::encode_control_message(&decision),
                    ))
                    .await
                {
                    break Err(format!("forward connector approval decision: {error}"));
                }
            },
            changed = stopped => {
                if changed.is_err() || *shutdown.borrow() {
                    break Ok(RelayOutcome::Stopped);
                }
            }
            _ = keepalive.tick() => {
                // This deadline must be independent of websocket.next(): the
                // one-second token-file check is another select branch and
                // would otherwise cancel/recreate a long read timeout forever
                // on a completely silent half-open socket.
                missed_inbound += 1;
                if missed_inbound >= MAXIMUM_MISSED_IDLE_PINGS {
                    eprintln!(
                        "thumble relay: control channel unresponsive for {}s; reconnecting",
                        missed_inbound as u64 * CONTROL_IDLE_PING.as_secs()
                    );
                    break Ok(RelayOutcome::Disconnected);
                }
                if let Err(error) = websocket
                    .send(Message::text(thumble_tunnel::ws_rpc::encode_control_message(
                        &TunnelMessage::Ping,
                    )))
                    .await
                {
                    break Err(format!("send ping: {error}"));
                }
            }
            _ = token_check.tick() => {
                match read_token_file(&config.token_file) {
                    Ok(Some(latest)) if latest != token => {
                        eprintln!("thumble relay: device token changed; reconnecting with the new link");
                        break Ok(RelayOutcome::Disconnected);
                    }
                    Ok(Some(_)) => {}
                    Ok(None) => {
                        eprintln!("thumble relay: device token removed; stopping until explicitly linked");
                        break Ok(RelayOutcome::Revoked);
                    }
                    Err(error) => break Err(error),
                }
            }
        }
    };
    live_sessions.abort_all().await;
    drop(approval_prompts);
    outcome
}

async fn open_session_socket(url: &str, token: &str) -> Result<WebSocketStream<WsIo>, String> {
    validate_websocket_url(url, "session")?;
    let mut request = url
        .to_owned()
        .into_client_request()
        .map_err(|error| format!("parse session url: {error}"))?;
    let value = HeaderValue::from_str(&format!("Bearer {token}"))
        .map_err(|error| format!("build session auth header: {error}"))?;
    request.headers_mut().insert("Authorization", value);
    tokio_tungstenite::connect_async_with_config(request, Some(websocket_config()), false)
        .await
        .map(|(stream, _)| stream)
        .map_err(|error| format!("open session websocket: {error}"))
}

/// Link this Mac once and persist the granted device token without starting
/// the long-lived relay. `thumble relay start` can be launched afterwards.
pub async fn run_link(config: &RelayConfig) -> Result<(), String> {
    if read_token_file(&config.token_file)?.is_some() {
        eprintln!("thumble relay: device is already linked; use `relay rotate` to authorize again");
        return Ok(());
    }
    let websocket = connect_control(&config.link_url(), None).await?;
    link_device(config, websocket).await?;
    eprintln!("thumble relay: device linked; start `thumble relay connect` to serve MCP");
    Ok(())
}

/// Replace an existing device token. A running relay notices the atomic token
/// replacement and reconnects without requiring a second manually managed
/// process.
/// Replace an existing device token. The link socket authenticates with the
/// current token so the gateway rotates this device's credential in place:
/// the Mac keeps its device identity, OAuth bindings, and cached manifest,
/// and there is never a window where both the old and new tokens are valid.
/// A running relay notices the atomic token replacement and reconnects
/// without requiring a second manually managed process.
pub async fn run_relink(config: &RelayConfig) -> Result<(), String> {
    let previous_token = read_token_file(&config.token_file)?;
    let websocket = match previous_token.as_deref() {
        Some(token) => connect_control(&config.link_url(), Some(token))
            .await
            .map_err(|error| {
                format!(
                    "{error}; if the stored link is stale, run `thumble relay revoke` (or delete \
                     the token file) and then `thumble relay link`"
                )
            })?,
        None => {
            eprintln!("thumble relay: no stored device token; rotating as a fresh first-time link");
            connect_control(&config.link_url(), None).await?
        }
    };
    link_device(config, websocket).await?;
    eprintln!("thumble relay: device link rotated in place; the managed relay will reconnect automatically");
    Ok(())
}

/// Run the relay forever with reconnect backoff until `shutdown` fires.
pub async fn run_relay(
    config: RelayConfig,
    mut shutdown: watch::Receiver<bool>,
) -> Result<RelayOutcome, String> {
    let _relay_lock = acquire_relay_lock(&config.token_file)?;
    let mut backoff = RELAY_BACKOFF_INITIAL;
    loop {
        if read_token_file(&config.token_file)?.is_none() || config.allow_config_write {
            if let Err(error) = ensure_local_host_ready(&config).await {
                eprintln!("thumble relay: waiting for local prerequisites: {error}");
                let wait = tokio::time::sleep(backoff);
                tokio::select! {
                    _ = wait => {},
                    changed = shutdown.changed() => {
                        if changed.is_err() || *shutdown.borrow() {
                            return Ok(RelayOutcome::Stopped);
                        }
                    }
                }
                backoff = (backoff * 2).min(RELAY_BACKOFF_MAXIMUM);
                continue;
            }
        }
        match run_relay_once(&config, &mut shutdown).await {
            Ok(RelayOutcome::Stopped) => return Ok(RelayOutcome::Stopped),
            Ok(RelayOutcome::Disconnected) => {}
            Ok(RelayOutcome::Revoked) => return Ok(RelayOutcome::Revoked),
            Err(error) => {
                eprintln!("thumble relay: {error}");
            }
        }
        let wait = tokio::time::sleep(backoff);
        tokio::select! {
            _ = wait => {},
            changed = shutdown.changed() => {
                if changed.is_err() || *shutdown.borrow() {
                    return Ok(RelayOutcome::Stopped);
                }
            }
        }
        backoff = (backoff * 2).min(RELAY_BACKOFF_MAXIMUM);
    }
}

async fn revoke_token_at_gateway(config: &RelayConfig, token: &str) -> Result<(), String> {
    let mut websocket = connect_control(&config.revoke_url(), Some(token)).await?;
    websocket
        .send(Message::text(
            thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::RevokeRequest),
        ))
        .await
        .map_err(|error| format!("send revoke request: {error}"))?;
    let reply = tokio::time::timeout(Duration::from_secs(30), websocket.next())
        .await
        .map_err(|_| "revoke request timed out".to_owned())?
        .ok_or_else(|| "relay closed before revocation".to_owned())?
        .map_err(|error| format!("read revoke reply: {error}"))?;
    match thumble_tunnel::ws_rpc::decode_control_message(&reply.into_data()) {
        Some(TunnelMessage::RevokeGranted { .. }) => Ok(()),
        _ => Err("relay did not confirm the revocation".to_owned()),
    }
}

/// One-shot: ask the gateway to revoke this device token, then delete the
/// local token file.
pub async fn run_revoke(config: &RelayConfig) -> Result<(), String> {
    let token = read_token_file(&config.token_file)?
        .ok_or_else(|| "no relay token file to revoke".to_owned())?;
    revoke_token_at_gateway(config, &token).await?;
    delete_token_file(&config.token_file);
    eprintln!("thumble relay: device token revoked");
    Ok(())
}

/// One doctor check: `ok` when healthy, `warn` for degraded-but-usable,
/// `fail` for blocking, and `skip` when not applicable on this platform.
#[derive(Debug, Clone, Copy, PartialEq)]
enum DoctorStatus {
    Ok,
    Warn,
    Fail,
    Skip,
}

impl DoctorStatus {
    fn as_str(self) -> &'static str {
        match self {
            DoctorStatus::Ok => "ok",
            DoctorStatus::Warn => "warn",
            DoctorStatus::Fail => "fail",
            DoctorStatus::Skip => "skip",
        }
    }
}

struct DoctorCheck {
    id: &'static str,
    label: &'static str,
    status: DoctorStatus,
    detail: String,
    fix: Option<&'static str>,
}

impl DoctorCheck {
    fn ok(id: &'static str, label: &'static str, detail: String) -> Self {
        Self {
            id,
            label,
            status: DoctorStatus::Ok,
            detail,
            fix: None,
        }
    }
    fn unhealthy(
        id: &'static str,
        label: &'static str,
        status: DoctorStatus,
        detail: String,
        fix: &'static str,
    ) -> Self {
        Self {
            id,
            label,
            status,
            detail,
            fix: Some(fix),
        }
    }

    fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "id": self.id,
            "label": self.label,
            "status": self.status.as_str(),
            "detail": self.detail,
            "fix": self.fix,
        })
    }
}

fn launch_agent_plist_path() -> Option<PathBuf> {
    if !cfg!(target_os = "macos") {
        return None;
    }
    std::env::var_os("HOME").map(|home| {
        PathBuf::from(home).join("Library/LaunchAgents/com.codybontecou.thumble.mcp-relay.plist")
    })
}

/// Diagnose every local prerequisite for remote MCP connectors: the host
/// process, the Swift bridge, the stored device link, the serving relay, and
/// the launch agent. The CLI merges this with gateway-side status to produce
/// the full `thumble relay doctor` report. Returns `false` when at least one
/// check failed (the process exit code mirrors it).
pub async fn run_doctor(config: &RelayConfig, json_output: bool) -> Result<bool, String> {
    let mut checks: Vec<DoctorCheck> = Vec::new();

    // Thumble Host itself.
    let mut host_detail = String::new();
    let host_status = match send_request(&config.control_socket, &ControlRequest::Status).await {
        Ok(response) if response.ok => response.status.inspect(|status| {
            host_detail = format!(
                "running on port {} (input {}, configuration writes {})",
                status.requested_port,
                if status.input_enabled { "on" } else { "off" },
                if status.configuration_write_enabled {
                    "on"
                } else {
                    "off"
                },
            );
        }),
        Ok(response) => {
            host_detail = response
                .error
                .unwrap_or_else(|| "Thumble Host rejected its status request".to_owned());
            None
        }
        Err(error) => {
            host_detail = error;
            None
        }
    };
    checks.push(match host_status {
        Some(_) => DoctorCheck::ok("host", "Thumble Host", host_detail),
        None => DoctorCheck::unhealthy(
            "host",
            "Thumble Host",
            DoctorStatus::Fail,
            host_detail,
            "start it with `thumble server start` (or open the Thumble Mac app; add --allow-config-write if ChatGPT should save profiles)",
        ),
    });

    // Swift bridge + configuration gate (only meaningful while the host runs).
    if host_status.is_some() {
        let configuration =
            send_request(&config.control_socket, &ControlRequest::ConfigurationStatus).await;
        checks.push(match configuration {
            Ok(response) if response.ok && response.configuration.is_some() => {
                let summary = response.configuration.unwrap();
                if summary.bridge_available {
                    DoctorCheck::ok(
                        "bridge",
                        "Swift bridge",
                        format!(
                            "available (configuration writes {})",
                            if summary.configuration_write_enabled {
                                "enabled"
                            } else {
                                "disabled"
                            },
                        ),
                    )
                } else {
                    DoctorCheck::unhealthy(
                        "bridge",
                        "Swift bridge",
                        DoctorStatus::Warn,
                        "not found next to the host binary".to_owned(),
                        "reinstall Thumble so thumble-bridge sits beside thumble-host",
                    )
                }
            }
            _ => DoctorCheck::unhealthy(
                "bridge",
                "Swift bridge",
                DoctorStatus::Warn,
                "configuration status unavailable".to_owned(),
                "restart Thumble Host and retry",
            ),
        });
    }

    // Stored device link.
    let linked = match read_token_file(&config.token_file) {
        Ok(Some(_)) => true,
        Ok(None) => false,
        Err(_) => false,
    };
    checks.push(if linked {
        DoctorCheck::ok(
            "link",
            "Device link",
            format!("token stored at {}", config.token_file.display()),
        )
    } else {
        DoctorCheck::unhealthy(
            "link",
            "Device link",
            DoctorStatus::Fail,
            "no gateway device token is stored".to_owned(),
            "run `thumble relay link`, click Connect in ChatGPT, then click Allow on this Mac (use the displayed code only as a headless fallback)",
        )
    });

    // Token hygiene (warnings, not blockers).
    if linked {
        let token_mode = std::fs::metadata(&config.token_file)
            .ok()
            .map(|metadata| metadata.permissions().mode() & 0o777);
        let dir_mode = config
            .token_file
            .parent()
            .and_then(|parent| std::fs::metadata(parent).ok())
            .map(|metadata| metadata.permissions().mode() & 0o777);
        if token_mode == Some(0o600) && dir_mode.is_some_and(|mode| mode & 0o077 == 0) {
            checks.push(DoctorCheck::ok(
                "tokenFile",
                "Token hygiene",
                "token is user-only inside a private state directory".to_owned(),
            ));
        } else {
            checks.push(DoctorCheck::unhealthy(
                "tokenFile",
                "Token hygiene",
                DoctorStatus::Warn,
                format!(
                    "token mode {:o}, state directory mode {:o}",
                    token_mode.unwrap_or(0),
                    dir_mode.unwrap_or(0)
                ),
                "run `chmod 600` on the token file and `chmod 700` on its directory",
            ));
        }
    }

    // Serving relay process (the singleton lock answers without racing).
    let relay_running = acquire_relay_lock(&config.token_file).is_err();
    checks.push(if relay_running {
        DoctorCheck::ok(
            "relay",
            "Relay process",
            "a Thumble relay holds the serving lock".to_owned(),
        )
    } else {
        DoctorCheck::unhealthy(
            "relay",
            "Relay process",
            DoctorStatus::Fail,
            "no relay process is serving remote sessions".to_owned(),
            "run `thumble relay connect`, or `thumble relay install` for a background service",
        )
    });

    // Launch agent (macOS background service; optional convenience).
    checks.push(match launch_agent_plist_path() {
        Some(path) if path.exists() => DoctorCheck::ok(
            "launchAgent",
            "Launch agent",
            format!("installed at {}", path.display()),
        ),
        Some(path) => DoctorCheck::unhealthy(
            "launchAgent",
            "Launch agent",
            DoctorStatus::Warn,
            format!("not installed (expected {})", path.display()),
            "run `thumble relay install` to keep the relay running in the background",
        ),
        None => DoctorCheck {
            id: "launchAgent",
            label: "Launch agent",
            status: DoctorStatus::Skip,
            detail: "not applicable on this platform".to_owned(),
            fix: None,
        },
    });

    let ready = checks
        .iter()
        .all(|check| check.status != DoctorStatus::Fail);
    if json_output {
        let report = serde_json::json!({
            "ready": ready,
            "checks": checks.iter().map(DoctorCheck::to_json).collect::<Vec<_>>(),
        });
        println!(
            "{}",
            serde_json::to_string_pretty(&report)
                .map_err(|error| format!("encode doctor report: {error}"))?
        );
    } else {
        for check in &checks {
            let marker = match check.status {
                DoctorStatus::Ok => "ok",
                DoctorStatus::Warn => "!!",
                DoctorStatus::Fail => "XX",
                DoctorStatus::Skip => "--",
            };
            eprintln!("  [{marker}] {}: {}", check.label, check.detail);
            if let Some(fix) = check.fix {
                eprintln!("        fix: {fix}");
            }
        }
        eprintln!("overall: {}", if ready { "ready" } else { "not ready" });
    }
    Ok(ready)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Arc;

    fn token_path() -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir().unwrap();
        std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let path = dir.path().join("relay-token");
        (dir, path)
    }

    #[test]
    fn token_file_round_trip_is_user_only() {
        let (_dir, path) = token_path();
        assert!(read_token_file(&path).unwrap().is_none());
        write_token_file(&path, &thumble_tunnel::random_token(32)).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert!(read_token_file(&path).unwrap().is_some());
        delete_token_file(&path);
        assert!(read_token_file(&path).unwrap().is_none());
    }

    #[test]
    fn short_token_files_are_rejected() {
        let (_dir, path) = token_path();
        std::fs::write(&path, "short").unwrap();
        assert!(read_token_file(&path).is_err());
    }

    #[test]
    fn approval_prompt_never_treats_timeout_or_unknown_output_as_allow() {
        assert_eq!(
            parse_approval_prompt_output("button returned:Allow, gave up:false"),
            ApprovalPromptOutcome::Approved
        );
        assert_eq!(
            parse_approval_prompt_output("button returned:Deny, gave up:false"),
            ApprovalPromptOutcome::Denied
        );
        assert_eq!(
            parse_approval_prompt_output("button returned:Allow, gave up:true"),
            ApprovalPromptOutcome::Unavailable
        );
        assert_eq!(
            parse_approval_prompt_output("unexpected output"),
            ApprovalPromptOutcome::Unavailable
        );
        assert_eq!(approval_display_value("Chat\nGPT", 128), "Chat GPT");
        assert_eq!(approval_display_value("abcdef", 3), "abc");
    }

    #[test]
    fn token_replacement_is_atomic_and_leaves_only_the_current_credential() {
        let (directory, path) = token_path();
        let first = thumble_tunnel::random_token(32);
        let second = thumble_tunnel::random_token(32);
        write_token_file(&path, &first).unwrap();
        write_token_file(&path, &second).unwrap();
        assert_eq!(
            read_token_file(&path).unwrap().as_deref(),
            Some(second.as_str())
        );
        let temporary_files = std::fs::read_dir(directory.path())
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| {
                entry
                    .file_name()
                    .to_string_lossy()
                    .contains(".relay-token.")
            })
            .count();
        assert_eq!(temporary_files, 0);
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }

    #[test]
    fn relay_lock_prevents_duplicate_long_lived_processes() {
        let (_directory, path) = token_path();
        let first = acquire_relay_lock(&path).unwrap();
        assert!(acquire_relay_lock(&path).is_err());
        drop(first);
        assert!(acquire_relay_lock(&path).is_ok());
    }

    #[tokio::test]
    async fn revoke_uses_the_separate_endpoint_and_deletes_the_token_file() {
        use futures::{SinkExt as _, StreamExt as _};
        use tokio::net::TcpListener;

        let (_dir, token_file) = token_path();
        let token = thumble_tunnel::random_token(32);
        write_token_file(&token_file, &token).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let expected_auth = format!("Bearer {token}");
        let server = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut websocket = tokio_tungstenite::accept_hdr_async(
                tokio_tungstenite::MaybeTlsStream::Plain(stream),
                move |request: &tokio_tungstenite::tungstenite::http::Request<()>, response| {
                    assert_eq!(request.uri().path(), "/tunnel/revoke");
                    assert_eq!(
                        request
                            .headers()
                            .get("Authorization")
                            .unwrap()
                            .to_str()
                            .unwrap(),
                        expected_auth
                    );
                    Ok(response)
                },
            )
            .await
            .unwrap();
            let request = websocket.next().await.unwrap().unwrap();
            assert!(matches!(
                thumble_tunnel::ws_rpc::decode_control_message(&request.into_data()),
                Some(TunnelMessage::RevokeRequest)
            ));
            websocket
                .send(Message::text(
                    thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::RevokeGranted {
                        detail: None,
                    }),
                ))
                .await
                .unwrap();
        });
        let config = RelayConfig {
            relay_url: format!("ws://{address}/tunnel"),
            token_file: token_file.clone(),
            device_name: "Mac".to_owned(),
            control_socket: PathBuf::from("/tmp/not-used.sock"),
            allow_input: false,
            allow_config_write: false,
        };
        run_revoke(&config).await.unwrap();
        server.await.unwrap();
        assert!(read_token_file(&token_file).unwrap().is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn revoke_aborts_and_closes_every_active_session() {
        use futures::{SinkExt as _, StreamExt as _};
        use tokio::net::TcpListener;

        let (_dir, token_file) = token_path();
        write_token_file(&token_file, &thumble_tunnel::random_token(32)).unwrap();
        let control_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let session_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let control_address = control_listener.local_addr().unwrap();
        let session_address = session_listener.local_addr().unwrap();
        let config = RelayConfig {
            relay_url: format!("ws://{control_address}/tunnel"),
            token_file: token_file.clone(),
            device_name: "Mac".to_owned(),
            control_socket: PathBuf::from("/tmp/not-used.sock"),
            allow_input: false,
            allow_config_write: false,
        };
        let (_stop_tx, stop_rx) = watch::channel(false);
        let relay = tokio::spawn(run_relay(config, stop_rx));

        let (stream, _) = control_listener.accept().await.unwrap();
        let mut control =
            tokio_tungstenite::accept_async(tokio_tungstenite::MaybeTlsStream::Plain(stream))
                .await
                .unwrap();
        assert!(matches!(
            next_test_control_frame(&mut control).await,
            TunnelMessage::Manifest { .. }
        ));
        control
            .send(Message::text(
                thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::OpenSession {
                    session_id: "active-session".to_owned(),
                    session_url: format!("ws://{session_address}/tunnel/session/active-session"),
                }),
            ))
            .await
            .unwrap();
        let (stream, _) = session_listener.accept().await.unwrap();
        let mut session =
            tokio_tungstenite::accept_async(tokio_tungstenite::MaybeTlsStream::Plain(stream))
                .await
                .unwrap();

        control
            .send(Message::text(
                thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::RevokeGranted {
                    detail: None,
                }),
            ))
            .await
            .unwrap();
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(5), relay)
                .await
                .unwrap()
                .unwrap()
                .unwrap(),
            RelayOutcome::Revoked
        );
        assert!(read_token_file(&token_file).unwrap().is_none());
        let closed = tokio::time::timeout(Duration::from_secs(5), session.next())
            .await
            .expect("active session closes on revoke");
        assert!(matches!(
            closed,
            None | Some(Ok(Message::Close(_))) | Some(Err(_))
        ));
    }

    async fn next_test_control_frame(websocket: &mut WebSocketStream<WsIo>) -> TunnelMessage {
        loop {
            let message = websocket.next().await.unwrap().unwrap();
            if let Some(frame) =
                thumble_tunnel::ws_rpc::decode_control_message(&message.into_data())
            {
                return frame;
            }
        }
    }

    #[test]
    fn session_urls_derive_from_the_control_url() {
        let (_dir, path) = token_path();
        let config = RelayConfig {
            relay_url: "wss://mcp.thumble.app/tunnel".to_owned(),
            token_file: path,
            device_name: "Mac".to_owned(),
            control_socket: PathBuf::from("/tmp/control.sock"),
            allow_input: false,
            allow_config_write: false,
        };
        assert_eq!(
            config.session_url("tunnel/session/abc"),
            "wss://mcp.thumble.app/tunnel/session/abc"
        );
        assert_eq!(config.link_url(), "wss://mcp.thumble.app/tunnel/link");
        assert_eq!(config.revoke_url(), "wss://mcp.thumble.app/tunnel/revoke");
    }

    #[test]
    fn websocket_urls_require_tls_outside_loopback() {
        assert!(validate_websocket_url("wss://mcp.thumble.app/tunnel", "relay").is_ok());
        assert!(validate_websocket_url("ws://127.0.0.1:8080/tunnel", "relay").is_ok());
        assert!(validate_websocket_url("ws://mcp.thumble.app/tunnel", "relay").is_err());
        assert!(validate_websocket_url("https://mcp.thumble.app/tunnel", "relay").is_err());
        assert!(same_websocket_origin(
            "wss://mcp.thumble.app/tunnel",
            "wss://mcp.thumble.app/tunnel/session/1"
        ));
        assert!(!same_websocket_origin(
            "wss://mcp.thumble.app/tunnel",
            "wss://evil.example/session/1"
        ));
    }

    // ---- End-to-end relay test against an in-process mock gateway ----

    struct StatusOnlyHost;

    impl thumble_host::control::ControlHandler for StatusOnlyHost {
        fn handle(
            &self,
            request: thumble_host::control::ControlRequest,
        ) -> thumble_host::control::ControlResponse {
            match request {
                thumble_host::control::ControlRequest::Status => {
                    let mut response = thumble_host::control::ControlResponse::success();
                    response.status = Some(thumble_host::control::HostStatus {
                        pid: std::process::id(),
                        version: "test".to_owned(),
                        port: 0,
                        requested_port: 0,
                        bonjour: thumble_host::bonjour::BonjourInfo {
                            enabled: false,
                            registered: false,
                            state: "disabled".to_owned(),
                            service_name: String::new(),
                            error: None,
                        },
                        service_name: "thumble-test".to_owned(),
                        urls: Vec::new(),
                        accessibility_trusted: false,
                        input_enabled: false,
                        configuration_write_enabled: false,
                        state_path: String::new(),
                        control_socket: String::new(),
                        server_id: "test-server".to_owned(),
                        pairing_code: String::new(),
                        core: thumble_core::StatusSnapshot {
                            running: true,
                            paired: true,
                            client_name: Some("iPhone".to_owned()),
                            pairing_pending: false,
                            active_generation: None,
                            pressed_buttons: Vec::new(),
                            pressed_elements: Vec::new(),
                            active_pointer_buttons: Vec::new(),
                            active_profile_id: "profile-safe".to_owned(),
                            default_profile_id: "profile-safe".to_owned(),
                            configuration_revision: 1,
                            counters: thumble_core::StatusCounters {
                                messages_received: 0,
                                accepted_inputs: 0,
                                ignored_inputs: 0,
                                duplicate_sequences: 0,
                                rejected_inputs: 0,
                                stale_generations: 0,
                                pairing_rejections: 0,
                                expired_holds: 0,
                                release_all_events: 0,
                            },
                            status_text: "ok".to_owned(),
                        },
                        output: thumble_host::output::OutputSnapshot {
                            mode: "keyboard".to_owned(),
                            events_executed: 0,
                            held_key_count: 0,
                            pending_key_release_count: 0,
                            held_pointer_buttons: Vec::new(),
                            pending_pointer_releases: Vec::new(),
                            recent_events: Vec::new(),
                        },
                    });
                    response
                }
                _ => thumble_host::control::ControlResponse::success(),
            }
        }
    }

    async fn next_control_frame(websocket: &mut WebSocketStream<WsIo>) -> TunnelMessage {
        loop {
            let message = tokio::time::timeout(Duration::from_secs(30), websocket.next())
                .await
                .expect("control frame timeout")
                .expect("control websocket closed")
                .expect("control websocket error");
            if let Some(frame) =
                thumble_tunnel::ws_rpc::decode_control_message(&message.into_data())
            {
                return frame;
            }
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn relay_reloads_an_atomically_rotated_token() {
        use thumble_host::control::{bind_control_socket, remove_control_socket, serve_control};
        use tokio::net::TcpListener;
        use tokio::sync::oneshot;

        let host_dir = tempfile::tempdir().unwrap();
        std::fs::set_permissions(host_dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = host_dir.path().join("control.sock");
        let listener = bind_control_socket(&socket).await.unwrap();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let control_task = tokio::spawn(serve_control(
            listener,
            Arc::new(StatusOnlyHost),
            shutdown_rx,
        ));

        let gateway_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let gateway_port = gateway_listener.local_addr().unwrap().port();
        let first_token = thumble_tunnel::random_token(32);
        let second_token = thumble_tunnel::random_token(32);
        let (manifest_tx, manifest_rx) = oneshot::channel();
        let (second_manifest_tx, second_manifest_rx) = oneshot::channel();
        let expected_first = format!("Bearer {first_token}");
        let expected_second = format!("Bearer {second_token}");
        let gateway_task = tokio::spawn(async move {
            let (stream, _) = gateway_listener.accept().await.unwrap();
            let mut first = tokio_tungstenite::accept_hdr_async(
                tokio_tungstenite::MaybeTlsStream::Plain(stream),
                move |request: &tokio_tungstenite::tungstenite::http::Request<()>, response| {
                    assert_eq!(
                        request
                            .headers()
                            .get("Authorization")
                            .unwrap()
                            .to_str()
                            .unwrap(),
                        expected_first
                    );
                    Ok(response)
                },
            )
            .await
            .unwrap();
            assert!(matches!(
                next_control_frame(&mut first).await,
                TunnelMessage::Manifest { .. }
            ));
            manifest_tx.send(()).unwrap();

            let (stream, _) = gateway_listener.accept().await.unwrap();
            let mut second = tokio_tungstenite::accept_hdr_async(
                tokio_tungstenite::MaybeTlsStream::Plain(stream),
                move |request: &tokio_tungstenite::tungstenite::http::Request<()>, response| {
                    assert_eq!(
                        request
                            .headers()
                            .get("Authorization")
                            .unwrap()
                            .to_str()
                            .unwrap(),
                        expected_second
                    );
                    Ok(response)
                },
            )
            .await
            .unwrap();
            assert!(matches!(
                next_control_frame(&mut second).await,
                TunnelMessage::Manifest { .. }
            ));
            second_manifest_tx.send(()).unwrap();
            // Stay alive like a healthy gateway: answer probes until closed.
            while let Some(Ok(message)) = second.next().await {
                if matches!(
                    thumble_tunnel::ws_rpc::decode_control_message(&message.into_data()),
                    Some(TunnelMessage::Ping)
                ) && second
                    .send(Message::text(
                        thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::Pong),
                    ))
                    .await
                    .is_err()
                {
                    break;
                }
            }
        });

        let (token_dir, token_file) = token_path();
        write_token_file(&token_file, &first_token).unwrap();
        let config = RelayConfig {
            relay_url: format!("ws://127.0.0.1:{gateway_port}/tunnel"),
            token_file: token_file.clone(),
            device_name: "Rotation Test Mac".to_owned(),
            control_socket: socket.clone(),
            allow_input: false,
            allow_config_write: false,
        };
        let (stop_tx, stop_rx) = watch::channel(false);
        let relay_task = tokio::spawn(run_relay(config, stop_rx));
        manifest_rx.await.unwrap();
        write_token_file(&token_file, &second_token).unwrap();

        // The serving relay notices the atomic replacement, reconnects with
        // the new credential, and stays up (no revocation is involved).
        second_manifest_rx.await.unwrap();
        let _ = stop_tx.send(true);
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(10), relay_task)
                .await
                .unwrap()
                .unwrap()
                .unwrap(),
            RelayOutcome::Stopped
        );
        gateway_task.await.unwrap();
        assert_eq!(
            read_token_file(&token_file).unwrap().as_deref(),
            Some(second_token.as_str())
        );
        let _ = shutdown_tx.send(true);
        let _ = control_task.await;
        remove_control_socket(&socket);
        drop(token_dir);
        drop(host_dir);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn relink_presents_the_stored_token_and_rotates_in_place() {
        use tokio::net::TcpListener;
        use tokio::sync::oneshot;

        // The link socket must authenticate with the current device token so
        // the gateway rotates that device's credential in place instead of
        // minting a second identity for the same Mac.
        let gateway_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let gateway_port = gateway_listener.local_addr().unwrap().port();
        let old_token = thumble_tunnel::random_token(32);
        let new_token = thumble_tunnel::random_token(32);
        let new_token_for_task = new_token.clone();
        let expected_auth = format!("Bearer {old_token}");
        let (granted_tx, granted_rx) = oneshot::channel();
        let gateway_task = tokio::spawn(async move {
            let (stream, _) = gateway_listener.accept().await.unwrap();
            let mut link = tokio_tungstenite::accept_hdr_async(
                tokio_tungstenite::MaybeTlsStream::Plain(stream),
                move |request: &tokio_tungstenite::tungstenite::http::Request<()>, response| {
                    assert_eq!(
                        request
                            .headers()
                            .get("Authorization")
                            .unwrap()
                            .to_str()
                            .unwrap(),
                        expected_auth
                    );
                    Ok(response)
                },
            )
            .await
            .unwrap();
            match next_control_frame(&mut link).await {
                TunnelMessage::LinkRequest { device_name } => {
                    assert_eq!(device_name, "Rotation Test Mac");
                }
                other => panic!("expected LinkRequest, got {other:?}"),
            }
            link.send(Message::text(
                thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::LinkGranted {
                    device_id: "dev_existing".to_owned(),
                    device_token: new_token_for_task.clone(),
                }),
            ))
            .await
            .unwrap();
            assert!(matches!(
                next_control_frame(&mut link).await,
                TunnelMessage::LinkPersisted { ref device_id }
                    if device_id == "dev_existing"
            ));
            granted_tx.send(()).unwrap();
        });

        let (token_dir, token_file) = token_path();
        write_token_file(&token_file, &old_token).unwrap();
        let config = RelayConfig {
            relay_url: format!("ws://127.0.0.1:{gateway_port}/tunnel"),
            token_file: token_file.clone(),
            device_name: "Rotation Test Mac".to_owned(),
            control_socket: PathBuf::from("/nonexistent/control.sock"),
            allow_input: false,
            allow_config_write: false,
        };
        run_relink(&config).await.unwrap();
        granted_rx.await.unwrap();
        assert_eq!(
            read_token_file(&token_file).unwrap().as_deref(),
            Some(new_token.as_str())
        );
        gateway_task.await.unwrap();
        drop(token_dir);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn relay_reconnects_after_silent_and_protocol_noise_only_control_channels() {
        use thumble_host::control::{bind_control_socket, remove_control_socket, serve_control};
        use tokio::net::TcpListener;
        use tokio::sync::oneshot;

        // NAT/edge-teardown failures can leave the socket open locally either
        // with no inbound frames at all or with only protocol ping/pong noise.
        // The relay must require an application-level Pong and reconnect after
        // both failure modes instead of waiting for TCP retransmission.
        let host_dir = tempfile::tempdir().unwrap();
        std::fs::set_permissions(host_dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = host_dir.path().join("control.sock");
        let listener = bind_control_socket(&socket).await.unwrap();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let control_task = tokio::spawn(serve_control(
            listener,
            Arc::new(StatusOnlyHost),
            shutdown_rx,
        ));

        let gateway_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let gateway_port = gateway_listener.local_addr().unwrap().port();
        let token = thumble_tunnel::random_token(32);
        let (healthy_manifest_tx, healthy_manifest_rx) = oneshot::channel();

        let gateway_task = tokio::spawn(async move {
            // Connection 1: consume the manifest and client probes but send no
            // frames at all. A token-file tick faster than CONTROL_IDLE_PING
            // must not starve the independent dead-peer deadline.
            let (stream, _) = gateway_listener.accept().await.unwrap();
            let mut silent =
                tokio_tungstenite::accept_async(tokio_tungstenite::MaybeTlsStream::Plain(stream))
                    .await
                    .unwrap();
            assert!(matches!(
                next_control_frame(&mut silent).await,
                TunnelMessage::Manifest { .. }
            ));
            let silent_closed = tokio::time::timeout(Duration::from_secs(10), async {
                while let Some(Ok(message)) = silent.next().await {
                    if matches!(message, Message::Close(_)) {
                        break;
                    }
                    // Deliberately ignore application-level Ping probes.
                }
            })
            .await;
            assert!(
                silent_closed.is_ok(),
                "relay must close a completely silent half-open control channel"
            );

            // Connection 2: behave like an edge proxy in front of a dead
            // origin—emit protocol-level WebSocket pings only and never an
            // application-level Pong.
            let (stream, _) = gateway_listener.accept().await.unwrap();
            let mut noisy =
                tokio_tungstenite::accept_async(tokio_tungstenite::MaybeTlsStream::Plain(stream))
                    .await
                    .unwrap();
            assert!(matches!(
                next_control_frame(&mut noisy).await,
                TunnelMessage::Manifest { .. }
            ));
            let mut edge_noise = tokio::time::interval(Duration::from_millis(150));
            // A protocol frame payload that is valid control JSON must still
            // never reset application-level liveness.
            let deceptive_ping_payload =
                thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::Pong).into_bytes();
            let noisy_closed = tokio::time::timeout(Duration::from_secs(10), async {
                loop {
                    tokio::select! {
                        _ = edge_noise.tick() => {
                            if noisy
                                .send(Message::Ping(deceptive_ping_payload.clone().into()))
                                .await
                                .is_err()
                            {
                                break;
                            }
                        }
                        inbound = noisy.next() => match inbound {
                            None | Some(Err(_)) => break,
                            Some(Ok(message)) => {
                                if matches!(message, Message::Close(_)) {
                                    break;
                                }
                                // Protocol keepalives only; no app frames.
                            }
                        },
                    }
                }
            })
            .await;
            assert!(
                noisy_closed.is_ok(),
                "relay must close a control channel with only protocol noise"
            );

            // Connection 3: behave like a healthy gateway.
            let (stream, _) = gateway_listener.accept().await.unwrap();
            let mut healthy =
                tokio_tungstenite::accept_async(tokio_tungstenite::MaybeTlsStream::Plain(stream))
                    .await
                    .unwrap();
            assert!(matches!(
                next_control_frame(&mut healthy).await,
                TunnelMessage::Manifest { .. }
            ));
            let mut healthy_manifest_tx = Some(healthy_manifest_tx);
            let mut healthy_probe_count = 0;
            while let Some(Ok(message)) = healthy.next().await {
                if matches!(
                    thumble_tunnel::ws_rpc::decode_control_message(&message.into_data()),
                    Some(TunnelMessage::Ping)
                ) {
                    use futures::SinkExt as _;
                    if healthy
                        .send(Message::text(
                            thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::Pong),
                        ))
                        .await
                        .is_err()
                    {
                        break;
                    }
                    healthy_probe_count += 1;
                    if healthy_probe_count > MAXIMUM_MISSED_IDLE_PINGS {
                        if let Some(ready) = healthy_manifest_tx.take() {
                            ready.send(()).unwrap();
                        }
                    }
                }
            }
        });

        let (token_dir, token_file) = token_path();
        write_token_file(&token_file, &token).unwrap();
        let config = RelayConfig {
            relay_url: format!("ws://127.0.0.1:{gateway_port}/tunnel"),
            token_file: token_file.clone(),
            device_name: "Dead Peer Mac".to_owned(),
            control_socket: socket.clone(),
            allow_input: false,
            allow_config_write: false,
        };
        let (stop_tx, stop_rx) = watch::channel(false);
        let relay_task = tokio::spawn(run_relay(config, stop_rx));

        // The relay recovers onto the healthy third connection and survives
        // through a complete application-level Ping/Pong exchange.
        tokio::time::timeout(Duration::from_secs(10), healthy_manifest_rx)
            .await
            .expect("healthy relay must survive beyond the missed-ping threshold")
            .unwrap();
        let _ = stop_tx.send(true);
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(10), relay_task)
                .await
                .unwrap()
                .unwrap()
                .unwrap(),
            RelayOutcome::Stopped
        );
        gateway_task.await.unwrap();
        let _ = shutdown_tx.send(true);
        let _ = control_task.await;
        remove_control_socket(&socket);
        drop(token_dir);
        drop(host_dir);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn relay_links_publishes_manifest_and_serves_a_remote_session() {
        use futures::SinkExt as _;
        use thumble_host::control::{bind_control_socket, remove_control_socket, serve_control};
        use tokio::net::TcpListener;

        // Local host with a bound control socket.
        let host_dir = tempfile::tempdir().unwrap();
        std::fs::set_permissions(host_dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = host_dir.path().join("control.sock");
        let listener = bind_control_socket(&socket).await.unwrap();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let control_task = tokio::spawn(serve_control(
            listener,
            Arc::new(StatusOnlyHost),
            shutdown_rx,
        ));

        // Mock gateway: control listener + session listener.
        let control_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let session_listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let control_port = control_listener.local_addr().unwrap().port();
        let session_port = session_listener.local_addr().unwrap().port();

        let gateway_task = tokio::spawn(async move {
            use rmcp::ServiceExt as _;
            // Connection 1: unauthenticated link flow.
            let (stream, _) = control_listener.accept().await.unwrap();
            let mut link_ws =
                tokio_tungstenite::accept_async(tokio_tungstenite::MaybeTlsStream::Plain(stream))
                    .await
                    .unwrap();
            match next_control_frame(&mut link_ws).await {
                TunnelMessage::LinkRequest { .. } => {}
                other => panic!("expected LinkRequest, got {other:?}"),
            }
            link_ws
                .send(Message::text(
                    thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::LinkOffer {
                        code: "123456".to_owned(),
                        url: format!("http://127.0.0.1:{control_port}/link"),
                        expires_in: 300,
                    }),
                ))
                .await
                .unwrap();
            let device_token = thumble_tunnel::random_token(32);
            link_ws
                .send(Message::text(
                    thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::LinkGranted {
                        device_id: "device-1".to_owned(),
                        device_token: device_token.clone(),
                    }),
                ))
                .await
                .unwrap();
            assert!(matches!(
                next_control_frame(&mut link_ws).await,
                TunnelMessage::LinkPersisted { ref device_id } if device_id == "device-1"
            ));
            drop(link_ws);

            // Connection 2: authenticated control channel.
            let expected_auth = format!("Bearer {device_token}");
            let (stream, _) = control_listener.accept().await.unwrap();
            let mut control_ws = tokio_tungstenite::accept_hdr_async(
                tokio_tungstenite::MaybeTlsStream::Plain(stream),
                move |request: &tokio_tungstenite::tungstenite::http::Request<()>,
                      response: tokio_tungstenite::tungstenite::http::Response<()>| {
                    let auth = request
                        .headers()
                        .get("Authorization")
                        .and_then(|value| value.to_str().ok())
                        .unwrap_or_default()
                        .to_owned();
                    if auth != expected_auth {
                        let rejection = tokio_tungstenite::tungstenite::http::Response::builder()
                            .status(401)
                            .body(Some("unauthorized device token".to_owned()))
                            .unwrap();
                        return Err(rejection);
                    }
                    Ok(response)
                },
            )
            .await
            .unwrap();

            match next_control_frame(&mut control_ws).await {
                TunnelMessage::Manifest { tools, .. } => {
                    assert!(!tools.is_empty(), "manifest must include tools");
                }
                other => panic!("expected Manifest, got {other:?}"),
            }

            // Ask the device to open a session and drive it as an MCP client.
            let session_id = "sess-e2e".to_owned();
            control_ws
                .send(Message::text(
                    thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::OpenSession {
                        session_id: session_id.clone(),
                        session_url: format!(
                            "ws://127.0.0.1:{session_port}/tunnel/session/{session_id}"
                        ),
                    }),
                ))
                .await
                .unwrap();

            let (stream, _) = session_listener.accept().await.unwrap();
            let session_ws =
                tokio_tungstenite::accept_async(tokio_tungstenite::MaybeTlsStream::Plain(stream))
                    .await
                    .unwrap();
            let (sink, stream) = split_json_rpc_ws::<rmcp::RoleClient>(session_ws);
            let transport = rmcp::transport::sink_stream::SinkStreamTransport::new(sink, stream);
            let client: rmcp::service::RunningService<rmcp::RoleClient, ()> = ()
                .serve(transport)
                .await
                .expect("initialize remote session");
            let tools = client.peer().list_tools(None).await.expect("list tools");
            assert!(tools.tools.iter().any(|tool| tool.name == "host_status"));
            let call = client
                .peer()
                .call_tool(rmcp::model::CallToolRequestParams::new("host_status"))
                .await
                .expect("call host_status through the tunnel");
            assert!(
                call.is_error != Some(true),
                "host_status must succeed: {call:?}"
            );
            client.cancel().await.ok();

            // Expect the session result once the socket drains.
            match next_control_frame(&mut control_ws).await {
                TunnelMessage::SessionResult { ok: true, .. } => {}
                other => panic!("expected successful SessionResult, got {other:?}"),
            }
        });

        // Device under test.
        let (token_dir, token_file) = token_path();
        let config = RelayConfig {
            relay_url: format!("ws://127.0.0.1:{control_port}/tunnel"),
            token_file: token_file.clone(),
            device_name: "Test Mac".to_owned(),
            control_socket: socket.clone(),
            allow_input: false,
            allow_config_write: false,
        };
        let (stop_tx, stop_rx) = watch::channel(false);
        let relay_task = tokio::spawn(run_relay(config, stop_rx));

        tokio::time::timeout(Duration::from_secs(60), gateway_task)
            .await
            .expect("gateway scenario timeout")
            .unwrap();

        // The device token persisted after linking.
        assert!(read_token_file(&token_file).unwrap().is_some());
        let _ = stop_tx.send(true);
        tokio::time::timeout(Duration::from_secs(10), relay_task)
            .await
            .ok();
        let _ = shutdown_tx.send(true);
        let _ = control_task.await;
        remove_control_socket(&socket);
        drop(token_dir);
        drop(host_dir);
    }
}
