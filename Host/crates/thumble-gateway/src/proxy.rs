//! The remote-facing MCP handler: a proxy that forwards tool/resource
//! requests to the linked device over its tunnel, enforcing per-tool
//! scopes before anything leaves the gateway.
//!
//! Identity (device + granted scopes) arrives per HTTP request via
//! extensions inserted by the auth middleware; the Streamable HTTP session
//! worker attaches the originating `http::request::Parts` to every request
//! context, so each call resolves it from `context.extensions`.
//!
//! When the device is offline, `initialize` and `tools/list` still succeed
//! from the cached manifest so connector validation keeps working; every
//! tool call fails fast with a bounded, actionable error.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};

use rmcp::model::{
    CallToolRequestParams, CallToolResponse, DiscoverResult, Icon, Implementation,
    InitializeResult, ListResourcesResult, ListToolsResult, PaginatedRequestParams,
    ReadResourceRequestParams, ReadResourceResponse, ResultType, ServerCapabilities, ServerInfo,
    Tool,
};
use rmcp::service::{RequestContext, RunningService};
use rmcp::{ErrorData as McpError, RoleClient, RoleServer, ServerHandler};
use serde_json::Value;

use crate::state::{AppState, TokenIdentity};

const THUMBLE_ICON_URL: &str = "https://pocketpad-site.pages.dev/assets/app-icon.png?v=6eae962e";
const THUMBLE_WEBSITE_URL: &str = "https://pocketpad-site.pages.dev";

fn thumble_server_implementation() -> Implementation {
    Implementation::new("thumble-relay", env!("CARGO_PKG_VERSION"))
        .with_title("Thumble MCP Controller")
        .with_description("Authenticated Thumble MCP connector for typed controller setup, preview, validation, and save; use MCP tools rather than Computer Use")
        .with_icons(vec![Icon::new(THUMBLE_ICON_URL)
            .with_mime_type("image/png")
            .with_sizes(vec!["1024x1024".to_owned()])])
        .with_website_url(THUMBLE_WEBSITE_URL)
}

pub struct RelayProxy {
    state: Arc<AppState>,
    identity: OnceLock<TokenIdentity>,
    mcp_session_acquired: AtomicBool,
    device: tokio::sync::OnceCell<Result<RunningService<RoleClient, ()>, String>>,
    session_id: String,
}

impl RelayProxy {
    pub fn new(state: Arc<AppState>) -> Self {
        Self {
            state,
            identity: OnceLock::new(),
            mcp_session_acquired: AtomicBool::new(false),
            device: tokio::sync::OnceCell::new(),
            session_id: format!("sess_{}", thumble_tunnel::random_token(12)),
        }
    }

    /// Resolve the caller identity for this request from the HTTP parts.
    fn request_identity(context: &RequestContext<RoleServer>) -> Option<TokenIdentity> {
        let parts = context.extensions.get::<axum::http::request::Parts>()?;
        let identity = parts.extensions.get::<Arc<TokenIdentity>>()?;
        Some(TokenIdentity {
            device_id: identity.device_id.clone(),
            scope: identity.scope.clone(),
        })
    }

    /// Bind the Streamable HTTP session to the first authenticated identity.
    /// A stolen `Mcp-Session-Id` cannot be replayed with another device or
    /// scope set even when that caller owns a different valid access token.
    fn bind_identity(
        &self,
        context: &RequestContext<RoleServer>,
    ) -> Result<&TokenIdentity, McpError> {
        let current = Self::request_identity(context).ok_or_else(bearer_required)?;
        if let Some(bound) = self.identity.get() {
            if bound != &current {
                return Err(McpError::invalid_request(
                    "the MCP session is bound to a different token identity; reinitialize",
                    None,
                ));
            }
            return Ok(bound);
        }
        let _ = self.identity.set(current);
        self.identity.get().ok_or_else(bearer_required)
    }

    fn acquire_session_slot(&self, identity: &TokenIdentity) -> Result<(), McpError> {
        if !self.mcp_session_acquired.swap(true, Ordering::SeqCst) {
            if let Err(error) = self.state.session_limiter.acquire(&identity.device_id) {
                self.mcp_session_acquired.store(false, Ordering::SeqCst);
                return Err(McpError::invalid_request(error, None));
            }
        }
        Ok(())
    }

