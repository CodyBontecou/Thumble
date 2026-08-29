//! Read-only native rendering of arbitrary skin review sources.
//!
//! `preview_skin_workspace` renders an existing `.pocketpad` review package or
//! skin workspace with the exact native controller renderer used by the app
//! and the `thumble` CLI. It never imports, applies, detaches, drafts, saves,
//! or otherwise observes and mutates authoritative host configuration, and it
//! never touches the paired phone. This keeps the review flow in MCP chat
//! truthful: agents can show the real controller view for a package that is
//! not installed.
//!
//! The render is delegated to the locally installed `thumble` CLI because the
//! Swift skin engine (compilation, artwork layers, state resolution) is the
//! single source of truth for native appearance. The adapter never accepts a
//! shell command: it validates every parameter, discovers the binary through
//! an explicit environment override or `PATH`, builds a fixed argument vector,
//! and enforces bounded output, a render deadline, and private temp files.

use base64::Engine as _;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio::process::Command;

const SKIN_CLI_ENV: &str = "THUMBLE_MCP_SKIN_CLI";
const CLI_NAME: &str = "thumble";
const MAXIMUM_PACKAGE_BYTES: u64 = 64 * 1024 * 1024;
const MAXIMUM_PREVIEW_PNG_BYTES: usize = 8 * 1024 * 1024;
const MAXIMUM_STDOUT_BYTES: usize = 64 * 1024;
const MAXIMUM_STDERR_BYTES: usize = 8 * 1024;
const RENDER_TIMEOUT: Duration = Duration::from_secs(120);

/// Bounded preview request validated before any process starts.
#[derive(Debug, Clone, PartialEq)]
pub struct SkinPreviewRequest {
    /// Absolute path to a `.pocketpad` review package or skin workspace.
    pub source_path: PathBuf,
    pub orientation: Option<SkinPreviewOrientation>,
    pub scheme: Option<SkinPreviewScheme>,
    pub state: Option<SkinPreviewState>,
    pub scale: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkinPreviewOrientation {
    Portrait,
    Landscape,
}

impl SkinPreviewOrientation {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Portrait => "portrait",
            Self::Landscape => "landscape",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkinPreviewScheme {
    Light,
    Dark,
}

impl SkinPreviewScheme {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Light => "light",
            Self::Dark => "dark",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SkinPreviewState {
    Normal,
    Pressed,
    Active,
    Disabled,
}

impl SkinPreviewState {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Normal => "normal",
            Self::Pressed => "pressed",
            Self::Active => "active",
            Self::Disabled => "disabled",
        }
    }
}

/// The rendered controller-view frame plus bounded identifying metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SkinPreviewImage {
    pub skin_name: String,
    pub skin_identifier: String,
    pub skin_version: String,
    pub orientation: String,
    pub color_scheme: String,
    pub state: String,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub byte_length: u64,
    pub sha256: String,
    pub png: Vec<u8>,
}

/// Validate a caller-supplied source path without reading package contents.
pub fn validate_source_path(path: &Path) -> Result<(), String> {
    if !path.is_absolute() {
        return Err("sourcePath must be an absolute path".to_owned());
    }
    let metadata = fs::metadata(path).map_err(|error| {
        format!(
            "skin preview source {} is not readable: {error}",
            path.display()
        )
    })?;
    if metadata.is_dir() {
        return Ok(());
    }
    if !metadata.is_file() {
        return Err(format!(
            "skin preview source {} is neither a .pocketpad file nor a workspace directory",
            path.display()
        ));
    }
    if path.extension().and_then(|value| value.to_str()) != Some("pocketpad") {
        return Err(format!(
            "skin preview file source {} must end with .pocketpad",
            path.display()
        ));
    }
    if metadata.len() > MAXIMUM_PACKAGE_BYTES {
        return Err(format!(
            "skin package {} is {} bytes; the preview bound is {MAXIMUM_PACKAGE_BYTES} bytes",
            path.display(),
            metadata.len()
        ));
    }
    Ok(())
}

