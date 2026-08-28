//! Live device tunnel state: authenticated control WebSockets, anonymous
//! link WebSockets, and on-demand remote MCP session handoffs.
//!
//! The gateway side speaks axum WebSockets (see `http.rs` for the session
//! sink/stream adapters); the device side (`thumble-mcp --relay`) speaks
//! tokio-tungstenite. Both use the same wire protocol from
//! `thumble-tunnel`: control frames as Text messages, one JSON-RPC message
//! per Binary frame.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use axum::extract::ws::{Message as WsMessage, WebSocket};
use futures::SinkExt;
use rmcp::service::RunningService;
use rmcp::RoleClient;
use thumble_tunnel::protocol::{
    CONNECTOR_APPROVAL_TTL_SECONDS, LINK_CODE_TTL_SECONDS, MAXIMUM_DEVICE_SESSIONS,
};
use thumble_tunnel::TunnelMessage;
use tokio::sync::{mpsc, oneshot};

use crate::store::{DeviceRecord, ManifestRecord, Store};

pub const MAXIMUM_REMOTE_SESSIONS: usize = MAXIMUM_DEVICE_SESSIONS;
const SESSION_OPEN_TIMEOUT: Duration = Duration::from_secs(30);
const LINK_PERSIST_TIMEOUT: Duration = Duration::from_secs(30);
const MAXIMUM_PENDING_LINKS: usize = 16;
const LINK_WINDOW: Duration = Duration::from_secs(LINK_CODE_TTL_SECONDS + 5);

/// One authenticated device control channel.
struct DeviceConnection {
    sender: mpsc::Sender<TunnelMessage>,
    /// Opaque identity for this exact authenticated WebSocket instance.
    connection_key: String,
    /// Gateway-observed browser/tunnel source (normally the public IP).
    /// Automatic approval prompts never cross this boundary.
    source_key: String,
    manifest: Option<ManifestRecord>,
    session_count: usize,
}

/// An anonymous connection waiting for the user to confirm a link code.
struct PendingLink {
    sender: mpsc::Sender<TunnelMessage>,
    source_key: String,
    device_name: String,
    /// When the link socket authenticated with the device's current bearer
    /// token, confirming the code rotates that device's credential in place
    /// instead of minting a second device identity for the same Mac.
    rotate_device_id: Option<String>,
}

struct SessionWaiter {
    device_id: String,
    sender: oneshot::Sender<Result<RunningService<RoleClient, ()>, String>>,
}

struct LinkPersistenceWaiter {
    device_id: String,
    sender: oneshot::Sender<Result<(), String>>,
}

/// Which live connection a pushed connector-approval request was offered
/// to. Decisions are accepted only from a connection that received the
/// offer, and the first decision wins.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum ApprovalTarget {
    PendingLink(String),
    Device {
        device_id: String,
        connection_key: String,
    },
}

#[derive(Debug)]
struct ConnectorApproval {
    targets: Vec<ApprovalTarget>,
    expires_at: Instant,
    decision: Option<(ApprovalTarget, bool)>,
}

/// Owns a reserved device-session slot until the session service is handed
/// off successfully. Dropping the opening future (for example when a modern
/// stateless HTTP request disconnects) removes its waiter and releases the
/// slot instead of stranding capacity.
struct SessionOpeningGuard {
    registry: Arc<TunnelRegistry>,
    device_id: String,
    session_id: String,
    waiter_installed: bool,
    armed: bool,
}

impl SessionOpeningGuard {
    fn new(registry: Arc<TunnelRegistry>, device_id: &str, session_id: &str) -> Self {
        Self {
            registry,
            device_id: device_id.to_owned(),
            session_id: session_id.to_owned(),
            waiter_installed: false,
            armed: true,
        }
    }

    fn disarm(&mut self) {
        self.armed = false;
        self.waiter_installed = false;
    }
}

impl Drop for SessionOpeningGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        if self.waiter_installed {
            let mut waiters = self.registry.session_waiters.lock().unwrap();
            if waiters
                .get(&self.session_id)
                .is_some_and(|waiter| waiter.device_id == self.device_id)
            {
                waiters.remove(&self.session_id);
            }
        }
        self.registry.session_ended(&self.device_id);
    }
}

#[derive(Default)]
pub struct TunnelRegistry {
    devices: Mutex<HashMap<String, DeviceConnection>>,
    pending_links: Mutex<HashMap<String, PendingLink>>,
    link_persistence_waiters: Mutex<HashMap<String, LinkPersistenceWaiter>>,
    session_waiters: Mutex<HashMap<String, SessionWaiter>>,
    connector_approvals: Mutex<HashMap<String, ConnectorApproval>>,
}

impl TunnelRegistry {
    pub fn new() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Is the device control channel currently online?
    pub fn device_online(&self, device_id: &str) -> bool {
        self.devices
            .lock()
            .unwrap()
            .get(device_id)
            .map(|connection| !connection.sender.is_closed())
            .unwrap_or(false)
    }

    pub fn device_connection_key(&self, device_id: &str) -> Option<String> {
        self.devices
            .lock()
            .unwrap()
            .get(device_id)
            .filter(|connection| !connection.sender.is_closed())
            .map(|connection| connection.connection_key.clone())
    }

    pub async fn request_device_reconnect(
        &self,
        device_id: &str,
        connection_key: &str,
    ) -> Result<(), String> {
        let sender = self
            .devices
            .lock()
            .unwrap()
            .get(device_id)
            .filter(|connection| connection.connection_key == connection_key)
            .map(|connection| connection.sender.clone());
        let Some(sender) = sender else {
            return Ok(());
        };
        let _ = sender
            .send(TunnelMessage::ReconnectRequired {
                detail: Some(
                    "device token rotated; reconnect with the stored credential".to_owned(),
                ),
            })
            .await;
        // A send failure means the old socket already closed, which is the
        // desired post-rotation state.
        Ok(())
    }

