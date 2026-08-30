//! OAuth 2.1 authorization server for remote MCP connectors (ChatGPT).
//!
//! Implements the subset required by MCP authorization: RFC 8414-style
//! server metadata, RFC 7591 dynamic client registration, authorization
//! code + PKCE (S256 only), and refresh-token rotation with reuse
//! detection. Bearer tokens are opaque and stored hashed.

use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{Html, IntoResponse, Response};
use axum::Json;
use serde::{Deserialize, Serialize};
use std::sync::Arc;

use crate::principal::{Principal, ResourceKind};
use crate::scopes;
use crate::state::AppState;
use crate::tunnel::ApprovalTarget;
use thumble_tunnel::protocol::CONNECTOR_APPROVAL_TTL_SECONDS;

const AUTH_CODE_TTL_SECONDS: i64 = 3600;
const ACCESS_TOKEN_TTL_SECONDS: i64 = 900;
const REFRESH_TOKEN_TTL_SECONDS: i64 = 30 * 24 * 3600;
/// How often the waiting authorization page polls the decision endpoint.
const APPROVAL_POLL_SECONDS: u64 = 2;
const BUILDER_CONSENT_COOKIE: &str = "thumble_builder_consent";
const BUILDER_CONFIRM_PATH: &str = "/authorize/builder/confirm";

fn builder_consent_cookie(base_url: &str, nonce: &str, clear: bool) -> Result<HeaderValue, String> {
    let base = url::Url::parse(base_url).map_err(|_| "gateway base URL is invalid")?;
    let secure = match (base.scheme(), base.host_str()) {
        ("https", Some(_)) => true,
        ("http", Some("localhost" | "127.0.0.1" | "::1")) => false,
        _ => return Err("builder consent requires HTTPS or exact loopback HTTP".to_owned()),
    };
    let value = if clear {
        format!(
            "{BUILDER_CONSENT_COOKIE}=; Path={BUILDER_CONFIRM_PATH}; HttpOnly; SameSite=Lax; Max-Age=0{}",
            if secure { "; Secure" } else { "" }
        )
    } else {
        format!(
            "{BUILDER_CONSENT_COOKIE}={nonce}; Path={BUILDER_CONFIRM_PATH}; HttpOnly; SameSite=Lax{}",
            if secure { "; Secure" } else { "" }
        )
    };
    HeaderValue::from_str(&value).map_err(|_| "builder consent cookie is invalid".to_owned())
}

fn valid_builder_consent_proof(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_alphanumeric())
}

fn builder_consent_nonce(headers: &HeaderMap) -> Option<&str> {
    let mut found = None;
    for value in headers.get_all(header::COOKIE) {
        let value = value.to_str().ok()?;
        for cookie in value.split(';') {
            let (name, value) = cookie.trim().split_once('=')?;
            if name == BUILDER_CONSENT_COOKIE {
                if found.is_some() || !valid_builder_consent_proof(value) {
                    return None;
                }
                found = Some(value);
            }
        }
    }
    found
}

fn same_gateway_origin(headers: &HeaderMap, base_url: &str) -> bool {
    let mut origins = headers.get_all(header::ORIGIN).iter();
    let Some(origin) = origins.next().and_then(|value| value.to_str().ok()) else {
        return false;
    };
    if origins.next().is_some() {
        return false;
    }
    let Ok(origin) = url::Url::parse(origin) else {
        return false;
    };
    let Ok(base) = url::Url::parse(base_url) else {
        return false;
    };
    origin.username().is_empty()
        && origin.password().is_none()
        && origin.path() == "/"
        && origin.query().is_none()
        && origin.fragment().is_none()
        && origin.scheme() == base.scheme()
        && origin.host() == base.host()
        && origin.port_or_known_default() == base.port_or_known_default()
}

fn with_builder_cookie(mut response: Response, cookie: HeaderValue) -> Response {
    response.headers_mut().append(header::SET_COOKIE, cookie);
    response
}

fn forbidden_builder_consent(reason: &'static str) -> Response {
    // Fixed reason labels only: never log request IDs, cookies, proofs, OAuth
    // state, redirect URIs, or any other attacker/user-controlled value.
    eprintln!("gateway: builder-consent outcome=forbidden reason={reason}");
    (
        StatusCode::FORBIDDEN,
        Html("<h1>Forbidden</h1><p>This builder consent could not be verified. Return to the connector and start a fresh authorization.</p>"),
    )
        .into_response()
}

fn resource_url(base_url: &str, resource: ResourceKind) -> String {
    let base_url = base_url.trim_end_matches('/');
    match resource {
        ResourceKind::Relay => format!("{base_url}/mcp"),
        ResourceKind::Builder => format!("{base_url}/builder/mcp"),
    }
}

fn requested_resource_kind(base_url: &str, resource: Option<&str>) -> Result<ResourceKind, String> {
    match resource {
        None => Ok(ResourceKind::Relay),
        Some(resource) if resource == resource_url(base_url, ResourceKind::Relay) => {
            Ok(ResourceKind::Relay)
        }
        Some(resource) if resource == resource_url(base_url, ResourceKind::Builder) => {
            Ok(ResourceKind::Builder)
        }
        Some(_) => Err("resource does not identify this MCP server".to_owned()),
    }
}

fn audit_principal(event: &str, principal: &Principal) {
    // Principal identifiers are generated or validated by the store and are
    // bounded. Never log codes, bearer tokens, state, callbacks, or content.
    eprintln!(
        "gateway: OAuth {event}; principal_kind={} principal_id={}",
        principal.kind, principal.id
    );
}

pub fn protected_resource_metadata(base_url: &str) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "resource": resource_url(base_url, ResourceKind::Relay),
        "authorization_servers": [base_url.trim_end_matches('/')],
        "scopes_supported": [
            scopes::SCOPE_READ,
            scopes::SCOPE_DRAFT,
            scopes::SCOPE_CONFIG,
            scopes::SCOPE_OFFLINE_ACCESS,
        ],
    }))
}

pub fn builder_protected_resource_metadata(base_url: &str) -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "resource": resource_url(base_url, ResourceKind::Builder),
        "authorization_servers": [base_url.trim_end_matches('/')],
        "scopes_supported": [scopes::SCOPE_BUILD, scopes::SCOPE_OFFLINE_ACCESS],
    }))
}

pub fn authorization_server_metadata(base_url: &str) -> Json<serde_json::Value> {
    let base_url = base_url.trim_end_matches('/');
    Json(serde_json::json!({
        "issuer": base_url,
        "authorization_response_iss_parameter_supported": true,
        "authorization_endpoint": format!("{base_url}/authorize"),
        "token_endpoint": format!("{base_url}/token"),
        "registration_endpoint": format!("{base_url}/register"),
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code", "refresh_token"],
        "code_challenge_methods_supported": ["S256"],
        "token_endpoint_auth_methods_supported": ["none"],
        "scopes_supported": [
            scopes::SCOPE_READ,
            scopes::SCOPE_DRAFT,
            scopes::SCOPE_CONFIG,
            scopes::SCOPE_BUILD,
            scopes::SCOPE_OFFLINE_ACCESS,
        ],
        "refresh_token_endpoint": format!("{base_url}/token"),
    }))
}

#[derive(Debug, Deserialize)]
pub struct RegisterRequest {
    #[serde(default)]
    pub client_name: Option<String>,
    pub redirect_uris: Vec<String>,
    #[serde(default)]
    pub token_endpoint_auth_method: Option<String>,
    #[serde(default)]
    pub grant_types: Option<Vec<String>>,
    #[serde(default)]
    pub response_types: Option<Vec<String>>,
}

#[derive(Debug, Serialize)]
pub struct RegisterResponse {
    pub client_id: String,
    pub client_id_issued_at: i64,
    pub client_name: String,
    pub redirect_uris: Vec<String>,
    pub token_endpoint_auth_method: String,
    pub grant_types: Vec<String>,
    pub response_types: Vec<String>,
}

