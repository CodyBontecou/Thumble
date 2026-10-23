//! Separate management-only saved-control reads. No input/trust/policy mutex crosses IO.
use super::{hex, send, AuthorizedConnection};
use crate::{
    control_tls::{ControlChannel, FrameKind},
    native_ingress::Client,
    runtime,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc, Arc, Mutex,
    },
    time::Duration,
};
#[path = "phone_presentation_codec.rs"]
mod codec;
use codec::{Request, Scalars, FRAME_BYTES};
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Protocol {
    BaseV1,
    BanksV2,
}
impl Protocol {
    fn wire_version(self) -> u8 {
        match self {
            Self::BaseV1 => 1,
            Self::BanksV2 => 2,
        }
    }
}
const WAIT: Duration = Duration::from_secs(2);
struct Pending {
    id: String,
    request: Request,
    send: mpsc::SyncSender<Value>,
}
pub(crate) struct Bridge {
    authority: String,
    root: PathBuf,
    // Held before any native IPC opens, including both source checks. Input
    // never acquires this gate; parent delivery uses the separate pending lock.
    operation: Arc<Mutex<()>>,
    // A reusable idle management peer must not consume every TLS worker.
    // This gate is never acquired by input/control grants.
    connection: Mutex<()>,
    output: Mutex<Option<mpsc::SyncSender<String>>>,
    pending: Mutex<Option<Pending>>,
    next: AtomicU64,
}
impl Bridge {
    pub(crate) fn new(authority: &str, root: &Path, operation: Arc<Mutex<()>>) -> Self {
        Self {
            authority: authority.into(),
            root: root.into(),
            operation,
            connection: Mutex::new(()),
            output: Mutex::new(None),
            pending: Mutex::new(None),
            next: AtomicU64::new(1),
        }
    }
    pub(crate) fn attach(&self, output: mpsc::SyncSender<String>) -> Result<(), &'static str> {
        let mut slot = self.output.lock().map_err(|_| "presentation_unavailable")?;
        if slot.is_some() {
            return Err("presentation_unavailable");
        }
        *slot = Some(output);
        Ok(())
    }
    pub(crate) fn enabled(&self) -> bool {
        self.output
            .lock()
            .map(|slot| slot.is_some())
            .unwrap_or(false)
    }
    fn pin(&self, request: &Request) -> Result<(), &'static str> {
        let mut client = Client::connect(&self.root).map_err(|_| "presentation_unavailable")?;
        let (configuration, pin) = client
            .output_configuration()
            .map_err(|_| "presentation_unavailable")?;
        // This ephemeral read-only connection closes before parent/TLS waits.
        let pin = pin
            .filter(|pin| {
                configuration.active
                    && pin.configuration_revision == request.text("expectedConfigurationRevision")
                    && pin.source_hash == request.text("expectedSourceHash")
                    && pin.profile_id == request.text("profileId")
                    && pin.generation == request.text("generation")
                    && pin.revision == request.text("revision")
            })
            .ok_or("presentation_reactivation_required")?;
        if configuration.generation.to_string() != pin.generation
            || configuration.revision.to_string() != pin.revision
        {
            return Err("presentation_reactivation_required");
        }
        Ok(())
    }
    fn request(&self, request: &Request) -> Value {
        let result = (|| {
            let output = self
                .output
                .lock()
                .map_err(|_| "presentation_unavailable")?
                .clone()
                .ok_or("presentation_unavailable")?;
            let id = self
                .next
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
                .map_err(|_| "presentation_unavailable")?
                .to_string();
            let (send, received) = mpsc::sync_channel(1);
            {
                let mut pending = self
                    .pending
                    .lock()
                    .map_err(|_| "presentation_unavailable")?;
                if pending.is_some() {
                    return Err("presentation_busy");
                }
                *pending = Some(Pending {
                    id: id.clone(),
                    request: request.clone(),
                    send,
                });
            }
            let event = request.event(&self.authority, &id).to_string();
            let reply = if output.try_send(event).is_err() {
                Err("presentation_unavailable")
            } else {
                received
                    .recv_timeout(WAIT)
                    .map_err(|_| "presentation_timeout")
            };
            if let Ok(mut pending) = self.pending.lock() {
                if pending.as_ref().is_some_and(|p| p.id == id) {
                    pending.take();
                }
            }
            reply
        })();
        result.unwrap_or_else(|error| json!({"kind":"error","error":error}))
    }
    pub(crate) fn deliver(&self, bytes: &[u8]) -> Result<(), &'static str> {
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Success {
            version: u8,
            event: String,
            event_id: String,
            authority_instance_id: String,
            result: Scalars,
        }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Failure {
            version: u8,
            event: String,
            event_id: String,
            authority_instance_id: String,
            error: String,
        }
        #[derive(Deserialize)]
        #[serde(untagged)]
        enum Reply {
            Success(Success),
            Failure(Failure),
        }
        if bytes.len() > FRAME_BYTES {
            return Err("presentation_parent_invalid");
        }
        let parsed: Reply =
            serde_json::from_slice(bytes).map_err(|_| "presentation_parent_invalid")?;
        let (version, event, id, authority, result) = match parsed {
            Reply::Success(r) => (
                r.version,
                r.event,
                r.event_id,
                r.authority_instance_id,
                r.result.0,
            ),
            Reply::Failure(r) => {
                if !codec::error(&r.error) {
                    return Err("presentation_parent_invalid");
                }
                (
                    r.version,
                    r.event,
                    r.event_id,
                    r.authority_instance_id,
                    json!({"kind":"error","error":r.error}),
                )
            }
        };
        if version != 1
            || event != "phone-presentation-reply"
            || authority != self.authority
            || runtime::decimal(&id).ok().is_none_or(|n| n == 0)
        {
            return Err("presentation_parent_invalid");
        }
        let mut pending = self
            .pending
            .lock()
            .map_err(|_| "presentation_unavailable")?;
        if let Some(p) = pending.as_ref().filter(|p| p.id == id) {
            if !codec::result(&result, &p.request, &self.authority) {
                return Err("presentation_parent_invalid");
            }
        }
        if pending.as_ref().is_some_and(|p| p.id == id) {
            if let Some(p) = pending.take() {
                let _ = p.send.try_send(result);
            }
        }
        Ok(())
    }
}
pub(super) fn serve(
    channel: &mut ControlChannel,
    authority: &str,
    authorized: &mut AuthorizedConnection,
    bridge: &Bridge,
    protocol: Protocol,
    now: &mut impl FnMut() -> Result<u64, &'static str>,
) -> Result<(), &'static str> {
    let _connection = bridge.connection.try_lock().map_err(|error| match error {
        std::sync::TryLockError::WouldBlock => "presentation_busy",
        std::sync::TryLockError::Poisoned(_) => "presentation_unavailable",
    })?;
    let mut admission = authorized.reply("authenticated", authority);
    admission["role"] = json!("management");
    send(channel, admission)?;
    for index in 0..65 {
        let frame = match channel.receive() {
            Ok(frame) => frame,
            Err(_) if index > 0 => return Ok(()),
            Err(_) => return Err("authenticated_control_transport_failed"),
        };
        if frame.kind != FrameKind::Control || frame.payload.len() > 2048 {
            return Err("presentation_request_invalid");
        }
        let request = Request::parse(&frame.payload, &hex(&authorized.binding), protocol)?;
        let authorization = authorized.authorization.clone();
        {
            let _scope = authorization.guard()?;
            authorized.validate_cached(channel, now)?;
        }
        let operation = bridge.operation.try_lock();
        let mut result = match &operation {
            Ok(_) => match bridge.pin(&request) {
                Ok(()) => bridge.request(&request),
                Err(error) => json!({"kind":"error","error":error}),
            },
            Err(std::sync::TryLockError::WouldBlock) => {
                json!({"kind":"error","error":"presentation_busy"})
            }
            Err(_) => json!({"kind":"error","error":"presentation_unavailable"}),
        };
        // Management delivery fence is independent from input. Revoke/reenroll mark
        // dead first, drop global locks, then wait for this bounded delivery to drain.
        let _delivery = authorization.management_guard()?;
        if matches!(
            result.get("kind").and_then(Value::as_str),
            Some("presentation" | "icon")
        ) {
            if let Err(error) = bridge.pin(&request) {
                result = json!({"kind":"error","error":error});
            }
        }
        {
            let _scope = authorization.guard()?;
            authorized.validate_cached(channel, now)?;
        }
        // Configuration may replace after the final query; presentation never authorizes
        // input. The phone must discard updates unless its installed profile/epochs
        // and immutable map still match; role9 remains the input admission boundary.
        let mut reply = result
            .as_object()
            .ok_or("presentation_parent_invalid")?
            .clone();
        reply.insert("version".into(), json!(protocol.wire_version()));
        reply.insert(
            "command".into(),
            json!(if request.icon() {
                "configuration-presentation-icon-result"
            } else {
                "configuration-presentation-result"
            }),
        );
        reply.insert("connectionId".into(), json!(hex(&authorized.binding)));
        let reply = Value::Object(reply);
        if serde_json::to_vec(&reply)
            .map_err(|_| "presentation_parent_invalid")?
            .len()
            > if request.icon() { 16_384 } else { FRAME_BYTES }
        {
            return send(
                channel,
                json!({"version":protocol.wire_version(),"command":if request.icon(){"configuration-presentation-icon-result"}else{"configuration-presentation-result"},"connectionId":hex(&authorized.binding),"kind":"error","error":"presentation_response_too_large"}),
            );
        }
        send(channel, reply)?;
    }
    Ok(())
}
