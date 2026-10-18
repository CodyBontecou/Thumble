//! Explicit opt-in: creates a native input device/foreground test window.
//! The witness observes OS events; receiver counters alone cannot pass this test.
#![cfg(any(windows, target_os = "linux"))]
use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use std::{
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    time::Duration,
};
use thumble_core::{KeyBinding, OutputBinding};
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType as Kind, ControllerPointerButton,
    ControllerPointerEventKind, ControllerWireCodec, KeypadElementID,
};
use thumble_receiver::{runtime::control, store::Store};
use tokio_tungstenite::{connect_async, tungstenite::Message};
#[cfg(target_os = "linux")]
#[path = "native/linux.rs"]
mod platform;
#[cfg(windows)]
#[path = "native/windows.rs"]
mod platform;

#[derive(Debug, Clone, Serialize)]
struct Observed {
    kind: &'static str,
    code: u16,
    value: i32,
}
struct Witness {
    events: Arc<Mutex<Vec<Observed>>>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Witness {
    fn has(&self, kind: &str, code: u16, value: i32) -> bool {
        self.events
            .lock()
            .unwrap()
            .iter()
            .any(|e| e.kind == kind && e.code == code && e.value == value)
    }
    async fn wait(&self, kind: &str, code: u16, value: i32) {
        for _ in 0..200 {
            if self.has(kind, code, value) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!(
            "Missing native OS event {kind}/{code}/{value}; observed {:?}",
            self.events.lock().unwrap()
        );
    }
}
impl Drop for Witness {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
struct Host(Child);
impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;
async fn send(socket: &mut Socket, message: ControllerMessage) {
    socket
        .send(Message::Binary(
            ControllerWireCodec::encode(&message).unwrap().into(),
        ))
        .await
        .unwrap();
}
async fn key(socket: &mut Socket, number: u16, down: bool, sequence: u64) {
    socket
        .send(Message::Binary(
            ControllerWireCodec::encode_button_with_sequence(
                KeypadElementID::preset(number),
                if down {
                    ButtonPressState::Down
                } else {
                    ButtonPressState::Up
                },
                sequence,
                Some(sequence),
                Some(17),
            )
            .into(),
        ))
        .await
        .unwrap();
}
async fn pointer(socket: &mut Socket, event: ControllerPointerEventKind, sequence: u64) {
    let mut message = ControllerMessage::new(Kind::Pointer, sequence as i64);
    message.pointer_event = Some(event);
    if event == ControllerPointerEventKind::Button {
        message.state = Some(ButtonPressState::Down);
    }
    message.pointer_button = Some(ControllerPointerButton::Left);
    message.delta_x = Some(40.0);
    message.delta_y = Some(40.0);
    message.input_protocol_version = Some(3);
    message.input_generation = Some(17);
    message.input_sequence = Some(sequence);
    send(socket, message).await;
}

#[tokio::test]
#[ignore = "requires an isolated native desktop/uinput test environment; see docs/cross-platform-receiver.md"]
async fn receiver_delivers_native_input_and_releases_on_disconnect() {
    let temp = tempfile::tempdir().unwrap();
    let store = Store::open(Some(temp.path().join("state"))).unwrap();
    let mut state = store.load().unwrap();
    for (number, code) in [(5u16, 0u16), (6, 1)] {
        let binding = KeyBinding::new(code, 8);
        let output = OutputBinding::keyboard(binding.clone());
        let id = KeypadElementID::preset(number);
        state.key_bindings.insert(id, binding.clone());
        state.output_bindings.insert(id, output.clone());
        state
            .profile_key_bindings
            .get_mut(&state.active_profile_id)
            .unwrap()
            .insert(id, binding);
        state
            .profile_output_bindings
            .get_mut(&state.active_profile_id)
            .unwrap()
            .insert(id, output.clone());
        let element = &mut state.profiles[0]["customization"]["elements"][number as usize - 1];
        element["output"] = output.element_value();
        element["defaultOutput"] = output.element_value();
    }
    store.save(&state).unwrap();
    let _host = Host(
        Command::new(env!("CARGO_BIN_EXE_thumble-receiver"))
            .arg("--state-dir")
            .arg(&store.directory)
            .args(["run", "--port", "0", "--no-bonjour"])
            .stdout(Stdio::null())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap(),
    );
    let mut port = None;
    for _ in 0..200 {
        if let Ok(status) = control(&store, "status").await {
            port = status["port"].as_u64();
            break;
        }
        tokio::time::sleep(Duration::from_millis(25)).await;
    }
    let port = port.expect("Native receiver did not start (uinput/desktop/ACL setup required)");
    let witness = platform::open()
        .expect("Cannot observe native OS input; do not count this as an input-delivery pass");
    let (mut socket, _) = connect_async(format!("ws://127.0.0.1:{port}"))
        .await
        .unwrap();
    let mut request = ControllerMessage::new(Kind::PairingRequest, 1);
    request.client_name = Some("Native CI iPhone protocol client".into());
    send(&mut socket, request).await;
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(Ok(Message::Binary(bytes))) = socket.next().await {
                if ControllerWireCodec::decode(&bytes).unwrap().message_type
                    == Kind::PairingChallenge
                {
                    break;
                }
            }
        }
    })
    .await
    .unwrap();
    let mut hello = ControllerMessage::new(Kind::Hello, 2);
    hello.client_name = Some("Native CI iPhone protocol client".into());
    hello.pairing_code = control(&store, "pairing-code").await.unwrap()["pairingCode"]
        .as_str()
        .map(str::to_owned);
    send(&mut socket, hello).await;
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            if let Some(Ok(Message::Binary(bytes))) = socket.next().await {
                if ControllerWireCodec::decode(&bytes).unwrap().message_type
                    == Kind::PairingAccepted
                {
                    break;
                }
            }
        }
    })
    .await
    .unwrap();
    key(&mut socket, 5, true, 1).await;
    witness.wait("key", 30, 1).await;
    witness.wait("key", 29, 1).await;
    key(&mut socket, 6, true, 2).await;
    witness.wait("key", 31, 1).await;
    key(&mut socket, 5, false, 3).await;
    witness.wait("key", 30, 0).await;
    assert!(
        !witness.has("key", 29, 0),
        "Shared Ctrl released while second chord remained held"
    );
    key(&mut socket, 6, false, 4).await;
    witness.wait("key", 31, 0).await;
    witness.wait("key", 29, 0).await;
    let moves_before = witness
        .events
        .lock()
        .unwrap()
        .iter()
        .filter(|e| e.kind == "move")
        .count();
    pointer(&mut socket, ControllerPointerEventKind::Move, 1).await;
    for _ in 0..200 {
        if witness
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.kind == "move")
            .count()
            > moves_before
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(
        witness
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.kind == "move")
            .count()
            > moves_before,
        "No native pointer movement after receiver command"
    );
    pointer(&mut socket, ControllerPointerEventKind::Scroll, 2).await;
    witness.wait("scroll", 0, 1).await;
    pointer(&mut socket, ControllerPointerEventKind::Button, 3).await;
    witness.wait("button", 272, 1).await;
    key(&mut socket, 5, true, 5).await;
    // Ensure a new down, rather than an earlier cached observation, reached the OS.
    for _ in 0..200 {
        if witness
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.kind == "key" && e.code == 30 && e.value == 1)
            .count()
            >= 2
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    socket.close(None).await.unwrap();
    witness.wait("button", 272, 0).await;
    for _ in 0..200 {
        if witness
            .events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e.kind == "key" && e.code == 30 && e.value == 0)
            .count()
            >= 2
        {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let events = witness.events.lock().unwrap().clone();
    assert_eq!(
        events
            .iter()
            .filter(|e| e.kind == "key" && e.code == 30 && e.value == 0)
            .count(),
        2,
        "Disconnect failed to release A"
    );
    let report = serde_json::json!({"platform":std::env::consts::OS,"transport":"real receiver WebSocket with iOS v3 codec (synthetic client)","nativeDelivery":true,"events":events});
    if let Some(path) = std::env::var_os("THUMBLE_NATIVE_EVIDENCE") {
        std::fs::write(path, serde_json::to_vec_pretty(&report).unwrap()).unwrap();
    }
    println!("{}", serde_json::to_string_pretty(&report).unwrap());
    control(&store, "stop").await.unwrap();
}