/// RFC 7591 dynamic client registration. Public clients only (PKCE, no
/// secret) — exactly what connector platforms use.
pub async fn register(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    connect_info: axum::extract::ConnectInfo<std::net::SocketAddr>,
    Json(request): Json<RegisterRequest>,
) -> Response {
    let source = crate::http::client_source_key(&headers, Some(&connect_info));
    if let Err(error) = state.oauth_rate_limiter.allow_registration(&source) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Json(serde_json::json!({
                "error": "temporarily_unavailable",
                "error_description": error
            })),
        )
            .into_response();
    }
    if request
        .token_endpoint_auth_method
        .as_deref()
        .unwrap_or("none")
        != "none"
        || request.grant_types.as_ref().is_some_and(|values| {
            values
                .iter()
                .any(|value| value != "authorization_code" && value != "refresh_token")
        })
        || request
            .response_types
            .as_ref()
            .is_some_and(|values| values.iter().any(|value| value != "code"))
    {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "error": "invalid_client_metadata",
                "error_description": "only public authorization-code + refresh-token clients are supported"
            })),
        )
            .into_response();
    }
    let client_name = request
        .client_name
        .unwrap_or_else(|| "connector".to_owned());
    let redirect_uris = request.redirect_uris;
    match state
        .store
        .register_client(&client_name, redirect_uris.clone())
    {
        Ok(client_id) => (
            StatusCode::CREATED,
            Json(RegisterResponse {
                client_id,
                client_id_issued_at: chrono_free_now(),
                client_name,
                redirect_uris,
                token_endpoint_auth_method: "none".to_owned(),
                grant_types: vec!["authorization_code".to_owned(), "refresh_token".to_owned()],
                response_types: vec!["code".to_owned()],
            }),
        )
            .into_response(),
        Err(error) => (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "invalid_client_metadata", "error_description": error })),
        )
            .into_response(),
    }
}

fn chrono_free_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn valid_pkce_challenge(challenge: &str) -> bool {
    (43..=128).contains(&challenge.len())
        && challenge
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn valid_pkce_verifier(verifier: &str) -> bool {
    (43..=128).contains(&verifier.len())
        && verifier
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~'))
}

/// Push approval is intentionally narrower than open DCR. Arbitrary OAuth
/// clients keep working through explicit fallback-code consent, but only
/// callbacks controlled by ChatGPT can trigger a native Mac prompt.
fn trusted_push_connector(redirect_uri: &str) -> Option<&'static str> {
    let url = url::Url::parse(redirect_uri).ok()?;
    if url.scheme() != "https" || url.port_or_known_default() != Some(443) {
        return None;
    }
    match url.host_str()? {
        "chatgpt.com" | "chat.openai.com" => Some("ChatGPT"),
        // Reserved RFC 2606 host used only by the in-process e2e.
        "chatgpt.example" => Some("ChatGPT test connector"),
        _ => None,
    }
}

fn html_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&#39;")
}

fn server_error(error: impl std::fmt::Display) -> Response {
    let bounded: String = error
        .to_string()
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .take(512)
        .collect();
    eprintln!("gateway: OAuth server error: {bounded}");
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Html("<h1>Server error</h1><p>The request could not be completed.</p>"),
    )
        .into_response()
}

fn oauth_response_url(redirect_uri: &str, parameters: &[(&str, &str)]) -> Result<String, String> {
    let mut url = url::Url::parse(redirect_uri)
        .map_err(|error| format!("parse OAuth callback URL: {error}"))?;
    url.query_pairs_mut()
        .extend_pairs(parameters.iter().copied());
    Ok(url.into())
}

fn oauth_redirect(url: &str) -> Response {
    let location = match HeaderValue::from_str(url) {
        Ok(location) => location,
        Err(_) => return server_error("invalid OAuth callback location"),
    };
    // OAuth authorization endpoints conventionally return 302. In
    // particular, ChatGPT's connector callback handoff may stall on a 303
    // even though browsers generally treat both as GET redirects.
    (StatusCode::FOUND, [(header::LOCATION, location)]).into_response()
}

fn authorization_complete(callback_url: &str, device_name: Option<&str>) -> Response {
    // Some connector browser surfaces leave the POSTed consent form visible
    // instead of following its cross-origin 302. Return an explicit no-script
    // handoff page: standards-compliant user-agent redirection via meta refresh
    // plus a visible link if automatic navigation is suppressed. Global
    // middleware adds no-store and no-referrer, so the one-time code cannot be
    // cached or leaked in a Referer header.
    let callback_url = html_escape(callback_url);
    let linked_line = match device_name {
        Some(name) => format!("Linked to <b>{}</b>. ", html_escape(name)),
        None => String::new(),
    };
    Html(format!(
        r#"<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="0;url={callback_url}">
<title>Return to ChatGPT</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:36rem;margin:4rem auto;padding:0 1rem;line-height:1.45}}
a{{display:inline-block;padding:.7rem 1rem;border-radius:.5rem;background:#0879f9;color:white;text-decoration:none}}</style></head>
<body><h1>Thumble linked</h1>
<p>{linked_line}Returning to ChatGPT to finish authentication…</p>
<p><a id="oauth-callback" href="{callback_url}">Return to ChatGPT</a></p>
<p>If nothing happens automatically, click the button once.</p>
</body></html>"#,
    ))
    .into_response()
}

fn unavailable_authorization_request(reason: &str) -> Response {
    let (heading, message) = if reason == "authorization request already used" {
        (
            "Link already submitted",
            "The first action already completed this authorization request. Return to ChatGPT and wait for it to finish; do not submit again. If ChatGPT did not complete, start a fresh connection and approve the new prompt on your Mac (or use a new fallback code).",
        )
    } else if reason == "authorization request expired" {
        (
            "Authorization expired",
            "This authorization page is too old to use. Return to ChatGPT, click Connect again, and approve the new prompt on your Mac. Use the current six-digit code only if the prompt is unavailable.",
        )
    } else if reason.contains("locked") || reason.contains("ten attempts") {
        (
            "Too many attempts",
            "This sign-in page received too many incorrect fallback-code submissions and is locked. Return to ChatGPT, click Connect again, and approve the new prompt on your Mac (or use a fresh fallback code).",
        )
    } else {
        (
            "Link attempt is no longer active",
            "This page can no longer be submitted. It may already have succeeded—return to ChatGPT and wait for it to finish. Otherwise, click Connect again and approve the new Mac prompt; use the code only as a fallback.",
        )
    };
    (
        StatusCode::CONFLICT,
        Html(format!(
            "<!doctype html><html><head><meta charset=\"utf-8\"><title>{heading}</title>\n<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:36rem;margin:4rem auto;padding:0 1rem}}strong{{font-weight:600}}</style></head>\n<body><h1>{heading}</h1><p>{message}</p></body></html>"
        )),
    )
        .into_response()
}

/// Translate the store's link-code failure reasons into the exact cause and
/// the concrete next step, shown directly on the consent form.
fn friendly_link_code_error(reason: &str) -> String {
    match reason {
        "unknown link code" => "That code is not recognized. Codes come from the Thumble relay on your Mac, can be used once, and last one hour. Check for typos and try again, or run `thumble relay rotate` on your Mac for a fresh code.".to_owned(),
        "link code already used" => "That code was already used — each code links exactly once. Run `thumble relay rotate` on your Mac for a fresh code, then submit it here.".to_owned(),
        "link code expired" => "That code expired — codes stay valid for one hour. Run `thumble relay rotate` on your Mac for a fresh code, then submit it here.".to_owned(),
        reason if reason.contains("locked") => "Too many incorrect attempts with that code. Run `thumble relay rotate` on your Mac for a fresh code, then submit it here.".to_owned(),
        other => format!(
            "The link could not be completed ({other}). Run `thumble relay rotate` on your Mac for a fresh code, then submit it here."
        ),
    }
}

