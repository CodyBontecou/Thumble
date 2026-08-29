use std::sync::Arc;

use rmcp::model::CallToolRequestParams;
use rmcp::transport::streamable_http_client::{
    StreamableHttpClientTransport, StreamableHttpClientTransportConfig,
};
use rmcp::ServiceExt as _;
use serde_json::{Map, Value};
use thumble_builder::BuilderSession;
use thumble_gateway::builder::{BUILDER_TOOL_CATALOG_MAXIMUM_BYTES, BUILDER_TOOL_MAXIMUM_BYTES};
use thumble_gateway::principal::OAuthBinding;
use thumble_gateway::state::AppState;
use thumble_gateway::store::Store;
use thumble_gateway::tunnel::TunnelRegistry;

async fn server_with_store(
    store: Arc<Store>,
) -> (String, Arc<AppState>, tokio::task::JoinHandle<()>) {
    let state = Arc::new(AppState::new(
        store,
        TunnelRegistry::new(),
        "http://127.0.0.1".to_owned(),
    ));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let base = format!("http://{address}");
    state.set_base_url(base.clone());
    let app = thumble_gateway::app(state.clone());
    let task = tokio::spawn(async move {
        axum::serve(
            listener,
            app.into_make_service_with_connect_info::<std::net::SocketAddr>(),
        )
        .await
        .unwrap();
    });
    (base, state, task)
}

async fn server() -> (String, Arc<AppState>, tokio::task::JoinHandle<()>) {
    server_with_store(Arc::new(Store::open_in_memory().unwrap())).await
}

#[tokio::test]
async fn apple_app_site_association_is_exact_redirect_free_and_no_store() {
    let (base, _state, task) = server().await;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .unwrap();
    for path in [
        "/.well-known/apple-app-site-association",
        "/apple-app-site-association",
    ] {
        let response = client.get(format!("{base}{path}")).send().await.unwrap();
        assert_eq!(response.status(), reqwest::StatusCode::OK);
        assert_eq!(
            response.headers().get("content-type").unwrap(),
            "application/json"
        );
        assert_eq!(response.headers().get("cache-control").unwrap(), "no-store");
        assert!(response.headers().get("location").is_none());
        assert_eq!(
            response.json::<Value>().await.unwrap(),
            serde_json::json!({
                "applinks": {
                    "details": [{
                        "appIDs": ["67KC823C9A.com.codybontecou.PocketPad.iOS"],
                        "components": [{
                            "/": "/share/*",
                            "comment": "Hosted-builder profile artifact pickup"
                        }]
                    }]
                }
            })
        );
    }
    task.abort();
}