/// Resolve the preview scale exactly like the CLI: finite and 0.5...4.
pub fn validate_scale(scale: f64) -> Result<f64, String> {
    if scale.is_finite() && (0.5..=4.0).contains(&scale) {
        Ok(scale)
    } else {
        Err("scale must be a number between 0.5 and 4".to_owned())
    }
}

/// Discover the native renderer CLI.
///
/// `THUMBLE_MCP_SKIN_CLI` must be an absolute path to an executable file.
/// Without the override, a `thumble` executable is resolved from `PATH`.
pub fn discover_skin_cli() -> Result<PathBuf, String> {
    if let Some(value) = std::env::var_os(SKIN_CLI_ENV) {
        let path = PathBuf::from(&value);
        if !path.is_absolute() {
            return Err(format!(
                "{SKIN_CLI_ENV} must be an absolute executable path"
            ));
        }
        if !is_executable_file(&path) {
            return Err(format!(
                "{SKIN_CLI_ENV}={} is not an executable file",
                path.display()
            ));
        }
        return Ok(path);
    }
    let search_path = std::env::var_os("PATH").unwrap_or_default();
    for directory in std::env::split_paths(&search_path) {
        if !directory.is_absolute() {
            continue;
        }
        let candidate = directory.join(CLI_NAME);
        if is_executable_file(&candidate) {
            return Ok(candidate);
        }
    }
    Err(format!(
        "the thumble CLI with the native skin renderer was not found on PATH; build ThumbleCLI \
         with Xcode, install it on PATH, or point {SKIN_CLI_ENV} at the absolute executable path"
    ))
}

fn is_executable_file(path: &Path) -> bool {
    let metadata = match fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(_) => return false,
    };
    metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
}

/// Render one controller-view frame for an arbitrary review source.
///
/// This is a read-only operation: the CLI renders into a private temporary
/// directory that is removed before returning, and nothing is imported,
/// applied, or synchronized to the paired phone.
pub async fn render_skin_preview(request: &SkinPreviewRequest) -> Result<SkinPreviewImage, String> {
    validate_source_path(&request.source_path)?;
    let scale = match request.scale {
        Some(scale) => validate_scale(scale)?,
        None => 2.0,
    };
    let cli = discover_skin_cli()?;

    let temporary = tempfile::Builder::new()
        .prefix("thumble-mcp-skin-preview-")
        .tempdir()
        .map_err(|error| format!("create private preview directory: {error}"))?;
    fs::set_permissions(temporary.path(), fs::Permissions::from_mode(0o700))
        .map_err(|error| format!("protect private preview directory: {error}"))?;
    let output_path = temporary.path().join("controller-view.png");

    let source = request
        .source_path
        .to_str()
        .ok_or_else(|| "sourcePath must be valid UTF-8".to_owned())?
        .to_owned();
    let output_argument = output_path
        .to_str()
        .ok_or_else(|| "preview output path must be valid UTF-8".to_owned())?
        .to_owned();
    let mut arguments = vec![
        "skin".to_owned(),
        "preview".to_owned(),
        source,
        "-o".to_owned(),
        output_argument,
        "--render-scale".to_owned(),
        format_scale(scale),
        "--json".to_owned(),
    ];
    if let Some(orientation) = request.orientation {
        arguments.push("--orientation".to_owned());
        arguments.push(orientation.as_str().to_owned());
    }
    if let Some(scheme) = request.scheme {
        arguments.push("--scheme".to_owned());
        arguments.push(scheme.as_str().to_owned());
    }
    if let Some(state) = request.state {
        arguments.push("--state".to_owned());
        arguments.push(state.as_str().to_owned());
    }

    let summary = run_skin_cli(&cli, &arguments).await?;
    let frame = single_frame(&summary)?;
    let frame_path = PathBuf::from(&frame.path);
    let png = fs::read(&frame_path).map_err(|error| {
        format!(
            "read rendered controller view {}: {error}",
            frame_path.display()
        )
    })?;
    if png.len() > MAXIMUM_PREVIEW_PNG_BYTES {
        return Err(format!(
            "rendered controller view is {} bytes; the preview bound is {MAXIMUM_PREVIEW_PNG_BYTES} bytes",
            png.len()
        ));
    }
    let (width, height) = png_dimensions(&png)?;
    if let Some(expected) = frame.pixel_width {
        if expected != width {
            return Err(format!(
                "rendered controller view width {width} does not match the reported {expected}"
            ));
        }
    }
    if let Some(expected) = frame.pixel_height {
        if expected != height {
            return Err(format!(
                "rendered controller view height {height} does not match the reported {expected}"
            ));
        }
    }
    let digest = Sha256::digest(&png);

    Ok(SkinPreviewImage {
        skin_name: summary.skin_name,
        skin_identifier: summary.skin_identifier,
        skin_version: summary.skin_version.unwrap_or_default(),
        orientation: summary.orientation,
        color_scheme: summary.color_scheme,
        state: summary.state,
        pixel_width: width,
        pixel_height: height,
        byte_length: u64::try_from(png.len()).unwrap_or(u64::MAX),
        sha256: format!("{digest:x}"),
        png,
    })
}

