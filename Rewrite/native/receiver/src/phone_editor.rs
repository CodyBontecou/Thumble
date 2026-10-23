//! Authenticated role12 adapter. The captured writer is never replaced or inferred from phone data.
use super::{hex, send, AuthorizedConnection};
use crate::{
    cached_authorization::CachedAuthorization,
    control_tls::{ControlChannel, FrameKind},
    editor_codec::{self, Context, LabelIntent, Operation, Reply, Request},
    editor_commit_fence::{BoundDatabase, WriterLifetime},
    editor_pending::{EditContext, EditIntent, EditorCoordinator, PendingEdit},
};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    path::{Path, PathBuf},
    sync::{mpsc, Arc, Mutex},
    time::Duration,
};
const WAIT: Duration = Duration::from_secs(2);
const INVALID: &str = "phone_editor_parent_invalid";
struct Call {
    envelope: Value,
    request: Request,
    send: mpsc::SyncSender<Value>,
    edit: Option<Arc<PendingEdit>>,
    intent: Option<EditIntent>,
}
struct Tombstone {
    envelope: Value,
    request: Request,
}
struct State {
    next: u64,
    output: Option<mpsc::SyncSender<String>>,
    owner: Option<String>,
    coordinator: Option<Arc<EditorCoordinator>>,
    write: Option<Call>,
    read: Option<Call>,
    // After an orphan proof the exact old envelope remains bounded, without a DB lease.
    tombstone: Option<Tombstone>,
    read_tombstones: VecDeque<Tombstone>,
    closed: bool,
}
pub(crate) struct Bridge {
    authority: String,
    root: PathBuf,
    state: Mutex<State>,
}
fn uuid(value: &str) -> Result<[u8; 16], &'static str> {
    if value.len() != 36
        || value.bytes().enumerate().any(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b != b'-'
            } else {
                !(b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            }
        })
    {
        return Err(INVALID);
    }
    let digits: Vec<_> = value.bytes().filter(|b| *b != b'-').collect();
    let digit = |b: u8| if b <= b'9' { b - b'0' } else { b - b'a' + 10 };
    let mut result = [0; 16];
    for (i, p) in digits.chunks_exact(2).enumerate() {
        result[i] = digit(p[0]) * 16 + digit(p[1]);
    }
    Ok(result)
}
fn fields(value: &Value, expected: &[&str]) -> Result<(), &'static str> {
    let object = value.as_object().ok_or(INVALID)?;
    if object.len() != expected.len() || expected.iter().any(|k| !object.contains_key(*k)) {
        Err(INVALID)
    } else {
        Ok(())
    }
}
fn intent_value(i: &LabelIntent) -> Value {
    json!({"command":"configuration-set-control-label","operationId":i.operation_id,"expectedRevision":i.expected_revision.to_string(),"profileId":i.profile_id,"controlId":i.control_id,"label":i.label})
}
fn native_intent(i: &LabelIntent) -> Result<EditIntent, &'static str> {
    EditIntent::new(
        i.operation_id.clone(),
        i.expected_revision,
        uuid(&i.profile_id)?,
        uuid(&i.control_id)?,
        i.label.clone(),
    )
    .map_err(|_| INVALID)
}
fn phone_reply(request: &Request, outcome: Value) -> Result<Value, &'static str> {
    let mut object = outcome.as_object().ok_or(INVALID)?.clone();
    if object.remove("version").is_some_and(|v| v != json!(1)) {
        return Err(INVALID);
    }
    if ["command", "connectionId", "authorityInstanceId"]
        .iter()
        .any(|k| object.contains_key(*k))
    {
        return Err(INVALID);
    }
    object.insert("version".into(), json!(1));
    object.insert("command".into(), json!(request.command()));
    object.insert("connectionId".into(), json!(request.context.connection_id));
    object.insert(
        "authorityInstanceId".into(),
        json!(request.context.authority_instance_id),
    );
    let result = Value::Object(object);
    Reply::parse(&serde_json::to_vec(&result).map_err(|_| INVALID)?, request)
        .map(|r| r.value)
        .map_err(|_| INVALID)
}
fn error(request: &Request, code: &str) -> Value {
    phone_reply(request, json!({"kind":"error","error":code})).expect("fixed native error")
}
fn fixed_error(value: &Value) -> Result<&'static str, &'static str> {
    match value.as_str().ok_or(INVALID)? {
        "configuration_owner_busy" => Ok("editor_busy"),
        "configuration_source_changed" => Ok("editor_source_changed"),
        "configuration_access_denied" => Ok("editor_access_denied"),
        "operation_id_reused" => Ok("editor_operation_reused"),
        "configuration_profile_not_found" => Ok("editor_profile_not_found"),
        "configuration_control_not_found" => Ok("editor_control_not_found"),
        "unsupported_editor_profile" => Ok("editor_unsupported_profile"),
        "invalid_editor_read" => Ok("editor_invalid_request"),
        "editor_owner_unavailable" | "editor_owner_lifetime_mismatch" | "editor_unavailable" => {
            Ok("editor_unavailable")
        }
        _ => Err(INVALID),
    }
}
fn checked_result(
    request: &Request,
    envelope: &Value,
    result: &Value,
    write: bool,
) -> Result<(Value, bool), &'static str> {
    let kind = result["kind"].as_str().ok_or(INVALID)?;
    let mut definitive = false;
    let reply = match (write, kind) {
        (true, "owner-response") | (false, "read-response") => {
            fields(result, &["kind", "response"])?;
            let response = &result["response"];
            fields(response, &["envelope", "outcome"])?;
            if response["envelope"] != *envelope {
                return Err(INVALID);
            }
            if response["outcome"]["version"] != 1 {
                return Err(INVALID);
            }
            let reply = phone_reply(request, response["outcome"].clone())?;
            if write && !matches!(reply["kind"].as_str(), Some("committed" | "conflict")) {
                return Err(INVALID);
            }
            definitive = write;
            reply
        }
        (true, "owner-error") | (false, "read-error") => {
            fields(result, &["kind", "error"])?;
            let code = fixed_error(&result["error"])?;
            definitive = write;
            error(request, code)
        }
        (true, "not-dispatched") => {
            fields(result, &["kind", "error"])?;
            let code = fixed_error(&result["error"])?;
            error(request, code)
        }
        (true, "writer-exited" | "transport-uncertain") => {
            fields(result, &["kind", "disposition"])?;
            if result["disposition"] != "unknown" {
                return Err(INVALID);
            }
            error(request, "editor_unavailable")
        }
        _ => return Err(INVALID),
    };
    Ok((reply, definitive))
}
impl Bridge {
    pub(crate) fn new(authority: &str, root: &Path) -> Self {
        Self {
            authority: authority.into(),
            root: root.into(),
            state: Mutex::new(State {
                next: 1,
                output: None,
                owner: None,
                coordinator: None,
                write: None,
                read: None,
                tombstone: None,
                read_tombstones: VecDeque::new(),
                closed: false,
            }),
        }
    }
    pub(crate) fn enable(
        &self,
        owner: &str,
        output: mpsc::SyncSender<String>,
    ) -> Result<(), &'static str> {
        let writer = WriterLifetime::new(uuid(owner)?);
        uuid(&self.authority)?;
        let mut state = self.state.lock().map_err(|_| INVALID)?;
        if state.owner.is_some() || state.closed {
            return Err("editor_unavailable");
        }
        // Existing DB, immutable startup root and original UUID only. Never create a database here.
        let database = BoundDatabase::existing(&self.root, writer.clone())
            .map_err(|_| "editor_unavailable")?;
        state.coordinator = Some(EditorCoordinator::new(writer, database));
        state.owner = Some(owner.into());
        state.output = Some(output);
        Ok(())
    }
    pub(crate) fn enabled(&self) -> bool {
        self.state
            .lock()
            .map(|s| s.owner.is_some() && !s.closed)
            .unwrap_or(false)
    }
    pub(crate) fn enabled_for(&self, owner: &str) -> bool {
        uuid(owner).is_ok()
            && self
                .state
                .lock()
                .map(|s| !s.closed && s.owner.as_deref() == Some(owner))
                .unwrap_or(false)
    }
    pub(crate) fn try_coordinator(&self) -> Result<Option<Arc<EditorCoordinator>>, &'static str> {
        Ok(self.state.lock().map_err(|_| INVALID)?.coordinator.clone())
    }
    #[cfg(all(test, unix))]
    pub(crate) fn coordinator(&self) -> Option<Arc<EditorCoordinator>> {
        self.state.lock().ok()?.coordinator.clone()
    }
    pub(crate) fn parent_lost(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.closed = true;
            state.output = None;
            if let Some(c) = &state.coordinator {
                let _ = c.retire_writer();
            }
        }
    }
    /// Called only after an exact shared orphan completion proof was acquired.
    pub(crate) fn reap_orphan_completed(
        &self,
        edit: &Arc<PendingEdit>,
    ) -> Result<(), &'static str> {
        let mut state = self.state.lock().map_err(|_| INVALID)?;
        if state
            .write
            .as_ref()
            .and_then(|c| c.edit.as_ref())
            .is_some_and(|e| Arc::ptr_eq(e, edit))
        {
            state.tombstone = state.write.take().map(|c| Tombstone {
                envelope: c.envelope,
                request: c.request,
            });
        }
        Ok(())
    }
    fn request(
        &self,
        request: Request,
        authorization: CachedAuthorization,
        phone: &str,
        epoch: &str,
    ) -> Value {
        let published = (|| {
            let mut state = self.state.lock().map_err(|_| "editor_unavailable")?;
            if state.closed {
                return Err("editor_unavailable");
            }
            let write = matches!(request.operation, Operation::SetLabel(_));
            if if write {
                state.write.is_some()
            } else {
                state.read.is_some() || state.read_tombstones.len() == 4
            } {
                return Err("editor_busy");
            }
            let output = state.output.clone().ok_or("editor_unavailable")?;
            let coordinator = state.coordinator.clone().ok_or("editor_unavailable")?;
            let id = state.next.to_string();
            state.next = state.next.checked_add(1).ok_or("editor_unavailable")?;
            let payload = match &request.operation {
                Operation::SetLabel(i) => intent_value(i),
                Operation::LabelStatus(i) => {
                    json!({"command":"editor-label-status","intent":intent_value(i)})
                }
                Operation::Profile {
                    revision,
                    source_hash,
                    profile_id,
                    offset,
                } => {
                    json!({"command":"editor-profile","expectedRevision":revision.to_string(),"expectedSourceHash":source_hash,"profileId":profile_id,"offset":offset})
                }
            };
            let mut envelope = json!({"command":if write {"editor-label-commit"}else{"editor-read"},"ownerLifetimeId":state.owner,"eventId":id,"authorityInstanceId":self.authority,"phoneId":phone,"credentialEpoch":epoch});
            envelope[if write { "intent" } else { "query" }] = payload;
            let (send, received) = mpsc::sync_channel(1);
            let (edit, intent) = if let Operation::SetLabel(i) = &request.operation {
                let intent = native_intent(i)?;
                let context = EditContext::new(
                    id.clone(),
                    uuid(&self.authority)?,
                    phone.into(),
                    crate::runtime::decimal(epoch).map_err(|_| INVALID)?,
                )
                .map_err(|_| INVALID)?;
                let attachment = coordinator.attach(authorization);
                let edit = attachment
                    .admit(context, intent.clone())
                    .map_err(|_| "editor_busy")?;
                // Publish absolutely no bytes until the exact registered ticket is dispatched.
                if coordinator.begin_dispatch(&edit).is_err() {
                    let _ = attachment.close();
                    return Err("editor_access_denied");
                }
                (Some(edit), Some(intent))
            } else {
                (None, None)
            };
            let event=json!({"version":1,"event":if write {"phone-editor-write"}else{"phone-editor-read"},"envelope":envelope}).to_string();
            let call = Call {
                envelope,
                request: request.clone(),
                send,
                edit,
                intent,
            };
            if write {
                state.write = Some(call)
            } else {
                state.read = Some(call)
            }
            if output.try_send(event).is_err() {
                state.closed = true;
                if write {
                    let _ = coordinator
                        .uncertain_dispatch(state.write.as_ref().unwrap().edit.as_ref().unwrap());
                } else {
                    state.read = None;
                }
                return Err("editor_unavailable");
            }
            Ok((received, id, write))
        })();
        let (received, id, write) = match published {
            Ok(v) => v,
            Err(e) => return error(&request, e),
        };
        match received.recv_timeout(WAIT) {
            Ok(reply) => reply,
            Err(_) => {
                if let Ok(mut state) = self.state.lock() {
                    // This is only the phone response budget. The retained parent
                    // call still has its independent owner-health budget; elapsed
                    // time proves neither completion nor transport loss.
                    if !write
                        && state
                            .read
                            .as_ref()
                            .is_some_and(|c| c.envelope["eventId"] == id)
                    {
                        if let Some(call) = state.read.take() {
                            // Admission reserves space; never evict a still legitimate late reply.
                            debug_assert!(state.read_tombstones.len() < 4);
                            state.read_tombstones.push_back(Tombstone {
                                envelope: call.envelope,
                                request: call.request,
                            });
                        }
                    }
                }
                if let Operation::SetLabel(i) = &request.operation {
                    phone_reply(
                        &request,
                        json!({"kind":"editor-label-admitted","operationId":i.operation_id}),
                    )
                    .unwrap()
                } else {
                    error(&request, "editor_unavailable")
                }
            }
        }
    }
    pub(crate) fn deliver(&self, bytes: &[u8]) -> Result<(), &'static str> {
        let result = self.deliver_inner(bytes);
        if result.is_err() {
            self.parent_lost();
        }
        result
    }
    fn deliver_inner(&self, bytes: &[u8]) -> Result<(), &'static str> {
        let value = editor_codec::parent_json(bytes).map_err(|_| INVALID)?;
        fields(&value, &["version", "event", "envelope", "result"])?;
        if value["version"] != 1 {
            return Err(INVALID);
        }
        let write = match value["event"].as_str() {
            Some("phone-editor-write-reply") => true,
            Some("phone-editor-read-reply") => false,
            _ => return Err(INVALID),
        };
        let mut state = self.state.lock().map_err(|_| INVALID)?;
        if write {
            if let Some(tombstone) = &state.tombstone {
                if tombstone.envelope == value["envelope"] {
                    checked_result(
                        &tombstone.request,
                        &tombstone.envelope,
                        &value["result"],
                        true,
                    )?;
                    return Ok(());
                }
            }
        }
        if !write {
            if let Some(index) = state
                .read_tombstones
                .iter()
                .position(|t| t.envelope == value["envelope"])
            {
                let tombstone = &state.read_tombstones[index];
                checked_result(
                    &tombstone.request,
                    &tombstone.envelope,
                    &value["result"],
                    false,
                )?;
                state.read_tombstones.remove(index);
                return Ok(());
            }
        }
        let call = if write { &state.write } else { &state.read };
        let Some(call) = call else {
            return Err(INVALID);
        };
        if value["envelope"] != call.envelope {
            return Err(INVALID);
        }
        let (reply, definitive) =
            checked_result(&call.request, &call.envelope, &value["result"], write)?;
        if write {
            let coordinator = state.coordinator.as_ref().ok_or(INVALID)?;
            if definitive {
                coordinator
                    .actual_owner_completed(
                        call.edit.as_ref().ok_or(INVALID)?,
                        uuid(state.owner.as_ref().ok_or(INVALID)?)?,
                        call.envelope["eventId"].as_str().ok_or(INVALID)?,
                        call.intent.as_ref().ok_or(INVALID)?,
                    )
                    .map_err(|_| INVALID)?;
            } else {
                coordinator
                    .uncertain_dispatch(call.edit.as_ref().ok_or(INVALID)?)
                    .map_err(|_| INVALID)?;
            }
            let _ = call.send.try_send(reply);
            if definitive {
                state.write = None;
            } else {
                state.closed = true;
            }
        } else {
            let _ = call.send.try_send(reply);
            state.read = None;
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
    if frame.kind != FrameKind::Control {
        return Err("editor_invalid_request");
    }
    let request = Request::parse(
        &frame.payload,
        &Context {
            connection_id: hex(&authorized.binding),
            authority_instance_id: authority.into(),
        },
    )?;
    {
        let authorization = authorized.authorization.clone();
        let _scope = authorization.guard()?;
        authorized.validate_cached(channel, now)?;
    }
    let reply = bridge.request(
        request,
        authorized.authorization.clone(),
        &authorized.phone.phone_id,
        &authorized.phone.credential_epoch,
    );
    let authorization = authorized.authorization.clone();
    let _delivery = authorization.management_guard()?;
    {
        let _scope = authorization.guard()?;
        authorized.validate_cached(channel, now)?;
    }
    send(channel, reply)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::{
        authorization_clock::Clock, cached_authorization::Scope, editor_commit_fence::FenceError,
    };
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        sync::atomic::{AtomicU64, Ordering},
        thread,
    };
    static NEXT: AtomicU64 = AtomicU64::new(1);
    const AUTHORITY: &str = "11111111-1111-1111-1111-111111111111";
    const OWNER: &str = "22222222-2222-2222-2222-222222222222";
    struct Fixture {
        root: PathBuf,
        bridge: Arc<Bridge>,
        events: mpsc::Receiver<String>,
        scope: Arc<Scope>,
        authorization: CachedAuthorization,
    }
    impl Fixture {
        fn new() -> Self {
            let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("target/editor-fixtures")
                .join(format!(
                    "{}-{}",
                    std::process::id(),
                    NEXT.fetch_add(1, Ordering::Relaxed)
                ));
            fs::create_dir_all(&root).unwrap();
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
            let db = rusqlite::Connection::open(root.join("configuration-v1.sqlite3")).unwrap();
            db.execute_batch("PRAGMA application_id=1414021958;PRAGMA user_version=1;CREATE TABLE fixture(v INTEGER);").unwrap();
            drop(db);
            fs::set_permissions(
                root.join("configuration-v1.sqlite3"),
                fs::Permissions::from_mode(0o600),
            )
            .unwrap();
            let bridge = Arc::new(Bridge::new(AUTHORITY, &root));
            let (out, events) = mpsc::sync_channel(4);
            bridge.enable(OWNER, out).unwrap();
            let clock = Arc::new(Clock::new(100, 1100).unwrap());
            let scope = Scope::new(clock.clone());
            let authorization = CachedAuthorization::new(scope.clone(), clock);
            Self {
                root,
                bridge,
                events,
                scope,
                authorization,
            }
        }
        fn event(&self) -> Value {
            serde_json::from_str(&self.events.recv_timeout(WAIT).unwrap()).unwrap()
        }
        fn write(&self) -> thread::JoinHandle<Value> {
            let b = self.bridge.clone();
            let a = self.authorization.clone();
            thread::spawn(move || b.request(request(true), a, "phone-a", "1"))
        }
        fn deliver(&self, event: &Value, result: Value) -> Result<(), &'static str> {
            self.bridge.deliver(json!({"version":1,"event":if event["event"]=="phone-editor-write"{"phone-editor-write-reply"}else{"phone-editor-read-reply"},"envelope":event["envelope"],"result":result}).to_string().as_bytes())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    fn label() -> LabelIntent {
        LabelIntent {
            operation_id: "operation-one".into(),
            expected_revision: 1,
            profile_id: "33333333-3333-3333-3333-333333333333".into(),
            control_id: "44444444-4444-4444-4444-444444444444".into(),
            label: Some("Jump".into()),
        }
    }
    fn request(write: bool) -> Request {
        Request {
            context: Context {
                connection_id: "00000000000000000000000000000000".into(),
                authority_instance_id: AUTHORITY.into(),
            },
            operation: if write {
                Operation::SetLabel(label())
            } else {
                Operation::LabelStatus(label())
            },
        }
    }
    #[test]
    fn not_dispatched_retains_exact_write_and_late_actual_error_completes_after_tls_caller_left() {
        let f = Fixture::new();
        let caller = f.write();
        let event = f.event();
        let c = f.bridge.coordinator().unwrap();
        f.scope.retire().unwrap();
        let closed = c.close_retired_scope(f.scope.clone()).unwrap().unwrap();
        f.deliver(
            &event,
            json!({"kind":"not-dispatched","error":"configuration_owner_busy"}),
        )
        .unwrap();
        assert_eq!(caller.join().unwrap()["error"], "editor_busy");
        assert!(matches!(
            closed.wait_for_ack(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        assert_eq!(
            f.bridge
                .request(request(true), f.authorization.clone(), "phone-a", "1")["error"],
            "editor_unavailable"
        );
        f.deliver(
            &event,
            json!({"kind":"owner-error","error":"editor_unavailable"}),
        )
        .unwrap();
        assert!(closed.wait_for_ack(Duration::ZERO).is_ok());
    }
    #[test]
    fn read_completion_never_releases_write_and_counter_is_shared() {
        let f = Fixture::new();
        let writer = f.write();
        let write = f.event();
        let bridge = f.bridge.clone();
        let auth = f.authorization.clone();
        let reader = thread::spawn(move || bridge.request(request(false), auth, "phone-a", "1"));
        let read = f.event();
        assert_eq!(write["envelope"]["eventId"], "1");
        assert_eq!(read["envelope"]["eventId"], "2");
        f.deliver(&read,json!({"kind":"read-response","response":{"envelope":read["envelope"],"outcome":{"version":1,"kind":"editor-label-pending","operationId":"operation-one"}}})).unwrap();
        assert_eq!(reader.join().unwrap()["kind"], "editor-label-pending");
        assert_eq!(
            f.bridge
                .request(request(true), f.authorization.clone(), "phone-a", "1")["error"],
            "editor_busy"
        );
        f.scope.retire().unwrap();
        let closed = f
            .bridge
            .coordinator()
            .unwrap()
            .close_retired_scope(f.scope.clone())
            .unwrap()
            .unwrap();
        assert!(matches!(
            closed.wait_for_ack(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        f.deliver(
            &write,
            json!({"kind":"owner-error","error":"configuration_control_not_found"}),
        )
        .unwrap();
        assert_eq!(writer.join().unwrap()["error"], "editor_control_not_found");
        assert!(closed.wait_for_ack(Duration::ZERO).is_ok());
    }
    #[test]
    fn malformed_or_cross_context_response_retires_without_completion() {
        let f = Fixture::new();
        let writer = f.write();
        let event = f.event();
        let mut wrong = event.clone();
        wrong["envelope"]["credentialEpoch"] = json!("2");
        assert!(f
            .deliver(
                &wrong,
                json!({"kind":"owner-error","error":"editor_unavailable"})
            )
            .is_err());
        f.scope.retire().unwrap();
        let closed = f
            .bridge
            .coordinator()
            .unwrap()
            .close_retired_scope(f.scope.clone())
            .unwrap()
            .unwrap();
        assert!(matches!(
            closed.wait_for_ack(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        f.deliver(
            &event,
            json!({"kind":"owner-error","error":"editor_unavailable"}),
        )
        .unwrap();
        let _ = writer.join().unwrap();
        assert!(closed.wait_for_ack(Duration::ZERO).is_ok());
    }
    #[test]
    fn publication_backpressure_is_uncertain_and_never_cancels_a_dispatched_ticket() {
        let f = Fixture::new();
        let output = f.bridge.state.lock().unwrap().output.clone().unwrap();
        for _ in 0..4 {
            output.try_send("occupied".into()).unwrap();
        }
        let reply = f
            .bridge
            .request(request(true), f.authorization.clone(), "phone-a", "1");
        assert_eq!(reply["error"], "editor_unavailable");
        f.scope.retire().unwrap();
        let closed = f
            .bridge
            .coordinator()
            .unwrap()
            .close_retired_scope(f.scope.clone())
            .unwrap()
            .unwrap();
        assert!(matches!(
            closed.wait_for_ack(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        assert!(!f.bridge.enabled());
    }
    #[test]
    fn timeout_retains_write_and_late_actual_completion_still_correlates() {
        let f = Fixture::new();
        let writer = f.write();
        let event = f.event();
        assert_eq!(writer.join().unwrap()["kind"], "editor-label-admitted");
        assert!(f.bridge.enabled());
        assert_eq!(
            f.bridge
                .request(request(true), f.authorization.clone(), "phone-a", "1")["error"],
            "editor_busy"
        );
        f.scope.retire().unwrap();
        let closed = f
            .bridge
            .coordinator()
            .unwrap()
            .close_retired_scope(f.scope.clone())
            .unwrap()
            .unwrap();
        assert!(matches!(
            closed.wait_for_ack(Duration::ZERO),
            Err(FenceError::Pending)
        ));
        f.deliver(
            &event,
            json!({"kind":"owner-error","error":"editor_unavailable"}),
        )
        .unwrap();
        assert!(closed.wait_for_ack(Duration::ZERO).is_ok());
        // A fresh authenticated epoch can use the same healthy captured writer.
        let clock = Arc::new(Clock::new(100, 1100).unwrap());
        let authorization = CachedAuthorization::new(Scope::new(clock.clone()), clock);
        let bridge = f.bridge.clone();
        let next =
            thread::spawn(move || bridge.request(request(true), authorization, "phone-a", "2"));
        let event = f.event();
        f.deliver(
            &event,
            json!({"kind":"owner-error","error":"editor_unavailable"}),
        )
        .unwrap();
        assert_eq!(next.join().unwrap()["error"], "editor_unavailable");
        assert!(f.bridge.enabled());
    }
    #[test]
    fn exact_tombstone_validates_nested_late_context_without_retaining_a_ticket() {
        let f = Fixture::new();
        let envelope = json!({"command":"editor-label-commit","ownerLifetimeId":OWNER,"eventId":"1","authorityInstanceId":AUTHORITY,"phoneId":"phone-a","credentialEpoch":"1","intent":intent_value(&label())});
        f.bridge.state.lock().unwrap().tombstone = Some(Tombstone {
            envelope: envelope.clone(),
            request: request(true),
        });
        let reply = json!({"version":1,"event":"phone-editor-write-reply","envelope":envelope,"result":{"kind":"owner-error","error":"editor_unavailable"}});
        f.bridge.deliver(reply.to_string().as_bytes()).unwrap();
        let mut wrong = reply.clone();
        wrong["result"] = json!({"kind":"owner-response","response":{"envelope":{},"outcome":{"version":1,"kind":"conflict","currentRevision":"2"}}});
        assert!(f.bridge.deliver(wrong.to_string().as_bytes()).is_err());
        let mut invalid = reply;
        invalid["result"] = json!({"kind":"owner-error","error":"arbitrary-error"});
        assert!(f.bridge.deliver(invalid.to_string().as_bytes()).is_err());
    }
    #[test]
    fn late_read_after_timeout_keeps_new_read_and_writer_healthy() {
        let f = Fixture::new();
        let b = f.bridge.clone();
        let a = f.authorization.clone();
        let old = thread::spawn(move || b.request(request(false), a, "phone-a", "1"));
        let first = f.event();
        assert_eq!(old.join().unwrap()["error"], "editor_unavailable");
        let b = f.bridge.clone();
        let a = f.authorization.clone();
        let newer = thread::spawn(move || b.request(request(false), a, "phone-a", "1"));
        let second = f.event();
        let response = |event: &Value| json!({"kind":"read-response","response":{"envelope":event["envelope"],"outcome":{"version":1,"kind":"editor-label-pending","operationId":"operation-one"}}});
        let writer = f.write();
        let write = f.event();
        f.deliver(&first, response(&first)).unwrap();
        assert!(f.bridge.state.lock().unwrap().write.is_some());
        assert!(f.bridge.enabled());
        assert_eq!(
            f.bridge
                .state
                .lock()
                .unwrap()
                .read
                .as_ref()
                .unwrap()
                .envelope,
            second["envelope"]
        );
        f.deliver(&second, response(&second)).unwrap();
        assert_eq!(newer.join().unwrap()["kind"], "editor-label-pending");
        f.deliver(
            &write,
            json!({"kind":"owner-error","error":"editor_unavailable"}),
        )
        .unwrap();
        writer.join().unwrap();
        let mut wrong = response(&first);
        wrong["response"]["envelope"]["phoneId"] = json!("other-phone");
        assert!(f.deliver(&first, wrong).is_err());
    }
    #[test]
    fn read_tombstone_capacity_blocks_new_reads_without_eviction_or_writer_retirement() {
        let f = Fixture::new();
        {
            let mut state = f.bridge.state.lock().unwrap();
            for i in 1..=4 {
                state.read_tombstones.push_back(Tombstone {
                    envelope: json!({"eventId":i.to_string()}),
                    request: request(false),
                });
            }
        }
        assert_eq!(
            f.bridge
                .request(request(false), f.authorization.clone(), "phone-a", "1")["error"],
            "editor_busy"
        );
        assert!(f.bridge.enabled());
        assert_eq!(f.bridge.state.lock().unwrap().read_tombstones.len(), 4);
        assert!(f.events.try_recv().is_err());
    }
    #[test]
    fn duplicate_parent_fields_and_untrusted_enable_uuid_fail_closed() {
        let f = Fixture::new();
        assert!(f.bridge.enabled_for(OWNER));
        assert!(!f.bridge.enabled_for(AUTHORITY));
        assert!(!f.bridge.enabled_for("invalid-owner"));
        assert!(f.bridge.deliver(br#"{"version":1,"version":1,"event":"phone-editor-read-reply","envelope":{},"result":{}}"#).is_err());
        let b = Bridge::new(AUTHORITY, &f.root);
        let (tx, _) = mpsc::sync_channel(1);
        assert!(b.enable("../other-owner", tx).is_err());
        assert!(!b.enabled());
        assert!(serde_json::from_value::<crate::pairing_host::Command>(
            json!({"command":"phone-editor-enable","ownerLifetimeId":OWNER,"path":"/wrong"})
        )
        .is_err());
    }
}
