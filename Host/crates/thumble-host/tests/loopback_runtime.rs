use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tempfile::tempdir;
use thumble_core::PersistentState;
use thumble_host::control::{send_request, ControlRequest, ControlResponse, HostStatus};
use thumble_host::draft_operation::ConfigurationOperation;
use thumble_host::paths::HostPaths;
use thumble_host::runtime::{run_runtime, RuntimeOptions};
use thumble_host::storage::save_atomic;
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType, ControllerPointerEventKind,
    ControllerWireCodec, KeypadElementID,
};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn current_ios_loopback_pairs_reconnects_records_input_and_releases_on_shutdown() {
    let directory = tempdir().unwrap();
    let paths = HostPaths::new(
        directory.path().to_path_buf(),
        directory.path().join("control.sock"),
    );
    paths.ensure_state_dir().unwrap();
    save_atomic(
        &paths.state_file,
        &PersistentState::minimal("loopback-server-id").unwrap(),
    )
    .unwrap();
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
    let initial_status = wait_for_status(&paths).await;
    assert_ne!(initial_status.port, 0);
    assert!(!initial_status.bonjour.enabled);
    assert!(!initial_status.input_enabled);

    let configuration = successful(
        send_request(&paths.control_socket, &ControlRequest::ConfigurationStatus)
            .await
            .unwrap(),
    )
    .configuration
    .unwrap();
    assert_eq!(configuration.configuration_revision, 1);
    assert_eq!(configuration.profile_count, 1);
    assert!(!configuration.bridge_available);
    assert!(configuration.configuration_write_enabled);
    let stale_begin = send_request(
        &paths.control_socket,
        &ControlRequest::BeginConfigurationDraft {
            expected_configuration_revision: 2,
        },
    )
    .await
    .unwrap();
    assert!(!stale_begin.ok);
    assert_eq!(
        stale_begin.error_code.as_deref(),
        Some("configuration_revision_conflict")
    );
    assert_eq!(stale_begin.expected_revision, Some(2));
    assert_eq!(stale_begin.actual_revision, Some(1));
    let draft = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::BeginConfigurationDraft {
                expected_configuration_revision: 1,
            },
        )
        .await
        .unwrap(),
    )
    .draft
    .unwrap();
    assert_eq!(draft.base_configuration_revision, 1);
    assert_eq!(draft.draft_revision, 1);
    let fetched = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::GetConfigurationDraft {
                draft_id: draft.draft_id.clone(),
            },
        )
        .await
        .unwrap(),
    )
    .draft
    .unwrap();
    assert_eq!(fetched, draft);
    let competing_draft = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::BeginConfigurationDraft {
                expected_configuration_revision: 1,
            },
        )
        .await
        .unwrap(),
    )
    .draft
    .unwrap();
    let operation_id = "00000000-0000-0000-0000-000000000401";
    let rename = ConfigurationOperation::ProfileRename {
        profile_id: thumble_core::DEFAULT_PROFILE_ID.to_owned(),
        name: "Loopback Edited".to_owned(),
    };
    let edited = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::EditConfigurationDraft {
                draft_id: draft.draft_id.clone(),
                expected_draft_revision: 1,
                operation_id: operation_id.to_owned(),
                operation: rename.clone(),
            },
        )
        .await
        .unwrap(),
    );
    assert_eq!(edited.draft.as_ref().unwrap().draft_revision, 2);
    assert!(edited.draft_operation.as_ref().unwrap().changed);
    assert_eq!(edited.idempotent_replay, Some(false));
    let replayed_edit = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::EditConfigurationDraft {
                draft_id: draft.draft_id.clone(),
                expected_draft_revision: 1,
                operation_id: operation_id.to_owned(),
                operation: rename,
            },
        )
        .await
        .unwrap(),
    );
    assert_eq!(replayed_edit.draft.as_ref().unwrap().draft_revision, 2);
    assert_eq!(replayed_edit.idempotent_replay, Some(true));
    let preview = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::PreviewConfigurationDraft {
                draft_id: draft.draft_id.clone(),
                expected_draft_revision: 2,
            },
        )
        .await
        .unwrap(),
    );
    assert_eq!(
        preview.controller.as_ref().unwrap().profile.name,
        "Loopback Edited"
    );
    let validation = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::ValidateConfigurationDraft {
                draft_id: draft.draft_id.clone(),
                expected_draft_revision: 2,
            },
        )
        .await
        .unwrap(),
    )
    .validation
    .unwrap();
    assert!(validation.valid);
    assert_eq!(validation.error_count, 0);
    let commit_id = "00000000-0000-0000-0000-000000000501";
    let saved = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::SaveConfigurationDraft {
                draft_id: draft.draft_id.clone(),
                expected_draft_revision: 2,
                expected_configuration_revision: 1,
                commit_id: commit_id.to_owned(),
            },
        )
        .await
        .unwrap(),
    )
    .save
    .unwrap();
    assert!(saved.changed);
    assert_eq!(saved.configuration_revision, 2);
    assert!(!saved.idempotent_replay);
    let replayed_save = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::SaveConfigurationDraft {
                draft_id: draft.draft_id.clone(),
                expected_draft_revision: 2,
                expected_configuration_revision: 1,
                commit_id: commit_id.to_owned(),
            },
        )
        .await
        .unwrap(),
    )
    .save
    .unwrap();
    assert_eq!(replayed_save.configuration_revision, 2);
    assert!(replayed_save.idempotent_replay);
    let configuration = successful(
        send_request(&paths.control_socket, &ControlRequest::ConfigurationStatus)
            .await
            .unwrap(),
    )
    .configuration
    .unwrap();
    assert_eq!(configuration.configuration_revision, 2);
    let conflicting_save = send_request(
        &paths.control_socket,
        &ControlRequest::SaveConfigurationDraft {
            draft_id: competing_draft.draft_id.clone(),
            expected_draft_revision: 1,
            expected_configuration_revision: 1,
            commit_id: "00000000-0000-0000-0000-000000000502".to_owned(),
        },
    )
    .await
    .unwrap();
    assert_eq!(
        conflicting_save.error_code.as_deref(),
        Some("configuration_revision_conflict")
    );
    assert_eq!(conflicting_save.expected_revision, Some(1));
    assert_eq!(conflicting_save.actual_revision, Some(2));
    let rebase_id = "00000000-0000-0000-0000-000000000504";
    let rebased = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::RebaseConfigurationDraft {
                draft_id: competing_draft.draft_id.clone(),
                expected_draft_revision: 1,
                expected_configuration_revision: 2,
                rebase_id: rebase_id.to_owned(),
            },
        )
        .await
        .unwrap(),
    );
    assert_eq!(
        rebased.draft.as_ref().unwrap().base_configuration_revision,
        2
    );
    assert_eq!(rebased.draft.as_ref().unwrap().draft_revision, 2);
    assert_eq!(rebased.idempotent_replay, Some(false));
    let replayed_rebase = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::RebaseConfigurationDraft {
                draft_id: competing_draft.draft_id.clone(),
                expected_draft_revision: 1,
                expected_configuration_revision: 2,
                rebase_id: rebase_id.to_owned(),
            },
        )
        .await
        .unwrap(),
    );
    assert_eq!(replayed_rebase.idempotent_replay, Some(true));
    successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::DiscardConfigurationDraft {
                draft_id: competing_draft.draft_id,
                expected_draft_revision: 2,
            },
        )
        .await
        .unwrap(),
    );

    let profile_response = successful(
        send_request(&paths.control_socket, &ControlRequest::ListProfiles)
            .await
            .unwrap(),
    );
    assert_eq!(profile_response.configuration_revision, Some(2));
    let profiles = profile_response.profiles.unwrap();
    assert_eq!(profiles.len(), 1);
    assert!(profiles[0].active);
    assert_eq!(
        profile_response.active_profile_id.as_deref(),
        Some(profiles[0].id.as_str())
    );
    let control_response = successful(
        send_request(&paths.control_socket, &ControlRequest::ListControls)
            .await
            .unwrap(),
    );
    let controls = control_response.controls.unwrap();
    assert!(controls
        .iter()
        .any(|control| control.control_id == "element:00000000-0000-0000-0000-000000000105"));
    assert!(controls
        .iter()
        .all(|control| !control.control_id.to_ascii_lowercase().contains("keycode")));
    let controller_response = successful(
        send_request(&paths.control_socket, &ControlRequest::RenderController)
            .await
            .unwrap(),
    );
    let controller = controller_response.controller.unwrap();
    assert_eq!(controller_response.configuration_revision, Some(2));
    assert_eq!(controller.profile.id, profiles[0].id);
    assert_eq!(controller.profile.name, "Loopback Edited");
    assert_eq!(controller.orientation.as_str(), "landscape");
    assert_eq!(controller.canvas.width, 874.0);
    assert_eq!(controller.canvas.height, 402.0);
    assert_eq!(controller.elements.len(), 10);
    let encoded_controller = serde_json::to_string(&controller).unwrap();
    for forbidden in ["authToken", "keyCode", "modifiersRawValue", "partOutputs"] {
        assert!(!encoded_controller.contains(forbidden));
    }
    let select = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::SelectProfile {
                profile_id: profiles[0].id.clone(),
            },
        )
        .await
        .unwrap(),
    );
    assert_eq!(select.profile_changed, Some(false));
    let disabled_press = send_request(
        &paths.control_socket,
        &ControlRequest::PressControl {
            control_id: "element:00000000-0000-0000-0000-000000000105".to_owned(),
        },
    )
    .await
    .unwrap();
    assert!(!disabled_press.ok);
    assert_eq!(
        disabled_press.error.as_deref(),
        Some("host input is disabled")
    );

    let url = format!("ws://127.0.0.1:{}", initial_status.port);
    let (mut first, _) = connect_async(&url).await.unwrap();

    let mut pairing_request = ControllerMessage::new(ControllerMessageType::PairingRequest, 1);
    pairing_request.client_name = Some("Loopback iPhone".to_owned());
    first
        .send(Message::Text(
            serde_json::to_string(&pairing_request).unwrap().into(),
        ))
        .await
        .unwrap();
    let challenge = receive_type(&mut first, ControllerMessageType::PairingChallenge).await;
    assert_eq!(challenge.pairing_code, None);
    assert_eq!(challenge.auth_token, None);

    let pairing = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::PairingCode { rotate: false },
        )
        .await
        .unwrap(),
    );
    let pairing_code = pairing.pairing_code.unwrap();
    assert_eq!(pairing_code.len(), 6);

    let mut hello = ControllerMessage::new(ControllerMessageType::Hello, 2);
    hello.pairing_code = Some(pairing_code);
    hello.client_name = Some("Loopback iPhone".to_owned());
    first
        .send(Message::Binary(serde_json::to_vec(&hello).unwrap().into()))
        .await
        .unwrap();
    let accepted = receive_type(&mut first, ControllerMessageType::PairingAccepted).await;
    assert_eq!(accepted.input_protocol_version, Some(3));
    assert_eq!(accepted.realtime_token, None);
    assert_eq!(accepted.capabilities, Some(Vec::new()));
    assert_eq!(
        accepted.gamepad_profiles.as_ref().unwrap()[0]["name"],
        "Loopback Edited"
    );
    let paired_draft = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::BeginConfigurationDraft {
                expected_configuration_revision: 2,
            },
        )
        .await
        .unwrap(),
    )
    .draft
    .unwrap();
    let paired_edit = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::EditConfigurationDraft {
                draft_id: paired_draft.draft_id.clone(),
                expected_draft_revision: 1,
                operation_id: "00000000-0000-0000-0000-000000000402".to_owned(),
                operation: ConfigurationOperation::ProfileRename {
                    profile_id: thumble_core::DEFAULT_PROFILE_ID.to_owned(),
                    name: "Phone Synced".to_owned(),
                },
            },
        )
        .await
        .unwrap(),
    );
    assert_eq!(paired_edit.draft.as_ref().unwrap().draft_revision, 2);
    let paired_save = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::SaveConfigurationDraft {
                draft_id: paired_draft.draft_id,
                expected_draft_revision: 2,
                expected_configuration_revision: 2,
                commit_id: "00000000-0000-0000-0000-000000000503".to_owned(),
            },
        )
        .await
        .unwrap(),
    )
    .save
    .unwrap();
    assert_eq!(paired_save.configuration_revision, 3);
    assert!(paired_save.phone_sync_queued);
    let synchronized = receive_type(&mut first, ControllerMessageType::GamepadProfiles).await;
    assert_eq!(
        synchronized.gamepad_profiles.as_ref().unwrap()[0]["name"],
        "Phone Synced"
    );

    let auth_token = accepted.auth_token.clone().expect("test-only auth token");
    let server_id = accepted.server_id.clone().unwrap();

    first
        .send(Message::Binary(
            ControllerWireCodec::encode_button_with_sequence(
                KeypadElementID::preset(5),
                ButtonPressState::Down,
                1,
                Some(10),
                Some(7),
            )
            .into(),
        ))
        .await
        .unwrap();
    first
        .send(Message::Binary(
            ControllerWireCodec::encode_button_with_sequence(
                KeypadElementID::preset(5),
                ButtonPressState::Up,
                2,
                Some(10),
                Some(7),
            )
            .into(),
        ))
        .await
        .unwrap();
    let mut pointer = ControllerMessage::new(ControllerMessageType::Pointer, 3);
    pointer.pointer_event = Some(ControllerPointerEventKind::Move);
    pointer.delta_x = Some(12.5);
    pointer.delta_y = Some(-3.0);
    pointer.input_protocol_version = Some(3);
    pointer.input_generation = Some(7);
    pointer.input_sequence = Some(1);
    first
        .send(Message::Text(
            serde_json::to_string(&pointer).unwrap().into(),
        ))
        .await
        .unwrap();
    assert_ping_round_trip(&mut first, 54).await;

    // A trusted same-token hello on a second socket replaces the first active
    // connection and exercises the current iOS authenticated reconnect path.
    let (mut second, _) = connect_async(&url).await.unwrap();
    let mut reconnect = ControllerMessage::new(ControllerMessageType::Hello, 4);
    reconnect.auth_token = Some(auth_token);
    reconnect.server_id = Some(server_id.clone());
    reconnect.client_name = Some("Loopback iPhone".to_owned());
    second
        .send(Message::Binary(
            serde_json::to_vec(&reconnect).unwrap().into(),
        ))
        .await
        .unwrap();
    let reaccepted = receive_type(&mut second, ControllerMessageType::PairingAccepted).await;
    assert_eq!(reaccepted.server_id.as_deref(), Some(server_id.as_str()));
    assert_eq!(reaccepted.input_protocol_version, Some(3));
    assert_eq!(reaccepted.realtime_token, None);

    let unsupported = ControllerMessage::new(ControllerMessageType::LaunchProfileTarget, 5);
    second
        .send(Message::Text(
            serde_json::to_string(&unsupported).unwrap().into(),
        ))
        .await
        .unwrap();
    let ping = ControllerMessage::new(ControllerMessageType::Ping, 55);
    second
        .send(Message::Text(serde_json::to_string(&ping).unwrap().into()))
        .await
        .unwrap();
    let pong = receive_type(&mut second, ControllerMessageType::Pong).await;
    assert_eq!(
        pong.timestamp, 55,
        "unsupported request must not end iOS session"
    );

    let profile_request = ControllerMessage::new(ControllerMessageType::GamepadProfiles, 6);
    second
        .send(Message::Text(
            serde_json::to_string(&profile_request).unwrap().into(),
        ))
        .await
        .unwrap();
    let profiles = receive_type(&mut second, ControllerMessageType::GamepadProfiles).await;
    assert!(!profiles.gamepad_profiles.unwrap().is_empty());
    assert!(profiles.gamepad_profile_id.is_some());

    second
        .send(Message::Binary(
            ControllerWireCodec::encode_button_with_sequence(
                KeypadElementID::preset(5),
                ButtonPressState::Down,
                1,
                Some(20),
                Some(9),
            )
            .into(),
        ))
        .await
        .unwrap();
    second
        .send(Message::Binary(
            ControllerWireCodec::encode_button_with_sequence(
                KeypadElementID::preset(5),
                ButtonPressState::Down,
                2,
                Some(21),
                Some(9),
            )
            .into(),
        ))
        .await
        .unwrap();
    assert_ping_round_trip(&mut second, 56).await;
    let active_status = wait_for_status(&paths).await;
    assert!(active_status.core.paired);
    assert_eq!(active_status.core.pressed_buttons, vec![KeypadElementID::preset(5)]);
    assert_eq!(active_status.output.held_key_count, 1);
    assert!(active_status
        .output
        .recent_events
        .iter()
        .any(|event| event.starts_with("pointer_move:")));
    assert!(active_status
        .output
        .recent_events
        .iter()
        .any(|event| event.starts_with("key_down:")));
    assert!(active_status
        .output
        .recent_events
        .iter()
        .any(|event| event.starts_with("key_pulse_down:")));

    let stop = successful(
        send_request(&paths.control_socket, &ControlRequest::Stop)
            .await
            .unwrap(),
    );
    assert_eq!(stop.stopping, Some(true));
    let runtime_result = tokio::time::timeout(Duration::from_secs(5), runtime)
        .await
        .expect("runtime stopped")
        .expect("runtime task joined");
    runtime_result.unwrap();

    let recording = std::fs::read_to_string(&paths.output_recording_file).unwrap();
    assert!(recording.contains("pointer_move:12.500:-3.000"));
    assert!(recording.contains("key_down:36:0"), "{recording}");
    assert!(recording.contains("key_pulse_up:36:0"), "{recording}");
    assert!(recording.contains("key_pulse_down:36:0"), "{recording}");
    assert!(recording.contains("key_up:36:0"), "{recording}");
    assert!(!paths.control_socket.exists());
    assert!(!paths.pid_file.exists());
}