/// Shown when the authorization succeeded at this end but the relay's link
/// socket (which must stay open to receive its token) had already closed.
fn relay_window_closed_page() -> Response {
    Html(
        r#"<!doctype html><html><head><meta charset="utf-8"><title>Relay window closed</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:36rem;margin:4rem auto;padding:0 1rem;line-height:1.45}
code{background:#f3f3f3;padding:.1rem .4rem;border-radius:.3rem}</style></head>
<body><h1>Your Mac's relay window closed</h1>
<p>The approval (or fallback code) was accepted here, but the relay process on
your Mac had already stopped waiting, so it never received its device token.</p>
<p><strong>Fix:</strong> start <code>thumble relay connect</code> on your Mac,
return to ChatGPT, click <strong>Connect</strong> again, and approve the new Mac
prompt. On a headless Mac, <code>thumble relay rotate</code> creates a fresh
fallback code.</p>
</body></html>"#,
    )
    .into_response()
}

#[derive(Debug, Deserialize)]
pub struct AuthorizeQuery {
    pub response_type: Option<String>,
    pub client_id: Option<String>,
    pub redirect_uri: Option<String>,
    pub resource: Option<String>,
    pub state: Option<String>,
    pub scope: Option<String>,
    pub code_challenge: Option<String>,
    pub code_challenge_method: Option<String>,
    /// Optional six-digit link code used only to prefill the consent input
    /// (for example when the relay hands the code to the browser).
    pub code: Option<String>,
}

/// Validate the connector's OAuth request, push approval to an eligible Mac
/// when one is online, and otherwise render the fallback-code consent page.
pub async fn authorize(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    connect_info: axum::extract::ConnectInfo<std::net::SocketAddr>,
    Query(query): Query<AuthorizeQuery>,
) -> Response {
    let source = crate::http::client_source_key(&headers, Some(&connect_info));
    if let Err(error) = state.oauth_rate_limiter.allow_authorization(&source) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Html(format!(
                "<h1>Try again later</h1><p>{}</p>",
                html_escape(&error)
            )),
        )
            .into_response();
    }
    let issuer = state.base_url();
    let redirect_error = |oauth_error: &str,
                          description: &str,
                          redirect: Option<&str>,
                          request_state: Option<&str>| {
        let Some(redirect) = redirect else {
            return (
                StatusCode::BAD_REQUEST,
                Html(format!(
                    "<h1>Bad request</h1><p>{}</p>",
                    html_escape(description)
                )),
            )
                .into_response();
        };
        // Every non-None redirect reaches here only after exact membership in
        // the registered client's redirect URI set has been established.
        let mut parameters = vec![
            ("error", oauth_error),
            ("error_description", description),
            ("iss", issuer.as_str()),
        ];
        if let Some(request_state) = request_state {
            parameters.push(("state", request_state));
        }
        match oauth_response_url(redirect, &parameters) {
            Ok(url) => oauth_redirect(&url),
            Err(error) => server_error(error),
        }
    };
    let error_redirect =
        |description: &str, redirect: Option<&str>, request_state: Option<&str>| {
            redirect_error("invalid_request", description, redirect, request_state)
        };

    let client_id = match query.client_id.as_deref() {
        Some(client_id) => client_id,
        None => return error_redirect("client_id is required", None, None),
    };
    let client = match state.store.client(client_id) {
        Ok(Some(client)) => client,
        _ => return error_redirect("unknown client_id", None, None),
    };
    let redirect_uri = match query.redirect_uri.as_deref() {
        Some(uri) => uri,
        None => return error_redirect("redirect_uri is required", None, None),
    };
    if !client.redirect_uris.iter().any(|uri| uri == redirect_uri) {
        // Never redirect to an unregistered URI: return a local error page.
        return error_redirect(
            "redirect_uri is not registered for this client",
            None,
            query.state.as_deref(),
        );
    }
    let resource = match requested_resource_kind(&issuer, query.resource.as_deref()) {
        Ok(resource) => resource,
        Err(error) => {
            return redirect_error(
                "invalid_target",
                &error,
                Some(redirect_uri),
                query.state.as_deref(),
            )
        }
    };
    if query.response_type.as_deref() != Some("code") {
        return error_redirect(
            "only response_type=code is supported",
            Some(redirect_uri),
            query.state.as_deref(),
        );
    }
    if query.code_challenge_method.as_deref() != Some("S256") {
        return error_redirect(
            "code_challenge_method must be S256",
            Some(redirect_uri),
            query.state.as_deref(),
        );
    }
    let Some(code_challenge) = query.code_challenge.as_deref() else {
        return error_redirect(
            "code_challenge (PKCE S256) is required",
            Some(redirect_uri),
            query.state.as_deref(),
        );
    };
    if !valid_pkce_challenge(code_challenge) {
        return error_redirect(
            "code_challenge must be 43-128 base64url characters",
            Some(redirect_uri),
            query.state.as_deref(),
        );
    }
    let requested_scope = query.scope.as_deref().unwrap_or(match resource {
        ResourceKind::Relay => "thumble.read thumble.draft thumble.config offline_access",
        ResourceKind::Builder => "",
    });
    let granted_scopes = match resource {
        ResourceKind::Relay => scopes::parse_relay_scopes(requested_scope),
        ResourceKind::Builder => scopes::parse_builder_scopes(requested_scope),
    };
    let granted_scopes = match granted_scopes {
        Ok(scopes) => scopes,
        Err(error) => return error_redirect(&error, Some(redirect_uri), query.state.as_deref()),
    };

    let granted_scope = granted_scopes.join(" ");
    if resource == ResourceKind::Builder {
        let (request_id, consent_nonce) = match state.store.create_builder_authorization_request(
            client_id,
            redirect_uri,
            query.state.as_deref().unwrap_or_default(),
            &granted_scope,
            code_challenge,
            AUTH_CODE_TTL_SECONDS,
        ) {
            Ok(created) => created,
            Err(error) => return server_error(error),
        };
        let cookie = match builder_consent_cookie(&issuer, &consent_nonce, false) {
            Ok(cookie) => cookie,
            Err(error) => return server_error(error),
        };
        return with_builder_cookie(
            Html(builder_consent_html(
                &request_id,
                &granted_scope,
                &consent_nonce,
            ))
            .into_response(),
            cookie,
        );
    }
    let request_id = match state.store.create_authorization_request_for_resource(
        client_id,
        redirect_uri,
        query.state.as_deref().unwrap_or_default(),
        &granted_scope,
        code_challenge,
        resource,
        AUTH_CODE_TTL_SECONDS,
    ) {
        Ok(request_id) => request_id,
        Err(error) => return server_error(error),
    };

    let prefilled_code = query
        .code
        .as_deref()
        .map(str::trim)
        .filter(|value| value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_digit()))
        .map(|value| value.to_owned())
        .unwrap_or_default();

    // Click-to-connect: push the approval to the user's Mac(s) and let the
    // page poll for the decision. The six-digit code remains the fallback
    // (headless Macs, SSH sessions, or a missed dialog).
    let notified = trusted_push_connector(redirect_uri).map_or(0, |connector_name| {
        state.tunnels.offer_connector_approval(
            &request_id,
            connector_name,
            &granted_scope,
            &source,
            CONNECTOR_APPROVAL_TTL_SECONDS,
        )
    });
    if notified > 0 {
        return Html(approval_waiting_html(
            &request_id,
            &granted_scope,
            &prefilled_code,
            notified,
        ))
        .into_response();
    }

    Html(consent_form_html(
        &request_id,
        &granted_scope,
        None,
        &prefilled_code,
    ))
    .into_response()
}