    /// Borrow the live device MCP session, opening it on first use.
    async fn device_session(
        &self,
        identity: &TokenIdentity,
    ) -> Result<&RunningService<RoleClient, ()>, McpError> {
        // Modern 2026-07-28 requests are stateless and do not call initialize.
        // Acquire the same bounded per-device slot lazily before they open a
        // tunnel session; legacy sessions already acquire it in initialize.
        self.acquire_session_slot(identity)?;
        let state = self.state.clone();
        let session_id = self.session_id.clone();
        let device_id = identity.device_id.clone();
        let outcome = self
            .device
            .get_or_init(|| async move {
                let ws_base = {
                    let base = state.base_url();
                    if let Some(rest) = base.strip_prefix("https://") {
                        format!("wss://{rest}")
                    } else if let Some(rest) = base.strip_prefix("http://") {
                        format!("ws://{rest}")
                    } else {
                        base
                    }
                };
                let session_url = format!("{ws_base}/tunnel/session/{session_id}");
                match state
                    .tunnels
                    .open_device_session(&device_id, &session_id, &session_url)
                    .await
                {
                    Ok(service) => Ok(service),
                    Err(error) => Err(error),
                }
            })
            .await;
        outcome.as_ref().map_err(|error: &String| {
            McpError::internal_error(
                format!(
                    "Your Thumble device is unavailable: {error}. On your Mac, start \
                     thumble-host and the relay (`thumble relay connect` or the installed \
                     background service), verify with `thumble relay doctor`, then retry."
                ),
                None,
            )
        })
    }

    fn cached_manifest(
        &self,
        identity: &TokenIdentity,
    ) -> (Vec<Value>, Vec<Value>, Option<String>) {
        if let Some(manifest) = self.state.tunnels.manifest(&identity.device_id) {
            return (manifest.tools, manifest.resources, manifest.instructions);
        }
        if let Ok(Some(manifest)) = self.state.store.manifest(&identity.device_id) {
            return (manifest.tools, manifest.resources, manifest.instructions);
        }
        (Vec::new(), Vec::new(), None)
    }
}

fn compact_remote_edit_schema() -> Value {
    serde_json::json!({
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "type": "object",
        "additionalProperties": false,
        "required": ["draftId", "expectedDraftRevision", "operationId", "operation"],
        "properties": {
            "draftId": {
                "type": "string",
                "description": "Exact draft ID returned by begin/get/edit."
            },
            "expectedDraftRevision": {
                "type": "integer",
                "minimum": 0,
                "description": "Exact current draft revision."
            },
            "operationId": {
                "type": "string",
                "description": "Caller-generated UUID for idempotent retry."
            },
            "operation": {
                "type": "object",
                "additionalProperties": true,
                "required": ["type"],
                "description": "One typed Thumble operation. The Mac validates the complete canonical schema and rejects unknown or malformed fields. Common example: {type:'profile.rename', profileID:'...', name:'...'}. Submit one operation per call and use exact revisions returned by the prior result.",
                "properties": {
                    "type": {
                        "type": "string",
                        "enum": [
                            "profile.rename", "element.add", "element.set", "binding.set",
                            "binding.clear", "binding.reset", "binding.reset-all", "output.mode",
                            "output.set", "output.reset", "output.reset-all", "profile.reset",
                            "customization.set", "customization.reset", "customization.fix",
                            "orientation.set", "device.set", "control-bar.set", "control-bar.add",
                            "control-bar.remove", "control-bar.move", "control-bar.item.set",
                            "style.create", "style.rename", "style.apply", "style.detach",
                            "style.delete", "layer.move", "layer.forward", "layer.backward",
                            "layer.front", "layer.back", "group.create", "group.rename",
                            "group.duplicate", "group.ungroup", "group.hide", "group.show",
                            "group.lock", "group.unlock", "group.nudge", "group.forward",
                            "group.backward", "group.front", "group.back", "control-bar.reset",
                            "control-bar.item.reset", "generation.generate", "template.install",
                            "profile.select", "profile.default", "profile.duplicate",
                            "profile.delete", "profile.move", "profile.create", "theme.apply",
                            "orientation.copy", "element.duplicate", "element.align",
                            "element.distribute", "element.nudge", "element.delete", "element.reset"
                        ]
                    }
                }
            }
        }
    })
}

fn remote_tool(mut value: Value, scope: &str) -> Option<Tool> {
    let name = value.get("name")?.as_str()?.to_owned();
    crate::scopes::tool_allowed(&name, scope).ok()?;
    let object = value.as_object_mut()?;

    // ChatGPT applies a bounded action-discovery token budget. Output schemas
    // are optional MCP metadata and account for much of this catalog; actual
    // structured results remain unchanged. The full edit union is retained and
    // enforced by the Mac, while the gateway advertises a compact outer
    // envelope and every allowed discriminator.
    object.remove("outputSchema");
    if name == "edit_configuration_draft" {
        object.insert("inputSchema".to_owned(), compact_remote_edit_schema());
    }
    serde_json::from_value(value).ok()
}

fn bearer_required() -> McpError {
    McpError::invalid_request(
        "this MCP endpoint requires a Bearer access token issued by /token",
        None,
    )
}

