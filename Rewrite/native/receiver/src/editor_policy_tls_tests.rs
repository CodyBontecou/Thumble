//! Policy integration through the actual bridge and pinned native TLS worker.
use super::*;
use super::{
    editor_tls_tests::{authenticated, setup},
    tests::{connect, receive, send},
};
const AUTHORITY: &str = "11111111-1111-1111-1111-111111111111";
fn start_write(
    host: &Host,
    endpoint: &Value,
    credential: &Value,
    events: &mpsc::Receiver<String>,
) -> (ControlChannel, Value) {
    let (mut channel, admission) = authenticated(endpoint, credential);
    send(
        &mut channel,
        json!({"version":1,"command":"configuration-set-control-label","connectionId":admission["connectionId"],"authorityInstanceId":AUTHORITY,"operationId":"policy-edit","expectedRevision":"1","profileId":"33333333-3333-3333-3333-333333333333","controlId":"44444444-4444-4444-4444-444444444444","label":"Jump"}),
    );
    let event =
        serde_json::from_str(&events.recv_timeout(Duration::from_secs(2)).unwrap()).unwrap();
    assert!(host.editor.coordinator().is_some());
    (channel, event)
}
fn owner_reply(host: &Host, event: &Value, kind: &str) {
    host.editor.deliver(json!({"version":1,"event":"phone-editor-write-reply","envelope":event["envelope"],"result":{"kind":kind,"error":"configuration_owner_busy"}}).to_string().as_bytes()).unwrap();
}
fn writable(path: &Path) -> bool {
    let db = rusqlite::Connection::open(path).unwrap();
    db.busy_timeout(Duration::ZERO).unwrap();
    db.execute_batch("BEGIN EXCLUSIVE;ROLLBACK").is_ok()
}
#[test]
fn actual_revoke_deferred_wait_accepts_owner_completion_without_retiring_healthy_writer() {
    let (_root, mut host, endpoint, credential, events) = setup();
    let (_channel, event) = start_write(&host, &endpoint, &credential, &events);
    let coordinator = host.editor.coordinator().unwrap();
    let prepared = host.prepare_revoke("phone-a".into()).unwrap();
    let (done, finished) = mpsc::sync_channel(1);
    let worker = thread::spawn(move || done.send(prepared.finish()).unwrap());
    // The actual main dispatcher remains free to receive this parent event.
    owner_reply(&host, &event, "owner-error");
    let (outcome, guard) = finished
        .recv_timeout(Duration::from_secs(1))
        .unwrap()
        .unwrap();
    assert!(outcome.is_ok());
    assert!(coordinator.retired_writer_if_any().unwrap().is_none());
    let mut output = Vec::new();
    GuardedLine {
        line: response(Some("revoke"), outcome),
        guard: Some(guard),
    }
    .write(&mut output)
    .unwrap();
    assert!(serde_json::from_slice::<Value>(&output).unwrap()["ok"]
        .as_bool()
        .unwrap());
    worker.join().unwrap();
}
#[test]
fn actual_orphan_busy_revoke_has_no_guard_and_repeat_reaps_bridge_without_lease_leak() {
    let (root, mut host, endpoint, credential, events) = setup();
    let (mut channel, event) = start_write(&host, &endpoint, &credential, &events);
    owner_reply(&host, &event, "not-dispatched");
    assert_eq!(receive(&mut channel)["error"], "editor_busy");
    let path = root.0.join("runtime/configuration-v1.sqlite3");
    let owner = rusqlite::Connection::open(&path).unwrap();
    owner
        .execute_batch("PRAGMA locking_mode=EXCLUSIVE;BEGIN EXCLUSIVE;COMMIT;")
        .unwrap();
    assert!(matches!(
        host.prepare_revoke("phone-a".into()).unwrap().finish(),
        Err("editor_policy_undrained")
    ));
    drop(owner);
    let (outcome, guard) = host
        .prepare_revoke("phone-a".into())
        .unwrap()
        .finish()
        .unwrap();
    assert!(outcome.is_ok());
    assert!(!writable(&path));
    // The retained proof is shared with a repeated same-phone acknowledgement.
    let (_, late) = host
        .prepare_revoke("phone-a".into())
        .unwrap()
        .finish()
        .unwrap();
    drop(guard);
    assert!(!writable(&path));
    drop(late);
    assert!(writable(&path));
    // The real bridge stays alive; its immutable tombstone holds no edit/lease.
    owner_reply(&host, &event, "owner-error");
    assert!(writable(&path));
}
#[test]
fn actual_reenrollment_guard_covers_both_tls_sends_and_error_unwind() {
    for stored in [true, false] {
        let (root, mut host, endpoint, credential, events) = setup();
        let (mut old, event) = start_write(&host, &endpoint, &credential, &events);
        owner_reply(&host, &event, "not-dispatched");
        assert_eq!(receive(&mut old)["error"], "editor_busy");
        old.close();
        let offer = host.execute(Command::PairingOpen {}).unwrap();
        let mut channel = connect(&endpoint);
        send(
            &mut channel,
            json!({"version":1,"command":"hello","controlVersion":2,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1}),
        );
        receive(&mut channel);
        send(
            &mut channel,
            json!({"version":1,"command":"enroll","authorityInstanceId":AUTHORITY,"windowId":offer["offer"]["windowId"],"proof":offer["offer"]["secret"],"phoneId":"phone-a","label":"Re-enrolled native editor"}),
        );
        let fresh = receive(&mut channel);
        assert_eq!(fresh["command"], "enrolled");
        let path = root.0.join("runtime/configuration-v1.sqlite3");
        assert!(!writable(&path));
        assert_ne!(fresh["credentialEpoch"], credential["credentialEpoch"]);
        send(
            &mut channel,
            json!({"version":1,"command":"enrollment-stored","phoneId":if stored {"phone-a"}else{"wrong-phone"},"credentialEpoch":fresh["credentialEpoch"]}),
        );
        if stored {
            assert_eq!(receive(&mut channel)["command"], "enrollment-complete");
        } else {
            assert!(channel.receive().is_err());
        }
        let until = std::time::Instant::now() + Duration::from_secs(1);
        while !writable(&path) && std::time::Instant::now() < until {
            thread::yield_now();
        }
        assert!(writable(&path));
        channel.close();
        owner_reply(&host, &event, "owner-error");
    }
}

