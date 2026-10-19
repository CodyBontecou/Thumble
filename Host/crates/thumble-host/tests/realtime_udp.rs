use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tempfile::{tempdir, TempDir};
use thumble_core::PersistentState;
use thumble_host::{
    control::{send_request, ControlRequest, HostStatus},
    paths::HostPaths,
    runtime::{run_runtime, RuntimeOptions},
    storage::save_atomic,
};
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType as Kind, ControllerWireCodec,
    KeypadElementID,
};
use tokio::{
    net::{TcpStream, UdpSocket},
    task::JoinHandle,
};
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;
async fn start(
    port: u16,
) -> (
    TempDir,
    HostPaths,
    JoinHandle<Result<(), String>>,
    HostStatus,
) {
    let dir = tempdir().unwrap();
    let paths = HostPaths::new(dir.path().into(), dir.path().join("control.sock"));
    paths.ensure_state_dir().unwrap();
    save_atomic(
        &paths.state_file,
        &PersistentState::minimal("udp-test").unwrap(),
    )
    .unwrap();
    let copy = paths.clone();
    let task = tokio::spawn(run_runtime(
        copy,
        RuntimeOptions {
            port,
            bonjour: false,
            input: false,
            configuration_write: false,
        },
    ));
    let status = wait(&paths, |_| true).await;
    (dir, paths, task, status)
}
async fn wait(paths: &HostPaths, predicate: impl Fn(&HostStatus) -> bool) -> HostStatus {
    for _ in 0..200 {
        if let Ok(response) = send_request(&paths.control_socket, &ControlRequest::Status).await {
            if let Some(s) = response.status {
                if predicate(&s) {
                    return s;
                }
            }
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("receiver condition timed out");
}
async fn pair(status: &HostStatus, auth: Option<String>) -> (Ws, ControllerMessage) {
    let (mut ws, _) = connect_async(format!("ws://127.0.0.1:{}", status.port))
        .await
        .unwrap();
    let mut hello = ControllerMessage::new(Kind::Hello, 0);
    hello.pairing_code = auth.is_none().then(|| status.pairing_code.clone());
    hello.auth_token = auth;
    hello.server_id = Some("udp-test".into());
    send(&mut ws, &hello).await;
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(3), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let Message::Binary(bytes) = frame {
            let message = ControllerWireCodec::decode(&bytes).unwrap();
            if message.message_type == Kind::PairingAccepted {
                return (ws, message);
            }
        }
    }
}
async fn send(ws: &mut Ws, message: &ControllerMessage) {
    ws.send(Message::Binary(
        ControllerWireCodec::encode(message).unwrap().into(),
    ))
    .await
    .unwrap();
}
async fn udp(port: u16) -> UdpSocket {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    socket.connect(("127.0.0.1", port)).await.unwrap();
    socket
}
async fn hello(socket: &UdpSocket, token: &str) {
    let mut message = ControllerMessage::new(Kind::Hello, 0);
    message.realtime_token = Some(token.into());
    socket
        .send(&ControllerWireCodec::encode(&message).unwrap())
        .await
        .unwrap();
}
fn edge(slot: u16, down: bool, sequence: u64, press: u64) -> Vec<u8> {
    ControllerWireCodec::encode_button_with_sequence(
        KeypadElementID::preset(slot),
        if down {
            ButtonPressState::Down
        } else {
            ButtonPressState::Up
        },
        sequence,
        Some(press),
        Some(7),
    )
}
async fn stop(paths: &HostPaths, task: JoinHandle<Result<(), String>>) {
    assert!(
        send_request(&paths.control_socket, &ControlRequest::Stop)
            .await
            .unwrap()
            .ok
    );
    tokio::time::timeout(Duration::from_secs(3), task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn udp_auth_mirrored_multitouch_and_websocket_release_after_udp_loss() {
    let (_dir, paths, task, initial) = start(0).await;
    assert!(initial.realtime.enabled);
    let (mut ws, accepted) = pair(&initial, None).await;
    let datagram = udp(initial.port).await;
    let stranger = udp(initial.port).await;
    datagram.send(&edge(5, true, 1, 10)).await.unwrap(); // No hello yet.
    hello(&datagram, "wrong-token").await;
    hello(&datagram, accepted.realtime_token.as_ref().unwrap()).await;
    wait(&paths, |s| s.realtime.authenticated).await;
    stranger.send(&edge(5, true, 1, 10)).await.unwrap(); // Valid input, wrong endpoint.
    datagram.send(&[b'x'; 8193]).await.unwrap();
    // Configuration and pairing are never accepted over the authenticated UDP lane.
    let request = ControllerMessage::new(Kind::GamepadProfiles, 0);
    datagram
        .send(&ControllerWireCodec::encode(&request).unwrap())
        .await
        .unwrap();
    let denied = wait(&paths, |s| s.realtime.rejected_datagrams >= 5).await;
    assert!(denied.core.pressed_buttons.is_empty());

    let first = edge(5, true, 1, 10);
    let second = edge(6, true, 2, 11);
    datagram.send(&first).await.unwrap();
    wait(&paths, |s| s.realtime.udp_accepted_inputs == 1).await;
    ws.send(Message::Binary(first.clone().into()))
        .await
        .unwrap();
    // Reverse lane order for the second finger; both lanes share deduplication.
    ws.send(Message::Binary(second.clone().into()))
        .await
        .unwrap();
    wait(&paths, |s| s.core.pressed_buttons.len() == 2).await;
    datagram.send(&second).await.unwrap();
    wait(&paths, |s| s.core.counters.duplicate_sequences >= 2).await;
    // The second finger's UDP refresh overtakes the first finger's release.
    datagram.send(&edge(6, true, 4, 11)).await.unwrap();
    wait(&paths, |s| s.realtime.udp_accepted_inputs == 2).await;
    // UDP drops here: older reliable releases must still release both holds.
    ws.send(Message::Binary(edge(5, false, 3, 10).into()))
        .await
        .unwrap();
    ws.send(Message::Binary(edge(6, false, 5, 11).into()))
        .await
        .unwrap();
    let released = wait(&paths, |s| s.core.counters.accepted_inputs == 5).await;
    assert!(released.core.pressed_buttons.is_empty());
    assert_eq!(released.realtime.udp_accepted_inputs, 2);
    assert_eq!(released.realtime.websocket_accepted_inputs, 3);
    // A late UDP down cannot resurrect a released touch.
    datagram.send(&first).await.unwrap();
    let late = wait(&paths, |s| s.core.counters.duplicate_sequences >= 3).await;
    assert!(late.core.pressed_buttons.is_empty());
    assert_eq!(late.core.counters.expired_holds, 0);

    // Reconnecting rotates the UDP token and retires the old authenticated endpoint.
    let (mut replacement, reaccepted) = pair(&initial, accepted.auth_token).await;
    assert_ne!(reaccepted.realtime_token, accepted.realtime_token);
    let before = wait(&paths, |s| !s.realtime.authenticated)
        .await
        .realtime
        .rejected_datagrams;
    hello(&datagram, accepted.realtime_token.as_ref().unwrap()).await;
    datagram.send(&edge(5, true, 5, 12)).await.unwrap();
    wait(&paths, |s| s.realtime.rejected_datagrams >= before + 2).await;
    hello(&datagram, reaccepted.realtime_token.as_ref().unwrap()).await;
    wait(&paths, |s| s.realtime.authenticated).await;
    datagram.send(&edge(5, true, 1, 20)).await.unwrap();
    wait(&paths, |s| s.core.pressed_buttons.len() == 1).await;
    replacement.close(None).await.unwrap();
    let closed = wait(&paths, |s| !s.core.paired).await;
    assert!(!closed.realtime.authenticated);
    assert!(closed.core.pressed_buttons.is_empty());
    let before = closed.realtime.rejected_datagrams;
    datagram.send(&edge(5, true, 2, 21)).await.unwrap();
    wait(&paths, |s| s.realtime.rejected_datagrams > before).await;
    stop(&paths, task).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn occupied_udp_port_keeps_websocket_input_available_without_advertising_token() {
    let occupied = UdpSocket::bind("0.0.0.0:0").await.unwrap();
    let port = occupied.local_addr().unwrap().port();
    let (_dir, paths, task, initial) = start(port).await;
    assert!(!initial.realtime.enabled);
    let (mut ws, accepted) = pair(&initial, None).await;
    assert!(accepted.realtime_token.is_none());
    ws.send(Message::Binary(edge(5, true, 1, 1).into()))
        .await
        .unwrap();
    ws.send(Message::Binary(edge(5, false, 2, 1).into()))
        .await
        .unwrap();
    let status = wait(&paths, |s| s.core.counters.accepted_inputs == 2).await;
    assert!(status.core.pressed_buttons.is_empty());
    stop(&paths, task).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn ipv6_udp_release_barrier_retires_delayed_generation() {
    let (_dir, paths, task, initial) = start(0).await;
    let (_ws, accepted) = pair(&initial, None).await;
    let socket = UdpSocket::bind("[::1]:0").await.unwrap();
    socket.connect(("::1", initial.port)).await.unwrap();
    hello(&socket, accepted.realtime_token.as_ref().unwrap()).await;
    wait(&paths, |s| s.realtime.authenticated).await;
    socket.send(&edge(5, true, 1, 1)).await.unwrap();
    wait(&paths, |s| s.core.pressed_buttons.len() == 1).await;
    let mut barrier = ControllerMessage::new(Kind::ReleaseAll, 0);
    barrier.input_protocol_version = Some(3);
    barrier.input_generation = Some(8);
    barrier.input_sequence = Some(1);
    socket
        .send(&ControllerWireCodec::encode(&barrier).unwrap())
        .await
        .unwrap();
    wait(&paths, |s| {
        s.core.active_generation == Some(8) && s.core.pressed_buttons.is_empty()
    })
    .await;
    socket.send(&edge(5, true, 2, 2)).await.unwrap();
    let status = wait(&paths, |s| s.core.counters.stale_generations > 0).await;
    assert!(status.core.pressed_buttons.is_empty());
    stop(&paths, task).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn reordered_relative_udp_motion_cannot_suppress_reliable_pointer_release() {
    use thumble_protocol::{ControllerPointerButton, ControllerPointerEventKind};
    let (_dir, paths, task, initial) = start(0).await;
    let (mut ws, accepted) = pair(&initial, None).await;
    let datagram = udp(initial.port).await;
    hello(&datagram, accepted.realtime_token.as_ref().unwrap()).await;
    wait(&paths, |s| s.realtime.authenticated).await;
    let baseline = wait(&paths, |_| true).await.output.events_executed;
    let pointer = |kind, sequence| {
        let mut message = ControllerMessage::new(Kind::Pointer, 0);
        message.pointer_event = Some(kind);
        message.input_protocol_version = Some(3);
        message.input_generation = Some(7);
        message.input_sequence = Some(sequence);
        message
    };
    let mut down = pointer(ControllerPointerEventKind::Button, 1);
    down.pointer_button = Some(ControllerPointerButton::Left);
    down.state = Some(ButtonPressState::Down);
    datagram
        .send(&ControllerWireCodec::encode(&down).unwrap())
        .await
        .unwrap();
    wait(&paths, |s| s.core.active_pointer_buttons.len() == 1).await;
    let mut motion = pointer(ControllerPointerEventKind::Move, 4);
    motion.delta_x = Some(7.0);
    datagram
        .send(&ControllerWireCodec::encode(&motion).unwrap())
        .await
        .unwrap();
    let mut scroll = pointer(ControllerPointerEventKind::Scroll, 5);
    scroll.delta_y = Some(2.0);
    datagram
        .send(&ControllerWireCodec::encode(&scroll).unwrap())
        .await
        .unwrap();
    wait(&paths, |s| s.realtime.udp_accepted_inputs == 3).await;
    let mut earlier = pointer(ControllerPointerEventKind::Move, 3);
    earlier.delta_x = Some(3.0);
    send(&mut ws, &earlier).await;
    let mut up = pointer(ControllerPointerEventKind::Button, 2);
    up.pointer_button = Some(ControllerPointerButton::Left);
    up.state = Some(ButtonPressState::Up);
    send(&mut ws, &up).await;
    let status = wait(&paths, |s| s.core.counters.accepted_inputs == 5).await;
    assert!(status.core.active_pointer_buttons.is_empty());
    assert!(status.output.held_pointer_buttons.is_empty());
    assert_eq!(status.output.events_executed - baseline, 5);
    assert_eq!(status.core.counters.expired_holds, 0);
    datagram
        .send(&ControllerWireCodec::encode(&down).unwrap())
        .await
        .unwrap();
    send(&mut ws, &motion).await;
    let status = wait(&paths, |s| s.core.counters.duplicate_sequences >= 2).await;
    assert!(status.core.active_pointer_buttons.is_empty());
    assert_eq!(status.output.events_executed - baseline, 5);
    stop(&paths, task).await;
}