fn args(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

async fn call(
    peer: &rmcp::service::Peer<rmcp::RoleClient>,
    name: &'static str,
    value: Value,
) -> rmcp::model::CallToolResult {
    peer.call_tool(CallToolRequestParams::new(name).with_arguments(args(value)))
        .await
        .unwrap()
}

#[tokio::test]
async fn builder_streamable_http_lists_exact_catalog_and_replays_terminal_tools() {
    let (base, state, task) = server().await;
    let builder_id = state
        .store
        .create_builder_principal("HTTP builder")
        .unwrap();
    let token = state
        .store
        .issue_access_token_for_binding(
            &OAuthBinding::builder(&builder_id).unwrap(),
            "thumble.build",
            900,
        )
        .unwrap();
    let transport = StreamableHttpClientTransport::with_client(
        reqwest::Client::new(),
        StreamableHttpClientTransportConfig::with_uri(format!("{base}/builder/mcp"))
            .auth_header(token.clone()),
    );
    let client = ().serve(transport).await.unwrap();
    assert_eq!(state.builder_mutation_semaphore.available_permits(), 4);
    let info = client.peer_info().unwrap();
    assert_eq!(
        info.server_info.as_ref().unwrap().name,
        "thumble-hosted-builder"
    );
    assert!(info
        .instructions
        .as_deref()
        .unwrap()
        .contains("no phone authority"));
    let listed = client.peer().list_tools(None).await.unwrap();
    assert_eq!(listed.tools.len(), 9);
    let catalog = serde_json::to_vec(&listed.tools).unwrap();
    assert!(catalog.len() <= BUILDER_TOOL_CATALOG_MAXIMUM_BYTES);
    for tool in &listed.tools {
        assert!(serde_json::to_vec(tool).unwrap().len() <= BUILDER_TOOL_MAXIMUM_BYTES);
        assert_eq!(
            tool.input_schema.get("additionalProperties"),
            Some(&Value::Bool(false))
        );
    }

    let begun = call(
        client.peer(),
        "begin_builder_session",
        serde_json::json!({}),
    )
    .await;
    let begun = begun.structured_content.unwrap();
    let session_id = begun["sessionID"].as_str().unwrap();
    assert_eq!(begun["revision"], 1);

    let operation_id = "00000000-0000-4000-8000-000000000001";
    let edit_args = serde_json::json!({
        "sessionID":session_id,
        "expectedRevision":1,
        "operationID":operation_id,
        "operation":{"type":"profile.rename","name":"Hosted Profile"}
    });
    let edited = call(client.peer(), "edit_builder_profile", edit_args.clone()).await;
    assert_eq!(
        edited.structured_content.as_ref().unwrap()["resultRevision"],
        2
    );
    let replay = call(client.peer(), "edit_builder_profile", edit_args).await;
    assert_eq!(edited.structured_content, replay.structured_content);

    let status = call(
        client.peer(),
        "builder_status",
        serde_json::json!({"sessionID":session_id}),
    )
    .await;
    assert_eq!(status.structured_content.unwrap()["revision"], 2);
    call(
        client.peer(),
        "validate_builder_profile",
        serde_json::json!({"sessionID":session_id,"expectedRevision":2}),
    )
    .await;
    let preview = call(
        client.peer(),
        "preview_builder_profile",
        serde_json::json!({"sessionID":session_id,"expectedRevision":2}),
    )
    .await;
    assert!(preview.content[0].as_text().unwrap().text.len() <= 2048);

    let installed = call(
        client.peer(),
        "install_template",
        serde_json::json!({
            "sessionID":session_id,"expectedRevision":2,
            "operationID":"00000000-0000-4000-8000-000000000002",
            "template":"nes","name":"Template Profile"
        }),
    )
    .await;
    assert_eq!(installed.structured_content.unwrap()["resultRevision"], 3);
    let generated = call(
        client.peer(),
        "generate_from_spec",
        serde_json::json!({
            "sessionID":session_id,"expectedRevision":3,
            "operationID":"00000000-0000-4000-8000-000000000003",
            "spec":{"name":"Generated Profile","controls":[
                {"button":"jump","label":"Jump","key":"space"}
            ]}
        }),
    )
    .await;
    assert_eq!(generated.structured_content.unwrap()["resultRevision"], 4);

    let emitted = call(
        client.peer(),
        "emit_profile_artifact",
        serde_json::json!({"sessionID":session_id,"expectedRevision":4}),
    )
    .await;
    let retry = call(
        client.peer(),
        "emit_profile_artifact",
        serde_json::json!({"sessionID":session_id,"expectedRevision":4}),
    )
    .await;
    assert_eq!(emitted.structured_content, retry.structured_content);
    assert!(emitted.structured_content.unwrap()["shareURL"]
        .as_str()
        .unwrap()
        .contains("#token="));

    let second = call(
        client.peer(),
        "begin_builder_session",
        serde_json::json!({}),
    )
    .await;
    let second_id = second.structured_content.unwrap()["sessionID"]
        .as_str()
        .unwrap()
        .to_owned();
    let discarded = call(
        client.peer(),
        "discard_builder_session",
        serde_json::json!({"sessionID":second_id,"expectedRevision":1}),
    )
    .await;
    let discard_replay = call(
        client.peer(),
        "discard_builder_session",
        serde_json::json!({"sessionID":second_id,"expectedRevision":1}),
    )
    .await;
    assert_eq!(
        discarded.structured_content,
        discard_replay.structured_content
    );

    let oversized = call(
        client.peer(),
        "begin_builder_session",
        serde_json::json!({}),
    )
    .await;
    let oversized_id = oversized.structured_content.unwrap()["sessionID"]
        .as_str()
        .unwrap()
        .to_owned();
    let secret_marker = "must-not-be-reflected";
    let large_source = format!("{secret_marker}{}", "x".repeat(257 * 1024));
    let generation_error = client
        .peer()
        .call_tool(
            CallToolRequestParams::new("generate_from_spec").with_arguments(args(
                serde_json::json!({
                    "sessionID":oversized_id,"expectedRevision":1,
                    "operationID":"00000000-0000-4000-8000-000000000004",
                    "spec":{"source":large_source,"controls":[
                        {"button":"jump","label":"Jump","key":"space"}
                    ]}
                }),
            )),
        )
        .await
        .unwrap_err()
        .to_string();
    assert!(generation_error.contains("256 KiB"));
    assert!(!generation_error.contains(secret_marker));

    let body_limit = reqwest::Client::new()
        .post(format!("{base}/builder/mcp"))
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "application/json")
        .body(vec![b' '; 512 * 1024 + 1])
        .send()
        .await
        .unwrap();
    assert_eq!(body_limit.status(), 413);

    client.cancel().await.ok();
    task.abort();
}

