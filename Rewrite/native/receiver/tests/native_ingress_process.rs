use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    net::{Ipv4Addr, TcpStream},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc, Arc, Mutex,
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
struct OwnerPipe {
    input: Option<ChildStdin>,
    replies: mpsc::Receiver<Value>,
    serial: u64,
}
impl OwnerPipe {
    fn command(&mut self, body: Value) -> Value {
        self.serial += 1;
        let value = json!({"version":1,"requestId":format!("native-{}",self.serial),"body":body});
        writeln!(self.input.as_mut().unwrap(), "{value}").unwrap();
        self.input.as_mut().unwrap().flush().unwrap();
        self.replies.recv_timeout(Duration::from_secs(2)).unwrap()
    }
}
struct OwnerHeartbeat {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Drop for OwnerHeartbeat {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.thread.take() {
            worker.join().unwrap();
        }
    }
}
struct Receiver {
    root: PathBuf,
    child: Child,
    owner: Arc<Mutex<OwnerPipe>>,
    generation: Arc<AtomicU64>,
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
            owner: Arc::new(Mutex::new(OwnerPipe {
                input,
                replies,
                serial: 0,
            })),
            generation: Arc::new(AtomicU64::new(0)),
        }
    }
    fn command(&mut self, body: Value) -> Value {
        let generation = if matches!(body["command"].as_str(), Some("activate" | "activateSaved")) {
            body["generation"].as_str().and_then(|s| s.parse().ok())
        } else {
            None
        };
        let reply = self.owner.lock().unwrap().command(body);
        if reply["ok"] == true {
            if let Some(generation) = generation {
                self.generation.store(generation, Ordering::SeqCst);
            }
        }
        reply
    }
    /// Model the independent healthy configuration owner during valid transport scenarios.
    /// Tests of owner disappearance intentionally do not create this guard.
    fn maintain_owner(&self) -> OwnerHeartbeat {
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let owner = self.owner.clone();
        let generation = self.generation.clone();
        let worker = thread::spawn(move || {
            while !stopped.load(Ordering::SeqCst) {
                let generation = generation.load(Ordering::SeqCst);
                if generation > 0 {
                    let Ok(mut owner) = owner.lock() else { break };
                    let _ = owner.command(json!({"command":"renew","generation":generation.to_string(),"sessionId":"service-owner"}));
                }
                thread::sleep(Duration::from_millis(50));
            }
        });
        OwnerHeartbeat {
            stop,
            thread: Some(worker),
        }
    }
    fn activate(&mut self) {
        self.activate_timing(750, 350);
    }
    fn activate_timing(&mut self, lease: u64, ttl: u64) {
        assert_eq!(self.command(json!({"command":"activate","generation":"1","revision":"1","profileId":"profile-a","sessionId":"service-owner","leaseMs":lease,"inputTtlMs":ttl}))["ok"],true);
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
        self.owner.lock().unwrap_or_else(|e| e.into_inner()).input = None;
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
    let _owner = receiver.maintain_owner();
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
    let _owner = receiver.maintain_owner();
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
    // Native IPC cleanup can issue a later idempotent release after rejecting
    // the first post-expiry packet. Require the actual lease-expiry output event.
    let events: Vec<Value> = fs::read_to_string(receiver.root.join("recording.jsonl"))
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let reasons: Vec<_> = events.iter().map(|event| event["reason"].clone()).collect();
    assert!(
        events
            .iter()
            .any(|event| event["reason"] == "lease_expired" && event["reportHex"] == hex(&NEUTRAL)),
        "missing native lease fence: {reasons:?}"
    );
    assert_eq!(receiver.status()["reportHex"], hex(&NEUTRAL));
}
#[test]
fn stalled_ipc_clients_do_not_block_owner_commands_or_input_expiry() {
    let mut receiver = Receiver::new();
    let _owner = receiver.maintain_owner();
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
#[track_caller]
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
fn try_phone_held(
    channel: &mut ControlChannel,
    receipt: &Value,
    sender: &mut PacketSender,
) -> Result<(), &'static str> {
    channel
        .send(
            FrameKind::Input,
            &sender.seal(&held()).map_err(|_| "sample_seal_failed")?,
        )
        .map_err(|_| "sample_input_send_failed")?;
    // A following ordered control reply proves the previous native input RPC completed.
    let request = serde_json::to_vec(
        &json!({"version":1,"command":"control-status","connectionId":receipt["connectionId"]}),
    )
    .map_err(|_| "sample_status_encoding_failed")?;
    channel
        .send(FrameKind::Control, &request)
        .map_err(|_| "sample_status_send_failed")?;
    let reply = channel
        .receive()
        .map_err(|_| "sample_status_receive_failed")?;
    let value: Value =
        serde_json::from_slice(&reply.payload).map_err(|_| "sample_status_json_failed")?;
    if reply.kind != FrameKind::Control || value["command"] != "control-status" {
        return Err("sample_status_invalid");
    }
    Ok(())
}
fn phone_held(channel: &mut ControlChannel, receipt: &Value, sender: &mut PacketSender) {
    try_phone_held(channel, receipt, sender).unwrap();
}
#[test]
fn authenticated_tls_input_reaches_the_independent_receiver_and_revocation_waits_for_neutral() {
    let mut receiver = Receiver::new();
    let _owner = receiver.maintain_owner();
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
    let _owner = receiver.maintain_owner();
    receiver.activate();
    let (mut host, value) = listen_host(&receiver);
    let old = phone_enroll(&value);
    receiver.command(json!({"command":"renew","generation":"1","sessionId":"service-owner"}));
    let (mut channel, receipt) = phone_auth(&value, &old);
    let (mut sender, _) = phone_grant(&mut channel, &receipt);
    phone_held(&mut channel, &receipt, &mut sender);
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    let stop = Arc::new(AtomicBool::new(false));
    let stopped = stop.clone();
    let sampling = thread::spawn(move || {
        while !stopped.load(Ordering::SeqCst) {
            if channel
                .send(FrameKind::Input, &sender.seal(&held()).unwrap())
                .is_err()
            {
                break;
            }
            thread::sleep(Duration::from_millis(30));
        }
        channel
    });
    let offer = host.execute(PairingCommand::PairingOpen {}).unwrap();
    let fresh = phone_enroll(&offer);
    stop.store(true, Ordering::SeqCst);
    let mut channel = sampling.join().unwrap();
    assert_ne!(fresh["credentialEpoch"], old["credentialEpoch"]);
    assert_eq!(receiver.status()["reportHex"], hex(&NEUTRAL));
    assert_eq!(receiver.status()["active"], false);
    assert_eq!(
        receiver.status()["lastReleaseReason"],
        "native_input_released"
    );
    let _ = channel.send(
        FrameKind::Control,
        &serde_json::to_vec(
            &json!({"version":1,"command":"control-status","connectionId":receipt["connectionId"]}),
        )
        .unwrap(),
    );
    assert!(channel.receive().is_err());
}
#[test]
fn native_tls_source_release_is_acknowledged_and_a_peer_drop_retires_its_grant() {
    let mut receiver = Receiver::new();
    let _owner = receiver.maintain_owner();
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
    let started = Instant::now();
    let phase = |label| {
        eprintln!(
            "stale-grant phase={label} elapsedMs={}",
            started.elapsed().as_millis()
        )
    };
    let mut receiver = Receiver::new();
    phase("receiver-ready");
    let _owner = receiver.maintain_owner();
    receiver.activate();
    let (_host, value) = listen_host(&receiver);
    let credential = phone_enroll(&value);
    phase("enrolled");
    receiver.command(json!({"command":"renew","generation":"1","sessionId":"service-owner"}));
    let (mut channel, receipt) = phone_auth(&value, &credential);
    phase("current-authenticated");
    let (mut sender, _) = phone_grant(&mut channel, &receipt);
    phase("current-granted");
    phone_held(&mut channel, &receipt, &mut sender);
    phase("current-held-acknowledged");
    // Maintain real native full-state input while a different TLS peer proves
    // rejection. Time spent handshaking that peer must not stand in for TTL loss.
    let stop = Arc::new(AtomicBool::new(false));
    let stopped = stop.clone();
    // Bound this fixture to one input/status round trip. Concurrent authorization
    // work can otherwise queue samples ahead of the status barrier and make this
    // generation-fencing scenario depend on unchecked producer throughput.
    let sampling_receipt = receipt.clone();
    let (sample_ready, first_sample) = mpsc::sync_channel(1);
    let sampling = thread::spawn(move || {
        let mut ready = Some(sample_ready);
        #[cfg(debug_assertions)]
        let mut previous = Instant::now();
        while !stopped.load(Ordering::SeqCst) {
            #[cfg(debug_assertions)]
            thumble_rewrite_receiver::input_io_diagnostics::record(
                thumble_rewrite_receiver::input_io_diagnostics::Metric::SampleGap,
                previous.elapsed(),
            );
            #[cfg(debug_assertions)]
            {
                previous = Instant::now();
            }
            #[cfg(debug_assertions)]
            let cycle = thumble_rewrite_receiver::input_io_diagnostics::Span::start(
                thumble_rewrite_receiver::input_io_diagnostics::Metric::SampleCycle,
            );
            let result = try_phone_held(&mut channel, &sampling_receipt, &mut sender);
            // Record the failed IO duration before panic hooks/backtraces can
            // add unrelated stderr time to an active sample span.
            #[cfg(debug_assertions)]
            drop(cycle);
            #[cfg(debug_assertions)]
            if let Err(error) = &result {
                thumble_rewrite_receiver::input_io_diagnostics::terminal("sample", 0, error);
            }
            result?;
            if let Some(ready) = ready.take() {
                ready.send(()).unwrap();
            }
            thread::sleep(Duration::from_millis(30));
        }
        Ok::<_, &'static str>((channel, sender))
    });
    first_sample.recv_timeout(Duration::from_secs(2)).unwrap();
    phase("sampling-first-native-ack");
    let (mut stale, stale_receipt) = phone_auth(&value, &credential);
    phase("stale-authenticated");
    control_send(
        &mut stale,
        json!({"version":1,"command":"input-grant","connectionId":stale_receipt["connectionId"],"generation":"1","revision":"2"}),
    );
    assert!(stale.receive().is_err());
    phase("stale-rejected");
    #[cfg(debug_assertions)]
    eprintln!(
        "[DEBUG-native-io] {}",
        thumble_rewrite_receiver::input_io_diagnostics::snapshot()
    );
    let observed = receiver.status();
    assert_ne!(observed["reportHex"], hex(&NEUTRAL), "{observed}");
    stop.store(true, Ordering::SeqCst);
    let (mut channel, mut sender) = sampling.join().unwrap().unwrap();
    phase("sampling-joined");
    // Drain all old-generation samples before explicitly replacing configuration.
    control_send(
        &mut channel,
        json!({"version":1,"command":"control-status","connectionId":receipt["connectionId"]}),
    );
    assert_eq!(control_receive(&mut channel)["command"], "control-status");
    phase("sampling-drained");
    assert_eq!(receiver.command(json!({"command":"activate","generation":"2","revision":"2","profileId":"profile-b","sessionId":"service-owner","leaseMs":750,"inputTtlMs":350}))["ok"],true);
    channel
        .send(FrameKind::Input, &sender.seal(&held()).unwrap())
        .unwrap();
    assert!(channel.receive().is_err());
    phase("old-generation-rejected");
    let status = receiver.status();
    assert_eq!(status["active"], true);
    assert_eq!(status["generation"], "2");
    assert_eq!(status["reportHex"], hex(&NEUTRAL));
    let (mut fresh, fresh_receipt) = phone_auth(&value, &credential);
    phase("fresh-authenticated");
    let (mut sender, _) = phone_grant(&mut fresh, &fresh_receipt);
    phone_held(&mut fresh, &fresh_receipt, &mut sender);
    phase("fresh-held-acknowledged");
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
}

