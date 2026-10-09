use futures_util::{SinkExt, StreamExt};
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use tempfile::tempdir;
use thumble_core::PersistentState;
use thumble_host::control::{send_request, ControlRequest, ControlResponse, HostStatus};
use thumble_host::paths::{HostPaths, CONTROL_SOCKET_ENV, STATE_DIR_ENV};
use thumble_host::storage::save_atomic;
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType, ControllerWireCodec, KeypadElementID,
};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{connect_async, MaybeTlsStream, WebSocketStream};

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn sigterm_releases_held_input_before_process_exit() {
    let directory = tempdir().unwrap();
    let paths = HostPaths::new(
        directory.path().to_path_buf(),
        directory.path().join("control.sock"),
    );
    paths.ensure_state_dir().unwrap();
    save_atomic(
        &paths.state_file,
        &PersistentState::minimal("signal-test-server").unwrap(),
    )
    .unwrap();

    let mut child = Command::new(env!("CARGO_BIN_EXE_thumble-host"))
        .args(["run", "--port", "0", "--no-bonjour", "--no-input"])
        .env(STATE_DIR_ENV, &paths.state_dir)
        .env(CONTROL_SOCKET_ENV, &paths.control_socket)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();

    let status = wait_for_status_or_child(&paths, &mut child).await;
    let url = format!("ws://127.0.0.1:{}", status.port);
    let (mut socket, _) = connect_async(url).await.unwrap();

    let mut pairing_request = ControllerMessage::new(ControllerMessageType::PairingRequest, 1);
    pairing_request.client_name = Some("Signal Test iPhone".to_owned());
    socket
        .send(Message::Binary(
            serde_json::to_vec(&pairing_request).unwrap().into(),
        ))
        .await
        .unwrap();
    let _ = receive_type(&mut socket, ControllerMessageType::PairingChallenge).await;
    let code = successful(
        send_request(
            &paths.control_socket,
            &ControlRequest::PairingCode { rotate: false },
        )
        .await
        .unwrap(),
    )
    .pairing_code
    .unwrap();
    let mut hello = ControllerMessage::new(ControllerMessageType::Hello, 2);
    hello.pairing_code = Some(code);
    hello.client_name = Some("Signal Test iPhone".to_owned());
    socket
        .send(Message::Binary(serde_json::to_vec(&hello).unwrap().into()))
        .await
        .unwrap();
    let _ = receive_type(&mut socket, ControllerMessageType::PairingAccepted).await;
    socket
        .send(Message::Binary(
            ControllerWireCodec::encode_button_with_sequence(
                KeypadElementID::preset(5),
                ButtonPressState::Down,
                1,
                Some(1),
                Some(99),
            )
            .into(),
        ))
        .await
        .unwrap();

    wait_for_held_key(&paths).await;
    // SAFETY: the PID belongs to the child spawned above and SIGTERM is the
    // production graceful-termination path under launchd and process managers.
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGTERM) }, 0);
    wait_for_exit(&mut child).await;

    let recording = std::fs::read_to_string(&paths.output_recording_file).unwrap();
    assert!(recording.contains("key_down:36:0"), "{recording}");
    assert!(recording.contains("key_up:36:0"), "{recording}");
    assert!(!paths.control_socket.exists());
    assert!(!paths.pid_file.exists());
}

async fn wait_for_status_or_child(paths: &HostPaths, child: &mut Child) -> HostStatus {
    for _ in 0..200 {
        assert!(
            child.try_wait().unwrap().is_none(),
            "host exited before ready"
        );
        if let Ok(response) = send_request(&paths.control_socket, &ControlRequest::Status).await {
            if response.ok {
                if let Some(status) = response.status {
                    return status;
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let _ = child.kill();
    panic!("host did not become ready");
}

async fn wait_for_held_key(paths: &HostPaths) {
    for _ in 0..100 {
        if let Ok(response) = send_request(&paths.control_socket, &ControlRequest::Status).await {
            if response
                .status
                .is_some_and(|status| status.output.held_key_count == 1)
            {
                return;
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("host did not record held key");
}

async fn wait_for_exit(child: &mut Child) {
    for _ in 0..200 {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success(), "host exited unsuccessfully: {status}");
            return;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let _ = child.kill();
    panic!("host ignored SIGTERM");
}

fn successful(response: ControlResponse) -> ControlResponse {
    assert!(response.ok, "control failure: {:?}", response.error);
    response
}

type ClientSocket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

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
