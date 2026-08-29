//! End-to-end gateway test: a scripted "device" (real tunnel protocol, real
//! `ThumbleMcp` sessions), the full OAuth 2.1 + PKCE flow, and a real
//! Streamable HTTP MCP client standing in for ChatGPT.
//!
//! Covered:
//! - DCR `/register`, consent `/authorize` + `/authorize/confirm` with a
//!   real link code, `/token` with PKCE S256
//! - refresh-token rotation + reuse detection
//! - bearer-only `/mcp`: initialize, scope-filtered tools/list, tool call
//!   through the tunnel into `ThumbleMcp` and the host control socket
//! - scope denial and locally-blocked tools
//! - 401 without a token

use std::os::unix::fs::PermissionsExt as _;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures::{SinkExt, StreamExt};
use rmcp::transport::streamable_http_client::{
    StreamableHttpClientTransport, StreamableHttpClientTransportConfig,
};
use rmcp::{ClientLifecycleMode, ClientServiceExt as _, ServiceExt as _};
use thumble_gateway::principal::ResourceKind;
use thumble_gateway::state::AppState;
use thumble_gateway::store::Store;
use thumble_gateway::tunnel::TunnelRegistry;
use thumble_tunnel::ws_rpc::WsIo;
use thumble_tunnel::ws_rpc::{decode_control_message, encode_control_message, split_json_rpc_ws};
use thumble_tunnel::TunnelMessage;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

#[derive(Default)]
struct StatusHost {
    draft_revision: AtomicU64,
}

impl StatusHost {
    fn draft(&self) -> thumble_host::control::ConfigurationDraftSummary {
        let revision = self.draft_revision.load(Ordering::SeqCst).max(1);
        thumble_host::control::ConfigurationDraftSummary {
            draft_id: "00000000-0000-0000-0000-000000000301".to_owned(),
            base_configuration_revision: 1,
            draft_revision: revision,
            profile_count: 1,
            active_profile_id: "profile-safe".to_owned(),
            default_profile_id: "profile-safe".to_owned(),
            operation_count: revision.saturating_sub(1) as usize,
            created_at: 1,
            updated_at: revision as i64,
            expires_at: 86_401,
        }
    }
}

impl thumble_host::control::ControlHandler for StatusHost {
    fn handle(
        &self,
        request: thumble_host::control::ControlRequest,
    ) -> thumble_host::control::ControlResponse {
        use thumble_host::control::ControlRequest;
        let mut response = thumble_host::control::ControlResponse::success();
        match request {
            ControlRequest::Status => response.status = Some(host_status_snapshot()),
            ControlRequest::ConfigurationStatus => {
                response.configuration = Some(thumble_host::control::ConfigurationStatusSummary {
                    configuration_revision: 1,
                    profile_count: 1,
                    active_profile_id: "profile-safe".to_owned(),
                    default_profile_id: "profile-safe".to_owned(),
                    maximum_live_drafts: 8,
                    draft_lifetime_millis: 86_400_000,
                    operation_schema_version: 1,
                    bridge_available: true,
                    configuration_write_enabled: true,
                });
            }
            ControlRequest::BeginConfigurationDraft { .. } => {
                self.draft_revision.store(1, Ordering::SeqCst);
                response.draft = Some(self.draft());
            }
            ControlRequest::EditConfigurationDraft { .. } => {
                self.draft_revision.store(2, Ordering::SeqCst);
                response.draft = Some(self.draft());
                response.draft_operation = Some(
                    thumble_host::draft_operation::ConfigurationOperationOutcome {
                        changed: true,
                        changed_paths: vec!["profiles.profile-safe.name".to_owned()],
                    },
                );
                response.idempotent_replay = Some(false);
            }
            ControlRequest::ValidateConfigurationDraft { .. } => {
                response.validation = Some(thumble_host::control::ConfigurationValidationSummary {
                    draft_id: self.draft().draft_id,
                    draft_revision: self.draft().draft_revision,
                    valid: true,
                    error_count: 0,
                    warning_count: 0,
                    validator: "e2e".to_owned(),
                });
            }
            ControlRequest::PreviewConfigurationDraft { .. } => {
                response.draft = Some(self.draft());
                response.editable_variant = Some("primary".to_owned());
                response.controller = Some(controller_snapshot());
            }
            ControlRequest::SaveConfigurationDraft { commit_id, .. } => {
                response.save = Some(thumble_host::control::ConfigurationSaveSummary {
                    draft_id: self.draft().draft_id,
                    commit_id,
                    base_configuration_revision: 1,
                    configuration_revision: 2,
                    draft_revision: self.draft().draft_revision,
                    changed: true,
                    idempotent_replay: false,
                    phone_sync_queued: true,
                });
            }
            _ => {}
        }
        response
    }
}

fn controller_snapshot() -> thumble_core::ControllerSnapshot {
    thumble_core::ControllerSnapshot {
        profile: thumble_core::ControllerProfileSnapshot {
            id: "profile-safe".to_owned(),
            name: "E2E Draft".to_owned(),
            orientation_preference: "automatic".to_owned(),
        },
        orientation: thumble_core::ControllerOrientation::Landscape,
        color_scheme_preference: "system".to_owned(),
        accent_style: "purple".to_owned(),
        shows_button_labels: true,
        canvas: thumble_core::ControllerCanvasSnapshot {
            frame_id: "iphone-17-pro-landscape".to_owned(),
            width: 874.0,
            height: 402.0,
            fill: None,
            light_fill: None,
            dark_fill: None,
            unsupported_content_omitted: false,
        },
        elements: Vec::new(),
        control_bar_items: Vec::new(),
        layers: Vec::new(),
        groups: Vec::new(),
        styles: Vec::new(),
        layout_quality: thumble_core::ControllerLayoutQualitySnapshot::default(),
    }
}

fn host_status_snapshot() -> thumble_host::control::HostStatus {
    thumble_host::control::HostStatus {
        pid: std::process::id(),
        version: "gateway-e2e".to_owned(),
        port: 0,
        requested_port: 0,
        bonjour: thumble_host::bonjour::BonjourInfo {
            enabled: false,
            registered: false,
            state: "disabled".to_owned(),
            service_name: String::new(),
            error: None,
        },
        service_name: "thumble-e2e".to_owned(),
        urls: Vec::new(),
        accessibility_trusted: false,
        input_enabled: false,
        configuration_write_enabled: false,
        state_path: String::new(),
        control_socket: String::new(),
        server_id: "e2e-server".to_owned(),
        pairing_code: String::new(),
        core: thumble_core::StatusSnapshot {
            running: true,
            paired: true,
            client_name: Some("iPhone".to_owned()),
            pairing_pending: false,
            active_generation: None,
            pressed_buttons: Vec::new(),
            pressed_elements: Vec::new(),
            active_pointer_buttons: Vec::new(),
            active_profile_id: "profile-safe".to_owned(),
            default_profile_id: "profile-safe".to_owned(),
            configuration_revision: 1,
            counters: thumble_core::StatusCounters {
                messages_received: 0,
                accepted_inputs: 0,
                ignored_inputs: 0,
                duplicate_sequences: 0,
                rejected_inputs: 0,
                stale_generations: 0,
                pairing_rejections: 0,
                expired_holds: 0,
                release_all_events: 0,
            },
            status_text: "ok".to_owned(),
        },
        output: thumble_host::output::OutputSnapshot {
            mode: "keyboard".to_owned(),
            events_executed: 0,
            held_key_count: 0,
            pending_key_release_count: 0,
            held_pointer_buttons: Vec::new(),
            pending_pointer_releases: Vec::new(),
            recent_events: Vec::new(),
        },
    }
}

async fn next_frame(websocket: &mut WebSocketStream<WsIo>) -> TunnelMessage {
    loop {
        let message = tokio::time::timeout(Duration::from_secs(30), websocket.next())
            .await
            .expect("frame timeout")
            .expect("socket closed")
            .expect("socket error");
        if let Some(frame) = decode_control_message(&message.into_data()) {
            return frame;
        }
    }
}

async fn persist_next_link_grant(websocket: &mut WebSocketStream<WsIo>) -> (String, String) {
    let (device_id, device_token) = match next_frame(websocket).await {
        TunnelMessage::LinkGranted {
            device_id,
            device_token,
        } => (device_id, device_token),
        other => panic!("expected LinkGranted, got {other:?}"),
    };
    websocket
        .send(Message::text(encode_control_message(
            &TunnelMessage::LinkPersisted {
                device_id: device_id.clone(),
            },
        )))
        .await
        .unwrap();
    (device_id, device_token)
}

async fn authorized_ws(url: &str, token: &str) -> WebSocketStream<WsIo> {
    let mut request = url.to_owned().into_client_request().unwrap();
    request.headers_mut().insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
    );
    tokio_tungstenite::connect_async(request)
        .await
        .expect("connect websocket")
        .0
}

async fn real_manifest(
    control_socket: PathBuf,
) -> (
    Vec<serde_json::Value>,
    Vec<serde_json::Value>,
    Option<String>,
) {
    let (server_transport, client_transport) = tokio::io::duplex(256 * 1024);
    let server_task = tokio::spawn(async move {
        thumble_mcp::ThumbleMcp::new(control_socket, false, true)
            .serve(server_transport)
            .await
            .unwrap()
            .waiting()
            .await
            .unwrap();
    });
    let client = ().serve(client_transport).await.unwrap();
    let tools = client
        .list_all_tools()
        .await
        .unwrap()
        .into_iter()
        .map(|tool| serde_json::to_value(tool).unwrap())
        .collect();
    let resources = client
        .list_all_resources()
        .await
        .unwrap()
        .into_iter()
        .map(|resource| serde_json::to_value(resource).unwrap())
        .collect();
    let instructions = client
        .peer_info()
        .and_then(|info| info.instructions.clone());
    client.cancel().await.unwrap();
    server_task.await.unwrap();
    (tools, resources, instructions)
}