#[test]
fn two_actual_same_phone_policy_success_and_storage_error_acks_share_lease_through_writer_queue() {
    let (root, mut host, endpoint, credential, events) = setup();
    let (mut channel, event) = start_write(&host, &endpoint, &credential, &events);
    owner_reply(&host, &event, "not-dispatched");
    assert_eq!(receive(&mut channel)["error"], "editor_busy");
    channel.close();
    let first = host.prepare_revoke("phone-a".into()).unwrap();
    // Real durable mutation failure AFTER the first revoke has detached the
    // ledger mapping; the second capture must use the trusted phone fallback.
    let trust = rusqlite::Connection::open(root.0.join("identity/phone-trust.sqlite3")).unwrap();
    trust.execute_batch("CREATE TRIGGER reject_policy_update BEFORE UPDATE ON phones BEGIN SELECT RAISE(ABORT,'policy fixture'); END;").unwrap();
    let second = host.prepare_revoke("phone-a".into()).unwrap();
    trust
        .execute_batch("DROP TRIGGER reject_policy_update;")
        .unwrap();
    drop(trust);
    let (first_result, first_guard) = first.finish().unwrap();
    let (second_result, second_guard) = second.finish().unwrap();
    assert!(first_result.is_ok());
    assert!(second_result.is_err());
    let path = root.0.join("runtime/configuration-v1.sqlite3");
    let (queue, incoming) = mpsc::sync_channel::<GuardedLine>(4);
    let (entered, observed) = mpsc::sync_channel::<()>(1);
    let (release, waiting) = mpsc::sync_channel::<()>(1);
    struct Sink {
        path: std::path::PathBuf,
        entered: mpsc::SyncSender<()>,
        waiting: mpsc::Receiver<()>,
    }
    impl std::io::Write for Sink {
        fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
            assert!(!writable(&self.path));
            Ok(bytes.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            assert!(!writable(&self.path));
            self.entered.send(()).unwrap();
            self.waiting.recv().unwrap();
            assert!(!writable(&self.path));
            Ok(())
        }
    }
    let writer_path = path.clone();
    let writer = thread::spawn(move || {
        let mut sink = Sink {
            path: writer_path,
            entered,
            waiting,
        };
        for line in incoming {
            line.write(&mut sink).unwrap();
        }
    });
    queue
        .send(GuardedLine {
            line: response(Some("policy-success"), first_result),
            guard: Some(first_guard),
        })
        .unwrap();
    queue
        .send(GuardedLine {
            line: response(Some("policy-storage-error"), second_result),
            guard: Some(second_guard),
        })
        .unwrap();
    drop(queue);
    observed.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(!writable(&path));
    release.send(()).unwrap();
    observed.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(!writable(&path));
    release.send(()).unwrap();
    writer.join().unwrap();
    assert!(writable(&path));
    // Actual Bridge survives both ACKs and no longer retains a lease-bearing edit.
    owner_reply(&host, &event, "owner-error");
    assert!(writable(&path));
}
