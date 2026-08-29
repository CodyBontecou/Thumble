//! Full tunnel-free hosted-builder acceptance over real loopback HTTP and the
//! rmcp Streamable HTTP client. The relay e2e remains in `e2e.rs`.

use std::sync::Arc;
use std::time::Duration;

use base64::Engine as _;
use rmcp::model::{
    CallToolRequestParams, CallToolResult, ClientCapabilities, Implementation, RequestMetaObject,
};
use rmcp::transport::streamable_http_client::{
    StreamableHttpClientTransport, StreamableHttpClientTransportConfig,
};
use rmcp::ServiceExt as _;
use serde_json::{Map, Value};
use sha2::{Digest as _, Sha256};
use thumble_gateway::builder::{BUILDER_TOOL_CATALOG_MAXIMUM_BYTES, BUILDER_TOOL_MAXIMUM_BYTES};
use thumble_gateway::builder_store::BuilderStoreError;
use thumble_gateway::principal::ResourceKind;
use thumble_gateway::state::AppState;
use thumble_gateway::store::Store;
use thumble_gateway::tunnel::TunnelRegistry;

const REDIRECT_URI: &str = "https://builder.example/callback";
const MALICIOUS: &str = "<script>credential-owner-device-tunnel-/etc/passwd</script>";

struct Gateway {
    base: String,
    state: Arc<AppState>,
    database: std::path::PathBuf,
    task: tokio::task::JoinHandle<()>,
    _directory: tempfile::TempDir,
}

impl Gateway {
    async fn start() -> Self {
        let directory = tempfile::tempdir().unwrap();
        let database = directory.path().join("builder-e2e.db");
        let store =
            Arc::new(Store::open(&database, "builder-e2e-secret-with-at-least-32-bytes").unwrap());
        let state = Arc::new(AppState::new(
            store,
            TunnelRegistry::new(),
            "http://placeholder.invalid".to_owned(),
        ));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        state.set_base_url(base.clone());
        let app_state = state.clone();
        let task = tokio::spawn(async move {
            axum::serve(
                listener,
                thumble_gateway::app(app_state)
                    .into_make_service_with_connect_info::<std::net::SocketAddr>(),
            )
            .await
            .unwrap();
        });
        Self {
            base,
            state,
            database,
            task,
            _directory: directory,
        }
    }
}