fn hidden_form_value(html: &str, name: &str) -> String {
    let marker = format!("name=\"{name}\" value=\"");
    html.split(&marker)
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .expect("hidden form value")
        .to_owned()
}

fn builder_consent_cookie(response: &reqwest::Response) -> String {
    let set_cookie = response
        .headers()
        .get("set-cookie")
        .expect("builder consent cookie")
        .to_str()
        .unwrap();
    assert!(set_cookie.contains("Path=/authorize/builder/confirm"));
    assert!(set_cookie.contains("HttpOnly"));
    assert!(set_cookie.contains("SameSite=Lax"));
    assert!(
        !set_cookie.contains("Secure"),
        "loopback HTTP cookie must remain usable"
    );
    set_cookie.split(';').next().unwrap().to_owned()
}

fn completion_callback(html: &str) -> String {
    let marker = "id=\"oauth-callback\" href=\"";
    html.split(marker)
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .expect("OAuth completion callback")
        .replace("&amp;", "&")
}

async fn wait_for_authorization_completion(
    http: &reqwest::Client,
    base: &str,
    request_id: &str,
) -> String {
    let mut last_body = String::new();
    for _ in 0..100 {
        let response = http
            .get(format!("{base}/authorize/wait"))
            .query(&[("request_id", request_id)])
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 200);
        last_body = response.text().await.unwrap();
        if last_body.contains("id=\"oauth-callback\"") || last_body.contains("Connection declined")
        {
            return last_body;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    panic!("authorization did not complete: {last_body}");
}

fn callback_values(location: &str, name: &str) -> Vec<String> {
    url::Url::parse(location)
        .expect("OAuth callback URL")
        .query_pairs()
        .filter(|(key, _)| key == name)
        .map(|(_, value)| value.into_owned())
        .collect()
}

fn pkce_pair() -> (String, String) {
    use base64::Engine as _;
    let verifier = "e2e-verifier-e2e-verifier-e2e-verifier-e2e-verifier".to_owned();
    let digest = sha2::Sha256::digest(verifier.as_bytes());
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(digest);
    (verifier, challenge)
}

use sha2::Digest as _;

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn chatgpt_style_connector_drives_a_device_end_to_end() {
    // ---- Local host + control socket ----
    let host_dir = tempfile::tempdir().unwrap();
    std::fs::set_permissions(host_dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let control_socket = host_dir.path().join("control.sock");
    let listener = thumble_host::control::bind_control_socket(&control_socket)
        .await
        .unwrap();
    let (host_shutdown_tx, host_shutdown_rx) = tokio::sync::watch::channel(false);
    let host_task = tokio::spawn(thumble_host::control::serve_control(
        listener,
        Arc::new(StatusHost::default()),
        host_shutdown_rx,
    ));

    // ---- Gateway on a real TCP listener ----
    // The e2e asserts strict replay-revocation; disable the concurrent
    // refresh grace window here (unit tests cover the grace semantics).
    let store = Arc::new(Store::open_in_memory().unwrap().with_refresh_grace(0));
    let state = Arc::new(AppState::new(
        store,
        TunnelRegistry::new(),
        "http://placeholder.invalid".to_owned(),
    ));
    let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let gateway_port = tcp.local_addr().unwrap().port();
    state.set_base_url(format!("http://127.0.0.1:{gateway_port}"));
    let state_for_assertions = state.clone();
    let server_task = tokio::spawn(async move {
        axum::serve(
            tcp,
            thumble_gateway::app(state)
                .into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )
        .await
        .unwrap();
    });

    let base = format!("http://127.0.0.1:{gateway_port}");
    let resource = format!("{base}/mcp");
    let ws_base = format!("ws://127.0.0.1:{gateway_port}");

    // ---- Device: anonymous link window ----
    let (link_ws, _) = tokio_tungstenite::connect_async(format!("{ws_base}/tunnel/link"))
        .await
        .unwrap();
    let mut link_ws = link_ws;
    link_ws
        .send(Message::text(encode_control_message(
            &TunnelMessage::LinkRequest {
                device_name: "E2E Mac".to_owned(),
            },
        )))
        .await
        .unwrap();
    let link_code = match next_frame(&mut link_ws).await {
        TunnelMessage::LinkOffer { code, url, .. } => {
            assert_eq!(url, format!("{base}/link?code={code}"));
            code
        }
        other => panic!("expected LinkOffer, got {other:?}"),
    };

    // ---- OAuth: DCR, authorize page, confirm, token ----
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let link_page = http
        .get(format!("{base}/link?code={link_code}"))
        .send()
        .await
        .unwrap();
    assert_eq!(link_page.status(), 200);
    let link_page_body = link_page.text().await.unwrap();
    assert!(link_page_body.contains(&format!("<code>{link_code}</code>")));
    assert!(link_page_body.contains("No code is needed"));
    assert!(link_page_body.contains("click <strong>Connect</strong>"));

    let metadata_response = http
        .get(format!("{base}/.well-known/oauth-authorization-server"))
        .send()
        .await
        .unwrap();
    assert_eq!(metadata_response.status(), 200);
    assert_eq!(
        metadata_response
            .headers()
            .get("x-content-type-options")
            .unwrap(),
        "nosniff"
    );
    assert_eq!(
        metadata_response.headers().get("cache-control").unwrap(),
        "no-store"
    );
    let metadata: serde_json::Value = metadata_response.json().await.unwrap();
    let issuer = metadata["issuer"].as_str().unwrap().to_owned();
    assert_eq!(metadata["code_challenge_methods_supported"][0], "S256");
    assert_eq!(
        metadata["authorization_response_iss_parameter_supported"],
        true
    );
    assert!(metadata["scopes_supported"]
        .as_array()
        .unwrap()
        .contains(&serde_json::Value::String("offline_access".to_owned())));

    let protected: serde_json::Value = http
        .get(format!("{base}/.well-known/oauth-protected-resource"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(protected["scopes_supported"]
        .as_array()
        .unwrap()
        .contains(&serde_json::Value::String("thumble.config".to_owned())));

    let register_response = http
        .post(format!("{base}/register"))
        .json(&serde_json::json!({
            "client_name": "ChatGPT E2E",
            "redirect_uris": [
                "https://chatgpt.example/connector/cb",
                "http://127.0.0.1:34567/callback"
            ],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(register_response.status(), 201);
    let register: serde_json::Value = register_response.json().await.unwrap();
    assert_eq!(register["token_endpoint_auth_method"], "none");
    assert_eq!(
        register["redirect_uris"][0],
        "https://chatgpt.example/connector/cb"
    );
    let client_id = register["client_id"].as_str().unwrap().to_owned();

    let authorize_page = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("state", "st4te"),
            ("scope", "thumble.read thumble.draft"),
            ("resource", resource.as_str()),
            ("code_challenge", "placeholder-challenge-will-be-replaced"),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    // A too-short PKCE challenge is rejected via the standard OAuth error
    // redirect (302 to the registered redirect_uri with error=invalid_request).
    assert_eq!(
        authorize_page.status(),
        302,
        "bad PKCE challenge must fail closed"
    );
    let location = authorize_page
        .headers()
        .get("location")
        .unwrap()
        .to_str()
        .unwrap();
    assert_eq!(callback_values(location, "error"), vec!["invalid_request"]);
    assert_eq!(callback_values(location, "state"), vec!["st4te"]);
    assert_eq!(callback_values(location, "iss"), vec![issuer.clone()]);

    // Every non-None error redirect has already passed exact registration;
    // registered numeric loopback callbacks receive the same OAuth response.
    let loopback_error = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "http://127.0.0.1:34567/callback"),
            ("state", "loopback-state"),
            ("scope", "thumble.read"),
            ("resource", resource.as_str()),
            ("code_challenge", "too-short"),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(loopback_error.status(), 302);
    let loopback_location = loopback_error
        .headers()
        .get("location")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(loopback_location.starts_with("http://127.0.0.1:34567/callback?"));
    assert_eq!(
        callback_values(loopback_location, "iss"),
        vec![issuer.clone()]
    );

    let (verifier, challenge) = pkce_pair();
    let wrong_target = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("state", "wrong-target-state"),
            ("scope", "thumble.config offline_access"),
            ("resource", "https://wrong.example/mcp"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(wrong_target.status(), 302);
    let wrong_target_location = wrong_target
        .headers()
        .get("location")
        .unwrap()
        .to_str()
        .unwrap();
    assert_eq!(
        callback_values(wrong_target_location, "error"),
        vec!["invalid_target"]
    );
    assert_eq!(
        callback_values(wrong_target_location, "iss"),
        vec![issuer.clone()]
    );

    let authorize_page = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("resource", resource.as_str()),
            ("state", "st4te"),
            ("scope", "thumble.config offline_access"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(authorize_page.status(), 200);
    let page = authorize_page.text().await.unwrap();
    assert!(
        page.contains("thumble.read") && page.contains("offline_access"),
        "consent page must show scopes"
    );
    assert!(
        page.contains("Waiting for your Mac") && page.contains("no code needed"),
        "online link windows must get click-to-connect UI: {page}"
    );
    let request_id = match next_frame(&mut link_ws).await {
        TunnelMessage::ConnectorApprovalRequest {
            request_id,
            client_name,
            scope,
            expires_in,
        } => {
            assert_eq!(client_name, "ChatGPT test connector");
            assert!(scope.contains("thumble.config"));
            assert_eq!(
                expires_in,
                thumble_tunnel::protocol::CONNECTOR_APPROVAL_TTL_SECONDS
            );
            request_id
        }
        other => panic!("expected ConnectorApprovalRequest, got {other:?}"),
    };
    assert!(page.contains(&format!("/authorize/wait?request_id={request_id}")));
    assert!(page.contains(&format!("/authorize/code?request_id={request_id}")));
    // Unsigned client-controlled authorization fields are absent; the form
    // carries only an opaque server-side request handle.
    assert!(!page.contains("name=\"redirect_uri\""));
    assert!(!page.contains("name=\"code_challenge\""));

    // The fallback link leaves the polling page for a stable form, so meta
    // refresh cannot discard the code while a headless user types it.
    let fallback_page = http
        .get(format!("{base}/authorize/code"))
        .query(&[("request_id", request_id.as_str())])
        .send()
        .await
        .unwrap();
    assert_eq!(fallback_page.status(), 200);
    let fallback_body = fallback_page.text().await.unwrap();
    assert_eq!(hidden_form_value(&fallback_body, "request_id"), request_id);
    assert!(!fallback_body.contains("http-equiv=\"refresh\""));

    // Wrong code must fail closed, burn nothing, and explain itself ON THE
    // PAGE (with the same request still usable) instead of bouncing the
    // user back to the connector with an opaque OAuth error.
    let wrong = http
        .post(format!("{base}/authorize/confirm"))
        .form(&[("request_id", request_id.as_str()), ("code", "000001")])
        .send()
        .await
        .unwrap();
    assert_eq!(wrong.status(), 200);
    let wrong_body = wrong.text().await.unwrap();
    assert!(
        wrong_body.contains("Link failed"),
        "wrong code must show the in-page error banner: {wrong_body}"
    );
    assert!(wrong_body.contains("not recognized"));
    assert!(
        wrong_body.contains("thumble relay rotate"),
        "the error must name the fix command"
    );
    // The re-rendered form keeps the same request alive and echoes the
    // submitted code so the user can correct it in place.
    assert_eq!(hidden_form_value(&wrong_body, "request_id"), request_id);
    assert!(wrong_body.contains("value=\"000001\""));

    // The browser poll waits while the native dialog is unanswered.
    let waiting = http
        .get(format!("{base}/authorize/wait"))
        .query(&[("request_id", request_id.as_str())])
        .send()
        .await
        .unwrap();
    assert_eq!(waiting.status(), 200);
    let waiting_body = waiting.text().await.unwrap();
    assert!(waiting_body.contains("Waiting for your Mac"));
    assert!(waiting_body.contains(&format!("/authorize/code?request_id={request_id}")));

    // Clicking Allow on the Mac completes this authorization without ever
    // submitting the generated fallback code.
    link_ws
        .send(Message::text(encode_control_message(
            &TunnelMessage::ConnectorApprovalDecision {
                request_id: request_id.clone(),
                approved: true,
            },
        )))
        .await
        .unwrap();
    let wait_http = http.clone();
    let wait_base = base.clone();
    let wait_request = request_id.clone();
    let completion_task = tokio::spawn(async move {
        wait_for_authorization_completion(&wait_http, &wait_base, &wait_request).await
    });
    let _first_link = persist_next_link_grant(&mut link_ws).await;
    let completion_page = completion_task.await.unwrap();
    assert!(completion_page.contains("Thumble linked"));
    let location = completion_callback(&completion_page);
    assert_eq!(callback_values(&location, "state"), vec!["st4te"]);
    assert_eq!(callback_values(&location, "iss"), vec![issuer.clone()]);

    // A browser can leave the consent page visible after the first submit.
    // Make a second click safe and explain that the first submission already
    // completed instead of returning a generic bad-request page.
    let duplicate = http
        .post(format!("{base}/authorize/confirm"))
        .form(&[
            ("request_id", request_id.as_str()),
            ("code", link_code.as_str()),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(duplicate.status(), 409);
    let duplicate_body = duplicate.text().await.unwrap();
    assert!(
        duplicate_body.contains("Link attempt is no longer active"),
        "duplicate submission must be actionable: {duplicate_body}"
    );

    let authorization_code = location
        .split("code=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap()
        .to_owned();

    // OAuth returned only after the simulated relay acknowledged durable
    // token persistence above.
    drop(link_ws);

    // The MCP resource is bound before consuming the authorization code.
    let wrong_resource: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", authorization_code.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("client_id", client_id.as_str()),
            ("resource", "https://wrong.example/mcp"),
            ("code_verifier", verifier.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(wrong_resource["error"], "invalid_target");

    // Wrong PKCE verifier must fail.
    let wrong_pkce: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", authorization_code.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("client_id", client_id.as_str()),
            ("resource", resource.as_str()),
            (
                "code_verifier",
                "wrong-verifier-wrong-verifier-wrong-verifier-wrong-1",
            ),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(wrong_pkce["error"], "invalid_grant", "got {wrong_pkce}");

    // Wrong PKCE must not burn the code; the legitimate verifier can still
    // exchange it exactly once.
    let recovered: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", authorization_code.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("client_id", client_id.as_str()),
            ("resource", resource.as_str()),
            ("code_verifier", verifier.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(recovered["access_token"].is_string(), "got {recovered}");
    let replayed: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", authorization_code.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("client_id", client_id.as_str()),
            ("resource", resource.as_str()),
            ("code_verifier", verifier.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(replayed["error"], "invalid_grant", "got {replayed}");

    // Run the OAuth flow again for a fresh code (link window is gone, so a
    // new anonymous device is required).
    let (link_ws2, _) = tokio_tungstenite::connect_async(format!("{ws_base}/tunnel/link"))
        .await
        .unwrap();
    let mut link_ws2 = link_ws2;
    link_ws2
        .send(Message::text(encode_control_message(
            &TunnelMessage::LinkRequest {
                device_name: "E2E Mac".to_owned(),
            },
        )))
        .await
        .unwrap();
    let link_code2 = match next_frame(&mut link_ws2).await {
        TunnelMessage::LinkOffer { code, url, .. } => {
            assert_eq!(url, format!("{base}/link?code={code}"));
            code
        }
        other => panic!("expected LinkOffer, got {other:?}"),
    };
    // Older compatible clients may omit RFC 8707 resource; the gateway has
    // exactly one protected MCP resource, so omission remains supported.
    let authorize_page = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("state", "st4te"),
            ("scope", "thumble.config offline_access"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(authorize_page.status(), 200);
    let request_id2 = match next_frame(&mut link_ws2).await {
        TunnelMessage::ConnectorApprovalRequest { request_id, .. } => request_id,
        other => panic!("expected ConnectorApprovalRequest, got {other:?}"),
    };
    let confirm_http = http.clone();
    let confirm_base = base.clone();
    let confirm_request = request_id2.clone();
    let confirm_code = link_code2.clone();
    let confirm_task = tokio::spawn(async move {
        confirm_http
            .post(format!("{confirm_base}/authorize/confirm"))
            .form(&[
                ("request_id", confirm_request.as_str()),
                ("code", confirm_code.as_str()),
            ])
            .send()
            .await
            .unwrap()
    });
    let (device_id, device_token) = persist_next_link_grant(&mut link_ws2).await;
    let confirmed = confirm_task.await.unwrap();
    assert_eq!(confirmed.status(), 200);
    let completion_page = confirmed.text().await.unwrap();
    let location = completion_callback(&completion_page);
    let authorization_code = location
        .split("code=")
        .nth(1)
        .unwrap()
        .split('&')
        .next()
        .unwrap()
        .to_owned();
    drop(link_ws2);

    let tokens: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", authorization_code.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("client_id", client_id.as_str()),
            ("resource", resource.as_str()),
            ("code_verifier", verifier.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let access_token = tokens["access_token"].as_str().unwrap().to_owned();
    let refresh_token = tokens["refresh_token"].as_str().unwrap().to_owned();
    assert_eq!(tokens["token_type"], "Bearer");
    assert_eq!(
        tokens["scope"],
        "thumble.config offline_access thumble.draft thumble.read"
    );

    // ---- Device control channel with the complete production manifest ----
    let (manifest_tools, manifest_resources, server_instructions) =
        real_manifest(control_socket.clone()).await;
    let mut control = authorized_ws(&format!("{ws_base}/tunnel"), &device_token).await;
    control
        .send(Message::text(encode_control_message(
            &TunnelMessage::Manifest {
                tools: manifest_tools,
                resources: manifest_resources,
                server_instructions,
            },
        )))
        .await
        .unwrap();

    let mut linked_status = serde_json::Value::Null;
    for _ in 0..50 {
        linked_status = http
            .get(format!("{base}/device/status"))
            .header("Authorization", format!("Bearer {device_token}"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        if linked_status["manifestPublished"] == true {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert_eq!(linked_status["linked"], true);
    assert_eq!(linked_status["online"], true);
    assert_eq!(linked_status["manifestPublished"], true);

    // Serve device sessions on demand with the REAL ThumbleMcp server. The
    // same authenticated control tunnel also answers later click-to-connect
    // approvals without rotating the device token.
    let control_socket_for_sessions = control_socket.clone();
    let device_token_for_sessions = device_token.clone();
    let (approval_policy_sender, mut approval_policy_receiver) =
        tokio::sync::mpsc::channel::<bool>(4);
    let (approval_seen_sender, mut approval_seen_receiver) =
        tokio::sync::mpsc::channel::<(String, String, String)>(4);
    let (approval_result_sender, mut approval_result_receiver) =
        tokio::sync::mpsc::channel::<(String, bool, Option<String>)>(4);
    let device_task = tokio::spawn(async move {
        loop {
            match next_frame(&mut control).await {
                TunnelMessage::OpenSession {
                    session_id,
                    session_url,
                } => {
                    let socket = control_socket_for_sessions.clone();
                    let token = device_token_for_sessions.clone();
                    tokio::spawn(async move {
                        let session_ws = authorized_ws(&session_url, &token).await;
                        let (sink, stream) = split_json_rpc_ws::<rmcp::RoleServer>(session_ws);
                        let transport =
                            rmcp::transport::sink_stream::SinkStreamTransport::new(sink, stream);
                        use rmcp::ServiceExt as _;
                        if let Ok(running) = thumble_mcp::ThumbleMcp::new(socket, false, true)
                            .serve(transport)
                            .await
                        {
                            let _ = running.waiting().await;
                        }
                        let _ = session_id;
                    });
                }
                TunnelMessage::ConnectorApprovalRequest {
                    request_id,
                    client_name,
                    scope,
                    ..
                } => {
                    approval_seen_sender
                        .send((request_id.clone(), client_name, scope))
                        .await
                        .unwrap();
                    let approved = approval_policy_receiver
                        .recv()
                        .await
                        .expect("approval policy for pushed request");
                    control
                        .send(Message::text(encode_control_message(
                            &TunnelMessage::ConnectorApprovalDecision {
                                request_id,
                                approved,
                            },
                        )))
                        .await
                        .unwrap();
                }
                TunnelMessage::ConnectorApprovalResult {
                    request_id,
                    granted,
                    detail,
                } => {
                    approval_result_sender
                        .send((request_id, granted, detail))
                        .await
                        .unwrap();
                }
                TunnelMessage::Ping => {
                    let _ = control
                        .send(Message::text(encode_control_message(&TunnelMessage::Pong)))
                        .await;
                }
                TunnelMessage::CloseSession { .. } => continue,
                other => panic!("unexpected control frame: {other:?}"),
            }
        }
    });

    // ---- /mcp without a token is rejected ----
    let unauthorized = http.post(format!("{base}/mcp")).send().await.unwrap();
    assert_eq!(unauthorized.status(), 401);
    let challenge_header = unauthorized
        .headers()
        .get("www-authenticate")
        .unwrap()
        .to_str()
        .unwrap();
    assert!(challenge_header.contains("oauth-protected-resource"));
    assert!(challenge_header.contains("thumble.config"));
    assert!(challenge_header.contains("offline_access"));

    let oversized = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Content-Type", "application/json")
        .body(vec![b'x'; thumble_tunnel::MAXIMUM_FRAME_BYTES + 1])
        .send()
        .await
        .unwrap();
    assert_eq!(oversized.status(), 413, "MCP body cap must be enforced");

    let disallowed_origin = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Origin", "https://evil.example")
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "origin-test", "version": "1"}
            }
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(disallowed_origin.status(), 403);

    let disallowed_host = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Host", "evil.example")
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "host-test", "version": "1"}
            }
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(disallowed_host.status(), 403);

    // Current ChatGPT clients probe MCP 2026-07-28 with server/discover before
    // listing actions. The official ChatGPT web origin is allowlisted while
    // arbitrary browser origins remain rejected above.
    let modern_meta = serde_json::json!({
        "io.modelcontextprotocol/protocolVersion": "2026-07-28",
        "io.modelcontextprotocol/clientInfo": {
            "name": "ChatGPT",
            "version": "1"
        },
        "io.modelcontextprotocol/clientCapabilities": {}
    });
    let discovery = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Origin", "https://chatgpt.com")
        .header("MCP-Protocol-Version", "2026-07-28")
        .header("MCP-Method", "server/discover")
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": "discover-1",
            "method": "server/discover",
            "params": {"_meta": modern_meta.clone()}
        }))
        .send()
        .await
        .unwrap();
    let discovery_status = discovery.status();
    let discovery_has_session = discovery.headers().get("mcp-session-id").is_some();
    let discovery_body = discovery.text().await.unwrap();
    assert_eq!(
        discovery_status, 200,
        "modern discovery failed: {discovery_body}"
    );
    assert!(
        !discovery_has_session,
        "modern discovery must remain stateless"
    );
    let discovery: serde_json::Value = serde_json::from_str(&discovery_body).unwrap();
    assert_eq!(discovery["id"], "discover-1");
    assert_eq!(discovery["result"]["resultType"], "complete");
    assert!(discovery["result"]["supportedVersions"]
        .as_array()
        .unwrap()
        .iter()
        .any(|version| version == "2026-07-28"));
    assert!(discovery["result"]["capabilities"]["tools"].is_object());
    assert!(discovery["result"]["capabilities"]["resources"].is_object());
    assert_eq!(
        discovery["result"]["_meta"]["io.modelcontextprotocol/serverInfo"]["title"],
        "Thumble MCP Controller"
    );
    assert!(discovery["result"]["instructions"]
        .as_str()
        .unwrap()
        .starts_with("Control a running local Thumble Host"));

    let modern_tools = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Origin", "https://chatgpt.com")
        .header("MCP-Protocol-Version", "2026-07-28")
        .header("MCP-Method", "tools/list")
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": "tools-1",
            "method": "tools/list",
            "params": {"_meta": modern_meta}
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(modern_tools.status(), 200);
    assert!(
        modern_tools.headers().get("mcp-session-id").is_none(),
        "modern action discovery must remain stateless"
    );
    let modern_tools: serde_json::Value = modern_tools.json().await.unwrap();
    assert_eq!(modern_tools["id"], "tools-1");
    assert_eq!(modern_tools["result"]["resultType"], "complete");
    let modern_catalog = modern_tools["result"]["tools"].as_array().unwrap();
    assert_eq!(
        modern_catalog.len(),
        18,
        "complete production catalog minus three local-only tools"
    );
    let modern_catalog_bytes = serde_json::to_vec(modern_catalog).unwrap().len();
    assert!(
        modern_catalog_bytes < 20_000,
        "remote action catalog must remain below ChatGPT's discovery budget: {modern_catalog_bytes} bytes"
    );
    assert!(
        modern_catalog
            .iter()
            .all(|tool| tool.get("outputSchema").is_none()),
        "optional output schemas must not consume remote discovery budget"
    );
    let edit_tool = modern_catalog
        .iter()
        .find(|tool| tool["name"] == "edit_configuration_draft")
        .unwrap();
    assert_eq!(edit_tool["inputSchema"]["additionalProperties"], false);
    assert_eq!(
        edit_tool["inputSchema"]["properties"]["operation"]["properties"]["type"]["enum"]
            .as_array()
            .unwrap()
            .len(),
        63
    );
    let modern_names: Vec<&str> = modern_catalog
        .iter()
        .filter_map(|tool| tool["name"].as_str())
        .collect();
    assert!(modern_names.contains(&"host_status"));
    assert!(modern_names.contains(&"save_configuration_draft"));
    assert!(!modern_names.contains(&"press_control"));

    let modern_call = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Origin", "https://chatgpt.com")
        .header("MCP-Protocol-Version", "2026-07-28")
        .header("MCP-Method", "tools/call")
        .header("MCP-Name", "host_status")
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": "call-1",
            "method": "tools/call",
            "params": {
                "_meta": {
                    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                    "io.modelcontextprotocol/clientInfo": {
                        "name": "ChatGPT",
                        "version": "1"
                    },
                    "io.modelcontextprotocol/clientCapabilities": {}
                },
                "name": "host_status",
                "arguments": {}
            }
        }))
        .send()
        .await
        .unwrap();
    let modern_call_status = modern_call.status();
    let modern_call_body = modern_call.text().await.unwrap();
    assert_eq!(
        modern_call_status, 200,
        "modern tool call failed: {modern_call_body}"
    );
    let modern_call: serde_json::Value = serde_json::from_str(&modern_call_body).unwrap();
    assert_eq!(modern_call["id"], "call-1");
    assert_eq!(modern_call["result"]["resultType"], "complete");
    assert_eq!(
        modern_call["result"]["structuredContent"]["serverId"],
        "e2e-server"
    );

    let modern_transport = StreamableHttpClientTransport::with_client(
        reqwest::Client::new(),
        StreamableHttpClientTransportConfig::with_uri(format!("{base}/mcp"))
            .auth_header(access_token.clone()),
    );
    let modern_client = rmcp::model::ClientInfo::default()
        .serve_with_lifecycle(
            modern_transport,
            ClientLifecycleMode::Discover {
                preferred_versions: vec![rmcp::model::ProtocolVersion::V_2026_07_28],
            },
        )
        .await
        .expect("official modern client discovery");
    let discovered_tools = modern_client
        .list_tools(None)
        .await
        .expect("official modern tools/list");
    assert!(discovered_tools
        .tools
        .iter()
        .any(|tool| tool.name == "host_status"));
    let modern_status = modern_client
        .call_tool(rmcp::model::CallToolRequestParams::new("host_status"))
        .await
        .expect("official modern tools/call");
    assert_eq!(
        modern_status.structured_content.as_ref().unwrap()["serverId"],
        "e2e-server"
    );
    modern_client.cancel().await.unwrap();

    // A valid token cannot replay another token's Mcp-Session-Id. Missing
    // Origin is accepted for native/server-to-server clients such as ChatGPT.
    let initialize = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "identity-binding-test", "version": "1"}
            }
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(initialize.status(), 200);
    let raw_session_id = initialize
        .headers()
        .get("mcp-session-id")
        .expect("MCP session ID")
        .to_str()
        .unwrap()
        .to_owned();
    let initialized = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Mcp-Session-Id", raw_session_id.as_str())
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        }))
        .send()
        .await
        .unwrap();
    assert!(initialized.status().is_success());

    let other_access = state_for_assertions
        .store
        .issue_access_token(
            &device_id,
            "thumble.config offline_access thumble.draft thumble.read",
            900,
        )
        .unwrap();
    let replay = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {other_access}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Mcp-Session-Id", raw_session_id.as_str())
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list",
            "params": {}
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(replay.status(), 403);
    let replay_body = replay.text().await.unwrap();
    assert!(
        replay_body.contains("different token identity"),
        "session identity mismatch must fail closed: {replay_body}"
    );

    let cross_identity_get = http
        .get(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {other_access}"))
        .header("Accept", "text/event-stream")
        .header("Mcp-Session-Id", raw_session_id.as_str())
        .send()
        .await
        .unwrap();
    assert_eq!(cross_identity_get.status(), 403);
    let cross_identity_delete = http
        .delete(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {other_access}"))
        .header("Mcp-Session-Id", raw_session_id.as_str())
        .send()
        .await
        .unwrap();
    assert_eq!(cross_identity_delete.status(), 403);
    let cross_identity_cancel = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {other_access}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Mcp-Session-Id", raw_session_id.as_str())
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "method": "notifications/cancelled",
            "params": {"requestId": 1, "reason": "cross-identity cancellation"}
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(cross_identity_cancel.status(), 403);

    let owner_still_active = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Mcp-Session-Id", raw_session_id.as_str())
        .json(&serde_json::json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/list",
            "params": {}
        }))
        .send()
        .await
        .unwrap();
    let owner_status = owner_still_active.status();
    let owner_body = owner_still_active.text().await.unwrap();
    assert_eq!(owner_status, 200, "owner session failed: {owner_body}");

    let owner_delete = http
        .delete(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {access_token}"))
        .header("Mcp-Session-Id", raw_session_id)
        .send()
        .await
        .unwrap();
    assert!(owner_delete.status().is_success());

    // ---- ChatGPT stand-in: rmcp streamable HTTP client ----
    let limited_access = state_for_assertions
        .store
        .issue_access_token(&device_id, "thumble.draft thumble.read", 900)
        .unwrap();
    let limited_transport = StreamableHttpClientTransport::with_client(
        reqwest::Client::new(),
        StreamableHttpClientTransportConfig::with_uri(format!("{base}/mcp"))
            .auth_header(limited_access),
    );
    let limited_client = ().serve(limited_transport).await.unwrap();
    let limited_tools = limited_client.peer().list_tools(None).await.unwrap();
    assert!(!limited_tools
        .tools
        .iter()
        .any(|tool| tool.name == "save_configuration_draft"));
    let denied = limited_client
        .peer()
        .call_tool(rmcp::model::CallToolRequestParams::new(
            "save_configuration_draft",
        ))
        .await;
    assert!(denied.is_err(), "scope must be enforced before the tunnel");
    limited_client.cancel().await.ok();

    let transport = StreamableHttpClientTransport::with_client(
        reqwest::Client::new(),
        StreamableHttpClientTransportConfig::with_uri(format!("{base}/mcp"))
            .auth_header(access_token.clone()),
    );
    let client = ().serve(transport).await.expect("initialize via gateway");
    let peer_info = client.peer_info().unwrap();
    let server_info = peer_info
        .server_info
        .as_ref()
        .expect("proxy implementation metadata");
    assert_eq!(
        server_info.name, "thumble-relay",
        "proxy must identify itself"
    );
    assert_eq!(server_info.title.as_deref(), Some("Thumble MCP Controller"));
    assert_eq!(
        server_info.website_url.as_deref(),
        Some("https://pocketpad-site.pages.dev")
    );
    let icons = server_info.icons.as_ref().expect("branded server icon");
    assert_eq!(icons.len(), 1);
    assert_eq!(
        icons[0].src,
        "https://pocketpad-site.pages.dev/assets/app-icon.png?v=6eae962e"
    );
    assert_eq!(icons[0].mime_type.as_deref(), Some("image/png"));
    assert_eq!(
        icons[0].sizes.as_deref(),
        Some(["1024x1024".to_owned()].as_slice())
    );

    let tools = client.peer().list_tools(None).await.unwrap();
    assert!(
        tools.result_type.is_none(),
        "legacy tools/list must omit the modern resultType discriminator"
    );
    let names: Vec<String> = tools.tools.iter().map(|t| t.name.to_string()).collect();
    assert!(names.contains(&"host_status".to_owned()), "got {names:?}");
    assert!(
        names.contains(&"save_configuration_draft".to_owned()),
        "config tool must be listed with thumble.config scope: {names:?}"
    );
    assert!(
        !names.contains(&"press_control".to_owned()),
        "locally-blocked tool must never be listed: {names:?}"
    );

    let status = client
        .peer()
        .call_tool(rmcp::model::CallToolRequestParams::new("host_status"))
        .await
        .expect("host_status through the full stack");
    assert!(status.is_error != Some(true), "got {status:?}");
    assert!(
        status.result_type.is_none(),
        "legacy tools/call must omit the modern resultType discriminator"
    );
    let text = serde_json::to_string(&status.structured_content).unwrap_or_default();
    assert!(
        text.contains("thumble-e2e"),
        "expected host data, got {text}"
    );

    let call = |name: &'static str, arguments: serde_json::Value| {
        let client = &client;
        async move {
            client
                .peer()
                .call_tool(
                    rmcp::model::CallToolRequestParams::new(name).with_arguments(
                        arguments
                            .as_object()
                            .expect("tool arguments object")
                            .clone(),
                    ),
                )
                .await
                .unwrap()
        }
    };
    let configuration = call("configuration_status", serde_json::json!({})).await;
    assert_eq!(
        configuration.structured_content.as_ref().unwrap()["configurationRevision"],
        1
    );
    let begun = call(
        "begin_configuration_draft",
        serde_json::json!({"expectedConfigurationRevision": 1}),
    )
    .await;
    let draft_id = begun.structured_content.as_ref().unwrap()["draftId"]
        .as_str()
        .unwrap()
        .to_owned();
    let edited = call(
        "edit_configuration_draft",
        serde_json::json!({
            "draftId": draft_id.clone(),
            "expectedDraftRevision": 1,
            "operationId": "00000000-0000-0000-0000-000000000401",
            "operation": {
                "type": "profile.rename",
                "profileID": "profile-safe",
                "name": "E2E Renamed"
            }
        }),
    )
    .await;
    assert_eq!(
        edited.structured_content.as_ref().unwrap()["draft"]["draftRevision"],
        2
    );
    let validated = call(
        "validate_configuration_draft",
        serde_json::json!({"draftId": draft_id.clone(), "expectedDraftRevision": 2}),
    )
    .await;
    assert_eq!(
        validated.structured_content.as_ref().unwrap()["valid"],
        true
    );
    let previewed = call(
        "preview_configuration_draft",
        serde_json::json!({"draftId": draft_id.clone(), "expectedDraftRevision": 2}),
    )
    .await;
    assert_eq!(
        previewed.structured_content.as_ref().unwrap()["draft"]["draftRevision"],
        2
    );
    let saved = call(
        "save_configuration_draft",
        serde_json::json!({
            "draftId": draft_id,
            "expectedDraftRevision": 2,
            "expectedConfigurationRevision": 1,
            "commitId": "00000000-0000-0000-0000-000000000501"
        }),
    )
    .await;
    assert_eq!(
        saved.structured_content.as_ref().unwrap()["configurationRevision"],
        2
    );
    assert_eq!(
        saved.structured_content.as_ref().unwrap()["phoneSyncQueued"],
        true,
        "save must preserve the phone-delivery boundary"
    );

    // Locally blocked tools are denied outright.
    let blocked = client
        .peer()
        .call_tool(rmcp::model::CallToolRequestParams::new("press_control"))
        .await;
    assert!(blocked.is_err(), "press_control must be remote-blocked");

    client.cancel().await.ok();
    tokio::time::timeout(Duration::from_secs(2), async {
        while state_for_assertions.tunnels.session_count(&device_id) != 0 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("gateway session reservation must be released");

    // ---- Clicking Connect against an already-running background relay ----
    // No pending link window and no fresh device code are required. The
    // authenticated control tunnel receives the approval request, and the
    // resulting OAuth token remains bound to the same device identity.
    approval_policy_sender.send(true).await.unwrap();
    let reconnect_authorize = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("resource", resource.as_str()),
            ("state", "click-connect-online"),
            ("scope", "thumble.read"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(reconnect_authorize.status(), 200);
    let reconnect_page = reconnect_authorize.text().await.unwrap();
    assert!(reconnect_page.contains("Waiting for your Mac"));
    let (reconnect_request, seen_client, seen_scope) =
        tokio::time::timeout(Duration::from_secs(2), approval_seen_receiver.recv())
            .await
            .expect("online device receives connector approval")
            .unwrap();
    assert!(reconnect_page.contains(&reconnect_request));
    assert_eq!(seen_client, "ChatGPT test connector");
    assert_eq!(seen_scope, "thumble.read");
    let reconnect_completion =
        wait_for_authorization_completion(&http, &base, &reconnect_request).await;
    let reconnect_location = completion_callback(&reconnect_completion);
    assert_eq!(
        callback_values(&reconnect_location, "state"),
        vec!["click-connect-online"]
    );
    let reconnect_code = callback_values(&reconnect_location, "code")
        .into_iter()
        .next()
        .unwrap();
    let reconnect_tokens: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", reconnect_code.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("client_id", client_id.as_str()),
            ("resource", resource.as_str()),
            ("code_verifier", verifier.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let reconnect_access = reconnect_tokens["access_token"].as_str().unwrap();
    assert_eq!(
        state_for_assertions
            .store
            .access_token(reconnect_access)
            .unwrap()
            .unwrap()
            .device_id,
        device_id,
        "click-to-connect must reuse the existing device identity"
    );
    let (result_request, result_granted, result_detail) =
        tokio::time::timeout(Duration::from_secs(2), approval_result_receiver.recv())
            .await
            .expect("online device receives approval result")
            .unwrap();
    assert_eq!(result_request, reconnect_request);
    assert!(result_granted);
    assert_eq!(result_detail.as_deref(), Some("ChatGPT connected"));

    // Explicit denial ends the browser wait without issuing an OAuth code.
    approval_policy_sender.send(false).await.unwrap();
    let denied_authorize = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("resource", resource.as_str()),
            ("state", "click-connect-denied"),
            ("scope", "thumble.read"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(denied_authorize.status(), 200);
    let denied_page = denied_authorize.text().await.unwrap();
    let (denied_request, _, _) =
        tokio::time::timeout(Duration::from_secs(2), approval_seen_receiver.recv())
            .await
            .expect("online device receives denial request")
            .unwrap();
    assert!(denied_page.contains(&denied_request));
    let denied_completion = wait_for_authorization_completion(&http, &base, &denied_request).await;
    assert!(denied_completion.contains("Connection declined"));
    assert!(!denied_completion.contains("id=\"oauth-callback\""));
    let (denied_result_request, denied_granted, _) =
        tokio::time::timeout(Duration::from_secs(2), approval_result_receiver.recv())
            .await
            .expect("online device receives denial result")
            .unwrap();
    assert_eq!(denied_result_request, denied_request);
    assert!(!denied_granted);
    assert!(
        state_for_assertions
            .store
            .authorization_request(&denied_request)
            .unwrap()
            .is_err(),
        "Deny must make fallback completion impossible"
    );

    // Connector validation remains available from the persisted manifest
    // while the Mac is offline, but tool calls fail fast.
    device_task.abort();
    tokio::time::timeout(Duration::from_secs(2), async {
        while state_for_assertions.tunnels.device_online(&device_id) {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("device control channel must unregister");
    let offline_status: serde_json::Value = http
        .get(format!("{base}/device/status"))
        .header("Authorization", format!("Bearer {device_token}"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(offline_status["online"], false);
    let offline_transport = StreamableHttpClientTransport::with_client(
        reqwest::Client::new(),
        StreamableHttpClientTransportConfig::with_uri(format!("{base}/mcp"))
            .auth_header(access_token.clone()),
    );
    let offline_client = ().serve(offline_transport).await.unwrap();
    let offline_tools = offline_client.peer().list_tools(None).await.unwrap();
    assert!(offline_tools
        .tools
        .iter()
        .any(|tool| tool.name == "host_status"));
    assert!(offline_client
        .peer()
        .call_tool(rmcp::model::CallToolRequestParams::new("host_status"))
        .await
        .is_err());
    offline_client.cancel().await.ok();

    // ---- Device-token rotation in place while the relay is linked ----
    //
    // `thumble relay rotate` authenticates the link socket with the current
    // device token, so the gateway replaces the credential of the SAME device
    // (keeping its OAuth bindings, manifest, and identity) instead of minting
    // a second identity for one Mac, and the old token dies the moment the
    // new one is granted.
    let mut active_control = authorized_ws(&format!("{ws_base}/tunnel"), &device_token).await;
    let mut rotate_link = authorized_ws(&format!("{ws_base}/tunnel/link"), &device_token).await;
    rotate_link
        .send(Message::text(encode_control_message(
            &TunnelMessage::LinkRequest {
                device_name: "E2E Mac Rotated".to_owned(),
            },
        )))
        .await
        .unwrap();
    let rotate_code = match next_frame(&mut rotate_link).await {
        TunnelMessage::LinkOffer { code, url, .. } => {
            assert_eq!(url, format!("{base}/link?code={code}"));
            code
        }
        other => panic!("expected rotation LinkOffer, got {other:?}"),
    };
    let rotation_authorize = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://chatgpt.example/connector/cb"),
            ("state", "rot4te"),
            ("scope", "thumble.config offline_access"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(rotation_authorize.status(), 200);
    let rotation_page = rotation_authorize.text().await.unwrap();
    assert!(rotation_page.contains("Waiting for your Mac"));
    let rotation_request = match next_frame(&mut rotate_link).await {
        TunnelMessage::ConnectorApprovalRequest { request_id, .. } => request_id,
        other => panic!("expected ConnectorApprovalRequest, got {other:?}"),
    };
    assert!(rotation_page.contains(&rotation_request));
    let rotation_http = http.clone();
    let rotation_base = base.clone();
    let rotation_request_for_task = rotation_request.clone();
    let rotate_code_for_task = rotate_code.clone();
    let rotation_task = tokio::spawn(async move {
        rotation_http
            .post(format!("{rotation_base}/authorize/confirm"))
            .form(&[
                ("request_id", rotation_request_for_task.as_str()),
                ("code", rotate_code_for_task.as_str()),
            ])
            .send()
            .await
            .unwrap()
    });
    let (granted_device, rotated_token) = persist_next_link_grant(&mut rotate_link).await;
    assert_eq!(
        granted_device, device_id,
        "rotation must keep the device identity"
    );
    assert!(matches!(
        next_frame(&mut active_control).await,
        TunnelMessage::ReconnectRequired { .. }
    ));
    let rotation_confirm = rotation_task.await.unwrap();
    assert_eq!(rotation_confirm.status(), 200);
    let rotation_completion = rotation_confirm.text().await.unwrap();
    assert!(
        rotation_completion.contains("E2E Mac Rotated"),
        "completion page should name the linked device: {rotation_completion}"
    );
    assert_ne!(rotated_token, device_token);

    // The old credential stops working immediately — no dual-valid window.
    let mut stale_request = format!("{ws_base}/tunnel").into_client_request().unwrap();
    stale_request.headers_mut().insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {device_token}")).unwrap(),
    );
    assert!(
        tokio_tungstenite::connect_async(stale_request)
            .await
            .is_err(),
        "the previous device token must be rejected"
    );
    let mut stale_link_request = format!("{ws_base}/tunnel/link")
        .into_client_request()
        .unwrap();
    stale_link_request.headers_mut().insert(
        "Authorization",
        HeaderValue::from_str(&format!("Bearer {device_token}")).unwrap(),
    );
    assert!(
        tokio_tungstenite::connect_async(stale_link_request)
            .await
            .is_err(),
        "dead tokens must not open link sockets"
    );

    // Emulate the serving relay noticing the atomic token-file replacement:
    // drop the stale control channel, reconnect with the rotated credential,
    // re-publish the manifest, and keep serving sessions.
    drop(active_control);
    tokio::time::timeout(Duration::from_secs(2), async {
        while state_for_assertions.tunnels.device_online(&device_id) {
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("stale control channel must unregister");
    let (rotated_tools, rotated_resources, rotated_instructions) =
        real_manifest(control_socket.clone()).await;
    let mut rotated_control = authorized_ws(&format!("{ws_base}/tunnel"), &rotated_token).await;
    rotated_control
        .send(Message::text(encode_control_message(
            &TunnelMessage::Manifest {
                tools: rotated_tools,
                resources: rotated_resources,
                server_instructions: rotated_instructions,
            },
        )))
        .await
        .unwrap();
    tokio::time::timeout(Duration::from_secs(2), async {
        while !state_for_assertions.tunnels.device_online(&device_id) {
            tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        }
    })
    .await
    .expect("rotated control channel must register");
    let mut rotated_status = serde_json::Value::Null;
    for _ in 0..200 {
        rotated_status = http
            .get(format!("{base}/device/status"))
            .header("Authorization", format!("Bearer {rotated_token}"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        if rotated_status["manifestPublished"] == true {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
    }
    assert_eq!(rotated_status["linked"], true);
    assert_eq!(rotated_status["online"], true);
    assert_eq!(rotated_status["manifestPublished"], true);
    assert_eq!(rotated_status["deviceName"], "E2E Mac Rotated");

    // Existing OAuth access tokens keep working through the rotated link.
    let control_socket_for_rotated = control_socket.clone();
    let rotated_token_for_sessions = rotated_token.clone();
    let active_relay_task = tokio::spawn(async move {
        loop {
            match next_frame(&mut rotated_control).await {
                TunnelMessage::OpenSession {
                    session_id,
                    session_url,
                } => {
                    let socket = control_socket_for_rotated.clone();
                    let token = rotated_token_for_sessions.clone();
                    tokio::spawn(async move {
                        let session_ws = authorized_ws(&session_url, &token).await;
                        let (sink, stream) = split_json_rpc_ws::<rmcp::RoleServer>(session_ws);
                        let transport =
                            rmcp::transport::sink_stream::SinkStreamTransport::new(sink, stream);
                        use rmcp::ServiceExt as _;
                        if let Ok(running) = thumble_mcp::ThumbleMcp::new(socket, false, true)
                            .serve(transport)
                            .await
                        {
                            let _ = running.waiting().await;
                        }
                        let _ = session_id;
                    });
                }
                TunnelMessage::Ping => {
                    let _ = rotated_control
                        .send(Message::text(encode_control_message(&TunnelMessage::Pong)))
                        .await;
                }
                TunnelMessage::RevokeGranted { .. } => break,
                TunnelMessage::CloseSession { .. } => continue,
                other => panic!("unexpected rotated relay frame: {other:?}"),
            }
        }
    });
    let rotated_transport = StreamableHttpClientTransport::with_client(
        reqwest::Client::new(),
        StreamableHttpClientTransportConfig::with_uri(format!("{base}/mcp"))
            .auth_header(access_token.clone()),
    );
    let rotated_client = ().serve(rotated_transport).await.unwrap();
    rotated_client
        .peer()
        .call_tool(rmcp::model::CallToolRequestParams::new("host_status"))
        .await
        .expect("tool call through the rotated link");
    rotated_client.cancel().await.ok();

    // ---- Refresh rotation + reuse detection ----
    let rotated: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token.as_str()),
            ("client_id", client_id.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let new_access = rotated["access_token"].as_str().unwrap().to_owned();
    let new_refresh = rotated["refresh_token"].as_str().unwrap().to_owned();
    assert_ne!(new_access, access_token);

    let replay: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh_token.as_str()),
            ("client_id", client_id.as_str()),
            ("resource", resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(replay["error"], "invalid_grant", "reuse must be detected");

    // Family revocation: the rotated tokens are now dead too.
    let dead: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", new_refresh.as_str()),
            ("client_id", client_id.as_str()),
            ("resource", resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(dead["error"], "invalid_grant", "family must be revoked");
    let revoked_check = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {new_access}"))
        .header("Content-Type", "application/json")
        .body("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}")
        .send()
        .await
        .unwrap();
    assert_eq!(revoked_check.status(), 401, "revoked family token must 401");

    let mut revoke_socket =
        authorized_ws(&format!("{ws_base}/tunnel/revoke"), &rotated_token).await;
    revoke_socket
        .send(Message::text(encode_control_message(
            &TunnelMessage::RevokeRequest,
        )))
        .await
        .unwrap();
    assert!(matches!(
        next_frame(&mut revoke_socket).await,
        TunnelMessage::RevokeGranted { .. }
    ));
    tokio::time::timeout(Duration::from_secs(2), active_relay_task)
        .await
        .expect("active relay receives revocation")
        .unwrap();
    assert!(state_for_assertions
        .store
        .device_for_token(&rotated_token)
        .unwrap()
        .is_none());

    server_task.abort();
    let _ = host_shutdown_tx.send(true);
    let _ = host_task.await;
    thumble_host::control::remove_control_socket(&control_socket);
}

async fn complete_builder_consent(
    http: &reqwest::Client,
    base: &str,
    client_id: &str,
    scope: Option<&str>,
    oauth_state: &str,
) -> (String, String, String) {
    let (_, challenge) = pkce_pair();
    let resource = format!("{base}/builder/mcp");
    let mut query = vec![
        ("response_type", "code"),
        ("client_id", client_id),
        ("redirect_uri", "https://builder.example/callback"),
        ("state", oauth_state),
        ("resource", resource.as_str()),
        ("code_challenge", challenge.as_str()),
        ("code_challenge_method", "S256"),
    ];
    if let Some(scope) = scope {
        query.push(("scope", scope));
    }
    let consent = http
        .get(format!("{base}/authorize"))
        .query(&query)
        .send()
        .await
        .unwrap();
    assert_eq!(consent.status(), 200);
    let cookie = builder_consent_cookie(&consent);
    let consent = consent.text().await.unwrap();
    assert!(consent.contains("Authorize Thumble Builder"));
    assert!(consent.contains("action=\"/authorize/builder/confirm\""));
    assert!(!consent.contains("six-digit"));
    assert!(!consent.contains("consent_nonce"));
    let request_id = hidden_form_value(&consent, "request_id");
    assert!(!consent.contains(&cookie));
    let confirmed = http
        .post(format!("{base}/authorize/builder/confirm"))
        .header("Origin", base)
        .header("Cookie", &cookie)
        .form(&[("request_id", request_id.as_str()), ("decision", "allow")])
        .send()
        .await
        .unwrap();
    assert_eq!(confirmed.status(), 302);
    assert!(confirmed
        .headers()
        .get("set-cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .contains("Max-Age=0"));
    let location = confirmed
        .headers()
        .get("location")
        .unwrap()
        .to_str()
        .unwrap();
    assert_eq!(callback_values(location, "state"), vec![oauth_state]);
    assert_eq!(callback_values(location, "iss"), vec![base]);
    let code = callback_values(location, "code")
        .into_iter()
        .next()
        .unwrap();
    (request_id, code, cookie)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn builder_oauth_is_resource_isolated_without_a_device_or_tunnel() {
    let store = Arc::new(Store::open_in_memory().unwrap().with_refresh_grace(0));
    let state = Arc::new(AppState::new(
        store,
        TunnelRegistry::new(),
        "http://placeholder.invalid".to_owned(),
    ));
    let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = tcp.local_addr().unwrap().port();
    let base = format!("http://127.0.0.1:{port}");
    state.set_base_url(base.clone());
    let assertions = state.clone();
    let server = tokio::spawn(async move {
        axum::serve(
            tcp,
            thumble_gateway::app(state)
                .into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )
        .await
        .unwrap();
    });
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    let relay_resource = format!("{base}/mcp");
    let builder_resource = format!("{base}/builder/mcp");

    let authorization_metadata: serde_json::Value = http
        .get(format!("{base}/.well-known/oauth-authorization-server"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(authorization_metadata["issuer"], base);
    let advertised_scopes = authorization_metadata["scopes_supported"]
        .as_array()
        .unwrap();
    for scope in [
        "thumble.read",
        "thumble.draft",
        "thumble.config",
        "thumble.build",
        "offline_access",
    ] {
        assert!(advertised_scopes.contains(&serde_json::Value::String(scope.to_owned())));
    }
    let relay_metadata: serde_json::Value = http
        .get(format!("{base}/.well-known/oauth-protected-resource"))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(relay_metadata["resource"], relay_resource);
    assert!(!relay_metadata["scopes_supported"]
        .as_array()
        .unwrap()
        .contains(&serde_json::Value::String("thumble.build".to_owned())));
    let builder_metadata: serde_json::Value = http
        .get(format!(
            "{base}/.well-known/oauth-protected-resource/builder/mcp"
        ))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(builder_metadata["resource"], builder_resource);
    assert_eq!(
        builder_metadata["scopes_supported"],
        serde_json::json!(["thumble.build", "offline_access"])
    );

    let register: serde_json::Value = http
        .post(format!("{base}/register"))
        .json(&serde_json::json!({
            "client_name": "Builder OAuth E2E",
            "redirect_uris": ["https://builder.example/callback"],
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"]
        }))
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let client_id = register["client_id"].as_str().unwrap().to_owned();
    let (verifier, challenge) = pkce_pair();

    // Missing resource remains the relay compatibility flow, while every
    // unknown resource and every cross-resource scope mix is rejected.
    let omitted_resource = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("scope", "thumble.read"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(omitted_resource.status(), 200);
    let omitted_resource = omitted_resource.text().await.unwrap();
    assert!(omitted_resource.contains("Link your Mac's Thumble controller"));
    let relay_request_id = hidden_form_value(&omitted_resource, "request_id");
    // The builder resource tolerates shared-issuer scope unions: relay scopes
    // are filtered out (never granted) and the builder consent page is shown.
    let union_scopes = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("state", "union"),
            ("resource", builder_resource.as_str()),
            ("scope", "thumble.build thumble.read"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(union_scopes.status(), 200);
    let union_page = union_scopes.text().await.unwrap();
    assert!(union_page.contains("thumble.build"));
    assert!(
        !union_page.contains("thumble.read"),
        "the consent page must show only builder scopes, never relay scopes"
    );
    for (resource, scope) in [
        (relay_resource.as_str(), "thumble.build"),
        ("https://wrong.example/mcp", "thumble.build"),
        (builder_resource.as_str(), "thumble.nonsense"),
    ] {
        let rejected = http
            .get(format!("{base}/authorize"))
            .query(&[
                ("response_type", "code"),
                ("client_id", client_id.as_str()),
                ("redirect_uri", "https://builder.example/callback"),
                ("state", "rejected"),
                ("resource", resource),
                ("scope", scope),
                ("code_challenge", challenge.as_str()),
                ("code_challenge_method", "S256"),
            ])
            .send()
            .await
            .unwrap();
        assert_eq!(rejected.status(), 302);
        let location = rejected
            .headers()
            .get("location")
            .unwrap()
            .to_str()
            .unwrap();
        assert!(matches!(
            callback_values(location, "error").as_slice(),
            [error] if error == "invalid_request" || error == "invalid_target"
        ));
    }

    // Builder confirmation is bound to the exact browser consent cookie and
    // same gateway origin. Rejected detached/cross-site submissions neither
    // consume the request nor make a relay request eligible for this route.
    let protected_page = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("state", "protected-state"),
            ("resource", builder_resource.as_str()),
            ("scope", "thumble.build"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    let protected_cookie = builder_consent_cookie(&protected_page);
    let protected_html = protected_page.text().await.unwrap();
    let protected_request = hidden_form_value(&protected_html, "request_id");
    let confirm_url = format!("{base}/authorize/builder/confirm");
    let form = [
        ("request_id", protected_request.as_str()),
        ("decision", "allow"),
    ];

    let missing_cookie = http
        .post(&confirm_url)
        .header("Origin", &base)
        .form(&form)
        .send()
        .await
        .unwrap();
    assert_eq!(missing_cookie.status(), 403);
    let wrong_cookie = http
        .post(&confirm_url)
        .header("Origin", &base)
        .header(
            "Cookie",
            format!("thumble_builder_consent={}", "A".repeat(64)),
        )
        .form(&form)
        .send()
        .await
        .unwrap();
    assert_eq!(wrong_cookie.status(), 403);
    let malformed_cookie = http
        .post(&confirm_url)
        .header("Origin", &base)
        .header("Cookie", "thumble_builder_consent=not-valid!")
        .form(&form)
        .send()
        .await
        .unwrap();
    assert_eq!(malformed_cookie.status(), 403);
    let missing_origin = http
        .post(&confirm_url)
        .header("Cookie", &protected_cookie)
        .form(&form)
        .send()
        .await
        .unwrap();
    assert_eq!(missing_origin.status(), 403);
    for origin in ["https://cross-site.example", "not an origin"] {
        let rejected = http
            .post(&confirm_url)
            .header("Origin", origin)
            .header("Cookie", &protected_cookie)
            .form(&form)
            .send()
            .await
            .unwrap();
        assert_eq!(rejected.status(), 403);
    }
    let detached = http.post(&confirm_url).form(&form).send().await.unwrap();
    assert_eq!(detached.status(), 403);
    let relay_at_builder_confirm = http
        .post(&confirm_url)
        .header("Origin", &base)
        .header("Cookie", &protected_cookie)
        .form(&[
            ("request_id", relay_request_id.as_str()),
            ("decision", "allow"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(relay_at_builder_confirm.status(), 403);
    assert!(assertions
        .store
        .authorization_request(&relay_request_id)
        .unwrap()
        .is_ok());

    let protected_allow = http
        .post(&confirm_url)
        .header("Origin", &base)
        .header("Cookie", &protected_cookie)
        .form(&form)
        .send()
        .await
        .unwrap();
    assert_eq!(protected_allow.status(), 302);
    assert_eq!(
        callback_values(
            protected_allow
                .headers()
                .get("location")
                .unwrap()
                .to_str()
                .unwrap(),
            "state"
        ),
        vec!["protected-state"]
    );
    let protected_replay = http
        .post(&confirm_url)
        .header("Origin", &base)
        .header("Cookie", &protected_cookie)
        .form(&form)
        .send()
        .await
        .unwrap();
    assert_eq!(protected_replay.status(), 409);

    // Denial consumes the request without creating a principal or code.
    let deny_page = http
        .get(format!("{base}/authorize"))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("state", "deny-state"),
            ("resource", builder_resource.as_str()),
            ("scope", "thumble.build"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    let deny_cookie = builder_consent_cookie(&deny_page);
    let deny_page = deny_page.text().await.unwrap();
    let denied_request = hidden_form_value(&deny_page, "request_id");
    let denied = http
        .post(format!("{base}/authorize/builder/confirm"))
        .header("Origin", &base)
        .header("Cookie", &deny_cookie)
        .form(&[
            ("request_id", denied_request.as_str()),
            ("decision", "deny"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(denied.status(), 302);
    assert!(denied
        .headers()
        .get("set-cookie")
        .unwrap()
        .to_str()
        .unwrap()
        .contains("Max-Age=0"));
    let denied_location = denied.headers().get("location").unwrap().to_str().unwrap();
    assert_eq!(
        callback_values(denied_location, "error"),
        vec!["access_denied"]
    );
    let denied_again = http
        .post(format!("{base}/authorize/builder/confirm"))
        .header("Origin", &base)
        .header("Cookie", &deny_cookie)
        .form(&[
            ("request_id", denied_request.as_str()),
            ("decision", "allow"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(denied_again.status(), 409);

    let (first_request, first_code, first_cookie) = complete_builder_consent(
        &http,
        &base,
        &client_id,
        Some("thumble.build offline_access"),
        "builder-one",
    )
    .await;
    assert_eq!(assertions.tunnels.device_count(), 0);
    let used_again = http
        .post(format!("{base}/authorize/builder/confirm"))
        .header("Origin", &base)
        .header("Cookie", &first_cookie)
        .form(&[
            ("request_id", first_request.as_str()),
            ("decision", "allow"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(used_again.status(), 409);

    // A builder code cannot omit or switch its audience. Failed audience
    // checks do not burn the code, so the exact builder resource still works.
    for resource in [None, Some(relay_resource.as_str())] {
        let mut form = vec![
            ("grant_type", "authorization_code"),
            ("code", first_code.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("client_id", client_id.as_str()),
            ("code_verifier", verifier.as_str()),
        ];
        if let Some(resource) = resource {
            form.push(("resource", resource));
        }
        let rejected: serde_json::Value = http
            .post(format!("{base}/token"))
            .form(&form)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap();
        assert_eq!(rejected["error"], "invalid_grant");
    }
    let unknown_target: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", first_code.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("client_id", client_id.as_str()),
            ("code_verifier", verifier.as_str()),
            ("resource", "https://wrong.example/mcp"),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(unknown_target["error"], "invalid_target");
    let first_tokens: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", first_code.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("client_id", client_id.as_str()),
            ("code_verifier", verifier.as_str()),
            ("resource", builder_resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(first_tokens["scope"], "thumble.build offline_access");
    let first_access = first_tokens["access_token"].as_str().unwrap().to_owned();
    let first_refresh = first_tokens["refresh_token"].as_str().unwrap().to_owned();
    let first_identity = assertions
        .store
        .access_token_for_resource(&first_access, ResourceKind::Builder)
        .unwrap()
        .unwrap()
        .binding
        .principal;
    assert!(first_identity.id.starts_with("bpr_"));

    let omitted_refresh: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", first_refresh.as_str()),
            ("client_id", client_id.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(omitted_refresh["error"], "invalid_grant");
    let rotated: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", first_refresh.as_str()),
            ("client_id", client_id.as_str()),
            ("resource", builder_resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let rotated_access = rotated["access_token"].as_str().unwrap().to_owned();
    let rotated_identity = assertions
        .store
        .access_token_for_resource(&rotated_access, ResourceKind::Builder)
        .unwrap()
        .unwrap()
        .binding
        .principal;
    assert_eq!(rotated_identity, first_identity);

    // Fresh consent creates a distinct principal; omission of scope defaults
    // to build without granting refresh access.
    let (_, second_code, _) =
        complete_builder_consent(&http, &base, &client_id, None, "builder-two").await;
    let second_tokens: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", second_code.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("client_id", client_id.as_str()),
            ("code_verifier", verifier.as_str()),
            ("resource", builder_resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(second_tokens["scope"], "thumble.build");
    assert!(second_tokens.get("refresh_token").is_none());
    let second_access = second_tokens["access_token"].as_str().unwrap().to_owned();
    let second_identity = assertions
        .store
        .access_token_for_resource(&second_access, ResourceKind::Builder)
        .unwrap()
        .unwrap()
        .binding
        .principal;
    assert_ne!(second_identity, first_identity);

    // Relay omission still exchanges a relay code. Each bearer gate rejects
    // the other resource with its own exact RFC 9728 challenge.
    let (device_id, _) = assertions.store.create_device("Isolation relay").unwrap();
    let relay_code = assertions
        .store
        .create_auth_code(
            &client_id,
            "https://builder.example/callback",
            "thumble.read offline_access",
            &challenge,
            &device_id,
            60,
        )
        .unwrap();
    let relay_wrong_audience: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", relay_code.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("client_id", client_id.as_str()),
            ("code_verifier", verifier.as_str()),
            ("resource", builder_resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(relay_wrong_audience["error"], "invalid_grant");
    let relay_tokens: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", relay_code.as_str()),
            ("redirect_uri", "https://builder.example/callback"),
            ("client_id", client_id.as_str()),
            ("code_verifier", verifier.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    let relay_access = relay_tokens["access_token"].as_str().unwrap().to_owned();
    let relay_refresh = relay_tokens["refresh_token"].as_str().unwrap();
    let relay_refresh_wrong_audience: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", relay_refresh),
            ("client_id", client_id.as_str()),
            ("resource", builder_resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(relay_refresh_wrong_audience["error"], "invalid_grant");
    let relay_refresh_omitted: serde_json::Value = http
        .post(format!("{base}/token"))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", relay_refresh),
            ("client_id", client_id.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert!(relay_refresh_omitted["access_token"].is_string());

    let relay_without_token = http.post(format!("{base}/mcp")).send().await.unwrap();
    assert_eq!(relay_without_token.status(), 401);
    let relay_challenge = format!(
        "Bearer error=\"invalid_token\", resource_metadata=\"{base}/.well-known/oauth-protected-resource\", scope=\"thumble.read thumble.draft thumble.config offline_access\""
    );
    assert_eq!(
        relay_without_token
            .headers()
            .get("www-authenticate")
            .unwrap()
            .to_str()
            .unwrap(),
        relay_challenge
    );
    let builder_without_token = http
        .post(format!("{base}/builder/mcp"))
        .send()
        .await
        .unwrap();
    assert_eq!(builder_without_token.status(), 401);
    let builder_challenge = format!(
        "Bearer error=\"invalid_token\", resource_metadata=\"{base}/.well-known/oauth-protected-resource/builder/mcp\", scope=\"thumble.build\""
    );
    assert_eq!(
        builder_without_token
            .headers()
            .get("www-authenticate")
            .unwrap()
            .to_str()
            .unwrap(),
        builder_challenge
    );
    let builder_on_relay = http
        .post(format!("{base}/mcp"))
        .header("Authorization", format!("Bearer {second_access}"))
        .send()
        .await
        .unwrap();
    assert_eq!(builder_on_relay.status(), 401);
    assert_eq!(
        builder_on_relay
            .headers()
            .get("www-authenticate")
            .unwrap()
            .to_str()
            .unwrap(),
        relay_challenge
    );
    let relay_on_builder = http
        .post(format!("{base}/builder/mcp"))
        .header("Authorization", format!("Bearer {relay_access}"))
        .send()
        .await
        .unwrap();
    assert_eq!(relay_on_builder.status(), 401);
    assert_eq!(
        relay_on_builder
            .headers()
            .get("www-authenticate")
            .unwrap()
            .to_str()
            .unwrap(),
        builder_challenge
    );
    // A valid builder bearer now reaches the isolated Streamable HTTP
    // service. An empty POST is not an MCP request and is rejected by the
    // transport rather than by the former Stage B placeholder.
    let builder_transport_rejection = http
        .post(format!("{base}/builder/mcp"))
        .header("Authorization", format!("Bearer {second_access}"))
        .send()
        .await
        .unwrap();
    assert_eq!(builder_transport_rejection.status(), 406);
    let rejection_body = builder_transport_rejection.text().await.unwrap();
    assert!(rejection_body.len() < 256);
    assert!(!rejection_body.contains("tools"));

    assertions
        .store
        .revoke_builder_principal(&first_identity.id)
        .unwrap();
    let revoked_builder = http
        .post(format!("{base}/builder/mcp"))
        .header("Authorization", format!("Bearer {rotated_access}"))
        .send()
        .await
        .unwrap();
    assert_eq!(revoked_builder.status(), 401);
    assert!(assertions
        .store
        .access_token_for_resource(&second_access, ResourceKind::Builder)
        .unwrap()
        .is_some());
    assert!(assertions
        .store
        .access_token(&relay_access)
        .unwrap()
        .is_some());

    server.abort();
}