impl SkinPreviewImage {
    pub fn png_base64(&self) -> String {
        base64::engine::general_purpose::STANDARD.encode(&self.png)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CliPreviewSummary {
    skin_name: String,
    skin_identifier: String,
    #[serde(default)]
    skin_version: Option<String>,
    orientation: String,
    color_scheme: String,
    state: String,
    #[serde(default)]
    contact_sheet: Option<bool>,
    #[serde(default)]
    frame_count: Option<usize>,
    frames: Vec<CliPreviewFrame>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CliPreviewFrame {
    path: String,
    #[serde(default)]
    pixel_width: Option<u32>,
    #[serde(default)]
    pixel_height: Option<u32>,
}

async fn run_skin_cli(cli: &Path, arguments: &[String]) -> Result<CliPreviewSummary, String> {
    let mut command = Command::new(cli);
    command
        .args(arguments)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let mut child = command
        .spawn()
        .map_err(|error| format!("start {}: {error}", cli.display()))?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| "renderer did not provide stdout".to_owned())?;
    let mut stderr = child
        .stderr
        .take()
        .ok_or_else(|| "renderer did not provide stderr".to_owned())?;

    let render = async {
        let (stdout_result, stderr_result) = tokio::join!(
            read_bounded(&mut stdout, MAXIMUM_STDOUT_BYTES),
            read_bounded(&mut stderr, MAXIMUM_STDERR_BYTES)
        );
        let status = child.wait().await;
        (stdout_result, stderr_result, status)
    };
    let (stdout_result, stderr_result, status) =
        match tokio::time::timeout(RENDER_TIMEOUT, render).await {
            Ok(result) => result,
            Err(_) => {
                let _ = child.start_kill();
                return Err(format!(
                    "native controller render did not finish within {} seconds",
                    RENDER_TIMEOUT.as_secs()
                ));
            }
        };
    let stdout = stdout_result?;
    let stderr = stderr_result?;
    let status = status.map_err(|error| format!("wait for {}: {error}", cli.display()))?;
    if !status.success() {
        let detail = if stderr.is_empty() {
            "no diagnostics".to_owned()
        } else {
            String::from_utf8_lossy(&stderr).trim().to_owned()
        };
        return Err(format!(
            "thumble skin preview failed with status {}: {detail}",
            status.code().unwrap_or(-1)
        ));
    }
    let summary: CliPreviewSummary = serde_json::from_slice(&stdout)
        .map_err(|error| format!("parse thumble skin preview --json output: {error}"))?;
    Ok(summary)
}

async fn read_bounded<R: tokio::io::AsyncRead + Unpin>(
    reader: &mut R,
    limit: usize,
) -> Result<Vec<u8>, String> {
    let mut buffer = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let read = reader
            .read(&mut chunk)
            .await
            .map_err(|error| format!("read renderer output: {error}"))?;
        if read == 0 {
            return Ok(buffer);
        }
        if buffer.len() + read > limit {
            return Err(format!("renderer output exceeded the {limit} byte bound"));
        }
        buffer.extend_from_slice(&chunk[..read]);
    }
}

fn single_frame(summary: &CliPreviewSummary) -> Result<&CliPreviewFrame, String> {
    if summary.contact_sheet.unwrap_or(false) {
        return Err(
            "the renderer returned a contact sheet; request one controller view at a time"
                .to_owned(),
        );
    }
    if let Some(count) = summary.frame_count {
        if count != 1 {
            return Err(format!(
                "the renderer returned {count} frames; request one controller view at a time"
            ));
        }
    }
    if summary.frames.len() != 1 {
        return Err(format!(
            "the renderer returned {} frames; request one controller view at a time",
            summary.frames.len()
        ));
    }
    Ok(&summary.frames[0])
}

/// Read the IHDR dimensions of an encoded PNG without decoding it.
fn png_dimensions(png: &[u8]) -> Result<(u32, u32), String> {
    const SIGNATURE: [u8; 8] = [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
    if png.len() < 24 || png[..8] != SIGNATURE {
        return Err("the renderer did not produce a PNG controller view".to_owned());
    }
    if &png[12..16] != b"IHDR" {
        return Err("the rendered PNG is missing its IHDR header".to_owned());
    }
    let width = u32::from_be_bytes([png[16], png[17], png[18], png[19]]);
    let height = u32::from_be_bytes([png[20], png[21], png[22], png[23]]);
    if width == 0 || height == 0 {
        return Err("the rendered PNG reports an empty controller view".to_owned());
    }
    Ok((width, height))
}

fn format_scale(scale: f64) -> String {
    if (scale - scale.round()).abs() < f64::EPSILON {
        format!("{}", scale.round() as i64)
    } else {
        format!("{scale}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn request(path: &str) -> SkinPreviewRequest {
        SkinPreviewRequest {
            source_path: PathBuf::from(path),
            orientation: Some(SkinPreviewOrientation::Landscape),
            scheme: Some(SkinPreviewScheme::Light),
            state: Some(SkinPreviewState::Normal),
            scale: Some(2.0),
        }
    }

    #[test]
    fn relative_paths_are_rejected_before_any_process_starts() {
        let error = validate_source_path(Path::new("build/skin.pocketpad")).unwrap_err();
        assert!(error.contains("absolute"));
    }

    #[test]
    fn non_package_files_are_rejected() {
        let temporary = tempdir().unwrap();
        let archive = temporary.path().join("skin.zip");
        fs::write(&archive, b"not a package").unwrap();
        let error = validate_source_path(&archive).unwrap_err();
        assert!(error.contains(".pocketpad"));
    }

    #[test]
    fn missing_sources_report_the_path() {
        let error = validate_source_path(Path::new(
            "/tmp/thumble-skin-preview-does-not-exist.pocketpad",
        ))
        .unwrap_err();
        assert!(error.contains("not readable"));
    }

    #[test]
    fn scale_bounds_match_the_cli() {
        for valid in [0.5, 1.0, 2.0, 4.0] {
            assert!(validate_scale(valid).is_ok());
        }
        for invalid in [0.0, 0.49, 4.01, f64::NAN, f64::INFINITY] {
            assert!(validate_scale(invalid).is_err());
        }
    }

    #[test]
    fn render_validates_before_discovering_the_cli() {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let error = runtime
            .block_on(render_skin_preview(&request("relative.pocketpad")))
            .unwrap_err();
        assert!(error.contains("absolute"));
    }

    #[test]
    fn png_dimensions_parse_the_ihdr_header() {
        let mut png = vec![0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a];
        png.extend_from_slice(&13u32.to_be_bytes());
        png.extend_from_slice(b"IHDR");
        png.extend_from_slice(&854u32.to_be_bytes());
        png.extend_from_slice(&480u32.to_be_bytes());
        assert_eq!(png_dimensions(&png).unwrap(), (854, 480));
        assert!(png_dimensions(&png[..16]).is_err());
        let mut broken = png.clone();
        broken[12..16].copy_from_slice(b"IDAT");
        assert!(png_dimensions(&broken).is_err());
    }

    #[test]
    fn single_frame_rejects_contact_sheets_and_multi_frame_output() {
        let frame = CliPreviewFrame {
            path: "/tmp/view.png".to_owned(),
            pixel_width: Some(100),
            pixel_height: Some(100),
        };
        let summary = CliPreviewSummary {
            skin_name: "Industrial Synth".to_owned(),
            skin_identifier: "com.example.industrial-synth".to_owned(),
            skin_version: None,
            orientation: "landscape".to_owned(),
            color_scheme: "light".to_owned(),
            state: "normal".to_owned(),
            contact_sheet: Some(false),
            frame_count: Some(1),
            frames: vec![frame],
        };
        assert!(single_frame(&summary).is_ok());
        let contact_sheet = CliPreviewSummary {
            contact_sheet: Some(true),
            ..summary.clone()
        };
        assert!(single_frame(&contact_sheet)
            .unwrap_err()
            .contains("contact sheet"));
        let multi = CliPreviewSummary {
            frames: vec![
                CliPreviewFrame {
                    path: "/tmp/a.png".to_owned(),
                    pixel_width: None,
                    pixel_height: None,
                },
                CliPreviewFrame {
                    path: "/tmp/b.png".to_owned(),
                    pixel_width: None,
                    pixel_height: None,
                },
            ],
            ..summary
        };
        assert!(single_frame(&multi).unwrap_err().contains("2 frames"));
    }

    #[test]
    fn cli_json_summary_parses_the_documented_contract() {
        let summary: CliPreviewSummary = serde_json::from_str(
            r#"{
                "skinName": "Industrial Synth",
                "skinIdentifier": "com.creator.industrial-synth",
                "skinVersion": "1.0.0",
                "orientation": "landscape",
                "colorScheme": "light",
                "state": "normal",
                "contactSheet": false,
                "output": "/tmp/view.png",
                "frameCount": 1,
                "frames": [
                    {"title": "landscape · light · normal", "path": "/tmp/view.png", "pixelWidth": 1696, "pixelHeight": 1088}
                ]
            }"#,
        )
        .unwrap();
        assert_eq!(summary.skin_name, "Industrial Synth");
        assert_eq!(summary.frames[0].pixel_width, Some(1696));
    }

    #[test]
    fn scale_formats_like_the_cli_accepts() {
        assert_eq!(format_scale(2.0), "2");
        assert_eq!(format_scale(1.5), "1.5");
    }

    /// End-to-end render exercised only when a real CLI and package are
    /// provided: `THUMBLE_MCP_SKIN_TEST_PACKAGE=/abs/path.pocketpad`.
    #[test]
    fn renders_a_real_package_when_provided() {
        let Ok(package) = std::env::var("THUMBLE_MCP_SKIN_TEST_PACKAGE") else {
            return;
        };
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        let image = runtime
            .block_on(render_skin_preview(&request(&package)))
            .expect("native render");
        assert!(!image.png.is_empty());
        assert_eq!(image.sha256.len(), 64);
        assert!(image.pixel_width > 0 && image.pixel_height > 0);
    }
}