impl Drop for Gateway {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn args(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

async fn call_ok(
    peer: &rmcp::service::Peer<rmcp::RoleClient>,
    name: &'static str,
    value: Value,
) -> CallToolResult {
    peer.call_tool(CallToolRequestParams::new(name).with_arguments(args(value)))
        .await
        .unwrap()
}

async fn call_error(
    peer: &rmcp::service::Peer<rmcp::RoleClient>,
    name: &'static str,
    value: Value,
) -> String {
    let error = peer
        .call_tool(CallToolRequestParams::new(name).with_arguments(args(value)))
        .await
        .unwrap_err()
        .to_string();
    assert!(error.len() <= 1024, "unbounded tool error: {error}");
    assert!(!error.contains(MALICIOUS), "tool error reflected input");
    error
}

fn hidden_value(html: &str, name: &str) -> String {
    let marker = format!("name=\"{name}\" value=\"");
    html.split(&marker)
        .nth(1)
        .and_then(|rest| rest.split('"').next())
        .unwrap()
        .to_owned()
}

fn callback_value(location: &str, name: &str) -> String {
    url::Url::parse(location)
        .unwrap()
        .query_pairs()
        .find(|(key, _)| key == name)
        .unwrap()
        .1
        .into_owned()
}

fn pkce() -> (String, String) {
    let verifier = "builder-e2e-verifier-builder-e2e-verifier-123456789".to_owned();
    let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .encode(Sha256::digest(verifier.as_bytes()));
    (verifier, challenge)
}

struct Authorization {
    access: String,
    refresh: String,
    client_id: String,
    principal_id: String,
}

async fn authorize(http: &reqwest::Client, gateway: &Gateway, label: &str) -> Authorization {
    let resource = format!("{}/builder/mcp", gateway.base);
    let register = http
        .post(format!("{}/register", gateway.base))
        .json(&serde_json::json!({
            "client_name":label,
            "redirect_uris":[REDIRECT_URI],
            "token_endpoint_auth_method":"none",
            "grant_types":["authorization_code","refresh_token"],
            "response_types":["code"]
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(register.status(), 201);
    let client_id = register.json::<Value>().await.unwrap()["client_id"]
        .as_str()
        .unwrap()
        .to_owned();
    let (verifier, challenge) = pkce();
    let consent = http
        .get(format!("{}/authorize", gateway.base))
        .query(&[
            ("response_type", "code"),
            ("client_id", client_id.as_str()),
            ("redirect_uri", REDIRECT_URI),
            ("state", label),
            ("resource", resource.as_str()),
            ("scope", "thumble.build offline_access"),
            ("code_challenge", challenge.as_str()),
            ("code_challenge_method", "S256"),
        ])
        .send()
        .await
        .unwrap();
    assert_eq!(consent.status(), 200);
    let cookie = consent.headers()["set-cookie"]
        .to_str()
        .unwrap()
        .split(';')
        .next()
        .unwrap()
        .to_owned();
    assert!(consent.headers()["set-cookie"]
        .to_str()
        .unwrap()
        .contains("SameSite=Lax"));
    let html = consent.text().await.unwrap();
    assert!(html.contains("Authorize Thumble Builder"));
    let request_id = hidden_value(&html, "request_id");

    // Consent is bound to both the scoped cookie and the gateway origin.
    assert_eq!(
        http.post(format!("{}/authorize/builder/confirm", gateway.base))
            .header("Cookie", &cookie)
            .form(&[("request_id", request_id.as_str()), ("decision", "allow")])
            .send()
            .await
            .unwrap()
            .status(),
        403
    );
    let confirmed = http
        .post(format!("{}/authorize/builder/confirm", gateway.base))
        .header("Origin", &gateway.base)
        .header("Cookie", cookie)
        .form(&[("request_id", request_id.as_str()), ("decision", "allow")])
        .send()
        .await
        .unwrap();
    assert_eq!(confirmed.status(), 302);
    let location = confirmed.headers()["location"].to_str().unwrap();
    assert_eq!(callback_value(location, "state"), label);
    let code = callback_value(location, "code");

    // Builder codes cannot be exchanged at the relay audience and a failed
    // audience check does not consume the code.
    let rejected = http
        .post(format!("{}/token", gateway.base))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code.as_str()),
            ("redirect_uri", REDIRECT_URI),
            ("client_id", client_id.as_str()),
            ("code_verifier", verifier.as_str()),
            ("resource", format!("{}/mcp", gateway.base).as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json::<Value>()
        .await
        .unwrap();
    assert_eq!(rejected["error"], "invalid_grant");

    let token = http
        .post(format!("{}/token", gateway.base))
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", code.as_str()),
            ("redirect_uri", REDIRECT_URI),
            ("client_id", client_id.as_str()),
            ("code_verifier", verifier.as_str()),
            ("resource", resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json::<Value>()
        .await
        .unwrap();
    let access = token["access_token"].as_str().unwrap().to_owned();
    let refresh = token["refresh_token"].as_str().unwrap().to_owned();
    let principal_id = gateway
        .state
        .store
        .access_token_for_resource(&access, ResourceKind::Builder)
        .unwrap()
        .unwrap()
        .binding
        .principal
        .id;
    Authorization {
        access,
        refresh,
        client_id,
        principal_id,
    }
}

async fn mcp_client(
    base: &str,
    access: &str,
) -> rmcp::service::RunningService<rmcp::RoleClient, ()> {
    let transport = StreamableHttpClientTransport::with_client(
        reqwest::Client::new(),
        StreamableHttpClientTransportConfig::with_uri(format!("{base}/builder/mcp"))
            .auth_header(access.to_owned()),
    );
    ().serve(transport).await.unwrap()
}

fn assert_safe_projection(value: &Value) {
    assert_safe_value(value, false);
}

fn assert_safe_artifact(value: &Value) {
    // Portable artifacts intentionally contain the authority's lossless
    // numeric keyboard encoding. All other public builder projections must
    // remain semantic; the artifact boundary still forbids identity,
    // credentials, raw operation descriptors, and paths.
    assert_safe_value(value, true);
}

fn assert_safe_value(value: &Value, portable_artifact: bool) {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                let normalized = key.to_ascii_lowercase().replace(['_', '-'], "");
                let mut forbidden = vec![
                    "credential",
                    "credentials",
                    "deviceid",
                    "devicetoken",
                    "ownerid",
                    "tunnel",
                    "rawdescriptor",
                    "filepath",
                ];
                if !portable_artifact {
                    forbidden.push("keycode");
                }
                assert!(
                    !forbidden.contains(&normalized.as_str()),
                    "unsafe projection key: {key}"
                );
                if normalized == "key" {
                    assert!(child.is_string(), "numeric key code escaped projection");
                }
                assert_safe_value(child, portable_artifact);
            }
        }
        Value::Array(array) => array
            .iter()
            .for_each(|child| assert_safe_value(child, portable_artifact)),
        Value::String(string) => {
            assert!(
                !string.contains(MALICIOUS),
                "projection reflected malicious input"
            );
            assert!(
                !string.starts_with('/') && !string.contains("../"),
                "unsafe path escaped projection"
            );
        }
        _ => {}
    }
}

fn result_value(result: &CallToolResult) -> &Value {
    result.structured_content.as_ref().unwrap()
}

fn parse_share_url(value: &Value) -> (String, String) {
    let url = url::Url::parse(value["shareURL"].as_str().unwrap()).unwrap();
    let token = url
        .fragment()
        .unwrap()
        .strip_prefix("token=")
        .unwrap()
        .to_owned();
    let mut clean = url;
    clean.set_fragment(None);
    (clean.to_string(), token)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn full_builder_oauth_tools_share_and_isolation_e2e() {
    let gateway = Gateway::start().await;
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    assert_eq!(gateway.state.tunnels.device_count(), 0);

    let relay_metadata = http
        .get(format!(
            "{}/.well-known/oauth-protected-resource",
            gateway.base
        ))
        .send()
        .await
        .unwrap()
        .json::<Value>()
        .await
        .unwrap();
    let builder_metadata = http
        .get(format!(
            "{}/.well-known/oauth-protected-resource/builder/mcp",
            gateway.base
        ))
        .send()
        .await
        .unwrap()
        .json::<Value>()
        .await
        .unwrap();
    assert_eq!(relay_metadata["resource"], format!("{}/mcp", gateway.base));
    assert_eq!(
        builder_metadata["resource"],
        format!("{}/builder/mcp", gateway.base)
    );
    assert_ne!(relay_metadata["resource"], builder_metadata["resource"]);

    let owner = authorize(&http, &gateway, "owner").await;
    assert_eq!(gateway.state.tunnels.device_count(), 0);
    let client = mcp_client(&gateway.base, &owner.access).await;
    assert_eq!(
        client
            .peer_info()
            .unwrap()
            .server_info
            .as_ref()
            .unwrap()
            .name,
        "thumble-hosted-builder"
    );
    let discover_meta = RequestMetaObject::with_client_context(
        client.peer_info().unwrap().protocol_version.clone(),
        Implementation::new("builder-e2e", "1"),
        ClientCapabilities::default(),
    );
    let discovered = client.peer().discover(discover_meta).await.unwrap();
    assert_eq!(
        discovered.server_info().unwrap().name,
        "thumble-hosted-builder"
    );
    let listed = client.peer().list_tools(None).await.unwrap();
    assert_eq!(listed.tools.len(), 9);
    assert!(serde_json::to_vec(&listed.tools).unwrap().len() <= BUILDER_TOOL_CATALOG_MAXIMUM_BYTES);
    for tool in &listed.tools {
        assert!(serde_json::to_vec(tool).unwrap().len() <= BUILDER_TOOL_MAXIMUM_BYTES);
        assert_eq!(tool.input_schema["additionalProperties"], false);
    }

    let begun = call_ok(
        client.peer(),
        "begin_builder_session",
        serde_json::json!({}),
    )
    .await;
    let session_id = result_value(&begun)["sessionID"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_safe_projection(result_value(&begun));
    let status = call_ok(
        client.peer(),
        "builder_status",
        serde_json::json!({"sessionID":session_id}),
    )
    .await;
    assert_eq!(result_value(&status)["revision"], 1);

    let operation_id = "00000000-0000-4000-8000-000000000401";
    let malicious_error = call_error(
        client.peer(),
        "edit_builder_profile",
        serde_json::json!({
            "sessionID":session_id,"expectedRevision":1,"operationID":operation_id,
            "operation":{"type":"profile.rename","name":"Hosted Profile","unsafePath":MALICIOUS}
        }),
    )
    .await;
    assert!(malicious_error.contains("invalid arguments"));
    let edit_arguments = serde_json::json!({
        "sessionID":session_id,"expectedRevision":1,"operationID":operation_id,
        "operation":{"type":"profile.rename","name":"Hosted Profile"}
    });
    let edited = call_ok(
        client.peer(),
        "edit_builder_profile",
        edit_arguments.clone(),
    )
    .await;
    let replay = call_ok(client.peer(), "edit_builder_profile", edit_arguments).await;
    assert_eq!(edited.structured_content, replay.structured_content);
    assert_eq!(result_value(&edited)["resultRevision"], 2);
    let changed_replay = call_error(
        client.peer(),
        "edit_builder_profile",
        serde_json::json!({
            "sessionID":session_id,"expectedRevision":1,"operationID":operation_id,
            "operation":{"type":"profile.rename","name":"different"}
        }),
    )
    .await;
    assert!(changed_replay.contains("operation ID was reused"));
    let stale = call_error(
        client.peer(),
        "edit_builder_profile",
        serde_json::json!({
            "sessionID":session_id,"expectedRevision":1,
            "operationID":"00000000-0000-4000-8000-000000000402",
            "operation":{"type":"profile.rename","name":"stale"}
        }),
    )
    .await;
    assert!(stale.contains("revision conflict"));

    let validated = call_ok(
        client.peer(),
        "validate_builder_profile",
        serde_json::json!({"sessionID":session_id,"expectedRevision":2}),
    )
    .await;
    assert_safe_projection(result_value(&validated));
    let preview = call_ok(
        client.peer(),
        "preview_builder_profile",
        serde_json::json!({"sessionID":session_id,"expectedRevision":2}),
    )
    .await;
    assert_safe_projection(result_value(&preview));
    let preview_text = &preview.content[0].as_text().unwrap().text;
    assert!(preview_text.len() <= 2048);
    assert!(!preview_text.contains(MALICIOUS));

    let installed = call_ok(
        client.peer(),
        "install_template",
        serde_json::json!({
            "sessionID":session_id,"expectedRevision":2,
            "operationID":"00000000-0000-4000-8000-000000000403",
            "template":"nes","name":"Installed"
        }),
    )
    .await;
    assert_eq!(result_value(&installed)["resultRevision"], 3);
    assert_safe_projection(result_value(&installed));

    let basic_spec: Value = serde_json::from_slice(include_bytes!(
        "../../../fixtures/generation-spec/v1/aliases-basic.json"
    ))
    .unwrap();
    let basic = call_ok(
        client.peer(),
        "generate_from_spec",
        serde_json::json!({
            "sessionID":session_id,"expectedRevision":3,
            "operationID":"00000000-0000-4000-8000-000000000404","spec":basic_spec
        }),
    )
    .await;
    assert_eq!(result_value(&basic)["resultRevision"], 4);
    assert_safe_projection(result_value(&basic));
    let rich_spec: Value = serde_json::from_slice(include_bytes!(
        "../../../fixtures/generation-spec/v1/rich-appearance.json"
    ))
    .unwrap();
    let rich = call_ok(
        client.peer(),
        "generate_from_spec",
        serde_json::json!({
            "sessionID":session_id,"expectedRevision":4,
            "operationID":"00000000-0000-4000-8000-000000000405","spec":rich_spec
        }),
    )
    .await;
    assert_eq!(result_value(&rich)["resultRevision"], 5);
    assert_safe_projection(result_value(&rich));

    let emitted = call_ok(
        client.peer(),
        "emit_profile_artifact",
        serde_json::json!({"sessionID":session_id,"expectedRevision":5}),
    )
    .await;
    let terminal_retry = call_ok(
        client.peer(),
        "emit_profile_artifact",
        serde_json::json!({"sessionID":session_id,"expectedRevision":5}),
    )
    .await;
    assert_eq!(
        emitted.structured_content,
        terminal_retry.structured_content
    );
    let emission = result_value(&emitted);
    assert_safe_artifact(&emission["artifact"]);
    let artifact_bytes = emission["artifactJSON"].as_str().unwrap().as_bytes();
    assert_eq!(
        emission["contentHash"],
        emission["artifact"]["contentHash"]["value"]
    );
    assert_eq!(
        Sha256::digest(artifact_bytes),
        Sha256::digest(
            terminal_retry.structured_content.as_ref().unwrap()["artifactJSON"]
                .as_str()
                .unwrap()
                .as_bytes()
        )
    );
    let (share_url, share_token) = parse_share_url(emission);
    let shared = http
        .get(&share_url)
        .header("Authorization", format!("ThumbleShare {share_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(shared.status(), 200);
    assert_eq!(shared.bytes().await.unwrap().as_ref(), artifact_bytes);
    assert_eq!(
        http.get(&share_url)
            .header("Authorization", format!("ThumbleShare {share_token}"))
            .send()
            .await
            .unwrap()
            .status(),
        200
    );
    for authorization in [
        None,
        Some(format!("Bearer {share_token}")),
        Some("ThumbleShare wrong".to_owned()),
    ] {
        let mut request = http.get(&share_url);
        if let Some(authorization) = authorization {
            request = request.header("Authorization", authorization);
        }
        let response = request.send().await.unwrap();
        assert_eq!(response.status(), 404);
        assert!(response.bytes().await.unwrap().is_empty());
    }

    let discarded_session = call_ok(
        client.peer(),
        "begin_builder_session",
        serde_json::json!({}),
    )
    .await
    .structured_content
    .unwrap()["sessionID"]
        .as_str()
        .unwrap()
        .to_owned();
    let discard = call_ok(
        client.peer(),
        "discard_builder_session",
        serde_json::json!({"sessionID":discarded_session,"expectedRevision":1}),
    )
    .await;
    let discard_retry = call_ok(
        client.peer(),
        "discard_builder_session",
        serde_json::json!({"sessionID":discarded_session,"expectedRevision":1}),
    )
    .await;
    assert_eq!(discard.structured_content, discard_retry.structured_content);

    // A second OAuth principal cannot load the owner's builder session and
    // cannot swap its independently emitted share credential onto this URL.
    let other = authorize(&http, &gateway, "other").await;
    let other_client = mcp_client(&gateway.base, &other.access).await;
    let denied = call_error(
        other_client.peer(),
        "builder_status",
        serde_json::json!({"sessionID":session_id}),
    )
    .await;
    assert!(denied.contains("not found"));
    let other_session = call_ok(
        other_client.peer(),
        "begin_builder_session",
        serde_json::json!({}),
    )
    .await
    .structured_content
    .unwrap()["sessionID"]
        .as_str()
        .unwrap()
        .to_owned();
    let other_emission = call_ok(
        other_client.peer(),
        "emit_profile_artifact",
        serde_json::json!({"sessionID":other_session,"expectedRevision":1}),
    )
    .await;
    let (other_url, other_token) = parse_share_url(result_value(&other_emission));
    assert_eq!(
        http.get(&share_url)
            .header("Authorization", format!("ThumbleShare {other_token}"))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );
    gateway
        .state
        .store
        .revoke_builder_share(&other.principal_id, other_url.rsplit('/').next().unwrap())
        .unwrap();
    assert_eq!(
        http.get(&other_url)
            .header("Authorization", format!("ThumbleShare {other_token}"))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );

    // Expired shares are the same uniform empty 404 as every bad share.
    let artifact_id = share_url.rsplit('/').next().unwrap();
    rusqlite::Connection::open(&gateway.database)
        .unwrap()
        .execute(
            "UPDATE builder_shares SET expires_at = 0 WHERE artifact_id = ?1",
            [artifact_id],
        )
        .unwrap();
    let expired_share = http
        .get(&share_url)
        .header("Authorization", format!("ThumbleShare {share_token}"))
        .send()
        .await
        .unwrap();
    assert_eq!(expired_share.status(), 404);
    assert!(expired_share.bytes().await.unwrap().is_empty());

    // Builder access is rejected by the relay endpoint with the relay's own
    // challenge, and oversized HTTP requests fail before MCP dispatch.
    let relay_rejection = http
        .post(format!("{}/mcp", gateway.base))
        .header("Authorization", format!("Bearer {}", other.access))
        .send()
        .await
        .unwrap();
    assert_eq!(relay_rejection.status(), 401);
    assert!(relay_rejection.headers()["www-authenticate"]
        .to_str()
        .unwrap()
        .contains("oauth-protected-resource\""));
    let body_rejection = http
        .post(format!("{}/builder/mcp", gateway.base))
        .header("Authorization", format!("Bearer {}", other.access))
        .header("Content-Type", "application/json")
        .body(vec![b'x'; 512 * 1024 + 1])
        .send()
        .await
        .unwrap();
    assert_eq!(body_rejection.status(), 413);

    client.cancel().await.ok();
    other_client.cancel().await.ok();
    assert_eq!(gateway.state.tunnels.device_count(), 0);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 6)]
async fn builder_limits_expiry_refresh_and_storage_cas_fail_closed() {
    let gateway = Gateway::start().await;
    let http = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();

    let quota_auth = authorize(&http, &gateway, "quota").await;
    let quota_client = mcp_client(&gateway.base, &quota_auth.access).await;
    for _ in 0..4 {
        call_ok(
            quota_client.peer(),
            "begin_builder_session",
            serde_json::json!({}),
        )
        .await;
    }
    assert!(call_error(
        quota_client.peer(),
        "begin_builder_session",
        serde_json::json!({})
    )
    .await
    .contains("storage quota"));

    let expiry_auth = authorize(&http, &gateway, "expiry").await;
    let expiry_client = mcp_client(&gateway.base, &expiry_auth.access).await;
    let expiring = call_ok(
        expiry_client.peer(),
        "begin_builder_session",
        serde_json::json!({"ttlSeconds":1}),
    )
    .await
    .structured_content
    .unwrap()["sessionID"]
        .as_str()
        .unwrap()
        .to_owned();
    tokio::time::sleep(Duration::from_millis(1100)).await;
    assert!(call_error(
        expiry_client.peer(),
        "builder_status",
        serde_json::json!({"sessionID":expiring})
    )
    .await
    .contains("not found"));
    let bad_session = call_error(
        expiry_client.peer(),
        "builder_status",
        serde_json::json!({"sessionID":"../../etc/passwd"}),
    )
    .await;
    assert!(bad_session.contains("not found") || bad_session.contains("invalid arguments"));
    let unsafe_spec: Value = serde_json::from_slice(include_bytes!(
        "../../../fixtures/generation-spec/v1/failures/unsafe.json"
    ))
    .unwrap();
    let spec_session = call_ok(
        expiry_client.peer(),
        "begin_builder_session",
        serde_json::json!({}),
    )
    .await
    .structured_content
    .unwrap()["sessionID"]
        .as_str()
        .unwrap()
        .to_owned();
    let spec_error = call_error(
        expiry_client.peer(),
        "generate_from_spec",
        serde_json::json!({
            "sessionID":spec_session,"expectedRevision":1,
            "operationID":"00000000-0000-4000-8000-000000000499","spec":unsafe_spec
        }),
    )
    .await;
    assert!(spec_error.contains("unsafe") || spec_error.contains("controls"));

    let rate_auth = authorize(&http, &gateway, "rate").await;
    let rate_client = mcp_client(&gateway.base, &rate_auth.access).await;
    let rate_session = call_ok(
        rate_client.peer(),
        "begin_builder_session",
        serde_json::json!({}),
    )
    .await
    .structured_content
    .unwrap()["sessionID"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut rate_error = None;
    for _ in 0..100 {
        match rate_client
            .peer()
            .call_tool(
                CallToolRequestParams::new("builder_status")
                    .with_arguments(args(serde_json::json!({"sessionID":rate_session}))),
            )
            .await
        {
            Ok(_) => {}
            Err(error) => {
                rate_error = Some(error.to_string());
                break;
            }
        }
    }
    let rate_error = rate_error.expect("builder rate limiter must reject a burst");
    assert!(rate_error.contains("rate limit"));
    assert!(rate_error.len() <= 1024);

    // Refresh rotation during the grace window preserves the opaque builder
    // binding. Reusing the same parent beyond its bounded successor budget
    // revokes that family without affecting another builder family.
    let resource = format!("{}/builder/mcp", gateway.base);
    let mut rotated_accesses = Vec::new();
    for _ in 0..4 {
        let response = http
            .post(format!("{}/token", gateway.base))
            .form(&[
                ("grant_type", "refresh_token"),
                ("refresh_token", quota_auth.refresh.as_str()),
                ("client_id", quota_auth.client_id.as_str()),
                ("resource", resource.as_str()),
            ])
            .send()
            .await
            .unwrap()
            .json::<Value>()
            .await
            .unwrap();
        let access = response["access_token"].as_str().unwrap().to_owned();
        let binding = gateway
            .state
            .store
            .access_token_for_resource(&access, ResourceKind::Builder)
            .unwrap()
            .unwrap()
            .binding
            .principal
            .id;
        assert_eq!(binding, quota_auth.principal_id);
        rotated_accesses.push(access);
    }
    let reused = http
        .post(format!("{}/token", gateway.base))
        .form(&[
            ("grant_type", "refresh_token"),
            ("refresh_token", quota_auth.refresh.as_str()),
            ("client_id", quota_auth.client_id.as_str()),
            ("resource", resource.as_str()),
        ])
        .send()
        .await
        .unwrap()
        .json::<Value>()
        .await
        .unwrap();
    assert_eq!(reused["error"], "invalid_grant");
    assert!(gateway
        .state
        .store
        .access_token_for_resource(&rotated_accesses[0], ResourceKind::Builder)
        .unwrap()
        .is_none());
    assert!(gateway
        .state
        .store
        .access_token_for_resource(&expiry_auth.access, ResourceKind::Builder)
        .unwrap()
        .is_some());

    // Two Store handles emulate concurrent gateway workers against one real
    // SQLite file; the independent storage-generation CAS rejects the loser.
    let first = Store::open(
        &gateway.database,
        "builder-e2e-secret-with-at-least-32-bytes",
    )
    .unwrap();
    let second = Store::open(
        &gateway.database,
        "builder-e2e-secret-with-at-least-32-bytes",
    )
    .unwrap();
    let cas_builder = first.create_builder_principal("CAS").unwrap();
    let cas_session = "00000000-0000-4000-8000-000000000498";
    first
        .begin_builder_workspace(&cas_builder, cas_session, None)
        .unwrap();
    let mut left = first
        .load_builder_workspace(&cas_builder, cas_session)
        .unwrap();
    let right = second
        .load_builder_workspace(&cas_builder, cas_session)
        .unwrap();
    left.session
        .apply_edit(
            "00000000-0000-4000-8000-000000000497",
            1,
            thumble_builder::BuilderEdit::ProfileRename {
                name: "CAS winner".to_owned(),
            },
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs() as i64,
        )
        .unwrap();
    first
        .save_builder_workspace(&cas_builder, 1, left.storage_generation, &left.session)
        .unwrap();
    assert!(matches!(
        second.save_builder_workspace(&cas_builder, 1, right.storage_generation, &right.session),
        Err(BuilderStoreError::Conflict { .. })
            | Err(BuilderStoreError::StorageGenerationConflict { .. })
    ));

    quota_client.cancel().await.ok();
    expiry_client.cancel().await.ok();
    rate_client.cancel().await.ok();
    assert_eq!(gateway.state.tunnels.device_count(), 0);
}