#[tokio::test]
async fn builder_mcp_session_ids_follow_a_refreshed_principal_but_reject_another_principal() {
    let (base, state, task) = server().await;
    let owner = state.store.create_builder_principal("Owner").unwrap();
    let other = state.store.create_builder_principal("Other").unwrap();
    let (owner_token, owner_refresh) = state
        .store
        .issue_authorization_tokens_for_binding(
            &OAuthBinding::builder(&owner).unwrap(),
            "builder-http-client",
            "thumble.build offline_access",
            900,
            3_600,
            true,
        )
        .unwrap();
    let other_token = state
        .store
        .issue_access_token_for_binding(
            &OAuthBinding::builder(&other).unwrap(),
            "thumble.build",
            900,
        )
        .unwrap();
    let http = reqwest::Client::new();
    let initialize = http
        .post(format!("{base}/builder/mcp"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .json(&serde_json::json!({
            "jsonrpc":"2.0","id":1,"method":"initialize",
            "params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"binding-test","version":"1"}}
        }))
        .send()
        .await
        .unwrap();
    assert_eq!(initialize.status(), 200);
    let session_id = initialize
        .headers()
        .get("mcp-session-id")
        .unwrap()
        .to_str()
        .unwrap()
        .to_owned();

    let refreshed_token = state
        .store
        .rotate_refresh_token_for_resource(
            &owner_refresh.unwrap(),
            "builder-http-client",
            thumble_gateway::principal::ResourceKind::Builder,
            3_600,
        )
        .unwrap()
        .unwrap()
        .access_token;
    let refreshed_list = http
        .post(format!("{base}/builder/mcp"))
        .header("Authorization", format!("Bearer {refreshed_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Mcp-Session-Id", &session_id)
        .json(&serde_json::json!({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}))
        .send()
        .await
        .unwrap();
    assert_eq!(refreshed_list.status(), 200);

    for method in [
        reqwest::Method::POST,
        reqwest::Method::GET,
        reqwest::Method::DELETE,
    ] {
        let mut request = http
            .request(method.clone(), format!("{base}/builder/mcp"))
            .header("Authorization", format!("Bearer {other_token}"))
            .header("Accept", "application/json, text/event-stream")
            .header("Mcp-Session-Id", &session_id);
        if method == reqwest::Method::POST {
            request = request.header("Content-Type", "application/json").json(
                &serde_json::json!({"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}),
            );
        }
        assert_eq!(request.send().await.unwrap().status(), 403);
    }

    let owner_list = http
        .post(format!("{base}/builder/mcp"))
        .header("Authorization", format!("Bearer {owner_token}"))
        .header("Content-Type", "application/json")
        .header("Accept", "application/json, text/event-stream")
        .header("Mcp-Session-Id", &session_id)
        .json(&serde_json::json!({"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}))
        .send()
        .await
        .unwrap();
    assert_eq!(owner_list.status(), 200);
    let owner_delete = http
        .delete(format!("{base}/builder/mcp"))
        .header("Authorization", format!("Bearer {refreshed_token}"))
        .header("Mcp-Session-Id", session_id)
        .send()
        .await
        .unwrap();
    assert!(owner_delete.status().is_success());
    task.abort();
}

#[tokio::test]
async fn malformed_share_source_is_throttled_before_artifact_or_token_parsing() {
    let (base, _state, task) = server().await;
    let http = reqwest::Client::new();
    for _ in 0..thumble_gateway::rate_limit::ShareRateLimiter::SOURCE_MAXIMUM {
        let response = http
            .get(format!("{base}/share/not-an-artifact"))
            .header("Authorization", "ThumbleShare malformed")
            .send()
            .await
            .unwrap();
        assert_eq!(response.status(), 404);
        assert!(response.bytes().await.unwrap().is_empty());
    }
    let throttled = http
        .get(format!("{base}/share/not-an-artifact"))
        .header("Authorization", "ThumbleShare malformed")
        .send()
        .await
        .unwrap();
    assert_eq!(throttled.status(), 429);
    assert!(throttled.bytes().await.unwrap().is_empty());
    task.abort();
}

#[tokio::test]
async fn expired_share_http_is_a_uniform_empty_not_found() {
    let directory = tempfile::tempdir().unwrap();
    let database = directory.path().join("expired-share.db");
    let store =
        Arc::new(Store::open(&database, "expired-share-test-secret-at-least-32-bytes").unwrap());
    let (base, state, task) = server_with_store(store).await;
    let builder = state
        .store
        .create_builder_principal("Expired share")
        .unwrap();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let mut session =
        BuilderSession::begin("00000000-0000-4000-8000-000000000097", now, 3600).unwrap();
    state
        .store
        .create_builder_workspace(&builder, &session)
        .unwrap();
    let emission = session.emit_artifact(1, now).unwrap();
    let handoff = session.mark_emitted(1, now).unwrap();
    let result = state
        .store
        .emit_builder_artifact(&builder, &session, 1, 1, &emission, &handoff)
        .unwrap();
    let share = match result {
        thumble_gateway::builder_store::BuilderEmissionResult::Emitted { share, .. } => share,
        _ => panic!("fresh emission must not replay"),
    };
    let connection = rusqlite::Connection::open(&database).unwrap();
    connection
        .execute(
            "UPDATE builder_shares SET expires_at = 0 WHERE artifact_id = ?1",
            rusqlite::params![share.artifact_id],
        )
        .unwrap();
    drop(connection);

    let response = reqwest::Client::new()
        .get(format!("{base}/share/{}", share.artifact_id))
        .header(
            "Authorization",
            format!("ThumbleShare {}", share.share_token),
        )
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 404);
    assert_eq!(response.headers()["cache-control"], "no-store");
    assert_eq!(response.headers()["referrer-policy"], "no-referrer");
    assert_eq!(response.headers()["x-content-type-options"], "nosniff");
    assert!(!response.headers().contains_key("www-authenticate"));
    assert!(response.bytes().await.unwrap().is_empty());
    task.abort();
}

#[tokio::test]
async fn share_http_requires_custom_header_and_returns_exact_bytes() {
    let (base, state, task) = server().await;
    let builder_id = state
        .store
        .create_builder_principal("Share builder")
        .unwrap();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let mut session =
        BuilderSession::begin("00000000-0000-4000-8000-000000000099", now, 3600).unwrap();
    state
        .store
        .create_builder_workspace(&builder_id, &session)
        .unwrap();
    let emission = session.emit_artifact(1, now).unwrap();
    let handoff = session.mark_emitted(1, now).unwrap();
    let result = state
        .store
        .emit_builder_artifact(&builder_id, &session, 1, 1, &emission, &handoff)
        .unwrap();
    let (artifact, share) = match result {
        thumble_gateway::builder_store::BuilderEmissionResult::Emitted { artifact, share } => {
            (artifact, share)
        }
        _ => panic!("fresh emission must not replay"),
    };
    let url = format!("{base}/share/{}", share.artifact_id);
    let http = reqwest::Client::new();
    for invalid in [
        None,
        Some(format!("Bearer {}", share.share_token)),
        Some("ThumbleShare wrong".to_owned()),
        Some(format!("ThumbleShare {}", "a".repeat(63))),
        Some(format!("ThumbleShare {}", "a".repeat(65))),
    ] {
        let mut request = http.get(&url);
        if let Some(value) = invalid {
            request = request.header("Authorization", value);
        }
        let response = request.send().await.unwrap();
        assert_eq!(response.status(), 404);
        assert_eq!(response.headers()["cache-control"], "no-store");
        assert_eq!(response.headers()["referrer-policy"], "no-referrer");
        assert_eq!(response.headers()["x-content-type-options"], "nosniff");
        assert!(!response.headers().contains_key("www-authenticate"));
        assert!(response.bytes().await.unwrap().is_empty());
    }
    assert_eq!(
        http.get(format!("{url}?token={}", share.share_token))
            .send()
            .await
            .unwrap()
            .status(),
        404
    );

    let response = http
        .get(&url)
        .header(
            "Authorization",
            format!("ThumbleShare {}", share.share_token),
        )
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), 200);
    assert_eq!(response.headers()["content-type"], "application/json");
    assert_eq!(response.headers()["cache-control"], "no-store");
    assert_eq!(response.headers()["referrer-policy"], "no-referrer");
    assert_eq!(response.headers()["x-content-type-options"], "nosniff");
    assert!(response.headers()["content-disposition"]
        .to_str()
        .unwrap()
        .starts_with("attachment;"));
    assert_eq!(
        response.bytes().await.unwrap().as_ref(),
        artifact.artifact_json
    );

    let mut second_session =
        BuilderSession::begin("00000000-0000-4000-8000-000000000098", now, 3600).unwrap();
    state
        .store
        .create_builder_workspace(&builder_id, &second_session)
        .unwrap();
    let second_emission = second_session.emit_artifact(1, now).unwrap();
    let second_handoff = second_session.mark_emitted(1, now).unwrap();
    let second = state
        .store
        .emit_builder_artifact(
            &builder_id,
            &second_session,
            1,
            1,
            &second_emission,
            &second_handoff,
        )
        .unwrap();
    let (_, second_share) = match second {
        thumble_gateway::builder_store::BuilderEmissionResult::Emitted { artifact, share } => {
            (artifact, share)
        }
        _ => panic!("fresh second emission must not replay"),
    };
    let swapped = http
        .get(&url)
        .header(
            "Authorization",
            format!("ThumbleShare {}", second_share.share_token),
        )
        .send()
        .await
        .unwrap();
    assert_eq!(swapped.status(), 404);
    assert_eq!(swapped.headers()["cache-control"], "no-store");
    assert!(!swapped.headers().contains_key("www-authenticate"));
    assert!(swapped.bytes().await.unwrap().is_empty());
    state
        .store
        .revoke_builder_share(&builder_id, &second_share.artifact_id)
        .unwrap();
    let revoked = http
        .get(format!("{base}/share/{}", second_share.artifact_id))
        .header(
            "Authorization",
            format!("ThumbleShare {}", second_share.share_token),
        )
        .send()
        .await
        .unwrap();
    assert_eq!(revoked.status(), 404);
    assert_eq!(revoked.headers()["cache-control"], "no-store");
    assert!(!revoked.headers().contains_key("www-authenticate"));
    assert!(revoked.bytes().await.unwrap().is_empty());

    // Reuse is allowed, but both the credential digest and network source are
    // independently bounded. One successful read above consumed the first
    // credential slot.
    for _ in 1..thumble_gateway::rate_limit::ShareRateLimiter::TOKEN_MAXIMUM {
        assert_eq!(
            http.get(&url)
                .header(
                    "Authorization",
                    format!("ThumbleShare {}", share.share_token),
                )
                .send()
                .await
                .unwrap()
                .status(),
            200
        );
    }
    assert_eq!(
        http.get(&url)
            .header(
                "Authorization",
                format!("ThumbleShare {}", share.share_token),
            )
            .send()
            .await
            .unwrap()
            .status(),
        429
    );

    task.abort();
}