    pub fn manifest(&self, device_id: &str) -> Option<ManifestRecord> {
        self.devices
            .lock()
            .unwrap()
            .get(device_id)
            .and_then(|connection| connection.manifest.clone())
    }

    pub fn device_count(&self) -> usize {
        self.devices.lock().unwrap().len()
    }

    pub fn register_device(
        &self,
        device_id: &str,
        source_key: &str,
        connection_key: &str,
        sender: mpsc::Sender<TunnelMessage>,
    ) -> Result<(), String> {
        let mut devices = self.devices.lock().unwrap();
        if let Some(existing) = devices.get(device_id) {
            if !existing.sender.is_closed() {
                return Err("device control channel is already connected".to_owned());
            }
        }
        devices.insert(
            device_id.to_owned(),
            DeviceConnection {
                sender,
                connection_key: connection_key.to_owned(),
                source_key: source_key.to_owned(),
                manifest: None,
                session_count: 0,
            },
        );
        Ok(())
    }

    pub fn update_manifest(&self, device_id: &str, manifest: ManifestRecord) {
        if let Some(connection) = self.devices.lock().unwrap().get_mut(device_id) {
            connection.manifest = Some(manifest);
        }
    }

    fn reserve_device_session(&self, device_id: &str) -> Result<(), String> {
        let mut devices = self.devices.lock().unwrap();
        let connection = devices.get_mut(device_id).ok_or_else(|| {
            "the device relay is offline (no control tunnel is connected). Start the relay with \
                 `thumble relay connect` on your Mac, or install the background service with \
                 `thumble relay install`; `thumble relay doctor` reports the full state"
                .to_owned()
        })?;
        if connection.sender.is_closed() {
            return Err("device control channel is closed".to_owned());
        }
        if connection.session_count >= MAXIMUM_REMOTE_SESSIONS {
            return Err("device is already serving its maximum remote sessions".to_owned());
        }
        connection.session_count += 1;
        Ok(())
    }

    pub fn session_count(&self, device_id: &str) -> usize {
        self.devices
            .lock()
            .unwrap()
            .get(device_id)
            .map(|connection| connection.session_count)
            .unwrap_or(0)
    }

    pub fn session_ended(&self, device_id: &str) {
        if let Some(connection) = self.devices.lock().unwrap().get_mut(device_id) {
            connection.session_count = connection.session_count.saturating_sub(1);
        }
    }

    pub fn unregister_device(&self, device_id: &str, connection_key: &str) {
        let mut devices = self.devices.lock().unwrap();
        if devices
            .get(device_id)
            .is_some_and(|connection| connection.connection_key == connection_key)
        {
            devices.remove(device_id);
        }
    }

    /// Ask a device to open a session WebSocket and wait for the resulting
    /// MCP client session to be handed back by the session WS handler.
    pub async fn open_device_session(
        self: &Arc<Self>,
        device_id: &str,
        session_id: &str,
        session_url: &str,
    ) -> Result<RunningService<RoleClient, ()>, String> {
        // Reserve atomically before sending OpenSession so concurrent MCP
        // sessions cannot all pass the cap check.
        self.reserve_device_session(device_id)?;
        let mut opening = SessionOpeningGuard::new(self.clone(), device_id, session_id);
        let (notify, wait) = oneshot::channel();
        {
            let mut waiters = self.session_waiters.lock().unwrap();
            if waiters.contains_key(session_id) {
                return Err("session ID is already waiting for a device".to_owned());
            }
            waiters.insert(
                session_id.to_owned(),
                SessionWaiter {
                    device_id: device_id.to_owned(),
                    sender: notify,
                },
            );
            opening.waiter_installed = true;
        }
        let request = TunnelMessage::OpenSession {
            session_id: session_id.to_owned(),
            session_url: session_url.to_owned(),
        };
        let send = {
            let devices = self.devices.lock().unwrap();
            devices
                .get(device_id)
                .ok_or_else(|| "device went offline".to_owned())?
                .sender
                .clone()
        };
        if send.send(request).await.is_err() {
            return Err("device control channel dropped the session request".to_owned());
        }
        match tokio::time::timeout(SESSION_OPEN_TIMEOUT, wait).await {
            Ok(Ok(Ok(service))) => {
                opening.disarm();
                Ok(service)
            }
            Ok(Ok(Err(error))) => Err(error),
            Ok(Err(_)) => Err("device session websocket never connected".to_owned()),
            Err(_) => Err("timed out waiting for the device session websocket".to_owned()),
        }
    }

    pub fn session_expected(&self, session_id: &str, device_id: &str) -> bool {
        self.session_waiters
            .lock()
            .unwrap()
            .get(session_id)
            .is_some_and(|waiter| waiter.device_id == device_id)
    }

    /// Called by the session WS handler once the device's MCP client session
    /// is running (or failed).
    pub fn complete_device_session(
        &self,
        session_id: &str,
        device_id: &str,
        result: Result<RunningService<RoleClient, ()>, String>,
    ) -> Result<(), String> {
        let mut waiters = self.session_waiters.lock().unwrap();
        let waiter = waiters
            .get(session_id)
            .ok_or_else(|| "no session is waiting for this websocket".to_owned())?;
        if waiter.device_id != device_id {
            return Err("session websocket was opened by the wrong device".to_owned());
        }
        let waiter = waiters.remove(session_id).expect("waiter checked above");
        waiter
            .sender
            .send(result)
            .map_err(|_| "session waiter disappeared".to_owned())
    }