fn builder_consent_html(request_id: &str, granted_scope: &str, browser_proof: &str) -> String {
    let offline = if granted_scope
        .split_whitespace()
        .any(|scope| scope == scopes::SCOPE_OFFLINE_ACCESS)
    {
        "<li><b>offline_access</b> — refresh access without repeating this consent</li>"
    } else {
        ""
    };
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><title>Authorize Thumble Builder</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;line-height:1.45}}
.panel{{border:1px solid #ddd;border-radius:.7rem;padding:1rem 1.2rem}}button{{font-size:1rem;padding:.65rem 1rem;margin:.5rem .5rem 0 0}}
.deny{{background:white;border:1px solid #999}}</style></head><body>
<h1>Authorize Thumble Builder</h1><div class="panel"><p>This connector is requesting a fresh, private builder authorization. It does not connect to a Mac, device, or tunnel.</p>
<ul><li><b>thumble.build</b> — use the hosted controller builder</li>{offline}</ul>
<p>This creates a new opaque authorization identity for this consent. No existing account selects that identity.</p>
<form method="post" action="/authorize/builder/confirm">
<input type="hidden" name="request_id" value="{request_id}">
<input type="hidden" name="browser_proof" value="{browser_proof}">
<button type="submit" name="decision" value="allow">Authorize builder</button>
<button class="deny" type="submit" name="decision" value="deny">Deny</button>
</form></div></body></html>"#,
        request_id = html_escape(request_id),
        browser_proof = html_escape(browser_proof),
    )
}

fn unavailable_builder_authorization(reason: &str) -> Response {
    let message = if reason.contains("expired") {
        "This builder authorization expired. Return to the connector and start a fresh request."
    } else if reason.contains("used") {
        "This builder authorization was already submitted and cannot be used again."
    } else {
        "This builder authorization is not available. Return to the connector and start again."
    };
    (
        StatusCode::CONFLICT,
        Html(format!(
            "<!doctype html><html><head><meta charset=\"utf-8\"><title>Authorization unavailable</title></head><body><h1>Authorization unavailable</h1><p>{}</p></body></html>",
            html_escape(message)
        )),
    )
        .into_response()
}

#[derive(Debug, Deserialize)]
pub struct BuilderConfirmForm {
    pub request_id: String,
    pub decision: String,
    /// Fallback for browser/webview contexts that partition or omit cookies.
    /// The store still verifies this one-time proof against its digest.
    pub browser_proof: Option<String>,
}

pub async fn authorize_builder_confirm(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    connect_info: axum::extract::ConnectInfo<std::net::SocketAddr>,
    axum::Form(form): axum::Form<BuilderConfirmForm>,
) -> Response {
    let issuer = state.base_url();
    let source = crate::http::client_source_key(&headers, Some(&connect_info));
    // Charge every confirmation attempt before parsing proof material, which
    // bounds both rejection telemetry and brute-force work.
    if let Err(error) = state.oauth_rate_limiter.allow_authorization(&source) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Html(format!(
                "<h1>Try again later</h1><p>{}</p>",
                html_escape(&error)
            )),
        )
            .into_response();
    }

    let form_nonce = match form.browser_proof.as_deref() {
        Some(value) if valid_builder_consent_proof(value) => Some(value),
        Some(_) => return forbidden_builder_consent("malformed-form-proof"),
        None => None,
    };
    let consent_nonce = match form_nonce {
        // The form-carried proof is authoritative for isolated OAuth
        // webviews. It is random, stored only as a digest, request/PKCE/client/
        // redirect/resource-bound, and atomically single-use. Origin and
        // cookies are therefore unnecessary (and unreliable) on this path;
        // stale partitioned cookies are deliberately ignored.
        Some(form_nonce) => form_nonce,
        None => {
            // Backward-compatible cookie-only forms retain the strict exact-
            // origin check because they do not carry the form proof.
            if !same_gateway_origin(&headers, &issuer) {
                return forbidden_builder_consent("cookie-only-origin");
            }
            match builder_consent_nonce(&headers) {
                Some(cookie_nonce) => cookie_nonce,
                None => return forbidden_builder_consent("missing-browser-proof"),
            }
        }
    };
    if form.request_id.is_empty() || form.request_id.len() > 128 {
        return (StatusCode::BAD_REQUEST, Html("<h1>Bad request</h1>")).into_response();
    }
    let clear_cookie = match builder_consent_cookie(&issuer, "", true) {
        Ok(cookie) => cookie,
        Err(error) => return server_error(error),
    };
    if form.decision == "deny" {
        let request = match state
            .store
            .deny_builder_authorization(&form.request_id, consent_nonce)
        {
            Ok(Ok(request)) => request,
            Ok(Err(reason)) if reason == "builder consent verification failed" => {
                return forbidden_builder_consent("stored-proof-mismatch")
            }
            Ok(Err(reason)) => return unavailable_builder_authorization(&reason),
            Err(error) => return server_error(error),
        };
        let mut parameters = vec![
            ("error", "access_denied"),
            ("error_description", "builder authorization was denied"),
            ("iss", issuer.as_str()),
        ];
        if !request.state.is_empty() {
            parameters.push(("state", request.state.as_str()));
        }
        return match oauth_response_url(&request.redirect_uri, &parameters) {
            Ok(url) => with_builder_cookie(oauth_redirect(&url), clear_cookie),
            Err(error) => server_error(error),
        };
    }
    if form.decision != "allow" {
        return (StatusCode::BAD_REQUEST, Html("<h1>Bad request</h1>")).into_response();
    }
    let (authorization_code, builder_id, request) = match state
        .store
        .complete_new_builder_authorization(&form.request_id, consent_nonce, AUTH_CODE_TTL_SECONDS)
    {
        Ok(Ok(completed)) => completed,
        Ok(Err(reason)) if reason == "builder consent verification failed" => {
            return forbidden_builder_consent("stored-proof-mismatch")
        }
        Ok(Err(reason)) => return unavailable_builder_authorization(&reason),
        Err(error) => return server_error(error),
    };
    let principal = match Principal::builder(builder_id) {
        Ok(principal) => principal,
        Err(error) => return server_error(error),
    };
    audit_principal("builder consent granted", &principal);
    let mut parameters = vec![
        ("code", authorization_code.as_str()),
        ("iss", issuer.as_str()),
    ];
    if !request.state.is_empty() {
        parameters.push(("state", request.state.as_str()));
    }
    match oauth_response_url(&request.redirect_uri, &parameters) {
        // Isolated OAuth webviews can leave a POSTed consent page visible
        // instead of following a cross-origin 302 (notably loopback callbacks
        // owned by the ChatGPT desktop app). Reuse the relay flow's explicit
        // no-script handoff page so meta refresh or the visible link completes
        // the exact same validated callback without minting another code.
        Ok(url) => with_builder_cookie(authorization_complete(&url, None), clear_cookie),
        Err(error) => server_error(error),
    }
}

fn scope_list_markup(granted_scope: &str) -> String {
    granted_scope
        .split_whitespace()
        .map(|scope| match scope {
            scopes::SCOPE_READ => {
                "<li><b>thumble.read</b> — read host status, profiles, controls, and previews</li>"
                    .to_owned()
            }
            scopes::SCOPE_DRAFT => {
                "<li><b>thumble.draft</b> — create and edit private controller drafts</li>"
                    .to_owned()
            }
            scopes::SCOPE_CONFIG => {
                "<li><b>thumble.config</b> — save drafts and switch the active profile</li>"
                    .to_owned()
            }
            scopes::SCOPE_OFFLINE_ACCESS => {
                "<li><b>offline_access</b> — refresh access without repeating consent</li>"
                    .to_owned()
            }
            _ => String::new(),
        })
        .collect::<String>()
}

/// The code-entry form fragment shared by the standalone consent page and
/// the click-to-connect waiting page's fallback.
fn consent_form_fragment(request_id: &str, prefilled_code: &str, note: &str) -> String {
    let prefilled_value =
        if prefilled_code.len() == 6 && prefilled_code.bytes().all(|byte| byte.is_ascii_digit()) {
            format!(" value=\"{}\"", html_escape(prefilled_code))
        } else {
            String::new()
        };
    format!(
        r#"<form method="post" action="/authorize/confirm">
<input type="hidden" name="request_id" value="{request_id}">
<label for="code">Fallback: enter the six-digit code from your Mac:</label><br>
<input type="text" id="code" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{{6}}" maxlength="6" required{prefilled_value}>
<button type="submit">Link device</button>{note}</form>"#,
        request_id = html_escape(request_id),
        prefilled_value = prefilled_value,
        note = note,
    )
}

