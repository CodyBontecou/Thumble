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
        mpsc, Mutex,
    },
    time::Duration,
};
#[path = "phone_controls_codec.rs"]
mod codec;
use codec::{Request, Scalars, FRAME_BYTES};
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
    operation: Mutex<()>,
    output: Mutex<Option<mpsc::SyncSender<String>>>,
    pending: Mutex<Option<Pending>>,
    next: AtomicU64,
}
impl Bridge {
    pub(crate) fn new(authority: &str, root: &Path) -> Self {
        Self {
            authority: authority.into(),
            root: root.into(),
            operation: Mutex::new(()),
            output: Mutex::new(None),
            pending: Mutex::new(None),
            next: AtomicU64::new(1),
        }
    }
    pub(crate) fn attach(&self, output: mpsc::SyncSender<String>) -> Result<(), &'static str> {
        let mut slot = self.output.lock().map_err(|_| "saved_map_unavailable")?;
        if slot.is_some() {
            return Err("saved_map_unavailable");
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
        let mut client = Client::connect(&self.root).map_err(|_| "saved_map_unavailable")?;
        let (configuration, pin) = client
            .output_configuration()
            .map_err(|_| "saved_map_unavailable")?;
        // This ephemeral read-only connection closes before parent/TLS waits.
        let pin = pin
            .filter(|pin| {
                configuration.active
                    && pin.configuration_revision == request.expected_configuration_revision
                    && pin.source_hash == request.expected_source_hash
                    && pin.profile_id == request.profile_id
                    && pin.generation == request.generation
                    && pin.revision == request.revision
            })
            .ok_or("saved_map_reactivation_required")?;
        if configuration.generation.to_string() != pin.generation
            || configuration.revision.to_string() != pin.revision
        {
            return Err("saved_map_reactivation_required");
        }
        Ok(())
    }
    fn request(&self, request: &Request) -> Value {
        let result = (|| {
            let output = self
                .output
                .lock()
                .map_err(|_| "saved_map_unavailable")?
                .clone()
                .ok_or("saved_map_unavailable")?;
            let id = self
                .next
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
                .map_err(|_| "saved_map_unavailable")?
                .to_string();
            let (send, received) = mpsc::sync_channel(1);
            {
                let mut pending = self.pending.lock().map_err(|_| "saved_map_unavailable")?;
                if pending.is_some() {
                    return Err("saved_map_busy");
                }
                *pending = Some(Pending {
                    id: id.clone(),
                    request: request.clone(),
                    send,
                });
            }
            let event=json!({"version":1,"event":"phone-controls","eventId":id,"authorityInstanceId":self.authority,"expectedConfigurationRevision":request.expected_configuration_revision,"expectedSourceHash":request.expected_source_hash,"profileId":request.profile_id,"generation":request.generation,"revision":request.revision,"viewportWidth":request.viewport_width,"viewportHeight":request.viewport_height}).to_string();
            let reply = if output.try_send(event).is_err() {
                Err("saved_map_unavailable")
            } else {
                received.recv_timeout(WAIT).map_err(|_| "saved_map_timeout")
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
            return Err("saved_map_parent_invalid");
        }
        let parsed: Reply =
            serde_json::from_slice(bytes).map_err(|_| "saved_map_parent_invalid")?;
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
                    return Err("saved_map_parent_invalid");
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
            || event != "phone-controls-reply"
            || authority != self.authority
            || runtime::decimal(&id).ok().is_none_or(|n| n == 0)
        {
            return Err("saved_map_parent_invalid");
        }
        let mut pending = self.pending.lock().map_err(|_| "saved_map_unavailable")?;
        if let Some(p) = pending.as_ref().filter(|p| p.id == id) {
            if !codec::result(&result, &p.request, &self.authority) {
                return Err("saved_map_parent_invalid");
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
    now: &mut impl FnMut() -> Result<u64, &'static str>,
) -> Result<(), &'static str> {
    let mut admission = authorized.reply("authenticated", authority);
    admission["role"] = json!("management");
    send(channel, admission)?;
    let frame = channel
        .receive()
        .map_err(|_| "authenticated_control_transport_failed")?;
    if frame.kind != FrameKind::Control || frame.payload.len() > 1024 {
        return Err("saved_map_request_invalid");
    }
    let request: Request =
        serde_json::from_slice(&frame.payload).map_err(|_| "saved_map_request_invalid")?;
    if !request.valid(&hex(&authorized.binding)) {
        return Err("saved_map_request_invalid");
    }
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
            json!({"kind":"error","error":"saved_map_busy"})
        }
        Err(_) => json!({"kind":"error","error":"saved_map_unavailable"}),
    };
    // Management delivery fence is independent from input. Revoke/reenroll mark
    // dead first, drop global locks, then wait for this bounded delivery to drain.
    let _delivery = authorization.management_guard()?;
    if result.get("kind").and_then(Value::as_str) == Some("controls") {
        if let Err(error) = bridge.pin(&request) {
            result = json!({"kind":"error","error":error});
        }
    }
    {
        let _scope = authorization.guard()?;
        authorized.validate_cached(channel, now)?;
    }
    // A configuration may replace after the final query. The phone must still
    // recheck the returned generation/revision against role6 bind/grant before install.
    let mut reply = result
        .as_object()
        .ok_or("saved_map_parent_invalid")?
        .clone();
    reply.insert("version".into(), json!(1));
    reply.insert("command".into(), json!("configuration-controls-result"));
    reply.insert("connectionId".into(), json!(hex(&authorized.binding)));
    let reply = Value::Object(reply);
    if serde_json::to_vec(&reply)
        .map_err(|_| "saved_map_parent_invalid")?
        .len()
        > FRAME_BYTES
    {
        return send(
            channel,
            json!({"version":1,"command":"configuration-controls-result","connectionId":hex(&authorized.binding),"kind":"error","error":"saved_map_response_too_large"}),
        );
    }
    send(channel, reply)
}
#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::Arc, thread};
    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../packages/fixtures/saved-controller-control-v8.json"
        ))
        .unwrap()
    }
    fn request() -> Request {
        serde_json::from_value(fixture()["request"].clone()).unwrap()
    }
    fn result() -> Value {
        let mut value = fixture()["reply"].clone();
        for key in ["version", "command", "connectionId"] {
            value.as_object_mut().unwrap().remove(key);
        }
        value
    }
    #[test]
    fn management_parent_bridge_rejects_malformed_results_and_preserves_single_pending_correlation()
    {
        let bridge = Arc::new(Bridge::new("synthetic-authority", Path::new("unused")));
        let (output, events) = mpsc::sync_channel(1);
        bridge.attach(output).unwrap();
        let copy = bridge.clone();
        let worker = thread::spawn(move || copy.request(&request()));
        let event: Value = serde_json::from_str(&events.recv_timeout(WAIT).unwrap()).unwrap();
        assert_eq!(event["eventId"], "1");
        assert!(event.get("connectionId").is_none());
        assert!(event.get("credential").is_none());
        assert_eq!(
            bridge.request(&request()),
            json!({"kind":"error","error":"saved_map_busy"})
        );
        let reply = json!({"version":1,"event":"phone-controls-reply","eventId":"1","authorityInstanceId":"synthetic-authority","result":result()});
        let encoded = serde_json::to_string(&reply).unwrap();
        let duplicate = encoded.replace(
            "\"kind\":\"controls\"",
            "\"kind\":\"controls\",\"kind\":\"controls\"",
        );
        assert_eq!(
            bridge.deliver(duplicate.as_bytes()),
            Err("saved_map_parent_invalid")
        );
        for (key, value) in [
            ("authorityInstanceId", json!("wrong-authority")),
            ("eventId", json!("01")),
            ("event", json!("phone-catalog-reply")),
        ] {
            let mut bad = reply.clone();
            bad[key] = value;
            assert_eq!(
                bridge.deliver(&serde_json::to_vec(&bad).unwrap()),
                Err("saved_map_parent_invalid")
            );
        }
        let mut bad = reply.clone();
        bad["result"]["sourceHash"] = json!("b".repeat(64));
        assert_eq!(
            bridge.deliver(&serde_json::to_vec(&bad).unwrap()),
            Err("saved_map_parent_invalid")
        );
        let mut late = reply.clone();
        late["eventId"] = json!("999");
        bridge.deliver(&serde_json::to_vec(&late).unwrap()).unwrap();
        bridge.deliver(encoded.as_bytes()).unwrap();
        assert_eq!(worker.join().unwrap(), result());
        // A duplicate completion and an old response cannot satisfy a new slot.
        bridge.deliver(encoded.as_bytes()).unwrap();
        let copy = bridge.clone();
        let next = thread::spawn(move || copy.request(&request()));
        let event: Value = serde_json::from_str(&events.recv_timeout(WAIT).unwrap()).unwrap();
        assert_eq!(event["eventId"], "3");
        bridge.deliver(encoded.as_bytes()).unwrap();
        let next_reply = json!({"version":1,"event":"phone-controls-reply","eventId":"3","authorityInstanceId":"synthetic-authority","error":"saved_map_unsupported_profile"});
        bridge
            .deliver(&serde_json::to_vec(&next_reply).unwrap())
            .unwrap();
        assert_eq!(
            next.join().unwrap(),
            json!({"kind":"error","error":"saved_map_unsupported_profile"})
        );
        assert_eq!(
            bridge.deliver(&vec![b' '; FRAME_BYTES + 1]),
            Err("saved_map_parent_invalid")
        );
    }
}