    pub async fn notify_device_revoked(&self, device_id: &str) {
        let sender = {
            let devices = self.devices.lock().unwrap();
            devices
                .get(device_id)
                .map(|connection| connection.sender.clone())
        };
        if let Some(sender) = sender {
            let _ = sender
                .send(TunnelMessage::RevokeGranted {
                    detail: Some("device token revoked".to_owned()),
                })
                .await;
        }
    }

    pub async fn close_device_session(&self, device_id: &str, session_id: &str) {
        let sender = {
            let devices = self.devices.lock().unwrap();
            devices.get(device_id).map(|c| c.sender.clone())
        };
        if let Some(sender) = sender {
            let _ = sender
                .send(TunnelMessage::CloseSession {
                    session_id: session_id.to_owned(),
                })
                .await;
        }
    }

    pub fn register_pending_link(
        &self,
        pending_key: &str,
        source_key: &str,
        device_name: &str,
        sender: mpsc::Sender<TunnelMessage>,
        rotate_device_id: Option<String>,
    ) {
        self.pending_links.lock().unwrap().insert(
            pending_key.to_owned(),
            PendingLink {
                sender,
                source_key: source_key.to_owned(),
                device_name: device_name.to_owned(),
                rotate_device_id,
            },
        );
    }

    pub fn pending_link_name(&self, pending_key: &str) -> Option<String> {
        self.pending_links
            .lock()
            .unwrap()
            .get(pending_key)
            .map(|link| link.device_name.clone())
    }

    /// The device whose token should be rotated in place when this pending
    /// link is confirmed, if the link socket authenticated with one.
    pub fn pending_link_rotation(&self, pending_key: &str) -> Option<String> {
        self.pending_links
            .lock()
            .unwrap()
            .get(pending_key)
            .and_then(|link| link.rotate_device_id.clone())
    }

