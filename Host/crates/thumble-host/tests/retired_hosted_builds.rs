//! Retired upload endpoints reject without mutating profiles or legacy receipts.
use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use thumble_core::PersistentState;
use thumble_host::control::{send_request, ControlRequest};
use thumble_host::paths::HostPaths;
use thumble_host::runtime::{run_runtime, RuntimeOptions};
use thumble_protocol::{
    AdoptionConflictPolicy, AdoptionMetadata, AdoptionReceipt, AdoptionResult, AdoptionStatus,
    ControllerCapability, ControllerMessage, ControllerMessageType as Kind, ControllerWireCodec,
};
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};
use uuid::Uuid;

type Ws = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;
async fn send(ws: &mut Ws, message: ControllerMessage) {
    ws.send(Message::Binary(
        serde_json::to_vec(&message).unwrap().into(),
    ))
    .await
    .unwrap();
}
async fn receive(ws: &mut Ws, kind: Kind) -> ControllerMessage {
    tokio::time::timeout(Duration::from_secs(5), async {
        while let Some(frame) = ws.next().await {
            let frame = frame.unwrap();
            let bytes = match frame {
                Message::Binary(bytes) => bytes.to_vec(),
                Message::Text(text) => text.as_bytes().to_vec(),
                _ => continue,
            };
            let message = ControllerWireCodec::decode(&bytes).unwrap();
            if message.message_type == kind {
                return message;
            }
        }
        panic!("connection closed before expected reply")
    })
    .await
    .unwrap()
}
fn metadata() -> AdoptionMetadata {
    AdoptionMetadata {
        operation_id: Uuid::from_u128(901),
        record_id: Uuid::from_u128(902),
        intended_server_id: "retirement-fixture".into(),
        content_hash: "a".repeat(64),
        raw_sha256: "b".repeat(64),
        byte_count: 1,
        chunk_count: 1,
        conflict_policy: AdoptionConflictPolicy::AppendAsCopies,
    }
}
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn old_phone_and_socket_uploads_reject_while_pairing_and_profiles_remain_usable() {
    let directory = tempfile::tempdir().unwrap();
    let paths = HostPaths::new(
        directory.path().to_owned(),
        directory.path().join("control.sock"),
    );
    paths.ensure_state_dir().unwrap();
    let mut state = PersistentState::minimal("retirement-fixture").unwrap();
    let metadata = metadata();
    state.profile_artifact_adoptions.push(AdoptionReceipt {
        metadata: metadata.clone(),
        result: AdoptionResult::new(
            &metadata,
            &state.server_id,
            AdoptionStatus::Succeeded,
            None,
            vec![Uuid::parse_str(&state.active_profile_id).unwrap()],
        ),
        completed_at_milliseconds: 1,
    });
    thumble_host::storage::save_atomic(&paths.state_file, &state).unwrap();
    let runtime_paths = paths.clone();
    let runtime = tokio::spawn(async move {
        run_runtime(
            runtime_paths,
            RuntimeOptions {
                port: 0,
                bonjour: false,
                input: false,
                configuration_write: true,
            },
        )
        .await
    });
    let status = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            if let Ok(response) = send_request(&paths.control_socket, &ControlRequest::Status).await
            {
                if let Some(status) = response.status {
                    break status;
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    let (mut ws, _) = connect_async(format!("ws://127.0.0.1:{}", status.port))
        .await
        .unwrap();
    send(&mut ws, ControllerMessage::new(Kind::PairingRequest, 1)).await;
    receive(&mut ws, Kind::PairingChallenge).await;
    let code = send_request(
        &paths.control_socket,
        &ControlRequest::PairingCode { rotate: false },
    )
    .await
    .unwrap()
    .pairing_code
    .unwrap();
    let mut hello = ControllerMessage::new(Kind::Hello, 2);
    hello.pairing_code = Some(code);
    send(&mut ws, hello).await;
    let accepted = receive(&mut ws, Kind::PairingAccepted).await;
    assert!(!accepted
        .capabilities
        .unwrap_or_default()
        .contains(&ControllerCapability::ProfileArtifactAdoptionV1));
    let before = std::fs::read(&paths.state_file).unwrap();
    for request in [
        ControlRequest::AdoptProfileArtifact {
            metadata: metadata.clone(),
            artifact_base64: "not even base64".into(),
        },
        ControlRequest::ProfileArtifactAdoptionStatus {
            operation_id: metadata.operation_id,
        },
        ControlRequest::CancelProfileArtifactAdoption {
            operation_id: metadata.operation_id,
        },
    ] {
        let response = send_request(&paths.control_socket, &request).await.unwrap();
        assert!(!response.ok);
        assert_eq!(
            response.error_code.as_deref(),
            Some("hosted_builds_retired")
        );
        assert_eq!(std::fs::read(&paths.state_file).unwrap(), before);
    }
    for kind in [
        Kind::ProfileArtifactAdoptionBegin,
        Kind::ProfileArtifactAdoptionChunk,
        Kind::ProfileArtifactAdoptionCommit,
        Kind::ProfileArtifactAdoptionCancel,
    ] {
        let mut request = ControllerMessage::new(kind, 3);
        match kind {
            Kind::ProfileArtifactAdoptionBegin => {
                request.profile_artifact_adoption_metadata = Some(metadata.clone())
            }
            Kind::ProfileArtifactAdoptionChunk => {
                request.profile_artifact_adoption_operation_id = Some(metadata.operation_id);
                request.profile_artifact_adoption_chunk_index = Some(0);
                request.profile_artifact_adoption_chunk_data = Some("YQ==".into());
            }
            _ => request.profile_artifact_adoption_operation_id = Some(metadata.operation_id),
        }
        send(&mut ws, request).await;
        let response = receive(&mut ws, Kind::Error).await;
        assert!(response.message.unwrap().contains("retired"));
        assert_eq!(std::fs::read(&paths.state_file).unwrap(), before);
    }
    send(&mut ws, ControllerMessage::new(Kind::Ping, 100)).await;
    assert_eq!(receive(&mut ws, Kind::Pong).await.timestamp, 100);
    send(&mut ws, ControllerMessage::new(Kind::GamepadProfiles, 101)).await;
    let profiles = receive(&mut ws, Kind::GamepadProfiles).await;
    assert_eq!(profiles.gamepad_profiles.unwrap(), state.profiles);
    assert!(!profiles
        .capabilities
        .unwrap_or_default()
        .contains(&ControllerCapability::ProfileArtifactAdoptionV1));
    assert_eq!(std::fs::read(&paths.state_file).unwrap(), before);
    assert!(
        send_request(&paths.control_socket, &ControlRequest::Stop)
            .await
            .unwrap()
            .ok
    );
    tokio::time::timeout(Duration::from_secs(5), runtime)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
}

#[test]
fn host_cli_hides_and_rejects_retired_commands_without_reading_files_or_opening_state() {
    let binary = env!("CARGO_BIN_EXE_thumble-host");
    let help = std::process::Command::new(binary)
        .arg("--help")
        .output()
        .unwrap();
    assert!(help.status.success());
    assert!(!String::from_utf8(help.stdout)
        .unwrap()
        .contains("shared-build"));
    let directory = tempfile::tempdir().unwrap();
    let state = directory.path().join("must-not-create");
    for arguments in [
        vec!["shared-build"],
        vec!["shared-build", "adopt", "/does-not-exist", "--json"],
        vec!["shared-build", "status", "invalid-uuid"],
        vec!["shared-build", "cancel", "invalid-uuid"],
    ] {
        let result = std::process::Command::new(binary)
            .args(arguments)
            .env("THUMBLE_HOST_STATE_DIR", &state)
            .output()
            .unwrap();
        assert!(!result.status.success());
        assert!(String::from_utf8(result.stderr)
            .unwrap()
            .contains("retired"));
        assert!(!state.exists());
    }
}