impl ServerHandler for RelayProxy {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(
            ServerCapabilities::builder()
                .enable_tools()
                .enable_resources()
                .build(),
        )
        .with_server_info(thumble_server_implementation())
    }

    async fn initialize(
        &self,
        _request: rmcp::model::InitializeRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<InitializeResult, McpError> {
        let identity = self.bind_identity(&context)?;
        self.acquire_session_slot(identity)?;
        let (_, _, instructions) = self.cached_manifest(identity);
        let info = self.get_info();
        let mut result = InitializeResult::new(info.capabilities.clone()).with_instructions(
            instructions.unwrap_or_else(|| {
                "Proxy to your Thumble device. Configuration writes require the \
                 thumble.config scope and the device-side --allow-config-write opt-in; \
                 input injection is local-only."
                    .to_owned()
            }),
        );
        result.server_info = info.server_info;
        Ok(result)
    }

    async fn discover(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<DiscoverResult, McpError> {
        let identity = self.bind_identity(&context)?;
        let (_, _, instructions) = self.cached_manifest(identity);
        let mut info = self.get_info();
        info.instructions = Some(instructions.unwrap_or_else(|| {
            "Proxy to your Thumble device. Configuration writes require the thumble.config \
             scope and the device-side --allow-config-write opt-in; input injection is \
             local-only."
                .to_owned()
        }));
        Ok(DiscoverResult::from_server_info(
            self.supported_protocol_versions().into_owned(),
            info,
        ))
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        let identity = self.bind_identity(&context)?;
        let (tools, _, _) = self.cached_manifest(identity);
        let tools: Vec<Tool> = tools
            .into_iter()
            .filter_map(|value| remote_tool(value, &identity.scope))
            .collect();
        Ok(ListToolsResult::with_all_items(tools))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        let identity = self.bind_identity(&context)?;
        let tool_name = request.name.to_string();
        if let Err(error) = crate::scopes::tool_allowed(&tool_name, &identity.scope) {
            gateway_audit(&identity.device_id, &tool_name, "scope-denied");
            return Err(McpError::invalid_request(error, None));
        }
        if let Err(error) = self.state.rate_limiter.allow(&identity.device_id) {
            gateway_audit(&identity.device_id, &tool_name, "rate-limited");
            return Err(McpError::invalid_request(error, None));
        }
        let device = match self.device_session(identity).await {
            Ok(device) => device,
            Err(error) => {
                gateway_audit(&identity.device_id, &tool_name, "device-offline");
                return Err(error);
            }
        };
        match device.peer().call_tool(request).await {
            Ok(mut result) => {
                // A linked device may still speak a pre-2026 MCP revision,
                // where complete tool results omit the modern discriminator.
                // Normalize it before the gateway serves a modern client; the
                // rmcp handler removes it again for legacy HTTP sessions.
                result.result_type = Some(ResultType::COMPLETE);
                gateway_audit(&identity.device_id, &tool_name, "succeeded");
                Ok(result.into())
            }
            Err(error) => {
                gateway_audit(&identity.device_id, &tool_name, "failed");
                Err(McpError::internal_error(
                    format!("device tool call failed: {error}"),
                    None,
                ))
            }
        }
    }

    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, McpError> {
        let identity = self.bind_identity(&context)?;
        let (_, resources, _) = self.cached_manifest(identity);
        let resources = resources
            .into_iter()
            .filter_map(|value| serde_json::from_value(value).ok())
            .collect();
        Ok(ListResourcesResult::with_all_items(resources))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, McpError> {
        let identity = self.bind_identity(&context)?;
        let device = match self.device_session(identity).await {
            Ok(device) => device,
            Err(error) => return Err(error),
        };
        device
            .peer()
            .read_resource(request)
            .await
            .map(|mut result| {
                result.result_type = Some(ResultType::COMPLETE);
                result.into()
            })
            .map_err(|error| {
                McpError::internal_error(format!("device resource read failed: {error}"), None)
            })
    }
}

/// Bounded audit line: identity + action + outcome. No profile content,
/// bindings, or credentials ever pass through the gateway.
fn gateway_audit(device_id: &str, tool: &str, outcome: &str) {
    eprintln!("gateway: audit device={device_id} tool={tool} outcome={outcome}");
}

impl Drop for RelayProxy {
    fn drop(&mut self) {
        let Some(identity) = self.identity.get().cloned() else {
            return;
        };
        if self.mcp_session_acquired.load(Ordering::SeqCst) {
            self.state.session_limiter.release(&identity.device_id);
        }
        if !matches!(self.device.get(), Some(Ok(_))) {
            return;
        }
        self.state.tunnels.session_ended(&identity.device_id);
        let tunnels = self.state.tunnels.clone();
        let session_id = self.session_id.clone();
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            runtime.spawn(async move {
                tunnels
                    .close_device_session(&identity.device_id, &session_id)
                    .await;
            });
        }
    }
}