    /// Send LinkGranted and wait until the relay confirms the token was
    /// atomically persisted. OAuth must not complete on queueing alone.
    pub async fn grant_pending_link(
        &self,
        pending_key: &str,
        device_id: &str,
        device_token: &str,
    ) -> Result<(), String> {
        let sender = self
            .pending_links
            .lock()
            .unwrap()
            .get(pending_key)
            .map(|link| link.sender.clone())
            .ok_or_else(|| "the device link window expired; restart the relay".to_owned())?;
        let (notify, wait) = oneshot::channel();
        {
            let mut waiters = self.link_persistence_waiters.lock().unwrap();
            if waiters.contains_key(pending_key) {
                return Err("the device link already has a persistence handoff".to_owned());
            }
            waiters.insert(
                pending_key.to_owned(),
                LinkPersistenceWaiter {
                    device_id: device_id.to_owned(),
                    sender: notify,
                },
            );
        }
        if sender
            .send(TunnelMessage::LinkGranted {
                device_id: device_id.to_owned(),
                device_token: device_token.to_owned(),
            })
            .await
            .is_err()
        {
            self.link_persistence_waiters
                .lock()
                .unwrap()
                .remove(pending_key);
            self.pending_links.lock().unwrap().remove(pending_key);
            return Err("the device disconnected before linking".to_owned());
        }

        let outcome = match tokio::time::timeout(LINK_PERSIST_TIMEOUT, wait).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err("the token-persistence waiter disappeared".to_owned()),
            Err(_) => Err("timed out waiting for the relay to persist its token".to_owned()),
        };
        self.link_persistence_waiters
            .lock()
            .unwrap()
            .remove(pending_key);
        self.pending_links.lock().unwrap().remove(pending_key);
        if let Err(error) = &outcome {
            let _ = sender
                .send(TunnelMessage::LinkDenied {
                    reason: error.clone(),
                })
                .await;
        }
        outcome
    }

    pub fn confirm_link_persisted(&self, pending_key: &str, device_id: &str) -> Result<(), String> {
        let waiter = {
            let mut waiters = self.link_persistence_waiters.lock().unwrap();
            let waiter = waiters
                .get(pending_key)
                .ok_or_else(|| "no token persistence handoff is pending".to_owned())?;
            if waiter.device_id != device_id {
                return Err("token persistence came from the wrong device".to_owned());
            }
            waiters
                .remove(pending_key)
                .expect("persistence waiter checked above")
        };
        waiter
            .sender
            .send(Ok(()))
            .map_err(|_| "token-persistence receiver disappeared".to_owned())
    }

    pub fn fail_link_persistence(&self, pending_key: &str, reason: &str) {
        if let Some(waiter) = self
            .link_persistence_waiters
            .lock()
            .unwrap()
            .remove(pending_key)
        {
            let _ = waiter.sender.send(Err(reason.to_owned()));
        }
    }

    fn prune_expired_approvals(approvals: &mut HashMap<String, ConnectorApproval>) {
        let now = Instant::now();
        approvals.retain(|_, approval| approval.expires_at > now);
    }

    /// Push a connector-approval request only to connections sharing the
    /// authorization browser's gateway-observed source. Matching open link
    /// windows take priority (their user just deliberately started linking);
    /// otherwise matching online devices are eligible. A target with another
    /// live prompt is skipped, and the first offered connection to answer
    /// wins. Zero means the connector must use the fallback-code path.
    pub fn offer_connector_approval(
        &self,
        request_id: &str,
        client_name: &str,
        scope: &str,
        source_key: &str,
        ttl_seconds: u64,
    ) -> usize {
        let ttl_seconds = ttl_seconds.clamp(1, CONNECTOR_APPROVAL_TTL_SECONDS);
        let frame = TunnelMessage::ConnectorApprovalRequest {
            request_id: request_id.to_owned(),
            client_name: client_name.to_owned(),
            scope: scope.to_owned(),
            expires_in: ttl_seconds,
        };
        let mut candidates: Vec<(ApprovalTarget, mpsc::Sender<TunnelMessage>)> = Vec::new();
        {
            let pending_links = self.pending_links.lock().unwrap();
            for (pending_key, link) in pending_links.iter() {
                if link.source_key == source_key {
                    candidates.push((
                        ApprovalTarget::PendingLink(pending_key.clone()),
                        link.sender.clone(),
                    ));
                }
            }
        }
        if candidates.is_empty() {
            let devices = self.devices.lock().unwrap();
            for (device_id, connection) in devices.iter() {
                if connection.source_key == source_key {
                    candidates.push((
                        ApprovalTarget::Device {
                            device_id: device_id.clone(),
                            connection_key: connection.connection_key.clone(),
                        },
                        connection.sender.clone(),
                    ));
                }
            }
        }
        if candidates.is_empty() {
            return 0;
        }

        // Install the offer before sending any frame. A fast relay may answer
        // immediately; holding this lock until the successfully notified
        // target list is final makes that decision wait instead of racing an
        // "unknown request" lookup.
        let mut approvals = self.connector_approvals.lock().unwrap();
        Self::prune_expired_approvals(&mut approvals);
        let busy_targets = approvals
            .values()
            .filter(|approval| approval.decision.is_none())
            .flat_map(|approval| approval.targets.iter().cloned())
            .collect::<std::collections::HashSet<_>>();
        candidates.retain(|(target, _)| !busy_targets.contains(target));
        if candidates.is_empty() {
            return 0;
        }
        approvals.insert(
            request_id.to_owned(),
            ConnectorApproval {
                targets: Vec::new(),
                expires_at: Instant::now() + Duration::from_secs(ttl_seconds),
                decision: None,
            },
        );
        let mut notified_targets = Vec::new();
        for (target, sender) in candidates {
            if sender.try_send(frame.clone()).is_ok() {
                notified_targets.push(target);
            }
        }
        if notified_targets.is_empty() {
            approvals.remove(request_id);
            return 0;
        }
        let notified = notified_targets.len();
        approvals
            .get_mut(request_id)
            .expect("approval inserted above")
            .targets = notified_targets;
        notified
    }

    /// Record a device-side decision for a pushed approval. The decision is
    /// accepted only when the exact connection it came from was offered the
    /// request and nobody answered first.
    pub fn decide_connector_approval(
        &self,
        request_id: &str,
        approved: bool,
        source: &ApprovalTarget,
    ) -> Result<Option<ApprovalTarget>, String> {
        let mut approvals = self.connector_approvals.lock().unwrap();
        Self::prune_expired_approvals(&mut approvals);
        let approval = approvals
            .get_mut(request_id)
            .ok_or_else(|| "the approval request is unknown or expired".to_owned())?;
        if let Some((decided_by, _)) = &approval.decision {
            return Err(format!(
                "this approval request was already answered by {}",
                match decided_by {
                    ApprovalTarget::PendingLink(_) => "another link window".to_owned(),
                    ApprovalTarget::Device { .. } => "another device".to_owned(),
                }
            ));
        }
        if !approval.targets.iter().any(|target| target == source) {
            return Err("this approval request was not offered to this connection".to_owned());
        }
        approval.decision = Some((source.clone(), approved));
        Ok(if approved { Some(source.clone()) } else { None })
    }

    /// The recorded decision for a request, if any connection answered yet.
    pub fn approval_decision(&self, request_id: &str) -> Option<(ApprovalTarget, bool)> {
        let mut approvals = self.connector_approvals.lock().unwrap();
        Self::prune_expired_approvals(&mut approvals);
        approvals
            .get(request_id)
            .and_then(|approval| approval.decision.clone())
    }

    /// Seconds left before the pushed approval stops being answerable.
    pub fn approval_remaining_seconds(&self, request_id: &str) -> Option<u64> {
        let mut approvals = self.connector_approvals.lock().unwrap();
        Self::prune_expired_approvals(&mut approvals);
        approvals.get(request_id).map(|approval| {
            approval
                .expires_at
                .saturating_duration_since(Instant::now())
                .as_secs()
        })
    }

    pub fn approval_target_count(&self, request_id: &str) -> Option<usize> {
        let mut approvals = self.connector_approvals.lock().unwrap();
        Self::prune_expired_approvals(&mut approvals);
        approvals
            .get(request_id)
            .map(|approval| approval.targets.len())
    }

    /// Tell the connection that answered (or every offered connection when
    /// nobody did, on timeout) how the approval ended, then forget it.
    pub async fn complete_connector_approval(&self, request_id: &str, granted: bool, detail: &str) {
        let approval = {
            let mut approvals = self.connector_approvals.lock().unwrap();
            Self::prune_expired_approvals(&mut approvals);
            approvals.remove(request_id)
        };
        let Some(approval) = approval else {
            return;
        };
        // Close every prompt that received the offer, not only the first
        // connection that decided. Otherwise other Macs on the same source
        // can keep displaying a stale Allow dialog until timeout.
        let mut recipients = Vec::new();
        for target in &approval.targets {
            match target {
                ApprovalTarget::PendingLink(key) => {
                    if let Some(link) = self.pending_links.lock().unwrap().get(key) {
                        recipients.push(link.sender.clone());
                    }
                }
                ApprovalTarget::Device {
                    device_id,
                    connection_key,
                } => {
                    if let Some(connection) = self
                        .devices
                        .lock()
                        .unwrap()
                        .get(device_id)
                        .filter(|connection| connection.connection_key == *connection_key)
                    {
                        recipients.push(connection.sender.clone());
                    }
                }
            }
        }
        let frame = TunnelMessage::ConnectorApprovalResult {
            request_id: request_id.to_owned(),
            granted,
            detail: Some(detail.to_owned()),
        };
        for recipient in recipients {
            let _ = recipient.send(frame.clone()).await;
        }
    }
}

