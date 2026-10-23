//! The actual native stdin dispatcher must keep consuming owner replies while
//! policy draining is deferred. No real phone or output backend is used.
#![cfg(unix)]
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Child, Command, Stdio},
    sync::mpsc,
    thread,
    time::Duration,
};
use thumble_rewrite_receiver::{
    control_tls::{CertificatePin, ControlChannel, FrameKind},
    host_identity,
};
const AUTH: &str = "11111111-1111-1111-1111-111111111111";
struct Owner {
    child: Child,
    input: Option<std::process::ChildStdin>,
    output: mpsc::Receiver<Value>,
    root: PathBuf,
}
impl Owner {
    fn new() -> Self {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("target/policy-process-tests")
            .join(std::process::id().to_string());
        fs::create_dir_all(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        host_identity::load_or_create(&root.join("identity")).unwrap();
        let runtime = root.join("runtime");
        fs::create_dir_all(&runtime).unwrap();
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
        thumble_rewrite_receiver::security::directory(&runtime).unwrap();
        let db = rusqlite::Connection::open(runtime.join("configuration-v1.sqlite3")).unwrap();
        db.execute_batch("PRAGMA application_id=1414021958;PRAGMA user_version=1;CREATE TABLE fixture(v INTEGER);").unwrap();
        drop(db);
        fs::set_permissions(
            runtime.join("configuration-v1.sqlite3"),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_thumble-rewrite-receiver"))
            .arg("pairing-host")
            .arg(&runtime)
            .arg(AUTH)
            .arg(root.join("identity"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let input = child.stdin.take();
        let stdout = child.stdout.take().unwrap();
        let (send, output) = mpsc::sync_channel(16);
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                let value = serde_json::from_str(&line).unwrap();
                if send.send(value).is_err() {
                    break;
                }
            }
        });
        let owner = Self {
            child,
            input,
            output,
            root,
        };
        assert_eq!(owner.next()["ready"], true);
        owner
    }
    fn send(&mut self, value: Value) {
        let input = self.input.as_mut().unwrap();
        writeln!(input, "{value}").unwrap();
        input.flush().unwrap();
    }
    fn request(&mut self, id: &str, body: Value) {
        self.send(json!({"version":1,"requestId":id,"body":body}));
    }
    fn next(&self) -> Value {
        self.output.recv_timeout(Duration::from_secs(3)).unwrap()
    }
}
impl Drop for Owner {
    fn drop(&mut self) {
        self.input.take();
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.root);
    }
}
fn send(channel: &mut ControlChannel, value: Value) {
    channel
        .send(FrameKind::Control, &serde_json::to_vec(&value).unwrap())
        .unwrap();
}
fn receive(channel: &mut ControlChannel) -> Value {
    serde_json::from_slice(&channel.receive().unwrap().payload).unwrap()
}
fn connect(endpoint: &Value) -> ControlChannel {
    ControlChannel::connect_pinned(
        format!("127.0.0.1:{}", endpoint["transport"]["port"])
            .parse()
            .unwrap(),
        CertificatePin::from_hex(endpoint["transport"]["certificatePin"].as_str().unwrap())
            .unwrap(),
    )
    .unwrap()
}
fn hello(channel: &mut ControlChannel, version: u8) {
    let mut value = json!({"version":1,"command":"hello","controlVersion":version,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1});
    if version == 12 {
        value["role"] = json!("management");
    }
    send(channel, value);
    receive(channel);
}
#[test]
fn native_stdio_reads_parent_completion_and_other_requests_while_revoke_waits() {
    let mut owner = Owner::new();
    owner.request("enable",json!({"command":"phone-editor-enable","ownerLifetimeId":"22222222-2222-2222-2222-222222222222"}));
    assert_eq!(owner.next()["ok"], true);
    owner.request(
        "listen",
        json!({"command":"pairing-listen","bindAddress":"127.0.0.1:0","advertiseHost":"127.0.0.1"}),
    );
    let endpoint = owner.next()["result"].clone();
    let mut channel = connect(&endpoint);
    hello(&mut channel, 2);
    send(
        &mut channel,
        json!({"version":1,"command":"enroll","authorityInstanceId":AUTH,"windowId":endpoint["offer"]["windowId"],"proof":endpoint["offer"]["secret"],"phoneId":"phone-a","label":"Policy process fixture"}),
    );
    let credential = receive(&mut channel);
    send(
        &mut channel,
        json!({"version":1,"command":"enrollment-stored","phoneId":"phone-a","credentialEpoch":credential["credentialEpoch"]}),
    );
    receive(&mut channel);
    channel.close();
    let mut channel = connect(&endpoint);
    hello(&mut channel, 12);
    send(
        &mut channel,
        json!({"version":1,"command":"authenticate","authorityInstanceId":AUTH,"phoneId":"phone-a","credentialEpoch":credential["credentialEpoch"],"credential":credential["credential"]}),
    );
    let authenticated = receive(&mut channel);
    send(
        &mut channel,
        json!({"version":1,"command":"configuration-set-control-label","connectionId":authenticated["connectionId"],"authorityInstanceId":AUTH,"operationId":"process-operation","expectedRevision":"1","profileId":"33333333-3333-3333-3333-333333333333","controlId":"44444444-4444-4444-4444-444444444444","label":"Jump"}),
    );
    let event = owner.next();
    assert_eq!(event["event"], "phone-editor-write");
    owner.request(
        "revoke",
        json!({"command":"pairing-revoke","phoneId":"phone-a"}),
    );
    for id in ["concurrent-revoke", "queued-three", "queued-four"] {
        owner.request(id, json!({"command":"pairing-revoke","phoneId":"phone-a"}));
    }
    owner.request(
        "busy-revoke",
        json!({"command":"pairing-revoke","phoneId":"phone-a"}),
    );
    owner.request("status-during-drain", json!({"command":"pairing-status"}));
    let status = owner.next();
    assert_eq!(status["requestId"], "status-during-drain");
    assert_eq!(status["ok"], true);
    owner.send(json!({"version":1,"event":"phone-editor-write-reply","envelope":event["envelope"],"result":{"kind":"owner-error","error":"configuration_owner_busy"}}));
    for id in ["revoke", "concurrent-revoke", "queued-three", "queued-four"] {
        let revoked = owner.next();
        assert_eq!(revoked["requestId"], id);
        assert_eq!(revoked["ok"], true);
    }
    assert!(owner
        .output
        .recv_timeout(Duration::from_millis(150))
        .is_err());
    channel.close();
    owner.input.take();
    assert!(owner.child.wait().unwrap().success());
}
