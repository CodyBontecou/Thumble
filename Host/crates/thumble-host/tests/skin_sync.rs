//! Runs against the packaged native bridge, not a scripted transform helper.
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::os::unix::fs::PermissionsExt;
use std::process::{Child, Command, Stdio};
use std::time::Duration;
use thumble_host::control::{send_request, ControlRequest, HostStatus};
use thumble_host::paths::HostPaths;
use thumble_host::skin_command::SkinCommand;
use thumble_host::skins::SkinReference;
use thumble_protocol::{
    ControllerCapability, ControllerMessage, ControllerMessageType as Kind, ControllerWireCodec,
};
use tokio::net::TcpStream;
use tokio_tungstenite::{connect_async, tungstenite::Message, MaybeTlsStream, WebSocketStream};

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;
struct Receiver(Child);
impl Drop for Receiver {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
async fn send(ws: &mut Ws, message: ControllerMessage) {
    ws.send(Message::Binary(
        ControllerWireCodec::encode(&message).unwrap().into(),
    ))
    .await
    .unwrap();
}
async fn receive(ws: &mut Ws, kind: Kind) -> ControllerMessage {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            match ws.next().await.unwrap().unwrap() {
                Message::Binary(data) => {
                    let message = ControllerWireCodec::decode(&data).unwrap();
                    if message.message_type == kind {
                        return message;
                    }
                }
                Message::Text(data) => {
                    let message = ControllerWireCodec::decode(data.as_bytes()).unwrap();
                    if message.message_type == kind {
                        return message;
                    }
                }
                Message::Ping(data) => ws.send(Message::Pong(data)).await.unwrap(),
                _ => (),
            }
        }
    })
    .await
    .expect("native receiver response timed out")
}
async fn status(paths: &HostPaths) -> HostStatus {
    send_request(&paths.control_socket, &ControlRequest::Status)
        .await
        .unwrap()
        .status
        .unwrap()
}
async fn list(paths: &HostPaths) -> Value {
    let response = send_request(
        &paths.control_socket,
        &ControlRequest::Skin {
            request: SkinCommand::List,
        },
    )
    .await
    .unwrap();
    assert!(response.ok);
    response.skin.unwrap()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "requires THUMBLE_TEST_SKIN_RUNTIME_BIN containing the packaged host and native bridge"]
async fn native_receiver_authenticates_skin_changes_and_never_acknowledges_failed_persistence() {
    let bin = std::path::PathBuf::from(
        std::env::var_os("THUMBLE_TEST_SKIN_RUNTIME_BIN")
            .expect("packaged binary directory required"),
    );
    let directory = tempfile::tempdir().unwrap();
    let paths = HostPaths::new(
        directory.path().into(),
        directory.path().join("control.sock"),
    );
    paths.ensure_state_dir().unwrap();
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../fixtures/controller-templates/v1/productivityStarter.json"
    ))
    .unwrap();
    let profile = &fixture["profile"];
    let id = profile["id"].as_str().unwrap();
    std::fs::write(&paths.state_file,serde_json::to_vec(&json!({"schemaVersion":3,"serverID":"native-skin-test","trustedClients":{},"profiles":[profile],"activeProfileID":id,"defaultProfileID":id})).unwrap()).unwrap();
    std::fs::set_permissions(&paths.state_file, std::fs::Permissions::from_mode(0o600)).unwrap();
    let _receiver = Receiver(
        Command::new(bin.join("thumble-host"))
            .args(["run", "--port", "0", "--no-input", "--no-bonjour"])
            .env("THUMBLE_HOST_STATE_DIR", directory.path())
            .env("THUMBLE_HOST_CONTROL_SOCKET", &paths.control_socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let initial = tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if let Ok(response) = send_request(&paths.control_socket, &ControlRequest::Status).await
            {
                if let Some(s) = response.status {
                    break s;
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap();
    assert!(list(&paths).await["packages"]
        .as_array()
        .unwrap()
        .is_empty());
    let archive = include_bytes!(
        "../../../../Website/skins/packages/solar-sumi-1.0.0-edbecde5b708.pocketpad"
    );
    let (mut ws, _) = connect_async(format!("ws://127.0.0.1:{}", initial.port))
        .await
        .unwrap();
    let mut upload = ControllerMessage::new(Kind::SkinPackages, 0);
    upload.skin_packages = Some(vec![STANDARD.encode(archive)]);
    send(&mut ws, upload.clone()).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert!(
        list(&paths).await["packages"]
            .as_array()
            .unwrap()
            .is_empty(),
        "unauthenticated upload installed an archive"
    );
    let mut hello = ControllerMessage::new(Kind::Hello, 0);
    hello.server_id = Some("native-skin-test".into());
    hello.pairing_code = Some(initial.pairing_code);
    send(&mut ws, hello).await;
    let accepted = receive(&mut ws, Kind::PairingAccepted).await;
    assert!(accepted
        .capabilities
        .unwrap()
        .contains(&ControllerCapability::GamepadProfileSkinSelection));
    upload.skin_packages = Some(vec![
        STANDARD.encode(b"invalid zip"),
        STANDARD.encode(archive),
    ]);
    send(&mut ws, upload).await;
    let replay = receive(&mut ws, Kind::SkinPackages).await;
    assert_eq!(
        replay.skin_packages.unwrap(),
        vec![STANDARD.encode(archive)]
    );
    let packages = list(&paths).await;
    let reference: SkinReference =
        serde_json::from_value(packages["packages"][0]["reference"].clone()).unwrap();
    let mut apply = ControllerMessage::new(Kind::GamepadProfileSkinSelection, 0);
    apply.gamepad_profile_id = Some(id.into());
    apply.skin_reference = Some(json!(reference));
    send(&mut ws, apply.clone()).await;
    let authoritative = receive(&mut ws, Kind::GamepadProfiles).await;
    assert_eq!(
        authoritative.gamepad_profiles.unwrap()[0]["skinReference"],
        json!(reference)
    );
    let before = status(&paths).await;
    assert!(before.core.paired);
    let saved: Value = serde_json::from_slice(&std::fs::read(&paths.state_file).unwrap()).unwrap();
    assert_eq!(saved["profiles"][0]["skinReference"], json!(reference));
    let in_use = send_request(
        &paths.control_socket,
        &ControlRequest::Skin {
            request: SkinCommand::Remove {
                reference: reference.clone(),
            },
        },
    )
    .await
    .unwrap();
    assert!(!in_use.ok);
    let backup = directory.path().join("saved.json");
    std::fs::rename(&paths.state_file, &backup).unwrap();
    std::fs::create_dir(&paths.state_file).unwrap();
    apply.skin_reference = None;
    send(&mut ws, apply).await;
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if std::fs::read_to_string(&paths.log_file)
                .unwrap_or_default()
                .contains("skin_profile_save_failed")
            {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("failed-save diagnostic missing");
    let after = status(&paths).await;
    assert!(after.core.paired);
    assert_eq!(
        after.core.configuration_revision,
        before.core.configuration_revision
    );
    assert!(after.core.pressed_buttons.is_empty());
    assert!(after.core.pressed_elements.is_empty());
    std::fs::remove_dir(&paths.state_file).unwrap();
    std::fs::rename(backup, &paths.state_file).unwrap();
    assert!(
        serde_json::from_slice::<Value>(&std::fs::read(&paths.state_file).unwrap()).unwrap()
            == saved,
        "failed skin persistence changed the saved state"
    );
    ws.close(None).await.unwrap();
}
