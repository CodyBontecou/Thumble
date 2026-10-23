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

fn skin_cli(
    bin: &std::path::Path,
    paths: &HostPaths,
    arguments: &[&str],
    succeeds: bool,
) -> Vec<u8> {
    let output = Command::new(bin.join("thumble"))
        .arg("skin")
        .args(arguments)
        .env("THUMBLE_HOST_STATE_DIR", &paths.state_dir)
        .env("THUMBLE_HOST_CONTROL_SOCKET", &paths.control_socket)
        .stdin(Stdio::null())
        .output()
        .expect("packaged Swift CLI failed to launch");
    assert_eq!(
        output.status.success(),
        succeeds,
        "packaged skin CLI {:?}: {}",
        arguments,
        String::from_utf8_lossy(&output.stderr)
    );
    output.stdout
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
    let inactive: Value = serde_json::from_str(include_str!(
        "../../../fixtures/controller-templates/v1/gameBoy.json"
    ))
    .unwrap();
    let mut inactive = inactive["profile"].clone();
    inactive["id"] = json!("4FD20F4A-3C83-40B5-87C0-64512F4AC925");
    let inactive_id = inactive["id"].as_str().unwrap();
    std::fs::write(&paths.state_file,serde_json::to_vec(&json!({"schemaVersion":3,"serverID":"native-skin-test","trustedClients":{},"profiles":[profile,inactive],"activeProfileID":id,"defaultProfileID":id})).unwrap()).unwrap();
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
        "../../../../docs/skins/examples/css-first-light/dist/css-first-light-1.0.0.pocketpad"
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
    std::fs::rename(&backup, &paths.state_file).unwrap();
    assert!(
        serde_json::from_slice::<Value>(&std::fs::read(&paths.state_file).unwrap()).unwrap()
            == saved,
        "failed skin persistence changed the saved state"
    );

    // Exercise the public Swift entry point, not just its underlying local IPC.
    // These commands must address this receiver's library and broadcast the same
    // durable profile state that authenticated phones receive.
    let target = format!("{}@{}", reference.identifier, reference.version);
    let catalog: Value =
        serde_json::from_slice(&skin_cli(&bin, &paths, &["list", "--json"], true)).unwrap();
    assert_eq!(catalog["packages"][0]["reference"], json!(reference));
    let exported = directory.path().join("exact.pocketpad");
    skin_cli(
        &bin,
        &paths,
        &["export", &target, "-o", exported.to_str().unwrap()],
        true,
    );
    assert_eq!(std::fs::read(&exported).unwrap(), archive);
    skin_cli(&bin, &paths, &["remove", &target], false);
    let after_rejected_remove: Value =
        serde_json::from_slice(&std::fs::read(&paths.state_file).unwrap()).unwrap();
    assert_eq!(after_rejected_remove, saved);

    skin_cli(&bin, &paths, &["detach", "--profile", id], true);
    let detached = receive(&mut ws, Kind::GamepadProfiles).await;
    assert!(detached.gamepad_profiles.unwrap()[0]["skinReference"].is_null());
    skin_cli(&bin, &paths, &["remove", &target], true);
    assert!(list(&paths).await["packages"]
        .as_array()
        .unwrap()
        .is_empty());
    skin_cli(&bin, &paths, &["import", exported.to_str().unwrap()], true);
    skin_cli(
        &bin,
        &paths,
        &["apply", &target, "--profile", id, "--appearance", "dark"],
        true,
    );
    let applied = receive(&mut ws, Kind::GamepadProfiles).await;
    assert_eq!(
        applied.gamepad_profiles.unwrap()[0]["skinReference"],
        json!(reference)
    );
    let persisted: Value =
        serde_json::from_slice(&std::fs::read(&paths.state_file).unwrap()).unwrap();
    assert_eq!(persisted["profiles"][0]["skinReference"], json!(reference));
    assert_eq!(persisted["activeProfileID"], saved["activeProfileID"]);
    assert_eq!(persisted["trustedClients"], saved["trustedClients"]);

    let mut customization = ControllerMessage::new(Kind::GamepadCustomization, 0);
    customization.gamepad_profile_id = Some(inactive_id.to_uppercase());
    let mut layout = inactive["customization"].clone();
    layout["colorSchemePreference"] = json!("dark");
    customization.gamepad_customization = Some(layout);
    send(&mut ws, customization.clone()).await;
    let appearance = receive(&mut ws, Kind::GamepadProfiles).await;
    assert_eq!(appearance.gamepad_profile_id.as_deref(), Some(id));
    let profiles = appearance.gamepad_profiles.unwrap();
    assert_eq!(profiles[0], persisted["profiles"][0]);
    assert_eq!(
        profiles[1]["customization"]["colorSchemePreference"],
        json!("dark")
    );
    assert!(
        ["portraitCustomization", "landscapeCustomization"]
            .iter()
            .any(|key| profiles[1].get(key) == profiles[1].get("customization")),
        "native orientation slot must mirror its updated primary customization"
    );
    let committed: Value =
        serde_json::from_slice(&std::fs::read(&paths.state_file).unwrap()).unwrap();
    assert_eq!(committed["activeProfileID"], persisted["activeProfileID"]);
    assert_eq!(committed["defaultProfileID"], persisted["defaultProfileID"]);
    assert_eq!(committed["trustedClients"], persisted["trustedClients"]);
    let before_failure = status(&paths).await;
    std::fs::rename(&paths.state_file, &backup).unwrap();
    std::fs::create_dir(&paths.state_file).unwrap();
    customization.gamepad_customization = Some(profiles[1]["customization"].clone());
    customization.gamepad_customization.as_mut().unwrap()["colorSchemePreference"] = json!("light");
    send(&mut ws, customization).await;
    tokio::time::timeout(Duration::from_secs(15), async {
        while !std::fs::read_to_string(&paths.log_file)
            .unwrap_or_default()
            .contains("phone_layout_save_failed")
        {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("phone layout persistence failure diagnostic missing");
    assert_eq!(
        status(&paths).await.core.configuration_revision,
        before_failure.core.configuration_revision
    );
    assert!(tokio::time::timeout(
        Duration::from_millis(300),
        receive(&mut ws, Kind::GamepadProfiles)
    )
    .await
    .is_err());
    std::fs::remove_dir(&paths.state_file).unwrap();
    std::fs::rename(&backup, &paths.state_file).unwrap();
    assert_eq!(
        serde_json::from_slice::<Value>(&std::fs::read(&paths.state_file).unwrap()).unwrap(),
        committed
    );
    // A full inactive portrait edit must preserve the landscape and active
    // profile, rather than merely replacing the primary JSON layout.
    let mut portrait = profiles[1]["customization"].clone();
    portrait["deviceCanvas"] = json!({"frameID":"iphone-17-pro-portrait"});
    let mut replacement = ControllerMessage::new(Kind::GamepadCustomization, 0);
    replacement.gamepad_profile_id = Some(inactive_id.into());
    replacement.gamepad_customization = Some(portrait);
    send(&mut ws, replacement.clone()).await;
    let changed = receive(&mut ws, Kind::GamepadProfiles).await;
    let changed = changed.gamepad_profiles.unwrap();
    assert_eq!(changed[0], profiles[0]);
    assert_eq!(
        changed[1]["customization"]["deviceCanvas"]["frameID"],
        "iphone-17-pro-portrait"
    );
    assert_eq!(
        changed[1]["portraitCustomization"],
        changed[1]["customization"]
    );
    assert_eq!(
        changed[1]["landscapeCustomization"],
        profiles[1]["landscapeCustomization"]
    );

    let recovered_id = uuid::Uuid::new_v4();
    replacement.gamepad_profile_id = Some(recovered_id.to_string());
    replacement.gamepad_customization = Some(changed[1]["customization"].clone());
    send(&mut ws, replacement.clone()).await;
    let recovered = receive(&mut ws, Kind::GamepadProfiles).await;
    assert_eq!(recovered.gamepad_profile_id.as_deref(), Some(id));
    let recovered = recovered.gamepad_profiles.unwrap();
    assert_eq!(recovered.len(), 3);
    assert_eq!(recovered[2]["name"], "Recovered Phone Layout");
    assert_eq!(
        uuid::Uuid::parse_str(recovered[2]["id"].as_str().unwrap()).unwrap(),
        recovered_id
    );
    assert_eq!(
        recovered[2]["portraitCustomization"],
        recovered[2]["customization"]
    );
    assert!(recovered[2].get("launchTarget").is_none_or(Value::is_null));
    let catalog = Command::new(bin.join("thumble-host"))
        .args(["profiles", "--json"])
        .env("THUMBLE_HOST_STATE_DIR", &paths.state_dir)
        .env("THUMBLE_HOST_CONTROL_SOCKET", &paths.control_socket)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        catalog.status.success(),
        "CLI could not read the recovered profile"
    );
    let catalog: Value = serde_json::from_slice(&catalog.stdout).unwrap();
    assert!(catalog
        .to_string()
        .to_lowercase()
        .contains(&recovered_id.to_string()));
    let before_noop = status(&paths).await;
    replacement.gamepad_customization = Some(recovered[2]["customization"].clone());
    send(&mut ws, replacement).await;
    receive(&mut ws, Kind::GamepadProfiles).await;
    assert_eq!(
        status(&paths).await.core.configuration_revision,
        before_noop.core.configuration_revision
    );
    let saved: Value = serde_json::from_slice(&std::fs::read(&paths.state_file).unwrap()).unwrap();
    assert_eq!(saved["activeProfileID"], committed["activeProfileID"]);
    assert_eq!(saved["defaultProfileID"], committed["defaultProfileID"]);
    assert_eq!(saved["trustedClients"], committed["trustedClients"]);
    // More pending layouts than the worker's eight slots must converge without
    // retiring authentication or invalidating each queued job's revision.
    let mut missing = (0..12)
        .map(|_| uuid::Uuid::new_v4())
        .collect::<std::collections::BTreeSet<_>>();
    let layout = recovered[2]["customization"].clone();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(45);
    loop {
        for id in &missing {
            let mut request = ControllerMessage::new(Kind::GamepadCustomization, 0);
            request.gamepad_profile_id = Some(id.to_string());
            request.gamepad_customization = Some(layout.clone());
            send(&mut ws, request).await;
        }
        loop {
            assert!(
                tokio::time::Instant::now() < deadline,
                "queued layout batch failed to converge"
            );
            let response = tokio::time::timeout(
                Duration::from_millis(500),
                receive(&mut ws, Kind::GamepadProfiles),
            )
            .await;
            let Ok(response) = response else {
                break;
            };
            for profile in response.gamepad_profiles.unwrap() {
                let id = uuid::Uuid::parse_str(profile["id"].as_str().unwrap()).unwrap();
                missing.remove(&id);
            }
            if missing.is_empty() {
                break;
            }
        }
        if missing.is_empty() {
            break;
        }
    }
    let final_status = status(&paths).await;
    assert!(final_status.core.paired);
    let saved: Value = serde_json::from_slice(&std::fs::read(&paths.state_file).unwrap()).unwrap();
    assert_eq!(saved["profiles"].as_array().unwrap().len(), 15);
    assert_eq!(saved["activeProfileID"], committed["activeProfileID"]);
    assert_eq!(saved["defaultProfileID"], committed["defaultProfileID"]);
    ws.close(None).await.unwrap();
}
