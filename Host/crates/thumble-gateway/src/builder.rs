//! Direct hosted MCP builder service.
//!
//! This handler is deliberately isolated from the relay proxy. It owns no
//! tunnel, host, manifest, resource, input, or phone-authority path.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};

use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, DiscoverResult,
    Implementation, InitializeResult, ListToolsResult, PaginatedRequestParams, ServerCapabilities,
    ServerInfo, Tool,
};
use rmcp::service::RequestContext;
use rmcp::{ErrorData as McpError, RoleServer, ServerHandler};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{Map, Value};
use sha2::{Digest as _, Sha256};
use thumble_builder::{BuilderEdit, BuilderError, BuilderSession, BuilderTemplate};
use thumble_core::{ProfileArtifact, MAXIMUM_GENERATION_SPEC_BYTES};

use crate::builder_store::{
    BuilderDiscardResult, BuilderEmissionResult, BuilderStoreError,
    DEFAULT_BUILDER_SESSION_TTL_SECONDS, MAXIMUM_BUILDER_SESSION_TTL_SECONDS,
};
use crate::state::{AppState, BuilderTokenIdentity};
use crate::store::Store;

pub const BUILDER_MCP_MAXIMUM_BODY_BYTES: usize = 512 * 1024;
pub const BUILDER_TOOL_CATALOG_MAXIMUM_BYTES: usize = 48 * 1024;
pub const BUILDER_TOOL_MAXIMUM_BYTES: usize = 12 * 1024;
const MAXIMUM_RESULT_TEXT_BYTES: usize = 2 * 1024;

pub struct BuilderMcp {
    state: Arc<AppState>,
    identity: OnceLock<BuilderTokenIdentity>,
    session_acquired: AtomicBool,
}

impl BuilderMcp {
    pub fn new(state: Arc<AppState>) -> Self {
        Self {
            state,
            identity: OnceLock::new(),
            session_acquired: AtomicBool::new(false),
        }
    }

    fn request_identity(context: &RequestContext<RoleServer>) -> Option<BuilderTokenIdentity> {
        let parts = context.extensions.get::<axum::http::request::Parts>()?;
        let identity = parts.extensions.get::<Arc<BuilderTokenIdentity>>()?;
        Some((**identity).clone())
    }

    fn bind_identity(
        &self,
        context: &RequestContext<RoleServer>,
    ) -> Result<&BuilderTokenIdentity, McpError> {
        let current = Self::request_identity(context).ok_or_else(builder_bearer_required)?;
        if let Some(bound) = self.identity.get() {
            if bound != &current {
                return Err(McpError::invalid_request(
                    "the builder MCP session is bound to a different token identity; reinitialize",
                    None,
                ));
            }
            return Ok(bound);
        }
        let _ = self.identity.set(current);
        self.identity.get().ok_or_else(builder_bearer_required)
    }

    fn acquire_session(&self, identity: &BuilderTokenIdentity) -> Result<(), McpError> {
        if !self.session_acquired.swap(true, Ordering::SeqCst) {
            if let Err(error) = self
                .state
                .builder_session_limiter
                .acquire(&identity.builder_id)
            {
                self.session_acquired.store(false, Ordering::SeqCst);
                return Err(McpError::invalid_request(error, None));
            }
        }
        Ok(())
    }

    fn authorize_call(
        &self,
        context: &RequestContext<RoleServer>,
        tool: &str,
    ) -> Result<BuilderTokenIdentity, McpError> {
        let identity = self.bind_identity(context)?.clone();
        self.acquire_session(&identity)?;
        if self
            .state
            .builder_tool_rate_limiter
            .allow(&identity.builder_id)
            .is_err()
        {
            builder_audit(&identity.builder_id, tool, "rate-limited");
            return Err(McpError::invalid_request(
                "builder tool-call rate limit exceeded; retry shortly",
                None,
            ));
        }
        Ok(identity)
    }

    async fn mutation<F, T>(&self, operation: F) -> Result<T, McpError>
    where
        F: FnOnce() -> Result<T, McpError> + Send + 'static,
        T: Send + 'static,
    {
        // The caller already holds one of the eight process-wide work permits.
        // Mutations additionally take the four-wide subset permit before any
        // blocking thread is spawned.
        let mutation_permit = self
            .state
            .builder_mutation_semaphore
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| McpError::internal_error("builder service unavailable", None))?;
        tokio::task::spawn_blocking(move || {
            let _mutation_permit = mutation_permit;
            operation()
        })
        .await
        .map_err(|_| McpError::internal_error("builder service unavailable", None))?
    }

    async fn read<F, T>(operation: F) -> Result<T, McpError>
    where
        F: FnOnce() -> Result<T, McpError> + Send + 'static,
        T: Send + 'static,
    {
        tokio::task::spawn_blocking(operation)
            .await
            .map_err(|_| McpError::internal_error("builder service unavailable", None))?
    }
}

impl Drop for BuilderMcp {
    fn drop(&mut self) {
        if self.session_acquired.load(Ordering::SeqCst) {
            if let Some(identity) = self.identity.get() {
                self.state
                    .builder_session_limiter
                    .release(&identity.builder_id);
            }
        }
    }
}