/// Render the consent form. `error` (if any) is shown in a prominent banner
/// so a wrong or expired code fails visibly on this page with the exact fix,
/// instead of silently bouncing the user back to the connector with an
/// opaque OAuth error. `prefilled_code` (a validated six-digit value) seeds
/// the input so retries need only one correction.
fn consent_form_html(
    request_id: &str,
    granted_scope: &str,
    error: Option<&str>,
    prefilled_code: &str,
) -> String {
    let scopes_markup = scope_list_markup(granted_scope);
    let error_banner = error
        .map(|message| {
            format!(
                "<div class=\"error\"><strong>Link failed.</strong> {}</div>",
                html_escape(message)
            )
        })
        .unwrap_or_default();
    let form = consent_form_fragment(
        request_id,
        prefilled_code,
        "<p style=\"color:#666\">Click <strong>Link device</strong> once and wait for the
connector to return. A second click reuses the one-time authorization request
and will show an already-submitted message. Input injection is never granted
remotely. Configuration writes also require the
<code>--allow-config-write</code> opt-in on your Mac.</p>",
    );
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8"><title>Link Thumble to the connector</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem}}
code{{background:#f3f3f3;padding:.1rem .4rem;border-radius:.3rem}}
input[type=text]{{font-size:1.5rem;letter-spacing:.4em;width:12rem;padding:.4rem;text-align:center}}
button{{font-size:1.1rem;padding:.6rem 1.4rem;margin-top:1rem}}
.error{{background:#fdecec;border:1px solid #f1b8b8;color:#8f1d1d;padding:.8rem 1rem;border-radius:.5rem;margin-bottom:1rem;line-height:1.45}}</style></head>
<body><h1>Link your Mac's Thumble controller</h1>
{error_banner}<p>This connector will drive the Thumble Host on your own Mac through an
encrypted tunnel. Your Mac must be running <code>thumble-host</code> and
<code>thumble-mcp --relay</code>. If your Mac did not show an approval
prompt, link it with the relay's six-digit code — it was printed (and usually
copied to your clipboard) by the relay. Codes work once and last one hour.</p>
<p>Scopes requested:<ul>{scopes_markup}</ul></p>
{form}
</body></html>"#
    )
}

/// The click-to-connect page: an approval prompt was pushed to the user's
/// Mac(s); poll the decision endpoint until the Mac answers, the request is
/// completed through the fallback code, or the approval window ends.
fn approval_waiting_html(
    request_id: &str,
    granted_scope: &str,
    prefilled_code: &str,
    notified: usize,
) -> String {
    let scopes_markup = scope_list_markup(granted_scope);
    let escaped_request_id = html_escape(request_id);
    let wait_url = format!("/authorize/wait?request_id={escaped_request_id}");
    let fallback_url =
        if prefilled_code.len() == 6 && prefilled_code.bytes().all(|byte| byte.is_ascii_digit()) {
            format!(
                "/authorize/code?request_id={escaped_request_id}&amp;code={}",
                html_escape(prefilled_code)
            )
        } else {
            format!("/authorize/code?request_id={escaped_request_id}")
        };
    let prompt_target = if notified == 1 {
        "an approval prompt on your Mac".to_owned()
    } else {
        format!("approval prompts on {notified} of your linked Macs")
    };
    format!(
        r#"<!doctype html><html><head><meta charset="utf-8">
<meta http-equiv="refresh" content="{APPROVAL_POLL_SECONDS};url={wait_url}">
<title>Approve on your Mac</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem;line-height:1.45}}
code{{background:#f3f3f3;padding:.1rem .4rem;border-radius:.3rem}}
input[type=text]{{font-size:1.5rem;letter-spacing:.4em;width:12rem;padding:.4rem;text-align:center}}
button{{font-size:1.1rem;padding:.6rem 1.4rem;margin-top:1rem}}
.pending{{display:inline-block;width:.9rem;height:.9rem;border-radius:50%;border:.18rem #c9c9c9 solid;border-top-color:#0879f9;animation:spin 1s linear infinite;vertical-align:-0.1rem;margin-right:.4rem}}
@keyframes spin{{to{{transform:rotate(360deg)}}}}
details{{margin-top:1.5rem}}summary{{cursor:pointer;color:#0879f9}}
a.fallback{{display:inline-block;margin-top:.7rem;padding:.55rem .8rem;border-radius:.45rem;background:#f2f2f2;color:#222;text-decoration:none}}</style></head>
<body><h1><span class="pending"></span>Waiting for your Mac…</h1>
<p>The connector asked to link, and this page sent {prompt_target}.
Click <b>Allow</b> there and this page will finish by itself — no code needed.</p>
<p>Approve only if you just started this connection yourself. Scopes
requested:<ul>{scopes_markup}</ul></p>
<details><summary>My Mac did not ask — use the six-digit code instead</summary>
<p>The polling refresh would interrupt typing, so code entry opens on a stable page.</p>
<a class="fallback" href="{fallback_url}">Enter fallback code</a></details>
<p style="color:#666">This page keeps checking automatically and stops after a few
minutes. Keep your Mac online with <code>thumble relay connect</code> (or the
installed background service) while connecting.</p>
</body></html>"#
    )
}

/// Complete an authorization request by binding it to a pending link
/// window: mint (or rotate) the device identity, issue the OAuth code, and
/// deliver the device token to the waiting relay socket. Shared by the
/// six-digit code path and the pushed-approval path.
///
/// The caller must have consumed (or otherwise validated as usable) the
/// authorization request beforehand; this function never re-checks it.
async fn complete_pending_link_grant(
    state: &Arc<AppState>,
    request: &crate::store::AuthorizationRequestRecord,
    pending_key: &str,
) -> (Response, bool) {
    let issuer = state.base_url();
    let device_name = state.tunnels.pending_link_name(pending_key);
    let rotating_device_id = state.tunnels.pending_link_rotation(pending_key);
    let previous_connection_key = rotating_device_id
        .as_deref()
        .and_then(|device_id| state.tunnels.device_connection_key(device_id));
    let is_rotation = rotating_device_id.is_some();
    let (device_id, device_token) = match rotating_device_id.clone() {
        // The link socket authenticated with this device's current token:
        // rotate the credential in place so the same Mac keeps its identity,
        // OAuth bindings, and manifest, with no dual-valid-token window.
        Some(existing_id) => {
            let name = device_name.as_deref().unwrap_or("linked Mac");
            match state.store.rotate_device_token(&existing_id, name) {
                Ok(token) => (existing_id, token),
                Err(error) => return (server_error(error), false),
            }
        }
        None => match state
            .store
            .create_device(device_name.as_deref().unwrap_or("linked Mac"))
        {
            Ok(created) => created,
            Err(error) => return (server_error(error), false),
        },
    };
    // Rotation invalidates the old database credential immediately. Close the
    // exact control connection authenticated with it on every subsequent
    // path, including persistence or link-socket failure.
    if let Some(previous_connection_key) = previous_connection_key.as_deref() {
        let _ = state
            .tunnels
            .request_device_reconnect(&device_id, previous_connection_key)
            .await;
    }
    let authorization_code = match state.store.create_auth_code(
        &request.client_id,
        &request.redirect_uri,
        &request.scope,
        &request.code_challenge,
        &device_id,
        AUTH_CODE_TTL_SECONDS,
    ) {
        Ok(code) => code,
        Err(error) => {
            if !is_rotation {
                state.store.revoke_device(&device_id).ok();
            }
            return (server_error(error), false);
        }
    };
    if state
        .tunnels
        .grant_pending_link(pending_key, &device_id, &device_token)
        .await
        .is_err()
    {
        // Only freshly created devices are rolled back on grant failure; a
        // rotation keeps the device row (and the account's OAuth bindings)
        // intact even if the link socket dropped mid-handoff.
        if !is_rotation {
            state.store.revoke_device(&device_id).ok();
        }
        return (relay_window_closed_page(), false);
    }
    let mut parameters = vec![
        ("code", authorization_code.as_str()),
        ("iss", issuer.as_str()),
    ];
    if !request.state.is_empty() {
        parameters.push(("state", request.state.as_str()));
    }
    let url = match oauth_response_url(&request.redirect_uri, &parameters) {
        Ok(url) => url,
        Err(error) => return (server_error(error), false),
    };
    eprintln!("gateway: OAuth device link granted; returning authorization response");
    (authorization_complete(&url, device_name.as_deref()), true)
}

#[derive(Debug, Deserialize)]
pub struct ConfirmForm {
    pub request_id: String,
    pub code: String,
}

pub async fn authorize_confirm(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    connect_info: axum::extract::ConnectInfo<std::net::SocketAddr>,
    axum::Form(form): axum::Form<ConfirmForm>,
) -> Response {
    let source = crate::http::client_source_key(&headers, Some(&connect_info));
    if let Err(error) = state.link_rate_limiter.allow_confirmation(&source) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Html(format!(
                "<h1>Try again shortly</h1><p>{}</p>",
                html_escape(&error)
            )),
        )
            .into_response();
    }
    let request = match state.store.authorization_request(&form.request_id) {
        Ok(Ok(request)) => request,
        Ok(Err(reason)) => return unavailable_authorization_request(&reason),
        Err(error) => return server_error(error),
    };
    // Code-entry failures re-render this page with the exact reason and fix
    // so the user can correct and retry in place. Only genuine completion
    // outcomes ever redirect back to the connector.
    let retry = |message: String, echoed_code: &str| {
        Html(consent_form_html(
            &form.request_id,
            &request.scope,
            Some(&message),
            echoed_code,
        ))
        .into_response()
    };

    if let Err(error) = state.store.record_authorization_attempt(&form.request_id) {
        return unavailable_authorization_request(&error);
    }
    let code = form.code.trim();
    if code.len() != 6 || !code.bytes().all(|byte| byte.is_ascii_digit()) {
        return retry(
            "Enter exactly six digits. The code is printed (and copied to your \
             clipboard) by the Thumble relay on your Mac — for example 482915."
                .to_owned(),
            "",
        );
    }
    let (request, pending_key) = match state
        .store
        .consume_authorization_with_link_code(&form.request_id, code)
    {
        Ok(Ok(claimed)) => claimed,
        Ok(Err(error)) if error.starts_with("authorization request") => {
            return unavailable_authorization_request(&error)
        }
        Ok(Err(error)) => return retry(friendly_link_code_error(&error), code),
        Err(error) => return server_error(error),
    };
    let (response, granted) = complete_pending_link_grant(&state, &request, &pending_key).await;
    state
        .tunnels
        .complete_connector_approval(
            &form.request_id,
            granted,
            if granted {
                "linked with the fallback code"
            } else {
                "fallback-code link did not complete"
            },
        )
        .await;
    response
}

#[derive(Debug, Deserialize)]
pub struct WaitQuery {
    pub request_id: String,
}

#[derive(Debug, Deserialize)]
pub struct CodePageQuery {
    pub request_id: String,
    pub code: Option<String>,
}

/// Stable fallback page without polling, so a headless user can type the
/// six-digit code without a meta refresh discarding their input.
pub async fn authorize_code(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    connect_info: axum::extract::ConnectInfo<std::net::SocketAddr>,
    Query(query): Query<CodePageQuery>,
) -> Response {
    let source = crate::http::client_source_key(&headers, Some(&connect_info));
    if let Err(error) = state.oauth_rate_limiter.allow_wait(&source) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Html(format!(
                "<h1>Try again later</h1><p>{}</p>",
                html_escape(&error)
            )),
        )
            .into_response();
    }
    let request_id = query.request_id.trim();
    if request_id.len() > 128 {
        return (
            StatusCode::BAD_REQUEST,
            Html("<h1>Bad request</h1><p>Malformed request id.</p>"),
        )
            .into_response();
    }
    let request = match state.store.authorization_request(request_id) {
        Ok(Ok(request)) => request,
        Ok(Err(reason)) => return unavailable_authorization_request(&reason),
        Err(error) => return server_error(error),
    };
    let prefilled_code = query
        .code
        .as_deref()
        .map(str::trim)
        .filter(|value| value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_digit()))
        .unwrap_or_default();
    Html(consent_form_html(
        request_id,
        &request.scope,
        None,
        prefilled_code,
    ))
    .into_response()
}

fn terminal_page(title: &str, body: &str) -> Response {
    (
        StatusCode::OK,
        Html(format!(
            r#"<!doctype html><html><head><meta charset="utf-8"><title>{title}</title>\n<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:36rem;margin:4rem auto;padding:0 1rem;line-height:1.45}}\ncode{{background:#f3f3f3;padding:.1rem .4rem;border-radius:.3rem}}</style></head>\n<body><h1>{title}</h1>{body}</body></html>"#,
            title = html_escape(title),
            body = body,
        )),
    )
        .into_response()
}

fn approval_denied_page() -> Response {
    terminal_page(
        "Connection declined",
        "<p>The request was declined on your Mac, so nothing was connected. You
can try again: return to the connector and start the connection once more,
then click <b>Allow</b> on your Mac when it asks.</p>",
    )
}

fn approval_timeout_page() -> Response {
    terminal_page(
        "No answer from your Mac",
        "<p>Your Mac did not answer the approval prompt in time, so this
connection attempt ended without linking anything.</p><p><b>Fix:</b> make
sure the relay is running with <code>thumble relay connect</code> (or the
installed background service) and your Mac is awake, then return to the
connector and connect again. On a headless Mac, use the six-digit code from
<code>thumble relay rotate</code> on the connector's code page instead.</p>",
    )
}

fn device_went_offline_page() -> Response {
    terminal_page(
        "Your Mac went offline",
        "<p>The approval was granted, but this Mac's tunnel had already
disconnected, so the connection could not complete.</p><p><b>Fix:</b> bring
the relay back with <code>thumble relay connect</code> on your Mac, then
return to the connector and connect again.</p>",
    )
}

fn already_completed_page() -> Response {
    terminal_page(
        "Already connected",
        "<p>This connection request was already completed — most likely you
also linked it with the six-digit code, or approved it in another browser
tab. Return to the connector; if it did not finish, start a fresh connection
there.</p>",
    )
}

/// Poll endpoint for the click-to-connect page. The waiting page's meta
/// refresh lands here every couple of seconds; the response either keeps
/// waiting, or finishes the OAuth handshake from a Mac-side decision.
pub async fn authorize_wait(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    connect_info: axum::extract::ConnectInfo<std::net::SocketAddr>,
    Query(query): Query<WaitQuery>,
) -> Response {
    let source = crate::http::client_source_key(&headers, Some(&connect_info));
    if let Err(error) = state.oauth_rate_limiter.allow_wait(&source) {
        return (
            StatusCode::TOO_MANY_REQUESTS,
            Html(format!(
                "<h1>Try again later</h1><p>{}</p>",
                html_escape(&error)
            )),
        )
            .into_response();
    }
    let request_id = query.request_id.trim().to_owned();
    if request_id.len() > 128 {
        return (
            StatusCode::BAD_REQUEST,
            Html("<h1>Bad request</h1><p>Malformed request id.</p>"),
        )
            .into_response();
    }
    // A request that is already consumed means some path completed it
    // (fallback code or a prior poll after approval).
    let request = match state.store.authorization_request(&request_id) {
        Ok(Ok(request)) => request,
        Ok(Err(reason)) if reason == "authorization request already used" => {
            return already_completed_page();
        }
        Ok(Err(reason)) => return unavailable_authorization_request(&reason),
        Err(error) => return server_error(error),
    };
    let decision = match state.tunnels.approval_decision(&request_id) {
        Some(decision) => decision,
        None => {
            // Still waiting: keep polling while the approval window is open.
            let remaining = state.tunnels.approval_remaining_seconds(&request_id);
            return match remaining {
                Some(_) => {
                    let notified = state
                        .tunnels
                        .approval_target_count(&request_id)
                        .unwrap_or(1);
                    Html(approval_waiting_html(
                        &request_id,
                        &request.scope,
                        "",
                        notified,
                    ))
                    .into_response()
                }
                None => match state.store.consume_authorization_request(&request_id) {
                    Ok(()) => approval_timeout_page(),
                    Err(error) if error.contains("already used") => already_completed_page(),
                    Err(error) => unavailable_authorization_request(&error),
                },
            };
        }
    };
    let (target, approved) = decision;
    if !approved {
        if let Err(error) = state.store.consume_authorization_request(&request_id) {
            if error.contains("already used") {
                return already_completed_page();
            }
            return unavailable_authorization_request(&error);
        }
        state
            .tunnels
            .complete_connector_approval(&request_id, false, "declined on the Mac")
            .await;
        return approval_denied_page();
    }
    if let Err(error) = state.store.consume_authorization_request(&request_id) {
        if error == "authorization request already used" {
            return already_completed_page();
        }
        return unavailable_authorization_request(&error);
    }
    match target {
        ApprovalTarget::PendingLink(pending_key) => {
            let (response, granted) =
                complete_pending_link_grant(&state, &request, &pending_key).await;
            state
                .tunnels
                .complete_connector_approval(
                    &request_id,
                    granted,
                    if granted {
                        "approved on the Mac"
                    } else {
                        "the approved link did not complete"
                    },
                )
                .await;
            response
        }
        ApprovalTarget::Device {
            device_id,
            connection_key: _,
        } => {
            if !state.tunnels.device_online(&device_id) {
                state
                    .tunnels
                    .complete_connector_approval(
                        &request_id,
                        false,
                        "the device went offline before the grant",
                    )
                    .await;
                return device_went_offline_page();
            }
            let device_name = state
                .store
                .device(&device_id)
                .ok()
                .flatten()
                .map(|d| d.name);
            let authorization_code = match state.store.create_auth_code(
                &request.client_id,
                &request.redirect_uri,
                &request.scope,
                &request.code_challenge,
                &device_id,
                AUTH_CODE_TTL_SECONDS,
            ) {
                Ok(code) => code,
                Err(error) => return server_error(error),
            };
            let issuer = state.base_url();
            let mut parameters = vec![
                ("code", authorization_code.as_str()),
                ("iss", issuer.as_str()),
            ];
            if !request.state.is_empty() {
                parameters.push(("state", request.state.as_str()));
            }
            let url = match oauth_response_url(&request.redirect_uri, &parameters) {
                Ok(url) => url,
                Err(error) => return server_error(error),
            };
            match Principal::device(&device_id) {
                Ok(principal) => audit_principal("connector approved", &principal),
                Err(error) => return server_error(error),
            }
            state
                .tunnels
                .complete_connector_approval(&request_id, true, "ChatGPT connected")
                .await;
            authorization_complete(&url, device_name.as_deref())
        }
    }
}

#[derive(Debug, Deserialize)]
pub struct TokenRequest {
    pub grant_type: String,
    pub code: Option<String>,
    pub redirect_uri: Option<String>,
    pub client_id: Option<String>,
    pub resource: Option<String>,
    pub code_verifier: Option<String>,
    pub refresh_token: Option<String>,
}

fn token_error(status: StatusCode, error: &str, description: &str) -> Response {
    (
        status,
        [(
            header::WWW_AUTHENTICATE,
            format!("Bearer error=\"{error}\""),
        )],
        Json(serde_json::json!({
            "error": error,
            "error_description": description,
        })),
    )
        .into_response()
}

pub async fn token(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    connect_info: axum::extract::ConnectInfo<std::net::SocketAddr>,
    axum::Form(form): axum::Form<TokenRequest>,
) -> Response {
    let source = crate::http::client_source_key(&headers, Some(&connect_info));
    if let Err(error) = state.oauth_rate_limiter.allow_token(&source) {
        return token_error(
            StatusCode::TOO_MANY_REQUESTS,
            "temporarily_unavailable",
            &error,
        );
    }
    let resource = match requested_resource_kind(&state.base_url(), form.resource.as_deref()) {
        Ok(resource) => resource,
        Err(error) => {
            return token_error(StatusCode::BAD_REQUEST, "invalid_target", &error);
        }
    };
    match form.grant_type.as_str() {
        "authorization_code" => token_authorization_code(state, form, resource).await,
        "refresh_token" => token_refresh(state, form, resource).await,
        other => token_error(
            StatusCode::BAD_REQUEST,
            "unsupported_grant_type",
            &format!("grant_type {other} is not supported"),
        ),
    }
}

fn token_store_error(detail: &str) -> Response {
    let bounded: String = detail
        .chars()
        .map(|character| {
            if character.is_control() {
                ' '
            } else {
                character
            }
        })
        .take(512)
        .collect();
    eprintln!("gateway: OAuth token store error: {bounded}");
    token_error(
        StatusCode::INTERNAL_SERVER_ERROR,
        "server_error",
        "the token request could not be completed",
    )
}

async fn token_authorization_code(
    state: Arc<AppState>,
    form: TokenRequest,
    resource: ResourceKind,
) -> Response {
    let Some(code) = form.code.as_deref() else {
        return token_error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "code is required",
        );
    };
    let Some(client_id) = form.client_id.as_deref() else {
        return token_error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "client_id is required",
        );
    };
    let Some(redirect_uri) = form.redirect_uri.as_deref() else {
        return token_error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "redirect_uri is required",
        );
    };
    let Some(verifier) = form.code_verifier.as_deref() else {
        return token_error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "code_verifier is required",
        );
    };
    if !valid_pkce_verifier(verifier) {
        return token_error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "code_verifier must be 43-128 RFC 7636 unreserved characters",
        );
    }
    let grant = match state.store.exchange_auth_code_for_resource(
        code,
        client_id,
        redirect_uri,
        verifier,
        resource,
        ACCESS_TOKEN_TTL_SECONDS,
        REFRESH_TOKEN_TTL_SECONDS,
    ) {
        Ok(Ok(grant)) => grant,
        Ok(Err(_)) => {
            return token_error(StatusCode::BAD_REQUEST, "invalid_grant", "invalid grant");
        }
        Err(error) => return token_store_error(&error),
    };
    audit_principal("authorization code exchanged", &grant.binding.principal);
    token_success(
        grant.access_token,
        grant.refresh_token,
        grant.scope,
        ACCESS_TOKEN_TTL_SECONDS,
    )
}

