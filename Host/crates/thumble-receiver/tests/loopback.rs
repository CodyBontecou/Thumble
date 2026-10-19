//! Real executable, real WebSockets, released iOS codecs; no physical OS input.
use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use std::{
    process::{Child, Command, Stdio},
    time::Duration,
};
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType as Kind, ControllerWireCodec,
    KeypadElementID,
};
use thumble_receiver::{runtime::control, store::Store};
use tokio_tungstenite::{connect_async, tungstenite::Message};

struct Host(Child);
impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn launch(store: &Store) -> Host {
    Host(
        Command::new(env!("CARGO_BIN_EXE_thumble-receiver"))
            .arg("--state-dir")
            .arg(&store.directory)
            .args(["run", "--port", "0", "--no-bonjour", "--no-input"])
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap(),
    )
}
async fn ready(store: &Store) -> Value {
    for _ in 0..100 {
        if let Ok(status) = control(store, "status").await {
            return status;
        }
        tokio::time::sleep(Duration::from_millis(30)).await;
    }
    panic!("Receiver never became ready");
}
type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;
async fn receive(socket: &mut Socket, kind: Kind) -> ControllerMessage {
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            match socket.next().await.unwrap().unwrap() {
                Message::Binary(bytes) => {
                    let message = ControllerWireCodec::decode(&bytes).unwrap();
                    if message.message_type == kind {
                        return message;
                    }
                }
                Message::Text(text) => {
                    let message = ControllerWireCodec::decode(text.as_bytes()).unwrap();
                    if message.message_type == kind {
                        return message;
                    }
                }
                _ => (),
            }
        }
    })
    .await
    .expect("Missing expected iOS response")
}
async fn send(socket: &mut Socket, message: ControllerMessage) {
    socket
        .send(Message::Binary(
            ControllerWireCodec::encode(&message).unwrap().into(),
        ))
        .await
        .unwrap();
}

#[tokio::test]
async fn pairing_input_expiry_disconnect_and_durable_reconnect() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(Some(temp.path().join("receiver"))).unwrap();
    let mut host = launch(&store);
    let status = ready(&store).await;
    let port = status["port"].as_u64().unwrap();
    assert_eq!(status["virtualGamepadStatus"]["phase"], "creation-failed");
    let (mut socket, _) = connect_async(format!("ws://127.0.0.1:{port}"))
        .await
        .unwrap();
    socket
        .send(Message::Binary(
            ControllerWireCodec::encode_button_with_sequence(
                KeypadElementID::preset(5),
                ButtonPressState::Down,
                1,
                Some(1),
                Some(9),
            )
            .into(),
        ))
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(60)).await;
    assert_eq!(
        control(&store, "status").await.unwrap()["core"]["paired"],
        false
    );
    drop(socket);
    let (mut socket, _) = connect_async(format!("ws://127.0.0.1:{port}"))
        .await
        .unwrap();
    let mut request = ControllerMessage::new(Kind::PairingRequest, 1);
    request.client_name = Some("Loopback iPhone".into());
    send(&mut socket, request).await;
    let challenge = receive(&mut socket, Kind::PairingChallenge).await;
    assert!(challenge.pairing_code.is_none());
    assert!(challenge.auth_token.is_none());
    let code = control(&store, "pairing-code").await.unwrap()["pairingCode"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut hello = ControllerMessage::new(Kind::Hello, 2);
    hello.client_name = Some("Loopback iPhone".into());
    hello.pairing_code = Some(code);
    send(&mut socket, hello).await;
    let accepted = receive(&mut socket, Kind::PairingAccepted).await;
    assert_eq!(accepted.input_protocol_version, Some(3));
    assert!(accepted.realtime_token.is_none());
    assert!(accepted
        .gamepad_profiles
        .as_ref()
        .is_some_and(|p| !p.is_empty()));
    let token = accepted.auth_token.unwrap();
    let server_id = store.load().unwrap().server_id;
    socket
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
    for _ in 0..100 {
        if control(&store, "status").await.unwrap()["core"]["counters"]["acceptedInputs"]
            .as_u64()
            .unwrap()
            > 0
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let status = control(&store, "status").await.unwrap();
    assert_eq!(
        status["core"]["pressedButtons"].as_array().unwrap().len(),
        1
    );
    tokio::time::sleep(Duration::from_millis(2100)).await;
    assert!(
        control(&store, "status").await.unwrap()["core"]["pressedButtons"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    socket.close(None).await.unwrap();
    for _ in 0..100 {
        if control(&store, "status").await.unwrap()["core"]["paired"] == false {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(
        control(&store, "status").await.unwrap()["core"]["paired"],
        false
    );
    control(&store, "stop").await.unwrap();
    for _ in 0..100 {
        if host.0.try_wait().unwrap().is_some() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(host.0.try_wait().unwrap().unwrap().success());
    assert!(!store.directory.join("runtime.json").exists());
    let _second = launch(&store);
    let port = ready(&store).await["port"].as_u64().unwrap();
    let (mut socket, _) = connect_async(format!("ws://127.0.0.1:{port}"))
        .await
        .unwrap();
    let mut hello = ControllerMessage::new(Kind::Hello, 3);
    hello.auth_token = Some(token);
    hello.server_id = Some(server_id.clone());
    hello.client_name = Some("Loopback iPhone".into());
    send(&mut socket, hello).await;
    receive(&mut socket, Kind::PairingAccepted).await;
    assert_eq!(store.load().unwrap().server_id, server_id);
    control(&store, "release-all").await.unwrap();
    control(&store, "stop").await.unwrap();
}

#[tokio::test]
async fn local_control_rejects_wrong_credentials_and_oversized_frames() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(Some(temp.path().join("receiver"))).unwrap();
    let _host = launch(&store);
    ready(&store).await;
    let endpoint: Value = store.read("runtime.json").unwrap();
    let mut socket =
        tokio::net::TcpStream::connect(("127.0.0.1", endpoint["port"].as_u64().unwrap() as u16))
            .await
            .unwrap();
    socket
        .write_all(b"{\"token\":\"wrong\",\"command\":\"stop\"}\n")
        .await
        .unwrap();
    let mut response = Vec::new();
    socket.read_to_end(&mut response).await.unwrap();
    assert!(response.is_empty());
    assert_eq!(control(&store, "status").await.unwrap()["ok"], true);
    let mut socket =
        tokio::net::TcpStream::connect(("127.0.0.1", endpoint["port"].as_u64().unwrap() as u16))
            .await
            .unwrap();
    socket.write_all(&vec![b'x'; 65537]).await.unwrap();
    socket.shutdown().await.unwrap();
    let mut response = Vec::new();
    let _ = socket.read_to_end(&mut response).await;
    assert!(response.is_empty());
    control(&store, "stop").await.unwrap();
}
