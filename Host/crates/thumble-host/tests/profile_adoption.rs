//! Real packaged native validation, receiver persistence and public CLI adoption.
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use thumble_host::control::{send_request, ControlRequest, HostStatus};
use thumble_host::paths::HostPaths;
use thumble_protocol::{
    AdoptionConflictPolicy, AdoptionError, AdoptionMetadata, AdoptionStatus, ControllerCapability,
    ControllerMessage, ControllerMessageType as Kind, ControllerWireCodec, ADOPTION_CHUNK_BYTES,
};
use tokio::net::TcpStream;
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};
use uuid::Uuid;

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

#[test]
#[ignore = "requires THUMBLE_TEST_ARTIFACT_RUNTIME_BIN with native compatibility bridge"]
fn native_legacy_inline_outputs_and_integral_float_metadata_round_trip_without_changes() {
    let bin = PathBuf::from(std::env::var_os("THUMBLE_TEST_ARTIFACT_RUNTIME_BIN").unwrap());
    let mut state = thumble_core::PersistentState::minimal("legacy-fixture").unwrap();
    state.profiles[0]["futureMetadata"] = json!({"scale":1.0,"count":2,"nested":[0.0,3.0]});
    let element = &mut state.profiles[0]["customization"]["elements"][0];
    element["output"] = json!({"gamepadButtons":[],"keyboard":{"keyCode":12,"modifiers":1,"sequence":[{"keyCode":12,"modifiers":1},{"keyCode":13,"modifiers":0}]}});
    element["defaultOutput"] = element["output"].clone();
    let mut second = state.profiles[0].clone();
    second["id"] = json!("00000000-0000-0000-0000-000000000202");
    second["futureMetadata"]["scale"] = json!(1);
    state.profiles.push(second);
    let doc = thumble_core::ConfigurationDocument::from_state(&state).unwrap();
    let bridge =
        thumble_host::bridge::ConfigurationBridge::at_path(bin.join("thumble-bridge")).unwrap();
    let operation = thumble_host::draft_operation::ConfigurationOperation::ProfileSelect {
        profile_id: state.active_profile_id,
    };
    let (response, _) = bridge.apply(&doc, &operation, 1234).unwrap();
    assert_eq!(response.profiles, doc.profiles);
    let reorder = thumble_host::draft_operation::ConfigurationOperation::ProfileMove {
        profile_id: "00000000-0000-0000-0000-000000000202".into(),
        index: 0,
    };
    let (reordered, _) = bridge.apply(&doc, &reorder, 1234).unwrap();
    assert_eq!(
        reordered.profiles,
        vec![doc.profiles[1].clone(), doc.profiles[0].clone()]
    );
}
struct Receiver(Child);
impl Drop for Receiver {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn spawn(bin: &Path, paths: &HostPaths, fixture_home: &Path) -> Receiver {
    Receiver(
        Command::new(bin.join("thumble-host"))
            .args([
                "run",
                "--port",
                "0",
                "--no-input",
                "--no-bonjour",
                "--allow-config-write",
            ])
            .env("HOME", fixture_home)
            .env("THUMBLE_HOST_STATE_DIR", &paths.state_dir)
            .env("THUMBLE_HOST_CONTROL_SOCKET", &paths.control_socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(paths.state_dir.join("receiver.stderr")).unwrap())
            .spawn()
            .unwrap(),
    )
}
async fn status(paths: &HostPaths) -> HostStatus {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if let Ok(r) = send_request(&paths.control_socket, &ControlRequest::Status).await {
                if let Some(s) = r.status {
                    return s;
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "Private receiver did not start: {}",
            std::fs::read_to_string(paths.state_dir.join("receiver.stderr")).unwrap_or_default()
        )
    })
}
async fn send(ws: &mut Ws, m: ControllerMessage) {
    ws.send(Message::Binary(
        ControllerWireCodec::encode(&m).unwrap().into(),
    ))
    .await
    .unwrap();
}
async fn receive(ws: &mut Ws, kind: Kind) -> ControllerMessage {
    tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            match ws.next().await.unwrap().unwrap() {
                Message::Binary(b) => {
                    let m = ControllerWireCodec::decode(&b).unwrap();
                    if m.message_type == kind {
                        return m;
                    }
                }
                Message::Text(t) => {
                    let m = ControllerWireCodec::decode(t.as_bytes()).unwrap();
                    if m.message_type == kind {
                        return m;
                    }
                }
                Message::Ping(b) => ws.send(Message::Pong(b)).await.unwrap(),
                _ => (),
            }
        }
    })
    .await
    .unwrap()
}
async fn pair(paths: &HostPaths, trust: Option<String>) -> (Ws, ControllerMessage) {
    let s = status(paths).await;
    let (mut ws, _) = connect_async(format!("ws://127.0.0.1:{}", s.port))
        .await
        .unwrap();
    let mut hello = ControllerMessage::new(Kind::Hello, 0);
    hello.server_id = Some(s.server_id);
    if let Some(trust) = trust {
        hello.auth_token = Some(trust);
    } else {
        hello.pairing_code = Some(s.pairing_code);
    }
    send(&mut ws, hello).await;
    let paired = receive(&mut ws, Kind::PairingAccepted).await;
    assert!(paired
        .capabilities
        .as_ref()
        .unwrap()
        .contains(&ControllerCapability::ProfileArtifactAdoptionV1));
    (ws, paired)
}
fn metadata(bytes: &[u8], server: &str) -> AdoptionMetadata {
    let root: Value = serde_json::from_slice(bytes).unwrap();
    AdoptionMetadata {
        operation_id: Uuid::new_v4(),
        record_id: Uuid::new_v4(),
        intended_server_id: server.into(),
        content_hash: root["contentHash"]["value"].as_str().unwrap().into(),
        raw_sha256: format!("{:x}", Sha256::digest(bytes)),
        byte_count: bytes.len(),
        chunk_count: bytes.len().div_ceil(ADOPTION_CHUNK_BYTES),
        conflict_policy: AdoptionConflictPolicy::AppendAsCopies,
    }
}
async fn begin(ws: &mut Ws, m: &AdoptionMetadata) -> thumble_protocol::AdoptionResult {
    let mut msg = ControllerMessage::new(Kind::ProfileArtifactAdoptionBegin, 0);
    msg.profile_artifact_adoption_metadata = Some(m.clone());
    send(ws, msg).await;
    receive(ws, Kind::ProfileArtifactAdoptionResult)
        .await
        .profile_artifact_adoption_result
        .unwrap()
}
async fn chunks(ws: &mut Ws, m: &AdoptionMetadata, bytes: &[u8]) {
    for (i, chunk) in bytes.chunks(ADOPTION_CHUNK_BYTES).enumerate() {
        let mut msg = ControllerMessage::new(Kind::ProfileArtifactAdoptionChunk, 0);
        msg.profile_artifact_adoption_operation_id = Some(m.operation_id);
        msg.profile_artifact_adoption_chunk_index = Some(i as i64);
        msg.profile_artifact_adoption_chunk_data = Some(STANDARD.encode(chunk));
        send(ws, msg).await;
    }
}
async fn operation(ws: &mut Ws, kind: Kind, m: &AdoptionMetadata) {
    let mut msg = ControllerMessage::new(kind, 0);
    msg.profile_artifact_adoption_operation_id = Some(m.operation_id);
    send(ws, msg).await;
}
fn saved(paths: &HostPaths) -> Value {
    serde_json::from_slice(&std::fs::read(&paths.state_file).unwrap()).unwrap()
}
fn cli(bin: &Path, paths: &HostPaths, fixture_home: &Path, args: &[&str], success: bool) -> Value {
    let output = Command::new(bin.join("thumble"))
        .arg("shared-build")
        .env("HOME", fixture_home)
        .args(args)
        .env("THUMBLE_HOST_STATE_DIR", &paths.state_dir)
        .env("THUMBLE_HOST_CONTROL_SOCKET", &paths.control_socket)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(
        output.status.success(),
        success,
        "CLI {:?}: {}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires THUMBLE_TEST_ARTIFACT_RUNTIME_BIN with current native bridge and public Swift CLI"]
async fn native_adoption_is_atomic_replayed_after_restart_and_shared_with_the_public_cli() {
    let bin = PathBuf::from(std::env::var_os("THUMBLE_TEST_ARTIFACT_RUNTIME_BIN").unwrap());
    // Use a private child of the trusted account home: /tmp ancestry is
    // intentionally rejected by the public runtime bridge.
    let directory = tempfile::Builder::new()
        .prefix(".th-")
        .tempdir_in(std::env::var_os("HOME").expect("account home required"))
        .unwrap();
    // The trusted Swift runtime bridge intentionally forwards HOME only.
    // A canonical fixture root lets the public CLI discover this receiver
    // without inheriting custom socket overrides or touching the real user home.
    let fixture_home = directory.path().to_path_buf();
    let state_dir = fixture_home.join("Library/Application Support/ThumbleHost");
    let paths = HostPaths::new(state_dir.clone(), state_dir.join("control.sock"));
    paths.ensure_state_dir().unwrap();
    let bytes = include_bytes!("../../../fixtures/profile-artifact/v1.json");
    let mut receiver = spawn(&bin, &paths, &fixture_home);
    let (mut ws, paired) = pair(&paths, None).await;
    let trust = paired.auth_token.unwrap();
    let initial = saved(&paths);
    let server = status(&paths).await.server_id;
    let m = metadata(bytes, &server);
    assert_eq!(begin(&mut ws, &m).await.status, AdoptionStatus::Accepted);
    chunks(&mut ws, &m, bytes).await;
    operation(&mut ws, Kind::ProfileArtifactAdoptionCommit, &m).await;
    let result = receive(&mut ws, Kind::ProfileArtifactAdoptionResult)
        .await
        .profile_artifact_adoption_result
        .unwrap();
    assert_eq!(result.status, AdoptionStatus::Succeeded);
    assert!(result.validates(&m));
    let committed = saved(&paths);
    assert_eq!(committed["profiles"].as_array().unwrap().len(), 2);
    assert_eq!(
        committed["profileArtifactAdoptions"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    assert_eq!(committed["defaultProfileID"], initial["defaultProfileID"]);
    assert_eq!(committed["trustedClients"], initial["trustedClients"]);
    assert_eq!(
        Uuid::parse_str(committed["activeProfileID"].as_str().unwrap()).unwrap(),
        result.destination_profile_ids[0]
    );
    assert_eq!(
        committed["profiles"][1]["futureProfileField"]["nested"],
        json!([true, null, 3.5])
    );
    let replay = begin(&mut ws, &m).await;
    assert_eq!(replay.status, AdoptionStatus::Replayed);
    assert_eq!(
        replay.destination_profile_ids,
        result.destination_profile_ids
    );
    assert_eq!(saved(&paths), committed);

    // Premature commits and bad chunk ordering cannot write a profile or receipt.
    let partial = metadata(bytes, &server);
    assert_eq!(
        begin(&mut ws, &partial).await.status,
        AdoptionStatus::Accepted
    );
    operation(&mut ws, Kind::ProfileArtifactAdoptionCommit, &partial).await;
    assert_eq!(
        receive(&mut ws, Kind::ProfileArtifactAdoptionResult)
            .await
            .profile_artifact_adoption_result
            .unwrap()
            .error_code,
        Some(AdoptionError::OutOfOrder)
    );
    let mut invalid_chunk = ControllerMessage::new(Kind::ProfileArtifactAdoptionChunk, 0);
    invalid_chunk.profile_artifact_adoption_operation_id = Some(partial.operation_id);
    invalid_chunk.profile_artifact_adoption_chunk_index = Some(1);
    invalid_chunk.profile_artifact_adoption_chunk_data = Some(STANDARD.encode(bytes));
    send(&mut ws, invalid_chunk).await;
    assert_eq!(
        receive(&mut ws, Kind::ProfileArtifactAdoptionResult)
            .await
            .profile_artifact_adoption_result
            .unwrap()
            .error_code,
        Some(AdoptionError::OutOfOrder)
    );
    operation(&mut ws, Kind::ProfileArtifactAdoptionCancel, &partial).await;
    assert_eq!(
        receive(&mut ws, Kind::ProfileArtifactAdoptionResult)
            .await
            .profile_artifact_adoption_result
            .unwrap()
            .error_code,
        Some(AdoptionError::Disconnected)
    );
    assert_eq!(saved(&paths), committed);
    let mut conflicting = m.clone();
    conflicting.raw_sha256 = "c".repeat(64);
    assert_eq!(
        begin(&mut ws, &conflicting).await.error_code,
        Some(AdoptionError::OperationConflict)
    );
    assert_eq!(saved(&paths), committed);
    let mut wrong = metadata(bytes, "other-server");
    assert_eq!(
        begin(&mut ws, &wrong).await.error_code,
        Some(AdoptionError::WrongServer)
    );
    wrong.intended_server_id = server.clone();
    assert_eq!(
        begin(&mut ws, &wrong).await.status,
        AdoptionStatus::Accepted
    );
    chunks(&mut ws, &wrong, bytes).await;
    operation(&mut ws, Kind::ProfileArtifactAdoptionCancel, &wrong).await;
    assert_eq!(
        receive(&mut ws, Kind::ProfileArtifactAdoptionResult)
            .await
            .profile_artifact_adoption_result
            .unwrap()
            .error_code,
        Some(AdoptionError::Disconnected)
    );
    assert_eq!(saved(&paths), committed);

    // A rejected filesystem write must never publish success or a replay receipt.
    assert_eq!(
        begin(&mut ws, &wrong).await.status,
        AdoptionStatus::Accepted
    );
    chunks(&mut ws, &wrong, bytes).await;
    let previous = std::fs::read(&paths.state_file).unwrap();
    std::fs::remove_file(&paths.state_file).unwrap();
    std::fs::create_dir(&paths.state_file).unwrap();
    operation(&mut ws, Kind::ProfileArtifactAdoptionCommit, &wrong).await;
    assert_eq!(
        receive(&mut ws, Kind::ProfileArtifactAdoptionResult)
            .await
            .profile_artifact_adoption_result
            .unwrap()
            .error_code,
        Some(AdoptionError::ImportFailed)
    );
    assert_eq!(
        send_request(&paths.control_socket, &ControlRequest::ListProfiles)
            .await
            .unwrap()
            .profiles
            .unwrap()
            .len(),
        2
    );
    std::fs::remove_dir(&paths.state_file).unwrap();
    std::fs::write(&paths.state_file, previous).unwrap();
    std::fs::set_permissions(&paths.state_file, std::fs::Permissions::from_mode(0o600)).unwrap();

    ws.close(None).await.unwrap();
    let _ = receiver.0.kill();
    let _ = receiver.0.wait();
    drop(receiver);
    receiver = spawn(&bin, &paths, &fixture_home);
    let (mut ws, _) = pair(&paths, Some(trust)).await;
    assert_eq!(begin(&mut ws, &m).await.status, AdoptionStatus::Replayed);
    let reconnected = saved(&paths);
    for key in [
        "profiles",
        "activeProfileID",
        "defaultProfileID",
        "profileArtifactAdoptions",
        "configurationRevision",
    ] {
        assert_eq!(reconnected[key], committed[key]);
    }
    let artifact = directory.path().join("kept.json");
    std::fs::write(&artifact, bytes).unwrap();
    let op = m.operation_id.to_string();
    let record = m.record_id.to_string();
    let replay = cli(
        &bin,
        &paths,
        &fixture_home,
        &[
            "adopt",
            artifact.to_str().unwrap(),
            "--operation-id",
            &op,
            "--record-id",
            &record,
            "--json",
        ],
        true,
    );
    assert_eq!(replay["status"], "replayed");
    assert_eq!(saved(&paths), reconnected);
    assert_eq!(
        cli(
            &bin,
            &paths,
            &fixture_home,
            &["status", &op, "--json"],
            true
        )["status"],
        "replayed"
    );
    let new_op = Uuid::new_v4().to_string();
    assert_eq!(
        cli(
            &bin,
            &paths,
            &fixture_home,
            &[
                "adopt",
                artifact.to_str().unwrap(),
                "--operation-id",
                &new_op,
                "--json"
            ],
            true
        )["status"],
        "succeeded"
    );
    let after = saved(&paths);
    assert_eq!(after["profiles"].as_array().unwrap().len(), 3);
    assert_eq!(
        cli(
            &bin,
            &paths,
            &fixture_home,
            &[
                "adopt",
                artifact.to_str().unwrap(),
                "--operation-id",
                &new_op,
                "--json"
            ],
            true
        )["status"],
        "replayed"
    );
    assert_eq!(saved(&paths), after);
    let cancel = metadata(bytes, &server);
    assert_eq!(
        begin(&mut ws, &cancel).await.status,
        AdoptionStatus::Accepted
    );
    let cancel_id = cancel.operation_id.to_string();
    assert_eq!(
        cli(
            &bin,
            &paths,
            &fixture_home,
            &["status", &cancel_id, "--json"],
            true
        )["status"],
        "accepted"
    );
    assert_eq!(
        cli(
            &bin,
            &paths,
            &fixture_home,
            &["cancel", &cancel_id, "--json"],
            false
        )["errorCode"],
        "disconnected"
    );
    assert_eq!(saved(&paths), after);
    ws.close(None).await.unwrap();
    drop(receiver);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires THUMBLE_TEST_ARTIFACT_RUNTIME_BIN with current native bridge and public Swift CLI"]
async fn cancellation_during_native_validation_keeps_authority_unchanged_and_cli_responsive() {
    let source = PathBuf::from(std::env::var_os("THUMBLE_TEST_ARTIFACT_RUNTIME_BIN").unwrap());
    // Use a private child of the trusted account home: /tmp ancestry is
    // intentionally rejected by the public runtime bridge.
    let directory = tempfile::Builder::new()
        .prefix(".th-")
        .tempdir_in(std::env::var_os("HOME").expect("account home required"))
        .unwrap();
    std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let bin = directory.path().join("bin");
    std::fs::create_dir(&bin).unwrap();
    for name in ["thumble-host", "thumble", "thumble-cli-bridge"] {
        std::fs::copy(source.join(name), bin.join(name)).unwrap();
    }
    let native = bin.join("native-artifact-bridge");
    std::fs::copy(source.join("thumble-bridge"), &native).unwrap();
    let marker = directory.path().join("validating");
    let wrapper = format!(
        "#!/usr/bin/python3\nimport json,subprocess,sys,time\ndata=sys.stdin.buffer.read(12*1024*1024+1)\nrequest=json.loads(data)\nif request.get('profileArtifactCommand')=='validate':\n open({},'w').close()\n time.sleep(3)\nresult=subprocess.run([{}],input=data,stdout=subprocess.PIPE)\nsys.stdout.buffer.write(result.stdout)\nsys.exit(result.returncode)\n",
        serde_json::to_string(marker.to_str().unwrap()).unwrap(),
        serde_json::to_string(native.to_str().unwrap()).unwrap()
    );
    let bridge = bin.join("thumble-bridge");
    std::fs::write(&bridge, wrapper).unwrap();
    std::fs::set_permissions(&bridge, std::fs::Permissions::from_mode(0o700)).unwrap();
    let fixture_home = directory.path().to_path_buf();
    let state_dir = fixture_home.join("Library/Application Support/ThumbleHost");
    let paths = HostPaths::new(state_dir.clone(), state_dir.join("control.sock"));
    paths.ensure_state_dir().unwrap();
    let receiver = spawn(&bin, &paths, &fixture_home);
    let (mut ws, _) = pair(&paths, None).await;
    let before = saved(&paths);
    let bytes = include_bytes!("../../../fixtures/profile-artifact/v1.json");
    let m = metadata(bytes, &status(&paths).await.server_id);
    assert_eq!(begin(&mut ws, &m).await.status, AdoptionStatus::Accepted);
    chunks(&mut ws, &m, bytes).await;
    operation(&mut ws, Kind::ProfileArtifactAdoptionCommit, &m).await;
    tokio::time::timeout(Duration::from_secs(5), async {
        while !marker.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    let op = m.operation_id.to_string();
    assert_eq!(
        send_request(
            &paths.control_socket,
            &ControlRequest::ProfileArtifactAdoptionStatus {
                operation_id: m.operation_id
            }
        )
        .await
        .unwrap()
        .profile_artifact_adoption
        .unwrap()
        .status,
        AdoptionStatus::Accepted
    );
    assert_eq!(
        cli(
            &bin,
            &paths,
            &fixture_home,
            &["cancel", &op, "--json"],
            false
        )["errorCode"],
        "disconnected"
    );
    // Both the immediate cancellation and the completing native worker report
    // cancellation; the worker cannot cross the authority boundary afterward.
    for _ in 0..2 {
        assert_eq!(
            receive(&mut ws, Kind::ProfileArtifactAdoptionResult)
                .await
                .profile_artifact_adoption_result
                .unwrap()
                .error_code,
            Some(AdoptionError::Disconnected)
        );
    }
    assert_eq!(saved(&paths), before);
    assert_eq!(status(&paths).await.output.held_key_count, 0);
    ws.close(None).await.unwrap();
    drop(receiver);
}
