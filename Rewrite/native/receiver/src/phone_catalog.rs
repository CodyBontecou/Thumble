//! Private parent-mediated catalog reads. No editable catalog or bearer enters this bridge.
use super::{hex, send, AuthorizedConnection};
use crate::{
    control_tls::{ControlChannel, FrameKind},
    runtime,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    mpsc, Mutex,
};
use std::time::Duration;
const REQUEST_BYTES: usize = 1024;
const REPLY_BYTES: usize = 32768;
const WAIT: Duration = Duration::from_secs(2);
struct Pending {
    id: String,
    send: mpsc::SyncSender<Value>,
}
/// One pending read, one bounded output queue; never holds policy or trust locks.
pub(crate) struct Bridge {
    authority: String,
    output: Mutex<Option<mpsc::SyncSender<String>>>,
    pending: Mutex<Option<Pending>>,
    next: AtomicU64,
}
impl Bridge {
    pub(crate) fn new(authority: &str) -> Self {
        Self {
            authority: authority.into(),
            output: Mutex::new(None),
            pending: Mutex::new(None),
            next: AtomicU64::new(1),
        }
    }
    pub(crate) fn attach(&self, output: mpsc::SyncSender<String>) -> Result<(), &'static str> {
        let mut slot = self
            .output
            .lock()
            .map_err(|_| "phone_catalog_unavailable")?;
        if slot.is_some() {
            return Err("phone_catalog_unavailable");
        }
        *slot = Some(output);
        Ok(())
    }
    pub(crate) fn enabled(&self) -> bool {
        self.output.lock().map(|o| o.is_some()).unwrap_or(false)
    }
    fn request(&self, expected: Option<String>, offset: u16) -> Value {
        let result = (|| {
            let output = self
                .output
                .lock()
                .map_err(|_| "phone_catalog_unavailable")?
                .clone()
                .ok_or("phone_catalog_unavailable")?;
            let (send, received) = mpsc::sync_channel(1);
            let id = self
                .next
                .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| n.checked_add(1))
                .map_err(|_| "phone_catalog_unavailable")?
                .to_string();
            {
                let mut pending = self
                    .pending
                    .lock()
                    .map_err(|_| "phone_catalog_unavailable")?;
                if pending.is_some() {
                    return Err("phone_catalog_busy");
                }
                *pending = Some(Pending {
                    id: id.clone(),
                    send,
                });
            }
            let event=json!({"version":1,"event":"phone-catalog","eventId":id,"authorityInstanceId":self.authority,"expectedRevision":expected,"offset":offset}).to_string();
            let reply = if output.try_send(event).is_err() {
                Err("phone_catalog_unavailable")
            } else {
                received
                    .recv_timeout(WAIT)
                    .map_err(|_| "phone_catalog_timeout")
            };
            // A late response cannot satisfy the successor's request, even after timeout.
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
            result: FlatResult,
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
        if bytes.len() > REPLY_BYTES {
            return Err("phone_catalog_parent_invalid");
        }
        let parsed: Reply =
            serde_json::from_slice(bytes).map_err(|_| "phone_catalog_parent_invalid")?;
        let (version, event, id, authority, result) = match parsed {
            Reply::Success(r) => (
                r.version,
                r.event,
                r.event_id,
                r.authority_instance_id,
                r.result.0,
            ),
            Reply::Failure(r) => {
                if !matches!(
                    r.error.as_str(),
                    "phone_catalog_busy" | "phone_catalog_timeout" | "phone_catalog_unavailable"
                ) {
                    return Err("phone_catalog_parent_invalid");
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
            || event != "phone-catalog-reply"
            || authority != self.authority
            || runtime::decimal(&id).ok().is_none_or(|id| id == 0)
            || !flat(&result)
        {
            return Err("phone_catalog_parent_invalid");
        }
        let mut pending = self
            .pending
            .lock()
            .map_err(|_| "phone_catalog_unavailable")?;
        if pending.as_ref().is_some_and(|p| p.id == id) {
            if let Some(p) = pending.take() {
                let _ = p.send.try_send(result);
            }
        }
        Ok(())
    }
}
// Parent results are scalar-only objects. Deserialize pairs directly so duplicate
// keys cannot disappear through serde_json::Value's map construction.
struct FlatResult(Value);
impl<'de> Deserialize<'de> for FlatResult {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        struct Object;
        impl<'de> serde::de::Visitor<'de> for Object {
            type Value = FlatResult;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a bounded unique scalar object")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut map: M,
            ) -> Result<Self::Value, M::Error> {
                let mut result = serde_json::Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if result.len() >= 64 || result.contains_key(&key) {
                        return Err(serde::de::Error::custom("duplicate or excess result keys"));
                    }
                    let value: Value = map.next_value()?;
                    if !(value.is_null() || value.is_string() || value.is_u64()) {
                        return Err(serde::de::Error::custom("non-scalar result"));
                    }
                    result.insert(key, value);
                }
                Ok(FlatResult(Value::Object(result)))
            }
        }
        deserializer.deserialize_map(Object)
    }
}
fn flat(value: &Value) -> bool {
    value.as_object().is_some_and(|v| {
        v.len() <= 64
            && !["version", "command", "connectionId"]
                .iter()
                .any(|k| v.contains_key(*k))
            && v.values()
                .all(|v| v.is_null() || v.is_string() || v.is_u64())
            && serde_json::to_vec(value).is_ok_and(|b| b.len() <= REPLY_BYTES - 128)
    })
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    version: u8,
    command: String,
    connection_id: String,
    #[serde(deserialize_with = "Option::<String>::deserialize")]
    expected_revision: Option<String>,
    offset: u16,
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
    // This role has no input methods, and each connection handles one bounded page.
    let frame = channel
        .receive()
        .map_err(|_| "authenticated_control_transport_failed")?;
    if frame.kind != FrameKind::Control || frame.payload.len() > REQUEST_BYTES {
        return Err("phone_catalog_request_invalid");
    }
    let request: Request =
        serde_json::from_slice(&frame.payload).map_err(|_| "phone_catalog_request_invalid")?;
    if request.version != 1
        || request.command != "configuration-list"
        || request.connection_id != hex(&authorized.binding)
        || request.offset > 255
        || request
            .expected_revision
            .as_ref()
            .is_some_and(|r| runtime::decimal(r).is_err())
        || (request.offset > 0 && request.expected_revision.is_none())
    {
        return Err("phone_catalog_request_invalid");
    }
    {
        let authorization = authorized.authorization.clone();
        let _scope = authorization.guard()?;
        authorized.validate_cached(channel, now)?;
    }
    let result = bridge.request(request.expected_revision, request.offset);
    let mut reply = result
        .as_object()
        .ok_or("phone_catalog_parent_invalid")?
        .clone();
    reply.insert("version".into(), json!(1));
    reply.insert("command".into(), json!("configuration-result"));
    reply.insert("connectionId".into(), json!(hex(&authorized.binding)));
    let reply = Value::Object(reply);
    if serde_json::to_vec(&reply)
        .map_err(|_| "phone_catalog_parent_invalid")?
        .len()
        > REPLY_BYTES
    {
        return Err("phone_catalog_parent_invalid");
    }
    let authorization = authorized.authorization.clone();
    // Delivery is fenced against revoke acknowledgement, independently of input.
    let _delivery = authorization.management_guard()?;
    {
        let _scope = authorization.guard()?;
        authorized.validate_cached(channel, now)?;
    }
    send(channel, reply)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{sync::Arc, thread};
    fn empty() -> Value {
        json!({"kind":"catalog","revision":"0","contentHash":null,"activeProfileId":null,"defaultProfileId":null,"nextOffset":null,"profileCount":0})
    }
    #[test]
    fn bridge_correlation_busy_bounds_and_late_responses_are_private_and_bounded() {
        let bridge = Arc::new(Bridge::new("authority-a"));
        let (output, events) = mpsc::sync_channel(1);
        bridge.attach(output).unwrap();
        let copy = bridge.clone();
        let worker = thread::spawn(move || copy.request(None, 0));
        let event: Value = serde_json::from_str(&events.recv_timeout(WAIT).unwrap()).unwrap();
        assert_eq!(
            event,
            json!({"version":1,"event":"phone-catalog","eventId":"1","authorityInstanceId":"authority-a","expectedRevision":null,"offset":0})
        );
        assert_eq!(
            bridge.request(None, 0),
            json!({"kind":"error","error":"phone_catalog_busy"})
        );
        let reply = json!({"version":1,"event":"phone-catalog-reply","eventId":"1","authorityInstanceId":"foreign","result":empty()});
        assert_eq!(
            bridge.deliver(&serde_json::to_vec(&reply).unwrap()),
            Err("phone_catalog_parent_invalid")
        );
        let mut reply = reply;
        reply["authorityInstanceId"] = json!("authority-a");
        bridge
            .deliver(&serde_json::to_vec(&reply).unwrap())
            .unwrap();
        assert_eq!(worker.join().unwrap(), empty());
        // Unknown/late IDs do not reply to a new pending read, or fail the owner.
        bridge
            .deliver(&serde_json::to_vec(&reply).unwrap())
            .unwrap();
        for result in [
            json!({"kind":"catalog","version":99}),
            json!({"kind":"catalog","profiles":[]}),
            json!({"kind":"catalog","source":"x".repeat(REPLY_BYTES)}),
        ] {
            reply["result"] = result;
            assert!(bridge
                .deliver(&serde_json::to_vec(&reply).unwrap())
                .is_err());
        }
    }
    #[test]
    fn duplicate_private_result_and_header_keys_fail_closed() {
        let bridge = Bridge::new("authority-a");
        for bytes in [
            r#"{"version":1,"event":"phone-catalog-reply","eventId":"1","authorityInstanceId":"authority-a","result":{"kind":"conflict","currentRevision":"1","currentRevision":"2"}}"#,
            r#"{"version":1,"version":1,"event":"phone-catalog-reply","eventId":"1","authorityInstanceId":"authority-a","result":{"kind":"conflict","currentRevision":"1"}}"#,
            r#"{"version":1,"event":"phone-catalog-reply","eventId":"1","authorityInstanceId":"authority-a","result":{"nested":{"kind":"conflict","kind":"error"}}}"#,
        ] {
            assert_eq!(
                bridge.deliver(bytes.as_bytes()),
                Err("phone_catalog_parent_invalid")
            );
        }
    }
    #[test]
    fn bridge_timeout_drops_response_without_renewing_or_queuing_work() {
        let bridge = Arc::new(Bridge::new("authority-a"));
        let (output, events) = mpsc::sync_channel(1);
        bridge.attach(output).unwrap();
        let copy = bridge.clone();
        let worker = thread::spawn(move || copy.request(Some("18446744073709551615".into()), 16));
        let old: Value = serde_json::from_str(&events.recv_timeout(WAIT).unwrap()).unwrap();
        assert_eq!(
            worker.join().unwrap(),
            json!({"kind":"error","error":"phone_catalog_timeout"})
        );
        let copy = bridge.clone();
        let worker = thread::spawn(move || copy.request(None, 0));
        let next: Value = serde_json::from_str(&events.recv_timeout(WAIT).unwrap()).unwrap();
        assert_ne!(old["eventId"], next["eventId"]);
        bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-catalog-reply","eventId":old["eventId"],"authorityInstanceId":"authority-a","result":empty()})).unwrap()).unwrap();
        bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-catalog-reply","eventId":next["eventId"],"authorityInstanceId":"authority-a","error":"phone_catalog_busy"})).unwrap()).unwrap();
        assert_eq!(
            worker.join().unwrap(),
            json!({"kind":"error","error":"phone_catalog_busy"})
        );
    }
}
