use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    net::{Ipv4Addr, TcpStream},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};
use thumble_rewrite_receiver::{
    gamepad::{hex, NEUTRAL},
    generated::GamepadState,
    native_ingress::Client,
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Receiver {
    root: PathBuf,
    child: Child,
    input: Option<ChildStdin>,
    replies: mpsc::Receiver<Value>,
    serial: u64,
}
impl Receiver {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "thumble-native-ingress-process-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let mut child = Command::new(env!("CARGO_BIN_EXE_thumble-rewrite-receiver"))
            .arg("run")
            .arg(&root)
            .arg(root.join("recording.jsonl"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let stdout = child.stdout.take().unwrap();
        let input = child.stdin.take();
        let (sender, replies) = mpsc::channel::<Value>();
        thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let line = match line {
                    Ok(line) => line,
                    Err(_) => break,
                };
                if let Ok(value) = serde_json::from_str(&line) {
                    if sender.send(value).is_err() {
                        break;
                    }
                }
            }
        });
        let ready = replies.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(ready["ready"], true);
        Self {
            root,
            child,
            input,
            replies,
            serial: 0,
        }
    }
    fn command(&mut self, body: Value) -> Value {
        self.serial += 1;
        let value = json!({"version":1,"requestId":format!("native-{}",self.serial),"body":body});
        writeln!(self.input.as_mut().unwrap(), "{value}").unwrap();
        self.input.as_mut().unwrap().flush().unwrap();
        self.replies.recv_timeout(Duration::from_secs(2)).unwrap()
    }
    fn activate(&mut self) {
        assert_eq!(self.command(json!({"command":"activate","generation":"1","revision":"1","profileId":"profile-a","sessionId":"service-owner","leaseMs":750,"inputTtlMs":350}))["ok"],true);
    }
    fn status(&mut self) -> Value {
        let reply = self.command(json!({"command":"status"}));
        assert_eq!(reply["ok"], true);
        reply["snapshot"].clone()
    }
    fn wait_neutral(&mut self) {
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            if self.status()["active"] == false {
                break;
            }
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(self.status()["reportHex"], hex(&NEUTRAL));
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        self.input = None;
        let _ = self.child.kill();
        let _ = self.child.wait();
        for _ in 0..100 {
            if fs::remove_dir_all(&self.root).is_ok() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}
fn held() -> GamepadState {
    serde_json::from_value(json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":1,"rightTrigger":1})).unwrap()
}
#[test]
fn native_process_routes_sealed_packets_without_bun_and_preserves_replay_and_owner_fences() {
    let mut receiver = Receiver::new();
    let mut client = Client::connect(&receiver.root).unwrap();
    assert!(!client.configuration().unwrap().active);
    assert!(client.grant([8; 16], 1, 1, 1000).is_err());
    receiver.activate();
    let configuration = client.configuration().unwrap();
    assert!(configuration.active);
    assert_eq!(configuration.generation, 1);
    assert_eq!(configuration.revision, 1);
    assert!(client.grant([8; 16], 1, 2, 1000).is_err());
    let grant = client.grant([8; 16], 1, 1, 1000).unwrap();
    assert_eq!(grant.generation(), 1);
    assert_eq!(grant.revision(), 1);
    assert_eq!(grant.lifetime_ms(), 1000);
    let binding = grant.binding();
    let mut sender = grant.into_sender().unwrap();
    let packet = sender.seal(&held()).unwrap();
    client.packet(binding, &packet).unwrap();
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    assert!(client.packet(binding, &packet).is_err());
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    let sample=receiver.command(json!({"command":"sample","generation":"1","sessionId":"service-owner","sequence":"99","state":held()}));
    assert_eq!(sample["error"], "packet_session_owns_input");
    let renew =
        receiver.command(json!({"command":"renew","generation":"1","sessionId":"service-owner"}));
    assert_eq!(renew["ok"], true);
    client.release(binding).unwrap();
    receiver.wait_neutral();
    assert!(client
        .packet(binding, &sender.seal(&held()).unwrap())
        .is_err());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(receiver.root.join("native-input.endpoint"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }
}
#[test]
fn stale_local_connection_cleanup_cannot_release_a_new_source_but_current_disconnect_does() {
    let mut receiver = Receiver::new();
    receiver.activate();
    let mut old = Client::connect(&receiver.root).unwrap();
    let grant = old.grant([8; 16], 1, 1, 1000).unwrap();
    let old_ref = grant.binding();
    let mut old_sender = grant.into_sender().unwrap();
    old.packet(old_ref, &old_sender.seal(&held()).unwrap())
        .unwrap();
    let mut new = Client::connect(&receiver.root).unwrap();
    let grant = new.grant([9; 16], 1, 1, 1000).unwrap();
    let binding = grant.binding();
    let mut sender = grant.into_sender().unwrap();
    assert_eq!(receiver.status()["reportHex"], hex(&NEUTRAL));
    drop(old);
    new.packet(binding, &sender.seal(&held()).unwrap()).unwrap();
    thread::sleep(Duration::from_millis(30));
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    assert!(new
        .packet(old_ref, &old_sender.seal(&held()).unwrap())
        .is_err());
    new.packet(binding, &sender.seal(&held()).unwrap()).unwrap();
    drop(new);
    receiver.wait_neutral();
}
#[test]
fn continuous_native_traffic_cannot_keep_a_lost_configuration_owner_alive() {
    let mut receiver = Receiver::new();
    receiver.activate();
    let mut client = Client::connect(&receiver.root).unwrap();
    let grant = client.grant([8; 16], 1, 1, 2000).unwrap();
    let binding = grant.binding();
    let mut sender = grant.into_sender().unwrap();
    let started = Instant::now();
    let mut accepted = 0;
    let mut rejected = false;
    while started.elapsed() < Duration::from_millis(1000) {
        if client
            .packet(binding, &sender.seal(&held()).unwrap())
            .is_ok()
        {
            accepted += 1;
        } else {
            rejected = true;
            break;
        }
        thread::sleep(Duration::from_millis(60));
    }
    assert!(accepted > 1);
    assert!(rejected);
    receiver.wait_neutral();
    assert_eq!(receiver.status()["lastReleaseReason"], "lease_expired");
}
#[test]
fn stalled_ipc_clients_do_not_block_owner_commands_or_input_expiry() {
    let mut receiver = Receiver::new();
    receiver.activate();
    let mut client = Client::connect(&receiver.root).unwrap();
    let grant = client.grant([8; 16], 1, 1, 2000).unwrap();
    let binding = grant.binding();
    let mut sender = grant.into_sender().unwrap();
    client
        .packet(binding, &sender.seal(&held()).unwrap())
        .unwrap();
    let endpoint = fs::read(receiver.root.join("native-input.endpoint")).unwrap();
    let port = u16::from_le_bytes(endpoint[8..10].try_into().unwrap());
    let mut stalled = Vec::new();
    for _ in 0..7 {
        stalled.push(TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap());
    }
    for _ in 0..4 {
        thread::sleep(Duration::from_millis(100));
        receiver.command(json!({"command":"renew","generation":"1","sessionId":"service-owner"}));
    }
    receiver.wait_neutral();
    assert_eq!(receiver.status()["lastReleaseReason"], "input_expired");
    drop(stalled);
}

use thumble_rewrite_receiver::{
    control_tls::{CertificatePin, ControlChannel, FrameKind},
    host_identity,
    input_packet::{PacketGrant, PacketSender, PACKET_LIMIT},
    pairing_host::{Command as PairingCommand, Host},
};
fn listen_host(receiver: &Receiver) -> (Host, Value) {
    let identity = receiver.root.join("identity");
    host_identity::load_or_create(&identity).unwrap();
    let mut host = Host::new(&receiver.root, "broker-authority", Some(&identity)).unwrap();
    let value = host
        .execute(PairingCommand::PairingListen {
            bind_address: "127.0.0.1:0".into(),
            advertise_host: "127.0.0.1".into(),
        })
        .unwrap();
    (host, value)
}
fn control_connect(value: &Value) -> ControlChannel {
    ControlChannel::connect_pinned(
        format!("127.0.0.1:{}", value["transport"]["port"])
            .parse()
            .unwrap(),
        CertificatePin::from_hex(value["transport"]["certificatePin"].as_str().unwrap()).unwrap(),
    )
    .unwrap()
}
fn control_send(channel: &mut ControlChannel, value: Value) {
    channel
        .send(FrameKind::Control, &serde_json::to_vec(&value).unwrap())
        .unwrap();
}
fn control_receive(channel: &mut ControlChannel) -> Value {
    let frame = channel.receive().unwrap();
    assert_eq!(frame.kind, FrameKind::Control);
    serde_json::from_slice(&frame.payload).unwrap()
}
fn control_hello(channel: &mut ControlChannel, version: u8) {
    control_send(
        channel,
        json!({"version":1,"command":"hello","controlVersion":version,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1}),
    );
    assert_eq!(control_receive(channel)["controlVersion"], version);
}
fn phone_enroll(value: &Value) -> Value {
    let mut channel = control_connect(value);
    control_hello(&mut channel, 2);
    control_send(
        &mut channel,
        json!({"version":1,"command":"enroll","authorityInstanceId":"broker-authority","windowId":value["offer"]["windowId"],"proof":value["offer"]["secret"],"phoneId":"phone-a","label":"Native input broker test"}),
    );
    let credential = control_receive(&mut channel);
    assert_eq!(credential["command"], "enrolled");
    control_send(
        &mut channel,
        json!({"version":1,"command":"enrollment-stored","phoneId":"phone-a","credentialEpoch":credential["credentialEpoch"]}),
    );
    assert_eq!(
        control_receive(&mut channel)["command"],
        "enrollment-complete"
    );
    credential
}
fn phone_auth(value: &Value, credential: &Value) -> (ControlChannel, Value) {
    let mut channel = control_connect(value);
    control_hello(&mut channel, 4);
    control_send(
        &mut channel,
        json!({"version":1,"command":"authenticate","authorityInstanceId":"broker-authority","phoneId":"phone-a","credentialEpoch":credential["credentialEpoch"],"credential":credential["credential"]}),
    );
    let receipt = control_receive(&mut channel);
    assert_eq!(receipt["command"], "authenticated");
    assert_eq!(receipt["inputSessionAvailable"], true);
    assert_eq!(receipt["inputEnabled"], false);
    (channel, receipt)
}
fn decode_hex<const N: usize>(value: &Value) -> [u8; N] {
    let text = value.as_str().unwrap();
    assert_eq!(text.len(), N * 2);
    let mut out = [0; N];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).unwrap();
    }
    out
}
fn phone_grant(channel: &mut ControlChannel, receipt: &Value) -> (PacketSender, Value) {
    control_send(
        channel,
        json!({"version":1,"command":"input-configuration","connectionId":receipt["connectionId"]}),
    );
    let configuration = control_receive(channel);
    assert_eq!(configuration["active"], true);
    control_send(
        channel,
        json!({"version":1,"command":"input-grant","connectionId":receipt["connectionId"],"generation":configuration["generation"],"revision":configuration["revision"]}),
    );
    let grant = control_receive(channel);
    assert_eq!(grant["command"], "input-granted");
    assert_eq!(grant["connectionId"], receipt["connectionId"]);
    assert_eq!(grant["generation"], configuration["generation"]);
    assert_eq!(grant["inputEnabled"], false);
    assert!(grant["lifetimeMs"].as_u64().unwrap() <= 60000);
    let sender = PacketSender::new(
        PacketGrant::new(
            &decode_hex(&grant["key"]),
            decode_hex(&grant["sessionId"]),
            decode_hex(&grant["noncePrefix"]),
            grant["generation"].as_str().unwrap().parse().unwrap(),
        )
        .unwrap(),
        PACKET_LIMIT,
    )
    .unwrap();
    (sender, grant)
}
fn phone_held(channel: &mut ControlChannel, receipt: &Value, sender: &mut PacketSender) {
    channel
        .send(FrameKind::Input, &sender.seal(&held()).unwrap())
        .unwrap();
    // A following ordered control reply proves the previous native input RPC completed.
    control_send(
        channel,
        json!({"version":1,"command":"control-status","connectionId":receipt["connectionId"]}),
    );
    assert_eq!(control_receive(channel)["command"], "control-status");
}
#[test]
fn authenticated_tls_input_reaches_the_independent_receiver_and_revocation_waits_for_neutral() {
    let mut receiver = Receiver::new();
    receiver.activate();
    let (mut host, value) = listen_host(&receiver);
    let credential = phone_enroll(&value);
    assert_eq!(
        receiver.command(json!({"command":"renew","generation":"1","sessionId":"service-owner"}))
            ["ok"],
        true
    );
    let (mut channel, receipt) = phone_auth(&value, &credential);
    let (mut sender, _) = phone_grant(&mut channel, &receipt);
    phone_held(&mut channel, &receipt, &mut sender);
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    let revoked = host
        .execute(PairingCommand::PairingRevoke {
            phone_id: "phone-a".into(),
        })
        .unwrap();
    assert_eq!(revoked["phones"][0]["active"], false);
    let status = receiver.status();
    assert_eq!(status["active"], false);
    assert_eq!(status["reportHex"], hex(&NEUTRAL));
    assert_eq!(status["lastReleaseReason"], "native_input_released");
    assert!(channel.receive().is_err());
}
#[test]
fn reenrollment_retires_old_receiver_keys_before_delivering_the_new_credential() {
    let mut receiver = Receiver::new();
    receiver.activate();
    let (mut host, value) = listen_host(&receiver);
    let old = phone_enroll(&value);
    receiver.command(json!({"command":"renew","generation":"1","sessionId":"service-owner"}));
    let (mut channel, receipt) = phone_auth(&value, &old);
    let (mut sender, _) = phone_grant(&mut channel, &receipt);
    phone_held(&mut channel, &receipt, &mut sender);
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    let offer = host.execute(PairingCommand::PairingOpen {}).unwrap();
    let fresh = phone_enroll(&offer);
    assert_ne!(fresh["credentialEpoch"], old["credentialEpoch"]);
    assert_eq!(receiver.status()["reportHex"], hex(&NEUTRAL));
    assert_eq!(receiver.status()["active"], false);
    control_send(
        &mut channel,
        json!({"version":1,"command":"control-status","connectionId":receipt["connectionId"]}),
    );
    assert!(channel.receive().is_err());
}
#[test]
fn native_tls_source_release_is_acknowledged_and_a_peer_drop_retires_its_grant() {
    let mut receiver = Receiver::new();
    receiver.activate();
    let (_host, value) = listen_host(&receiver);
    let credential = phone_enroll(&value);
    receiver.command(json!({"command":"renew","generation":"1","sessionId":"service-owner"}));
    let (mut channel, receipt) = phone_auth(&value, &credential);
    let (mut sender, grant) = phone_grant(&mut channel, &receipt);
    phone_held(&mut channel, &receipt, &mut sender);
    control_send(
        &mut channel,
        json!({"version":1,"command":"input-release","connectionId":receipt["connectionId"],"sessionId":grant["sessionId"]}),
    );
    assert_eq!(control_receive(&mut channel)["command"], "input-released");
    assert_eq!(receiver.status()["reportHex"], hex(&NEUTRAL));
    assert_eq!(receiver.command(json!({"command":"activate","generation":"2","revision":"2","profileId":"profile-a","sessionId":"service-owner","leaseMs":750,"inputTtlMs":350}))["ok"],true);
    let (mut sender, _) = phone_grant(&mut channel, &receipt);
    phone_held(&mut channel, &receipt, &mut sender);
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    // A delayed release of the previous session must not retire the fresh generation.
    control_send(
        &mut channel,
        json!({"version":1,"command":"input-release","connectionId":receipt["connectionId"],"sessionId":grant["sessionId"]}),
    );
    assert_eq!(control_receive(&mut channel)["command"], "input-released");
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    channel.close();
    receiver.wait_neutral();
    assert_eq!(
        receiver.status()["lastReleaseReason"],
        "native_input_released"
    );
}
#[test]
fn stale_grant_receipts_and_old_generation_packets_cannot_replace_or_release_new_configuration() {
    let mut receiver = Receiver::new();
    receiver.activate();
    let (_host, value) = listen_host(&receiver);
    let credential = phone_enroll(&value);
    receiver.command(json!({"command":"renew","generation":"1","sessionId":"service-owner"}));
    let (mut channel, receipt) = phone_auth(&value, &credential);
    let (mut sender, _) = phone_grant(&mut channel, &receipt);
    phone_held(&mut channel, &receipt, &mut sender);
    let (mut stale, stale_receipt) = phone_auth(&value, &credential);
    control_send(
        &mut stale,
        json!({"version":1,"command":"input-grant","connectionId":stale_receipt["connectionId"],"generation":"1","revision":"2"}),
    );
    assert!(stale.receive().is_err());
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    assert_eq!(receiver.command(json!({"command":"activate","generation":"2","revision":"2","profileId":"profile-b","sessionId":"service-owner","leaseMs":750,"inputTtlMs":350}))["ok"],true);
    channel
        .send(FrameKind::Input, &sender.seal(&held()).unwrap())
        .unwrap();
    assert!(channel.receive().is_err());
    let status = receiver.status();
    assert_eq!(status["active"], true);
    assert_eq!(status["generation"], "2");
    assert_eq!(status["reportHex"], hex(&NEUTRAL));
    let (mut fresh, fresh_receipt) = phone_auth(&value, &credential);
    let (mut sender, _) = phone_grant(&mut fresh, &fresh_receipt);
    phone_held(&mut fresh, &fresh_receipt, &mut sender);
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
}