async fn token_refresh(
    state: Arc<AppState>,
    form: TokenRequest,
    resource: ResourceKind,
) -> Response {
    let Some(refresh_token) = form.refresh_token.as_deref() else {
        return token_error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "refresh_token is required",
        );
    };
    let Some(client_id) = form.client_id.as_deref() else {
        return token_error(
            StatusCode::BAD_REQUEST,
            "invalid_request",
            "client_id is required",
        );
    };
    let rotated = state.store.rotate_refresh_token_for_resource(
        refresh_token,
        client_id,
        resource,
        REFRESH_TOKEN_TTL_SECONDS,
    );
    let grant = match rotated {
        Ok(Ok(rotated)) => rotated,
        Ok(Err(_)) => {
            return token_error(StatusCode::BAD_REQUEST, "invalid_grant", "invalid grant")
        }
        Err(error) => return token_store_error(&error),
    };
    audit_principal("refresh token rotated", &grant.binding.principal);
    token_success(
        grant.access_token,
        Some(grant.refresh_token),
        grant.scope,
        ACCESS_TOKEN_TTL_SECONDS,
    )
}

fn token_success(access: String, refresh: Option<String>, scope: String, ttl: i64) -> Response {
    let mut response = serde_json::json!({
        "access_token": access,
        "token_type": "Bearer",
        "expires_in": ttl,
        "scope": scope,
    });
    if let Some(refresh) = refresh {
        response["refresh_token"] = serde_json::Value::String(refresh);
    }
    Json(response).into_response()
}