async fn wait_for_status(paths: &HostPaths) -> HostStatus {
    for _ in 0..100 {
        if let Ok(response) = send_request(&paths.control_socket, &ControlRequest::Status).await {
            if response.ok {
                if let Some(status) = response.status {
                    return status;
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    panic!("runtime did not publish status");
}

fn successful(response: ControlResponse) -> ControlResponse {
    assert!(response.ok, "control failure: {:?}", response.error);
    response
}

type ClientSocket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

async fn assert_ping_round_trip(socket: &mut ClientSocket, timestamp: i64) {
    let ping = ControllerMessage::new(ControllerMessageType::Ping, timestamp);
    socket
        .send(Message::Text(serde_json::to_string(&ping).unwrap().into()))
        .await
        .unwrap();
    let pong = receive_type(socket, ControllerMessageType::Pong).await;
    assert_eq!(pong.timestamp, timestamp);
}

async fn receive_type(
    socket: &mut ClientSocket,
    expected: ControllerMessageType,
) -> ControllerMessage {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(3), socket.next())
            .await
            .expect("controller response timed out")
            .expect("WebSocket ended")
            .expect("WebSocket response failed");
        let message = match frame {
            Message::Binary(data) => ControllerWireCodec::decode(data.as_ref()).unwrap(),
            Message::Text(text) => ControllerWireCodec::decode(text.as_bytes()).unwrap(),
            Message::Ping(data) => {
                socket.send(Message::Pong(data)).await.unwrap();
                continue;
            }
            Message::Pong(_) => continue,
            Message::Close(frame) => panic!("unexpected close: {frame:?}"),
            Message::Frame(_) => continue,
        };
        if message.message_type == expected {
            return message;
        }
    }
}