fn builder_bearer_required() -> McpError {
    McpError::invalid_request(
        "this MCP endpoint requires a Bearer access token with thumble.build scope",
        None,
    )
}

fn server_implementation() -> Implementation {
    Implementation::new("thumble-hosted-builder", env!("CARGO_PKG_VERSION"))
        .with_title("Thumble Hosted Profile Builder")
        .with_description(
            "Credential-free pre-adoption profile builder; no phone authority, input, relay, tunnel, host, or Mac is required",
        )
}

const INSTRUCTIONS: &str = "Build a credential-free, pre-adoption Thumble profile and emit a portable artifact for explicit adoption. This service has no phone authority, cannot send input or save/sync a phone configuration, and does not require a Mac.";

impl ServerHandler for BuilderMcp {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(ServerCapabilities::builder().enable_tools().build())
            .with_server_info(server_implementation())
            .with_instructions(INSTRUCTIONS)
    }

    async fn initialize(
        &self,
        _request: rmcp::model::InitializeRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<InitializeResult, McpError> {
        let identity = self.bind_identity(&context)?;
        self.acquire_session(identity)?;
        let info = self.get_info();
        let mut result = InitializeResult::new(info.capabilities.clone())
            .with_instructions(INSTRUCTIONS.to_owned());
        result.server_info = info.server_info;
        Ok(result)
    }

    async fn discover(
        &self,
        context: RequestContext<RoleServer>,
    ) -> Result<DiscoverResult, McpError> {
        let identity = self.bind_identity(&context)?;
        self.acquire_session(identity)?;
        Ok(DiscoverResult::from_server_info(
            self.supported_protocol_versions().into_owned(),
            self.get_info(),
        ))
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, McpError> {
        let identity = self.bind_identity(&context)?;
        self.acquire_session(identity)?;
        Ok(ListToolsResult::with_all_items(builder_tools()))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, McpError> {
        let tool = request.name.to_string();
        let identity = self.authorize_call(&context, &tool)?;
        // Bound argument decoding, document decoding, SQLite reads, and
        // mutations under one process-wide permit. The permit is acquired
        // before the mutation subset permit, establishing a single lock order.
        let _work_permit = self
            .state
            .builder_work_semaphore
            .clone()
            .acquire_owned()
            .await
            .map_err(|_| McpError::internal_error("builder service unavailable", None))?;
        let arguments = Value::Object(request.arguments.unwrap_or_default());
        let outcome = async {
            match tool.as_str() {
                "begin_builder_session" => {
                    let params: BeginParams = decode(arguments)?;
                    let store = self.state.store.clone();
                    let builder_id = identity.builder_id.clone();
                    self.mutation(move || {
                        let session_id = new_uuid();
                        let record = store
                            .begin_builder_workspace(&builder_id, &session_id, params.ttl_seconds)
                            .map_err(store_error)?;
                        let status = record
                            .session
                            .status(crate::store::Store::now())
                            .map_err(builder_error)?;
                        tool_result(status, "Builder session started")
                    })
                    .await
                }
                "builder_status" => {
                    let params: SessionParams = decode(arguments)?;
                    let store = self.state.store.clone();
                    let builder_id = identity.builder_id.clone();
                    Self::read(move || {
                        let record = store
                            .load_builder_workspace(&builder_id, &params.session_id)
                            .map_err(store_error)?;
                        let status = record
                            .session
                            .status(crate::store::Store::now())
                            .map_err(builder_error)?;
                        tool_result(status, "Builder session status")
                    })
                    .await
                }
                "edit_builder_profile" => {
                    let params: EditParams = decode(arguments)?;
                    let store = self.state.store.clone();
                    let builder_id = identity.builder_id.clone();
                    self.mutation(move || {
                        let now = Store::now();
                        let result =
                            mutate_workspace(&store, &builder_id, &params.session_id, |session| {
                                session.apply_edit(
                                    &params.operation_id,
                                    params.expected_revision,
                                    params.operation.clone(),
                                    now,
                                )
                            })?;
                        tool_result(result, "Builder edit applied")
                    })
                    .await
                }
                "validate_builder_profile" => {
                    let params: RevisionParams = decode(arguments)?;
                    let store = self.state.store.clone();
                    let builder_id = identity.builder_id.clone();
                    Self::read(move || {
                        let record = store
                            .load_builder_workspace(&builder_id, &params.session_id)
                            .map_err(store_error)?;
                        require_revision(record.session.revision(), params.expected_revision)?;
                        let result = record
                            .session
                            .validate(crate::store::Store::now())
                            .map_err(builder_error)?;
                        tool_result(result, "Builder profile is valid")
                    })
                    .await
                }
                "preview_builder_profile" => {
                    let params: RevisionParams = decode(arguments)?;
                    let store = self.state.store.clone();
                    let builder_id = identity.builder_id.clone();
                    Self::read(move || {
                        let record = store
                            .load_builder_workspace(&builder_id, &params.session_id)
                            .map_err(store_error)?;
                        require_revision(record.session.revision(), params.expected_revision)?;
                        let preview = record
                            .session
                            .preview(crate::store::Store::now())
                            .map_err(builder_error)?;
                        // The text fallback is safe to display in logs and chat UIs:
                        // never interpolate caller-controlled profile content into it.
                        let text = format!(
                            "Preview ready: orientation={:?}, elements={}, layoutIssues={}",
                            preview.orientation,
                            preview.elements.len(),
                            preview.layout_quality.issue_count
                        );
                        tool_result(preview, &text)
                    })
                    .await
                }
                "install_template" => {
                    let params: TemplateParams = decode(arguments)?;
                    let store = self.state.store.clone();
                    let builder_id = identity.builder_id.clone();
                    self.mutation(move || {
                        let now = Store::now();
                        let summary =
                            mutate_workspace(&store, &builder_id, &params.session_id, |session| {
                                session.install_template(
                                    &params.operation_id,
                                    params.expected_revision,
                                    params.template,
                                    params.name.as_deref(),
                                    now,
                                )
                            })?;
                        tool_result(summary, "Builder template installed")
                    })
                    .await
                }
                "generate_from_spec" => {
                    let params: GenerateParams = decode(arguments)?;
                    let spec_json = serde_json::to_vec(&params.spec).map_err(|_| {
                        McpError::invalid_request("invalid arguments for builder tool", None)
                    })?;
                    if spec_json.len() > MAXIMUM_GENERATION_SPEC_BYTES {
                        return Err(McpError::invalid_request(
                            "generation spec exceeds 256 KiB",
                            None,
                        ));
                    }
                    let store = self.state.store.clone();
                    let builder_id = identity.builder_id.clone();
                    self.mutation(move || {
                        let now = Store::now();
                        let summary =
                            mutate_workspace(&store, &builder_id, &params.session_id, |session| {
                                session.generate_from_spec(
                                    &params.operation_id,
                                    params.expected_revision,
                                    &spec_json,
                                    params.requested_game_name.as_deref(),
                                    now,
                                )
                            })?;
                        tool_result(summary, "Builder profile generated")
                    })
                    .await
                }
                "emit_profile_artifact" => {
                    let params: RevisionParams = decode(arguments)?;
                    let store = self.state.store.clone();
                    let builder_id = identity.builder_id.clone();
                    let base_url = self.state.base_url();
                    self.mutation(move || {
                        let result =
                            match store.load_builder_workspace(&builder_id, &params.session_id) {
                                Ok(record) => {
                                    require_revision(
                                        record.session.revision(),
                                        params.expected_revision,
                                    )?;
                                    let mut session = record.session;
                                    let now = crate::store::Store::now();
                                    let emission = session
                                        .emit_artifact(params.expected_revision, now)
                                        .map_err(builder_error)?;
                                    let handoff = session
                                        .mark_emitted(params.expected_revision, now)
                                        .map_err(builder_error)?;
                                    store
                                        .emit_builder_artifact(
                                            &builder_id,
                                            &session,
                                            params.expected_revision,
                                            record.storage_generation,
                                            &emission,
                                            &handoff,
                                        )
                                        .map_err(store_error)?
                                }
                                Err(BuilderStoreError::NotFound) => store
                                    .replay_builder_emission(
                                        &builder_id,
                                        &params.session_id,
                                        params.expected_revision,
                                    )
                                    .map_err(store_error)?,
                                Err(error) => return Err(store_error(error)),
                            };
                        emission_result(result, &base_url)
                    })
                    .await
                }
                "discard_builder_session" => {
                    let params: RevisionParams = decode(arguments)?;
                    let store = self.state.store.clone();
                    let builder_id = identity.builder_id.clone();
                    self.mutation(move || {
                        let generation =
                            match store.load_builder_workspace(&builder_id, &params.session_id) {
                                Ok(record) => {
                                    require_revision(
                                        record.session.revision(),
                                        params.expected_revision,
                                    )?;
                                    Some(record.storage_generation)
                                }
                                Err(BuilderStoreError::NotFound) => None,
                                Err(error) => return Err(store_error(error)),
                            };
                        let result = store
                            .discard_builder_workspace(
                                &builder_id,
                                &params.session_id,
                                params.expected_revision,
                                generation,
                            )
                            .map_err(store_error)?;
                        let receipt = match result {
                            BuilderDiscardResult::Discarded(receipt)
                            | BuilderDiscardResult::Replayed(receipt) => receipt,
                        };
                        tool_result(receipt, "Builder session discarded")
                    })
                    .await
                }
                _ => Err(McpError::invalid_request("unknown builder tool", None)),
            }
        }
        .await;
        match &outcome {
            Ok(_) => builder_audit(&identity.builder_id, &tool, "succeeded"),
            Err(_) => builder_audit(&identity.builder_id, &tool, "failed"),
        }
        outcome
    }
}

fn mutate_workspace<T, F>(
    store: &Store,
    builder_id: &str,
    session_id: &str,
    apply: F,
) -> Result<T, McpError>
where
    F: Fn(&mut BuilderSession) -> Result<T, BuilderError>,
{
    let mut record = store
        .load_builder_workspace(builder_id, session_id)
        .map_err(store_error)?;
    let loaded_revision = record.session.revision();
    let loaded_generation = record.storage_generation;
    let operation_count = record.session.operation_count();
    let result = apply(&mut record.session).map_err(builder_error)?;

    // A sequential replay returns the persisted operation's exact result and
    // must not churn session bytes or the storage-only CAS generation.
    if record.session.operation_count() == operation_count {
        return Ok(result);
    }

    match store.save_builder_workspace(
        builder_id,
        loaded_revision,
        loaded_generation,
        &record.session,
    ) {
        Ok(_) => Ok(result),
        Err(conflict @ BuilderStoreError::Conflict { .. })
        | Err(conflict @ BuilderStoreError::StorageGenerationConflict { .. }) => {
            // Another connection won the CAS. Reload and reapply only to
            // recognize an exact idempotent replay (same ID, descriptor, and
            // base revision). Any new log entry or replay mismatch preserves
            // the original stable conflict instead of merging competing work.
            let mut current = store
                .load_builder_workspace(builder_id, session_id)
                .map_err(store_error)?;
            let operation_count = current.session.operation_count();
            match apply(&mut current.session) {
                Ok(replayed) if current.session.operation_count() == operation_count => {
                    Ok(replayed)
                }
                Ok(_) | Err(_) => Err(store_error(conflict)),
            }
        }
        Err(error) => Err(store_error(error)),
    }
}

fn require_revision(actual: u64, expected: u64) -> Result<(), McpError> {
    if actual == expected {
        Ok(())
    } else {
        Err(McpError::invalid_request(
            format!("builder revision conflict: expected {expected}, actual {actual}"),
            None,
        ))
    }
}

fn decode<T: DeserializeOwned>(value: Value) -> Result<T, McpError> {
    serde_json::from_value(value)
        .map_err(|_| McpError::invalid_request("invalid arguments for builder tool", None))
}

fn tool_result(value: impl serde::Serialize, text: &str) -> Result<CallToolResponse, McpError> {
    let structured = serde_json::to_value(value)
        .map_err(|_| McpError::internal_error("builder result encoding failed", None))?;
    let bounded: String = text.chars().take(MAXIMUM_RESULT_TEXT_BYTES).collect();
    let mut result = CallToolResult::success(vec![ContentBlock::text(bounded)]);
    result.structured_content = Some(structured);
    Ok(result.into())
}

fn emission_result(
    result: BuilderEmissionResult,
    base_url: &str,
) -> Result<CallToolResponse, McpError> {
    let (artifact, share) = match result {
        BuilderEmissionResult::Emitted { artifact, share }
        | BuilderEmissionResult::Replayed { artifact, share } => (artifact, share),
    };
    let parsed = ProfileArtifact::decode_json(&artifact.artifact_json)
        .map_err(|_| McpError::internal_error("builder artifact encoding failed", None))?;
    let artifact_json = String::from_utf8(artifact.artifact_json)
        .map_err(|_| McpError::internal_error("builder artifact encoding failed", None))?;
    let structured = serde_json::json!({
        "artifact": parsed,
        "artifactJSON": artifact_json,
        "contentHash": artifact.content_hash,
        "revision": artifact.source_revision,
        "shareURL": format!("{}/share/{}#token={}", base_url.trim_end_matches('/'), share.artifact_id, share.share_token),
        "shareExpiresAt": share.expires_at
    });
    tool_result(
        structured,
        "Profile artifact emitted; the share credential is present only in the URL fragment",
    )
}

fn store_error(error: BuilderStoreError) -> McpError {
    if matches!(
        error,
        BuilderStoreError::CorruptData(_) | BuilderStoreError::Storage(_)
    ) {
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
        eprintln!("gateway: builder store error: {bounded}");
    }
    let message = match error {
        BuilderStoreError::NotFound => "builder session not found".to_owned(),
        BuilderStoreError::Conflict { expected, actual } => match actual {
            Some(actual) => {
                format!("builder revision conflict: expected {expected}, actual {actual}")
            }
            None => format!("builder revision conflict: expected {expected}"),
        },
        BuilderStoreError::StorageGenerationConflict { .. } => {
            "builder workspace changed concurrently; reload and retry".to_owned()
        }
        BuilderStoreError::QuotaExceeded(_) => "builder storage quota exceeded".to_owned(),
        BuilderStoreError::InactivePrincipal => "builder principal unavailable".to_owned(),
        BuilderStoreError::InvalidInput(_) => "invalid builder request".to_owned(),
        BuilderStoreError::CorruptData(_) | BuilderStoreError::Storage(_) => {
            "builder service unavailable".to_owned()
        }
    };
    McpError::invalid_request(message, None)
}

fn builder_error(error: thumble_builder::BuilderError) -> McpError {
    McpError::invalid_request(
        error.to_string().chars().take(256).collect::<String>(),
        None,
    )
}

fn new_uuid() -> String {
    let digest = Sha256::digest(thumble_tunnel::random_token(32).as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
    )
}

fn builder_audit(principal: &str, tool: &str, outcome: &str) {
    let tool = if tool.len() <= 64
        && tool
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
    {
        tool
    } else {
        "unknown"
    };
    eprintln!("gateway: builder-audit principal={principal} tool={tool} outcome={outcome}");
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BeginParams {
    #[serde(default)]
    ttl_seconds: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SessionParams {
    #[serde(rename = "sessionID")]
    session_id: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RevisionParams {
    #[serde(rename = "sessionID")]
    session_id: String,
    expected_revision: u64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct EditParams {
    #[serde(rename = "sessionID")]
    session_id: String,
    expected_revision: u64,
    #[serde(rename = "operationID")]
    operation_id: String,
    operation: BuilderEdit,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TemplateParams {
    #[serde(rename = "sessionID")]
    session_id: String,
    expected_revision: u64,
    #[serde(rename = "operationID")]
    operation_id: String,
    template: BuilderTemplate,
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct GenerateParams {
    #[serde(rename = "sessionID")]
    session_id: String,
    expected_revision: u64,
    #[serde(rename = "operationID")]
    operation_id: String,
    spec: Map<String, Value>,
    #[serde(default)]
    requested_game_name: Option<String>,
}

fn object_schema(required: &[&str], properties: Value) -> Value {
    serde_json::json!({
        "type": "object",
        "additionalProperties": false,
        "required": required,
        "properties": properties
    })
}

fn session_property() -> Value {
    serde_json::json!({"type":"string","format":"uuid","description":"Exact builder session UUID."})
}

fn revision_property() -> Value {
    serde_json::json!({"type":"integer","minimum":1,"description":"Exact current builder revision."})
}

fn operation_schema() -> Value {
    let variant = |kind: &str, fields: &[&str], properties: Value| {
        let mut required = vec!["type"];
        required.extend_from_slice(fields);
        let mut map = properties.as_object().cloned().unwrap_or_default();
        map.insert("type".to_owned(), serde_json::json!({"const":kind}));
        object_schema(&required, Value::Object(map))
    };
    let mut layout = variant(
        "control.layout",
        &["elementID"],
        serde_json::json!({
            "elementID":{"type":"string","minLength":1,"maxLength":128},
            "x":{"type":"number","minimum":0,"maximum":1}, "y":{"type":"number","minimum":0,"maximum":1},
            "width":{"type":"number","minimum":0.001,"maximum":12}, "height":{"type":"number","minimum":0.001,"maximum":12},
            "hidden":{"type":"boolean"}, "locked":{"type":"boolean"}
        }),
    );
    layout
        .as_object_mut()
        .expect("layout schema object")
        .insert(
            "anyOf".to_owned(),
            serde_json::json!([
                {"required":["x"]},{"required":["y"]},{"required":["width"]},
                {"required":["height"]},{"required":["hidden"]},{"required":["locked"]}
            ]),
        );
    serde_json::json!({"oneOf":[
        variant("profile.rename", &["name"], serde_json::json!({"name":{"type":"string","minLength":1,"maxLength":256}})),
        layout,
        variant("control.remove", &["elementID"], serde_json::json!({"elementID":{"type":"string","minLength":1,"maxLength":128}})),
        variant("binding.set", &["button","key"], serde_json::json!({
            "button":{"type":"string","enum":["up","down","left","right","jump","attack","dash","focus","map","pause","custom1","custom2","custom3","custom4","custom5","custom6","custom7","custom8"]},
            "key":{"type":"string","minLength":1,"maxLength":128},
            "modifiers":{"type":"array","maxItems":16,"items":{"type":"string","enum":["cmd","command","meta","shift","opt","option","alt","ctrl","control"]}}
        })),
        variant("binding.clear", &["button"], serde_json::json!({"button":{"type":"string","enum":["up","down","left","right","jump","attack","dash","focus","map","pause","custom1","custom2","custom3","custom4","custom5","custom6","custom7","custom8"]}})),
        variant("output.mode", &["mode"], serde_json::json!({"mode":{"type":"string","enum":["keyboard","controller","custom"]}}))
    ]})
}

fn generation_spec_schema() -> Value {
    // The core generation-spec-v1 codec is the strict source of truth for all
    // aliases and rich nested appearance objects. Keep this transport schema
    // compact and bounded so valid v1 additions/aliases are never rejected by
    // an MCP client before the strict runtime validator can inspect them.
    serde_json::json!({
        "type":"object",
        "required":["controls"],
        "maxProperties":16,
        "additionalProperties":true,
        "properties":{
            "schemaVersion":{"type":"integer","const":1},
            "catalogRevision":{"type":"integer","const":1},
            "plannerRevision":{"type":"integer","const":1},
            "controls":{
                "type":"array","minItems":1,"maxItems":128,
                "items":{"type":"object","maxProperties":96,"additionalProperties":true}
            }
        },
        "$comment":"Strict field, alias, nested appearance, type, and byte validation is generation-spec-v1 in thumble-core; this bounded transport envelope intentionally does not duplicate it."
    })
}

fn tool_value(
    name: &str,
    description: &str,
    schema: Value,
    read_only: bool,
    destructive: bool,
    idempotent: bool,
) -> Value {
    serde_json::json!({
        "name": name,
        "description": description,
        "inputSchema": schema,
        "annotations": {
            "title": description,
            "readOnlyHint": read_only,
            "destructiveHint": destructive,
            "idempotentHint": idempotent,
            "openWorldHint": false
        }
    })
}

pub fn builder_tools() -> Vec<Tool> {
    let sid = session_property();
    let revision = revision_property();
    let operation_id = serde_json::json!({"type":"string","format":"uuid","description":"Caller-generated UUID used for idempotent retry."});
    let mut tools = vec![
        tool_value(
            "begin_builder_session",
            "Begin an isolated pre-adoption builder session",
            object_schema(
                &[],
                serde_json::json!({"ttlSeconds":{"type":"integer","default":DEFAULT_BUILDER_SESSION_TTL_SECONDS,"minimum":1,"maximum":MAXIMUM_BUILDER_SESSION_TTL_SECONDS}}),
            ),
            false,
            false,
            false,
        ),
        tool_value(
            "builder_status",
            "Read builder session status",
            object_schema(&["sessionID"], serde_json::json!({"sessionID":sid.clone()})),
            true,
            false,
            true,
        ),
        tool_value(
            "edit_builder_profile",
            "Apply one strict profile edit",
            object_schema(
                &["sessionID", "expectedRevision", "operationID", "operation"],
                serde_json::json!({"sessionID":sid.clone(),"expectedRevision":revision.clone(),"operationID":operation_id.clone(),"operation":operation_schema()}),
            ),
            false,
            true,
            true,
        ),
        tool_value(
            "validate_builder_profile",
            "Validate the current builder profile",
            object_schema(
                &["sessionID", "expectedRevision"],
                serde_json::json!({"sessionID":sid.clone(),"expectedRevision":revision.clone()}),
            ),
            true,
            false,
            true,
        ),
        tool_value(
            "preview_builder_profile",
            "Return a sanitized deterministic controller preview",
            object_schema(
                &["sessionID", "expectedRevision"],
                serde_json::json!({"sessionID":sid.clone(),"expectedRevision":revision.clone()}),
            ),
            true,
            false,
            true,
        ),
        tool_value(
            "install_template",
            "Install one canonical controller template",
            object_schema(
                &["sessionID", "expectedRevision", "operationID", "template"],
                serde_json::json!({"sessionID":sid.clone(),"expectedRevision":revision.clone(),"operationID":operation_id.clone(),"template":{"type":"string","enum":["productivityStarter","productivityOneHandedLeft","productivityOneHandedRight","nes","snes","nintendo64","gameCube","gameBoy","gameBoyAdvance","genesisSixButton","saturn","dreamcast","arcadeStick","psp","playStation","xbox","softWhite"]},"name":{"type":"string","minLength":1,"maxLength":256}}),
            ),
            false,
            true,
            true,
        ),
        tool_value(
            "generate_from_spec",
            "Generate a profile from one bounded typed specification",
            object_schema(
                &["sessionID", "expectedRevision", "operationID", "spec"],
                serde_json::json!({"sessionID":sid.clone(),"expectedRevision":revision.clone(),"operationID":operation_id,"spec":generation_spec_schema(),"requestedGameName":{"type":"string","minLength":1,"maxLength":256}}),
            ),
            false,
            true,
            true,
        ),
        tool_value(
            "emit_profile_artifact",
            "Atomically emit a portable profile artifact and fragment-only share URL",
            object_schema(
                &["sessionID", "expectedRevision"],
                serde_json::json!({"sessionID":sid.clone(),"expectedRevision":revision.clone()}),
            ),
            false,
            true,
            true,
        ),
        tool_value(
            "discard_builder_session",
            "Atomically discard a builder session",
            object_schema(
                &["sessionID", "expectedRevision"],
                serde_json::json!({"sessionID":sid,"expectedRevision":revision}),
            ),
            false,
            true,
            true,
        ),
    ];
    let encoded = serde_json::to_vec(&tools).expect("builder tool catalog serializes");
    assert!(encoded.len() <= BUILDER_TOOL_CATALOG_MAXIMUM_BYTES);
    for tool in &tools {
        assert!(
            serde_json::to_vec(tool)
                .expect("builder tool serializes")
                .len()
                <= BUILDER_TOOL_MAXIMUM_BYTES
        );
    }
    tools
        .drain(..)
        .map(|value| serde_json::from_value(value).expect("valid builder tool schema"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_is_exact_strict_and_bounded() {
        let tools = builder_tools();
        assert_eq!(tools.len(), 9);
        assert_eq!(
            tools
                .iter()
                .map(|tool| tool.name.as_ref())
                .collect::<Vec<_>>(),
            vec![
                "begin_builder_session",
                "builder_status",
                "edit_builder_profile",
                "validate_builder_profile",
                "preview_builder_profile",
                "install_template",
                "generate_from_spec",
                "emit_profile_artifact",
                "discard_builder_session"
            ]
        );
        let bytes = serde_json::to_vec(&tools).unwrap();
        assert!(bytes.len() <= BUILDER_TOOL_CATALOG_MAXIMUM_BYTES);
        for tool in tools {
            assert_eq!(
                tool.input_schema.get("additionalProperties"),
                Some(&Value::Bool(false))
            );
            assert!(tool.annotations.is_some());
            assert!(serde_json::to_vec(&tool).unwrap().len() <= BUILDER_TOOL_MAXIMUM_BYTES);
        }
    }

    #[test]
    fn schemas_cover_runtime_rich_aliases_and_reject_empty_layouts() {
        let schema = generation_spec_schema();
        assert_eq!(schema["additionalProperties"], true);
        assert_eq!(
            schema["properties"]["controls"]["items"]["additionalProperties"],
            true
        );

        for (index, fixture) in [
            include_bytes!("../../../fixtures/generation-spec/v1/rich-appearance.json").as_slice(),
            include_bytes!("../../../fixtures/generation-spec/v1/aliases-basic.json").as_slice(),
        ]
        .into_iter()
        .enumerate()
        {
            let value: Value = serde_json::from_slice(fixture).unwrap();
            assert!(value.as_object().unwrap().len() <= 16);
            assert!(value["controls"]
                .as_array()
                .unwrap()
                .iter()
                .all(|control| { control.as_object().is_some_and(|object| object.len() <= 96) }));
            let mut session = thumble_builder::BuilderSession::begin(
                format!("00000000-0000-4000-8000-{:012x}", index + 1),
                1_000,
                10_000,
            )
            .unwrap();
            session
                .generate_from_spec(
                    &format!("10000000-0000-4000-8000-{:012x}", index + 1),
                    1,
                    fixture,
                    None,
                    1_001,
                )
                .unwrap();
        }

        let operation = operation_schema();
        let layout = operation["oneOf"]
            .as_array()
            .unwrap()
            .iter()
            .find(|schema| schema["properties"]["type"]["const"] == "control.layout")
            .unwrap();
        assert_eq!(layout["anyOf"].as_array().unwrap().len(), 6);
        assert!(serde_json::from_value::<BuilderEdit>(serde_json::json!({
            "type":"control.layout", "elementID":"element"
        }))
        .is_ok());
        let mut session = thumble_builder::BuilderSession::begin(
            "00000000-0000-4000-8000-000000000099",
            1_000,
            10_000,
        )
        .unwrap();
        assert!(session
            .apply_edit(
                "10000000-0000-4000-8000-000000000099",
                1,
                serde_json::from_value(serde_json::json!({
                    "type":"control.layout", "elementID":"element"
                }))
                .unwrap(),
                1_001,
            )
            .is_err());

        let binding = operation["oneOf"]
            .as_array()
            .unwrap()
            .iter()
            .find(|schema| schema["properties"]["type"]["const"] == "binding.set")
            .unwrap();
        assert!(!binding["required"]
            .as_array()
            .unwrap()
            .iter()
            .any(|field| field == "modifiers"));
        assert_eq!(
            binding["properties"]["modifiers"]["items"]["enum"],
            serde_json::json!([
                "cmd", "command", "meta", "shift", "opt", "option", "alt", "ctrl", "control"
            ])
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn process_wide_builder_work_cap_queues_and_releases_after_eight() {
        let state = Arc::new(AppState::new(
            Arc::new(Store::open_in_memory().unwrap()),
            crate::tunnel::TunnelRegistry::new(),
            "https://mcp.thumble.app".to_owned(),
        ));
        let active = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let peak = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let release = Arc::new(tokio::sync::Semaphore::new(0));
        let mut jobs = Vec::new();
        for _ in 0..16 {
            let semaphore = state.builder_work_semaphore.clone();
            let active = active.clone();
            let peak = peak.clone();
            let release = release.clone();
            jobs.push(tokio::spawn(async move {
                let _permit = semaphore.acquire_owned().await.unwrap();
                let current = active.fetch_add(1, Ordering::SeqCst) + 1;
                peak.fetch_max(current, Ordering::SeqCst);
                let _release = release.acquire().await.unwrap();
                active.fetch_sub(1, Ordering::SeqCst);
            }));
        }
        tokio::time::timeout(std::time::Duration::from_secs(5), async {
            while active.load(Ordering::SeqCst) != 8 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("eight builder jobs should acquire work permits");
        assert_eq!(active.load(Ordering::SeqCst), 8);
        assert_eq!(state.builder_work_semaphore.available_permits(), 0);
        release.add_permits(16);
        for job in jobs {
            job.await.unwrap();
        }
        assert!(peak.load(Ordering::SeqCst) <= 8);
        assert_eq!(state.builder_work_semaphore.available_permits(), 8);
    }

    #[test]
    fn destructive_annotations_are_exact() {
        let tools = builder_tools();
        let serialized = serde_json::to_value(&tools).unwrap();
        for tool in serialized.as_array().unwrap() {
            let name = tool["name"].as_str().unwrap();
            let expected = matches!(
                name,
                "edit_builder_profile"
                    | "install_template"
                    | "generate_from_spec"
                    | "emit_profile_artifact"
                    | "discard_builder_session"
            );
            assert_eq!(
                tool["annotations"]["destructiveHint"],
                Value::Bool(expected),
                "unexpected destructiveHint for {name}"
            );
        }
    }

    fn assert_concurrent_identical_replay<T, F>(database_name: &str, session_id: &str, operation: F)
    where
        T: PartialEq + Send + 'static,
        F: Fn(&mut BuilderSession) -> Result<T, BuilderError> + Send + Sync + 'static,
    {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join(database_name);
        let secret = "builder-handler-cas-secret-at-least-32-bytes";
        let store = Arc::new(Store::open(&path, secret).unwrap());
        let builder = store.create_builder_principal("CAS builder").unwrap();
        let session = BuilderSession::begin(session_id, Store::now(), 3_600).unwrap();
        store.create_builder_workspace(&builder, &session).unwrap();
        let operation = Arc::new(operation);
        let barrier = Arc::new(std::sync::Barrier::new(2));

        let results = [store.clone(), store.clone()]
            .into_iter()
            .map(|store| {
                let builder = builder.clone();
                let session_id = session_id.to_owned();
                let operation = operation.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    let first_apply = std::sync::atomic::AtomicBool::new(true);
                    mutate_workspace(&store, &builder, &session_id, |session| {
                        if first_apply.swap(false, Ordering::SeqCst) {
                            barrier.wait();
                        }
                        operation(session)
                    })
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|thread| thread.join().unwrap().unwrap())
            .collect::<Vec<T>>();

        assert!(results[0] == results[1]);
        let persisted = store.load_builder_workspace(&builder, session_id).unwrap();
        assert_eq!(persisted.session.operation_count(), 1);
        assert_eq!(persisted.storage_generation, 2);

        // A later exact replay returns the persisted result without another
        // save or storage-generation increment.
        let replay =
            mutate_workspace(&store, &builder, session_id, |session| operation(session)).unwrap();
        assert!(replay == results[0]);
        let persisted = store.load_builder_workspace(&builder, session_id).unwrap();
        assert_eq!(persisted.session.operation_count(), 1);
        assert_eq!(persisted.storage_generation, 2);
    }

    #[test]
    fn concurrent_identical_edit_template_and_generation_replay_without_storage_churn() {
        assert_concurrent_identical_replay(
            "builder-handler-edit-cas.db",
            "00000000-0000-4000-8000-000000000091",
            |session| {
                session.apply_edit(
                    "10000000-0000-4000-8000-000000000091",
                    1,
                    BuilderEdit::ProfileRename {
                        name: "Default".to_owned(),
                    },
                    Store::now(),
                )
            },
        );
        assert_concurrent_identical_replay(
            "builder-handler-template-cas.db",
            "00000000-0000-4000-8000-000000000093",
            |session| {
                session.install_template(
                    "10000000-0000-4000-8000-000000000093",
                    1,
                    BuilderTemplate::Snes,
                    Some("Installed"),
                    Store::now(),
                )
            },
        );
        assert_concurrent_identical_replay(
            "builder-handler-generation-cas.db",
            "00000000-0000-4000-8000-000000000094",
            |session| {
                session.generate_from_spec(
                    "10000000-0000-4000-8000-000000000094",
                    1,
                    include_bytes!("../../../fixtures/generation-spec/v1/aliases-basic.json"),
                    None,
                    Store::now(),
                )
            },
        );
    }

    #[test]
    fn concurrent_distinct_noops_preserve_the_stable_cas_conflict() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("builder-handler-distinct-cas.db");
        let secret = "builder-handler-distinct-secret-at-least-32";
        let first = Arc::new(Store::open(&path, secret).unwrap());
        let builder = first.create_builder_principal("CAS builder").unwrap();
        let session =
            BuilderSession::begin("00000000-0000-4000-8000-000000000092", Store::now(), 3_600)
                .unwrap();
        first.create_builder_workspace(&builder, &session).unwrap();
        let second = first.clone();
        let barrier = Arc::new(std::sync::Barrier::new(2));

        let results = [first, second]
            .into_iter()
            .enumerate()
            .map(|(index, store)| {
                let builder = builder.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    let first_apply = std::sync::atomic::AtomicBool::new(true);
                    let operation_id = format!("10000000-0000-4000-8000-{:012x}", 92 + index);
                    mutate_workspace(
                        &store,
                        &builder,
                        "00000000-0000-4000-8000-000000000092",
                        |session| {
                            if first_apply.swap(false, Ordering::SeqCst) {
                                barrier.wait();
                            }
                            session.apply_edit(
                                &operation_id,
                                1,
                                BuilderEdit::ProfileRename {
                                    name: "Default".to_owned(),
                                },
                                Store::now(),
                            )
                        },
                    )
                })
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|thread| thread.join().unwrap())
            .collect::<Vec<_>>();

        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(results.iter().filter(|result| result.is_err()).count(), 1);
        let persisted = Store::open(&path, secret)
            .unwrap()
            .load_builder_workspace(&builder, "00000000-0000-4000-8000-000000000092")
            .unwrap();
        assert_eq!(persisted.session.operation_count(), 1);
        assert_eq!(persisted.storage_generation, 2);
    }

    #[test]
    fn builder_storage_errors_are_generic_to_mcp_clients() {
        let error = store_error(BuilderStoreError::Storage(
            "SQLITE_ERROR: no such table: builder_workspaces; SELECT session_json".to_owned(),
        ));
        let encoded = serde_json::to_string(&error).unwrap();
        assert!(encoded.contains("builder service unavailable"));
        assert!(!encoded.contains("SQLITE"));
        assert!(!encoded.contains("builder_workspaces"));
        assert!(!encoded.contains("SELECT"));
    }

    #[test]
    fn generated_session_ids_are_canonical_uuids() {
        let id = new_uuid();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
    }
}