fn decode_control_frame(message: &WsMessage) -> Option<TunnelMessage> {
    let bytes: &[u8] = match message {
        WsMessage::Text(text) => text.as_bytes(),
        WsMessage::Binary(bytes) => bytes,
        _ => return None,
    };
    if bytes.len() > thumble_tunnel::MAXIMUM_FRAME_BYTES {
        eprintln!("gateway: rejected oversized tunnel control frame");
        return None;
    }
    thumble_tunnel::ws_rpc::decode_control_message(bytes)
}

async fn read_control_frame(websocket: &mut WebSocket) -> Option<TunnelMessage> {
    loop {
        match tokio::time::timeout(Duration::from_secs(90), websocket.recv()).await {
            Ok(Some(Ok(message))) => {
                if let Some(frame) = decode_control_frame(&message) {
                    return Some(frame);
                }
                if matches!(message, WsMessage::Close(_)) {
                    return None;
                }
            }
            Ok(Some(Err(_))) | Ok(None) | Err(_) => return None,
        }
    }
}

/// Serve one authenticated device control WebSocket to completion.
pub async fn serve_control_frames(
    registry: Arc<TunnelRegistry>,
    store: Arc<Store>,
    device: DeviceRecord,
    source_key: String,
    mut websocket: WebSocket,
) {
    let (outbound_tx, mut outbound_rx) = mpsc::channel::<TunnelMessage>(64);
    let connection_key = thumble_tunnel::random_token(12);
    if registry
        .register_device(
            &device.id,
            &source_key,
            &connection_key,
            outbound_tx.clone(),
        )
        .is_err()
    {
        let _ = websocket.close().await;
        return;
    }
    store.touch_device(&device.id).ok();
    eprintln!(
        "gateway: device {} ({}) control channel online",
        device.id, device.name
    );

    let result = loop {
        tokio::select! {
            inbound = websocket.recv() => {
                let message = match inbound {
                    Some(Ok(message)) => message,
                    _ => break Ok(()),
                };
                let frame = decode_control_frame(&message);
                match frame {
                    Some(TunnelMessage::Manifest { tools, resources, server_instructions }) => {
                        let manifest = ManifestRecord { tools, resources, instructions: server_instructions };
                        if store.store_manifest(&device.id, &manifest).is_ok() {
                            registry.update_manifest(&device.id, manifest);
                        }
                    }
                    Some(TunnelMessage::Ping) => {
                        if websocket
                            .send(WsMessage::text(
                                thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::Pong),
                            ))
                            .await
                            .is_err()
                        {
                            break Ok(());
                        }
                    }
                    Some(TunnelMessage::RevokeRequest) => {
                        let _ = store.revoke_device(&device.id);
                        let _ = websocket
                            .send(WsMessage::text(thumble_tunnel::ws_rpc::encode_control_message(
                                &TunnelMessage::RevokeGranted {
                                    detail: Some("device unlinked from the gateway".to_owned()),
                                },
                            )))
                            .await;
                        eprintln!("gateway: device {} revoked itself", device.id);
                        break Ok(());
                    }
                    Some(TunnelMessage::ConnectorApprovalDecision { request_id, approved }) => {
                        if let Err(error) = registry.decide_connector_approval(
                            &request_id,
                            approved,
                            &ApprovalTarget::Device {
                                device_id: device.id.clone(),
                                connection_key: connection_key.clone(),
                            },
                        ) {
                            eprintln!("gateway: device approval decision rejected: {error}");
                        }
                    }
                    Some(_) | None => {}
                }
            }
            outbound = outbound_rx.recv() => {
                match outbound {
                    Some(frame) => {
                        let terminal = matches!(
                            frame,
                            TunnelMessage::RevokeGranted { .. }
                                | TunnelMessage::ReconnectRequired { .. }
                        );
                        if websocket
                            .send(WsMessage::text(thumble_tunnel::ws_rpc::encode_control_message(&frame)))
                            .await
                            .is_err()
                        {
                            break Err("control send failed");
                        }
                        if terminal {
                            break Ok(());
                        }
                    }
                    None => break Ok(()),
                }
            }
        }
    };
    registry.unregister_device(&device.id, &connection_key);
    eprintln!(
        "gateway: device {} control channel offline ({:?})",
        device.id, result
    );
}

/// Revoke a device through a separate authenticated control socket. This
/// remains available while the ordinary relay control channel is live.
pub async fn serve_revoke_frames(
    registry: Arc<TunnelRegistry>,
    store: Arc<Store>,
    device: DeviceRecord,
    mut websocket: WebSocket,
) {
    let request = tokio::time::timeout(Duration::from_secs(15), read_control_frame(&mut websocket))
        .await
        .ok()
        .flatten();
    if !matches!(request, Some(TunnelMessage::RevokeRequest)) {
        let _ = websocket.close().await;
        return;
    }
    if let Err(error) = store.revoke_device(&device.id) {
        eprintln!("gateway: revoke failed for {}: {error}", device.id);
        let _ = websocket.close().await;
        return;
    }
    registry.notify_device_revoked(&device.id).await;
    let _ = websocket
        .send(WsMessage::text(
            thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::RevokeGranted {
                detail: Some("device unlinked from the gateway".to_owned()),
            }),
        ))
        .await;
    let _ = websocket.close().await;
}

