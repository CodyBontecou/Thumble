//! Thin local facade over the shared native design service. Fixed argv only; no shell,
//! runtime UI automation, template regeneration, or authoritative state fallback.
use crate::skin_preview::discover_skin_cli;
use base64::Engine as _;
use rmcp::schemars::{self, JsonSchema};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{collections::BTreeMap, path::{Component, Path, PathBuf}, time::Duration};
use tokio::io::AsyncReadExt;

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BeginParams {
    pub workspace_path: String,
    pub profile: Option<String>,
    #[serde(rename = "draftID")]
    pub draft_id: Option<String>,
    pub expected_configuration_revision: u64,
    pub expected_draft_revision: Option<u64>,
    /// Create a durable private draft from the current authority before capture.
    pub private_draft: Option<bool>,
    pub identifier: String,
    pub name: Option<String>,
    /// Explicit normalized render viewport safe areas. No hardware insets are guessed.
    pub safe_areas: BTreeMap<String, SafeArea>,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct SafeArea { pub top: f64, pub leading: f64, pub bottom: f64, pub trailing: f64 }
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct FileEdit {
    pub path: String,
    /// Base64 file bytes, or null to delete. Only editable source paths are accepted.
    pub data: Option<String>,
}
#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UpdateParams {
    pub workspace_path: String,
    pub expected_revision: u64,
    #[serde(default)] pub edits: Vec<FileEdit>,
    #[serde(default)] pub layout_edits: Vec<LayoutEdit>,
}
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum LayoutVariant { Primary, Landscape, Portrait }

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LayoutEdit {
    pub variant: LayoutVariant,
    #[serde(rename = "controlID")] pub control_id: String,
    pub center_x: Option<f64>, pub center_y: Option<f64>,
    pub width_scale: Option<f64>, pub height_scale: Option<f64>,
    pub rotation_degrees: Option<f64>,
    /// Replace descriptive native metadata; never changes executable outputs.
    pub presentation: Option<crate::server::ElementPresentationInput>,
    #[serde(default)] pub clear_presentation: bool,
    pub visual_role: Option<crate::server::ElementVisualRoleInput>,
    #[serde(default)] pub clear_visual_role: bool,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReviewParams {
    pub workspace_path: String,
    pub expected_revision: u64,
    pub mixed_states: Option<BTreeMap<String, String>>,
    pub render_scale: Option<u8>,
    pub shows_safe_area_overlay: Option<bool>,
    pub shows_touch_targets: Option<bool>,
    /// Render native hints from the exact frozen bindings; disabled by default.
    pub shows_binding_hints: Option<bool>,
    /// Expanded native control bar evidence is included unless explicitly false.
    pub includes_control_bar: Option<bool>,
    /// Explicit native portrait device padding input, in points (0...128); default zero.
    pub minimum_portrait_top_inset: Option<f64>,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ApplyParams {
    pub workspace_path: String,
    pub expected_revision: u64,
    pub expected_configuration_revision: u64,
    pub review: u32,
    #[serde(rename = "evidenceSHA256")]
    pub evidence_sha256: String,
    #[serde(rename = "invocationID")]
    pub invocation_id: String,
    /// Optional explicit package-library directory; the default is the native app library.
    pub skin_library_path: Option<String>,
}

pub async fn apply(params: ApplyParams) -> Result<Value, String> {
    workspace(&params.workspace_path)?;
    if params.review == 0 || params.evidence_sha256.len() != 64 || !params.evidence_sha256.bytes().all(|b| b.is_ascii_hexdigit())
        || params.invocation_id.len() != 36 || !params.invocation_id.bytes().enumerate().all(|(i,b)| if [8,13,18,23].contains(&i) { b == b'-' } else { b.is_ascii_hexdigit() }) {
        return Err("apply requires a positive review, exact evidence SHA-256, and invocation UUID".into());
    }
    let mut args = vec!["design".into(), "apply".into(), "--workspace".into(), params.workspace_path,
        "--expected-revision".into(), positive(params.expected_revision)?,
        "--expected-configuration-revision".into(), positive(params.expected_configuration_revision)?,
        "--review".into(), params.review.to_string(), "--evidence-sha256".into(), params.evidence_sha256,
        "--invocation-id".into(), params.invocation_id];
    if let Some(library) = params.skin_library_path {
        workspace(&library)?;
        args.extend(["--skin-library".into(), library]);
    }
    run(args).await
}

fn workspace(path: &str) -> Result<PathBuf, String> {
    let path = PathBuf::from(path);
    if !path.is_absolute() || path.as_os_str().len() > 4096 || path.components().any(|p| matches!(p, Component::ParentDir | Component::CurDir)) {
        return Err("workspacePath must be a bounded absolute path without traversal".into());
    }
    Ok(path)
}
fn source_path(path: &str) -> bool {
    if path.len() > 512 || Path::new(path).is_absolute() || path.contains('\\') || path.split('/').any(|p| p.is_empty() || p == "." || p == "..") { return false; }
    path == "skin-source.json" || (path.starts_with("styles/") && path.ends_with(".css"))
        || (path.starts_with("sources/") && ["svg", "png", "json"].iter().any(|ext| path.ends_with(&format!(".{ext}"))))
}
fn positive(revision: u64) -> Result<String, String> {
    if revision == 0 { Err("expected revision must be positive".into()) } else { Ok(revision.to_string()) }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct InspectParams { pub workspace_path: String }

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CritiqueParams {
    pub workspace_path: String,
    pub expected_revision: u64,
    /// Structured native critique JSON: ID, review/evidence hash, reviewer, stage,
    /// verdict, and bounded issues with exact control/layer/action/frame targets.
    pub report: Value,
}

pub async fn critique(params: CritiqueParams) -> Result<Value, String> {
    workspace(&params.workspace_path)?;
    let data = serde_json::to_vec(&params.report).map_err(|_| "cannot encode critique")?;
    if data.len() > 128 * 1024 { return Err("critique exceeds byte budget".into()); }
    let temp = tempfile::tempdir().map_err(|_| "cannot prepare private critique input")?;
    let report = temp.path().join("critique.json");
    std::fs::write(&report, data).map_err(|_| "cannot write critique input")?;
    run(vec!["design".into(), "critique".into(), "--workspace".into(), params.workspace_path,
        "--expected-revision".into(), positive(params.expected_revision)?, "--report".into(), report.to_string_lossy().into_owned()]).await
}

pub async fn inspect(params: InspectParams) -> Result<Value, String> {
    workspace(&params.workspace_path)?;
    run(vec!["design".into(), "inspect".into(), "--workspace".into(), params.workspace_path]).await
}

pub async fn capabilities() -> Result<Value, String> { run(vec!["design".into(), "capabilities".into()]).await }

pub async fn begin(params: BeginParams) -> Result<Value, String> {
    workspace(&params.workspace_path)?;
    if params.identifier.len() > 256 || params.identifier.is_empty() || params.name.as_ref().is_some_and(|s| s.len() > 256)
        || params.profile.as_ref().is_some_and(|s| s.len() > 256) { return Err("design identity exceeds bounds".into()); }
    if params.safe_areas.is_empty() || params.safe_areas.len() > 2 || params.safe_areas.iter().any(|(key, v)|
        !["portrait", "landscape"].contains(&key.as_str()) || [v.top, v.leading, v.bottom, v.trailing].iter().any(|n| !n.is_finite() || !(0.0..=0.45).contains(n))) {
        return Err("safeAreas requires one or two explicit portrait/landscape viewports with finite normalized insets 0...0.45".into());
    }
    let temp = tempfile::tempdir().map_err(|_| "cannot prepare private capture input")?;
    let safe = temp.path().join("safe-areas.json");
    std::fs::write(&safe, serde_json::to_vec(&params.safe_areas).map_err(|_| "cannot encode safe areas")?).map_err(|_| "cannot write safe areas")?;
    let mut args = vec!["design".into(), "begin".into(), "--workspace".into(), params.workspace_path,
        "--identifier".into(), params.identifier, "--expected-configuration-revision".into(), positive(params.expected_configuration_revision)?,
        "--safe-areas".into(), safe.to_string_lossy().into_owned()];
    if let Some(profile) = params.profile { args.extend(["--profile".into(), profile]); }
    if let Some(name) = params.name { args.extend(["--name".into(), name]); }
    if params.private_draft == Some(true) {
        if params.draft_id.is_some() || params.expected_draft_revision.is_some() { return Err("privateDraft creates a draft and cannot resume draftID".into()); }
        args.push("--private-draft".into());
    }
    match (params.draft_id, params.expected_draft_revision) {
        (Some(id), Some(revision)) => {
            if id.len() != 36 || !id.bytes().enumerate().all(|(i, b)| if [8, 13, 18, 23].contains(&i) { b == b'-' } else { b.is_ascii_hexdigit() }) {
                return Err("draftID must be a UUID".into());
            }
            args.extend(["--draft".into(), id.to_ascii_lowercase(), "--expected-draft-revision".into(), positive(revision)?]);
        }
        (None, None) => {},
        _ => return Err("draftID and expectedDraftRevision must be supplied together".into()),
    }
    run(args).await
}

pub async fn update(params: UpdateParams) -> Result<Value, String> {
    workspace(&params.workspace_path)?;
    if params.edits.len() > 128 { return Err("at most 128 source edits are accepted".into()); }
    let mut paths = std::collections::BTreeSet::new();
    let mut total = 0;
    for edit in &params.edits {
        if !source_path(&edit.path) || !paths.insert(edit.path.clone()) { return Err("source edit paths must be safe, unique, and editable".into()); }
        if let Some(data) = &edit.data {
            if data.len() > 12 * 1024 * 1024 { return Err("source file exceeds its encoded byte limit".into()); }
            let bytes = base64::engine::general_purpose::STANDARD.decode(data).map_err(|_| "source data must be base64")?;
            total += bytes.len();
            if bytes.len() > 8 * 1024 * 1024 || total > 16 * 1024 * 1024 { return Err("source edits exceed byte limits".into()); }
        }
    }
    let temp = tempfile::tempdir().map_err(|_| "cannot prepare private source input")?;
    let edits = temp.path().join("edits.json");
    std::fs::write(&edits, serde_json::to_vec(&params.edits).map_err(|_| "cannot encode edits")?).map_err(|_| "cannot write edits")?;
    let mut args = vec!["design".into(), "update".into(), "--workspace".into(), params.workspace_path,
        "--expected-revision".into(), positive(params.expected_revision)?, "--edits".into(), edits.to_string_lossy().into_owned()];
    if !params.layout_edits.is_empty() {
        if params.layout_edits.len() > 256 { return Err("layout edit count exceeds budget".into()); }
        for edit in &params.layout_edits {
            if edit.presentation.as_ref().is_some_and(|p| !thumble_core::ElementPresentation::from(p.clone()).is_valid())
                || (edit.presentation.is_some() && edit.clear_presentation)
                || (edit.visual_role.is_some() && edit.clear_visual_role) {
                return Err("invalid or conflicting native presentation patch".into());
            }
        }
        let file = temp.path().join("layout.json");
        let data = serde_json::to_vec(&params.layout_edits).map_err(|_| "cannot encode layout edits")?;
        if data.len() > 64 * 1024 { return Err("layout edits exceed byte budget".into()); }
        std::fs::write(&file, data).map_err(|_| "cannot write layout edits")?;
        args.extend(["--layout-edits".into(), file.to_string_lossy().into_owned()]);
    }
    run(args).await
}

pub async fn review(params: ReviewParams) -> Result<(Value, Vec<String>), String> {
    let root = workspace(&params.workspace_path)?;
    let temp = tempfile::tempdir().map_err(|_| "cannot prepare private state input")?;
    let mut args = vec!["design".into(), "review".into(), "--workspace".into(), params.workspace_path,
        "--expected-revision".into(), positive(params.expected_revision)?];
    if params.shows_safe_area_overlay == Some(true) { args.push("--safe-area-overlay".into()); }
    if params.shows_touch_targets == Some(true) { args.push("--touch-targets".into()); }
    if params.shows_binding_hints == Some(true) { args.push("--binding-hints".into()); }
    if params.includes_control_bar == Some(false) { args.push("--no-control-bar".into()); }
    if let Some(inset) = params.minimum_portrait_top_inset {
        if !inset.is_finite() || !(0.0..=128.0).contains(&inset) { return Err("minimumPortraitTopInset must be 0...128 points".into()); }
        args.extend(["--portrait-top-inset".into(), inset.to_string()]);
    }
    if let Some(scale) = params.render_scale {
        if scale != 1 && scale != 2 { return Err("renderScale must be 1 or 2".into()); }
        args.extend(["--scale".into(), scale.to_string()]);
    }
    if let Some(states) = params.mixed_states {
        if states.len() > 256 || states.iter().any(|(id, state)| id.is_empty() || id.len() > 128 || !["normal", "pressed", "active", "disabled"].contains(&state.as_str())) {
            return Err("mixed states require bounded exact control IDs and native state names".into());
        }
        let file = temp.path().join("mixed.json");
        std::fs::write(&file, serde_json::to_vec(&states).map_err(|_| "cannot encode states")?).map_err(|_| "cannot write states")?;
        args.extend(["--mixed-states".into(), file.to_string_lossy().into_owned()]);
    }
    let result = run(args).await?;
    let evidence = result.get("evidence").ok_or("native review returned no evidence")?;
    let mut sheets = vec![&evidence["contactSheet"]];
    if let Some(bar) = evidence.get("controlBar") { sheets.push(&bar["contactSheet"]); }
    if let Some(drawer) = evidence.get("drawer") { sheets.push(&drawer["contactSheet"]); }
    let mut images = Vec::new();
    for sheet in sheets {
    let relative = sheet["path"].as_str().ok_or("review returned no contact sheet path")?;
    if !relative.starts_with("reviews/review-") || relative.split('/').any(|p| p == ".." || p.is_empty()) || !(relative.ends_with("/contact-sheet.png") || relative.ends_with("/control-bar-contact-sheet.png") || relative.ends_with("/drawer-contact-sheet.png")) {
        return Err("review returned an unsafe contact sheet path".into());
    }
    let file = root.join(relative);
    let canonical_root = std::fs::canonicalize(&root).map_err(|_| "cannot resolve workspace")?;
    let canonical_file = std::fs::canonicalize(&file).map_err(|_| "cannot resolve sheet")?;
    if !canonical_file.starts_with(canonical_root) { return Err("contact sheet escapes workspace".into()); }
    let metadata = std::fs::metadata(&file).map_err(|_| "contact sheet missing")?;
    if !metadata.is_file() || metadata.len() > 8 * 1024 * 1024 { return Err("contact sheet exceeds byte budget".into()); }
    let png = std::fs::read(&file).map_err(|_| "cannot read contact sheet")?;
    use sha2::{Digest, Sha256};
    let hash = format!("{:x}", Sha256::digest(&png));
    if sheet["sha256"].as_str() != Some(&hash) || sheet["byteCount"].as_u64() != Some(png.len() as u64) || !png.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err("contact sheet no longer matches native evidence".into());
    }
    images.push(base64::engine::general_purpose::STANDARD.encode(png));
    }
    Ok((result, images))
}

const ORDINARY_REPLY_BYTES: usize = 2 * 1024 * 1024;
const EVIDENCE_REPLY_BYTES: usize = 12 * 1024 * 1024;
fn reply_budget(args: &[String]) -> usize {
    if args.first().is_some_and(|s| s == "design")
        && args.get(1).is_some_and(|s| matches!(s.as_str(), "review" | "inspect")) {
        EVIDENCE_REPLY_BYTES
    } else { ORDINARY_REPLY_BYTES }
}
async fn read_output<O: tokio::io::AsyncRead + Unpin, E: tokio::io::AsyncRead + Unpin>(
    stdout: &mut O, stderr: &mut E, limit: usize,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    // Stop on either budget violation even if the other stream remains open.
    tokio::try_join!(bounded(stdout, limit), bounded(stderr, 8 * 1024))
}

async fn run(args: Vec<String>) -> Result<Value, String> {
    let cli = discover_skin_cli()?;
    let limit = reply_budget(&args);
    let mut child = tokio::process::Command::new(cli).args(args)
        .stdin(std::process::Stdio::null()).stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped()).kill_on_drop(true).spawn().map_err(|_| "cannot start native design service")?;
    let mut stdout = child.stdout.take().ok_or("native service has no stdout")?;
    let mut stderr = child.stderr.take().ok_or("native service has no stderr")?;
    let output = tokio::time::timeout(Duration::from_secs(180), async {
        let (out, err) = read_output(&mut stdout, &mut stderr, limit).await?;
        let status = child.wait().await.map_err(|_| "cannot wait for native service".to_owned())?;
        Ok::<_, String>((out, err, status))
    }).await.map_err(|_| "native design operation timed out")??;
    if !output.2.success() {
        // CLI errors contain source diagnostics and revision conflicts; bounded output only.
        return Err(format!("native design operation failed: {}", String::from_utf8_lossy(&output.1).trim()));
    }
    thumble_protocol::decode_unique_json(&output.0).map_err(|_| "native design response is not unique bounded JSON".into())
}
async fn bounded<R: tokio::io::AsyncRead + Unpin>(reader: &mut R, limit: usize) -> Result<Vec<u8>, String> {
    let mut result = Vec::new(); let mut chunk = [0; 8192];
    loop {
        let read = reader.read(&mut chunk).await.map_err(|_| "cannot read native service output")?;
        if read == 0 { return Ok(result); }
        if result.len() + read > limit { return Err("native service output exceeded budget".into()); }
        result.extend_from_slice(&chunk[..read]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn extended_reply_budget_is_only_for_native_evidence_operations() {
        for operation in ["review", "inspect"] {
            assert_eq!(reply_budget(&["design".into(), operation.into()]), EVIDENCE_REPLY_BYTES);
        }
        for operation in ["begin", "update", "apply", "critique", "capabilities"] {
            assert_eq!(reply_budget(&["design".into(), operation.into()]), ORDINARY_REPLY_BYTES);
        }
        assert_eq!(reply_budget(&["other".into(), "review".into()]), ORDINARY_REPLY_BYTES);
        assert_eq!(reply_budget(&[]), ORDINARY_REPLY_BYTES);
    }
    #[tokio::test]
    async fn evidence_reader_supports_large_matrices_and_rejects_overflow() {
        let data = vec![b'x'; ORDINARY_REPLY_BYTES + 4096];
        assert_eq!(bounded(&mut data.as_slice(), EVIDENCE_REPLY_BYTES).await.unwrap().len(), data.len());
        assert!(bounded(&mut data.as_slice(), ORDINARY_REPLY_BYTES).await.is_err());
        let oversized = vec![b'x'; EVIDENCE_REPLY_BYTES + 1];
        assert!(bounded(&mut oversized.as_slice(), EVIDENCE_REPLY_BYTES).await.is_err());
    }
    #[tokio::test]
    async fn reply_overflow_does_not_wait_for_pending_stderr() {
        use tokio::io::AsyncWriteExt;
        let (mut stdout, mut writer) = tokio::io::duplex(4096);
        let (mut stderr, _held_stderr_writer) = tokio::io::duplex(4096);
        let task = tokio::spawn(async move { let _ = writer.write_all(&vec![b'x'; 8192]).await; });
        let result = tokio::time::timeout(Duration::from_secs(1), read_output(&mut stdout, &mut stderr, 512)).await;
        task.abort(); let _ = task.await;
        assert_eq!(result.unwrap().unwrap_err(), "native service output exceeded budget");
    }

    #[tokio::test]
    async fn drawer_portrait_inset_is_bounded_before_cli_discovery() {
        let root = tempfile::tempdir().unwrap();
        for inset in [-1.0, 129.0, f64::MAX] {
            let params: ReviewParams = serde_json::from_value(serde_json::json!({
                "workspacePath": root.path().to_str().unwrap(), "expectedRevision": 1,
                "minimumPortraitTopInset": inset
            })).unwrap();
            let error = review(params).await.unwrap_err();
            assert_eq!(error, "minimumPortraitTopInset must be 0...128 points");
        }
    }
    #[test] fn design_paths_and_revisions_are_bounded_before_launch() {
        assert!(workspace("relative/workspace").is_err());
        assert!(workspace("/tmp/../escape").is_err());
        assert!(workspace("/tmp/design").is_ok());
        assert!(positive(0).is_err());
        for path in ["../escape.css", "contract/profile.json", "reviews/human-approval.json", "styles/script.js", "sources/../icon.svg"] { assert!(!source_path(path)); }
        for path in ["skin-source.json", "styles/controller.css", "sources/ability.svg"] { assert!(source_path(path)); }
    }
}