#[derive(Debug, Deserialize)]
pub struct LinkPageQuery {
    pub code: Option<String>,
}

/// Landing page printed by the relay as the link URL. This page is
/// intentionally informational: connecting happens by clicking Connect in
/// the connector (ChatGPT) and approving the prompt on the Mac; the
/// six-digit code is only the fallback.
pub async fn link_page(Query(query): Query<LinkPageQuery>) -> Response {
    let code = query
        .code
        .as_deref()
        .map(str::trim)
        .filter(|value| value.len() == 6 && value.bytes().all(|byte| byte.is_ascii_digit()))
        .map(|value| {
            format!(
                "<p class=\"code\">Fallback code (only if your Mac cannot show prompts): <code>{}</code></p>",
                html_escape(value)
            )
        })
        .unwrap_or_default();
    (
        StatusCode::OK,
        Html(format!(
            r#"<!doctype html><html><head><meta charset="utf-8"><title>Thumble device link</title>
<style>body{{font-family:-apple-system,system-ui,sans-serif;max-width:36rem;margin:4rem auto;padding:0 1rem;line-height:1.45}}
code{{background:#f3f3f3;padding:.1rem .4rem;border-radius:.3rem;letter-spacing:.12em}}
.code{{font-size:1.25rem}}</style></head>
<body><h1>Connect ChatGPT to this Mac</h1>
<p>Your Mac's relay is running and waiting. No code is needed:</p>
<ol><li>In ChatGPT, open the Thumble app page and click <strong>Connect</strong>.</li>
<li>An approval prompt appears on your Mac — click <strong>Allow</strong> there.</li>
<li>The browser page finishes by itself and ChatGPT is connected.</li></ol>
{code}
<p>Codes are only for Macs that cannot show approval prompts (for example
over SSH); they are valid for one hour and can be used once on the page
titled <em>Link your Mac's Thumble controller</em>.</p>
</body></html>"#
        )),
    )
        .into_response()
}

pub fn deny_unauthorized(_headers: &HeaderMap) -> Response {
    (
        StatusCode::UNAUTHORIZED,
        [(
            header::WWW_AUTHENTICATE,
            "Bearer error=\"invalid_token\"".to_owned(),
        )],
        Json(serde_json::json!({"error": "invalid_token"})),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use thumble_tunnel::TunnelMessage;

    #[tokio::test]
    async fn storage_error_responses_are_generic_and_do_not_leak_sql() {
        let detail = "SQLITE_ERROR: no such table: refresh_tokens; SELECT token_digest";
        let response = server_error(detail);
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        let body = axum::body::to_bytes(response.into_body(), 4_096)
            .await
            .unwrap();
        let body = String::from_utf8(body.to_vec()).unwrap();
        assert_eq!(
            body,
            "<h1>Server error</h1><p>The request could not be completed.</p>"
        );
        assert!(!body.contains("SQLITE"));
        assert!(!body.contains("refresh_tokens"));
        assert!(!body.contains("SELECT"));

        let response = token_store_error(detail);
        assert_eq!(response.status(), StatusCode::INTERNAL_SERVER_ERROR);
        let body = axum::body::to_bytes(response.into_body(), 4_096)
            .await
            .unwrap();
        let body = String::from_utf8(body.to_vec()).unwrap();
        assert!(body.contains("the token request could not be completed"));
        assert!(!body.contains("SQLITE"));
        assert!(!body.contains("refresh_tokens"));
        assert!(!body.contains("SELECT"));
    }

    #[test]
    fn native_push_requires_a_verified_chatgpt_callback_host() {
        assert_eq!(
            trusted_push_connector("https://chatgpt.com/connector/oauth/callback"),
            Some("ChatGPT")
        );
        assert_eq!(
            trusted_push_connector("https://chat.openai.com/connector/callback"),
            Some("ChatGPT")
        );
        assert!(trusted_push_connector("https://evil.example/callback").is_none());
        assert!(trusted_push_connector("https://chatgpt.com.evil.example/callback").is_none());
        assert!(trusted_push_connector("http://chatgpt.com/callback").is_none());
    }

    #[test]
    fn builder_consent_cookie_is_secure_except_on_exact_loopback_http() {
        let secure = builder_consent_cookie(
            "https://mcp.thumble.app",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            false,
        )
        .unwrap();
        assert!(secure.to_str().unwrap().contains("; Secure"));
        let loopback = builder_consent_cookie(
            "http://127.0.0.1:8080",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            false,
        )
        .unwrap();
        assert!(!loopback.to_str().unwrap().contains("; Secure"));
        assert!(builder_consent_cookie(
            "http://gateway.example",
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            false,
        )
        .is_err());
    }

    #[test]
    fn builder_cookie_only_origin_rejects_missing_header() {
        let headers = HeaderMap::new();
        assert!(!same_gateway_origin(&headers, "https://mcp.thumble.app"));
    }

    #[test]
    fn builder_origin_rejects_explicit_cross_origin_headers() {
        let mut headers = HeaderMap::new();
        headers.insert(
            header::ORIGIN,
            HeaderValue::from_static("https://mcp.thumble.app"),
        );
        assert!(same_gateway_origin(&headers, "https://mcp.thumble.app:443"));
        headers.append(
            header::ORIGIN,
            HeaderValue::from_static("https://cross-site.example"),
        );
        assert!(!same_gateway_origin(&headers, "https://mcp.thumble.app"));
    }

    #[tokio::test]
    async fn failed_rotation_still_disconnects_the_invalidated_control_socket() {
        let store = Arc::new(crate::store::Store::open_in_memory().unwrap());
        let tunnels = crate::tunnel::TunnelRegistry::new();
        let (device_id, old_token) = store.create_device("Mac").unwrap();
        let (control_sender, mut control_receiver) = tokio::sync::mpsc::channel(4);
        tunnels
            .register_device(&device_id, "source-a", "old-connection", control_sender)
            .unwrap();
        let (link_sender, mut link_receiver) = tokio::sync::mpsc::channel(4);
        tunnels.register_pending_link(
            "pending-rotation",
            "source-a",
            "Mac",
            link_sender,
            Some(device_id.clone()),
        );
        let state = Arc::new(AppState::new(
            store.clone(),
            tunnels.clone(),
            "https://mcp.thumble.app".to_owned(),
        ));
        let request = crate::store::AuthorizationRequestRecord {
            client_id: "cc-test".to_owned(),
            redirect_uri: "https://chatgpt.com/connector_platform_oauth_redirect".to_owned(),
            state: "state".to_owned(),
            scope: "thumble.read".to_owned(),
            code_challenge: "challenge".to_owned(),
            resource: crate::principal::ResourceKind::Relay,
        };
        let completion_state = state.clone();
        let completion = tokio::spawn(async move {
            complete_pending_link_grant(&completion_state, &request, "pending-rotation").await
        });

        assert!(matches!(
            control_receiver.recv().await.unwrap(),
            TunnelMessage::ReconnectRequired { .. }
        ));
        assert!(matches!(
            link_receiver.recv().await.unwrap(),
            TunnelMessage::LinkGranted { device_id: ref granted, .. }
                if granted == &device_id
        ));
        tunnels.fail_link_persistence("pending-rotation", "disk write failed");
        let (_, granted) = completion.await.unwrap();
        assert!(!granted);
        assert!(store.device_for_token(&old_token).unwrap().is_none());
    }
}