/// Serve one link WebSocket: hand out a link code, wait for the user to
/// confirm it on the authorize page, then deliver the device token.
///
/// `rotating_device` is set when the socket authenticated with a valid device
/// bearer token: confirming that link replaces the credential of the same
/// device instead of creating a second identity for one Mac.
pub async fn serve_link_frames(
    registry: Arc<TunnelRegistry>,
    store: Arc<Store>,
    base_url: String,
    source_key: String,
    rotating_device: Option<DeviceRecord>,
    mut websocket: WebSocket,
) {
    let device_name = match read_control_frame(&mut websocket).await {
        Some(TunnelMessage::LinkRequest { device_name }) => device_name,
        _ => return,
    };

    let (outbound_tx, mut outbound_rx) = mpsc::channel::<TunnelMessage>(8);
    let pending_key = thumble_tunnel::random_token(12);
    registry.register_pending_link(
        &pending_key,
        &source_key,
        &device_name,
        outbound_tx.clone(),
        rotating_device.map(|device| device.id),
    );
    let code = match store.create_link_code(
        &pending_key,
        &device_name,
        LINK_CODE_TTL_SECONDS as i64,
        MAXIMUM_PENDING_LINKS,
    ) {
        Ok(code) => code,
        Err(error) => {
            let _ = websocket
                .send(WsMessage::text(
                    thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::LinkDenied {
                        reason: error,
                    }),
                ))
                .await;
            return;
        }
    };
    let offer = TunnelMessage::LinkOffer {
        url: format!("{}/link?code={code}", base_url.trim_end_matches('/')),
        code: code.clone(),
        expires_in: LINK_CODE_TTL_SECONDS,
    };
    if websocket
        .send(WsMessage::text(
            thumble_tunnel::ws_rpc::encode_control_message(&offer),
        ))
        .await
        .is_err()
    {
        registry.pending_links.lock().unwrap().remove(&pending_key);
        return;
    }
    eprintln!("gateway: issued link code for device {device_name:?} (pending {pending_key})");

    let mut granted: Option<bool> = None;
    let deadline = tokio::time::sleep(LINK_WINDOW);
    tokio::pin!(deadline);
    while granted.is_none() {
        tokio::select! {
            inbound = read_control_frame(&mut websocket) => {
                match inbound {
                    Some(TunnelMessage::Ping) => {
                        if websocket
                            .send(WsMessage::text(thumble_tunnel::ws_rpc::encode_control_message(&TunnelMessage::Pong)))
                            .await
                            .is_err()
                        {
                            granted = Some(false);
                        }
                    }
                    Some(TunnelMessage::ConnectorApprovalDecision { request_id, approved }) => {
                        if let Err(error) = registry.decide_connector_approval(
                            &request_id,
                            approved,
                            &ApprovalTarget::PendingLink(pending_key.clone()),
                        ) {
                            eprintln!("gateway: link approval decision rejected: {error}");
                        }
                    }
                    Some(TunnelMessage::LinkPersisted { device_id }) => {
                        match registry.confirm_link_persisted(&pending_key, &device_id) {
                            Ok(()) => granted = Some(true),
                            Err(error) => {
                                eprintln!("gateway: token persistence rejected: {error}");
                                granted = Some(false);
                            }
                        }
                    }
                    Some(TunnelMessage::LinkPersistFailed { .. }) => {
                        registry.fail_link_persistence(
                            &pending_key,
                            "the relay could not persist its device token",
                        );
                        granted = Some(false);
                    }
                    Some(_) => continue,
                    None => {
                        registry.fail_link_persistence(
                            &pending_key,
                            "the device disconnected before confirming token persistence",
                        );
                        granted = Some(false);
                    },
                }
            }
            outbound = outbound_rx.recv() => {
                match outbound {
                    Some(frame) => {
                        let terminal = matches!(frame, TunnelMessage::LinkDenied { .. });
                        if websocket
                            .send(WsMessage::text(thumble_tunnel::ws_rpc::encode_control_message(&frame)))
                            .await
                            .is_err()
                        {
                            granted = Some(false);
                            continue;
                        }
                        if terminal {
                            registry.fail_link_persistence(
                                &pending_key,
                                "the gateway denied the token handoff",
                            );
                            granted = Some(false);
                        }
                    }
                    None => granted = Some(false),
                }
            }
            _ = &mut deadline => {
                registry.fail_link_persistence(&pending_key, "the device link window expired");
                granted = Some(false);
            }
        }
    }
    if granted == Some(true) {
        let _ = websocket.close().await;
    } else {
        registry.fail_link_persistence(&pending_key, "the device link window closed");
        registry.pending_links.lock().unwrap().remove(&pending_key);
        eprintln!("gateway: link window closed for pending {pending_key}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device_target(device_id: &str) -> ApprovalTarget {
        ApprovalTarget::Device {
            device_id: device_id.to_owned(),
            connection_key: "conn-1".to_owned(),
        }
    }

    #[test]
    fn registry_tracks_online_devices() {
        let registry = TunnelRegistry::new();
        let (sender, _receiver) = mpsc::channel(4);
        registry
            .register_device("dev_1", "source-a", "conn-1", sender)
            .unwrap();
        assert!(registry.device_online("dev_1"));
        assert!(!registry.device_online("dev_2"));
        assert_eq!(registry.device_count(), 1);
        registry.unregister_device("dev_1", "conn-1");
        assert!(!registry.device_online("dev_1"));
    }

    #[test]
    fn duplicate_live_registration_is_rejected() {
        let registry = TunnelRegistry::new();
        let (sender, _receiver) = mpsc::channel(4);
        registry
            .register_device("dev_1", "source-a", "conn-1", sender.clone())
            .unwrap();
        assert!(registry
            .register_device("dev_1", "source-a", "conn-2", sender)
            .is_err());
    }

    #[test]
    fn stale_disconnect_cannot_unregister_a_replacement_connection() {
        let registry = TunnelRegistry::new();
        let (old_sender, old_receiver) = mpsc::channel(4);
        registry
            .register_device("dev_1", "source-a", "conn-old", old_sender)
            .unwrap();
        drop(old_receiver);
        let (new_sender, _new_receiver) = mpsc::channel(4);
        registry
            .register_device("dev_1", "source-a", "conn-new", new_sender)
            .unwrap();

        registry.unregister_device("dev_1", "conn-old");
        assert!(registry.device_online("dev_1"));
        registry.unregister_device("dev_1", "conn-new");
        assert!(!registry.device_online("dev_1"));
    }

    #[test]
    fn session_handoffs_are_bound_to_the_expected_device() {
        let registry = TunnelRegistry::new();
        let (sender, _receiver) = oneshot::channel();
        registry.session_waiters.lock().unwrap().insert(
            "session-1".to_owned(),
            SessionWaiter {
                device_id: "dev_1".to_owned(),
                sender,
            },
        );
        assert!(registry.session_expected("session-1", "dev_1"));
        assert!(!registry.session_expected("session-1", "dev_2"));
        assert!(registry
            .complete_device_session("session-1", "dev_2", Err("denied".to_owned()))
            .is_err());
        assert!(registry.session_expected("session-1", "dev_1"));
        registry
            .complete_device_session("session-1", "dev_1", Err("test".to_owned()))
            .unwrap();
    }

    #[tokio::test]
    async fn cancelled_session_open_releases_waiter_and_capacity() {
        let registry = TunnelRegistry::new();
        let (sender, mut receiver) = mpsc::channel(4);
        registry
            .register_device("dev_1", "source-a", "conn-1", sender)
            .unwrap();

        let opening_registry = registry.clone();
        let opening = tokio::spawn(async move {
            opening_registry
                .open_device_session("dev_1", "cancelled-session", "ws://127.0.0.1/session")
                .await
        });
        let message = receiver.recv().await.expect("OpenSession request");
        assert!(matches!(
            message,
            TunnelMessage::OpenSession { ref session_id, .. }
                if session_id == "cancelled-session"
        ));
        assert_eq!(registry.session_count("dev_1"), 1);
        assert!(registry.session_expected("cancelled-session", "dev_1"));

        opening.abort();
        let _ = opening.await;
        tokio::task::yield_now().await;
        assert_eq!(registry.session_count("dev_1"), 0);
        assert!(!registry.session_expected("cancelled-session", "dev_1"));
    }

    #[test]
    fn session_reservations_are_atomic_and_bounded() {
        let registry = TunnelRegistry::new();
        let (sender, _receiver) = mpsc::channel(4);
        registry
            .register_device("dev_1", "source-a", "conn-1", sender)
            .unwrap();
        for _ in 0..MAXIMUM_REMOTE_SESSIONS {
            registry.reserve_device_session("dev_1").unwrap();
        }
        assert_eq!(registry.session_count("dev_1"), MAXIMUM_REMOTE_SESSIONS);
        assert!(registry.reserve_device_session("dev_1").is_err());
        for _ in 0..=MAXIMUM_REMOTE_SESSIONS {
            registry.session_ended("dev_1");
        }
        assert_eq!(registry.session_count("dev_1"), 0);
    }

    #[test]
    fn connector_approvals_prefer_pending_links_and_bind_decisions() {
        let registry = TunnelRegistry::new();
        let (device_sender, _device_receiver) = mpsc::channel(4);
        registry
            .register_device("dev_1", "source-a", "conn-1", device_sender)
            .unwrap();
        let (link_sender, mut link_receiver) = mpsc::channel(4);
        registry.register_pending_link("pending-1", "source-a", "Mac", link_sender, None);

        // The open link window wins over the online device.
        let notified =
            registry.offer_connector_approval("req-1", "ChatGPT", "thumble.read", "source-a", 60);
        assert_eq!(notified, 1);
        assert_eq!(
            registry.offer_connector_approval(
                "req-busy",
                "ChatGPT",
                "thumble.read",
                "source-a",
                60,
            ),
            0,
            "one connection must never receive overlapping prompts"
        );
        match link_receiver.try_recv().unwrap() {
            TunnelMessage::ConnectorApprovalRequest { request_id, .. } => {
                assert_eq!(request_id, "req-1");
            }
            other => panic!("expected ConnectorApprovalRequest, got {other:?}"),
        }

        // A connection that was not offered the request cannot answer it.
        assert!(registry
            .decide_connector_approval("req-1", true, &device_target("dev_1"))
            .is_err());
        assert!(registry.approval_decision("req-1").is_none());

        // The offered link window can; the first decision wins.
        assert_eq!(
            registry
                .decide_connector_approval(
                    "req-1",
                    true,
                    &ApprovalTarget::PendingLink("pending-1".to_owned())
                )
                .unwrap(),
            Some(ApprovalTarget::PendingLink("pending-1".to_owned()))
        );
        assert!(registry
            .decide_connector_approval(
                "req-1",
                false,
                &ApprovalTarget::PendingLink("pending-1".to_owned())
            )
            .is_err());
        assert_eq!(
            registry.approval_decision("req-1"),
            Some((ApprovalTarget::PendingLink("pending-1".to_owned()), true))
        );
        assert!(registry.approval_remaining_seconds("req-1").is_some());
        assert!(registry.approval_remaining_seconds("unknown").is_none());
    }

    #[test]
    fn connector_approvals_are_source_bound_and_fall_back_to_online_devices() {
        let registry = TunnelRegistry::new();
        assert_eq!(
            registry.offer_connector_approval("req-1", "ChatGPT", "thumble.read", "source-a", 60,),
            0,
            "nobody online must not create an offer"
        );
        assert!(registry.approval_decision("req-1").is_none());

        let (sender, mut receiver) = mpsc::channel(4);
        registry
            .register_device("dev_1", "source-a", "conn-1", sender)
            .unwrap();
        assert_eq!(
            registry.offer_connector_approval(
                "req-cross-source",
                "ChatGPT",
                "thumble.read",
                "source-b",
                60,
            ),
            0,
            "a browser source must never prompt another source's device"
        );
        assert!(receiver.try_recv().is_err());
        assert_eq!(
            registry.offer_connector_approval("req-2", "ChatGPT", "thumble.read", "source-a", 60,),
            1
        );
        assert!(matches!(
            receiver.try_recv().unwrap(),
            TunnelMessage::ConnectorApprovalRequest { .. }
        ));
        assert!(registry
            .decide_connector_approval(
                "req-2",
                true,
                &ApprovalTarget::Device {
                    device_id: "dev_1".to_owned(),
                    connection_key: "conn-other".to_owned(),
                },
            )
            .is_err());
        assert!(registry.approval_decision("req-2").is_none());
        // A denial from the exact offered connection resolves to no target
        // but is still recorded.
        assert!(registry
            .decide_connector_approval("req-2", false, &device_target("dev_1"))
            .unwrap()
            .is_none());
        assert_eq!(
            registry.approval_decision("req-2"),
            Some((device_target("dev_1"), false))
        );
    }

    #[test]
    fn expired_connector_approvals_are_pruned() {
        let registry = TunnelRegistry::new();
        let (sender, _receiver) = mpsc::channel(4);
        registry.register_pending_link("pending-1", "source-a", "Mac", sender, None);
        registry.offer_connector_approval("req-1", "ChatGPT", "thumble.read", "source-a", 60);
        // Force the offer past its deadline.
        registry
            .connector_approvals
            .lock()
            .unwrap()
            .get_mut("req-1")
            .unwrap()
            .expires_at = Instant::now() - Duration::from_secs(1);
        assert!(registry.approval_remaining_seconds("req-1").is_none());
        assert!(registry
            .decide_connector_approval(
                "req-1",
                true,
                &ApprovalTarget::PendingLink("pending-1".to_owned())
            )
            .is_err());
    }

    #[tokio::test]
    async fn pending_link_grant_requires_token_persistence_confirmation() {
        let registry = TunnelRegistry::new();
        let (sender, mut receiver) = mpsc::channel(4);
        registry.register_pending_link("pending-1", "source-a", "Mac", sender, None);

        let granting_registry = registry.clone();
        let grant = tokio::spawn(async move {
            granting_registry
                .grant_pending_link("pending-1", "dev-1", "device-token")
                .await
        });
        assert!(matches!(
            receiver.recv().await.unwrap(),
            TunnelMessage::LinkGranted { ref device_id, .. } if device_id == "dev-1"
        ));
        registry.fail_link_persistence("pending-1", "disk write failed");
        assert!(grant.await.unwrap().is_err());
        assert!(matches!(
            receiver.recv().await.unwrap(),
            TunnelMessage::LinkDenied { .. }
        ));
    }

    #[tokio::test]
    async fn connector_approval_results_close_every_offered_prompt() {
        let registry = TunnelRegistry::new();
        let (sender, mut receiver) = mpsc::channel(4);
        let (other_sender, mut other_receiver) = mpsc::channel(4);
        registry.register_pending_link("pending-1", "source-a", "Mac", sender, None);
        registry.register_pending_link("pending-2", "source-a", "Other Mac", other_sender, None);
        assert_eq!(
            registry.offer_connector_approval("req-1", "ChatGPT", "thumble.read", "source-a", 60,),
            2
        );
        // Drain both pushed request frames before the result arrives.
        assert!(matches!(
            receiver.recv().await.unwrap(),
            TunnelMessage::ConnectorApprovalRequest { .. }
        ));
        assert!(matches!(
            other_receiver.recv().await.unwrap(),
            TunnelMessage::ConnectorApprovalRequest { .. }
        ));
        registry
            .decide_connector_approval(
                "req-1",
                true,
                &ApprovalTarget::PendingLink("pending-1".to_owned()),
            )
            .unwrap();
        registry
            .complete_connector_approval("req-1", true, "ChatGPT connected")
            .await;
        for frame in [
            receiver.recv().await.unwrap(),
            other_receiver.recv().await.unwrap(),
        ] {
            match frame {
                TunnelMessage::ConnectorApprovalResult {
                    request_id,
                    granted,
                    detail,
                } => {
                    assert_eq!(request_id, "req-1");
                    assert!(granted);
                    assert_eq!(detail.as_deref(), Some("ChatGPT connected"));
                }
                other => panic!("expected ConnectorApprovalResult, got {other:?}"),
            }
        }
        // The offer is consumed exactly once.
        assert!(registry.approval_decision("req-1").is_none());
    }
}
