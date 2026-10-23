//! Real pinned TLS + native credential admission + local parent event adapter.
use super::tests::{connect, listen, receive, send, Root};
use super::*;
use std::os::unix::fs::PermissionsExt;
const AUTHORITY: &str = "11111111-1111-1111-1111-111111111111";
const OWNER: &str = "22222222-2222-2222-2222-222222222222";
pub(super) fn setup() -> (Root, Host, Value, Value, mpsc::Receiver<String>) {
    let root = Root::new();
    let runtime = root.0.join("runtime");
    let mut host = Host::new(&runtime, AUTHORITY, Some(&root.0.join("identity"))).unwrap();
    let db = rusqlite::Connection::open(runtime.join("configuration-v1.sqlite3")).unwrap();
    db.execute_batch(
        "PRAGMA application_id=1414021958;PRAGMA user_version=1;CREATE TABLE fixture(v INTEGER);",
    )
    .unwrap();
    drop(db);
    std::fs::set_permissions(
        runtime.join("configuration-v1.sqlite3"),
        std::fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let (tx, rx) = mpsc::sync_channel(4);
    host.editor.enable(OWNER, tx).unwrap();
    assert_eq!(
        host.execute(Command::PhoneEditorEnable {
            owner_lifetime_id: OWNER.into()
        })
        .unwrap(),
        json!({"kind":"phone-editor-enabled"})
    );
    let endpoint = listen(&mut host);
    let mut channel = connect(&endpoint);
    send(
        &mut channel,
        json!({"version":1,"command":"hello","controlVersion":2,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1}),
    );
    receive(&mut channel);
    send(
        &mut channel,
        json!({"version":1,"command":"enroll","authorityInstanceId":AUTHORITY,"windowId":endpoint["offer"]["windowId"],"proof":endpoint["offer"]["secret"],"phoneId":"phone-a","label":"Native editor"}),
    );
    let credential = receive(&mut channel);
    send(
        &mut channel,
        json!({"version":1,"command":"enrollment-stored","phoneId":"phone-a","credentialEpoch":credential["credentialEpoch"]}),
    );
    assert_eq!(receive(&mut channel)["command"], "enrollment-complete");
    channel.close();
    (root, host, endpoint, credential, rx)
}
pub(super) fn authenticated(endpoint: &Value, credential: &Value) -> (ControlChannel, Value) {
    let mut channel = connect(endpoint);
    send(
        &mut channel,
        json!({"version":1,"command":"hello","controlVersion":12,"role":"management","inputVersion":1,"documentVersion":1,"capabilitiesVersion":1}),
    );
    let hello = receive(&mut channel);
    assert_eq!(hello["controlVersion"], 12);
    assert_eq!(hello["role"], "management");
    assert_eq!(hello["inputEnabled"], false);
    assert_eq!(hello["inputSessionAvailable"], false);
    send(
        &mut channel,
        json!({"version":1,"command":"authenticate","authorityInstanceId":AUTHORITY,"phoneId":"phone-a","credentialEpoch":credential["credentialEpoch"],"credential":credential["credential"]}),
    );
    let admission = receive(&mut channel);
    assert_eq!(admission["role"], "management");
    assert_eq!(admission["inputSessionAvailable"], false);
    assert_eq!(admission["inputEnabled"], false);
    (channel, admission)
}
#[test]
fn editor_role12_real_pinned_tls_committed_receipt_and_read_are_strictly_correlated() {
    let (_root, host, endpoint, credential, events) = setup();
    let (mut channel, admission) = authenticated(&endpoint, &credential);
    let intent = json!({"command":"configuration-set-control-label","operationId":"edit-one","expectedRevision":"1","profileId":"33333333-3333-3333-3333-333333333333","controlId":"44444444-4444-4444-4444-444444444444","label":"Jump"});
    let mut request = intent.clone();
    request["version"] = json!(1);
    request["connectionId"] = admission["connectionId"].clone();
    request["authorityInstanceId"] = json!(AUTHORITY);
    send(&mut channel, request);
    let event: Value =
        serde_json::from_str(&events.recv_timeout(Duration::from_secs(2)).unwrap()).unwrap();
    assert_eq!(event["event"], "phone-editor-write");
    assert_eq!(event["envelope"]["intent"], intent);
    assert_eq!(event["envelope"]["phoneId"], "phone-a");
    assert_eq!(
        event["envelope"]["credentialEpoch"],
        credential["credentialEpoch"]
    );
    assert_eq!(event["envelope"]["ownerLifetimeId"], OWNER);
    let receipt = json!({"version":1,"operationId":"edit-one","resultingRevision":"2","contentHash":"a".repeat(64),"affectedEntities":[intent["profileId"],intent["controlId"]]});
    host.editor.deliver(json!({"version":1,"event":"phone-editor-write-reply","envelope":event["envelope"],"result":{"kind":"owner-response","response":{"envelope":event["envelope"],"outcome":{"version":1,"kind":"committed","receipt":receipt,"replayed":false}}}}).to_string().as_bytes()).unwrap();
    let reply = receive(&mut channel);
    assert_eq!(reply["kind"], "committed");
    assert_eq!(reply["receipt"], receipt);
    channel.close();
    let (mut channel, admission) = authenticated(&endpoint, &credential);
    send(
        &mut channel,
        json!({"version":1,"command":"editor-label-status","connectionId":admission["connectionId"],"authorityInstanceId":AUTHORITY,"intent":intent}),
    );
    let read: Value =
        serde_json::from_str(&events.recv_timeout(Duration::from_secs(2)).unwrap()).unwrap();
    assert_eq!(read["event"], "phone-editor-read");
    assert_eq!(read["envelope"]["eventId"], "2");
    host.editor.deliver(json!({"version":1,"event":"phone-editor-read-reply","envelope":read["envelope"],"result":{"kind":"read-response","response":{"envelope":read["envelope"],"outcome":{"version":1,"kind":"editor-label-receipt","receipt":receipt}}}}).to_string().as_bytes()).unwrap();
    assert_eq!(receive(&mut channel)["kind"], "editor-label-receipt");
    channel.close();
}
#[test]
fn editor_role12_rejects_extra_phone_context_before_any_parent_event() {
    let (_root, _host, endpoint, credential, events) = setup();
    let (mut channel, admission) = authenticated(&endpoint, &credential);
    send(
        &mut channel,
        json!({"version":1,"command":"editor-label-status","connectionId":admission["connectionId"],"authorityInstanceId":AUTHORITY,"phoneId":"attacker","intent":{"command":"configuration-set-control-label","operationId":"edit-one","expectedRevision":"1","profileId":"33333333-3333-3333-3333-333333333333","controlId":"44444444-4444-4444-4444-444444444444","label":null}}),
    );
    assert!(channel.receive().is_err());
    assert!(events.try_recv().is_err());
}