#[test]
fn managed_configuration_owner_survives_slow_pairing_before_native_input() {
    let mut receiver = Receiver::new();
    let _owner = receiver.maintain_owner();
    receiver.activate();
    let (_host, value) = listen_host(&receiver);
    let credential = phone_enroll(&value);
    thread::sleep(Duration::from_millis(900)); // Exceeds the unchanged 750ms owner lease.
    let (mut channel, receipt) = phone_auth(&value, &credential);
    let (mut sender, _) = phone_grant(&mut channel, &receipt);
    phone_held(&mut channel, &receipt, &mut sender);
    assert_ne!(receiver.status()["reportHex"], hex(&NEUTRAL));
    channel.close();
    receiver.wait_neutral();
    assert_eq!(
        receiver.status()["lastReleaseReason"],
        "native_input_released"
    );
}

fn datagram_auth(value: &Value, credential: &Value) -> (ControlChannel, Value) {
    let mut channel = control_connect(value);
    control_hello(&mut channel, 5);
    control_send(
        &mut channel,
        json!({"version":1,"command":"authenticate","authorityInstanceId":"broker-authority","phoneId":"phone-a","credentialEpoch":credential["credentialEpoch"],"credential":credential["credential"]}),
    );
    let receipt = control_receive(&mut channel);
    assert_eq!(receipt["command"], "authenticated");
    (channel, receipt)
}
fn datagram_grant(
    channel: &mut ControlChannel,
    receipt: &Value,
    generation: &str,
    revision: &str,
) -> (PacketSender, Value, std::net::UdpSocket) {
    control_send(
        channel,
        json!({"version":1,"command":"input-grant","connectionId":receipt["connectionId"],"generation":generation,"revision":revision}),
    );
    let grant = control_receive(channel);
    assert_eq!(grant["transport"], "udp+tls");
    let port = u16::try_from(grant["udpPort"].as_u64().unwrap()).unwrap();
    assert!(port > 0);
    let sender = PacketSender::new(
        PacketGrant::new(
            &decode_hex(&grant["key"]),
            decode_hex(&grant["sessionId"]),
            decode_hex(&grant["noncePrefix"]),
            generation.parse().unwrap(),
        )
        .unwrap(),
        PACKET_LIMIT,
    )
    .unwrap();
    let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    socket.connect((Ipv4Addr::LOCALHOST, port)).unwrap();
    (sender, grant, socket)
}
fn datagram_status(channel: &mut ControlChannel, receipt: &Value, grant: &Value) -> Value {
    control_send(
        channel,
        json!({"version":1,"command":"input-status","connectionId":receipt["connectionId"],"sessionId":grant["sessionId"]}),
    );
    let status = control_receive(channel);
    assert_eq!(status["command"], "input-status");
    assert_eq!(status["connectionId"], receipt["connectionId"]);
    status
}
fn datagram_wait(
    channel: &mut ControlChannel,
    receipt: &Value,
    grant: &Value,
    sequence: u64,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(1);
    let sequence = sequence.to_string();
    loop {
        let status = datagram_status(channel, receipt, grant);
        if status["lastAcceptedSequence"].as_str() == Some(sequence.as_str()) {
            return status;
        }
        assert!(
            Instant::now() < deadline,
            "UDP never reached receiver: {status}"
        );
        thread::sleep(Duration::from_millis(5));
    }
}
fn datagram_deliver(
    channel: &mut ControlChannel,
    receipt: &Value,
    grant: &Value,
    socket: &std::net::UdpSocket,
    packet: &[u8],
) -> Value {
    let expected = u64::from_le_bytes(packet[32..40].try_into().unwrap()).to_string();
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        // UDP can drop under contention. Resending identical ciphertext never reuses a nonce for different plaintext.
        socket.send(packet).unwrap();
        thread::sleep(Duration::from_millis(15));
        let status = datagram_status(channel, receipt, grant);
        if status["lastAcceptedSequence"].as_str() == Some(expected.as_str()) {
            return status;
        }
        assert!(Instant::now() < deadline, "UDP not admitted: {status}");
    }
}
#[test]
fn udp_and_tls_share_one_authenticated_counter_and_reject_malformed_datagrams_without_losing_fallback(
) {
    let mut receiver = Receiver::new();
    let _owner = receiver.maintain_owner();
    // This scenario probes transport ordering through many reliable round trips.
    // The separate replay/expiry test retains 350ms and does not renew input.
    receiver.activate_timing(1750, 1500);
    let (_host, value) = listen_host(&receiver);
    let credential = phone_enroll(&value);
    let (mut channel, receipt) = datagram_auth(&value, &credential);
    let (mut sender, grant, socket) = datagram_grant(&mut channel, &receipt, "1", "1");
    let first = sender.seal(&held()).unwrap();
    assert_eq!(
        datagram_deliver(&mut channel, &receipt, &grant, &socket, &first)["active"],
        true
    );
    assert_eq!(receiver.status()["reportHex"], hex(&held().report()));
    let neutral: GamepadState=serde_json::from_value(json!({"buttons":[],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":0,"rightTrigger":0})).unwrap();
    let reliable = sender.seal(&neutral).unwrap();
    channel.send(FrameKind::Input, &reliable).unwrap();
    assert_eq!(
        datagram_wait(&mut channel, &receipt, &grant, 1)["active"],
        true
    );
    assert_eq!(receiver.status()["reportHex"], hex(&NEUTRAL));
    socket.send(&first).unwrap();
    let mut invalid = sender.seal(&held()).unwrap();
    invalid[107] ^= 1;
    socket.send(&invalid).unwrap();
    thread::sleep(Duration::from_millis(30));
    assert_eq!(
        datagram_status(&mut channel, &receipt, &grant)["lastAcceptedSequence"],
        "1"
    );
    assert_eq!(receiver.status()["reportHex"], hex(&NEUTRAL));
    datagram_deliver(
        &mut channel,
        &receipt,
        &grant,
        &socket,
        &sender.seal(&held()).unwrap(),
    );
    channel.send(FrameKind::Input, &reliable).unwrap(); // Late TLS must not retire newer UDP state.
    assert_eq!(
        datagram_status(&mut channel, &receipt, &grant)["lastAcceptedSequence"],
        "3"
    );
    assert_eq!(receiver.status()["reportHex"], hex(&held().report()));
    let mut oversized = sender.seal(&neutral).unwrap();
    oversized.push(0);
    socket.send(&oversized).unwrap();
    let mut unknown = first.clone();
    unknown[8] ^= 1;
    socket.send(&unknown).unwrap();
    thread::sleep(Duration::from_millis(30));
    assert_eq!(
        datagram_status(&mut channel, &receipt, &grant)["lastAcceptedSequence"],
        "3"
    );
    channel
        .send(FrameKind::Input, &sender.seal(&neutral).unwrap())
        .unwrap();
    datagram_wait(&mut channel, &receipt, &grant, 5);
    assert_eq!(receiver.status()["reportHex"], hex(&NEUTRAL));
    control_send(
        &mut channel,
        json!({"version":1,"command":"input-release","connectionId":receipt["connectionId"],"sessionId":grant["sessionId"]}),
    );
    assert_eq!(control_receive(&mut channel)["command"], "input-released");
    assert_eq!(
        receiver.status()["lastReleaseReason"],
        "native_input_released"
    );
}
#[test]
fn udp_replays_cannot_renew_input_ttl_or_resurrect_an_expired_source_with_a_live_owner() {
    let mut receiver = Receiver::new();
    let _owner = receiver.maintain_owner();
    receiver.activate();
    let (_host, value) = listen_host(&receiver);
    let credential = phone_enroll(&value);
    let (mut channel, receipt) = datagram_auth(&value, &credential);
    let (mut sender, grant, socket) = datagram_grant(&mut channel, &receipt, "1", "1");
    let packet = sender.seal(&held()).unwrap();
    datagram_deliver(&mut channel, &receipt, &grant, &socket, &packet);
    let deadline = Instant::now() + Duration::from_millis(430);
    while Instant::now() < deadline {
        socket.send(&packet).unwrap();
        thread::sleep(Duration::from_millis(20));
    }
    let status = receiver.status();
    assert_eq!(status["active"], false);
    assert_eq!(status["lastReleaseReason"], "input_expired");
    socket.send(&sender.seal(&held()).unwrap()).unwrap();
    thread::sleep(Duration::from_millis(30));
    assert_eq!(
        datagram_status(&mut channel, &receipt, &grant)["active"],
        false
    );
    assert_eq!(receiver.status()["reportHex"], hex(&NEUTRAL));
}
#[test]
fn udp_revocation_and_listener_stop_acknowledge_native_neutral_and_old_keys_cannot_touch_a_new_epoch(
) {
    let mut receiver = Receiver::new();
    let _owner = receiver.maintain_owner();
    receiver.activate_timing(1750, 1500);
    let (mut host, value) = listen_host(&receiver);
    let old = phone_enroll(&value);
    let (mut channel, receipt) = datagram_auth(&value, &old);
    let (mut sender, grant, socket) = datagram_grant(&mut channel, &receipt, "1", "1");
    datagram_deliver(
        &mut channel,
        &receipt,
        &grant,
        &socket,
        &sender.seal(&held()).unwrap(),
    );
    host.execute(PairingCommand::PairingRevoke {
        phone_id: "phone-a".into(),
    })
    .unwrap();
    assert_eq!(receiver.status()["active"], false);
    assert_eq!(
        receiver.status()["lastReleaseReason"],
        "native_input_released"
    );
    socket.send(&sender.seal(&held()).unwrap()).unwrap();
    let offer = host.execute(PairingCommand::PairingOpen {}).unwrap();
    let fresh = phone_enroll(&offer);
    assert_ne!(old["credentialEpoch"], fresh["credentialEpoch"]);
    assert_eq!(receiver.command(json!({"command":"activate","generation":"2","revision":"2","profileId":"new","sessionId":"service-owner","leaseMs":1750,"inputTtlMs":1500}))["ok"],true);
    let (mut channel, receipt) = datagram_auth(&offer, &fresh);
    let (mut new_sender, grant, new_socket) = datagram_grant(&mut channel, &receipt, "2", "2");
    datagram_deliver(
        &mut channel,
        &receipt,
        &grant,
        &new_socket,
        &new_sender.seal(&held()).unwrap(),
    );
    socket.send(&sender.seal(&held()).unwrap()).unwrap();
    thread::sleep(Duration::from_millis(20));
    assert_eq!(receiver.status()["reportHex"], hex(&held().report()));
    host.execute(PairingCommand::PairingStopListening {})
        .unwrap();
    assert_eq!(receiver.status()["active"], false);
    assert_eq!(
        receiver.status()["lastReleaseReason"],
        "native_input_released"
    );
    let port = grant["udpPort"].as_u64().unwrap() as u16;
    let _rebound = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, port)).unwrap();
}

#[test]
fn live_native_key_rotation_preserves_held_state_and_stale_cleanup_cannot_retire_the_successor() {
    let mut receiver = Receiver::new();
    let _owner = receiver.maintain_owner();
    receiver.activate_timing(1750, 1500);
    let mut client = Client::connect(&receiver.root).unwrap();
    let grant = client.grant([8; 16], 1, 1, 5000).unwrap();
    let previous = grant.binding();
    let mut old = grant.into_sender().unwrap();
    client
        .packet(previous, &old.seal(&held()).unwrap())
        .unwrap();
    let initial = receiver.status();
    assert_eq!(initial["reportHex"], hex(&held().report()));
    let recording = receiver.root.join("recording.jsonl");
    let before = fs::metadata(&recording).unwrap().len() as usize;
    let grant = client.rotate(previous, 1, 1, 5000).unwrap();
    let next = grant.binding();
    assert!(previous != next);
    assert_eq!(receiver.status()["reportHex"], initial["reportHex"]);
    client
        .packet(previous, &old.seal(&held()).unwrap())
        .unwrap();
    let mut sender = grant.into_sender().unwrap();
    client.packet(next, &sender.seal(&held()).unwrap()).unwrap();
    assert_eq!(receiver.status()["sequence"], "0");
    client.release(previous).unwrap();
    assert!(client
        .packet(previous, &old.seal(&held()).unwrap())
        .is_err());
    client.packet(next, &sender.seal(&held()).unwrap()).unwrap();
    let current = receiver.status();
    assert_eq!(current["generation"], "1");
    assert_eq!(current["revision"], "1");
    assert_eq!(current["sequence"], "1");
    assert_eq!(current["reportHex"], initial["reportHex"]);
    assert_eq!(current["inputEnabled"], false);
    for line in fs::read_to_string(&recording).unwrap()[before..].lines() {
        let record: Value = serde_json::from_str(line).unwrap();
        assert_eq!(
            record["reportHex"], initial["reportHex"],
            "rotation emitted a release pulse"
        );
    }
    drop(client);
    receiver.wait_neutral();
    assert_eq!(
        receiver.status()["lastReleaseReason"],
        "native_input_released"
    );
}

#[test]
fn cancelling_staged_native_material_preserves_current_input_and_disconnect_retires_both() {
    let mut receiver = Receiver::new();
    let _owner = receiver.maintain_owner();
    receiver.activate_timing(1750, 1500);
    let mut client = Client::connect(&receiver.root).unwrap();
    let grant = client.grant([8; 16], 1, 1, 5000).unwrap();
    let previous = grant.binding();
    let mut old = grant.into_sender().unwrap();
    client
        .packet(previous, &old.seal(&held()).unwrap())
        .unwrap();
    assert!(client.rotate(previous, 2, 1, 5000).is_err());
    let grant = client.rotate(previous, 1, 1, 5000).unwrap();
    let staged = grant.binding();
    let mut cancelled = grant.into_sender().unwrap();
    client.release(staged).unwrap();
    assert!(client
        .packet(staged, &cancelled.seal(&held()).unwrap())
        .is_err());
    client
        .packet(previous, &old.seal(&held()).unwrap())
        .unwrap();
    assert_eq!(receiver.status()["reportHex"], hex(&held().report()));
    let _pending = client.rotate(previous, 1, 1, 5000).unwrap();
    assert_eq!(receiver.status()["reportHex"], hex(&held().report()));
    drop(client);
    receiver.wait_neutral();
    assert_eq!(
        receiver.status()["lastReleaseReason"],
        "native_input_released"
    );
}

#[test]
fn saved_binding_private_status_preserves_snapshot_shape_and_clears_after_release() {
    let mut receiver = Receiver::new();
    let status = receiver.command(json!({"command":"savedBindingStatus"}));
    assert_eq!(status["ok"], true);
    assert_eq!(status["savedBinding"], Value::Null);
    let heartbeat = receiver.maintain_owner();
    let activated=receiver.command(json!({"command":"activateSaved","generation":"1","revision":"1","profileId":"11111111-1111-1111-1111-111111111111","sessionId":"service-owner","leaseMs":750,"inputTtlMs":350,"configurationRevision":"9","sourceHash":"a".repeat(64)}));
    assert_eq!(activated["ok"], true, "{activated}");
    assert!(activated.get("savedBinding").is_none());
    let status = receiver.command(json!({"command":"savedBindingStatus"}));
    assert_eq!(status["savedBinding"]["configurationRevision"], "9");
    assert_eq!(status["savedBinding"]["sourceHash"], "a".repeat(64));
    assert_eq!(status["savedBinding"]["generation"], "1");
    assert_eq!(status["savedBinding"]["revision"], "1");
    assert_eq!(status["snapshot"]["backend"], "recording");
    assert_eq!(status["snapshot"]["inputEnabled"], false);
    assert!(status["snapshot"].get("savedBinding").is_none());
    let ordinary = receiver.status();
    assert!(ordinary.get("savedBinding").is_none());
    receiver.command(json!({"command":"release"}));
    let status = receiver.command(json!({"command":"savedBindingStatus"}));
    assert_eq!(status["savedBinding"], Value::Null);
    assert_eq!(status["snapshot"]["active"], false);
    drop(heartbeat);
}
