use crate::draft_operation::{ConfigurationOperation, ConfigurationOperationOutcome};
#[path = "layout_fix.rs"]
mod layout_fix;
#[path = "element_operation.rs"]
mod element_operation;
use layout_fix::constrained_layout_fix_delta;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::error::Error;
use std::fmt;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};
use thumble_core::{
    ButtonBindings, ConfigurationDocument, KeyBinding, OutputBinding,
    MAXIMUM_CONFIGURATION_DOCUMENT_BYTES,
};
use uuid::Uuid;

const BRIDGE_SCHEMA_VERSION: u32 = 1;
const BRIDGE_EXECUTABLE_NAME: &str = "thumble-bridge";
const BRIDGE_TIMEOUT: Duration = Duration::from_secs(5);
const BRIDGE_POLL_INTERVAL: Duration = Duration::from_millis(5);
const MAXIMUM_BRIDGE_BYTES: usize = MAXIMUM_CONFIGURATION_DOCUMENT_BYTES + 256 * 1024;
const MAXIMUM_BRIDGE_STDERR_BYTES: u64 = 16 * 1024;
const MAXIMUM_CHANGED_PATHS: usize = 128;
const MAXIMUM_CHANGED_PATH_BYTES: usize = 512;

#[derive(Debug, Clone)]
pub struct ConfigurationBridge {
    executable: PathBuf,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct BridgeRequest<'a> {
    schema_version: u32,
    now_millis: i64,
    document: &'a ConfigurationDocument,
    operation: &'a ConfigurationOperation,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BridgeSuccess {
    schema_version: u32,
    document: ConfigurationDocument,
    changed: bool,
    changed_paths: Vec<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BridgeFailure {
    schema_version: u32,
    error: BridgeFailureDetail,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BridgeFailureDetail {
    code: String,
    message: String,
}

impl ConfigurationBridge {
    pub fn discover() -> Result<Self, ConfigurationBridgeError> {
        let executable = std::env::current_exe().map_err(ConfigurationBridgeError::Discovery)?;
        let directory = executable
            .parent()
            .ok_or(ConfigurationBridgeError::Unavailable)?;
        Self::at_path(directory.join(BRIDGE_EXECUTABLE_NAME))
    }

    pub fn at_path(executable: PathBuf) -> Result<Self, ConfigurationBridgeError> {
        validate_executable(&executable)?;
        Ok(Self { executable })
    }

    pub fn is_available() -> bool {
        Self::discover().is_ok()
    }

    pub fn apply(
        &self,
        document: &ConfigurationDocument,
        operation: &ConfigurationOperation,
        now_millis: i64,
    ) -> Result<(ConfigurationDocument, ConfigurationOperationOutcome), ConfigurationBridgeError>
    {
        if !operation.requires_bridge() {
            return Err(ConfigurationBridgeError::OperationNotSupported);
        }
        document
            .validate()
            .map_err(|_| ConfigurationBridgeError::InvalidDocument)?;
        operation
            .validate_bridge_input()
            .map_err(|_| ConfigurationBridgeError::InvalidOperation)?;
        validate_operation_bounds(operation)?;
        let mut input = serde_json::to_vec(&BridgeRequest {
            schema_version: BRIDGE_SCHEMA_VERSION,
            now_millis,
            document,
            operation,
        })
        .map_err(|_| ConfigurationBridgeError::EncodingFailed)?;
        if input.len() > MAXIMUM_BRIDGE_BYTES {
            return Err(ConfigurationBridgeError::InputTooLarge);
        }
        input.push(b'\n');
        let output = self.execute(input)?;

        if let Ok(failure) = thumble_protocol::decode_unique_json::<BridgeFailure>(&output) {
            if failure.schema_version != BRIDGE_SCHEMA_VERSION
                || !allowed_failure_code(&failure.error.code)
                || failure.error.message.len() > 512
            {
                return Err(ConfigurationBridgeError::InvalidResponse);
            }
            return Err(ConfigurationBridgeError::Rejected(failure.error.code));
        }
        let response: BridgeSuccess = thumble_protocol::decode_unique_json(&output)
            .map_err(|_| ConfigurationBridgeError::InvalidResponse)?;
        if response.schema_version != BRIDGE_SCHEMA_VERSION {
            return Err(ConfigurationBridgeError::InvalidResponse);
        }
        response
            .document
            .validate()
            .map_err(|_| ConfigurationBridgeError::InvalidResponse)?;
        if response.changed != (response.document != *document)
            || response.changed == response.changed_paths.is_empty()
            || response.changed_paths.len() > MAXIMUM_CHANGED_PATHS
            || response.changed_paths.iter().any(|path| {
                !path.starts_with('/')
                    || path.len() > MAXIMUM_CHANGED_PATH_BYTES
                    || path.chars().any(char::is_control)
                    || !allowed_changed_path(operation, path)
            })
            || !valid_operation_delta(document, &response.document, operation)
        {
            return Err(ConfigurationBridgeError::InvalidResponse);
        }
        Ok((
            response.document,
            ConfigurationOperationOutcome {
                changed: response.changed,
                changed_paths: response.changed_paths,
            },
        ))
    }

    fn execute(&self, input: Vec<u8>) -> Result<Vec<u8>, ConfigurationBridgeError> {
        validate_executable(&self.executable)?;
        let mut command = Command::new(&self.executable);
        command
            .env_clear()
            .current_dir("/")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        // SAFETY: this closure only invokes async-signal-safe setpgid before exec.
        unsafe {
            command.pre_exec(|| {
                if libc::setpgid(0, 0) == 0 {
                    Ok(())
                } else {
                    Err(io::Error::last_os_error())
                }
            });
        }
        let mut child = command.spawn().map_err(ConfigurationBridgeError::Launch)?;
        let process_group =
            i32::try_from(child.id()).map_err(|_| ConfigurationBridgeError::LaunchPipe)?;
        let mut stdin = child
            .stdin
            .take()
            .ok_or(ConfigurationBridgeError::LaunchPipe)?;
        let stdout = child
            .stdout
            .take()
            .ok_or(ConfigurationBridgeError::LaunchPipe)?;
        let stderr = child
            .stderr
            .take()
            .ok_or(ConfigurationBridgeError::LaunchPipe)?;
        let deadline = Instant::now() + BRIDGE_TIMEOUT;

        let (stdin_sender, stdin_receiver) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let result = stdin.write_all(&input).and_then(|()| stdin.flush());
            drop(stdin);
            let _ = stdin_sender.send(result);
        });
        let (stdout_sender, stdout_receiver) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let _ = stdout_sender.send(read_bounded(stdout, MAXIMUM_BRIDGE_BYTES + 1));
        });
        let (stderr_sender, stderr_receiver) = mpsc::sync_channel(1);
        thread::spawn(move || {
            let _ = stderr_sender.send(read_bounded(stderr, MAXIMUM_BRIDGE_STDERR_BYTES as usize));
        });

        let status = loop {
            match child.try_wait().map_err(ConfigurationBridgeError::Wait)? {
                Some(status) => break status,
                None if Instant::now() >= deadline => {
                    terminate_process_group(process_group, &mut child);
                    return Err(ConfigurationBridgeError::TimedOut);
                }
                None => thread::sleep(BRIDGE_POLL_INTERVAL),
            }
        };
        let stdin_result = receive_before_deadline(&stdin_receiver, deadline, process_group)?;
        stdin_result.map_err(ConfigurationBridgeError::Write)?;
        let stdout = receive_before_deadline(&stdout_receiver, deadline, process_group)??;
        let _stderr = receive_before_deadline(&stderr_receiver, deadline, process_group)??;
        if stdout.len() > MAXIMUM_BRIDGE_BYTES {
            return Err(ConfigurationBridgeError::OutputTooLarge);
        }
        let output = single_line(&stdout)?;
        if !status.success() && serde_json::from_slice::<BridgeFailure>(output).is_err() {
            return Err(ConfigurationBridgeError::Failed);
        }
        Ok(output.to_vec())
    }
}

fn receive_before_deadline<T>(
    receiver: &mpsc::Receiver<T>,
    deadline: Instant,
    process_group: i32,
) -> Result<T, ConfigurationBridgeError> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    receiver.recv_timeout(remaining).map_err(|error| {
        if matches!(error, mpsc::RecvTimeoutError::Timeout) {
            // Kill descendants that retained a bridge pipe after the direct child exited.
            unsafe { libc::kill(-process_group, libc::SIGKILL) };
            ConfigurationBridgeError::TimedOut
        } else {
            ConfigurationBridgeError::ReadThread
        }
    })
}

fn terminate_process_group(process_group: i32, child: &mut std::process::Child) {
    // The child called setpgid(0, 0) before exec, so a negative PID targets only its group.
    unsafe { libc::kill(-process_group, libc::SIGKILL) };
    let _ = child.kill();
    let _ = child.wait();
}

fn validate_operation_bounds(
    operation: &ConfigurationOperation,
) -> Result<(), ConfigurationBridgeError> {
    let value =
        serde_json::to_value(operation).map_err(|_| ConfigurationBridgeError::EncodingFailed)?;
    let encoded =
        serde_json::to_vec(&value).map_err(|_| ConfigurationBridgeError::EncodingFailed)?;
    if matches!(operation, ConfigurationOperation::DesignApply { .. }) {
        // The typed operation validator bounds the archive and hash fields. Ordinary
        // scalar-edit budgets cannot describe an embedded reviewed package.
        return if encoded.len() <= MAXIMUM_BRIDGE_BYTES && operation.validate_bridge_input().is_ok() {
            Ok(())
        } else { Err(ConfigurationBridgeError::OperationTooLarge) };
    }
    if encoded.len() > 64 * 1024 || !bounded_json_value(&value, 0) {
        return Err(ConfigurationBridgeError::OperationTooLarge);
    }
    Ok(())
}

fn bounded_json_value(value: &serde_json::Value, depth: usize) -> bool {
    if depth > 8 {
        return false;
    }
    match value {
        serde_json::Value::String(value) => value.len() <= 512,
        serde_json::Value::Array(values) => {
            values.len() <= 128
                && values
                    .iter()
                    .all(|value| bounded_json_value(value, depth + 1))
        }
        serde_json::Value::Object(values) => {
            values.len() <= 64
                && values
                    .iter()
                    .all(|(key, value)| key.len() <= 64 && bounded_json_value(value, depth + 1))
        }
        _ => true,
    }
}

fn allowed_failure_code(code: &str) -> bool {
    matches!(
        code,
        "invalid_json"
            | "unsupported_schema_version"
            | "unsupported_operation"
            | "unexpected_field"
            | "invalid_timestamp"
            | "non_finite_number"
            | "invalid_profile_count"
            | "invalid_profile"
            | "invalid_profile_id"
            | "duplicate_profile_id"
            | "profile_not_found"
            | "missing_selected_profile"
            | "invalid_profile_name"
            | "invalid_profile_index"
            | "replacement_profile_required"
            | "too_many_binding_maps"
            | "unknown_theme"
            | "invalid_orientation"
            | "identical_orientations"
            | "missing_orientation"
            | "invalid_element_id"
            | "invalid_element_changes"
            | "invalid_alignment"
            | "invalid_distribution"
            | "invalid_geometry"
            | "invalid_output_edit"
            | "invalid_customization_changes"
            | "invalid_device_frame"
            | "invalid_control_bar"
            | "invalid_layer_destination"
            | "invalid_group"
            | "invalid_style"
            | "invalid_destination"
            | "stale_destination"
            | "unknown_generation_preset"
            | "revision_mismatch"
            | "invalid_generated_element_ids"
            | "invalid_generated_binding"
            | "invalid_request"
    )
}

fn allowed_changed_path(operation: &ConfigurationOperation, path: &str) -> bool {
    match operation {
        ConfigurationOperation::BindingSet { profile_id, .. }
        | ConfigurationOperation::BindingClear { profile_id, .. }
        | ConfigurationOperation::BindingReset { profile_id, .. }
        | ConfigurationOperation::BindingResetAll { profile_id }
        | ConfigurationOperation::OutputMode { profile_id, .. }
        | ConfigurationOperation::OutputSet { profile_id, .. }
        | ConfigurationOperation::OutputReset { profile_id, .. }
        | ConfigurationOperation::OutputResetAll { profile_id } => {
            matches!(
                path,
                "/keyBindings"
                    | "/outputBindings"
                    | "/profileKeyBindings"
                    | "/profileOutputBindings"
            ) || path
                .eq_ignore_ascii_case(&format!("/profiles/{}", escape_json_pointer(profile_id)))
        }
        ConfigurationOperation::ProfileSelect { .. } => matches!(
            path,
            "/activeProfileID"
                | "/keyBindings"
                | "/outputBindings"
                | "/profileKeyBindings"
                | "/profileOutputBindings"
        ),
        ConfigurationOperation::ProfileSetDefault { .. } => path == "/defaultProfileID",
        ConfigurationOperation::ProfileMove { .. } => path == "/profiles",
        ConfigurationOperation::ProfileDuplicate { .. }
        | ConfigurationOperation::ProfileDelete { .. }
        | ConfigurationOperation::ProfileCreate { .. }
        | ConfigurationOperation::GenerationGenerate { .. }
        | ConfigurationOperation::TemplateInstall { .. } => matches!(
            path,
            "/profiles"
                | "/activeProfileID"
                | "/defaultProfileID"
                | "/keyBindings"
                | "/outputBindings"
                | "/profileKeyBindings"
                | "/profileOutputBindings"
        ),
        ConfigurationOperation::ProfileReset { profile_id }
        | ConfigurationOperation::CustomizationSet { profile_id, .. }
        | ConfigurationOperation::CustomizationReset { profile_id, .. }
        | ConfigurationOperation::CustomizationFix { profile_id, .. }
        | ConfigurationOperation::OrientationSet { profile_id, .. }
        | ConfigurationOperation::DeviceSet { profile_id, .. }
        | ConfigurationOperation::ControlBarSet { profile_id, .. }
        | ConfigurationOperation::ControlBarAdd { profile_id, .. }
        | ConfigurationOperation::ControlBarRemove { profile_id, .. }
        | ConfigurationOperation::ControlBarMove { profile_id, .. }
        | ConfigurationOperation::StyleCreate { profile_id, .. }
        | ConfigurationOperation::StyleRename { profile_id, .. }
        | ConfigurationOperation::StyleApply { profile_id, .. }
        | ConfigurationOperation::StyleDetach { profile_id, .. }
        | ConfigurationOperation::StyleDelete { profile_id, .. }
        | ConfigurationOperation::LayerMove { profile_id, .. }
        | ConfigurationOperation::LayerForward { profile_id, .. }
        | ConfigurationOperation::LayerBackward { profile_id, .. }
        | ConfigurationOperation::LayerFront { profile_id, .. }
        | ConfigurationOperation::LayerBack { profile_id, .. }
        | ConfigurationOperation::GroupCreate { profile_id, .. }
        | ConfigurationOperation::GroupRename { profile_id, .. }
        | ConfigurationOperation::GroupDuplicate { profile_id, .. }
        | ConfigurationOperation::GroupUngroup { profile_id, .. }
        | ConfigurationOperation::GroupHide { profile_id, .. }
        | ConfigurationOperation::GroupShow { profile_id, .. }
        | ConfigurationOperation::GroupLock { profile_id, .. }
        | ConfigurationOperation::GroupUnlock { profile_id, .. }
        | ConfigurationOperation::GroupNudge { profile_id, .. }
        | ConfigurationOperation::GroupForward { profile_id, .. }
        | ConfigurationOperation::GroupBackward { profile_id, .. }
        | ConfigurationOperation::GroupFront { profile_id, .. }
        | ConfigurationOperation::GroupBack { profile_id, .. }
        | ConfigurationOperation::ControlBarReset { profile_id, .. }
        | ConfigurationOperation::ControlBarItemReset { profile_id, .. }
        | ConfigurationOperation::ControlBarItemSet { profile_id, .. }
        | ConfigurationOperation::DesignApply { profile_id, .. }
        | ConfigurationOperation::ThemeApply { profile_id, .. }
        | ConfigurationOperation::OrientationCopy { profile_id, .. }
        | ConfigurationOperation::ElementAdd { profile_id, .. }
        | ConfigurationOperation::ElementSet { profile_id, .. }
        | ConfigurationOperation::ElementDuplicate { profile_id, .. }
        | ConfigurationOperation::ElementAlign { profile_id, .. }
        | ConfigurationOperation::ElementDistribute { profile_id, .. }
        | ConfigurationOperation::ElementNudge { profile_id, .. }
        | ConfigurationOperation::ElementDelete { profile_id, .. }
        | ConfigurationOperation::ElementReset { profile_id, .. } => {
            path.eq_ignore_ascii_case(&format!("/profiles/{}", escape_json_pointer(profile_id)))
        }
        _ => false,
    }
}

fn valid_operation_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    if before == after {
        return true;
    }
    match operation {
        ConfigurationOperation::BindingSet { profile_id, .. }
        | ConfigurationOperation::BindingClear { profile_id, .. }
        | ConfigurationOperation::BindingReset { profile_id, .. } => {
            // Exact reconstruction validates every map entry, including required
            // reconciliation of other controls' stale sidecars to owned outputs.
            valid_binding_output_delta(before, after, profile_id, None)
                && exact_binding_output_delta(before, after, operation)
        }
        ConfigurationOperation::BindingResetAll { profile_id } => {
            valid_binding_output_delta(before, after, profile_id, None)
                && exact_binding_output_delta(before, after, operation)
        }
        ConfigurationOperation::OutputMode {
            profile_id, mode, ..
        } => {
            valid_binding_output_delta(before, after, profile_id, Some(*mode))
                && exact_binding_output_delta(before, after, operation)
        }
        ConfigurationOperation::OutputSet { profile_id, .. }
        | ConfigurationOperation::OutputReset { profile_id, .. } => {
            valid_binding_output_delta(
                before,
                after,
                profile_id,
                Some(crate::draft_operation::ConfigurationOutputMode::Custom),
            ) && exact_binding_output_delta(before, after, operation)
        }
        ConfigurationOperation::OutputResetAll { profile_id } => {
            valid_binding_output_delta(
                before,
                after,
                profile_id,
                Some(crate::draft_operation::ConfigurationOutputMode::Keyboard),
            ) && exact_binding_output_delta(before, after, operation)
        }
        ConfigurationOperation::ProfileSelect { profile_id } => {
            before.profiles == after.profiles
                && before.default_profile_id == after.default_profile_id
                && profile_id_matches(&after.active_profile_id, profile_id)
                && binding_maps_preserve_existing(
                    &before.profile_key_bindings,
                    &after.profile_key_bindings,
                )
                && binding_maps_preserve_existing(
                    &before.profile_output_bindings,
                    &after.profile_output_bindings,
                )
                && profile_binding_for(&after.profile_key_bindings, &after.active_profile_id)
                    == Some(&after.key_bindings)
                && profile_binding_for(&after.profile_output_bindings, &after.active_profile_id)
                    == Some(&after.output_bindings)
        }
        ConfigurationOperation::ProfileSetDefault { profile_id } => {
            let mut expected = before.clone();
            let Some(canonical) = profile_canonical_id(before, profile_id) else {
                return false;
            };
            expected.default_profile_id = canonical;
            expected == *after
        }
        ConfigurationOperation::ProfileMove { profile_id, index } => {
            let Some(source) = profile_position(before, profile_id) else {
                return false;
            };
            if *index >= before.profiles.len() {
                return false;
            }
            let mut expected = before.clone();
            let profile = expected.profiles.remove(source);
            expected.profiles.insert(*index, profile);
            expected == *after
        }
        operation @ ConfigurationOperation::ElementAdd { .. }
        | operation @ ConfigurationOperation::ElementSet { .. } => {
            constrained_element_operation_delta(before, after, operation)
        }
        operation @ ConfigurationOperation::ControlBarItemSet { .. } => {
            constrained_control_bar_item_set_delta(before, after, operation)
        }
        operation @ ConfigurationOperation::CustomizationFix { .. } => {
            constrained_layout_fix_delta(before, after, operation)
        }
        operation @ ConfigurationOperation::CustomizationSet { .. }
        | operation @ ConfigurationOperation::DeviceSet { .. }
        | operation @ ConfigurationOperation::ControlBarSet { .. }
        | operation @ ConfigurationOperation::ControlBarAdd { .. }
        | operation @ ConfigurationOperation::ControlBarRemove { .. }
        | operation @ ConfigurationOperation::ControlBarMove { .. }
        | operation @ ConfigurationOperation::LayerMove { .. }
        | operation @ ConfigurationOperation::LayerForward { .. }
        | operation @ ConfigurationOperation::LayerBackward { .. }
        | operation @ ConfigurationOperation::LayerFront { .. }
        | operation @ ConfigurationOperation::LayerBack { .. } => {
            constrained_customization_operation_delta(before, after, operation)
        }
        operation @ ConfigurationOperation::StyleApply { .. }
        | operation @ ConfigurationOperation::StyleDetach { .. } => {
            constrained_customization_operation_delta(before, after, operation)
        }
        operation @ ConfigurationOperation::StyleCreate { .. }
        | operation @ ConfigurationOperation::StyleRename { .. }
        | operation @ ConfigurationOperation::StyleDelete { .. } => {
            constrained_style_resource_delta(before, after, operation)
        }
        operation @ ConfigurationOperation::GroupCreate { .. }
        | operation @ ConfigurationOperation::GroupRename { .. }
        | operation @ ConfigurationOperation::GroupDuplicate { .. }
        | operation @ ConfigurationOperation::GroupUngroup { .. }
        | operation @ ConfigurationOperation::GroupHide { .. }
        | operation @ ConfigurationOperation::GroupShow { .. }
        | operation @ ConfigurationOperation::GroupLock { .. }
        | operation @ ConfigurationOperation::GroupUnlock { .. }
        | operation @ ConfigurationOperation::GroupNudge { .. }
        | operation @ ConfigurationOperation::GroupForward { .. }
        | operation @ ConfigurationOperation::GroupBackward { .. }
        | operation @ ConfigurationOperation::GroupFront { .. }
        | operation @ ConfigurationOperation::GroupBack { .. } => {
            constrained_group_operation_delta(before, after, operation)
        }
        ConfigurationOperation::DesignApply { profile_id, layout_edits_json, .. } => design_appearance_delta(before, after, profile_id, layout_edits_json.as_deref()),
        ConfigurationOperation::CustomizationReset {
            profile_id,
            variant,
        }
        | ConfigurationOperation::ControlBarReset {
            profile_id,
            variant,
        }
        | ConfigurationOperation::ControlBarItemReset {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::ThemeApply {
            profile_id,
            variant,
            ..
        }
        => customization_operation_delta(before, after, profile_id, *variant),
        ConfigurationOperation::ElementDuplicate { .. }
        | ConfigurationOperation::ElementAlign { .. }
        | ConfigurationOperation::ElementDistribute { .. }
        | ConfigurationOperation::ElementNudge { .. }
        | ConfigurationOperation::ElementDelete { .. }
        | ConfigurationOperation::ElementReset { .. } => constrained_control_ownership_delta(before, after, operation),
        ConfigurationOperation::ProfileReset { profile_id } => profile_local_delta(
            before,
            after,
            profile_id,
            &[
                "customization",
                "landscapeCustomization",
                "portraitCustomization",
                "updatedAt",
            ],
        ),
        ConfigurationOperation::OrientationSet {
            profile_id,
            preference,
        } => {
            let Some(index) = profile_position(before, profile_id) else {
                return false;
            };
            let Some(canonical_id) = profile_canonical_id(before, profile_id) else {
                return false;
            };
            let expected_value = serde_json::to_value(preference).ok();
            profile_position(after, &canonical_id) == Some(index)
                && after.profiles[index].get("orientationPreference") == expected_value.as_ref()
                && profile_local_delta(
                    before,
                    after,
                    profile_id,
                    &["orientationPreference", "updatedAt"],
                )
        }
        operation @ ConfigurationOperation::OrientationCopy { .. } => {
            constrained_orientation_copy_delta(before, after, operation)
        }
        ConfigurationOperation::ProfileDuplicate {
            profile_id,
            new_profile_id,
            name,
        } => valid_profile_duplicate(before, after, profile_id, new_profile_id, name),
        ConfigurationOperation::ProfileDelete {
            profile_id,
            replacement_profile_id,
        } => valid_profile_delete(before, after, profile_id, replacement_profile_id.as_deref()),
        ConfigurationOperation::ProfileCreate {
            name,
            new_profile_id,
            source_profile_id,
            select,
            make_default,
        } => valid_profile_create(
            before,
            after,
            name,
            new_profile_id,
            source_profile_id.as_deref(),
            *select,
            *make_default,
        ),
        ConfigurationOperation::GenerationGenerate {
            destination,
            new_element_ids,
            select,
            make_default,
            ..
        } => valid_generated_install(
            before,
            after,
            GeneratedInstallExpectation {
                destination,
                expected_name: "Hollow Knight",
                template: None,
                new_element_ids,
                select: *select,
                make_default: *make_default,
            },
        ),
        ConfigurationOperation::TemplateInstall {
            template,
            destination,
            name,
            new_element_ids,
            select,
            make_default,
            ..
        } => valid_generated_install(
            before,
            after,
            GeneratedInstallExpectation {
                destination,
                expected_name: name.as_deref().unwrap_or(template.display_name()).trim(),
                template: Some((*template, template.revision())),
                new_element_ids,
                select: *select,
                make_default: *make_default,
            },
        ),
        _ => false,
    }
}

/// Design attachment may replace native appearance and detachable baselines, but it may
/// not change any executable mapping, UUID-owned control, geometry or unrelated profile field.
fn design_appearance_delta(before: &ConfigurationDocument, after: &ConfigurationDocument, profile_id: &str, layout_plan: Option<&str>) -> bool {
    let edits = match layout_plan {
        Some(raw) => match crate::draft_operation::decode_design_layout_plan(raw) { Ok(edits) => edits, Err(_) => return false },
        None => Vec::new(),
    };
    if !profile_local_delta(before, after, profile_id, &[
        "customization", "landscapeCustomization", "portraitCustomization", "skinReference",
        "skinBaselineCustomization", "landscapeSkinBaselineCustomization", "portraitSkinBaselineCustomization", "updatedAt",
    ]) { return false; }
    let Some(index) = profile_position(before, profile_id) else { return false; };
    let left = &before.profiles[index];
    let right = &after.profiles[index];
    if thumble_core::profile_owned_outputs(left) != thumble_core::profile_owned_outputs(right) { return false; }
    let appearance_fields = [
        "shape", "cornerRadius", "cornerRadii", "fillColor", "fillStyle", "fillOpacity", "accentStyle",
        "borderColor", "borderWidth", "shadowStrength", "visualStyle", "styleID", "icon",
        "lightFillStyle", "darkFillStyle", "lightFillOpacity", "darkFillOpacity",
        "thumbFill", "lightThumbFill", "darkThumbFill", "thumbOpacity", "lightThumbOpacity", "darkThumbOpacity",
        "joystickVisualStyle",
    ];
    for slot in ["customization", "landscapeCustomization", "portraitCustomization"] {
        let a = left.get(slot).filter(|v| !v.is_null());
        let b = right.get(slot).filter(|v| !v.is_null());
        if a.is_none() && b.is_none() { continue; }
        let (Some(a), Some(b)) = (a.and_then(Value::as_object), b.and_then(Value::as_object)) else { return false; };
        let mut a_rest = a.clone();
        let mut b_rest = b.clone();
        for key in ["elements", "buttonCustomizations", "customButtons", "controlBarItemCustomizations",
                    "topBarActivationRegion", "styleLibrary", "assetLibrary", "artworkLayers", "backgroundFillStyle", "backgroundColor", "updatedAt"] {
            a_rest.remove(key); b_rest.remove(key);
        }
        if a_rest != b_rest { return false; }
        let element_map = |object: &Map<String, Value>| -> Option<std::collections::BTreeMap<String, Value>> {
            let elements = object.get("elements")?.as_array()?;
            let mut map = std::collections::BTreeMap::new();
            for element in elements {
                let mut stripped = element.as_object()?.clone();
                let id = stripped.get("id")?.as_str()?.to_ascii_lowercase();
                if let Some(layout) = stripped.get_mut("layout").and_then(Value::as_object_mut) {
                    for field in appearance_fields { layout.remove(field); }
                }
                if map.insert(id, Value::Object(stripped)).is_some() { return None; }
            }
            Some(map)
        };
        let (Some(mut a_elements), Some(b_elements)) = (element_map(a), element_map(b)) else { return false; };
        let variant = match slot { "landscapeCustomization" => crate::draft_operation::ConfigurationVariant::Landscape,
            "portraitCustomization" => crate::draft_operation::ConfigurationVariant::Portrait, _ => crate::draft_operation::ConfigurationVariant::Primary };
        for edit in edits.iter().filter(|edit| edit.variant == variant && edit.control_id != crate::draft_operation::DESIGN_REVEAL_CONTROL_ID) {
            let Some((_, id)) = edit.control_id.split_once('.') else { return false; };
            let Some(element) = a_elements.get_mut(&id.to_ascii_lowercase()).and_then(Value::as_object_mut) else { return false; };
            if edit.clear_visual_role { element.remove("visualRole"); }
            if let Some(role) = edit.visual_role {
                let Ok(value) = serde_json::to_value(role) else { return false; };
                element.insert("visualRole".into(), value);
            }
            if edit.clear_presentation { element.remove("presentation"); }
            if let Some(presentation) = &edit.presentation {
                let Ok(value) = serde_json::to_value(presentation) else { return false; };
                element.insert("presentation".into(), value);
            }
            let Some(layout) = element.get_mut("layout").and_then(Value::as_object_mut) else { return false; };
            for (key, value) in [("centerX", edit.center_x), ("centerY", edit.center_y), ("widthScale", edit.width_scale),
                ("heightScale", edit.height_scale), ("rotationDegrees", edit.rotation_degrees)] {
                if let Some(value) = value { layout.insert(key.into(), serde_json::json!(value)); }
            }
        }
        if !json_semantically_equal(&serde_json::json!(a_elements), &serde_json::json!(b_elements)) { return false; }
        // Existing explicit reveal geometry remains fixed. Absent fields are native defaults
        // and are checked by the native transform's exact resolved-geometry guard.
        if let Some(reveal) = a.get("topBarActivationRegion").and_then(Value::as_object) {
            for key in ["centerX", "centerY", "widthScale", "heightScale", "rotationDegrees", "hitInsets", "isHidden"] {
                if let Some(value) = reveal.get(key) {
                    let planned = edits.iter().find(|e| e.variant == variant && e.control_id == crate::draft_operation::DESIGN_REVEAL_CONTROL_ID)
                        .and_then(|e| match key { "centerX" => e.center_x, "centerY" => e.center_y, "widthScale" => e.width_scale,
                            "heightScale" => e.height_scale, "rotationDegrees" => e.rotation_degrees, _ => None });
                    let expected = planned.map(|v| serde_json::json!(v)).unwrap_or_else(|| value.clone());
                    if !json_semantically_equal(b.get("topBarActivationRegion").and_then(|r| r.get(key)).unwrap_or(&Value::Null), &expected) { return false; }
                }
            }
        }
    }
    true
}

fn customization_operation_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    profile_id: &str,
    variant: crate::draft_operation::ConfigurationVariant,
) -> bool {
    let (Some(before_index), Some(after_index)) = (
        profile_position(before, profile_id),
        profile_position(after, profile_id),
    ) else {
        return false;
    };
    let (Some(before_profile), Some(after_profile)) = (
        before.profiles[before_index].as_object(),
        after.profiles[after_index].as_object(),
    ) else {
        return false;
    };
    let landscape_changed =
        before_profile.get("landscapeCustomization") != after_profile.get("landscapeCustomization");
    let portrait_changed =
        before_profile.get("portraitCustomization") != after_profile.get("portraitCustomization");
    let target_key = match variant {
        crate::draft_operation::ConfigurationVariant::Landscape => "landscapeCustomization",
        crate::draft_operation::ConfigurationVariant::Portrait => "portraitCustomization",
        crate::draft_operation::ConfigurationVariant::Primary => {
            match (landscape_changed, portrait_changed) {
                (true, false) => "landscapeCustomization",
                (false, true) => "portraitCustomization",
                (true, true)
                    if after_profile.get("landscapeCustomization")
                        == after_profile.get("customization")
                        && before_profile.get("portraitCustomization").is_none()
                        && after_profile.get("portraitCustomization")
                            == before_profile.get("customization") =>
                {
                    "landscapeCustomization"
                }
                (true, true)
                    if after_profile.get("portraitCustomization")
                        == after_profile.get("customization")
                        && before_profile.get("landscapeCustomization").is_none()
                        && after_profile.get("landscapeCustomization")
                            == before_profile.get("customization") =>
                {
                    "portraitCustomization"
                }
                _ => return false,
            }
        }
    };
    if !customization_mirrors_are_semantically_equal(
        after_profile.get(target_key),
        after_profile.get("customization"),
        variant,
    ) {
        return false;
    }
    let preserved_key = if target_key == "landscapeCustomization" {
        "portraitCustomization"
    } else {
        "landscapeCustomization"
    };
    let preserved_changed = before_profile.get(preserved_key) != after_profile.get(preserved_key);
    if preserved_changed
        && (before_profile.get(preserved_key).is_some()
            || after_profile.get(preserved_key) != before_profile.get("customization"))
    {
        return false;
    }
    if preserved_changed {
        profile_local_delta(
            before,
            after,
            profile_id,
            &["customization", target_key, preserved_key, "updatedAt"],
        )
    } else {
        profile_local_delta(
            before,
            after,
            profile_id,
            &["customization", target_key, "updatedAt"],
        )
    }
}

fn customization_mirrors_are_semantically_equal(
    selected: Option<&Value>,
    primary: Option<&Value>,
    variant: crate::draft_operation::ConfigurationVariant,
) -> bool {
    if selected == primary {
        return true;
    }
    if variant != crate::draft_operation::ConfigurationVariant::Landscape {
        return false;
    }
    fn compact_default_landscape_canvas(value: Option<&Value>) -> Option<Value> {
        let mut value = value?.clone();
        let object = value.as_object_mut()?;
        let is_default = object.get("deviceCanvas").is_some_and(|canvas| {
            canvas.as_object().is_some_and(|canvas| {
                canvas.len() == 1
                    && canvas.get("frameID").and_then(Value::as_str)
                        == Some("iphone-17-pro-landscape")
            })
        });
        if is_default {
            object.remove("deviceCanvas");
        }
        Some(value)
    }
    compact_default_landscape_canvas(selected) == compact_default_landscape_canvas(primary)
}

fn constrained_element_operation_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    use crate::draft_operation::{ConfigurationVariant, ElementKind};

    let (profile_id, variant, element_id, changes, add_kind) = match operation {
        ConfigurationOperation::ElementAdd {
            profile_id,
            variant,
            element_id,
            kind,
            changes,
        } => (
            profile_id.as_str(),
            *variant,
            element_id.as_str(),
            changes.as_ref(),
            Some(*kind),
        ),
        ConfigurationOperation::ElementSet {
            profile_id,
            variant,
            element_id,
            changes,
        } => (
            profile_id.as_str(),
            *variant,
            element_id.as_str(),
            changes.as_ref(),
            None,
        ),
        _ => return false,
    };
    if (changes.is_presentation_only() || changes.is_output_only()) && add_kind.is_none() {
        return constrained_raw_element_fields_delta(before, after, profile_id, variant, element_id, changes);
    }
    if !customization_operation_delta(before, after, profile_id, variant) {
        return false;
    }
    let (Some(before_index), Some(after_index)) = (
        profile_position(before, profile_id),
        profile_position(after, profile_id),
    ) else {
        return false;
    };
    let (Some(before_profile), Some(after_profile)) = (
        before.profiles[before_index].as_object(),
        after.profiles[after_index].as_object(),
    ) else {
        return false;
    };
    let source_key = match variant {
        ConfigurationVariant::Primary => "customization",
        ConfigurationVariant::Landscape => "landscapeCustomization",
        ConfigurationVariant::Portrait => "portraitCustomization",
    };
    let (Some(before_customization), Some(after_customization)) = (
        before_profile
            .get(source_key)
            .or_else(|| before_profile.get("customization"))
            .and_then(Value::as_object),
        after_profile
            .get("customization")
            .and_then(Value::as_object),
    ) else {
        return false;
    };

    if !element_capacity_is_valid(after_customization) {
        return false;
    }
    // Compare logical appearance records derived only from declared controls.
    // Raw native overlays may omit unchanged mirrors and retain compact layouts.
    let mut before_appearance = before_customization.clone();
    let mut after_appearance = after_customization.clone();
    if !materialize_declared_custom_mirrors(&mut before_appearance)
        || !materialize_declared_custom_mirrors(&mut after_appearance) { return false; }
    let before_customization = &before_appearance;
    let after_customization = &after_appearance;
    let before_identity = if add_kind.is_some() {
        format!("custom:{}", element_id.to_ascii_lowercase())
    } else {
        let Some(identity) = resolve_layer_identity(before_customization, element_id) else {
            return false;
        };
        let Some(identity) = layer_identity_key(&identity) else {
            return false;
        };
        identity
    };
    let after_custom = custom_control_by_id(after_customization, element_id);
    let before_custom = custom_control_by_id(before_customization, element_id);
    let after_element = element_by_identity(after_customization, &before_identity);
    let before_element = element_by_identity(before_customization, &before_identity);
    if !map_changed_only_at(
        before_customization,
        after_customization,
        "customControlKinds",
        element_id,
    ) || !map_changed_only_at(
        before_customization,
        after_customization,
        "elementKinds",
        element_id,
    ) || !map_changed_only_at(
        before_customization,
        after_customization,
        "elementOutputBindings",
        element_id,
    ) {
        return false;
    }

    if !element_presentation_after_is_exact(before_element, after_element, changes) { return false; }
    if add_kind.is_some() {
        if before_custom.is_some()
            || before_element.is_some()
            || after_custom.is_none()
            || !sibling_controls_equal(
                before_customization,
                after_customization,
                "customButtons",
                |value| {
                    value
                        .get("id")
                        .and_then(Value::as_str)
                        .is_some_and(|id| id.eq_ignore_ascii_case(element_id))
                },
            )
            || !sibling_controls_equal(
                before_customization,
                after_customization,
                "elements",
                |value| element_identity_key(value).as_deref() == Some(before_identity.as_str()),
            )
        {
            return false;
        }
        let Some(custom) = after_custom else {
            return false;
        };
        let final_kind = requested_element_kind(add_kind.unwrap(), changes);
        if custom.get("controlKind").and_then(Value::as_str) != Some(element_kind_name(final_kind))
            || custom
                .get("id")
                .and_then(Value::as_str)
                .is_none_or(|id| !id.eq_ignore_ascii_case(element_id))
        {
            return false;
        }
        if let Some(element) = after_element {
            if !custom_element_mirrors_match(custom, element) {
                return false;
            }
        } else if !custom
            .get("layout")
            .and_then(|layout| layout.get("isHidden"))
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            return false;
        }
        if !valid_add_layer_delta(before_customization, after_customization, element_id) {
            return false;
        }
    } else {
        if !sibling_controls_equal(
            before_customization,
            after_customization,
            "customButtons",
            |value| {
                value
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| id.eq_ignore_ascii_case(element_id))
            },
        ) || !sibling_controls_equal(
            before_customization,
            after_customization,
            "elements",
            |value| element_identity_key(value).as_deref() == Some(before_identity.as_str()),
        ) {
            return false;
        }
        if before_custom.is_some() {
            let Some(custom) = after_custom else {
                return false;
            };
            if let Some(element) = after_element {
                if !custom_element_mirrors_match(custom, element) {
                    return false;
                }
            }
            if !target_changed_keys_allowed(before_custom, Some(custom), changes, true) {
                return false;
            }
        } else if let Some(button) = before_identity.strip_prefix("builtin:") {
            if !map_changed_only_at(
                before_customization,
                after_customization,
                "labelOverrides",
                button,
            ) {
                return false;
            }
            let before_owned_layout = builtin_layout(before_customization, button).map(|layout| {
                let mut normalized = normalized_known_layout(layout);
                normalized.entry("shape".to_owned()).or_insert_with(|| Value::String("rounded_rectangle".to_owned()));
                Value::Object(normalized)
            });
            let before_layout = before_owned_layout.as_ref();
            let after_layout = saved_button_layout_value(after_customization, button);
            let after_normalized_layout = after_layout.and_then(Value::as_object).map(|layout| {
                let mut normalized = normalized_known_layout(layout.clone());
                normalized.entry("shape".to_owned()).or_insert_with(|| Value::String("rounded_rectangle".to_owned()));
                Value::Object(normalized)
            });
            if !button_customization_siblings_equal(
                before_customization,
                after_customization,
                button,
            ) || !layout_changed_keys_allowed(before_layout, after_normalized_layout.as_ref(), changes)
                || after_layout.is_some_and(|layout| {
                    after_element.is_some_and(|element| {
                        !custom_element_mirrors_match(
                            &serde_json::json!({"id": element["id"], "label": element["label"], "controlKind":"button", "layout":layout, "visualRole":element.get("visualRole")}),
                            &serde_json::json!({"id": element["id"], "label": element["label"], "kind":"button", "layout":element.get("layout"), "visualRole":element.get("visualRole")})
                        )
                    })
                })
            {
                return false;
            }
        } else if before_identity == "system:top_bar_activation"
            && !layout_changed_keys_allowed(
                before_customization.get("topBarActivationRegion"),
                after_customization.get("topBarActivationRegion"),
                changes,
            )
        {
            return false;
        }
        if !target_changed_keys_allowed(before_element, after_element, changes, false) {
            return false;
        }
        if !json_semantically_equal(
            before_customization
                .get("designMetadata")
                .unwrap_or(&Value::Null),
            after_customization
                .get("designMetadata")
                .unwrap_or(&Value::Null),
        ) {
            return false;
        }
    }

    if !non_element_customization_fields_equal(before_customization, after_customization)
        || !element_output_change_is_exact(before_element, after_element, changes.output.as_ref())
        || !target_has_no_forbidden_injection(before_custom, after_custom)
        || !target_has_no_forbidden_element_injection(before_element, after_element)
    {
        return false;
    }
    if requested_element_kind(
        add_kind
            .or_else(|| {
                before_custom
                    .and_then(|value| value.get("controlKind"))
                    .and_then(Value::as_str)
                    .and_then(parse_element_kind)
            })
            .unwrap_or(ElementKind::Button),
        changes,
    )
    .is_passive()
        && changes.output.is_some()
    {
        return false;
    }
    true
}

/// Appearance/geometry operations must not alter owned executable data or
/// introduce undeclared identities, even when both orientation mirrors change.
fn constrained_control_ownership_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    use crate::draft_operation::ConfigurationVariant;
    let (profile_id, variant) = match operation {
        ConfigurationOperation::ElementDuplicate { profile_id, variant, .. }
        | ConfigurationOperation::ElementAlign { profile_id, variant, .. }
        | ConfigurationOperation::ElementDistribute { profile_id, variant, .. }
        | ConfigurationOperation::ElementNudge { profile_id, variant, .. }
        | ConfigurationOperation::ElementDelete { profile_id, variant, .. }
        | ConfigurationOperation::ElementReset { profile_id, variant, .. } => (profile_id, *variant),
        _ => return false,
    };
    if !customization_operation_delta(before, after, profile_id, variant) {
        return false;
    }
    let source_key = match variant {
        ConfigurationVariant::Primary => "customization",
        ConfigurationVariant::Landscape => "landscapeCustomization",
        ConfigurationVariant::Portrait => "portraitCustomization",
    };
    let (Some(before_profile), Some(after_profile)) = (
        profile_position(before, profile_id).and_then(|index| before.profiles[index].as_object()),
        profile_position(after, profile_id).and_then(|index| after.profiles[index].as_object()),
    ) else { return false; };
    let (Some(source), Some(result)) = (
        before_profile.get(source_key).or_else(|| before_profile.get("customization")).and_then(Value::as_object),
        after_profile.get("customization").and_then(Value::as_object),
    ) else { return false; };
    let mut resolved_source = source.clone();
    if variant != ConfigurationVariant::Primary {
        if let Some(color) = before_profile.get("customization").and_then(|value| value.get("colorSchemePreference")) {
            resolved_source.insert("colorSchemePreference".to_owned(), color.clone());
        }
    }
    let source = &resolved_source;
    fn declared(customization: &Map<String, Value>) -> Option<std::collections::BTreeMap<Uuid, &Value>> {
        let mut ids = std::collections::BTreeMap::new();
        for element in customization.get("elements")?.as_array()? {
            let id = Uuid::parse_str(element.get("id")?.as_str()?).ok()?;
            if ids.insert(id, element).is_some() { return None; }
        }
        Some(ids)
    }
    let (Some(source_elements), Some(result_elements)) = (declared(source), declared(result)) else { return false; };
    let mut expected_ids = source_elements.keys().copied().collect::<std::collections::BTreeSet<_>>();
    let mut duplicate_sources = Vec::new();
    let mut reset_id = None;
    match operation {
        ConfigurationOperation::ElementDuplicate { element_ids, new_element_ids, .. } => {
            if element_ids.is_empty() || element_ids.len() != new_element_ids.len() { return false; }
            let mut sources_seen = std::collections::HashSet::new();
            for (old, new) in element_ids.iter().zip(new_element_ids) {
                let (Ok(old), Ok(new)) = (Uuid::parse_str(old), Uuid::parse_str(new)) else { return false; };
                let Some(source) = source_elements.get(&old) else { return false; };
                if !sources_seen.insert(old) || !expected_ids.insert(new) { return false; }
                duplicate_sources.push((new, *source));
            }
        }
        ConfigurationOperation::ElementDelete { element_id, .. } => {
            let Some(identity) = resolve_layer_identity(source, element_id).and_then(|id| layer_identity_key(&id)) else { return false; };
            if let Some(id) = identity.strip_prefix("custom:").and_then(|id| Uuid::parse_str(id).ok()) {
                if !expected_ids.remove(&id) { return false; }
            }
        }
        ConfigurationOperation::ElementReset { element_id, .. } => {
            reset_id = Uuid::parse_str(element_id).ok();
            if reset_id.is_none() && !matches!(element_id.as_str(), "system.top_bar_activation") { return false; }
            if reset_id.is_some_and(|id| !source_elements.contains_key(&id)) { return false; }
        }
        ConfigurationOperation::ElementAlign { element_ids, .. }
        | ConfigurationOperation::ElementDistribute { element_ids, .. }
        | ConfigurationOperation::ElementNudge { element_ids, .. } => {
            if element_ids.iter().any(|id| resolve_layer_identity(source, id).is_none()) { return false; }
        }
        _ => return false,
    }
    if expected_ids != result_elements.keys().copied().collect() || !element_capacity_is_valid(result) {
        return false;
    }
    let mut mirror_ids = std::collections::HashSet::new();
    for mirror in result.get("customButtons").and_then(Value::as_array).into_iter().flatten() {
        let Some(id) = mirror.get("id").and_then(Value::as_str).and_then(|id| Uuid::parse_str(id).ok()) else { return false; };
        if !expected_ids.contains(&id) || !mirror_ids.insert(id) || !custom_element_appearance_matches(mirror, result_elements[&id]) {
            return false;
        }
    }
    for (id, original) in &source_elements {
        let Some(next) = result_elements.get(id) else { continue; };
        let (Some(original_object), Some(next_object)) = (original.as_object(), next.as_object()) else { return false; };
        let reset = reset_id == Some(*id);
        for key in original_object.keys().chain(next_object.keys()) {
            if key == "layout" || key == "id" || (reset && matches!(key.as_str(), "label" | "joystickOutputSettings" | "triggerSettings" | "trackpadSettings")) {
                continue;
            }
            let equal = if key == "partOutputs" {
                element_part_outputs(original) == element_part_outputs(next)
            } else {
                json_semantically_equal(original.get(key).unwrap_or(&Value::Null), next.get(key).unwrap_or(&Value::Null))
            };
            if !equal { return false; }
        }
    }
    for (new_id, original) in duplicate_sources {
        let Some(next) = result_elements.get(&new_id) else { return false; };
        let Some(mirror) = custom_control_by_id(result, &new_id.to_string()).and_then(Value::as_object) else { return false; };
        let Some(expected) = duplicate_element_from_button(mirror, original, &new_id.to_string().to_uppercase()) else { return false; };
        if !json_semantically_equal(next, &Value::Object(expected)) { return false; }
    }
    if let ConfigurationOperation::ElementNudge { element_ids, delta_x, delta_y, .. } = operation {
        let mut expected = source.clone();
        let mut logical_result = result.clone();
        if !materialize_declared_custom_mirrors(&mut expected)
            || !materialize_declared_custom_mirrors(&mut logical_result) { return false; }
        let Some(children) = element_ids.iter().map(|id| resolve_layer_identity(&expected, id)).collect::<Option<Vec<_>>>() else { return false; };
        let frame_id = expected.get("deviceCanvas").and_then(|value| value.get("frameID")).and_then(Value::as_str).unwrap_or("iphone-17-pro-landscape").to_owned();
        if !apply_expected_group_nudge(&mut expected, &logical_result, &children, &frame_id, *delta_x, *delta_y) { return false; }
        correct_customization_frame_orientation(&mut expected, variant);
        if !json_semantically_equal(&Value::Object(expected), &Value::Object(logical_result)) { return false; }
    }
    if matches!(operation, ConfigurationOperation::ElementAlign { .. } | ConfigurationOperation::ElementDistribute { .. })
        && !layout_fix::constrained_element_arrangement_delta(source, result, operation) {
        return false;
    }
    if matches!(operation, ConfigurationOperation::ElementDuplicate { .. } | ConfigurationOperation::ElementDelete { .. } | ConfigurationOperation::ElementReset { .. })
        && !element_operation::constrained_lifecycle_delta(source, result, operation) {
        return false;
    }
    true
}

fn requested_element_kind(
    initial: crate::draft_operation::ElementKind,
    changes: &crate::draft_operation::ElementChanges,
) -> crate::draft_operation::ElementKind {
    let explicit = changes.kind.unwrap_or(initial);
    if changes.joystick_mapping.is_some()
        || changes.joystick_settings.is_some()
        || changes.joystick_visual_style.is_some()
    {
        crate::draft_operation::ElementKind::Joystick
    } else if changes.trigger_settings.is_some() {
        crate::draft_operation::ElementKind::Trigger
    } else if changes.trackpad_settings.is_some() {
        crate::draft_operation::ElementKind::Trackpad
    } else {
        explicit
    }
}

fn element_kind_name(kind: crate::draft_operation::ElementKind) -> &'static str {
    use crate::draft_operation::ElementKind;
    match kind {
        ElementKind::Button => "button",
        ElementKind::Joystick => "joystick",
        ElementKind::Trigger => "trigger",
        ElementKind::Trackpad => "trackpad",
        ElementKind::Text => "text",
        ElementKind::Decoration => "decoration",
    }
}

fn parse_element_kind(value: &str) -> Option<crate::draft_operation::ElementKind> {
    use crate::draft_operation::ElementKind;
    Some(match value {
        "button" => ElementKind::Button,
        "joystick" => ElementKind::Joystick,
        "trigger" => ElementKind::Trigger,
        "trackpad" => ElementKind::Trackpad,
        "text" => ElementKind::Text,
        "decoration" => ElementKind::Decoration,
        _ => return None,
    })
}



fn custom_control_by_id<'a>(customization: &'a Map<String, Value>, id: &str) -> Option<&'a Value> {
    customization
        .get("customButtons")?
        .as_array()?
        .iter()
        .find(|value| {
            value
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|candidate| candidate.eq_ignore_ascii_case(id))
        })
}

fn element_by_identity<'a>(
    customization: &'a Map<String, Value>,
    identity: &str,
) -> Option<&'a Value> {
    customization
        .get("elements")?
        .as_array()?
        .iter()
        .find(|value| element_identity_key(value).as_deref() == Some(identity))
}

fn element_identity_key(value: &Value) -> Option<String> {
    let id = value.get("id")?.as_str()?;
    let identity = thumble_protocol::KeypadElementID::parse(id)?;
    let kind = if identity.starter_index().is_some() && value.get("kind").and_then(Value::as_str).unwrap_or("button") == "button" { "builtin" } else { "custom" };
    Some(format!("{kind}:{}", id.to_ascii_lowercase()))
}

fn sibling_controls_equal(
    before: &Map<String, Value>,
    after: &Map<String, Value>,
    key: &str,
    is_target: impl Fn(&Value) -> bool,
) -> bool {
    let filtered = |customization: &Map<String, Value>| {
        customization
            .get(key)
            .and_then(Value::as_array)
            .map(|values| {
                values
                    .iter()
                    .filter(|value| !is_target(value))
                    .cloned()
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default()
    };
    let before = filtered(before);
    let after = filtered(after);
    json_semantically_equal(&Value::Array(before), &Value::Array(after))
}

fn custom_element_mirrors_match(custom: &Value, element: &Value) -> bool {
    fn appearance(value: &Value) -> Option<Value> {
        let mut record = value.as_object()?.clone();
        let kind = record.get("controlKind").or_else(|| record.get("kind")).cloned()
            .unwrap_or_else(|| Value::String("button".to_owned()));
        record.insert("controlKind".to_owned(), kind);
        let mut layout = normalized_known_layout(record.get("layout").and_then(Value::as_object).cloned().unwrap_or_default());
        normalize_duplicate_kind_layout(&mut record, &mut layout);
        record.insert("layout".to_owned(), Value::Object(layout));
        Some(Value::Object(record))
    }
    let (Some(custom), Some(element)) = (appearance(custom), appearance(element)) else { return false; };
    for (custom_key, element_key) in [
        ("id", "id"),
        ("label", "label"),
        ("controlKind", "kind"),
        ("layout", "layout"),
        ("visualRole", "visualRole"),
        ("joystickMapping", "joystickMapping"),
        ("joystickOutputSettings", "joystickOutputSettings"),
        ("triggerSettings", "triggerSettings"),
        ("trackpadSettings", "trackpadSettings"),
    ] {
        if !json_semantically_equal(
            custom.get(custom_key).unwrap_or(&Value::Null),
            element.get(element_key).unwrap_or(&Value::Null),
        ) {
            return false;
        }
    }
    true
}

fn custom_element_appearance_matches(custom: &Value, element: &Value) -> bool {
    custom_element_mirrors_match(custom, element)
}

fn element_capacity_is_valid(customization: &Map<String, Value>) -> bool {
    let Some(buttons) = customization.get("elements").and_then(Value::as_array) else {
        return false;
    };
    if buttons.len() > 128 {
        return false;
    }
    let mut ids = std::collections::BTreeSet::new();
    let mut joystick = 0;
    let mut trigger = 0;
    let mut trackpad = 0;
    for button in buttons {
        let Some(id) = button.get("id").and_then(Value::as_str) else {
            return false;
        };
        if Uuid::parse_str(id).is_err() || !ids.insert(id.to_ascii_lowercase()) {
            return false;
        }
        match button
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("button")
        {
            "joystick" => joystick += 1,
            "trigger" => trigger += 1,
            "trackpad" => trackpad += 1,
            "button" | "text" | "decoration" => {}
            _ => return false,
        }
    }
    joystick <= 2 && trigger <= 2 && trackpad <= 1
}

fn non_element_customization_fields_equal(
    before: &Map<String, Value>,
    after: &Map<String, Value>,
) -> bool {
    let stripped = |value: &Map<String, Value>| {
        let mut value = value.clone();
        for key in [
            "customButtons",
            "elements",
            "buttonCustomizations",
            "labelOverrides",
            "topBarActivationRegion",
            "designMetadata",
        ] {
            value.remove(key);
        }
        Value::Object(value)
    };
    json_semantically_equal(&stripped(before), &stripped(after))
}

fn map_changed_only_at(
    before: &Map<String, Value>,
    after: &Map<String, Value>,
    property: &str,
    target: &str,
) -> bool {
    fn without_target(value: &Map<String, Value>, property: &str, target: &str) -> Value {
        let mut object = value
            .get(property)
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        object.remove(target);
        Value::Object(object)
    }
    json_semantically_equal(
        &without_target(before, property, target),
        &without_target(after, property, target),
    )
}

// Swift encodes [KeypadElementID: Layout] as an alternating key/value JSON array.
fn saved_button_layout_value<'a>(
    customization: &'a Map<String, Value>,
    button: &str,
) -> Option<&'a Value> {
    let values = customization.get("buttonCustomizations")?.as_array()?;
    if values.len() % 2 != 0 {
        return None;
    }
    values.chunks_exact(2).find_map(|pair| {
        pair[0]
            .as_str()
            .filter(|candidate| candidate.eq_ignore_ascii_case(button))
            .and_then(|_| pair[1].is_object().then_some(&pair[1]))
    })
}

fn button_customization_siblings_equal(
    before: &Map<String, Value>,
    after: &Map<String, Value>,
    target: &str,
) -> bool {
    fn siblings(customization: &Map<String, Value>, target: &str) -> Option<Vec<Value>> {
        let Some(values) = customization.get("buttonCustomizations") else {
            return Some(Vec::new());
        };
        let values = values.as_array()?;
        if values.len() % 2 != 0 {
            return None;
        }
        let mut result = Vec::with_capacity(values.len());
        for pair in values.chunks_exact(2) {
            let button = pair[0].as_str()?;
            if !pair[1].is_object() {
                return None;
            }
            if !button.eq_ignore_ascii_case(target) {
                result.extend_from_slice(pair);
            }
        }
        Some(result)
    }
    let (Some(before), Some(after)) = (siblings(before, target), siblings(after, target)) else {
        return false;
    };
    json_semantically_equal(&Value::Array(before), &Value::Array(after))
}

fn constrained_raw_element_fields_delta(before: &ConfigurationDocument, after: &ConfigurationDocument,
    profile_id: &str, variant: crate::draft_operation::ConfigurationVariant, element_id: &str,
    changes: &crate::draft_operation::ElementChanges) -> bool {
    let Some(index) = profile_position(before, profile_id) else { return false; };
    let Some(after_index) = profile_position(after, profile_id) else { return false; };
    let Some(profile) = before.profiles[index].as_object() else { return false; };
    let Some(primary) = profile.get("customization").and_then(Value::as_object) else { return false; };
    let Some((width, height)) = customization_canvas_size(primary) else { return false; };
    let primary_portrait = width < height;
    let target_portrait = match variant {
        crate::draft_operation::ConfigurationVariant::Primary => primary_portrait,
        crate::draft_operation::ConfigurationVariant::Portrait => true,
        crate::draft_operation::ConfigurationVariant::Landscape => false,
    };
    let key = if target_portrait { "portraitCustomization" } else { "landscapeCustomization" };
    let mut keys = Vec::new();
    if primary_portrait == target_portrait { keys.push("customization"); }
    if profile.get(key).is_some_and(Value::is_object) { keys.push(key); }
    if keys.is_empty() { return false; }
    let mut expected = before.clone();
    for key in keys {
        let Some(elements) = expected.profiles[index].get_mut(key).and_then(|v| v.get_mut("elements")).and_then(Value::as_array_mut) else { return false; };
        let Some(owner) = elements.iter_mut().find(|e| e.get("id").and_then(Value::as_str).is_some_and(|id| id.eq_ignore_ascii_case(element_id))) else { return false; };
        if changes.is_output_only() {
            let Some(actual) = after.profiles[after_index].get(key).and_then(|v| v.get("elements")).and_then(Value::as_array)
                .and_then(|elements| elements.iter().find(|e| e.get("id").and_then(Value::as_str).is_some_and(|id| id.eq_ignore_ascii_case(element_id)))) else { return false; };
            if !element_output_change_is_exact(Some(owner), Some(actual), changes.output.as_ref()) { return false; }
            if changes.output.as_ref().is_some_and(|output| output.part != crate::draft_operation::ElementInputPart::Primary)
                && !json_semantically_equal(owner.get("output").unwrap_or(&Value::Null), actual.get("output").unwrap_or(&Value::Null)) { return false; }
            let Some(actual) = actual.as_object() else { return false; };
            let Some(owner) = owner.as_object_mut() else { return false; };
            for field in ["output", "partOutputs"] {
                if let Some(value) = actual.get(field) { owner.insert(field.to_owned(), value.clone()); }
                else { owner.remove(field); }
            }
            continue;
        }
        let Some(owner) = owner.as_object_mut() else { return false; };
        if changes.clear_presentation { owner.remove("presentation"); }
        else if let Some(presentation) = &changes.presentation {
            let Ok(value) = serde_json::to_value(presentation) else { return false; };
            owner.insert("presentation".to_owned(), value);
        } else { return false; }
    }
    let Some(updated) = after.profiles[after_index].get("updatedAt").filter(|v| v.as_i64().is_some()) else { return false; };
    expected.profiles[index]["updatedAt"] = updated.clone();
    expected.profiles.len() == after.profiles.len()
        && expected.profiles.iter().zip(&after.profiles).all(|(a, b)| json_semantically_equal(a, b))
        && expected.active_profile_id == after.active_profile_id && expected.default_profile_id == after.default_profile_id
        && expected.key_bindings == after.key_bindings && expected.output_bindings == after.output_bindings
        && expected.profile_key_bindings == after.profile_key_bindings
        && expected.profile_output_bindings == after.profile_output_bindings
}

fn element_presentation_after_is_exact(before: Option<&Value>, after: Option<&Value>,
                                      changes: &crate::draft_operation::ElementChanges) -> bool {
    let expected = if let Some(presentation) = &changes.presentation {
        let Ok(value) = serde_json::to_value(presentation) else { return false; };
        value
    } else if changes.clear_presentation { Value::Null }
    else { before.and_then(|v| v.get("presentation")).cloned().unwrap_or(Value::Null) };
    json_semantically_equal(after.and_then(|v| v.get("presentation")).unwrap_or(&Value::Null), &expected)
}

fn target_changed_keys_allowed(
    before: Option<&Value>,
    after: Option<&Value>,
    changes: &crate::draft_operation::ElementChanges,
    custom: bool,
) -> bool {
    let (Some(before), Some(after)) = (
        before.and_then(Value::as_object),
        after.and_then(Value::as_object),
    ) else {
        return before.is_some() || after.is_none() || changes.is_hidden == Some(true);
    };
    let mut allowed = std::collections::BTreeSet::new();
    if !custom {
        if changes.clear_presentation {
            if after.get("presentation").is_some_and(|v| !v.is_null()) { return false; }
            allowed.insert("presentation");
        } else if let Some(presentation) = &changes.presentation {
            let Ok(expected) = serde_json::to_value(presentation) else { return false; };
            if !json_semantically_equal(after.get("presentation").unwrap_or(&Value::Null), &expected) { return false; }
            allowed.insert("presentation");
        }
    }
    if changes.label.is_some() || changes.clear_label {
        allowed.insert("label");
    }
    if changes.visual_role.is_some() || changes.clear_visual_role {
        allowed.insert("visualRole");
    }
    if changes.kind.is_some() {
        allowed.insert(if custom { "controlKind" } else { "kind" });
    }
    if changes.joystick_mapping.is_some() {
        allowed.insert("joystickMapping");
    }
    if changes.joystick_settings.is_some() {
        allowed.insert("joystickOutputSettings");
    }
    if changes.trigger_settings.is_some() {
        allowed.insert("triggerSettings");
    }
    if changes.trackpad_settings.is_some() {
        allowed.insert("trackpadSettings");
    }
    if changes.output.is_some() {
        allowed.insert("output");
        allowed.insert("partOutputs");
    }
    if element_has_layout_changes(changes)
        || changes.kind.is_some()
        || changes.joystick_mapping.is_some()
        || changes.joystick_settings.is_some()
        || changes.trigger_settings.is_some()
        || changes.trackpad_settings.is_some()
    {
        allowed.insert("layout");
    }
    before.keys().chain(after.keys()).all(|key| {
        json_semantically_equal(
            before.get(key).unwrap_or(&Value::Null),
            after.get(key).unwrap_or(&Value::Null),
        ) || allowed.contains(key.as_str())
    }) && layout_changed_keys_allowed(before.get("layout"), after.get("layout"), changes)
}

fn element_has_layout_changes(changes: &crate::draft_operation::ElementChanges) -> bool {
    changes.center_x.is_some()
        || changes.center_y.is_some()
        || changes.width_scale.is_some()
        || changes.height_scale.is_some()
        || changes.rotation_degrees.is_some()
        || changes.shape.is_some()
        || changes.is_hidden.is_some()
        || changes.is_location_locked.is_some()
        || changes.shows_integrated_label.is_some()
        || changes.z_index.is_some()
        || changes.hit_insets.is_some()
        || changes.clear_hit_insets
        || changes.corner_radius.is_some()
        || changes.corner_radii.is_some()
        || changes.shadow_strength.is_some()
        || changes.fill.is_some()
        || changes.clear_fill
        || changes.light_fill.is_some()
        || changes.clear_light_fill
        || changes.dark_fill.is_some()
        || changes.clear_dark_fill
        || changes.fill_opacity.is_some()
        || changes.light_fill_opacity.is_some()
        || changes.dark_fill_opacity.is_some()
        || changes.thumb_fill.is_some()
        || changes.clear_thumb_fill
        || changes.light_thumb_fill.is_some()
        || changes.clear_light_thumb_fill
        || changes.dark_thumb_fill.is_some()
        || changes.clear_dark_thumb_fill
        || changes.thumb_opacity.is_some()
        || changes.light_thumb_opacity.is_some()
        || changes.dark_thumb_opacity.is_some()
        || changes.joystick_visual_style.is_some()
        || changes.style_id.is_some()
        || changes.clear_style
        || changes.appearance.is_some()
        || changes.icon.is_some()
        || changes.clear_icon
        || changes.haptic.is_some()
        || changes.clear_haptic
}

fn layout_changed_keys_allowed(
    before: Option<&Value>,
    after: Option<&Value>,
    changes: &crate::draft_operation::ElementChanges,
) -> bool {
    let empty_before = Map::new();
    let empty_after = Map::new();
    let before = before.and_then(Value::as_object).unwrap_or(&empty_before);
    let after = after.and_then(Value::as_object).unwrap_or(&empty_after);
    let mut allowed = std::collections::BTreeSet::new();
    for (present, key) in [
        (changes.center_x.is_some(), "centerX"),
        (changes.center_y.is_some(), "centerY"),
        (changes.width_scale.is_some(), "widthScale"),
        (changes.height_scale.is_some(), "heightScale"),
        (changes.rotation_degrees.is_some(), "rotationDegrees"),
        (changes.shape.is_some(), "shape"),
        (changes.is_hidden.is_some(), "isHidden"),
        (changes.is_location_locked.is_some(), "isLocationLocked"),
        (
            changes.shows_integrated_label.is_some(),
            "showsIntegratedLabel",
        ),
        (changes.z_index.is_some(), "zIndex"),
        (
            changes.hit_insets.is_some() || changes.clear_hit_insets,
            "hitInsets",
        ),
        (changes.corner_radius.is_some(), "cornerRadius"),
        (changes.corner_radii.is_some(), "cornerRadii"),
        (changes.shadow_strength.is_some(), "shadowStrength"),
        (
            changes.joystick_visual_style.is_some(),
            "joystickVisualStyle",
        ),
        (changes.style_id.is_some() || changes.clear_style, "styleID"),
        (changes.appearance.is_some(), "visualStyle"),
        (changes.icon.is_some() || changes.clear_icon, "icon"),
        (
            changes.haptic.is_some() || changes.clear_haptic,
            "hapticStyle",
        ),
        (
            changes.haptic.is_some() || changes.clear_haptic,
            "hapticFeedback",
        ),
    ] {
        if present {
            allowed.insert(key);
        }
    }
    if changes.kind.is_some()
        || changes.joystick_mapping.is_some()
        || changes.joystick_settings.is_some()
        || changes.trigger_settings.is_some()
        || changes.trackpad_settings.is_some()
    {
        allowed.extend(["shape", "shadowStrength", "showsIntegratedLabel"]);
    }
    if changes.fill.is_some()
        || changes.clear_fill
        || changes.light_fill.is_some()
        || changes.clear_light_fill
        || changes.dark_fill.is_some()
        || changes.clear_dark_fill
        || changes.fill_opacity.is_some()
        || changes.light_fill_opacity.is_some()
        || changes.dark_fill_opacity.is_some()
    {
        allowed.extend([
            "fillColor",
            "lightFillColor",
            "darkFillColor",
            "fillStyle",
            "lightFillStyle",
            "darkFillStyle",
        ]);
    }
    if changes.thumb_fill.is_some()
        || changes.clear_thumb_fill
        || changes.light_thumb_fill.is_some()
        || changes.clear_light_thumb_fill
        || changes.dark_thumb_fill.is_some()
        || changes.clear_dark_thumb_fill
        || changes.thumb_opacity.is_some()
        || changes.light_thumb_opacity.is_some()
        || changes.dark_thumb_opacity.is_some()
    {
        allowed.extend([
            "joystickKnobColor",
            "lightJoystickKnobColor",
            "darkJoystickKnobColor",
        ]);
    }
    before.keys().chain(after.keys()).all(|key| {
        json_semantically_equal(
            before.get(key).unwrap_or(&Value::Null),
            after.get(key).unwrap_or(&Value::Null),
        ) || allowed.contains(key.as_str())
    })
}

fn valid_add_layer_delta(
    before: &Map<String, Value>,
    after: &Map<String, Value>,
    id: &str,
) -> bool {
    let before_groups = before
        .get("designMetadata")
        .and_then(|value| value.get("groups"));
    let after_groups = after
        .get("designMetadata")
        .and_then(|value| value.get("groups"));
    if !json_semantically_equal(
        before_groups.unwrap_or(&Value::Null),
        after_groups.unwrap_or(&Value::Null),
    ) {
        return false;
    }
    let Some(order) = normalized_layer_order(after) else {
        return false;
    };
    order
        .iter()
        .filter(|identity| {
            layer_identity_key(identity)
                .is_some_and(|key| key == format!("custom:{}", id.to_ascii_lowercase()))
        })
        .count()
        == 1
}

fn element_output_change_is_exact(
    before: Option<&Value>,
    after: Option<&Value>,
    changes: Option<&crate::draft_operation::ElementOutputChanges>,
) -> bool {
    use crate::draft_operation::{GamepadOutputEdit, KeyboardOutputEdit};

    let Some(changes) = changes else {
        return true;
    };
    let Some(after) = after.and_then(Value::as_object) else {
        return false;
    };
    let before = before.and_then(Value::as_object);
    let part = serde_json::to_value(changes.part)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned));
    let Some(part) = part else {
        return false;
    };
    let before_parts = before
        .and_then(|element| element.get("partOutputs"))
        .and_then(element_part_outputs)
        .unwrap_or_default();
    let after_parts = after
        .get("partOutputs")
        .and_then(element_part_outputs)
        .unwrap_or_default();
    let before_binding = if part == "primary" {
        before.and_then(|element| element.get("output")).cloned()
    } else {
        before_parts.get(&part).cloned()
    };
    let after_binding = if part == "primary" {
        after.get("output").cloned()
    } else {
        after_parts.get(&part).cloned()
    };
    let mut expected = before_binding
        .as_ref()
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    match &changes.keyboard_edit {
        KeyboardOutputEdit::Keep => {}
        KeyboardOutputEdit::Clear => {
            expected.remove("keyboard");
        }
        KeyboardOutputEdit::Set { sequence } => {
            let strokes = sequence
                .iter()
                .map(crate::draft_operation::resolve_stroke)
                .collect::<Result<Vec<_>, _>>();
            let Ok(strokes) = strokes else {
                return false;
            };
            let Some(first) = strokes.first() else {
                return false;
            };
            let mut keyboard = serde_json::json!({
                "keyCode": first.key_code,
                "modifiersRawValue": first.modifiers,
            });
            if strokes.len() > 1 {
                keyboard["sequence"] = Value::Array(
                    strokes
                        .iter()
                        .map(|stroke| {
                            serde_json::json!({
                                "keyCode": stroke.key_code,
                                "modifiersRawValue": stroke.modifiers,
                            })
                        })
                        .collect(),
                );
            }
            expected.insert("keyboard".to_owned(), keyboard);
        }
    }
    match changes.gamepad_edit {
        GamepadOutputEdit::Keep => {}
        GamepadOutputEdit::Clear => {
            expected.remove("gamepadButtons");
        }
        GamepadOutputEdit::Set { button } => {
            let Ok(button) = serde_json::to_value(button) else {
                return false;
            };
            expected.insert("gamepadButtons".to_owned(), Value::Array(vec![button]));
        }
    }
    let has_keyboard = expected.contains_key("keyboard");
    let has_gamepad = expected
        .get("gamepadButtons")
        .and_then(Value::as_array)
        .is_some_and(|buttons| !buttons.is_empty());
    if has_keyboard {
        expected
            .entry("gamepadButtons".to_owned())
            .or_insert_with(|| Value::Array(Vec::new()));
    } else if !has_gamepad {
        expected.remove("gamepadButtons");
    }
    let expected = (!expected.is_empty()).then_some(Value::Object(expected));
    if !json_semantically_equal(
        expected.as_ref().unwrap_or(&Value::Null),
        after_binding.as_ref().unwrap_or(&Value::Null),
    ) {
        return false;
    }
    if part == "primary" {
        json_semantically_equal(
            &serde_json::to_value(before_parts).unwrap_or(Value::Null),
            &serde_json::to_value(after_parts).unwrap_or(Value::Null),
        )
    } else {
        let mut expected_parts = before_parts;
        if let Some(expected) = expected {
            expected_parts.insert(part, expected);
        } else {
            expected_parts.remove(&part);
        }
        json_semantically_equal(
            &serde_json::to_value(expected_parts).unwrap_or(Value::Null),
            &serde_json::to_value(after_parts).unwrap_or(Value::Null),
        )
    }
}

fn element_part_outputs(value: &Value) -> Option<std::collections::BTreeMap<String, Value>> {
    if let Some(object) = value.as_object() {
        return Some(object.clone().into_iter().collect());
    }
    let values = value.as_array()?;
    if values.len() % 2 != 0 {
        return None;
    }
    let mut result = std::collections::BTreeMap::new();
    for pair in values.chunks_exact(2) {
        let key = pair[0].as_str()?.to_owned();
        if result.insert(key, pair[1].clone()).is_some() {
            return None;
        }
    }
    Some(result)
}

fn target_has_no_forbidden_element_injection(
    before: Option<&Value>,
    after: Option<&Value>,
) -> bool {
    let strip_outputs = |value: Option<&Value>| {
        value.cloned().map(|mut value| {
            if let Some(object) = value.as_object_mut() {
                object.remove("output");
                object.remove("partOutputs");
            }
            value
        })
    };
    let before = strip_outputs(before);
    let after = strip_outputs(after);
    target_has_no_forbidden_injection(before.as_ref(), after.as_ref())
}

fn target_has_no_forbidden_injection(before: Option<&Value>, after: Option<&Value>) -> bool {
    fn walk(before: Option<&Value>, after: &Value) -> bool {
        match after {
            Value::Object(object) => object.iter().all(|(key, value)| {
                let forbidden = matches!(
                    key.as_str(),
                    "data"
                        | "fileName"
                        | "assetID"
                        | "image"
                        | "artworkLayers"
                        | "launchTarget"
                        | "path"
                        | "argv"
                        | "credentials"
                        | "keyCode"
                        | "modifiersRawValue"
                );
                let before_value = before.and_then(|value| value.get(key));
                (!forbidden || before_value == Some(value)) && walk(before_value, value)
            }),
            Value::Array(values) => values
                .iter()
                .enumerate()
                .all(|(index, value)| walk(before.and_then(|before| before.get(index)), value)),
            _ => true,
        }
    }
    after.is_none_or(|after| walk(before, after))
}

fn constrained_control_bar_item_set_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    use crate::draft_operation::ConfigurationVariant;

    let ConfigurationOperation::ControlBarItemSet {
        profile_id,
        variant,
        item,
        changes,
    } = operation
    else {
        return false;
    };
    if !customization_operation_delta(before, after, profile_id, *variant) {
        return false;
    }
    let (Some(before_index), Some(after_index)) = (
        profile_position(before, profile_id),
        profile_position(after, profile_id),
    ) else {
        return false;
    };
    let (Some(before_profile), Some(after_profile)) = (
        before.profiles[before_index].as_object(),
        after.profiles[after_index].as_object(),
    ) else {
        return false;
    };
    let source_key = match variant {
        ConfigurationVariant::Primary => "customization",
        ConfigurationVariant::Landscape => "landscapeCustomization",
        ConfigurationVariant::Portrait => "portraitCustomization",
    };
    let Some(mut expected) = before_profile
        .get(source_key)
        .or_else(|| before_profile.get("customization"))
        .and_then(Value::as_object)
        .cloned()
    else {
        return false;
    };
    if *variant != ConfigurationVariant::Primary {
        if let Some(color_scheme) = before_profile
            .get("customization")
            .and_then(|value| value.get("colorSchemePreference"))
        {
            expected.insert("colorSchemePreference".to_owned(), color_scheme.clone());
        }
        correct_customization_frame_orientation(&mut expected, *variant);
    }
    let Some(item_text) = serde_json::to_value(item)
        .ok()
        .and_then(|value| value.as_str().map(str::to_owned))
    else {
        return false;
    };
    let items = effective_control_bar_items(&expected);
    if !items.iter().any(|candidate| candidate == &item_text) {
        return false;
    }
    if changes
        .style_id
        .as_ref()
        .is_some_and(|style_id| !style_exists_in_customization(&expected, style_id))
    {
        return false;
    }
    let mut appearance = effective_control_bar_appearance(&expected, &item_text);
    if !apply_expected_control_bar_changes(&mut appearance, changes) {
        return false;
    }
    normalize_control_bar_appearance(&mut appearance, &item_text);
    if !replace_expected_control_bar_appearance(&mut expected, &items, &item_text, appearance) {
        return false;
    }
    after_profile.get("customization").is_some_and(|actual| {
        control_bar_item_result_equal(actual, &Value::Object(expected), &item_text, false, None)
    })
}

fn control_bar_item_result_equal(
    actual: &Value,
    expected: &Value,
    target: &str,
    inside_target: bool,
    field: Option<&str>,
) -> bool {
    match (actual, expected) {
        (Value::Number(actual), Value::Number(expected)) => {
            let (Some(actual), Some(expected)) = (actual.as_f64(), expected.as_f64()) else {
                return false;
            };
            actual == expected
                || inside_target
                    && matches!(field, Some("red" | "green" | "blue"))
                    && f64_ulp_distance(actual, expected) <= 1
        }
        (Value::Array(actual), Value::Array(expected)) => {
            actual.len() == expected.len()
                && actual.iter().zip(expected).all(|(actual, expected)| {
                    control_bar_item_result_equal(actual, expected, target, inside_target, field)
                })
        }
        (Value::Object(actual), Value::Object(expected)) => {
            if actual.len() != expected.len() {
                return false;
            }
            let inside_target =
                inside_target || expected.get("item").and_then(Value::as_str) == Some(target);
            expected.iter().all(|(key, expected)| {
                actual.get(key).is_some_and(|actual| {
                    control_bar_item_result_equal(
                        actual,
                        expected,
                        target,
                        inside_target,
                        Some(key),
                    )
                })
            })
        }
        _ => actual == expected,
    }
}

fn f64_ulp_distance(left: f64, right: f64) -> u64 {
    if !left.is_finite()
        || !right.is_finite()
        || left.is_sign_negative() != right.is_sign_negative()
    {
        return u64::MAX;
    }
    left.to_bits().abs_diff(right.to_bits())
}

fn effective_control_bar_items(customization: &Map<String, Value>) -> Vec<String> {
    const DEFAULTS: &[&str] = &[
        "status",
        "profile_menu",
        "launch_target",
        "spacer",
        "edit_layout",
        "settings",
        "home",
        "connection",
    ];
    let source: Vec<String> = customization
        .get("controlBarItems")
        .and_then(Value::as_array)
        .map_or_else(
            || DEFAULTS.iter().map(|item| (*item).to_owned()).collect(),
            |values| {
                values
                    .iter()
                    .filter_map(Value::as_str)
                    .filter(|item| DEFAULTS.contains(item))
                    .map(str::to_owned)
                    .collect()
            },
        );
    let mut seen = std::collections::BTreeSet::new();
    source
        .into_iter()
        .filter(|item| seen.insert(item.clone()))
        .collect()
}

fn control_bar_customization<'a>(
    customization: &'a Map<String, Value>,
    item: &str,
) -> Option<&'a Value> {
    customization
        .get("controlBarItemCustomizations")
        .and_then(Value::as_array)?
        .iter()
        .rev()
        .find(|entry| entry.get("item").and_then(Value::as_str) == Some(item))
}

fn effective_control_bar_appearance(
    customization: &Map<String, Value>,
    item: &str,
) -> Map<String, Value> {
    let source = control_bar_customization(customization, item)
        .and_then(|entry| entry.get("appearance"))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    normalized_known_layout(source)
}

fn apply_expected_control_bar_changes(
    layout: &mut Map<String, Value>,
    changes: &crate::draft_operation::ControlBarItemChanges,
) -> bool {
    if let Some(value) = changes.width_scale {
        layout.insert("widthScale".to_owned(), Value::from(value));
    }
    if let Some(value) = changes.height_scale {
        layout.insert("heightScale".to_owned(), Value::from(value));
    }
    if let Some(value) = changes.is_hidden {
        layout.insert("isHidden".to_owned(), Value::Bool(value));
    }
    if let Some(value) = changes.shape {
        set_serialized(layout, "shape", value);
    }
    if let Some(value) = changes.accent_style {
        set_serialized(layout, "accentStyle", value);
        clear_all_control_bar_fills(layout);
    }
    if let Some(value) = changes.corner_radius {
        layout.insert(
            "shape".to_owned(),
            Value::String("rounded_rectangle".to_owned()),
        );
        layout.insert("cornerRadius".to_owned(), Value::from(value));
        layout.remove("cornerRadii");
    } else if let Some(value) = changes.corner_radii {
        layout.insert(
            "shape".to_owned(),
            Value::String("rounded_rectangle".to_owned()),
        );
        let Ok(value) = serde_json::to_value(value) else {
            return false;
        };
        layout.insert("cornerRadii".to_owned(), value);
        layout.remove("cornerRadius");
    }
    if let Some(value) = changes.shadow_strength {
        layout.insert("shadowStrength".to_owned(), Value::from(value));
    }
    if changes.clear_fill {
        clear_all_control_bar_fills(layout);
    } else if let Some(fill) = &changes.fill {
        set_global_control_bar_fill(layout, fill);
    }
    if changes.clear_light_fill {
        clear_scheme_control_bar_fill(layout, false);
    } else if let Some(fill) = &changes.light_fill {
        set_scheme_control_bar_fill(layout, fill, false);
    }
    if changes.clear_dark_fill {
        clear_scheme_control_bar_fill(layout, true);
    } else if let Some(fill) = &changes.dark_fill {
        set_scheme_control_bar_fill(layout, fill, true);
    }
    if let Some(opacity) = changes.fill_opacity {
        set_global_control_bar_fill_opacity(layout, opacity);
    }
    if let Some(opacity) = changes.light_fill_opacity {
        set_scheme_control_bar_fill_opacity(layout, opacity, false);
    }
    if let Some(opacity) = changes.dark_fill_opacity {
        set_scheme_control_bar_fill_opacity(layout, opacity, true);
    }
    if changes.clear_style {
        layout.remove("styleID");
    } else if let Some(style_id) = &changes.style_id {
        layout.insert("styleID".to_owned(), Value::String(style_id.clone()));
    }
    if let Some(appearance) = &changes.appearance {
        let existing = layout.get("visualStyle");
        let Some(visual) = expected_inline_visual_style(existing, appearance) else {
            return false;
        };
        layout.insert("visualStyle".to_owned(), visual);
    }
    if changes.clear_icon {
        layout.remove("icon");
    } else if let Some(icon) = &changes.icon {
        let source = match icon.source {
            crate::draft_operation::StyleIconSource::SfSymbol => "sf_symbol",
            crate::draft_operation::StyleIconSource::Text => "text",
        };
        layout.insert(
            "icon".to_owned(),
            serde_json::json!({
                "source": source,
                "value": icon.value.trim(),
                "placement": "center",
                "scale": 1,
                "renderingMode": "template"
            }),
        );
    }
    if changes.clear_haptic {
        layout.remove("hapticStyle");
        layout.remove("hapticFeedback");
    } else if let Some(haptic) = &changes.haptic {
        let Some(feedback) = overlay_expected_haptic(layout, haptic) else {
            return false;
        };
        if haptic_feedback_is_default(&feedback) {
            layout.remove("hapticStyle");
            layout.remove("hapticFeedback");
        } else {
            let Some(style) = feedback.get("style").cloned() else {
                return false;
            };
            layout.insert("hapticStyle".to_owned(), style);
            layout.insert("hapticFeedback".to_owned(), feedback);
        }
    }
    true
}

fn clear_all_control_bar_fills(layout: &mut Map<String, Value>) {
    for key in [
        "fillColor",
        "lightFillColor",
        "darkFillColor",
        "fillStyle",
        "lightFillStyle",
        "darkFillStyle",
    ] {
        layout.remove(key);
    }
}

fn normalized_element_fill_value(fill: &crate::draft_operation::ElementFill) -> Value {
    use crate::draft_operation::ElementFill;
    match fill {
        ElementFill::Solid { color } => solid_fill(*color),
        ElementFill::Gradient {
            gradient_type,
            angle_degrees,
            stops,
        } => {
            let mut angle = angle_degrees % 360.0;
            if angle < 0.0 {
                angle += 360.0;
            }
            let mut stops = stops.clone();
            stops.sort_by(|left, right| left.offset.total_cmp(&right.offset));
            serde_json::json!({
                "kind": "gradient",
                "gradient": {
                    "type": gradient_type,
                    "angleDegrees": angle,
                    "stops": stops.into_iter().map(|stop| serde_json::json!({
                        "offset": stop.offset,
                        "color": normalized_color_value(stop.color)
                    })).collect::<Vec<_>>()
                }
            })
        }
        ElementFill::Tile {
            pattern,
            foreground_color,
            background_color,
            scale,
            spacing_x,
            spacing_y,
            alignment,
            opacity,
        } => serde_json::json!({
            "kind": "tile",
            "tile": {
                "pattern": pattern,
                "foregroundColor": normalized_color_value(*foreground_color),
                "backgroundColor": normalized_color_value(*background_color),
                "scale": scale,
                "spacingX": spacing_x,
                "spacingY": spacing_y,
                "alignment": alignment,
                "opacity": opacity
            }
        }),
    }
}

fn set_global_control_bar_fill(
    layout: &mut Map<String, Value>,
    fill: &crate::draft_operation::ElementFill,
) {
    clear_all_control_bar_fills(layout);
    match fill {
        crate::draft_operation::ElementFill::Solid { color } => {
            layout.insert("fillColor".to_owned(), normalized_color_value(*color));
        }
        _ => {
            layout.insert("fillStyle".to_owned(), normalized_element_fill_value(fill));
        }
    }
}

fn prepare_scheme_control_bar_fills(layout: &mut Map<String, Value>) {
    if let Some(fill) = layout.get("fillColor").cloned() {
        layout
            .entry("lightFillColor".to_owned())
            .or_insert(fill.clone());
        layout.entry("darkFillColor".to_owned()).or_insert(fill);
    }
    if let Some(fill) = layout.get("fillStyle").cloned() {
        layout
            .entry("lightFillStyle".to_owned())
            .or_insert(fill.clone());
        layout.entry("darkFillStyle".to_owned()).or_insert(fill);
    }
    layout.remove("fillColor");
    layout.remove("fillStyle");
}

fn set_scheme_control_bar_fill(
    layout: &mut Map<String, Value>,
    fill: &crate::draft_operation::ElementFill,
    dark: bool,
) {
    prepare_scheme_control_bar_fills(layout);
    let color_key = if dark {
        "darkFillColor"
    } else {
        "lightFillColor"
    };
    let style_key = if dark {
        "darkFillStyle"
    } else {
        "lightFillStyle"
    };
    match fill {
        crate::draft_operation::ElementFill::Solid { color } => {
            layout.insert(color_key.to_owned(), normalized_color_value(*color));
            layout.remove(style_key);
        }
        _ => {
            layout.remove(color_key);
            layout.insert(style_key.to_owned(), normalized_element_fill_value(fill));
        }
    }
}

fn clear_scheme_control_bar_fill(layout: &mut Map<String, Value>, dark: bool) {
    prepare_scheme_control_bar_fills(layout);
    if dark {
        layout.remove("darkFillColor");
        layout.remove("darkFillStyle");
    } else {
        layout.remove("lightFillColor");
        layout.remove("lightFillStyle");
    }
}

fn fill_value_with_opacity(mut fill: Value, opacity: f64) -> Value {
    match fill.get("kind").and_then(Value::as_str) {
        Some("solid") => {
            if let Some(color) = fill.get_mut("color").and_then(Value::as_object_mut) {
                color.insert("alpha".to_owned(), Value::from(opacity));
            }
        }
        Some("gradient") => {
            if let Some(stops) = fill
                .get_mut("gradient")
                .and_then(|gradient| gradient.get_mut("stops"))
                .and_then(Value::as_array_mut)
            {
                for stop in stops {
                    if let Some(color) = stop.get_mut("color").and_then(Value::as_object_mut) {
                        color.insert("alpha".to_owned(), Value::from(opacity));
                    }
                }
            }
        }
        Some("tile") => {
            if let Some(tile) = fill.get_mut("tile").and_then(Value::as_object_mut) {
                tile.insert("opacity".to_owned(), Value::from(opacity));
            }
        }
        Some("image") => {
            if let Some(image) = fill.get_mut("image").and_then(Value::as_object_mut) {
                image.insert("opacity".to_owned(), Value::from(opacity));
            }
        }
        _ => {}
    }
    fill
}

fn set_global_control_bar_fill_opacity(layout: &mut Map<String, Value>, opacity: f64) {
    if let Some(fill) = layout.get("fillStyle").cloned() {
        layout.insert(
            "fillStyle".to_owned(),
            fill_value_with_opacity(fill, opacity),
        );
    } else {
        let mut color = layout
            .get("fillColor")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_else(|| {
                normalized_color_value(crate::draft_operation::ConfigurationRgbaColor {
                    red: 0.07,
                    green: 0.07,
                    blue: 0.07,
                    alpha: 1.0,
                })
                .as_object()
                .cloned()
                .unwrap_or_default()
            });
        color.insert("alpha".to_owned(), Value::from(opacity));
        layout.insert("fillColor".to_owned(), Value::Object(color));
    }
}

fn scheme_control_bar_fill(layout: &Map<String, Value>, dark: bool) -> Value {
    let style_key = if dark {
        "darkFillStyle"
    } else {
        "lightFillStyle"
    };
    let color_key = if dark {
        "darkFillColor"
    } else {
        "lightFillColor"
    };
    if let Some(fill) = layout.get(style_key).or_else(|| layout.get("fillStyle")) {
        return fill.clone();
    }
    let color = layout
        .get(color_key)
        .or_else(|| layout.get("fillColor"))
        .cloned()
        .unwrap_or_else(|| {
            normalized_color_value(crate::draft_operation::ConfigurationRgbaColor {
                red: 0.07,
                green: 0.07,
                blue: 0.07,
                alpha: 1.0,
            })
        });
    serde_json::json!({"kind": "solid", "color": color})
}

fn set_scheme_control_bar_fill_opacity(layout: &mut Map<String, Value>, opacity: f64, dark: bool) {
    let fill = fill_value_with_opacity(scheme_control_bar_fill(layout, dark), opacity);
    prepare_scheme_control_bar_fills(layout);
    let color_key = if dark {
        "darkFillColor"
    } else {
        "lightFillColor"
    };
    let style_key = if dark {
        "darkFillStyle"
    } else {
        "lightFillStyle"
    };
    if fill.get("kind").and_then(Value::as_str) == Some("solid") {
        if let Some(color) = fill.get("color") {
            layout.insert(color_key.to_owned(), color.clone());
            layout.remove(style_key);
        }
    } else {
        layout.remove(color_key);
        layout.insert(style_key.to_owned(), fill);
    }
}

fn expected_inline_visual_style(
    existing: Option<&Value>,
    appearance: &crate::draft_operation::StyleAppearance,
) -> Option<Value> {
    let typed = expected_style_token("element-inline", "Element Inline", appearance)?
        .get("visualStyle")?
        .clone();
    if appearance.material_preset.is_some() || existing.is_none() {
        return Some(typed);
    }
    let mut result = existing?.clone();
    let normal = result.get_mut("normal")?.as_object_mut()?;
    let overlay = typed.get("normal")?.as_object()?;
    for (present, key) in [
        (appearance.fill_color.is_some(), "fillStyle"),
        (appearance.foreground_color.is_some(), "foregroundColor"),
        (appearance.stroke_color.is_some(), "strokeColor"),
        (appearance.stroke_width.is_some(), "strokeWidth"),
        (appearance.glow_color.is_some(), "glowColor"),
        (appearance.glow_radius.is_some(), "glowRadius"),
        (appearance.inner_shadow_color.is_some(), "innerShadowColor"),
        (
            appearance.inner_shadow_radius.is_some(),
            "innerShadowRadius",
        ),
        (appearance.inner_shadow_x.is_some(), "innerShadowX"),
        (appearance.inner_shadow_y.is_some(), "innerShadowY"),
        (appearance.highlight_color.is_some(), "highlightColor"),
        (appearance.highlight_radius.is_some(), "highlightRadius"),
        (appearance.highlight_x.is_some(), "highlightX"),
        (appearance.highlight_y.is_some(), "highlightY"),
        (appearance.highlight_opacity.is_some(), "highlightOpacity"),
        (
            appearance.bevel_highlight_color.is_some(),
            "bevelHighlightColor",
        ),
        (appearance.bevel_shadow_color.is_some(), "bevelShadowColor"),
        (appearance.bevel_width.is_some(), "bevelWidth"),
        (appearance.opacity.is_some(), "opacity"),
        (appearance.shadows.is_some(), "shadows"),
    ] {
        if present {
            if let Some(value) = overlay.get(key) {
                normal.insert(key.to_owned(), value.clone());
            }
        }
    }
    if appearance.pressed_fill_color.is_some() || appearance.pressed_scale.is_some() {
        let pressed = result
            .as_object_mut()?
            .entry("pressed".to_owned())
            .or_insert_with(|| serde_json::json!({}))
            .as_object_mut()?;
        let overlay = typed.get("pressed")?.as_object()?;
        if appearance.pressed_fill_color.is_some() {
            pressed.insert("fillStyle".to_owned(), overlay.get("fillStyle")?.clone());
        }
        if appearance.pressed_scale.is_some() {
            pressed.insert("scale".to_owned(), overlay.get("scale")?.clone());
        }
    }
    if appearance.icon.is_some() {
        result
            .as_object_mut()?
            .insert("icon".to_owned(), typed.get("icon")?.clone());
    }
    if appearance.haptic.is_some() {
        let object = result.as_object_mut()?;
        object.insert("hapticStyle".to_owned(), typed.get("hapticStyle")?.clone());
        object.insert(
            "hapticFeedback".to_owned(),
            typed.get("hapticFeedback")?.clone(),
        );
    }
    Some(result)
}

fn overlay_expected_haptic(
    layout: &Map<String, Value>,
    input: &crate::draft_operation::StyleHaptic,
) -> Option<Value> {
    let style = input
        .style
        .or_else(|| {
            layout
                .get("hapticFeedback")
                .and_then(|feedback| feedback.get("style"))
                .or_else(|| layout.get("hapticStyle"))
                .and_then(Value::as_str)
                .and_then(|value| serde_json::from_value(Value::String(value.to_owned())).ok())
        })
        .unwrap_or(crate::draft_operation::StyleHapticKind::Light);
    let defaults = expected_haptic_feedback(&crate::draft_operation::StyleHaptic {
        style: Some(style),
        pattern: None,
        intensity: None,
        sharpness: None,
        duration: None,
    })?;
    let existing = layout.get("hapticFeedback");
    let mut result = defaults.as_object()?.clone();
    if let Some(existing) = existing.and_then(Value::as_object) {
        for key in ["style", "pattern", "intensity", "sharpness", "duration"] {
            if let Some(value) = existing.get(key) {
                result.insert(key.to_owned(), value.clone());
            }
        }
    }
    if let Some(style) = input.style {
        let value = serde_json::to_value(style).ok()?;
        result.insert("style".to_owned(), value);
    }
    if let Some(pattern) = input.pattern {
        let value = serde_json::to_value(pattern).ok()?;
        result.insert("pattern".to_owned(), value);
    }
    for (key, value) in [
        ("intensity", input.intensity),
        ("sharpness", input.sharpness),
        ("duration", input.duration),
    ] {
        if let Some(value) = value {
            result.insert(key.to_owned(), Value::from(value));
        }
    }
    if result.get("style").and_then(Value::as_str) == Some("none") {
        result.insert("pattern".to_owned(), Value::String("single".to_owned()));
        result.insert("intensity".to_owned(), Value::from(0.0));
        result.insert("sharpness".to_owned(), Value::from(0.0));
    }
    Some(Value::Object(result))
}

fn haptic_feedback_is_default(value: &Value) -> bool {
    let Some(default) = expected_haptic_feedback(&crate::draft_operation::StyleHaptic {
        style: None,
        pattern: None,
        intensity: None,
        sharpness: None,
        duration: None,
    }) else {
        return false;
    };
    json_semantically_equal(value, &default)
}

fn normalize_control_bar_appearance(layout: &mut Map<String, Value>, item: &str) {
    *layout = normalized_known_layout(layout.clone());
    layout.remove("centerX");
    layout.remove("centerY");
    layout.insert("rotationDegrees".to_owned(), Value::from(0.0));
    layout.insert("zIndex".to_owned(), Value::from(0));
    layout.insert("isLocationLocked".to_owned(), Value::Bool(false));
    for key in [
        "joystickKnobColor",
        "lightJoystickKnobColor",
        "darkJoystickKnobColor",
        "joystickVisualStyle",
    ] {
        layout.remove(key);
    }
    let default_radius = if layout.get("shape").and_then(Value::as_str) == Some("rectangle") {
        0.0
    } else {
        6.0
    };
    if let Some(radii) = layout.get("cornerRadii").and_then(Value::as_object) {
        let uniform_default = [
            "topLeading",
            "topTrailing",
            "bottomTrailing",
            "bottomLeading",
        ]
        .iter()
        .all(|key| radii.get(*key).and_then(Value::as_f64) == Some(default_radius));
        let dynamic = matches!(
            layout.get("shape").and_then(Value::as_str),
            Some("capsule" | "circle" | "ellipse")
        );
        if uniform_default && !dynamic {
            layout.remove("cornerRadii");
        }
        layout.remove("cornerRadius");
    } else if layout
        .get("cornerRadius")
        .and_then(Value::as_f64)
        .is_some_and(|radius| {
            (radius - default_radius).abs() < 0.001
                && !matches!(
                    layout.get("shape").and_then(Value::as_str),
                    Some("capsule" | "circle" | "ellipse")
                )
        })
    {
        layout.remove("cornerRadius");
    }
    if item == "spacer" {
        let width = layout
            .get("widthScale")
            .and_then(Value::as_f64)
            .unwrap_or(1.0);
        let hidden = layout
            .get("isHidden")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        *layout = default_button_layout();
        layout.insert("widthScale".to_owned(), Value::from(width));
        layout.insert("isHidden".to_owned(), Value::Bool(hidden));
    }
}

fn replace_expected_control_bar_appearance(
    customization: &mut Map<String, Value>,
    items: &[String],
    target: &str,
    target_appearance: Map<String, Value>,
) -> bool {
    let raw_values = customization
        .get("controlBarItemCustomizations")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut raw_by_item = std::collections::BTreeMap::new();
    for value in raw_values {
        let Some(item) = value.get("item").and_then(Value::as_str) else {
            return false;
        };
        raw_by_item.insert(item.to_owned(), value);
    }
    let mut result = Vec::new();
    for item in items {
        if item == target {
            if button_layout_is_default(&target_appearance) {
                continue;
            }
            let after = serde_json::json!({"item": item, "appearance": target_appearance});
            if let Some(raw) = raw_by_item.get(item) {
                let before_appearance = effective_control_bar_appearance(customization, item);
                let before = serde_json::json!({"item": item, "appearance": before_appearance});
                result.push(apply_expected_canonical_changes(raw, &before, &after));
            } else {
                result.push(after);
            }
        } else if let Some(raw) = raw_by_item.get(item) {
            result.push(raw.clone());
        }
    }
    if result.is_empty() {
        customization.remove("controlBarItemCustomizations");
    } else {
        customization.insert(
            "controlBarItemCustomizations".to_owned(),
            Value::Array(result),
        );
    }
    true
}

// Appearance anchors used for starter-only metadata, never an input pool.
const ORIENTATION_BUILTINS: [&str; 10] = [
    "00000000-0000-0000-0000-000000000101", "00000000-0000-0000-0000-000000000102",
    "00000000-0000-0000-0000-000000000103", "00000000-0000-0000-0000-000000000104",
    "00000000-0000-0000-0000-000000000105", "00000000-0000-0000-0000-000000000106",
    "00000000-0000-0000-0000-000000000107", "00000000-0000-0000-0000-000000000108",
    "00000000-0000-0000-0000-000000000109", "00000000-0000-0000-0000-00000000010A",
];

fn constrained_orientation_copy_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    let ConfigurationOperation::OrientationCopy {
        profile_id,
        source,
        destination,
        automatically_arrange,
    } = operation
    else {
        return false;
    };
    if source == destination {
        return false;
    }
    let (Some(before_index), Some(after_index)) = (
        profile_position(before, profile_id),
        profile_position(after, profile_id),
    ) else {
        return false;
    };
    let (Some(before_profile), Some(after_profile)) = (
        before.profiles[before_index].as_object(),
        after.profiles[after_index].as_object(),
    ) else {
        return false;
    };
    let source_key = orientation_variant_key(*source);
    let destination_key = orientation_variant_key(*destination);
    let Some(primary_before) = before_profile
        .get("customization")
        .and_then(Value::as_object)
    else {
        return false;
    };
    let explicit_source = before_profile.get(source_key).and_then(Value::as_object);
    let fallback_source = explicit_source.is_none();
    if fallback_source && customization_orientation_variant(primary_before) != Some(*source) {
        return false;
    }
    let mut effective_source = explicit_source.unwrap_or(primary_before).clone();
    if explicit_source.is_some() {
        if let Some(color_scheme) = primary_before.get("colorSchemePreference") {
            effective_source.insert("colorSchemePreference".to_owned(), color_scheme.clone());
        }
    }

    let mut allowed_keys = vec!["customization", destination_key, "updatedAt"];
    if fallback_source {
        allowed_keys.push(source_key);
    }
    if !profile_local_delta(before, after, profile_id, &allowed_keys) {
        return false;
    }
    let (Some(primary_after), Some(destination_after), Some(source_after)) = (
        after_profile
            .get("customization")
            .and_then(Value::as_object),
        after_profile
            .get(destination_key)
            .and_then(Value::as_object),
        after_profile.get(source_key).and_then(Value::as_object),
    ) else {
        return false;
    };
    if !json_semantically_equal(
        &Value::Object(primary_after.clone()),
        &Value::Object(destination_after.clone()),
    ) {
        return false;
    }
    if fallback_source {
        if !json_semantically_equal(
            &Value::Object(source_after.clone()),
            &Value::Object(effective_source.clone()),
        ) {
            return false;
        }
    } else if !before_profile.get(source_key).is_some_and(|before_source| {
        json_semantically_equal(before_source, &Value::Object(source_after.clone()))
    }) {
        return false;
    }

    let mut corrected_source = effective_source.clone();
    set_orientation_copy_frame(&mut corrected_source, *destination);
    if !automatically_arrange {
        return json_semantically_equal(
            &Value::Object(corrected_source),
            &Value::Object(destination_after.clone()),
        );
    }
    orientation_arranged_customization_is_exact(
        &effective_source,
        destination_after,
        *source,
        *destination,
    )
}

const fn orientation_variant_key(
    orientation: crate::draft_operation::OrientationVariant,
) -> &'static str {
    match orientation {
        crate::draft_operation::OrientationVariant::Landscape => "landscapeCustomization",
        crate::draft_operation::OrientationVariant::Portrait => "portraitCustomization",
    }
}

fn set_orientation_copy_frame(
    customization: &mut Map<String, Value>,
    destination: crate::draft_operation::OrientationVariant,
) {
    use crate::draft_operation::{ConfigurationVariant, OrientationVariant};
    correct_customization_frame_orientation(
        customization,
        match destination {
            OrientationVariant::Landscape => ConfigurationVariant::Landscape,
            OrientationVariant::Portrait => ConfigurationVariant::Portrait,
        },
    );
    if customization
        .get("deviceCanvas")
        .and_then(Value::as_object)
        .and_then(|canvas| canvas.get("frameID"))
        .and_then(Value::as_str)
        .is_none()
    {
        customization.insert(
            "deviceCanvas".to_owned(),
            serde_json::json!({
                "frameID": match destination {
                    OrientationVariant::Landscape => "iphone-17-pro-landscape",
                    OrientationVariant::Portrait => "iphone-17-pro-portrait",
                }
            }),
        );
    }
}

fn customization_orientation_variant(
    customization: &Map<String, Value>,
) -> Option<crate::draft_operation::OrientationVariant> {
    let frame_id = customization
        .get("deviceCanvas")
        .and_then(Value::as_object)
        .and_then(|canvas| canvas.get("frameID"))
        .and_then(Value::as_str)
        .unwrap_or("iphone-17-pro-landscape");
    if frame_id.ends_with("-landscape") {
        Some(crate::draft_operation::OrientationVariant::Landscape)
    } else if frame_id.ends_with("-portrait") {
        Some(crate::draft_operation::OrientationVariant::Portrait)
    } else {
        None
    }
}

fn orientation_arranged_customization_is_exact(
    source: &Map<String, Value>,
    destination: &Map<String, Value>,
    source_orientation: crate::draft_operation::OrientationVariant,
    destination_orientation: crate::draft_operation::OrientationVariant,
) -> bool {
    use crate::draft_operation::OrientationVariant;

    let destination_canvas = destination.get("deviceCanvas").cloned();
    let mut corrected = source.clone();
    set_orientation_copy_frame(&mut corrected, destination_orientation);
    let source_canvas = corrected.get("deviceCanvas").cloned().unwrap_or_else(|| {
        Value::Object(
            serde_json::json!({
                "frameID": match destination_orientation {
                    OrientationVariant::Landscape => "iphone-17-pro-landscape",
                    OrientationVariant::Portrait => "iphone-17-pro-portrait",
                }
            })
            .as_object()
            .cloned()
            .unwrap_or_default(),
        )
    });
    if !Some(&source_canvas)
        .zip(destination_canvas.as_ref())
        .is_some_and(|(expected, actual)| json_semantically_equal(expected, actual))
    {
        return false;
    }

    let mut source_rest = source.clone();
    let mut destination_rest = destination.clone();
    for key in [
        "deviceCanvas",
        "buttonCustomizations",
        "customButtons",
        "elements",
        "topBarActivationRegion",
        "designMetadata",
    ] {
        source_rest.remove(key);
        destination_rest.remove(key);
    }
    if !json_semantically_equal(
        &Value::Object(source_rest),
        &Value::Object(destination_rest),
    ) || !valid_orientation_button_map(source)
        || !valid_orientation_button_map(destination)
    {
        return false;
    }

    for button in source.get("elements").and_then(Value::as_array).into_iter().flatten()
        .filter_map(|element| element.get("id").and_then(Value::as_str)).filter(|id| is_builtin_layer_button(id)) {
        let (Some(source_layout), Some(destination_layout)) = (
            builtin_layout(source, button),
            builtin_layout(destination, button),
        ) else {
            return false;
        };
        if !layout_without_position_equal(&source_layout, &destination_layout) {
            return false;
        }
    }
    if !orientation_custom_controls_match(source, destination)
        || !orientation_elements_match(source, destination)
        || !orientation_top_bar_matches(source, destination)
    {
        return false;
    }
    if !orientation_guides_match(
        source,
        destination,
        source_orientation,
        destination_orientation,
    ) {
        return false;
    }
    if !orientation_control_positions_match(
        source,
        destination,
        source_orientation,
        destination_orientation,
    ) {
        return false;
    }
    orientation_top_bar_position_matches(source, destination, destination_orientation)
}

fn valid_orientation_button_map(customization: &Map<String, Value>) -> bool {
    let Some(values) = customization.get("buttonCustomizations") else {
        return true;
    };
    let Some(values) = values.as_array() else {
        return false;
    };
    if values.len() % 2 != 0 {
        return false;
    }
    let mut seen = std::collections::BTreeSet::new();
    values.chunks_exact(2).all(|pair| {
        pair[0].as_str().is_some_and(|button| {
            ORIENTATION_BUILTINS.contains(&button)
                && seen.insert(button.to_owned())
                && pair[1].is_object()
        })
    })
}

fn layout_without_position_equal(left: &Map<String, Value>, right: &Map<String, Value>) -> bool {
    let mut left = left.clone();
    let mut right = right.clone();
    left.remove("centerX");
    left.remove("centerY");
    right.remove("centerX");
    right.remove("centerY");
    json_semantically_equal(&Value::Object(left), &Value::Object(right))
}

fn orientation_custom_controls_match(
    source: &Map<String, Value>,
    destination: &Map<String, Value>,
) -> bool {
    let source = source
        .get("customButtons")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let destination = destination
        .get("customButtons")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    source.len() == destination.len()
        && source.iter().zip(destination).all(|(source, destination)| {
            let (Some(mut source), Some(mut destination)) = (
                source.as_object().cloned(),
                destination.as_object().cloned(),
            ) else {
                return false;
            };
            let (Some(source_layout), Some(destination_layout)) = (
                source
                    .remove("layout")
                    .and_then(|value| value.as_object().cloned()),
                destination
                    .remove("layout")
                    .and_then(|value| value.as_object().cloned()),
            ) else {
                return false;
            };
            json_semantically_equal(&Value::Object(source), &Value::Object(destination))
                && layout_without_position_equal(&source_layout, &destination_layout)
        })
}

fn orientation_elements_match(
    source: &Map<String, Value>,
    destination: &Map<String, Value>,
) -> bool {
    let source = source
        .get("elements")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let destination = destination
        .get("elements")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    source.len() == destination.len()
        && source.iter().zip(destination).all(|(source, destination)| {
            if element_identity_key(source) != element_identity_key(destination) {
                return false;
            }
            let (Some(mut source), Some(mut destination)) = (
                source.as_object().cloned(),
                destination.as_object().cloned(),
            ) else {
                return false;
            };
            let (Some(source_layout), Some(destination_layout)) = (
                source
                    .remove("layout")
                    .and_then(|value| value.as_object().cloned()),
                destination
                    .remove("layout")
                    .and_then(|value| value.as_object().cloned()),
            ) else {
                return false;
            };
            json_semantically_equal(&Value::Object(source), &Value::Object(destination))
                && layout_without_position_equal(&source_layout, &destination_layout)
        })
}

fn orientation_top_bar_matches(
    source: &Map<String, Value>,
    destination: &Map<String, Value>,
) -> bool {
    let source = source
        .get("topBarActivationRegion")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(default_top_bar_layout);
    let destination = destination
        .get("topBarActivationRegion")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(default_top_bar_layout);
    layout_without_position_equal(&source, &destination)
}

fn orientation_guides_match(
    source: &Map<String, Value>,
    destination: &Map<String, Value>,
    source_orientation: crate::draft_operation::OrientationVariant,
    destination_orientation: crate::draft_operation::OrientationVariant,
) -> bool {
    let source_metadata = source.get("designMetadata").and_then(Value::as_object);
    let destination_metadata = destination.get("designMetadata").and_then(Value::as_object);
    match (source_metadata, destination_metadata) {
        (None, None) => true,
        (Some(source_metadata), Some(destination_metadata)) => {
            let mut source_rest = source_metadata.clone();
            let mut destination_rest = destination_metadata.clone();
            let source_guides = source_rest
                .remove("guides")
                .and_then(|value| value.as_array().cloned())
                .unwrap_or_default();
            let destination_guides = destination_rest
                .remove("guides")
                .and_then(|value| value.as_array().cloned())
                .unwrap_or_default();
            json_semantically_equal(
                &Value::Object(source_rest),
                &Value::Object(destination_rest),
            ) && source_guides.len() == destination_guides.len()
                && source_guides.iter().zip(destination_guides).all(
                    |(source_guide, destination_guide)| {
                        orientation_guide_matches(
                            source_guide,
                            &destination_guide,
                            source_orientation,
                            destination_orientation,
                        )
                    },
                )
        }
        _ => false,
    }
}

fn orientation_guide_matches(
    source: &Value,
    destination: &Value,
    source_orientation: crate::draft_operation::OrientationVariant,
    destination_orientation: crate::draft_operation::OrientationVariant,
) -> bool {
    use crate::draft_operation::OrientationVariant;
    let (Some(mut source), Some(mut destination)) = (
        source.as_object().cloned(),
        destination.as_object().cloned(),
    ) else {
        return false;
    };
    let (
        Some(source_axis),
        Some(destination_axis),
        Some(source_position),
        Some(destination_position),
    ) = (
        source
            .remove("orientation")
            .and_then(|value| value.as_str().map(str::to_owned)),
        destination
            .remove("orientation")
            .and_then(|value| value.as_str().map(str::to_owned)),
        source.remove("position").and_then(|value| value.as_f64()),
        destination
            .remove("position")
            .and_then(|value| value.as_f64()),
    )
    else {
        return false;
    };
    let expected_axis = match source_axis.as_str() {
        "horizontal" => "vertical",
        "vertical" => "horizontal",
        _ => return false,
    };
    let expected_position = match (source_orientation, destination_orientation) {
        (OrientationVariant::Landscape, OrientationVariant::Portrait) => {
            if source_axis == "vertical" {
                source_position
            } else {
                1.0 - source_position
            }
        }
        (OrientationVariant::Portrait, OrientationVariant::Landscape) => {
            if source_axis == "horizontal" {
                source_position
            } else {
                1.0 - source_position
            }
        }
        _ => return false,
    };
    destination_axis == expected_axis
        && (destination_position - expected_position).abs() <= 1e-12
        && json_semantically_equal(&Value::Object(source), &Value::Object(destination))
}

fn orientation_control_positions_match(
    source: &Map<String, Value>,
    destination: &Map<String, Value>,
    source_orientation: crate::draft_operation::OrientationVariant,
    destination_orientation: crate::draft_operation::OrientationVariant,
) -> bool {
    let Some((source_width, source_height)) = customization_canvas_size(source) else {
        return false;
    };
    for button in source.get("elements").and_then(Value::as_array).into_iter().flatten()
        .filter_map(|element| element.get("id").and_then(Value::as_str)).filter(|id| is_builtin_layer_button(id)) {
        let identity = format!("builtin:{}", button.to_ascii_lowercase());
        if orientation_control_is_hidden(source, &identity) {
            continue;
        }
        if !orientation_control_position_matches(
            source,
            destination,
            &identity,
            source_width,
            source_height,
            source_orientation,
            destination_orientation,
        ) {
            return false;
        }
    }
    for button in source
        .get("customButtons")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let Some(id) = button.get("id").and_then(Value::as_str) else {
            return false;
        };
        let identity = format!("custom:{}", id.to_ascii_lowercase());
        if orientation_control_is_hidden(source, &identity) {
            continue;
        }
        if !orientation_control_position_matches(
            source,
            destination,
            &identity,
            source_width,
            source_height,
            source_orientation,
            destination_orientation,
        ) {
            return false;
        }
    }
    true
}

fn orientation_control_position_matches(
    source: &Map<String, Value>,
    destination: &Map<String, Value>,
    identity: &str,
    source_width: f64,
    source_height: f64,
    source_orientation: crate::draft_operation::OrientationVariant,
    destination_orientation: crate::draft_operation::OrientationVariant,
) -> bool {
    use crate::draft_operation::OrientationVariant;
    let Some(snapshot) = group_nudge_snapshot(source, identity, source_width, source_height) else {
        return false;
    };
    let source_x = snapshot.center_x / source_width;
    let source_y = snapshot.center_y / source_height;
    let expected = match (source_orientation, destination_orientation) {
        (OrientationVariant::Landscape, OrientationVariant::Portrait) => (source_y, 1.0 - source_x),
        (OrientationVariant::Portrait, OrientationVariant::Landscape) => (1.0 - source_y, source_x),
        _ => return false,
    };
    group_child_position(destination, identity).is_some_and(|actual| {
        (actual.0 - expected.0).abs() <= 1e-10 && (actual.1 - expected.1).abs() <= 1e-10
    })
}

fn orientation_control_is_hidden(customization: &Map<String, Value>, identity: &str) -> bool {
    let Some((kind, value)) = identity.split_once(':') else {
        return true;
    };
    let layout = match kind {
        "builtin" => builtin_layout(customization, value),
        "custom" => custom_button(customization, value)
            .and_then(|button| button.get("layout"))
            .and_then(Value::as_object)
            .cloned(),
        "system" if value == "top_bar_activation" => customization
            .get("topBarActivationRegion")
            .and_then(Value::as_object)
            .cloned()
            .or_else(|| Some(default_top_bar_layout())),
        _ => None,
    };
    layout
        .and_then(|layout| layout.get("isHidden").and_then(Value::as_bool))
        .unwrap_or(false)
}

fn orientation_top_bar_position_matches(
    source: &Map<String, Value>,
    destination: &Map<String, Value>,
    destination_orientation: crate::draft_operation::OrientationVariant,
) -> bool {
    use crate::draft_operation::OrientationVariant;
    if orientation_control_is_hidden(source, "system:top_bar_activation") {
        return true;
    }
    let source_layout = source
        .get("topBarActivationRegion")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(default_top_bar_layout);
    let source_y = source_layout
        .get("centerY")
        .and_then(Value::as_f64)
        .unwrap_or(0.115);
    let expected_y = if destination_orientation == OrientationVariant::Portrait {
        let mut selected = source_y;
        if orientation_top_bar_collides(destination, selected) {
            for candidate in [0.32, 0.50, 0.68] {
                selected = candidate;
                if !orientation_top_bar_collides(destination, candidate) {
                    break;
                }
            }
        }
        selected
    } else {
        source_y
    };
    group_child_position(destination, "system:top_bar_activation").is_some_and(|actual| {
        (actual.0 - 0.5).abs() <= 1e-12 && (actual.1 - expected_y).abs() <= 1e-12
    })
}

fn orientation_top_bar_collides(customization: &Map<String, Value>, center_y: f64) -> bool {
    let Some((width, height)) = customization_canvas_size(customization) else {
        return true;
    };
    let mut candidate = customization.clone();
    if !set_group_child_position(&mut candidate, "system:top_bar_activation", 0.5, center_y) {
        return true;
    }
    let Some(system) = group_nudge_snapshot(&candidate, "system:top_bar_activation", width, height)
    else {
        return true;
    };
    let system_frame = (
        system.center_x - system.width / 2.0 - 6.0,
        system.center_y - system.height / 2.0 - 6.0,
        system.center_x + system.width / 2.0 + 6.0,
        system.center_y + system.height / 2.0 + 6.0,
    );
    let identities = candidate.get("elements").and_then(Value::as_array).into_iter().flatten()
        .filter(|element| !matches!(element.get("kind").and_then(Value::as_str), Some("text" | "decoration")))
        .filter_map(element_identity_key).collect::<Vec<_>>();
    identities.into_iter().any(|identity| {
        if orientation_control_is_hidden(&candidate, &identity) {
            return false;
        }
        group_nudge_snapshot(&candidate, &identity, width, height).is_some_and(|control| {
            let frame = (
                control.center_x - control.width / 2.0,
                control.center_y - control.height / 2.0,
                control.center_x + control.width / 2.0,
                control.center_y + control.height / 2.0,
            );
            system_frame.0 < frame.2
                && system_frame.2 > frame.0
                && system_frame.1 < frame.3
                && system_frame.3 > frame.1
        })
    })
}

fn constrained_customization_operation_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    use crate::draft_operation::{
        ConfigurationBackgroundEdit, ConfigurationBackgroundScope, ConfigurationVariant,
        ControlBarMoveDirection, LayerMoveDestination,
    };

    let (profile_id, variant) = match operation {
        ConfigurationOperation::CustomizationSet {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::DeviceSet {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::ControlBarSet {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::ControlBarAdd {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::ControlBarRemove {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::ControlBarMove {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::StyleApply {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::StyleDetach {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::LayerMove {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::LayerForward {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::LayerBackward {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::LayerFront {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::LayerBack {
            profile_id,
            variant,
            ..
        } => (profile_id.as_str(), *variant),
        _ => return false,
    };
    if !customization_operation_delta(before, after, profile_id, variant) {
        return false;
    }
    let (Some(before_index), Some(after_index)) = (
        profile_position(before, profile_id),
        profile_position(after, profile_id),
    ) else {
        return false;
    };
    let (Some(before_profile), Some(after_profile)) = (
        before.profiles[before_index].as_object(),
        after.profiles[after_index].as_object(),
    ) else {
        return false;
    };
    let source_key = match variant {
        ConfigurationVariant::Primary => "customization",
        ConfigurationVariant::Landscape => "landscapeCustomization",
        ConfigurationVariant::Portrait => "portraitCustomization",
    };
    let Some(mut expected) = before_profile
        .get(source_key)
        .or_else(|| before_profile.get("customization"))
        .and_then(Value::as_object)
        .cloned()
    else {
        return false;
    };
    if variant != ConfigurationVariant::Primary {
        if let Some(color_scheme) = before_profile
            .get("customization")
            .and_then(|value| value.get("colorSchemePreference"))
        {
            expected.insert("colorSchemePreference".to_owned(), color_scheme.clone());
        }
        correct_customization_frame_orientation(&mut expected, variant);
    }

    match operation {
        ConfigurationOperation::CustomizationSet { changes, .. } => {
            if let Some(value) = changes.layout_mode {
                set_serialized(&mut expected, "layoutMode", value);
            }
            if let Some(value) = changes.control_scale {
                set_serialized(&mut expected, "controlScale", value);
            }
            if let Some(value) = changes.color_scheme {
                set_serialized(&mut expected, "colorSchemePreference", value);
            }
            if let Some(value) = changes.accent_style {
                set_serialized(&mut expected, "accentStyle", value);
            }
            if let Some(value) = changes.shows_button_labels {
                expected.insert("showsButtonLabels".to_owned(), Value::Bool(value));
            }
            match &changes.background_edit {
                ConfigurationBackgroundEdit::Keep => {}
                ConfigurationBackgroundEdit::Clear => {
                    for key in [
                        "backgroundLightColor",
                        "backgroundDarkColor",
                        "backgroundFillStyle",
                        "backgroundLightFillStyle",
                        "backgroundDarkFillStyle",
                    ] {
                        expected.remove(key);
                    }
                }
                ConfigurationBackgroundEdit::Set { scope, color } => {
                    let Ok(color) = serde_json::to_value(color) else {
                        return false;
                    };
                    match scope {
                        ConfigurationBackgroundScope::All => {
                            expected.insert("backgroundLightColor".to_owned(), color.clone());
                            expected.insert("backgroundDarkColor".to_owned(), color);
                            expected.remove("backgroundFillStyle");
                            expected.remove("backgroundLightFillStyle");
                            expected.remove("backgroundDarkFillStyle");
                        }
                        ConfigurationBackgroundScope::Light => {
                            expected.insert("backgroundLightColor".to_owned(), color);
                            expected.remove("backgroundLightFillStyle");
                        }
                        ConfigurationBackgroundScope::Dark => {
                            expected.insert("backgroundDarkColor".to_owned(), color);
                            expected.remove("backgroundDarkFillStyle");
                        }
                    }
                }
            }
        }
        ConfigurationOperation::DeviceSet { frame_id, .. } => {
            if let Some(canvas) = expected
                .get_mut("deviceCanvas")
                .and_then(Value::as_object_mut)
            {
                canvas.insert("frameID".to_owned(), Value::String(frame_id.clone()));
            } else {
                expected.insert(
                    "deviceCanvas".to_owned(),
                    serde_json::json!({"frameID": frame_id}),
                );
            }
        }
        ConfigurationOperation::ControlBarSet { items, .. } => {
            let Ok(items_value) = serde_json::to_value(items) else {
                return false;
            };
            expected.insert("controlBarItems".to_owned(), items_value);
            retain_control_bar_customizations(&mut expected, items);
        }
        ConfigurationOperation::ControlBarAdd { item, .. } => {
            ensure_expected_control_bar_items(&mut expected);
            let Ok(item_value) = serde_json::to_value(item) else {
                return false;
            };
            let Some(items) = expected
                .get_mut("controlBarItems")
                .and_then(Value::as_array_mut)
            else {
                return false;
            };
            if !items.contains(&item_value) {
                items.push(item_value);
            }
        }
        ConfigurationOperation::ControlBarRemove { item, .. } => {
            ensure_expected_control_bar_items(&mut expected);
            let Ok(item_value) = serde_json::to_value(item) else {
                return false;
            };
            let remaining_items = {
                let Some(items) = expected
                    .get_mut("controlBarItems")
                    .and_then(Value::as_array_mut)
                else {
                    return false;
                };
                items.retain(|value| value != &item_value);
                items_for_values(items)
            };
            retain_control_bar_customizations(&mut expected, &remaining_items);
        }
        ConfigurationOperation::ControlBarMove {
            item, direction, ..
        } => {
            ensure_expected_control_bar_items(&mut expected);
            let Ok(item_value) = serde_json::to_value(item) else {
                return false;
            };
            let Some(items) = expected
                .get_mut("controlBarItems")
                .and_then(Value::as_array_mut)
            else {
                return false;
            };
            if let Some(index) = items.iter().position(|value| value == &item_value) {
                let destination = match direction {
                    ControlBarMoveDirection::Up => index.saturating_sub(1),
                    ControlBarMoveDirection::Down => (index + 1).min(items.len() - 1),
                };
                if destination != index {
                    let value = items.remove(index);
                    items.insert(destination, value);
                }
            }
        }
        ConfigurationOperation::StyleApply {
            style_id,
            element_id,
            ..
        } => {
            if !style_exists_in_customization(&expected, style_id)
                || !set_control_style_id(&mut expected, element_id, Some(style_id))
            {
                return false;
            }
        }
        ConfigurationOperation::StyleDetach { element_id, .. } => {
            if !set_control_style_id(&mut expected, element_id, None) {
                return false;
            }
        }
        ConfigurationOperation::LayerMove {
            element_id,
            destination,
            ..
        } => {
            let Some(mut order) = normalized_layer_order(&expected) else {
                return false;
            };
            let Some(target) = resolve_layer_identity(&expected, element_id) else {
                return false;
            };
            let Some(source_index) = layer_order_position(&order, &target) else {
                return false;
            };
            let requested_index = match destination {
                LayerMoveDestination::Index { index } => i64::from(*index),
                LayerMoveDestination::Before { element_id } => {
                    let Some(reference) = resolve_layer_identity(&expected, element_id) else {
                        return false;
                    };
                    let Some(index) = layer_order_position(&order, &reference) else {
                        return false;
                    };
                    index as i64
                }
                LayerMoveDestination::After { element_id } => {
                    let Some(reference) = resolve_layer_identity(&expected, element_id) else {
                        return false;
                    };
                    let Some(index) = layer_order_position(&order, &reference) else {
                        return false;
                    };
                    index as i64 + 1
                }
            };
            let moving = order.remove(source_index);
            let destination_index = requested_index.clamp(0, order.len() as i64) as usize;
            order.insert(destination_index, moving);
            if !set_expected_layer_order(&mut expected, order) {
                return false;
            }
        }
        ConfigurationOperation::LayerForward { element_id, .. }
        | ConfigurationOperation::LayerBackward { element_id, .. }
        | ConfigurationOperation::LayerFront { element_id, .. }
        | ConfigurationOperation::LayerBack { element_id, .. } => {
            let Some(mut order) = normalized_layer_order(&expected) else {
                return false;
            };
            let Some(target) = resolve_layer_identity(&expected, element_id) else {
                return false;
            };
            let Some(source_index) = layer_order_position(&order, &target) else {
                return false;
            };
            let destination = match operation {
                ConfigurationOperation::LayerForward { .. } => {
                    if source_index + 1 >= order.len() {
                        source_index
                    } else {
                        source_index + 1
                    }
                }
                ConfigurationOperation::LayerBackward { .. } => source_index.saturating_sub(1),
                ConfigurationOperation::LayerFront { .. } => order.len() - 1,
                ConfigurationOperation::LayerBack { .. } => 0,
                _ => return false,
            };
            if destination != source_index {
                let moving = order.remove(source_index);
                order.insert(destination, moving);
            }
            if !set_expected_layer_order(&mut expected, order) {
                return false;
            }
        }
        _ => return false,
    }

    let expected = Value::Object(expected);
    after_profile.get("customization").is_some_and(|actual| {
        if matches!(operation, ConfigurationOperation::DeviceSet { frame_id, .. } if frame_id == "iphone-17-pro-landscape") {
            // Swift omits the known default canvas. Compare that representation
            // only; all unknown canvas fields and every other field stay exact.
            customization_mirrors_are_semantically_equal(Some(actual), Some(&expected), ConfigurationVariant::Landscape)
        } else {
            json_semantically_equal(actual, &expected)
        }
    })
}

fn constrained_style_resource_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    let (profile_id, allowed_keys): (&str, &[&str]) = match operation {
        ConfigurationOperation::StyleCreate { profile_id, .. }
        | ConfigurationOperation::StyleRename { profile_id, .. }
        | ConfigurationOperation::StyleDelete { profile_id, .. } => (
            profile_id,
            &[
                "customization",
                "landscapeCustomization",
                "portraitCustomization",
                "updatedAt",
            ],
        ),
        _ => return false,
    };
    if !profile_local_delta(before, after, profile_id, allowed_keys) {
        return false;
    }
    let (Some(before_index), Some(after_index)) = (
        profile_position(before, profile_id),
        profile_position(after, profile_id),
    ) else {
        return false;
    };
    let (Some(before_profile), Some(after_profile)) = (
        before.profiles[before_index].as_object(),
        after.profiles[after_index].as_object(),
    ) else {
        return false;
    };

    if let ConfigurationOperation::StyleRename { style_id, .. } = operation {
        let Some(primary) = before_profile
            .get("customization")
            .and_then(Value::as_object)
        else {
            return false;
        };
        if !style_exists_in_customization(primary, style_id) {
            return false;
        }
    }

    for key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let Some(before_value) = before_profile.get(key) else {
            if after_profile.get(key).is_some() {
                return false;
            }
            continue;
        };
        let Some(mut expected) = before_value.as_object().cloned() else {
            return false;
        };
        if !apply_style_resource_operation(&mut expected, operation) {
            return false;
        }
        if !after_profile.get(key).is_some_and(|actual| {
            style_resource_customization_equal(actual, &Value::Object(expected))
        }) {
            return false;
        }
    }
    true
}

fn style_resource_customization_equal(actual: &Value, expected: &Value) -> bool {
    let (Some(actual), Some(expected)) = (actual.as_object(), expected.as_object()) else {
        return false;
    };
    if actual.len() != expected.len() {
        return false;
    }
    actual.iter().all(|(key, actual)| {
        expected.get(key).is_some_and(|expected| {
            if key == "styleLibrary" {
                style_library_semantically_equal(actual, expected, None)
            } else {
                json_semantically_equal(actual, expected)
            }
        })
    })
}

fn style_library_semantically_equal(actual: &Value, expected: &Value, field: Option<&str>) -> bool {
    match (actual, expected) {
        (Value::Number(actual), Value::Number(expected)) => {
            let (Some(actual), Some(expected)) = (actual.as_f64(), expected.as_f64()) else {
                return actual == expected;
            };
            if matches!(field, Some("red" | "green" | "blue")) {
                (actual - expected).abs() <= f64::EPSILON
            } else {
                actual == expected
            }
        }
        (Value::Array(actual), Value::Array(expected)) => {
            actual.len() == expected.len()
                && actual.iter().zip(expected).all(|(actual, expected)| {
                    style_library_semantically_equal(actual, expected, field)
                })
        }
        (Value::Object(actual), Value::Object(expected)) => {
            actual.len() == expected.len()
                && actual.iter().all(|(key, actual)| {
                    expected.get(key).is_some_and(|expected| {
                        style_library_semantically_equal(actual, expected, Some(key))
                    })
                })
        }
        _ => actual == expected,
    }
}

fn apply_style_resource_operation(
    customization: &mut Map<String, Value>,
    operation: &ConfigurationOperation,
) -> bool {
    match operation {
        ConfigurationOperation::StyleCreate {
            style_id,
            name,
            appearance,
            ..
        } => {
            let Some(token) = expected_style_token(style_id, name.trim(), appearance) else {
                return false;
            };
            upsert_expected_style(customization, token)
        }
        ConfigurationOperation::StyleRename { style_id, name, .. } => {
            rename_expected_style(customization, style_id, name.trim())
        }
        ConfigurationOperation::StyleDelete { style_id, .. } => {
            delete_expected_style(customization, style_id)
        }
        _ => false,
    }
}

fn style_library_styles_mut(
    customization: &mut Map<String, Value>,
    create: bool,
) -> Option<&mut Vec<Value>> {
    if !customization.contains_key("styleLibrary") {
        if !create {
            return None;
        }
        customization.insert("styleLibrary".to_owned(), serde_json::json!({"styles": []}));
    }
    customization
        .get_mut("styleLibrary")?
        .as_object_mut()?
        .entry("styles".to_owned())
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
}

fn style_id(value: &Value) -> Option<&str> {
    value.get("id").and_then(Value::as_str)
}

fn style_exists_in_customization(customization: &Map<String, Value>, expected_id: &str) -> bool {
    customization
        .get("styleLibrary")
        .and_then(Value::as_object)
        .and_then(|library| library.get("styles"))
        .and_then(Value::as_array)
        .is_some_and(|styles| {
            styles
                .iter()
                .any(|style| style_id(style) == Some(expected_id))
        })
}

fn upsert_expected_style(customization: &mut Map<String, Value>, token: Value) -> bool {
    let Some(expected_id) = style_id(&token).map(str::to_owned) else {
        return false;
    };
    let Some(styles) = style_library_styles_mut(customization, true) else {
        return false;
    };
    let existing = styles
        .iter()
        .position(|style| style_id(style) == Some(expected_id.as_str()))
        .map(|index| styles.remove(index));
    let token = existing
        .as_ref()
        .map_or(token.clone(), |raw| merge_style_token_unknown(raw, &token));
    styles.push(token);
    true
}

fn rename_expected_style(
    customization: &mut Map<String, Value>,
    expected_id: &str,
    name: &str,
) -> bool {
    let Some(styles) = style_library_styles_mut(customization, false) else {
        return true;
    };
    if let Some(style) = styles
        .iter_mut()
        .find(|style| style_id(style) == Some(expected_id))
    {
        let Some(style) = style.as_object_mut() else {
            return false;
        };
        style.insert("name".to_owned(), Value::String(name.to_owned()));
    }
    true
}

fn delete_expected_style(customization: &mut Map<String, Value>, expected_id: &str) -> bool {
    if let Some(styles) = style_library_styles_mut(customization, false) {
        styles.retain(|style| style_id(style) != Some(expected_id));
        if styles.is_empty() {
            customization.remove("styleLibrary");
        }
    }
    clear_style_references(customization, expected_id)
}

fn clear_style_references(customization: &mut Map<String, Value>, expected_id: &str) -> bool {
    let mut cleared_builtins = Vec::new();
    let mut cleared_custom_ids = Vec::new();
    if let Some(values) = customization
        .get_mut("buttonCustomizations")
        .and_then(Value::as_array_mut)
    {
        if values.len() % 2 != 0 {
            return false;
        }
        let mut index = 0;
        while index + 1 < values.len() {
            let Some(button) = values[index].as_str().map(str::to_owned) else {
                return false;
            };
            let Some(layout) = values[index + 1].as_object_mut() else {
                return false;
            };
            if layout.get("styleID").and_then(Value::as_str) == Some(expected_id) {
                cleared_builtins.push(button);
                layout.remove("styleID");
                if button_layout_is_default(layout) {
                    values.drain(index..index + 2);
                    continue;
                }
            }
            index += 2;
        }
    }
    if let Some(buttons) = customization
        .get_mut("customButtons")
        .and_then(Value::as_array_mut)
    {
        for button in buttons {
            let Some(id) = button.get("id").and_then(Value::as_str).map(str::to_owned) else {
                return false;
            };
            let Some(layout) = button.get_mut("layout").and_then(Value::as_object_mut) else {
                return false;
            };
            if layout.get("styleID").and_then(Value::as_str) == Some(expected_id) {
                cleared_custom_ids.push(id);
                layout.remove("styleID");
            }
        }
    }
    if let Some(elements) = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
    {
        for element in elements {
            let is_cleared_builtin = element
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|button| {
                    cleared_builtins
                        .iter()
                        .any(|value| value.eq_ignore_ascii_case(button))
                });
            let is_cleared_custom = element.get("id").and_then(Value::as_str).is_some_and(|id| {
                cleared_custom_ids
                    .iter()
                    .any(|value| value.eq_ignore_ascii_case(id))
            });
            let owns_target_style = element.get("layout").and_then(|layout| layout.get("styleID"))
                .and_then(Value::as_str) == Some(expected_id);
            if is_cleared_builtin || is_cleared_custom || owns_target_style {
                let Some(layout) = element.get_mut("layout").and_then(Value::as_object_mut) else {
                    return false;
                };
                layout.remove("styleID");
            }
        }
    }
    if let Some(layout) = customization
        .get_mut("topBarActivationRegion")
        .and_then(Value::as_object_mut)
    {
        if layout.get("styleID").and_then(Value::as_str) == Some(expected_id) {
            layout.remove("styleID");
            if layout.is_empty() || top_bar_layout_is_default(layout) {
                customization.remove("topBarActivationRegion");
            }
        }
    }
    if let Some(values) = customization
        .get_mut("controlBarItemCustomizations")
        .and_then(Value::as_array_mut)
    {
        let mut index = 0;
        while index < values.len() {
            let Some(entry) = values[index].as_object_mut() else {
                return false;
            };
            let Some(appearance) = entry.get_mut("appearance").and_then(Value::as_object_mut)
            else {
                return false;
            };
            if appearance.get("styleID").and_then(Value::as_str) == Some(expected_id) {
                appearance.remove("styleID");
                if appearance.is_empty() || button_layout_is_default(appearance) {
                    values.remove(index);
                    continue;
                }
            }
            index += 1;
        }
        if values.is_empty() {
            customization.remove("controlBarItemCustomizations");
        }
    }
    true
}

fn expected_style_token(
    style_id: &str,
    name: &str,
    appearance: &crate::draft_operation::StyleAppearance,
) -> Option<Value> {
    use crate::draft_operation::StyleIconSource;

    let mut visual = appearance
        .material_preset
        .map(material_visual_style)
        .unwrap_or_else(|| serde_json::json!({"normal": {}}));
    let normal = visual.get_mut("normal")?.as_object_mut()?;
    if let Some(color) = appearance.fill_color {
        normal.insert("fillStyle".to_owned(), solid_fill(color));
    }
    for (key, color) in [
        ("foregroundColor", appearance.foreground_color),
        ("strokeColor", appearance.stroke_color),
        ("glowColor", appearance.glow_color),
        ("innerShadowColor", appearance.inner_shadow_color),
        ("highlightColor", appearance.highlight_color),
        ("bevelHighlightColor", appearance.bevel_highlight_color),
        ("bevelShadowColor", appearance.bevel_shadow_color),
    ] {
        if let Some(color) = color {
            normal.insert(key.to_owned(), normalized_color_value(color));
        }
    }
    for (key, value) in [
        ("strokeWidth", appearance.stroke_width),
        ("glowRadius", appearance.glow_radius),
        ("innerShadowRadius", appearance.inner_shadow_radius),
        ("innerShadowX", appearance.inner_shadow_x),
        ("innerShadowY", appearance.inner_shadow_y),
        ("highlightRadius", appearance.highlight_radius),
        ("highlightX", appearance.highlight_x),
        ("highlightY", appearance.highlight_y),
        ("highlightOpacity", appearance.highlight_opacity),
        ("bevelWidth", appearance.bevel_width),
        ("opacity", appearance.opacity),
    ] {
        if let Some(value) = value {
            normal.insert(key.to_owned(), Value::from(value));
        }
    }
    if let Some(shadows) = &appearance.shadows {
        normal.insert(
            "shadows".to_owned(),
            Value::Array(
                shadows
                    .iter()
                    .map(|shadow| {
                        let mut color = normalized_color(shadow.color);
                        color.alpha *= shadow.opacity;
                        serde_json::json!({
                            "color": color_value(color),
                            "radius": shadow.radius,
                            "x": shadow.x,
                            "y": shadow.y
                        })
                    })
                    .collect(),
            ),
        );
    }
    if appearance.pressed_fill_color.is_some() || appearance.pressed_scale.is_some() {
        let pressed = visual
            .as_object_mut()?
            .entry("pressed".to_owned())
            .or_insert_with(|| serde_json::json!({}))
            .as_object_mut()?;
        if let Some(color) = appearance.pressed_fill_color {
            pressed.insert("fillStyle".to_owned(), solid_fill(color));
        }
        if let Some(scale) = appearance.pressed_scale {
            pressed.insert("scale".to_owned(), Value::from(scale));
        }
    }
    if let Some(icon) = &appearance.icon {
        visual.as_object_mut()?.insert(
            "icon".to_owned(),
            serde_json::json!({
                "source": match icon.source {
                    StyleIconSource::SfSymbol => "sf_symbol",
                    StyleIconSource::Text => "text",
                },
                "value": icon.value.trim(),
                "placement": "center",
                "scale": 1,
                "renderingMode": "template"
            }),
        );
    }
    if let Some(haptic) = &appearance.haptic {
        let feedback = expected_haptic_feedback(haptic)?;
        let style = feedback.get("style")?.clone();
        let visual = visual.as_object_mut()?;
        visual.insert("hapticStyle".to_owned(), style);
        visual.insert("hapticFeedback".to_owned(), feedback);
    }
    let visual_object = visual.as_object_mut()?;
    if visual_object
        .get("normal")
        .and_then(Value::as_object)
        .is_some_and(Map::is_empty)
    {
        visual_object.insert("normal".to_owned(), serde_json::json!({}));
    }
    Some(serde_json::json!({
        "id": style_id,
        "name": name,
        "appliesTo": ["button", "decoration", "joystick", "text", "trackpad", "trigger"],
        "visualStyle": visual
    }))
}

fn expected_haptic_feedback(haptic: &crate::draft_operation::StyleHaptic) -> Option<Value> {
    use crate::draft_operation::{StyleHapticKind, StyleHapticPattern};
    let style = haptic.style.unwrap_or(StyleHapticKind::Light);
    let (default_intensity, default_sharpness) = match style {
        StyleHapticKind::None => (0.0, 0.0),
        StyleHapticKind::Light => (0.45, 0.48),
        StyleHapticKind::Medium => (0.62, 0.56),
        StyleHapticKind::Heavy => (0.82, 0.66),
        StyleHapticKind::Soft => (0.38, 0.24),
        StyleHapticKind::Rigid => (0.70, 0.92),
    };
    let style_text = match style {
        StyleHapticKind::None => "none",
        StyleHapticKind::Light => "light",
        StyleHapticKind::Medium => "medium",
        StyleHapticKind::Heavy => "heavy",
        StyleHapticKind::Soft => "soft",
        StyleHapticKind::Rigid => "rigid",
    };
    let pattern = if style == StyleHapticKind::None {
        StyleHapticPattern::Single
    } else {
        haptic.pattern.unwrap_or(StyleHapticPattern::Single)
    };
    let pattern_text = match pattern {
        StyleHapticPattern::Single => "single",
        StyleHapticPattern::Double => "double",
        StyleHapticPattern::Pulse => "pulse",
        StyleHapticPattern::Buzz => "buzz",
    };
    Some(serde_json::json!({
        "style": style_text,
        "pattern": pattern_text,
        "intensity": if style == StyleHapticKind::None { 0.0 } else { haptic.intensity.unwrap_or(default_intensity) },
        "sharpness": if style == StyleHapticKind::None { 0.0 } else { haptic.sharpness.unwrap_or(default_sharpness) },
        "duration": haptic.duration.unwrap_or(0.06)
    }))
}

#[derive(Clone, Copy)]
struct NormalizedStyleColor {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
}

fn normalized_color(color: crate::draft_operation::ConfigurationRgbaColor) -> NormalizedStyleColor {
    let key = ((color.red * 255.0).round() as u32) << 16
        | ((color.green * 255.0).round() as u32) << 8
        | ((color.blue * 255.0).round() as u32);
    let replacement = match key {
        0xFFF6DE | 0xFFF4CF | 0xFFF1C1 => Some(0xF5F5F5),
        0xFFDC73 | 0xFFC543 => Some(0xD4D4D4),
        0xFFA600 | 0xFFAE00 => Some(0xA3A3A3),
        0xFF9300 => Some(0x737373),
        0xAA4D00 => Some(0x525252),
        0x561900 => Some(0x262626),
        0x2A1700 => Some(0x1A1A1A),
        0x361900 => Some(0x1F1F1F),
        0x502800 => Some(0x292929),
        0x5B3000 => Some(0x2E2E2E),
        0x703E00 => Some(0x454545),
        0xED9A00 => Some(0x878787),
        0xFFF3D5 => Some(0xEDEDED),
        0xFDE68A => Some(0xE5E7EB),
        0xD97706 => Some(0x9CA3AF),
        0x78350F => Some(0x374151),
        0xFCD34D => Some(0xF3F4F6),
        0xF59E0B | 0xFACC15 | 0xEAB308 => Some(0xD1D5DB),
        0x451A03 => Some(0x111827),
        0xF97316 => Some(0x9CA3AF),
        _ => None,
    };
    let (red, green, blue) = replacement.map_or((color.red, color.green, color.blue), |rgb| {
        (
            f64::from((rgb >> 16) & 0xff) / 255.0,
            f64::from((rgb >> 8) & 0xff) / 255.0,
            f64::from(rgb & 0xff) / 255.0,
        )
    });
    NormalizedStyleColor {
        red,
        green,
        blue,
        alpha: color.alpha,
    }
}

fn color_value(color: NormalizedStyleColor) -> Value {
    serde_json::json!({
        "red": color.red,
        "green": color.green,
        "blue": color.blue,
        "alpha": color.alpha
    })
}

fn normalized_color_value(color: crate::draft_operation::ConfigurationRgbaColor) -> Value {
    color_value(normalized_color(color))
}

fn solid_fill(color: crate::draft_operation::ConfigurationRgbaColor) -> Value {
    serde_json::json!({"kind": "solid", "color": normalized_color_value(color)})
}

fn hex_color(rgb: u32, alpha: f64) -> Value {
    color_value(NormalizedStyleColor {
        red: f64::from((rgb >> 16) & 0xff) / 255.0,
        green: f64::from((rgb >> 8) & 0xff) / 255.0,
        blue: f64::from(rgb & 0xff) / 255.0,
        alpha,
    })
}

fn hex_fill(rgb: u32) -> Value {
    serde_json::json!({"kind": "solid", "color": hex_color(rgb, 1.0)})
}

fn material_shadow(rgb: u32, alpha: f64, radius: f64, x: f64, y: f64) -> Value {
    serde_json::json!({"color": hex_color(rgb, alpha), "radius": radius, "x": x, "y": y})
}

fn material_visual_style(preset: crate::draft_operation::StyleMaterialPreset) -> Value {
    use crate::draft_operation::StyleMaterialPreset;
    match preset {
        StyleMaterialPreset::SoftWhiteRaised => serde_json::json!({
            "normal": {
                "fillStyle": hex_fill(0xF7F4F8), "foregroundColor": hex_color(0x7C61A8, 1.0),
                "strokeColor": hex_color(0xFFFFFF, 0.68), "strokeWidth": 1,
                "shadows": [material_shadow(0xFFFFFF, 0.96, 14.0, -7.0, -7.0), material_shadow(0x9B91AA, 0.24, 20.0, 8.0, 9.0)],
                "highlightColor": hex_color(0xFFFFFF, 1.0), "highlightRadius": 10,
                "highlightX": -5, "highlightY": -5, "highlightOpacity": 0.34,
                "bevelHighlightColor": hex_color(0xFFFFFF, 0.70), "bevelShadowColor": hex_color(0xC8C0D2, 0.50), "bevelWidth": 1.25
            },
            "pressed": {
                "fillStyle": hex_fill(0xEDE8F1),
                "shadows": [material_shadow(0xA89DB7, 0.18, 8.0, 3.0, 3.0), material_shadow(0xFFFFFF, 0.74, 8.0, -2.0, -2.0)],
                "innerShadowColor": hex_color(0xB5AFC1, 0.36), "innerShadowRadius": 6,
                "innerShadowX": 2, "innerShadowY": 2, "highlightOpacity": 0.10,
                "bevelWidth": 0.6, "scale": 0.975
            },
            "hapticFeedback": {"style": "soft", "pattern": "single", "intensity": 0.42, "sharpness": 0.22, "duration": 0.06}
        }),
        StyleMaterialPreset::SoftWhiteInset => serde_json::json!({
            "normal": {
                "fillStyle": hex_fill(0xEFEAF2), "foregroundColor": hex_color(0x8067A7, 1.0),
                "strokeColor": hex_color(0xFFFFFF, 0.42), "strokeWidth": 1,
                "shadows": [material_shadow(0xFFFFFF, 0.62, 10.0, -3.0, -3.0), material_shadow(0xB0A7BC, 0.20, 12.0, 4.0, 5.0)],
                "innerShadowColor": hex_color(0xAFA7BB, 0.30), "innerShadowRadius": 8,
                "innerShadowX": 3, "innerShadowY": 3,
                "highlightColor": hex_color(0xFFFFFF, 1.0), "highlightRadius": 8,
                "highlightX": -4, "highlightY": -4, "highlightOpacity": 0.22,
                "bevelHighlightColor": hex_color(0xFFFFFF, 0.58), "bevelShadowColor": hex_color(0xB7AEC4, 0.42), "bevelWidth": 1
            },
            "pressed": {"innerShadowRadius": 10, "innerShadowX": 4, "innerShadowY": 4, "scale": 0.985},
            "hapticFeedback": {"style": "soft", "pattern": "single", "intensity": 0.34, "sharpness": 0.18, "duration": 0.06}
        }),
        StyleMaterialPreset::SoftWhitePlate => serde_json::json!({
            "normal": {
                "fillStyle": hex_fill(0xF2EEF5), "foregroundColor": hex_color(0x8169A7, 1.0),
                "strokeColor": hex_color(0xFFFFFF, 0.48), "strokeWidth": 1,
                "shadows": [material_shadow(0xFFFFFF, 0.92, 26.0, -12.0, -12.0), material_shadow(0x998DAA, 0.22, 34.0, 14.0, 16.0)],
                "highlightColor": hex_color(0xFFFFFF, 1.0), "highlightRadius": 22,
                "highlightX": -10, "highlightY": -10, "highlightOpacity": 0.26,
                "bevelHighlightColor": hex_color(0xFFFFFF, 0.64), "bevelShadowColor": hex_color(0xC8C0D2, 0.42), "bevelWidth": 1.4
            }
        }),
    }
}

fn merge_style_token_unknown(raw: &Value, after: &Value) -> Value {
    let before = style_known_projection(raw);
    apply_expected_canonical_changes(raw, &before, after)
}

fn style_known_projection(value: &Value) -> Value {
    fn project_object(value: &Value, keys: &[&str]) -> Value {
        let Some(object) = value.as_object() else {
            return value.clone();
        };
        Value::Object(
            keys.iter()
                .filter_map(|key| {
                    object
                        .get(*key)
                        .map(|value| ((*key).to_owned(), value.clone()))
                })
                .collect(),
        )
    }
    let mut token = project_object(value, &["id", "name", "appliesTo", "visualStyle"]);
    let Some(token_object) = token.as_object_mut() else {
        return token;
    };
    let Some(raw_visual) = value.get("visualStyle") else {
        return token;
    };
    let mut visual = project_object(
        raw_visual,
        &[
            "normal",
            "pressed",
            "active",
            "disabled",
            "icon",
            "hapticStyle",
            "hapticFeedback",
        ],
    );
    let state_keys = [
        "fillStyle",
        "foregroundColor",
        "strokeColor",
        "strokeWidth",
        "shadowColor",
        "shadowRadius",
        "shadowX",
        "shadowY",
        "shadows",
        "glowColor",
        "glowRadius",
        "innerShadowColor",
        "innerShadowRadius",
        "innerShadowX",
        "innerShadowY",
        "highlightColor",
        "highlightRadius",
        "highlightX",
        "highlightY",
        "highlightOpacity",
        "bevelHighlightColor",
        "bevelShadowColor",
        "bevelWidth",
        "indexColor",
        "indexWidth",
        "opacity",
        "scale",
        "blurRadius",
    ];
    if let Some(visual_object) = visual.as_object_mut() {
        for key in ["normal", "pressed", "active", "disabled"] {
            if let Some(raw_state) = raw_visual.get(key) {
                visual_object.insert(key.to_owned(), project_object(raw_state, &state_keys));
            }
        }
        if let Some(raw_icon) = raw_visual.get("icon") {
            visual_object.insert(
                "icon".to_owned(),
                project_object(
                    raw_icon,
                    &[
                        "source",
                        "value",
                        "placement",
                        "scale",
                        "tintColor",
                        "renderingMode",
                    ],
                ),
            );
        }
        if let Some(raw_haptic) = raw_visual.get("hapticFeedback") {
            visual_object.insert(
                "hapticFeedback".to_owned(),
                project_object(
                    raw_haptic,
                    &["style", "pattern", "intensity", "sharpness", "duration"],
                ),
            );
        }
    }
    token_object.insert("visualStyle".to_owned(), visual);
    token
}

fn apply_expected_canonical_changes(raw: &Value, before: &Value, after: &Value) -> Value {
    if json_semantically_equal(before, after) {
        return raw.clone();
    }
    match (raw, before, after) {
        (Value::Object(raw), Value::Object(before), Value::Object(after)) => {
            let mut result = raw.clone();
            let keys = before
                .keys()
                .chain(after.keys())
                .cloned()
                .collect::<std::collections::HashSet<_>>();
            for key in keys {
                match (before.get(&key), after.get(&key)) {
                    (Some(before), Some(after)) if !json_semantically_equal(before, after) => {
                        let raw = raw.get(&key).unwrap_or(before);
                        result.insert(key, apply_expected_canonical_changes(raw, before, after));
                    }
                    (None, Some(after)) => {
                        result.insert(key, after.clone());
                    }
                    (Some(_), None) => {
                        result.remove(&key);
                    }
                    _ => {}
                }
            }
            Value::Object(result)
        }
        (Value::Array(raw), Value::Array(before), Value::Array(after))
            if raw.len() == before.len() && before.len() == after.len() =>
        {
            Value::Array(
                raw.iter()
                    .zip(before)
                    .zip(after)
                    .map(|((raw, before), after)| {
                        apply_expected_canonical_changes(raw, before, after)
                    })
                    .collect(),
            )
        }
        _ => after.clone(),
    }
}

fn constrained_group_operation_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    use crate::draft_operation::ConfigurationVariant;

    let (profile_id, variant) = match operation {
        ConfigurationOperation::GroupCreate {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupRename {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupDuplicate {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupUngroup {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupHide {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupShow {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupLock {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupUnlock {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupNudge {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupForward {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupBackward {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupFront {
            profile_id,
            variant,
            ..
        }
        | ConfigurationOperation::GroupBack {
            profile_id,
            variant,
            ..
        } => (profile_id.as_str(), *variant),
        _ => return false,
    };
    if !customization_operation_delta(before, after, profile_id, variant) {
        return false;
    }
    let (Some(before_index), Some(after_index)) = (
        profile_position(before, profile_id),
        profile_position(after, profile_id),
    ) else {
        return false;
    };
    let (Some(before_profile), Some(after_profile)) = (
        before.profiles[before_index].as_object(),
        after.profiles[after_index].as_object(),
    ) else {
        return false;
    };
    let source_key = match variant {
        ConfigurationVariant::Primary => "customization",
        ConfigurationVariant::Landscape => "landscapeCustomization",
        ConfigurationVariant::Portrait => "portraitCustomization",
    };
    let Some(mut expected) = before_profile
        .get(source_key)
        .or_else(|| before_profile.get("customization"))
        .and_then(Value::as_object)
        .cloned()
    else {
        return false;
    };
    if variant != ConfigurationVariant::Primary {
        if let Some(color_scheme) = before_profile
            .get("customization")
            .and_then(|value| value.get("colorSchemePreference"))
        {
            expected.insert("colorSchemePreference".to_owned(), color_scheme.clone());
        }
        correct_customization_frame_orientation(&mut expected, variant);
    }

    let Some(mut groups) = saved_layer_groups(&expected) else {
        return false;
    };
    match operation {
        ConfigurationOperation::GroupCreate {
            group_id,
            name,
            element_ids,
            ..
        } => {
            let canonical_group_id = canonical_uuid_string(group_id);
            if groups.iter().any(|group| {
                group
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| id.eq_ignore_ascii_case(&canonical_group_id))
            }) {
                return false;
            }
            let children = element_ids
                .iter()
                .map(|element_id| resolve_layer_identity(&expected, element_id))
                .collect::<Option<Vec<_>>>();
            let Some(children) = children else {
                return false;
            };
            let child_keys = children
                .iter()
                .filter_map(layer_identity_key)
                .collect::<std::collections::HashSet<_>>();
            if child_keys.len() != children.len() {
                return false;
            }
            for group in &mut groups {
                let Some(saved_children) = group.get_mut("children").and_then(Value::as_array_mut)
                else {
                    return false;
                };
                saved_children.retain(|identity| {
                    layer_identity_key(identity).is_none_or(|key| !child_keys.contains(&key))
                });
            }
            groups.retain(|group| {
                group
                    .get("children")
                    .and_then(Value::as_array)
                    .is_some_and(|children| !children.is_empty())
            });
            let new_group = serde_json::json!({
                "id": canonical_group_id,
                "name": bounded_group_name(name),
                "children": children,
                "isLocked": false,
                "isHidden": false
            });
            let Some(new_group) = new_group.as_object().cloned() else {
                return false;
            };
            groups.push(new_group);
            let Some(mut order) = normalized_layer_order(&expected) else {
                return false;
            };
            let original_order = order.clone();
            let insertion_index = order
                .iter()
                .position(|identity| {
                    layer_identity_key(identity).is_some_and(|key| child_keys.contains(&key))
                })
                .unwrap_or(order.len());
            let moving = order
                .iter()
                .filter(|identity| {
                    layer_identity_key(identity).is_some_and(|key| child_keys.contains(&key))
                })
                .cloned()
                .collect::<Vec<_>>();
            order.retain(|identity| {
                layer_identity_key(identity).is_none_or(|key| !child_keys.contains(&key))
            });
            order.splice(
                insertion_index.min(order.len())..insertion_index.min(order.len()),
                moving,
            );
            if !set_expected_groups(&mut expected, groups)
                || (order != original_order && !set_expected_layer_order(&mut expected, order))
            {
                return false;
            }
        }
        ConfigurationOperation::GroupRename { group_id, name, .. } => {
            let Some(group) = group_by_id_mut(&mut groups, group_id) else {
                return false;
            };
            group.insert("name".to_owned(), Value::String(bounded_group_name(name)));
            if !set_expected_groups(&mut expected, groups) {
                return false;
            }
        }
        ConfigurationOperation::GroupDuplicate {
            group_id,
            new_group_id,
            name,
            new_element_ids,
            offset_x,
            offset_y,
            ..
        } => {
            let Some(source_group) = group_by_id(&groups, group_id).cloned() else {
                return false;
            };
            let Some(actual_customization) = after_profile
                .get(source_key)
                .or_else(|| after_profile.get("customization"))
                .and_then(Value::as_object)
            else {
                return false;
            };
            if !apply_expected_group_duplicate(
                &mut expected,
                actual_customization,
                &mut groups,
                GroupDuplicateExpectation {
                    source_group: &source_group,
                    new_group_id,
                    requested_name: name.as_deref(),
                    new_element_ids,
                    offset_x: *offset_x,
                    offset_y: *offset_y,
                },
            ) {
                return false;
            }
        }
        ConfigurationOperation::GroupUngroup { group_id, .. } => {
            let original_len = groups.len();
            groups.retain(|group| {
                !group
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| id.eq_ignore_ascii_case(group_id))
            });
            if groups.len() == original_len || !set_expected_groups(&mut expected, groups) {
                return false;
            }
        }
        ConfigurationOperation::GroupHide { group_id, .. }
        | ConfigurationOperation::GroupShow { group_id, .. }
        | ConfigurationOperation::GroupLock { group_id, .. }
        | ConfigurationOperation::GroupUnlock { group_id, .. } => {
            let (state_key, desired) = match operation {
                ConfigurationOperation::GroupHide { .. } => ("isHidden", true),
                ConfigurationOperation::GroupShow { .. } => ("isHidden", false),
                ConfigurationOperation::GroupLock { .. } => ("isLocationLocked", true),
                ConfigurationOperation::GroupUnlock { .. } => ("isLocationLocked", false),
                _ => return false,
            };
            let group_state_key = if state_key == "isHidden" {
                "isHidden"
            } else {
                "isLocked"
            };
            let Some(group) = group_by_id_mut(&mut groups, group_id) else {
                return false;
            };
            let Some(children) = group.get("children").and_then(Value::as_array).cloned() else {
                return false;
            };
            if children.is_empty()
                || children
                    .iter()
                    .any(|identity| layer_identity_key(identity).is_none())
            {
                return false;
            }
            group.insert(group_state_key.to_owned(), Value::Bool(desired));
            if !set_expected_groups(&mut expected, groups)
                || !set_group_children_layout_state(&mut expected, &children, state_key, desired)
            {
                return false;
            }
        }
        ConfigurationOperation::GroupNudge {
            group_id,
            canvas_frame_id,
            delta_x,
            delta_y,
            ..
        } => {
            let Some(group) = group_by_id(&groups, group_id) else {
                return false;
            };
            let Some(children) = group.get("children").and_then(Value::as_array) else {
                return false;
            };
            let Some(actual_customization) = after_profile
                .get(source_key)
                .or_else(|| after_profile.get("customization"))
                .and_then(Value::as_object)
            else {
                return false;
            };
            if !apply_expected_group_nudge(
                &mut expected,
                actual_customization,
                children,
                canvas_frame_id,
                *delta_x,
                *delta_y,
            ) {
                return false;
            }
        }
        ConfigurationOperation::GroupForward { group_id, .. }
        | ConfigurationOperation::GroupBackward { group_id, .. }
        | ConfigurationOperation::GroupFront { group_id, .. }
        | ConfigurationOperation::GroupBack { group_id, .. } => {
            let Some(group) = group_by_id(&groups, group_id) else {
                return false;
            };
            let Some(children) = group.get("children").and_then(Value::as_array) else {
                return false;
            };
            let child_keys = children
                .iter()
                .filter_map(layer_identity_key)
                .collect::<std::collections::HashSet<_>>();
            if child_keys.is_empty() || child_keys.len() != children.len() {
                return false;
            }
            let Some(mut order) = normalized_layer_order(&expected) else {
                return false;
            };
            reorder_group_layers(&mut order, &child_keys, operation);
            if !set_expected_layer_order(&mut expected, order) {
                return false;
            }
        }
        _ => return false,
    }

    after_profile
        .get(source_key)
        .or_else(|| after_profile.get("customization"))
        .is_some_and(|actual| json_semantically_equal(actual, &Value::Object(expected)))
}

fn saved_layer_groups(customization: &Map<String, Value>) -> Option<Vec<Map<String, Value>>> {
    match customization.get("designMetadata") {
        None | Some(Value::Null) => Some(Vec::new()),
        Some(metadata) => metadata
            .get("groups")
            .and_then(Value::as_array)
            .map(|groups| {
                groups
                    .iter()
                    .map(|group| group.as_object().cloned())
                    .collect::<Option<Vec<_>>>()
            })?,
    }
}

fn set_expected_groups(
    customization: &mut Map<String, Value>,
    groups: Vec<Map<String, Value>>,
) -> bool {
    if customization
        .get("designMetadata")
        .and_then(Value::as_object)
        .is_none()
    {
        let Some(order) = normalized_layer_order(customization) else {
            return false;
        };
        customization.insert(
            "designMetadata".to_owned(),
            serde_json::json!({
                "schemaVersion": 1,
                "layerOrder": order,
                "groups": [],
                "grid": {
                    "gridSize": 16,
                    "showsGrid": false,
                    "snapToGrid": false,
                    "snapToObjects": true,
                    "snapTolerance": 6
                },
                "guides": [],
                "tags": []
            }),
        );
    }
    let Some(metadata) = customization
        .get_mut("designMetadata")
        .and_then(Value::as_object_mut)
    else {
        return false;
    };
    metadata.insert(
        "groups".to_owned(),
        Value::Array(groups.into_iter().map(Value::Object).collect()),
    );
    true
}

fn group_by_id<'a>(groups: &'a [Map<String, Value>], id: &str) -> Option<&'a Map<String, Value>> {
    groups.iter().find(|group| {
        group
            .get("id")
            .and_then(Value::as_str)
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(id))
    })
}

fn group_by_id_mut<'a>(
    groups: &'a mut [Map<String, Value>],
    id: &str,
) -> Option<&'a mut Map<String, Value>> {
    groups.iter_mut().find(|group| {
        group
            .get("id")
            .and_then(Value::as_str)
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(id))
    })
}

fn canonical_uuid_string(value: &str) -> String {
    Uuid::parse_str(value)
        .map(|id| id.hyphenated().to_string().to_uppercase())
        .unwrap_or_else(|_| value.to_owned())
}

fn bounded_group_name(value: &str) -> String {
    value.trim().chars().take(48).collect()
}

fn set_group_children_layout_state(
    customization: &mut Map<String, Value>,
    children: &[Value],
    state_key: &str,
    desired: bool,
) -> bool {
    let mut seen = std::collections::HashSet::new();
    for child in children {
        let Some(identity) = layer_identity_key(child) else {
            return false;
        };
        if !seen.insert(identity.clone()) {
            return false;
        }
        let Some((kind, value)) = identity.split_once(':') else {
            return false;
        };
        let changed = match kind {
            "builtin" => set_builtin_layout_state(customization, value, state_key, desired),
            "custom" => set_custom_layout_state(customization, value, state_key, desired),
            "system" if value == "top_bar_activation" => {
                set_top_bar_layout_state(customization, state_key, desired)
            }
            _ => false,
        };
        if !changed {
            return false;
        }
    }
    true
}

struct GroupDuplicateExpectation<'a> {
    source_group: &'a Map<String, Value>,
    new_group_id: &'a str,
    requested_name: Option<&'a str>,
    new_element_ids: &'a [String],
    offset_x: f64,
    offset_y: f64,
}

fn apply_expected_group_duplicate(
    expected: &mut Map<String, Value>,
    actual: &Map<String, Value>,
    groups: &mut Vec<Map<String, Value>>,
    expectation: GroupDuplicateExpectation<'_>,
) -> bool {
    let GroupDuplicateExpectation {
        source_group,
        new_group_id,
        requested_name,
        new_element_ids,
        offset_x,
        offset_y,
    } = expectation;
    let Some(children) = source_group.get("children").and_then(Value::as_array) else {
        return false;
    };
    if children.is_empty() || children.len() != new_element_ids.len() {
        return false;
    }
    let canonical_group_id = canonical_uuid_string(new_group_id);
    if groups.iter().any(|group| {
        group
            .get("id")
            .and_then(Value::as_str)
            .is_some_and(|id| id.eq_ignore_ascii_case(&canonical_group_id))
    }) {
        return false;
    }
    let mut declared_ids = std::collections::HashSet::new();
    let canonical_element_ids = new_element_ids
        .iter()
        .map(|id| {
            let parsed = Uuid::parse_str(id).ok()?;
            let canonical = parsed.hyphenated().to_string().to_uppercase();
            declared_ids.insert(canonical.clone()).then_some(canonical)
        })
        .collect::<Option<Vec<_>>>();
    let Some(canonical_element_ids) = canonical_element_ids else {
        return false;
    };

    let mut custom_buttons = match expected.get("customButtons") {
        None | Some(Value::Null) => Vec::new(),
        Some(value) => match value.as_array().cloned() {
            Some(values) => values,
            None => return false,
        },
    };
    let mut elements = match expected.get("elements") {
        None | Some(Value::Null) => Vec::new(),
        Some(value) => match value.as_array().cloned() {
            Some(values) => values,
            None => return false,
        },
    };
    if custom_buttons.len() + children.len() > 128
        || custom_buttons.iter().any(|button| {
            button
                .get("id")
                .and_then(Value::as_str)
                .and_then(|id| Uuid::parse_str(id).ok())
                .is_some_and(|id| {
                    declared_ids.contains(&id.hyphenated().to_string().to_uppercase())
                })
        })
        || elements.iter().any(|element| {
            element
                .get("id")
                .and_then(Value::as_str)
                .and_then(|id| Uuid::parse_str(id).ok())
                .is_some_and(|id| {
                    declared_ids.contains(&id.hyphenated().to_string().to_uppercase())
                })
        })
    {
        return false;
    }

    let Some((canvas_width, canvas_height)) = customization_canvas_size(expected) else {
        return false;
    };
    let Some(mut order) = normalized_layer_order(expected) else {
        return false;
    };
    let mut seen_children = std::collections::HashSet::new();
    let mut duplicated_identities = Vec::with_capacity(children.len());
    let mut source_identities = Vec::with_capacity(children.len());
    let mut added_kinds = Vec::with_capacity(children.len());
    for (child, new_id) in children.iter().zip(&canonical_element_ids) {
        let Some(identity) = layer_identity_key(child) else {
            return false;
        };
        if !seen_children.insert(identity.clone()) {
            return false;
        }
        let Some((kind, value)) = identity.split_once(':') else {
            return false;
        };
        let (mut new_button, source_element) = match kind {
            "builtin" => {
                let Some(mut layout) = builtin_layout(expected, value) else {
                    return false;
                };
                layout = normalized_known_layout(layout);
                let hidden = layout
                    .get("isHidden")
                    .and_then(Value::as_bool)
                    .unwrap_or(false);
                let (center_x, center_y) = if hidden {
                    (
                        normalized_layout_center(&layout, "centerX", 0.5),
                        normalized_layout_center(&layout, "centerY", 0.5),
                    )
                } else {
                    let snapshot =
                        group_nudge_snapshot(expected, &identity, canvas_width, canvas_height);
                    match snapshot {
                        Some(snapshot) => (
                            Some(snapshot.center_x / canvas_width),
                            Some(snapshot.center_y / canvas_height),
                        ),
                        None => (None, None),
                    }
                };
                let (Some(center_x), Some(center_y)) = (center_x, center_y) else {
                    return false;
                };
                layout.insert(
                    "centerX".to_owned(),
                    Value::from((center_x + offset_x).clamp(0.0, 1.0)),
                );
                layout.insert(
                    "centerY".to_owned(),
                    Value::from((center_y + offset_y).clamp(0.0, 1.0)),
                );
                layout
                    .entry("shape".to_owned())
                    .or_insert_with(|| Value::String("rounded_rectangle".to_owned()));
                let source_element = element_for_identity(&elements, &identity)
                    .cloned()
                    .unwrap_or_else(|| Value::Object(Map::new()));
                let mut button = serde_json::json!({
                    "id": new_id,
                    "label": builtin_visual_label(expected, value),
                    "layout": layout,
                    "controlKind": "button"
                });
                if let Some(role) = source_element.get("visualRole") {
                    button["visualRole"] = role.clone();
                }
                (button, source_element)
            }
            "custom" => {
                let Some(source_button) = custom_button(expected, value) else {
                    return false;
                };
                let Some(mut button) = known_custom_button(source_button) else {
                    return false;
                };
                let Some(layout) = button.get("layout").and_then(Value::as_object).cloned() else {
                    return false;
                };
                let mut layout = normalized_known_layout(layout);
                let Some(center_x) = normalized_layout_center(&layout, "centerX", 0.5) else {
                    return false;
                };
                let Some(center_y) = normalized_layout_center(&layout, "centerY", 0.5) else {
                    return false;
                };
                layout.insert(
                    "centerX".to_owned(),
                    Value::from((center_x + offset_x).clamp(0.0, 1.0)),
                );
                layout.insert(
                    "centerY".to_owned(),
                    Value::from((center_y + offset_y).clamp(0.0, 1.0)),
                );
                normalize_duplicate_kind_layout(&mut button, &mut layout);
                button.insert("id".to_owned(), Value::String(new_id.clone()));
                button.insert("layout".to_owned(), Value::Object(layout));
                let Some(source_element) = element_for_identity(&elements, &identity) else {
                    return false;
                };
                (Value::Object(button), source_element.clone())
            }
            _ => return false,
        };
        let Some(expected_layout) = new_button.get("layout").and_then(Value::as_object).cloned()
        else {
            return false;
        };
        let Some(actual_button) = custom_button(actual, new_id) else {
            return false;
        };
        let Some(actual_layout) = actual_button.get("layout").and_then(Value::as_object) else {
            return false;
        };
        let (Some(expected_x), Some(expected_y), Some(actual_x), Some(actual_y)) = (
            expected_layout.get("centerX").and_then(Value::as_f64),
            expected_layout.get("centerY").and_then(Value::as_f64),
            actual_layout.get("centerX").and_then(Value::as_f64),
            actual_layout.get("centerY").and_then(Value::as_f64),
        ) else {
            return false;
        };
        if (expected_x - actual_x).abs() > 1e-10 || (expected_y - actual_y).abs() > 1e-10 {
            return false;
        }
        let Some(layout) = new_button.get_mut("layout").and_then(Value::as_object_mut) else {
            return false;
        };
        layout.insert("centerX".to_owned(), Value::from(actual_x));
        layout.insert("centerY".to_owned(), Value::from(actual_y));
        let Some(new_button_object) = new_button.as_object() else {
            return false;
        };
        let Some(new_element) =
            duplicate_element_from_button(new_button_object, &source_element, new_id)
        else {
            return false;
        };
        let Some(control_kind) = new_button_object.get("controlKind").and_then(Value::as_str)
        else {
            return false;
        };
        added_kinds.push(control_kind.to_owned());
        custom_buttons.push(new_button);
        elements.push(Value::Object(new_element));
        source_identities.push(child.clone());
        duplicated_identities.push(serde_json::json!({
            "kind": "custom",
            "id": new_id
        }));
    }
    if !valid_duplicate_kind_capacity(expected, &added_kinds) {
        return false;
    }

    expected.insert("customButtons".to_owned(), Value::Array(custom_buttons));
    expected.insert("elements".to_owned(), Value::Array(elements));

    let source_name = source_group
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("Group");
    let name = requested_name
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("{source_name} Copy"));
    let duplicate_group = serde_json::json!({
        "id": canonical_group_id,
        "name": name.chars().take(48).collect::<String>(),
        "children": duplicated_identities,
        "isLocked": source_group.get("isLocked").and_then(Value::as_bool).unwrap_or(false),
        "isHidden": source_group.get("isHidden").and_then(Value::as_bool).unwrap_or(false)
    });
    let Some(duplicate_group) = duplicate_group.as_object().cloned() else {
        return false;
    };
    groups.push(duplicate_group);
    if !set_expected_groups(expected, groups.clone()) {
        return false;
    }

    for (source, duplicate) in source_identities.iter().zip(&duplicated_identities) {
        let Some(source_key) = layer_identity_key(source) else {
            return false;
        };
        let Some(source_index) = order
            .iter()
            .position(|identity| layer_identity_key(identity).as_ref() == Some(&source_key))
        else {
            return false;
        };
        order.insert(source_index + 1, duplicate.clone());
    }
    set_expected_layer_order(expected, order)
}

fn known_custom_button(source: &Map<String, Value>) -> Option<Map<String, Value>> {
    let mut result = Map::new();
    for key in [
        "id",
        "label",
        "layout",
        "controlKind",
        "visualRole",
        "joystickMapping",
        "joystickOutputSettings",
        "triggerSettings",
        "trackpadSettings",
    ] {
        if let Some(value) = source.get(key) {
            result.insert(key.to_owned(), value.clone());
        }
    }
    for required in ["id", "label", "layout", "controlKind"] {
        if !result.contains_key(required) {
            return None;
        }
    }
    Some(result)
}

fn normalized_known_layout(source: Map<String, Value>) -> Map<String, Value> {
    let mut result = Map::new();
    for key in [
        "centerX",
        "centerY",
        "widthScale",
        "heightScale",
        "rotationDegrees",
        "zIndex",
        "hitInsets",
        "shape",
        "accentStyle",
        "fillColor",
        "lightFillColor",
        "darkFillColor",
        "fillStyle",
        "lightFillStyle",
        "darkFillStyle",
        "joystickKnobColor",
        "lightJoystickKnobColor",
        "darkJoystickKnobColor",
        "joystickVisualStyle",
        "styleID",
        "visualStyle",
        "icon",
        "hapticStyle",
        "hapticFeedback",
        "cornerRadius",
        "cornerRadii",
        "shadowStrength",
        "showsIntegratedLabel",
        "isLocationLocked",
        "isHidden",
    ] {
        if let Some(value) = source.get(key) {
            result.insert(key.to_owned(), value.clone());
        }
    }
    let scale = |key: &str| {
        result
            .get(key)
            .and_then(Value::as_f64)
            .unwrap_or(1.0)
            .clamp(0.001, 12.0)
    };
    let width = scale("widthScale");
    let height = scale("heightScale");
    result.insert("widthScale".to_owned(), Value::from(width));
    result.insert("heightScale".to_owned(), Value::from(height));
    let rotation = result
        .get("rotationDegrees")
        .and_then(Value::as_f64)
        .unwrap_or(0.0);
    let mut rotation = rotation % 360.0;
    if rotation > 180.0 {
        rotation -= 360.0;
    }
    if rotation <= -180.0 {
        rotation += 360.0;
    }
    if rotation.abs() < 0.001 {
        rotation = 0.0;
    }
    result.insert("rotationDegrees".to_owned(), Value::from(rotation));
    let z_index = result
        .get("zIndex")
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .clamp(-100, 100);
    result.insert("zIndex".to_owned(), Value::from(z_index));
    let shadow = result
        .get("shadowStrength")
        .and_then(Value::as_f64)
        .unwrap_or(1.0)
        .clamp(0.0, 2.0);
    result.insert("shadowStrength".to_owned(), Value::from(shadow));
    result.insert(
        "isLocationLocked".to_owned(),
        Value::Bool(
            result
                .get("isLocationLocked")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        ),
    );
    result.insert(
        "isHidden".to_owned(),
        Value::Bool(
            result
                .get("isHidden")
                .and_then(Value::as_bool)
                .unwrap_or(false),
        ),
    );
    if result
        .get("showsIntegratedLabel")
        .and_then(Value::as_bool)
        .unwrap_or(true)
    {
        result.remove("showsIntegratedLabel");
    } else {
        result.insert("showsIntegratedLabel".to_owned(), Value::Bool(false));
    }
    if result.get("joystickVisualStyle").and_then(Value::as_str) == Some("pad") {
        result.remove("joystickVisualStyle");
    }
    for key in ["centerX", "centerY"] {
        if let Some(value) = result.get(key).and_then(Value::as_f64) {
            result.insert(key.to_owned(), Value::from(value.clamp(0.0, 1.0)));
        }
    }
    result
}

fn normalize_duplicate_kind_layout(
    button: &mut Map<String, Value>,
    layout: &mut Map<String, Value>,
) {
    let kind = button
        .get("controlKind")
        .and_then(Value::as_str)
        .unwrap_or("button")
        .to_owned();
    let default_shape = match kind.as_str() {
        "joystick" => "circle",
        "trigger" => "capsule",
        "trackpad" | "button" | "decoration" => "rounded_rectangle",
        "text" => "rectangle",
        _ => "rounded_rectangle",
    };
    if kind == "joystick" || !layout.contains_key("shape") {
        layout.insert("shape".to_owned(), Value::String(default_shape.to_owned()));
    }
    match kind.as_str() {
        "joystick" => {
            if button.get("joystickOutputSettings").is_none_or(Value::is_null) {
                button.insert("joystickOutputSettings".to_owned(), serde_json::json!({
                    "analogTarget":"none", "deadZone":0.12, "sensitivity":1.0,
                    "invertX":false, "invertY":false, "sendsDigitalDirections":true, "snapToCardinal":false
                }));
            }
            button.remove("triggerSettings");
            button.remove("trackpadSettings");
        }
        "trigger" => {
            if button.get("triggerSettings").is_none_or(Value::is_null) {
                button.insert("triggerSettings".to_owned(), serde_json::json!({
                    "target":"right", "orientation":"vertical", "deadZone":0.03,
                    "sensitivity":1.0, "sendsDigitalButton":false, "digitalThreshold":0.5
                }));
            }
            button.remove("joystickMapping");
            button.remove("joystickOutputSettings");
            button.remove("trackpadSettings");
        }
        "trackpad" => {
            if button.get("trackpadSettings").is_none_or(Value::is_null) {
                button.insert("trackpadSettings".to_owned(), serde_json::json!({
                    "sensitivity":1.2, "scrollSensitivity":0.85, "naturalScrolling":true,
                    "tapToClick":true, "twoFingerScroll":true
                }));
            }
            button.remove("joystickMapping");
            button.remove("joystickOutputSettings");
            button.remove("triggerSettings");
        }
        "button" | "text" | "decoration" => {
            button.remove("joystickMapping");
            button.remove("joystickOutputSettings");
            button.remove("triggerSettings");
            button.remove("trackpadSettings");
        }
        _ => {}
    }
    if kind == "text" {
        layout.insert("shadowStrength".to_owned(), Value::from(0.0));
        layout.insert("showsIntegratedLabel".to_owned(), Value::Bool(false));
    }
}

fn element_for_identity<'a>(elements: &'a [Value], identity: &str) -> Option<&'a Value> {
    let (kind, value) = identity.split_once(':')?;
    match kind {
        "builtin" => elements.iter().find(|element| {
            element.get("kind").and_then(Value::as_str).unwrap_or("button") == "button"
                && element.get("id").and_then(Value::as_str)
                    .is_some_and(|button| button.eq_ignore_ascii_case(value))
        }),
        "custom" => {
            let expected = Uuid::parse_str(value).ok()?;
            elements.iter().find(|element| {
                element
                    .get("id")
                    .and_then(Value::as_str)
                    .and_then(|id| Uuid::parse_str(id).ok())
                    == Some(expected)
            })
        }
        _ => None,
    }
}

fn duplicate_element_from_button(
    button: &Map<String, Value>,
    source_element: &Value,
    new_id: &str,
) -> Option<Map<String, Value>> {
    let source = source_element.as_object()?;
    let kind = button.get("controlKind")?.clone();
    let kind_name = kind.as_str()?.to_owned();
    let known_fields = ["id", "label", "kind", "layout", "visualRole", "output", "defaultOutput", "partOutputs",
        "joystickMapping", "joystickOutputSettings", "triggerSettings", "trackpadSettings"];
    let mut element: Map<String, Value> = source.iter()
        .filter(|(key, _)| !known_fields.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone())).collect();
    element.insert("id".to_owned(), Value::String(new_id.to_owned()));
    element.insert("label".to_owned(), button.get("label")?.clone());
    element.insert("kind".to_owned(), kind);
    element.insert("layout".to_owned(), button.get("layout")?.clone());
    if let Some(value) = button.get("visualRole") {
        element.insert("visualRole".to_owned(), value.clone());
    }
    if !matches!(kind_name.as_str(), "text" | "decoration") {
        for key in ["output", "defaultOutput"] {
            if let Some(value) = source.get(key) {
                element.insert(key.to_owned(), value.clone());
            }
        }
        element.insert(
            "partOutputs".to_owned(),
            source
                .get("partOutputs")
                .cloned()
                .unwrap_or_else(|| Value::Array(Vec::new())),
        );
    } else {
        element.insert("partOutputs".to_owned(), Value::Array(Vec::new()));
    }
    for key in [
        "joystickMapping",
        "joystickOutputSettings",
        "triggerSettings",
        "trackpadSettings",
    ] {
        if let Some(value) = button.get(key) {
            element.insert(key.to_owned(), value.clone());
        }
    }
    Some(element)
}

fn valid_duplicate_kind_capacity(customization: &Map<String, Value>, added: &[String]) -> bool {
    let existing = customization
        .get("customButtons")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|button| button.get("controlKind").and_then(Value::as_str));
    for (kind, limit) in [("joystick", 2), ("trigger", 2), ("trackpad", 1)] {
        if existing
            .clone()
            .filter(|existing| *existing == kind)
            .count()
            + added.iter().filter(|added| added.as_str() == kind).count()
            > limit
        {
            return false;
        }
    }
    true
}

fn customization_canvas_size(customization: &Map<String, Value>) -> Option<(f64, f64)> {
    let frame_id = customization
        .get("deviceCanvas")
        .and_then(Value::as_object)
        .and_then(|canvas| canvas.get("frameID"))
        .and_then(Value::as_str)
        .unwrap_or("iphone-17-pro-landscape");
    if let Some(size) = nudge_canvas_size(frame_id) {
        return Some(size);
    }
    let value = frame_id.strip_prefix("custom-")?;
    let (dimensions, orientation) = value
        .strip_suffix("-landscape")
        .map(|value| (value, "landscape"))
        .or_else(|| {
            value
                .strip_suffix("-portrait")
                .map(|value| (value, "portrait"))
        })?;
    let (first, second) = dimensions.split_once('x')?;
    let first = first.parse::<f64>().ok()?.round().clamp(240.0, 1_800.0);
    let second = second.parse::<f64>().ok()?.round().clamp(240.0, 1_800.0);
    let portrait_width = first.min(second);
    let portrait_height = first.max(second);
    match orientation {
        "landscape" => Some((portrait_height, portrait_width)),
        "portrait" => Some((portrait_width, portrait_height)),
        _ => None,
    }
}

#[derive(Clone, Debug)]
struct GroupNudgeSnapshot {
    identity: String,
    center_x: f64,
    center_y: f64,
    width: f64,
    height: f64,
    eligible: bool,
}

fn apply_expected_group_nudge(
    expected: &mut Map<String, Value>,
    actual: &Map<String, Value>,
    children: &[Value],
    canvas_frame_id: &str,
    delta_x: f64,
    delta_y: f64,
) -> bool {
    let Some((canvas_width, canvas_height)) = nudge_canvas_size(canvas_frame_id) else {
        return false;
    };
    let mut seen = std::collections::HashSet::new();
    let mut snapshots = Vec::with_capacity(children.len());
    for child in children {
        let Some(identity) = layer_identity_key(child) else {
            return false;
        };
        if !seen.insert(identity.clone()) {
            return false;
        }
        let Some(snapshot) = group_nudge_snapshot(expected, &identity, canvas_width, canvas_height)
        else {
            return false;
        };
        snapshots.push(snapshot);
    }
    let eligible = snapshots
        .iter()
        .filter(|snapshot| snapshot.eligible)
        .collect::<Vec<_>>();
    if eligible.is_empty() {
        return false;
    }

    let min_x_offset = eligible
        .iter()
        .map(|snapshot| -(snapshot.center_x - snapshot.width / 2.0))
        .fold(f64::NEG_INFINITY, f64::max);
    let max_x_offset = eligible
        .iter()
        .map(|snapshot| canvas_width - (snapshot.center_x + snapshot.width / 2.0))
        .fold(f64::INFINITY, f64::min);
    let min_y_offset = eligible
        .iter()
        .map(|snapshot| -(snapshot.center_y - snapshot.height / 2.0))
        .fold(f64::NEG_INFINITY, f64::max);
    let max_y_offset = eligible
        .iter()
        .map(|snapshot| canvas_height - (snapshot.center_y + snapshot.height / 2.0))
        .fold(f64::INFINITY, f64::min);
    if ![min_x_offset, max_x_offset, min_y_offset, max_y_offset]
        .iter()
        .all(|value| value.is_finite())
    {
        return false;
    }
    let adjusted_x = swift_numeric_clamp(delta_x, min_x_offset, max_x_offset);
    let adjusted_y = swift_numeric_clamp(delta_y, min_y_offset, max_y_offset);
    if adjusted_x.abs() <= 0.001 && adjusted_y.abs() <= 0.001 {
        return false;
    }

    for snapshot in snapshots {
        if !snapshot.eligible {
            continue;
        }
        let expected_x = ((snapshot.center_x + adjusted_x) / canvas_width).clamp(0.0, 1.0);
        let expected_y = ((snapshot.center_y + adjusted_y) / canvas_height).clamp(0.0, 1.0);
        let Some((actual_x, actual_y)) = group_child_position(actual, &snapshot.identity) else {
            return false;
        };
        if (actual_x - expected_x).abs() > 1e-10 || (actual_y - expected_y).abs() > 1e-10 {
            return false;
        }
        if !set_group_child_position(expected, &snapshot.identity, actual_x, actual_y) {
            return false;
        }
    }
    true
}

fn swift_numeric_clamp(value: f64, lower: f64, upper: f64) -> f64 {
    value.max(lower).min(upper)
}

fn nudge_canvas_size(frame_id: &str) -> Option<(f64, f64)> {
    let catalog: Value =
        serde_json::from_str(include_str!("../../../../docs/mcp/device-frames-v1.json")).ok()?;
    let frame = catalog
        .get("frames")
        .and_then(Value::as_array)?
        .iter()
        .find(|frame| frame.get("id").and_then(Value::as_str) == Some(frame_id))?;
    let width = frame.get("width").and_then(Value::as_f64)?;
    let height = frame.get("height").and_then(Value::as_f64)?;
    (width.is_finite() && height.is_finite() && width > 1.0 && height > 1.0)
        .then_some((width, height))
}

fn group_nudge_snapshot(
    customization: &Map<String, Value>,
    identity: &str,
    canvas_width: f64,
    canvas_height: f64,
) -> Option<GroupNudgeSnapshot> {
    let (kind, value) = identity.split_once(':')?;
    let control_scale = match customization
        .get("controlScale")
        .and_then(Value::as_str)
        .unwrap_or("standard")
    {
        "compact" => 0.86,
        "standard" => 1.0,
        "large" => 1.14,
        _ => return None,
    };
    let (layout, default_center, base_size) = match kind {
        "builtin" => {
            let layout = builtin_layout(customization, value)?;
            let base_size = builtin_base_size(value, control_scale, canvas_width, canvas_height)?;
            let width = base_size.0 * normalized_layout_scale(&layout, "widthScale")?;
            let height = base_size.1 * normalized_layout_scale(&layout, "heightScale")?;
            let center = default_builtin_center(
                value,
                customization
                    .get("layoutMode")
                    .and_then(Value::as_str)
                    .unwrap_or("standard"),
                width,
                height,
                canvas_width,
                canvas_height,
            )?;
            (layout, center, base_size)
        }
        "custom" => {
            let button = custom_button(customization, value)?;
            let layout = button
                .get("layout")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_else(default_custom_layout);
            let kind = button
                .get("controlKind")
                .and_then(Value::as_str)
                .unwrap_or("button");
            let base_size = custom_base_size(
                kind,
                control_scale,
                canvas_width,
                canvas_height,
            )?;
            (layout, (0.5, 0.5), base_size)
        }
        "system" if value == "top_bar_activation" => {
            let layout = match customization.get("topBarActivationRegion") {
                None | Some(Value::Null) => default_top_bar_layout(),
                Some(value) => value.as_object()?.clone(),
            };
            (layout, (0.5, 0.115), (60.0, 44.0))
        }
        _ => return None,
    };
    let width = (base_size.0 * normalized_layout_scale(&layout, "widthScale")?).max(0.001);
    let height = (base_size.1 * normalized_layout_scale(&layout, "heightScale")?).max(0.001);
    let normalized_x = normalized_layout_center(&layout, "centerX", default_center.0)?;
    let normalized_y = normalized_layout_center(&layout, "centerY", default_center.1)?;
    let half_width = (width / 2.0).max(1.0).min(canvas_width / 2.0);
    let half_height = (height / 2.0).max(1.0).min(canvas_height / 2.0);
    let center_x = (normalized_x * canvas_width)
        .clamp(half_width, (canvas_width - half_width).max(half_width));
    let center_y = (normalized_y * canvas_height)
        .clamp(half_height, (canvas_height - half_height).max(half_height));
    let hidden = layout
        .get("isHidden")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let locked = layout
        .get("isLocationLocked")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    Some(GroupNudgeSnapshot {
        identity: identity.to_owned(),
        center_x,
        center_y,
        width,
        height,
        eligible: !hidden && !locked,
    })
}

fn normalized_layout_scale(layout: &Map<String, Value>, key: &str) -> Option<f64> {
    let value = match layout.get(key) {
        None => 1.0,
        Some(value) => value.as_f64()?,
    };
    value.is_finite().then_some(value.clamp(0.001, 12.0))
}

fn normalized_layout_center(layout: &Map<String, Value>, key: &str, default: f64) -> Option<f64> {
    let value = match layout.get(key) {
        None => default,
        Some(value) => value.as_f64()?,
    };
    value.is_finite().then_some(value.clamp(0.0, 1.0))
}

fn builtin_layout(customization: &Map<String, Value>, button: &str) -> Option<Map<String, Value>> {
    let owned_layout = customization.get("elements").and_then(Value::as_array)
        .and_then(|elements| elements.iter().find(|element| element.get("id").and_then(Value::as_str)
            .is_some_and(|id| id.eq_ignore_ascii_case(button))))
        .and_then(|element| element.get("layout")).and_then(Value::as_object).cloned()
        .unwrap_or_else(default_button_layout);
    let Some(values) = customization.get("buttonCustomizations") else {
        return Some(owned_layout);
    };
    let values = values.as_array()?;
    if values.len() % 2 != 0 {
        return None;
    }
    for pair in values.chunks_exact(2) {
        let key = pair[0].as_str()?;
        let layout = pair[1].as_object()?;
        if key.eq_ignore_ascii_case(button) {
            return Some(layout.clone());
        }
    }
    Some(owned_layout)
}

/// Builds edit/appearance mirrors only for UUIDs already declared in elements.
/// Owned outputs and unknown element metadata are never copied into a mirror.
fn materialize_declared_custom_mirrors(customization: &mut Map<String, Value>) -> bool {
    let Some(elements) = customization.get("elements").and_then(Value::as_array) else {
        return false;
    };
    let mut buttons = match customization.get("customButtons") {
        None => Vec::new(),
        Some(Value::Array(buttons)) => buttons.clone(),
        _ => return false,
    };
    let mut mirrored = buttons.iter().filter_map(|button| {
        button.get("id").and_then(Value::as_str).and_then(thumble_protocol::KeypadElementID::parse)
    }).collect::<std::collections::HashSet<_>>();
    let mut added = false;
    for element in elements {
        let Some(id) = element.get("id").and_then(Value::as_str).and_then(thumble_protocol::KeypadElementID::parse) else {
            return false;
        };
        let kind = element.get("kind").and_then(Value::as_str).unwrap_or("button");
        if (id.starter_index().is_some() && kind == "button") || !mirrored.insert(id) {
            continue;
        }
        let mut button = Map::new();
        button.insert("id".to_owned(), Value::String(id.to_string()));
        button.insert("label".to_owned(), element.get("label").cloned().unwrap_or_else(|| Value::String("Button".to_owned())));
        button.insert("controlKind".to_owned(), Value::String(kind.to_owned()));
        for field in ["visualRole", "joystickMapping", "joystickOutputSettings", "triggerSettings", "trackpadSettings"] {
            if let Some(value) = element.get(field).filter(|value| !value.is_null()) {
                button.insert(field.to_owned(), value.clone());
            }
        }
        let mut layout = normalized_known_layout(element.get("layout").and_then(Value::as_object).cloned().unwrap_or_default());
        normalize_duplicate_kind_layout(&mut button, &mut layout);
        button.insert("layout".to_owned(), Value::Object(layout));
        buttons.push(Value::Object(button));
        added = true;
    }
    if added {
        customization.insert("customButtons".to_owned(), Value::Array(buttons));
    }
    true
}

fn custom_button<'a>(
    customization: &'a Map<String, Value>,
    id: &str,
) -> Option<&'a Map<String, Value>> {
    let expected = Uuid::parse_str(id).ok()?;
    customization
        .get("customButtons")
        .and_then(Value::as_array)?
        .iter()
        .filter_map(Value::as_object)
        .find(|button| {
            button
                .get("id")
                .and_then(Value::as_str)
                .and_then(|candidate| Uuid::parse_str(candidate).ok())
                == Some(expected)
        })
}

fn default_custom_layout() -> Map<String, Value> {
    let mut layout = default_button_layout();
    layout.insert("centerX".to_owned(), Value::from(0.5));
    layout.insert("centerY".to_owned(), Value::from(0.5));
    layout.insert(
        "shape".to_owned(),
        Value::String("rounded_rectangle".to_owned()),
    );
    layout
}

fn builtin_base_size(
    button: &str,
    scale: f64,
    canvas_width: f64,
    canvas_height: f64,
) -> Option<(f64, f64)> {
    if !matches!(
        button,
        "00000000-0000-0000-0000-000000000101" | "00000000-0000-0000-0000-000000000102"
            | "00000000-0000-0000-0000-000000000103"
            | "00000000-0000-0000-0000-000000000104"
            | "00000000-0000-0000-0000-000000000105"
            | "00000000-0000-0000-0000-000000000106"
            | "00000000-0000-0000-0000-000000000107"
            | "00000000-0000-0000-0000-000000000108"
            | "00000000-0000-0000-0000-000000000109"
            | "00000000-0000-0000-0000-00000000010A"

    ) {
        return None;
    }
    let shortest = canvas_width.min(canvas_height).max(1.0);
    let factor = if canvas_width >= canvas_height {
        0.24
    } else {
        0.20
    };
    let side = (shortest * factor * scale)
        .max(50.0 * scale)
        .min(86.0 * scale);
    Some(match button {
        "00000000-0000-0000-0000-000000000109" => (side * 1.48, side * 0.72),
        "00000000-0000-0000-0000-00000000010A" => (side * 1.66, side * 0.72),
        _ => (side, side),
    })
}

fn custom_base_size(
    kind: &str,
    scale: f64,
    canvas_width: f64,
    canvas_height: f64,
) -> Option<(f64, f64)> {
    let landscape = canvas_width >= canvas_height;
    let shortest = canvas_width.min(canvas_height).max(1.0);
    match kind {
        "joystick" => {
            let side = (shortest * if landscape { 0.30 } else { 0.24 } * scale)
                .max(82.0 * scale)
                .min(128.0 * scale);
            Some((side, side))
        }
        "trigger" => Some((
            (shortest * if landscape { 0.30 } else { 0.24 } * scale)
                .max(86.0 * scale)
                .min(148.0 * scale),
            (shortest * if landscape { 0.11 } else { 0.09 } * scale)
                .max(34.0 * scale)
                .min(58.0 * scale),
        )),
        "trackpad" => Some((
            (shortest * if landscape { 0.48 } else { 0.42 } * scale)
                .max(142.0 * scale)
                .min(230.0 * scale),
            (shortest * if landscape { 0.28 } else { 0.24 } * scale)
                .max(92.0 * scale)
                .min(150.0 * scale),
        )),
        "text" => {
            let (width, height) = builtin_base_size("00000000-0000-0000-0000-000000000105", scale, canvas_width, canvas_height)?;
            Some((width, (height * 0.58).max(24.0)))
        }
        "decoration" | "button" => builtin_base_size("00000000-0000-0000-0000-000000000105", scale, canvas_width, canvas_height),
        _ => None,
    }
}

fn default_builtin_center(
    button: &str,
    layout_mode: &str,
    visual_width: f64,
    visual_height: f64,
    canvas_width: f64,
    canvas_height: f64,
) -> Option<(f64, f64)> {
    if !matches!(layout_mode, "standard" | "southpaw") {
        return None;
    }
    if canvas_width >= canvas_height {
        let x_step = ((visual_width * 1.12) / canvas_width).clamp(0.08, 0.18);
        let y_step = ((visual_height * 1.12) / canvas_height).clamp(0.10, 0.26);
        let dpad_x = if layout_mode == "standard" {
            0.18
        } else {
            0.82
        };
        let action_x = if layout_mode == "standard" {
            0.82
        } else {
            0.18
        };
        let y = 0.56;
        Some(match button {
            "00000000-0000-0000-0000-000000000101" => (dpad_x, y - y_step),
            "00000000-0000-0000-0000-000000000102" => (dpad_x, y + y_step),
            "00000000-0000-0000-0000-000000000103" => (dpad_x - x_step, y),
            "00000000-0000-0000-0000-000000000104" => (dpad_x + x_step, y),
            "00000000-0000-0000-0000-000000000108" => (action_x - x_step * 0.55, y - y_step * 0.55),
            "00000000-0000-0000-0000-000000000107" => (action_x + x_step * 0.55, y - y_step * 0.55),
            "00000000-0000-0000-0000-000000000106" => (action_x - x_step * 0.55, y + y_step * 0.55),
            "00000000-0000-0000-0000-000000000105" => (action_x + x_step * 0.55, y + y_step * 0.55),
            "00000000-0000-0000-0000-000000000109" => (0.43, y),
            "00000000-0000-0000-0000-00000000010A" => (0.57, y),
            _ if button.starts_with("custom") => (0.5, y),
            _ => return None,
        })
    } else {
        let dpad_y = if layout_mode == "standard" {
            0.28
        } else {
            0.74
        };
        let action_y = if layout_mode == "standard" {
            0.74
        } else {
            0.28
        };
        let x_step = ((visual_width * 1.16) / canvas_width).clamp(0.13, 0.22);
        let y_step = ((visual_height * 1.10) / canvas_height).clamp(0.08, 0.12);
        Some(match button {
            "00000000-0000-0000-0000-000000000101" => (0.5, dpad_y - y_step),
            "00000000-0000-0000-0000-000000000102" => (0.5, dpad_y + y_step),
            "00000000-0000-0000-0000-000000000103" => (0.5 - x_step, dpad_y),
            "00000000-0000-0000-0000-000000000104" => (0.5 + x_step, dpad_y),
            "00000000-0000-0000-0000-000000000108" => (0.5 - x_step * 0.55, action_y - y_step * 0.75),
            "00000000-0000-0000-0000-000000000107" => (0.5 + x_step * 0.55, action_y - y_step * 0.75),
            "00000000-0000-0000-0000-000000000106" => (0.5 - x_step * 0.55, action_y + y_step * 0.75),
            "00000000-0000-0000-0000-000000000105" => (0.5 + x_step * 0.55, action_y + y_step * 0.75),
            "00000000-0000-0000-0000-000000000109" => (0.36, 0.51),
            "00000000-0000-0000-0000-00000000010A" => (0.64, 0.51),
            _ if button.starts_with("custom") => (0.5, 0.51),
            _ => return None,
        })
    }
}

fn group_child_position(customization: &Map<String, Value>, identity: &str) -> Option<(f64, f64)> {
    let (kind, value) = identity.split_once(':')?;
    let layout = match kind {
        "builtin" => builtin_layout(customization, value)?,
        "custom" => custom_button(customization, value)?
            .get("layout")?
            .as_object()?
            .clone(),
        "system" if value == "top_bar_activation" => customization
            .get("topBarActivationRegion")?
            .as_object()?
            .clone(),
        _ => return None,
    };
    let x = layout.get("centerX").and_then(Value::as_f64)?;
    let y = layout.get("centerY").and_then(Value::as_f64)?;
    (x.is_finite() && y.is_finite() && (0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y))
        .then_some((x, y))
}

fn set_group_child_position(
    customization: &mut Map<String, Value>,
    identity: &str,
    x: f64,
    y: f64,
) -> bool {
    let Some((kind, value)) = identity.split_once(':') else {
        return false;
    };
    match kind {
        "builtin" => set_builtin_layout_position(customization, value, x, y),
        "custom" => set_custom_layout_position(customization, value, x, y),
        "system" if value == "top_bar_activation" => {
            let mut layout = match customization.get("topBarActivationRegion") {
                None | Some(Value::Null) => default_top_bar_layout(),
                Some(value) => match value.as_object().cloned() {
                    Some(layout) => layout,
                    None => return false,
                },
            };
            layout.insert("centerX".to_owned(), Value::from(x));
            layout.insert("centerY".to_owned(), Value::from(y));
            customization.insert("topBarActivationRegion".to_owned(), Value::Object(layout));
            true
        }
        _ => false,
    }
}

fn set_control_style_id(
    customization: &mut Map<String, Value>,
    element_id: &str,
    style_id: Option<&str>,
) -> bool {
    let Some(identity) = resolve_layer_identity(customization, element_id) else {
        return false;
    };
    let Some(identity) = layer_identity_key(&identity) else {
        return false;
    };
    let Some((kind, value)) = identity.split_once(':') else {
        return false;
    };
    match kind {
        "builtin" => set_builtin_style_id(customization, value, style_id),
        "custom" => set_custom_style_id(customization, value, style_id),
        "system" if value == "top_bar_activation" => set_top_bar_style_id(customization, style_id),
        _ => false,
    }
}

fn set_optional_style_id(layout: &mut Map<String, Value>, style_id: Option<&str>) {
    if let Some(style_id) = style_id {
        layout.insert("styleID".to_owned(), Value::String(style_id.to_owned()));
    } else {
        layout.remove("styleID");
    }
}

fn set_builtin_style_id(
    customization: &mut Map<String, Value>,
    button: &str,
    style_id: Option<&str>,
) -> bool {
    let Some(values) = customization
        .entry("buttonCustomizations".to_owned())
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
    else {
        return false;
    };
    if values.len() % 2 != 0
        || values
            .chunks_exact(2)
            .any(|pair| !pair[0].is_string() || !pair[1].is_object())
    {
        return false;
    }
    let position = values.chunks_exact(2).position(|pair| {
        pair[0]
            .as_str()
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(button))
    });
    let mut layout = position
        .and_then(|position| values[position * 2 + 1].as_object().cloned())
        .unwrap_or_else(default_button_layout);
    set_optional_style_id(&mut layout, style_id);
    if button_layout_is_default(&layout) {
        if let Some(position) = position {
            values.drain(position * 2..position * 2 + 2);
        }
    } else if let Some(position) = position {
        values[position * 2 + 1] = Value::Object(layout);
    } else {
        let order = game_button_order(button);
        let insertion = values
            .chunks_exact(2)
            .position(|pair| {
                pair[0]
                    .as_str()
                    .is_some_and(|candidate| game_button_order(candidate) > order)
            })
            .unwrap_or(values.len() / 2)
            * 2;
        values.insert(insertion, Value::String(button.to_owned()));
        values.insert(insertion + 1, Value::Object(layout));
    }
    if let Some(element) = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
        .and_then(|elements| {
            elements.iter_mut().find(|element| {
                element
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|candidate| candidate.eq_ignore_ascii_case(button))
            })
        })
    {
        let Some(layout) = element.get_mut("layout").and_then(Value::as_object_mut) else {
            return false;
        };
        set_optional_style_id(layout, style_id);
    }
    true
}

fn set_custom_style_id(
    customization: &mut Map<String, Value>,
    id: &str,
    style_id: Option<&str>,
) -> bool {
    let Some(expected_id) = Uuid::parse_str(id).ok() else {
        return false;
    };
    let Some(button) = customization
        .get_mut("customButtons")
        .and_then(Value::as_array_mut)
        .and_then(|buttons| {
            buttons.iter_mut().find(|button| {
                button
                    .get("id")
                    .and_then(Value::as_str)
                    .and_then(|candidate| Uuid::parse_str(candidate).ok())
                    == Some(expected_id)
            })
        })
    else {
        return false;
    };
    let Some(layout) = button.get_mut("layout").and_then(Value::as_object_mut) else {
        return false;
    };
    set_optional_style_id(layout, style_id);
    if let Some(element) = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
        .and_then(|elements| {
            elements.iter_mut().find(|element| {
                element
                    .get("id")
                    .and_then(Value::as_str)
                    .and_then(|candidate| Uuid::parse_str(candidate).ok())
                    == Some(expected_id)
            })
        })
    {
        let Some(layout) = element.get_mut("layout").and_then(Value::as_object_mut) else {
            return false;
        };
        set_optional_style_id(layout, style_id);
    }
    true
}

fn set_top_bar_style_id(customization: &mut Map<String, Value>, style_id: Option<&str>) -> bool {
    let mut layout = match customization.get("topBarActivationRegion") {
        None | Some(Value::Null) => default_top_bar_layout(),
        Some(value) => match value.as_object().cloned() {
            Some(layout) => layout,
            None => return false,
        },
    };
    set_optional_style_id(&mut layout, style_id);
    if top_bar_layout_is_default(&layout) {
        customization.remove("topBarActivationRegion");
    } else {
        customization.insert("topBarActivationRegion".to_owned(), Value::Object(layout));
    }
    true
}

fn set_builtin_layout_position(
    customization: &mut Map<String, Value>,
    button: &str,
    x: f64,
    y: f64,
) -> bool {
    let Some(owned_layout) = builtin_layout(customization, button) else { return false; };
    let mut owned_layout = normalized_known_layout(owned_layout);
    owned_layout.entry("shape".to_owned()).or_insert_with(|| Value::String("rounded_rectangle".to_owned()));
    let Some(values) = customization
        .entry("buttonCustomizations".to_owned())
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
    else {
        return false;
    };
    if values.len() % 2 != 0
        || values
            .chunks_exact(2)
            .any(|pair| !pair[0].is_string() || !pair[1].is_object())
    {
        return false;
    }
    let position = values.chunks_exact(2).position(|pair| {
        pair[0]
            .as_str()
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(button))
    });
    let mut layout = position
        .and_then(|position| values[position * 2 + 1].as_object().cloned())
        .unwrap_or(owned_layout);
    layout.insert("centerX".to_owned(), Value::from(x));
    layout.insert("centerY".to_owned(), Value::from(y));
    if let Some(position) = position {
        values[position * 2 + 1] = Value::Object(layout.clone());
    } else {
        let order = game_button_order(button);
        let insertion = values
            .chunks_exact(2)
            .position(|pair| {
                pair[0]
                    .as_str()
                    .is_some_and(|candidate| game_button_order(candidate) > order)
            })
            .unwrap_or(values.len() / 2)
            * 2;
        values.insert(insertion, Value::String(button.to_owned()));
        values.insert(insertion + 1, Value::Object(layout));
    }
    if let Some(elements) = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
    {
        if let Some(element) = elements.iter_mut().find(|element| {
            element
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|candidate| candidate.eq_ignore_ascii_case(button))
        }) {
            let Some(layout) = element.get_mut("layout").and_then(Value::as_object_mut) else {
                return false;
            };
            layout.insert("centerX".to_owned(), Value::from(x));
            layout.insert("centerY".to_owned(), Value::from(y));
        }
    }
    true
}

fn set_custom_layout_position(
    customization: &mut Map<String, Value>,
    id: &str,
    x: f64,
    y: f64,
) -> bool {
    let Some(expected_id) = Uuid::parse_str(id).ok() else {
        return false;
    };
    let Some(buttons) = customization
        .get_mut("customButtons")
        .and_then(Value::as_array_mut)
    else {
        return false;
    };
    let Some(button) = buttons.iter_mut().find(|button| {
        button
            .get("id")
            .and_then(Value::as_str)
            .and_then(|candidate| Uuid::parse_str(candidate).ok())
            == Some(expected_id)
    }) else {
        return false;
    };
    let Some(layout) = button.get_mut("layout").and_then(Value::as_object_mut) else {
        return false;
    };
    layout.insert("centerX".to_owned(), Value::from(x));
    layout.insert("centerY".to_owned(), Value::from(y));
    let Some(elements) = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
    else {
        return false;
    };
    let Some(element) = elements.iter_mut().find(|element| {
        element
            .get("id")
            .and_then(Value::as_str)
            .and_then(|candidate| Uuid::parse_str(candidate).ok())
            == Some(expected_id)
    }) else {
        return false;
    };
    let Some(layout) = element.get_mut("layout").and_then(Value::as_object_mut) else {
        return false;
    };
    layout.insert("centerX".to_owned(), Value::from(x));
    layout.insert("centerY".to_owned(), Value::from(y));
    true
}

fn set_builtin_layout_state(
    customization: &mut Map<String, Value>,
    button: &str,
    state_key: &str,
    desired: bool,
) -> bool {
    let owned_layout = builtin_layout(customization, button);
    let Some(values) = customization
        .entry("buttonCustomizations".to_owned())
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
    else {
        return false;
    };
    if values.len() % 2 != 0
        || values
            .chunks_exact(2)
            .any(|pair| !pair[0].is_string() || !pair[1].is_object())
    {
        return false;
    }
    let position = values.chunks_exact(2).position(|pair| {
        pair[0]
            .as_str()
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(button))
    });
    let mut layout = if let Some(position) = position {
        values[position * 2 + 1]
            .as_object()
            .cloned()
            .unwrap_or_default()
    } else {
        owned_layout.unwrap_or_else(default_button_layout)
    };
    layout.insert(state_key.to_owned(), Value::Bool(desired));
    if button_layout_is_default(&layout) {
        if let Some(position) = position {
            values.drain(position * 2..position * 2 + 2);
        }
    } else if let Some(position) = position {
        values[position * 2 + 1] = Value::Object(layout.clone());
    } else {
        let order = game_button_order(button);
        let insertion = values
            .chunks_exact(2)
            .position(|pair| {
                pair[0]
                    .as_str()
                    .is_some_and(|candidate| game_button_order(candidate) > order)
            })
            .unwrap_or(values.len() / 2)
            * 2;
        values.insert(insertion, Value::String(button.to_owned()));
        values.insert(insertion + 1, Value::Object(layout.clone()));
    }

    set_builtin_element_layout_state(customization, button, state_key, desired, &layout)
}

fn set_builtin_element_layout_state(
    customization: &mut Map<String, Value>,
    button: &str,
    state_key: &str,
    desired: bool,
    button_layout: &Map<String, Value>,
) -> bool {
    let label = builtin_visual_label(customization, button);
    let elements = customization
        .entry("elements".to_owned())
        .or_insert_with(|| Value::Array(Vec::new()));
    let Some(elements) = elements.as_array_mut() else {
        return false;
    };
    let position = elements.iter().position(|element| {
        element
            .get("id")
            .and_then(Value::as_str)
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(button))
    });
    if let Some(position) = position {
        let Some(layout) = elements[position]
            .get_mut("layout")
            .and_then(Value::as_object_mut)
        else {
            return false;
        };
        layout.insert(state_key.to_owned(), Value::Bool(desired));
    } else if state_key == "isHidden" && !desired {
        let Some(id) = builtin_element_id(button) else {
            return false;
        };
        let mut layout = button_layout.clone();
        if !layout.contains_key("shape") {
            layout.insert(
                "shape".to_owned(),
                Value::String("rounded_rectangle".to_owned()),
            );
        }
        // Explicit starter construction (Show Default Controls), never an
        // execution fallback or a slot assigned to a different control.
        let starter = thumble_core::minimal_default_customization();
        let Some(prototype) = starter.get("elements").and_then(Value::as_array).and_then(|elements|
            elements.iter().find(|element| element.get("id").and_then(Value::as_str).is_some_and(|candidate| candidate.eq_ignore_ascii_case(&id)))
        ) else { return false; };
        let Some(output) = prototype.get("defaultOutput") else { return false; };
        let element = serde_json::json!({
            "id": id,
            "label": label,
            "kind": "button",
            "visualRole": prototype["visualRole"],
            "layout": layout,
            "output": output,
            "defaultOutput": output,
            "partOutputs": []
        });
        let insertion = elements
            .iter()
            .position(|candidate| {
                candidate
                    .get("id")
                    .and_then(Value::as_str)
                    .is_none_or(|candidate| {
                        game_button_order(candidate) > game_button_order(button)
                    })
            })
            .unwrap_or(elements.len());
        elements.insert(insertion, element);
    }
    true
}

fn set_custom_layout_state(
    customization: &mut Map<String, Value>,
    id: &str,
    state_key: &str,
    desired: bool,
) -> bool {
    let Some(buttons) = customization
        .get_mut("customButtons")
        .and_then(Value::as_array_mut)
    else {
        return false;
    };
    let Some(button) = buttons.iter_mut().find(|button| {
        button
            .get("id")
            .and_then(Value::as_str)
            .and_then(|candidate| Uuid::parse_str(candidate).ok())
            .is_some_and(|candidate| candidate.hyphenated().to_string().eq_ignore_ascii_case(id))
    }) else {
        return false;
    };
    let Some(layout) = button.get_mut("layout").and_then(Value::as_object_mut) else {
        return false;
    };
    layout.insert(state_key.to_owned(), Value::Bool(desired));

    let Some(elements) = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
    else {
        return false;
    };
    let Some(element) = elements.iter_mut().find(|element| {
        element
            .get("id")
            .and_then(Value::as_str)
            .and_then(|candidate| Uuid::parse_str(candidate).ok())
            .is_some_and(|candidate| candidate.hyphenated().to_string().eq_ignore_ascii_case(id))
    }) else {
        return false;
    };
    let Some(layout) = element.get_mut("layout").and_then(Value::as_object_mut) else {
        return false;
    };
    layout.insert(state_key.to_owned(), Value::Bool(desired));
    true
}

fn set_top_bar_layout_state(
    customization: &mut Map<String, Value>,
    state_key: &str,
    desired: bool,
) -> bool {
    let mut layout = match customization.get("topBarActivationRegion") {
        None | Some(Value::Null) => default_top_bar_layout(),
        Some(value) => {
            let Some(layout) = value.as_object().cloned() else {
                return false;
            };
            layout
        }
    };
    layout.insert(state_key.to_owned(), Value::Bool(desired));
    if top_bar_layout_is_default(&layout) {
        customization.remove("topBarActivationRegion");
    } else {
        customization.insert("topBarActivationRegion".to_owned(), Value::Object(layout));
    }
    true
}

fn default_button_layout() -> Map<String, Value> {
    serde_json::json!({
        "widthScale": 1,
        "heightScale": 1,
        "rotationDegrees": 0,
        "zIndex": 0,
        "shadowStrength": 1,
        "isLocationLocked": false,
        "isHidden": false
    })
    .as_object()
    .cloned()
    .unwrap_or_default()
}

fn button_layout_is_default(layout: &Map<String, Value>) -> bool {
    json_semantically_equal(
        &Value::Object(layout.clone()),
        &Value::Object(default_button_layout()),
    )
}

fn default_top_bar_layout() -> Map<String, Value> {
    serde_json::json!({
        "centerX": 0.5,
        "centerY": 0.115,
        "widthScale": 1,
        "heightScale": 1,
        "rotationDegrees": 0,
        "zIndex": 100,
        "shape": "capsule",
        "accentStyle": "blue",
        "icon": {
            "source": "sf_symbol",
            "value": "chevron.down",
            "renderingMode": "template",
            "placement": "center",
            "scale": 1
        },
        "cornerRadius": 18,
        "shadowStrength": 0.35,
        "isLocationLocked": false,
        "isHidden": false
    })
    .as_object()
    .cloned()
    .unwrap_or_default()
}

fn top_bar_layout_is_default(layout: &Map<String, Value>) -> bool {
    json_semantically_equal(
        &Value::Object(layout.clone()),
        &Value::Object(default_top_bar_layout()),
    )
}

fn builtin_element_id(button: &str) -> Option<String> {
    let id = thumble_protocol::KeypadElementID::parse(button)?;
    id.starter_index()?;
    Some(id.to_string())
}

fn builtin_visual_label(customization: &Map<String, Value>, button: &str) -> String {
    if let Some(labels) = customization
        .get("labelOverrides")
        .and_then(Value::as_array)
    {
        for pair in labels.chunks_exact(2) {
            if pair[0]
                .as_str()
                .is_some_and(|candidate| candidate.eq_ignore_ascii_case(button))
            {
                if let Some(label) = pair[1].as_str() {
                    return label.to_owned();
                }
            }
        }
    }
    match button {
        "00000000-0000-0000-0000-000000000101" => "↑",
        "00000000-0000-0000-0000-000000000102" => "↓",
        "00000000-0000-0000-0000-000000000103" => "←",
        "00000000-0000-0000-0000-000000000104" => "→",
        "00000000-0000-0000-0000-000000000105" => "A",
        "00000000-0000-0000-0000-000000000106" => "B",
        "00000000-0000-0000-0000-000000000107" => "C",
        "00000000-0000-0000-0000-000000000108" => "D",
        "00000000-0000-0000-0000-000000000109" => "⇧⌘P",
        "00000000-0000-0000-0000-00000000010A" => "Esc",
        _ => "Button",
    }
    .to_owned()
}

fn game_button_order(button: &str) -> usize {
    thumble_protocol::KeypadElementID::parse(button).and_then(|id| id.starter_index()).map(|i| i - 1).unwrap_or(usize::MAX)
}

fn reorder_group_layers(
    order: &mut Vec<Value>,
    selected: &std::collections::HashSet<String>,
    operation: &ConfigurationOperation,
) {
    let selected_at =
        |identity: &Value| layer_identity_key(identity).is_some_and(|key| selected.contains(&key));
    let moving = order
        .iter()
        .filter(|identity| selected_at(identity))
        .cloned()
        .collect::<Vec<_>>();
    if moving.is_empty() {
        return;
    }
    match operation {
        ConfigurationOperation::GroupForward { .. } => {
            let Some(last_selected) = order.iter().rposition(&selected_at) else {
                return;
            };
            let Some(next_unselected) = order
                .iter()
                .enumerate()
                .find(|(index, identity)| *index > last_selected && !selected_at(identity))
                .map(|(index, _)| index)
            else {
                return;
            };
            let next_key = layer_identity_key(&order[next_unselected]);
            order.retain(|identity| !selected_at(identity));
            let Some(next_index) = next_key.and_then(|key| {
                order
                    .iter()
                    .position(|identity| layer_identity_key(identity).as_ref() == Some(&key))
            }) else {
                return;
            };
            order.splice((next_index + 1)..(next_index + 1), moving);
        }
        ConfigurationOperation::GroupBackward { .. } => {
            let Some(first_selected) = order.iter().position(&selected_at) else {
                return;
            };
            let Some(previous_unselected) = order
                .iter()
                .enumerate()
                .rev()
                .find(|(index, identity)| *index < first_selected && !selected_at(identity))
                .map(|(index, _)| index)
            else {
                return;
            };
            let previous_key = layer_identity_key(&order[previous_unselected]);
            order.retain(|identity| !selected_at(identity));
            let Some(previous_index) = previous_key.and_then(|key| {
                order
                    .iter()
                    .position(|identity| layer_identity_key(identity).as_ref() == Some(&key))
            }) else {
                return;
            };
            order.splice(previous_index..previous_index, moving);
        }
        ConfigurationOperation::GroupFront { .. } => {
            order.retain(|identity| !selected_at(identity));
            order.extend(moving);
        }
        ConfigurationOperation::GroupBack { .. } => {
            order.retain(|identity| !selected_at(identity));
            order.splice(0..0, moving);
        }
        _ => {}
    }
}

fn available_layer_identities(customization: &Map<String, Value>) -> Option<Vec<Value>> {
    let mut identities = vec![serde_json::json!({
        "kind": "system",
        "system": "top_bar_activation"
    })];
    for button in customization
        .get("elements")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let id = button.get("id").and_then(Value::as_str)?;
        let canonical = Uuid::parse_str(id)
            .ok()?
            .hyphenated()
            .to_string()
            .to_uppercase();
        let starter = thumble_protocol::KeypadElementID::parse(&canonical).and_then(|id| id.starter_index()).is_some()
            && button.get("kind").and_then(Value::as_str).unwrap_or("button") == "button";
        identities.push(if starter {
            serde_json::json!({"kind": "builtin", "button": canonical})
        } else {
            serde_json::json!({"kind": "custom", "id": canonical})
        });
    }
    let mut seen = std::collections::HashSet::new();
    if identities
        .iter()
        .all(|identity| layer_identity_key(identity).is_some_and(|key| seen.insert(key)))
    {
        Some(identities)
    } else {
        None
    }
}

fn layer_identity_key(identity: &Value) -> Option<String> {
    if let Some(raw) = identity.as_str() {
        let lower = raw.to_ascii_lowercase();
        if let Some(button) = lower.strip_prefix("builtin.") {
            return is_builtin_layer_button(button).then(|| format!("builtin:{button}"));
        }
        if let Some(id) = lower.strip_prefix("custom.") {
            return Uuid::parse_str(id)
                .ok()
                .map(|id| format!("custom:{}", id.hyphenated()));
        }
        if let Some(system) = lower.strip_prefix("system.") {
            return (system == "top_bar_activation").then(|| format!("system:{system}"));
        }
        if is_builtin_layer_button(&lower) {
            return Some(format!("builtin:{lower}"));
        }
        if lower == "top_bar_activation" {
            return Some("system:top_bar_activation".to_owned());
        }
        return Uuid::parse_str(&lower)
            .ok()
            .map(|id| format!("custom:{}", id.hyphenated()));
    }
    let object = identity.as_object()?;
    let kind = object.get("kind")?.as_str()?;
    match kind {
        "builtin" => {
            let button = object.get("button")?.as_str()?;
            is_builtin_layer_button(button).then(|| format!("builtin:{}", button.to_ascii_lowercase()))
        }
        "custom" => {
            let id = Uuid::parse_str(object.get("id")?.as_str()?).ok()?;
            Some(format!("custom:{}", id.hyphenated()))
        }
        "system" => {
            let system = object
                .get("system")
                .or_else(|| object.get("id"))?
                .as_str()?;
            (system == "top_bar_activation").then(|| format!("system:{system}"))
        }
        _ => None,
    }
}

fn is_builtin_layer_button(value: &str) -> bool {
    thumble_protocol::KeypadElementID::parse(value).and_then(|id| id.starter_index()).is_some()
}

fn resolve_layer_identity(customization: &Map<String, Value>, input: &str) -> Option<Value> {
    let available = available_layer_identities(customization)?;
    if let Ok(id) = Uuid::parse_str(input) {
        return available.into_iter().find(|identity| {
            identity.get("id").or_else(|| identity.get("button"))
                .and_then(Value::as_str).and_then(|value| Uuid::parse_str(value).ok()) == Some(id)
        });
    }
    let input_key = layer_identity_key(&Value::String(input.to_owned()))?;
    available
        .into_iter()
        .find(|identity| layer_identity_key(identity).as_deref() == Some(input_key.as_str()))
}

fn normalized_layer_order(customization: &Map<String, Value>) -> Option<Vec<Value>> {
    let available = available_layer_identities(customization)?;
    let lookup = available
        .iter()
        .filter_map(|identity| layer_identity_key(identity).map(|key| (key, identity.clone())))
        .collect::<std::collections::HashMap<_, _>>();
    let mut seen = std::collections::HashSet::new();
    let mut order = Vec::with_capacity(available.len());
    if let Some(saved) = customization
        .get("designMetadata")
        .and_then(|metadata| metadata.get("layerOrder"))
        .and_then(Value::as_array)
    {
        for identity in saved {
            let Some(key) = layer_identity_key(identity) else {
                continue;
            };
            if seen.insert(key.clone()) {
                if let Some(canonical) = lookup.get(&key) {
                    order.push(canonical.clone());
                }
            }
        }
    }
    for identity in available {
        let key = layer_identity_key(&identity)?;
        if seen.insert(key) {
            order.push(identity);
        }
    }
    Some(order)
}

fn layer_order_position(order: &[Value], target: &Value) -> Option<usize> {
    let key = layer_identity_key(target)?;
    order
        .iter()
        .position(|identity| layer_identity_key(identity).as_ref() == Some(&key))
}

fn set_expected_layer_order(customization: &mut Map<String, Value>, order: Vec<Value>) -> bool {
    let Some(available) = available_layer_identities(customization) else {
        return false;
    };
    let is_default_order = layer_orders_have_same_identities(&order, &available);
    if is_default_order
        && customization
            .get("designMetadata")
            .and_then(Value::as_object)
            .is_none_or(|metadata| {
                metadata_is_default_except_layer_order(metadata)
                    && !metadata_has_unknown_fields(metadata)
            })
    {
        customization.remove("designMetadata");
        return true;
    }
    let raw_by_identity = customization
        .get("designMetadata")
        .and_then(|metadata| metadata.get("layerOrder"))
        .and_then(Value::as_array)
        .map(|saved| {
            saved
                .iter()
                .filter_map(|identity| {
                    layer_identity_key(identity).map(|key| (key, identity.clone()))
                })
                .collect::<std::collections::HashMap<_, _>>()
        })
        .unwrap_or_default();
    let merged_order = order
        .into_iter()
        .map(|canonical| {
            let Some(key) = layer_identity_key(&canonical) else {
                return canonical;
            };
            let Some(raw) = raw_by_identity.get(&key).and_then(Value::as_object) else {
                return canonical;
            };
            let Some(canonical_object) = canonical.as_object() else {
                return canonical;
            };
            let mut merged = raw.clone();
            for identity_key in ["kind", "button", "id", "system", "controlBarItem"] {
                merged.remove(identity_key);
            }
            merged.extend(canonical_object.clone());
            Value::Object(merged)
        })
        .collect::<Vec<_>>();
    if let Some(metadata) = customization
        .get_mut("designMetadata")
        .and_then(Value::as_object_mut)
    {
        metadata.insert("layerOrder".to_owned(), Value::Array(merged_order));
        return true;
    }
    customization.insert(
        "designMetadata".to_owned(),
        serde_json::json!({
            "schemaVersion": 1,
            "layerOrder": merged_order,
            "groups": [],
            "grid": {
                "gridSize": 16,
                "showsGrid": false,
                "snapToGrid": false,
                "snapToObjects": true,
                "snapTolerance": 6
            },
            "guides": [],
            "tags": []
        }),
    );
    true
}

fn layer_orders_have_same_identities(left: &[Value], right: &[Value]) -> bool {
    left.len() == right.len()
        && left
            .iter()
            .zip(right)
            .all(|(left, right)| layer_identity_key(left) == layer_identity_key(right))
}

fn metadata_has_unknown_fields(metadata: &Map<String, Value>) -> bool {
    const KNOWN_METADATA_KEYS: [&str; 9] = [
        "schemaVersion",
        "layerOrder",
        "groups",
        "grid",
        "guides",
        "notes",
        "tags",
        "sourceTemplateID",
        "sourceTemplateRevision",
    ];
    if metadata
        .keys()
        .any(|key| !KNOWN_METADATA_KEYS.contains(&key.as_str()))
    {
        return true;
    }
    if metadata
        .get("grid")
        .and_then(Value::as_object)
        .is_some_and(|grid| {
            grid.keys().any(|key| {
                ![
                    "gridSize",
                    "showsGrid",
                    "snapToGrid",
                    "snapToObjects",
                    "snapTolerance",
                ]
                .contains(&key.as_str())
            })
        })
    {
        return true;
    }
    metadata
        .get("layerOrder")
        .and_then(Value::as_array)
        .is_some_and(|order| {
            order.iter().any(|identity| {
                let Some(identity) = identity.as_object() else {
                    return false;
                };
                identity.keys().any(|key| {
                    !["kind", "button", "id", "system", "controlBarItem"].contains(&key.as_str())
                })
            })
        })
}

fn metadata_is_default_except_layer_order(metadata: &Map<String, Value>) -> bool {
    metadata
        .get("schemaVersion")
        .and_then(Value::as_i64)
        .is_none_or(|version| version <= 1)
        && metadata
            .get("groups")
            .and_then(Value::as_array)
            .is_none_or(Vec::is_empty)
        && metadata
            .get("guides")
            .and_then(Value::as_array)
            .is_none_or(Vec::is_empty)
        && metadata
            .get("tags")
            .and_then(Value::as_array)
            .is_none_or(Vec::is_empty)
        && metadata
            .get("notes")
            .and_then(Value::as_str)
            .is_none_or(|value| value.trim().is_empty())
        && metadata
            .get("sourceTemplateID")
            .and_then(Value::as_str)
            .is_none_or(|value| value.trim().is_empty())
        && metadata.get("sourceTemplateRevision").is_none()
        && metadata.get("grid").is_none_or(|grid| {
            grid == &serde_json::json!({
                "gridSize": 16,
                "showsGrid": false,
                "snapToGrid": false,
                "snapToObjects": true,
                "snapTolerance": 6
            })
        })
}

fn json_semantically_equal(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::Number(left), Value::Number(right)) => {
            // Cross integer/float spelling is equivalent only inside the exact
            // binary64 integer range. Never round distinct extension integers
            // into equality when checking an otherwise constrained mutation.
            if left == right { return true; }
            const MAX_EXACT_INTEGER: u64 = 9_007_199_254_740_991;
            let exact = |number: &serde_json::Number| {
                number.as_i64().is_none_or(|value| value.unsigned_abs() <= MAX_EXACT_INTEGER)
                    && number.as_u64().is_none_or(|value| value <= MAX_EXACT_INTEGER)
            };
            exact(left) && exact(right) && left.as_f64() == right.as_f64()
        },
        (Value::Array(left), Value::Array(right)) => {
            left.len() == right.len()
                && left
                    .iter()
                    .zip(right)
                    .all(|(left, right)| json_semantically_equal(left, right))
        }
        (Value::Object(left), Value::Object(right)) => {
            left.len() == right.len()
                && left.iter().all(|(key, left)| {
                    right
                        .get(key)
                        .is_some_and(|right| json_semantically_equal(left, right))
                })
        }
        _ => left == right,
    }
}

fn set_serialized<T: serde::Serialize>(target: &mut Map<String, Value>, key: &str, value: T) {
    if let Ok(value) = serde_json::to_value(value) {
        target.insert(key.to_owned(), value);
    }
}

fn correct_customization_frame_orientation(
    customization: &mut Map<String, Value>,
    variant: crate::draft_operation::ConfigurationVariant,
) {
    let orientation = match variant {
        crate::draft_operation::ConfigurationVariant::Landscape => "landscape",
        crate::draft_operation::ConfigurationVariant::Portrait => "portrait",
        crate::draft_operation::ConfigurationVariant::Primary => return,
    };
    let frame_id = customization
        .get("deviceCanvas")
        .and_then(Value::as_object)
        .and_then(|canvas| canvas.get("frameID"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    if frame_id.is_none() && !customization.contains_key("deviceCanvas") {
        // Swift decodes an absent canvas as the canonical landscape frame and
        // omits that default again when it encodes the transformed profile.
        // Only a portrait edit must materialize an explicit frame.
        if variant == crate::draft_operation::ConfigurationVariant::Portrait {
            customization.insert(
                "deviceCanvas".to_owned(),
                serde_json::json!({"frameID": format!("iphone-17-pro-{orientation}")}),
            );
        }
        return;
    }
    let Some(base) = frame_id.as_deref().and_then(|frame_id| {
        frame_id
            .strip_suffix("-landscape")
            .or_else(|| frame_id.strip_suffix("-portrait"))
    }) else {
        return;
    };
    if let Some(canvas) = customization
        .get_mut("deviceCanvas")
        .and_then(Value::as_object_mut)
    {
        canvas.insert(
            "frameID".to_owned(),
            Value::String(format!("{base}-{orientation}")),
        );
    }
}

fn ensure_expected_control_bar_items(customization: &mut Map<String, Value>) {
    if !customization.contains_key("controlBarItems") {
        customization.insert(
            "controlBarItems".to_owned(),
            serde_json::json!([
                "status",
                "profile_menu",
                "launch_target",
                "spacer",
                "edit_layout",
                "settings",
                "home",
                "connection"
            ]),
        );
    }
}

fn retain_control_bar_customizations(
    customization: &mut Map<String, Value>,
    items: &[crate::draft_operation::ConfigurationControlBarItem],
) {
    let allowed = items
        .iter()
        .filter_map(|item| serde_json::to_value(item).ok())
        .collect::<Vec<_>>();
    if let Some(customizations) = customization
        .get_mut("controlBarItemCustomizations")
        .and_then(Value::as_array_mut)
    {
        customizations.retain(|value| value.get("item").is_some_and(|item| allowed.contains(item)));
    }
}

fn items_for_values(values: &[Value]) -> Vec<crate::draft_operation::ConfigurationControlBarItem> {
    values
        .iter()
        .filter_map(|value| serde_json::from_value(value.clone()).ok())
        .collect()
}

fn exact_binding_output_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    operation: &ConfigurationOperation,
) -> bool {
    let profile_id = match operation {
        ConfigurationOperation::BindingSet { profile_id, .. }
        | ConfigurationOperation::BindingClear { profile_id, .. }
        | ConfigurationOperation::BindingReset { profile_id, .. }
        | ConfigurationOperation::BindingResetAll { profile_id }
        | ConfigurationOperation::OutputMode { profile_id, .. }
        | ConfigurationOperation::OutputSet { profile_id, .. }
        | ConfigurationOperation::OutputReset { profile_id, .. }
        | ConfigurationOperation::OutputResetAll { profile_id } => profile_id,
        _ => return false,
    };
    let Some(profile_index) = profile_position(before, profile_id) else {
        return false;
    };
    let Some(before_profile) = before.profiles.get(profile_index) else {
        return false;
    };
    // Missing maps derive solely from the target profile's declared controls.
    let mut fallback_outputs = thumble_core::profile_owned_outputs(before_profile);
    let mut fallback_keys = ButtonBindings::default();
    for (id, output) in fallback_outputs.iter_ids() {
        if let Some(keyboard) = &output.keyboard {
            fallback_keys.insert(id, keyboard.clone());
        }
    }
    let before_keys =
        profile_binding_for(&before.profile_key_bindings, profile_id).unwrap_or(&fallback_keys);
    apply_binding_mode_outputs(binding_profile_mode(before_profile).unwrap_or(crate::draft_operation::ConfigurationOutputMode::Keyboard), before_keys, &mut fallback_outputs);
    let before_outputs = profile_binding_for(&before.profile_output_bindings, profile_id)
        .unwrap_or(&fallback_outputs);
    let (Some(after_keys), Some(after_outputs)) = (
        profile_binding_for(&after.profile_key_bindings, profile_id),
        profile_binding_for(&after.profile_output_bindings, profile_id),
    ) else {
        return false;
    };
    // Mirror native mutation: reconcile stored sidecars with explicit owned
    // configurations before editing, while preserving independent gamepad outputs.
    let mut expected_outputs = before_outputs.clone();
    for (id, output) in thumble_core::profile_configured_outputs(before_profile).iter_ids() {
        expected_outputs.insert(id, output.clone());
    }
    let mut expected_keys = ButtonBindings::default();
    for (id, output) in expected_outputs.iter_ids() {
        if let Some(keyboard) = &output.keyboard { expected_keys.insert(id, keyboard.clone()); }
    }
    let Some(mut expected_mode) = binding_profile_mode(before_profile) else {
        return false;
    };
    match operation {
        ConfigurationOperation::BindingSet {
            button, sequence, ..
        } => {
            let Some(binding) = resolved_semantic_binding(sequence) else {
                return false;
            };
            expected_keys.insert(*button, binding);
            apply_binding_mode_outputs(expected_mode, &expected_keys, &mut expected_outputs);
        }
        ConfigurationOperation::BindingClear { button, .. } => {
            expected_keys.remove(*button);
            apply_binding_mode_outputs(expected_mode, &expected_keys, &mut expected_outputs);
        }
        ConfigurationOperation::BindingReset { button, .. } => {
            let recommended = recommended_outputs(before_profile);
            match recommended
                .get(button)
                .and_then(|output| output.keyboard.clone())
            {
                Some(binding) => {
                    expected_keys.insert(*button, binding);
                }
                None => {
                    expected_keys.remove(*button);
                }
            }
            apply_binding_mode_outputs(expected_mode, &expected_keys, &mut expected_outputs);
        }
        ConfigurationOperation::BindingResetAll { .. } => {
            let recommended = recommended_outputs(before_profile);
            replace_recognized_keys(&mut expected_keys, &recommended);
            apply_binding_mode_outputs(expected_mode, &expected_keys, &mut expected_outputs);
        }
        ConfigurationOperation::OutputMode { mode, .. } => {
            expected_mode = *mode;
            apply_output_mode_outputs(expected_mode, &expected_keys, &mut expected_outputs);
        }
        ConfigurationOperation::OutputSet {
            button,
            keyboard_edit,
            gamepad_edit,
            ..
        } => {
            let original = expected_outputs.get(button).cloned();
            let mut output = original.clone().unwrap_or_default();
            match keyboard_edit {
                crate::draft_operation::KeyboardOutputEdit::Keep => {}
                crate::draft_operation::KeyboardOutputEdit::Clear => output.keyboard = None,
                crate::draft_operation::KeyboardOutputEdit::Set { sequence } => {
                    let Some(binding) = resolved_semantic_binding(sequence) else {
                        return false;
                    };
                    output.keyboard = Some(binding);
                }
            }
            match gamepad_edit {
                crate::draft_operation::GamepadOutputEdit::Keep => {}
                crate::draft_operation::GamepadOutputEdit::Clear => {
                    output.gamepad_buttons.clear();
                }
                crate::draft_operation::GamepadOutputEdit::Set { button } => {
                    output.gamepad_buttons.clear();
                    let Some(name) = configuration_gamepad_name(*button) else {
                        return false;
                    };
                    output.gamepad_buttons.insert(name.to_owned());
                }
            }
            if matches!(
                keyboard_edit,
                crate::draft_operation::KeyboardOutputEdit::Keep
            ) && output.keyboard.is_none()
                && !output.gamepad_buttons.is_empty()
            {
                output.keyboard = expected_keys.get(button).cloned();
            }
            // An explicit clear must remain present rather than exposing defaults.
            expected_outputs.insert(*button, output.clone());
            if expected_outputs.get(button) != original.as_ref() {
                match output.keyboard {
                    Some(binding) => {
                        expected_keys.insert(*button, binding);
                    }
                    None => {
                        expected_keys.remove(*button);
                    }
                }
            }
            expected_mode = crate::draft_operation::ConfigurationOutputMode::Custom;
        }
        ConfigurationOperation::OutputReset { button, .. } => {
            let original = expected_outputs.get(button).cloned();
            let recommended = recommended_outputs(before_profile);
            match recommended.get(button).cloned() {
                Some(output) => {
                    expected_outputs.insert(*button, output);
                }
                None => {
                    expected_outputs.remove(*button);
                }
            }
            if expected_outputs.get(button) != original.as_ref() {
                match expected_outputs
                    .get(button)
                    .and_then(|output| output.keyboard.clone())
                {
                    Some(binding) => {
                        expected_keys.insert(*button, binding);
                    }
                    None => {
                        expected_keys.remove(*button);
                    }
                }
            }
            expected_mode = crate::draft_operation::ConfigurationOutputMode::Custom;
        }
        ConfigurationOperation::OutputResetAll { .. } => {
            let recommended = recommended_outputs(before_profile);
            replace_recognized_outputs(&mut expected_outputs, &recommended);
            replace_recognized_keys(&mut expected_keys, &recommended);
            expected_mode = crate::draft_operation::ConfigurationOutputMode::Keyboard;
        }
        _ => return false,
    }
    if after_keys != &expected_keys || after_outputs != &expected_outputs {
        return false;
    }
    let Some(after_index) = profile_position(after, profile_id) else {
        return false;
    };
    let Some(after_profile) = after.profiles.get(after_index) else {
        return false;
    };
    binding_profile_sync_is_exact(
        before_profile,
        after_profile,
        expected_mode,
        &expected_outputs,
    )
}

fn binding_profile_mode(
    profile: &Value,
) -> Option<crate::draft_operation::ConfigurationOutputMode> {
    match profile
        .get("outputMode")
        .and_then(Value::as_str)
        .unwrap_or("keyboard")
    {
        "keyboard" => Some(crate::draft_operation::ConfigurationOutputMode::Keyboard),
        "controller" => Some(crate::draft_operation::ConfigurationOutputMode::Controller),
        "custom" => Some(crate::draft_operation::ConfigurationOutputMode::Custom),
        _ => None,
    }
}

fn resolved_semantic_binding(
    sequence: &[crate::draft_operation::SemanticKeyStroke],
) -> Option<KeyBinding> {
    let strokes = sequence
        .iter()
        .map(crate::draft_operation::resolve_stroke)
        .collect::<Result<Vec<_>, _>>()
        .ok()?;
    KeyBinding::from_strokes(strokes)
}

fn apply_binding_mode_outputs(_mode: crate::draft_operation::ConfigurationOutputMode, keys: &ButtonBindings<KeyBinding>, outputs: &mut ButtonBindings<OutputBinding>) {
    let ids = outputs.iter().map(|(id, _)| id).chain(keys.iter().map(|(id, _)| id))
        .filter_map(thumble_protocol::KeypadElementID::parse).collect::<std::collections::BTreeSet<_>>();
    for id in ids {
        let mut output = outputs.get(&id).cloned().unwrap_or_default();
        output.keyboard = keys.get(&id).cloned();
        outputs.insert(id, output);
    }
}

fn apply_output_mode_outputs(_mode: crate::draft_operation::ConfigurationOutputMode, keys: &ButtonBindings<KeyBinding>, outputs: &mut ButtonBindings<OutputBinding>) {
    for (raw_id, binding) in keys.iter() {
        let id = thumble_protocol::KeypadElementID::parse(raw_id).unwrap();
        if outputs.get(&id).is_none() { outputs.insert(id, OutputBinding::keyboard(binding.clone())); }
    }
}

const fn configuration_gamepad_name(
    button: crate::draft_operation::ConfigurationGamepadButton,
) -> Option<&'static str> {
    use crate::draft_operation::ConfigurationGamepadButton;
    Some(match button {
        ConfigurationGamepadButton::South => "south",
        ConfigurationGamepadButton::East => "east",
        ConfigurationGamepadButton::West => "west",
        ConfigurationGamepadButton::North => "north",
        ConfigurationGamepadButton::LeftShoulder => "leftShoulder",
        ConfigurationGamepadButton::RightShoulder => "rightShoulder",
        ConfigurationGamepadButton::LeftTriggerButton => "leftTriggerButton",
        ConfigurationGamepadButton::RightTriggerButton => "rightTriggerButton",
        ConfigurationGamepadButton::Select => "select",
        ConfigurationGamepadButton::Start => "start",
        ConfigurationGamepadButton::Home => "home",
        ConfigurationGamepadButton::LeftStickPress => "leftStickPress",
        ConfigurationGamepadButton::RightStickPress => "rightStickPress",
        ConfigurationGamepadButton::DpadUp => "dpadUp",
        ConfigurationGamepadButton::DpadDown => "dpadDown",
        ConfigurationGamepadButton::DpadLeft => "dpadLeft",
        ConfigurationGamepadButton::DpadRight => "dpadRight",
    })
}

fn recommended_outputs(profile: &Value) -> ButtonBindings<OutputBinding> { thumble_core::profile_default_outputs(profile) }

fn replace_recognized_keys(target: &mut ButtonBindings<KeyBinding>, source: &ButtonBindings<OutputBinding>) {
    let mut keys = ButtonBindings::default();
    for (raw_id, output) in source.iter() {
        if let Some(keyboard) = &output.keyboard { keys.insert(thumble_protocol::KeypadElementID::parse(raw_id).unwrap(), keyboard.clone()); }
    }
    *target = keys;
}

fn replace_recognized_outputs(target: &mut ButtonBindings<OutputBinding>, source: &ButtonBindings<OutputBinding>) { *target = source.clone(); }

fn binding_profile_sync_is_exact(
    before: &Value,
    after: &Value,
    expected_mode: crate::draft_operation::ConfigurationOutputMode,
    outputs: &ButtonBindings<OutputBinding>,
) -> bool {
    let (Some(before_object), Some(after_object)) = (before.as_object(), after.as_object()) else {
        return false;
    };
    if before != after
        && after
            .get("updatedAt")
            .and_then(Value::as_i64)
            .is_none_or(|timestamp| timestamp < 0)
    {
        return false;
    }
    let expected_mode_name = match expected_mode {
        crate::draft_operation::ConfigurationOutputMode::Keyboard => "keyboard",
        crate::draft_operation::ConfigurationOutputMode::Controller => "controller",
        crate::draft_operation::ConfigurationOutputMode::Custom => "custom",
    };
    let implicit_keyboard = !before_object.contains_key("outputMode")
        && !after_object.contains_key("outputMode")
        && expected_mode == crate::draft_operation::ConfigurationOutputMode::Keyboard;
    if !implicit_keyboard && after_object.get("outputMode").and_then(Value::as_str) != Some(expected_mode_name) {
        return false;
    }
    let mut before_rest = before_object.clone();
    let mut after_rest = after_object.clone();
    for key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
        "updatedAt",
        "outputMode",
    ] {
        before_rest.remove(key);
        after_rest.remove(key);
    }
    if !json_semantically_equal(&Value::Object(before_rest), &Value::Object(after_rest)) {
        return false;
    }
    for key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        if !customization_output_sync_is_exact(
            before_object.get(key),
            after_object.get(key),
            outputs,
        ) {
            return false;
        }
    }
    true
}

fn customization_output_sync_is_exact(
    before: Option<&Value>,
    after: Option<&Value>,
    outputs: &ButtonBindings<OutputBinding>,
) -> bool {
    match (before, after) {
        (None, None) => return true,
        (Some(Value::Null), Some(Value::Null)) => return true,
        (Some(_), None) | (None, Some(_)) => return false,
        _ => {}
    }
    let (Some(before), Some(after)) = (
        before.and_then(Value::as_object),
        after.and_then(Value::as_object),
    ) else {
        return false;
    };
    let mut before_rest = before.clone();
    let mut after_rest = after.clone();
    let before_elements = before_rest.remove("elements");
    let after_elements = after_rest.remove("elements");
    if !json_semantically_equal(&Value::Object(before_rest), &Value::Object(after_rest)) {
        return false;
    }
    let (Some(before_elements), Some(after_elements)) = (
        before_elements.as_ref().and_then(Value::as_array),
        after_elements.as_ref().and_then(Value::as_array),
    ) else {
        return before_elements == after_elements;
    };
    if before_elements.len() != after_elements.len() || before_elements.len() > 128 {
        return false;
    }
    before_elements
        .iter()
        .zip(after_elements)
        .all(|(before_element, after_element)| {
            element_output_sync_is_exact(before_element, after_element, outputs)
        })
}

fn element_output_sync_is_exact(before: &Value, after: &Value, outputs: &ButtonBindings<OutputBinding>) -> bool {
    let (Some(before), Some(after)) = (before.as_object(), after.as_object()) else { return false; };
    let mut before_rest = before.clone(); let mut after_rest = after.clone();
    before_rest.remove("output"); let after_output = after_rest.remove("output");
    if !json_semantically_equal(&Value::Object(before_rest), &Value::Object(after_rest)) { return false; }
    let Some(id) = before.get("id").and_then(Value::as_str).and_then(thumble_protocol::KeypadElementID::parse) else { return false; };
    match outputs.get(&id) {
        Some(expected) => after_output.and_then(|value| serde_json::from_value::<OutputBinding>(value).ok()).as_ref() == Some(expected),
        None => after_output.is_none() || after_output == Some(Value::Null),
    }
}

fn valid_binding_output_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    profile_id: &str,
    expected_mode: Option<crate::draft_operation::ConfigurationOutputMode>,
) -> bool {
    if before.active_profile_id != after.active_profile_id
        || before.default_profile_id != after.default_profile_id
        || before.profiles.len() != after.profiles.len()
        || !binding_maps_only_target_changed(
            &before.profile_key_bindings,
            &after.profile_key_bindings,
            profile_id,
        )
        || !binding_maps_only_target_changed(
            &before.profile_output_bindings,
            &after.profile_output_bindings,
            profile_id,
        )
    {
        return false;
    }
    let (Some(before_index), Some(after_index)) = (
        profile_position(before, profile_id),
        profile_position(after, profile_id),
    ) else {
        return false;
    };
    if before_index != after_index {
        return false;
    }
    for index in 0..before.profiles.len() {
        if index != before_index && before.profiles[index] != after.profiles[index] {
            return false;
        }
    }
    let (Some(before_profile), Some(after_profile)) = (
        before.profiles[before_index].as_object(),
        after.profiles[after_index].as_object(),
    ) else {
        return false;
    };
    let mut before_rest = before_profile.clone();
    let mut after_rest = after_profile.clone();
    for key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
        "updatedAt",
    ] {
        before_rest.remove(key);
        after_rest.remove(key);
    }
    if expected_mode.is_some() {
        before_rest.remove("outputMode");
        after_rest.remove("outputMode");
    }
    if before_rest != after_rest {
        return false;
    }
    if let Some(expected_mode) = expected_mode {
        let expected = match expected_mode {
            crate::draft_operation::ConfigurationOutputMode::Keyboard => "keyboard",
            crate::draft_operation::ConfigurationOutputMode::Controller => "controller",
            crate::draft_operation::ConfigurationOutputMode::Custom => "custom",
        };
        if after_profile
            .get("outputMode")
            .and_then(serde_json::Value::as_str)
            != Some(expected)
        {
            return false;
        }
    }
    let (Some(target_keys), Some(target_outputs)) = (
        profile_binding_for(&after.profile_key_bindings, profile_id),
        profile_binding_for(&after.profile_output_bindings, profile_id),
    ) else {
        return false;
    };
    if profile_id_matches(&after.active_profile_id, profile_id) {
        after.key_bindings == *target_keys && after.output_bindings == *target_outputs
    } else {
        after.key_bindings == before.key_bindings && after.output_bindings == before.output_bindings
    }
}

fn game_button_name(button: thumble_protocol::KeypadElementID) -> String { button.to_string() }

fn binding_maps_only_target_changed<T: PartialEq>(
    before: &std::collections::BTreeMap<String, T>,
    after: &std::collections::BTreeMap<String, T>,
    target_id: &str,
) -> bool {
    let before_non_target = before
        .iter()
        .filter(|(id, _)| !profile_id_matches(id, target_id));
    if before_non_target
        .clone()
        .any(|(id, value)| profile_binding_for(after, id) != Some(value))
    {
        return false;
    }
    if after.iter().any(|(id, value)| {
        !profile_id_matches(id, target_id) && profile_binding_for(before, id) != Some(value)
    }) {
        return false;
    }
    profile_binding_for(after, target_id).is_some() && after.len() <= before.len().saturating_add(1)
}

struct GeneratedInstallExpectation<'a> {
    destination: &'a crate::draft_operation::GeneratedProfileDestination,
    expected_name: &'a str,
    template: Option<(crate::draft_operation::ControllerTemplate, u32)>,
    new_element_ids: &'a [String],
    select: bool,
    make_default: bool,
}

fn valid_generated_install(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    expectation: GeneratedInstallExpectation<'_>,
) -> bool {
    use crate::draft_operation::GeneratedProfileDestination;

    let target_id = expectation.destination.profile_id();
    let expected_active = if expectation.select {
        target_id
    } else {
        &before.active_profile_id
    };
    let expected_default = if expectation.make_default {
        target_id
    } else {
        &before.default_profile_id
    };
    if !profile_id_matches(&after.active_profile_id, expected_active)
        || !profile_id_matches(&after.default_profile_id, expected_default)
        || !binding_maps_only_target_changed(
            &before.profile_key_bindings,
            &after.profile_key_bindings,
            target_id,
        )
        || !binding_maps_only_target_changed(
            &before.profile_output_bindings,
            &after.profile_output_bindings,
            target_id,
        )
    {
        return false;
    }

    let target_index = match expectation.destination {
        GeneratedProfileDestination::Create { .. } => {
            if after.profiles.len() != before.profiles.len() + 1
                || after.profiles[..before.profiles.len()] != before.profiles
            {
                return false;
            }
            before.profiles.len()
        }
        GeneratedProfileDestination::Replace { .. } => {
            let (Some(before_index), Some(after_index)) = (
                profile_position(before, target_id),
                profile_position(after, target_id),
            ) else {
                return false;
            };
            if before_index != after_index || after.profiles.len() != before.profiles.len() {
                return false;
            }
            for index in 0..before.profiles.len() {
                if index != before_index && before.profiles[index] != after.profiles[index] {
                    return false;
                }
            }
            before_index
        }
    };

    let Some(profile) = after.profiles[target_index].as_object() else {
        return false;
    };
    if !profile
        .get("id")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|id| profile_id_matches(id, target_id))
        || profile.get("name").and_then(serde_json::Value::as_str)
            != Some(expectation.expected_name)
        || profile
            .get("outputMode")
            .and_then(serde_json::Value::as_str)
            != Some("keyboard")
        || [
            "launchTarget",
            "skinReference",
            "skinBaselineCustomization",
            "landscapeSkinBaselineCustomization",
            "portraitSkinBaselineCustomization",
        ]
        .iter()
        .any(|key| profile.get(*key).is_some_and(|value| !value.is_null()))
    {
        return false;
    }

    if let Some((template, revision)) = expectation.template {
        let metadata = profile
            .get("customization")
            .and_then(|value| value.get("designMetadata"));
        if !metadata
            .and_then(|value| value.get("sourceTemplateID"))
            .and_then(serde_json::Value::as_str)
            .is_some_and(|value| template_id_matches(value, template))
            || metadata
                .and_then(|value| value.get("sourceTemplateRevision"))
                .and_then(serde_json::Value::as_u64)
                != Some(u64::from(revision))
        {
            return false;
        }
    }

    let expected_ids = expectation
        .new_element_ids
        .iter()
        .map(|id| id.to_ascii_lowercase())
        .collect::<Vec<_>>();
    if generated_custom_element_ids(profile) != Some(expected_ids.clone())
        || expected_ids.iter().any(|element_id| {
            after.profiles.iter().any(|profile| {
                profile
                    .get("id")
                    .and_then(serde_json::Value::as_str)
                    .is_some_and(|profile_id| profile_id.eq_ignore_ascii_case(element_id))
            })
        })
    {
        return false;
    }

    let Some(actual_keys) = profile_binding_for(&after.profile_key_bindings, target_id) else {
        return false;
    };
    let expected_outputs = thumble_core::profile_owned_outputs(&after.profiles[target_index]);
    let mut expected_keys = ButtonBindings::default();
    for (id, output) in expected_outputs.iter_ids() {
        if let Some(keyboard) = &output.keyboard {
            expected_keys.insert(id, keyboard.clone());
        }
    }
    let Some(actual_outputs) = profile_binding_for(&after.profile_output_bindings, target_id)
    else {
        return false;
    };
    if actual_keys != &expected_keys || actual_outputs != &expected_outputs {
        return false;
    }
    if profile_id_matches(&after.active_profile_id, target_id) {
        after.key_bindings == expected_keys && after.output_bindings == expected_outputs
    } else {
        after.key_bindings == before.key_bindings && after.output_bindings == before.output_bindings
    }
}

fn template_id_matches(value: &str, template: crate::draft_operation::ControllerTemplate) -> bool {
    value.eq_ignore_ascii_case(template.id())
}

fn generated_custom_element_ids(
    profile: &serde_json::Map<String, serde_json::Value>,
) -> Option<Vec<String>> {
    let mut result = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let Some(customization) = profile.get(key) else {
            continue;
        };
        if customization.is_null() {
            continue;
        }
        let buttons = customization.get("customButtons")?.as_array()?;
        for button in buttons {
            let id = button.get("id")?.as_str()?.to_ascii_lowercase();
            if seen.insert(id.clone()) {
                result.push(id);
            }
        }
    }
    Some(result)
}

fn valid_profile_duplicate(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    profile_id: &str,
    new_profile_id: &str,
    name: &str,
) -> bool {
    let Some(source_index) = profile_position(before, profile_id) else {
        return false;
    };
    if after.profiles.len() != before.profiles.len() + 1
        || after.profiles[..before.profiles.len()] != before.profiles
        || !profile_id_matches(&after.active_profile_id, new_profile_id)
        || after.default_profile_id != before.default_profile_id
        || after.profile_key_bindings.len() != before.profile_key_bindings.len() + 1
        || after.profile_output_bindings.len() != before.profile_output_bindings.len() + 1
        || !binding_maps_preserve_existing(
            &before.profile_key_bindings,
            &after.profile_key_bindings,
        )
        || !binding_maps_preserve_existing(
            &before.profile_output_bindings,
            &after.profile_output_bindings,
        )
    {
        return false;
    }
    let Some(duplicate) = after.profiles.last().and_then(serde_json::Value::as_object) else {
        return false;
    };
    let Some(source) = before.profiles[source_index].as_object() else {
        return false;
    };
    if !duplicate
        .get("id")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|id| profile_id_matches(id, new_profile_id))
        || duplicate.get("name").and_then(serde_json::Value::as_str) != Some(name.trim())
        || profile_without_identity(duplicate) != profile_without_identity(source)
    {
        return false;
    }
    let Some(new_keys) = profile_binding_for(&after.profile_key_bindings, new_profile_id) else {
        return false;
    };
    let Some(new_outputs) = profile_binding_for(&after.profile_output_bindings, new_profile_id)
    else {
        return false;
    };
    let expected_keys =
        profile_binding_for(&before.profile_key_bindings, profile_id).or_else(|| {
            profile_id_matches(&before.active_profile_id, profile_id)
                .then_some(&before.key_bindings)
        });
    let expected_outputs = profile_binding_for(&before.profile_output_bindings, profile_id)
        .or_else(|| {
            profile_id_matches(&before.active_profile_id, profile_id)
                .then_some(&before.output_bindings)
        });
    expected_keys == Some(new_keys)
        && expected_outputs == Some(new_outputs)
        && after.key_bindings == *new_keys
        && after.output_bindings == *new_outputs
}

fn valid_profile_create(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    name: &str,
    new_profile_id: &str,
    source_profile_id: Option<&str>,
    select: bool,
    make_default: bool,
) -> bool {
    let expected_active = if select {
        new_profile_id
    } else {
        &before.active_profile_id
    };
    let expected_default = if make_default {
        new_profile_id
    } else {
        &before.default_profile_id
    };
    if after.profiles.len() != before.profiles.len() + 1
        || after.profiles[..before.profiles.len()] != before.profiles
        || after.profile_key_bindings.len() != before.profile_key_bindings.len() + 1
        || after.profile_output_bindings.len() != before.profile_output_bindings.len() + 1
        || !binding_maps_preserve_existing(
            &before.profile_key_bindings,
            &after.profile_key_bindings,
        )
        || !binding_maps_preserve_existing(
            &before.profile_output_bindings,
            &after.profile_output_bindings,
        )
        || !profile_id_matches(&after.active_profile_id, expected_active)
        || !profile_id_matches(&after.default_profile_id, expected_default)
    {
        return false;
    }
    let Some(created) = after.profiles.last().and_then(serde_json::Value::as_object) else {
        return false;
    };
    if !created
        .get("id")
        .and_then(serde_json::Value::as_str)
        .is_some_and(|id| profile_id_matches(id, new_profile_id))
        || created.get("name").and_then(serde_json::Value::as_str) != Some(name.trim())
    {
        return false;
    }
    let (Some(new_keys), Some(new_outputs)) = (
        profile_binding_for(&after.profile_key_bindings, new_profile_id),
        profile_binding_for(&after.profile_output_bindings, new_profile_id),
    ) else {
        return false;
    };
    if let Some(source_id) = source_profile_id {
        let expected_keys =
            profile_binding_for(&before.profile_key_bindings, source_id).or_else(|| {
                profile_id_matches(&before.active_profile_id, source_id)
                    .then_some(&before.key_bindings)
            });
        let expected_outputs = profile_binding_for(&before.profile_output_bindings, source_id)
            .or_else(|| {
                profile_id_matches(&before.active_profile_id, source_id)
                    .then_some(&before.output_bindings)
            });
        if expected_keys != Some(new_keys) || expected_outputs != Some(new_outputs) {
            return false;
        }
    }
    if select {
        after.key_bindings == *new_keys && after.output_bindings == *new_outputs
    } else {
        after.key_bindings == before.key_bindings && after.output_bindings == before.output_bindings
    }
}

fn valid_profile_delete(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    profile_id: &str,
    replacement_profile_id: Option<&str>,
) -> bool {
    let Some(index) = profile_position(before, profile_id) else {
        return false;
    };
    let removed_id = before.profiles[index]
        .get("id")
        .and_then(serde_json::Value::as_str)
        .unwrap_or(profile_id);
    if binding_map_contains(&after.profile_key_bindings, removed_id)
        || binding_map_contains(&after.profile_output_bindings, removed_id)
    {
        return false;
    }
    if before.profiles.len() == 1 {
        let Some(replacement_id) = replacement_profile_id else {
            return false;
        };
        return after.profiles.len() == 1
            && after.profile_key_bindings.len() == 1
            && after.profile_output_bindings.len() == 1
            && after.profiles[0]
                .get("id")
                .and_then(serde_json::Value::as_str)
                .is_some_and(|id| profile_id_matches(id, replacement_id))
            && after.profiles[0]
                .get("name")
                .and_then(serde_json::Value::as_str)
                == Some("Setup 1")
            && profile_id_matches(&after.active_profile_id, replacement_id)
            && profile_id_matches(&after.default_profile_id, replacement_id)
            && profile_binding_for(&after.profile_key_bindings, replacement_id)
                == Some(&after.key_bindings)
            && profile_binding_for(&after.profile_output_bindings, replacement_id)
                == Some(&after.output_bindings);
    }
    let mut expected_profiles = before.profiles.clone();
    expected_profiles.remove(index);
    let expected_key_map_count = before.profile_key_bindings.len()
        - usize::from(binding_map_contains(
            &before.profile_key_bindings,
            removed_id,
        ));
    let expected_output_map_count = before.profile_output_bindings.len()
        - usize::from(binding_map_contains(
            &before.profile_output_bindings,
            removed_id,
        ));
    if after.profiles != expected_profiles
        || after.profile_key_bindings.len() != expected_key_map_count
        || after.profile_output_bindings.len() != expected_output_map_count
        || !binding_maps_preserve_retained(
            &before.profile_key_bindings,
            &after.profile_key_bindings,
            removed_id,
        )
        || !binding_maps_preserve_retained(
            &before.profile_output_bindings,
            &after.profile_output_bindings,
            removed_id,
        )
    {
        return false;
    }
    let fallback = after.profiles[index.min(after.profiles.len() - 1)]
        .get("id")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    let expected_active = if profile_id_matches(&before.active_profile_id, removed_id) {
        fallback
    } else {
        &before.active_profile_id
    };
    let expected_default = if profile_id_matches(&before.default_profile_id, removed_id) {
        expected_active
    } else {
        &before.default_profile_id
    };
    profile_id_matches(&after.active_profile_id, expected_active)
        && profile_id_matches(&after.default_profile_id, expected_default)
        && profile_binding_for(&after.profile_key_bindings, &after.active_profile_id)
            == Some(&after.key_bindings)
        && profile_binding_for(&after.profile_output_bindings, &after.active_profile_id)
            == Some(&after.output_bindings)
}

fn profile_without_identity(
    profile: &serde_json::Map<String, serde_json::Value>,
) -> serde_json::Map<String, serde_json::Value> {
    let mut profile = profile.clone();
    profile.remove("id");
    profile.remove("name");
    profile.remove("updatedAt");
    profile
}

fn binding_map_contains<T>(
    bindings: &std::collections::BTreeMap<String, T>,
    profile_id: &str,
) -> bool {
    bindings.keys().any(|id| profile_id_matches(id, profile_id))
}

fn binding_maps_preserve_retained<T: PartialEq>(
    before: &std::collections::BTreeMap<String, T>,
    after: &std::collections::BTreeMap<String, T>,
    removed_id: &str,
) -> bool {
    before.iter().all(|(id, value)| {
        profile_id_matches(id, removed_id)
            || profile_binding_for(after, id).is_some_and(|candidate| candidate == value)
    })
}

fn profile_local_delta(
    before: &ConfigurationDocument,
    after: &ConfigurationDocument,
    profile_id: &str,
    allowed_keys: &[&str],
) -> bool {
    if before.active_profile_id != after.active_profile_id
        || before.default_profile_id != after.default_profile_id
        || before.key_bindings != after.key_bindings
        || before.output_bindings != after.output_bindings
        || before.profile_key_bindings != after.profile_key_bindings
        || before.profile_output_bindings != after.profile_output_bindings
        || before.profiles.len() != after.profiles.len()
    {
        return false;
    }
    let Some(target) = profile_position(before, profile_id) else {
        return false;
    };
    for index in 0..before.profiles.len() {
        if index != target && before.profiles[index] != after.profiles[index] {
            return false;
        }
    }
    let (Some(before_object), Some(after_object)) = (
        before.profiles[target].as_object(),
        after.profiles[target].as_object(),
    ) else {
        return false;
    };
    let mut before_rest = before_object.clone();
    let mut after_rest = after_object.clone();
    for key in allowed_keys {
        before_rest.remove(*key);
        after_rest.remove(*key);
    }
    before_rest == after_rest
}

fn profile_position(document: &ConfigurationDocument, profile_id: &str) -> Option<usize> {
    document.profiles.iter().position(|profile| {
        profile
            .get("id")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|id| profile_id_matches(id, profile_id))
    })
}

fn profile_canonical_id(document: &ConfigurationDocument, profile_id: &str) -> Option<String> {
    document.profiles.iter().find_map(|profile| {
        let id = profile.get("id")?.as_str()?;
        profile_id_matches(id, profile_id).then(|| id.to_owned())
    })
}

fn profile_id_matches(left: &str, right: &str) -> bool {
    left.eq_ignore_ascii_case(right)
}

fn profile_binding_for<'a, T>(
    bindings: &'a std::collections::BTreeMap<String, T>,
    profile_id: &str,
) -> Option<&'a T> {
    bindings
        .iter()
        .find_map(|(id, value)| profile_id_matches(id, profile_id).then_some(value))
}

fn binding_maps_preserve_existing<T: PartialEq>(
    before: &std::collections::BTreeMap<String, T>,
    after: &std::collections::BTreeMap<String, T>,
) -> bool {
    before.iter().all(|(id, value)| {
        profile_binding_for(after, id).is_some_and(|candidate| candidate == value)
    })
}

fn escape_json_pointer(value: &str) -> String {
    value.replace('~', "~0").replace('/', "~1")
}

fn validate_executable(path: &Path) -> Result<(), ConfigurationBridgeError> {
    let parent = path
        .parent()
        .ok_or(ConfigurationBridgeError::InsecureExecutable)?;
    let parent_metadata =
        fs::symlink_metadata(parent).map_err(ConfigurationBridgeError::Discovery)?;
    if parent_metadata.file_type().is_symlink()
        || !parent_metadata.is_dir()
        || parent_metadata.uid() != unsafe { libc::geteuid() }
        || parent_metadata.permissions().mode() & 0o022 != 0
    {
        return Err(ConfigurationBridgeError::InsecureExecutable);
    }
    let metadata = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            ConfigurationBridgeError::Unavailable
        } else {
            ConfigurationBridgeError::Discovery(error)
        }
    })?;
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o022 != 0
        || metadata.permissions().mode() & 0o111 == 0
    {
        return Err(ConfigurationBridgeError::InsecureExecutable);
    }
    Ok(())
}

fn read_bounded<R: Read>(reader: R, maximum: usize) -> Result<Vec<u8>, ConfigurationBridgeError> {
    let mut output = Vec::new();
    reader
        .take(u64::try_from(maximum).unwrap_or(u64::MAX).saturating_add(1))
        .read_to_end(&mut output)
        .map_err(ConfigurationBridgeError::Read)?;
    Ok(output)
}

fn single_line(output: &[u8]) -> Result<&[u8], ConfigurationBridgeError> {
    if output.is_empty() || output.last() != Some(&b'\n') {
        return Err(ConfigurationBridgeError::InvalidResponse);
    }
    let line = &output[..output.len() - 1];
    if line.is_empty() || line.contains(&b'\n') || line.contains(&b'\r') {
        return Err(ConfigurationBridgeError::InvalidResponse);
    }
    Ok(line)
}

#[derive(Debug)]
pub enum ConfigurationBridgeError {
    Unavailable,
    InsecureExecutable,
    OperationNotSupported,
    InvalidDocument,
    InvalidOperation,
    EncodingFailed,
    OperationTooLarge,
    InputTooLarge,
    OutputTooLarge,
    TimedOut,
    InvalidResponse,
    Failed,
    Rejected(String),
    Discovery(io::Error),
    Launch(io::Error),
    LaunchPipe,
    Write(io::Error),
    Wait(io::Error),
    Read(io::Error),
    ReadThread,
}

impl fmt::Display for ConfigurationBridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Unavailable => formatter.write_str("configuration bridge is unavailable"),
            Self::InsecureExecutable => formatter
                .write_str("configuration bridge executable failed ownership or permission checks"),
            Self::OperationNotSupported => {
                formatter.write_str("operation does not use the configuration bridge")
            }
            Self::InvalidDocument => {
                formatter.write_str("configuration bridge input document is invalid")
            }
            Self::InvalidOperation => {
                formatter.write_str("configuration bridge operation is invalid")
            }
            Self::EncodingFailed => {
                formatter.write_str("configuration bridge request could not be encoded")
            }
            Self::OperationTooLarge => {
                formatter.write_str("configuration bridge operation exceeds its limits")
            }
            Self::InputTooLarge => {
                formatter.write_str("configuration bridge request exceeds its size limit")
            }
            Self::OutputTooLarge => {
                formatter.write_str("configuration bridge response exceeds its size limit")
            }
            Self::TimedOut => formatter.write_str("configuration bridge timed out"),
            Self::InvalidResponse => {
                formatter.write_str("configuration bridge returned an invalid response")
            }
            Self::Failed => formatter.write_str("configuration bridge process failed"),
            Self::Rejected(code) => write!(
                formatter,
                "configuration bridge rejected operation [{code}]"
            ),
            Self::Discovery(_) => {
                formatter.write_str("configuration bridge could not be discovered")
            }
            Self::Launch(_) | Self::LaunchPipe => {
                formatter.write_str("configuration bridge could not be launched")
            }
            Self::Write(_) => {
                formatter.write_str("configuration bridge request could not be written")
            }
            Self::Wait(_) => {
                formatter.write_str("configuration bridge process could not be observed")
            }
            Self::Read(_) | Self::ReadThread => {
                formatter.write_str("configuration bridge response could not be read")
            }
        }
    }
}

impl Error for ConfigurationBridgeError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Discovery(error)
            | Self::Launch(error)
            | Self::Write(error)
            | Self::Wait(error)
            | Self::Read(error) => Some(error),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;
    use tempfile::tempdir;


    #[test]
    fn design_attachment_replays_exact_native_reveal_geometry_only() {
        let state = thumble_core::PersistentState::minimal("design-reveal-delta-test").unwrap();
        let mut before = ConfigurationDocument::from_state(&state).unwrap();
        before.profiles[0]["customization"]["topBarActivationRegion"] = serde_json::json!({
            "centerX":0.5,"centerY":0.115,"widthScale":1,"heightScale":1,"rotationDegrees":0,
            "hitInsets":{"top":10,"leading":10,"bottom":10,"trailing":10},"isHidden":false
        });
        let mut after = before.clone();
        after.profiles[0]["customization"]["topBarActivationRegion"]["centerY"] = serde_json::json!(0.09);
        let operation = ConfigurationOperation::DesignApply {
            profile_id: before.active_profile_id.clone(), package_base64:"AA==".into(),
            package_sha256:"a".repeat(64),profile_sha256:"b".repeat(64),evidence_sha256:"c".repeat(64),
            base_profile_sha256:Some("d".repeat(64)),
            layout_edits_json:Some(serde_json::json!([{"variant":"primary","controlID":"system.top_bar_activation","centerY":0.09}]).to_string())
        };
        assert!(validate_operation_bounds(&operation).is_ok());
        assert!(valid_operation_delta(&before,&after,&operation));
        let mut unplanned = after.clone();
        unplanned.profiles[0]["customization"]["topBarActivationRegion"]["centerX"] = serde_json::json!(0.2);
        assert!(!valid_operation_delta(&before,&unplanned,&operation));
        unplanned = after.clone();
        unplanned.profiles[0]["customization"]["topBarActivationRegion"]["hitInsets"]["top"] = serde_json::json!(30);
        assert!(!valid_operation_delta(&before,&unplanned,&operation));
        unplanned = after.clone();
        unplanned.profiles[0]["customization"]["elements"][0]["layout"]["centerY"] = serde_json::json!(0.2);
        assert!(!valid_operation_delta(&before,&unplanned,&operation));
        unplanned = after;
        unplanned.profiles[0]["customization"]["elements"][0]["output"] = serde_json::json!({"gamepadButtons":["south"]});
        assert!(!valid_operation_delta(&before,&unplanned,&operation));
    }

    #[test]
    fn design_attachment_delta_preserves_geometry_routing_defaults_and_unknown_fields() {
        let state = thumble_core::PersistentState::minimal("design-delta-test").unwrap();
        let mut before = ConfigurationDocument::from_state(&state).unwrap();
        before.profiles[0]["unknownDesignSentinel"] = serde_json::json!({"keep": true});
        let id = before.active_profile_id.clone();
        let mut after = before.clone();
        after.profiles[0]["customization"]["elements"][0]["layout"]["fillColor"] = serde_json::json!({"red": 0.2, "green": 0.3, "blue": 0.4, "alpha": 1});
        after.profiles[0]["skinReference"] = serde_json::json!({"identifier": "com.test.design", "version": "1.0.0"});
        let operation = ConfigurationOperation::DesignApply { profile_id: id.clone(), package_base64: "AA==".into(),
            package_sha256: "a".repeat(64), profile_sha256: "b".repeat(64), evidence_sha256: "c".repeat(64),
            base_profile_sha256: None, layout_edits_json: None };
        assert!(validate_operation_bounds(&operation).is_ok());
        let artifact_operation = ConfigurationOperation::DesignApply { profile_id: id.clone(),
            package_base64: "A".repeat(100_000), package_sha256: "a".repeat(64), profile_sha256: "b".repeat(64), evidence_sha256: "c".repeat(64),
            base_profile_sha256: None, layout_edits_json: None };
        assert!(validate_operation_bounds(&artifact_operation).is_ok());
        assert!(allowed_changed_path(&operation, &format!("/profiles/{id}")));
        assert!(!allowed_changed_path(&operation, "/outputBindings"));
        assert!(valid_operation_delta(&before, &after, &operation));
        // Native skin attachment installs passive artwork alongside its raster assets.
        // It must still preserve customization interaction and extension fields.
        let mut decorated = after.clone();
        decorated.profiles[0]["customization"]["artworkLayers"] = serde_json::json!([
            {"id":"instrument-field","assetID":"field-landscape-light","placement":"underlay"}
        ]);
        assert!(valid_operation_delta(&before, &decorated, &operation));
        decorated.profiles[0]["customization"]["interactionSentinel"] = serde_json::json!(true);
        assert!(!valid_operation_delta(&before, &decorated, &operation));
        let mut moved = after.clone();
        moved.profiles[0]["customization"]["elements"][0]["layout"]["centerX"] = serde_json::json!(0.1);
        assert!(!valid_operation_delta(&before, &moved, &operation));
        let control_id = before.profiles[0]["customization"]["elements"][0]["id"].as_str().unwrap();
        let mut planned = operation.clone();
        if let ConfigurationOperation::DesignApply { base_profile_sha256, layout_edits_json, .. } = &mut planned {
            *base_profile_sha256 = Some("d".repeat(64));
            *layout_edits_json = Some(serde_json::json!([{"variant":"primary", "controlID":format!("builtin.{control_id}"),"centerX":0.1}]).to_string());
        }
        assert!(valid_operation_delta(&before, &moved, &planned));
        moved.profiles[0]["customization"]["elements"][0]["layout"]["centerY"] = serde_json::json!(0.2);
        assert!(!valid_operation_delta(&before, &moved, &planned));
        let metadata = serde_json::json!({"schemaVersion":1,"actionID":"lux.light-binding","groupIDs":["abilities"],"legend":"Q"});
        let mut described = after.clone();
        described.profiles[0]["customization"]["elements"][0]["presentation"] = metadata.clone();
        assert!(!valid_operation_delta(&before, &described, &operation));
        let mut semantic_plan = operation.clone();
        if let ConfigurationOperation::DesignApply { base_profile_sha256, layout_edits_json, .. } = &mut semantic_plan {
            *base_profile_sha256 = Some("d".repeat(64));
            *layout_edits_json = Some(serde_json::json!([{"variant":"primary","controlID":format!("builtin.{control_id}"),"presentation":metadata}]).to_string());
        }
        assert!(validate_operation_bounds(&semantic_plan).is_ok());
        assert!(valid_operation_delta(&before, &described, &semantic_plan));
        described.profiles[0]["customization"]["elements"][0]["presentation"]["legend"] = serde_json::json!("forged");
        assert!(!valid_operation_delta(&before, &described, &semantic_plan));
        let mut clear_plan = operation.clone();
        if let ConfigurationOperation::DesignApply { base_profile_sha256, layout_edits_json, .. } = &mut clear_plan {
            *base_profile_sha256 = Some("d".repeat(64));
            *layout_edits_json = Some(serde_json::json!([{"variant":"primary","controlID":format!("builtin.{control_id}"),"clearPresentation":true}]).to_string());
        }
        assert!(validate_operation_bounds(&clear_plan).is_ok());
        assert!(valid_operation_delta(&described, &after, &clear_plan));
        let mut role_changed = after.clone();
        role_changed.profiles[0]["customization"]["elements"][0]["visualRole"] = serde_json::json!("utility");
        assert!(!valid_operation_delta(&before, &role_changed, &operation));
        let mut role_plan = operation.clone();
        if let ConfigurationOperation::DesignApply { base_profile_sha256, layout_edits_json, .. } = &mut role_plan {
            *base_profile_sha256 = Some("d".repeat(64));
            *layout_edits_json = Some(serde_json::json!([{"variant":"primary","controlID":format!("builtin.{control_id}"),"visualRole":"utility"}]).to_string());
        }
        assert!(validate_operation_bounds(&role_plan).is_ok());
        assert!(valid_operation_delta(&before, &role_changed, &role_plan));
        role_changed.profiles[0]["customization"]["elements"][0]["visualRole"] = serde_json::json!("primary_action");
        assert!(!valid_operation_delta(&before, &role_changed, &role_plan));
        let mut rebound = after.clone();
        rebound.profiles[0]["customization"]["elements"][0]["output"] = serde_json::json!({"gamepadButtons": ["south"]});
        assert!(!valid_operation_delta(&before, &rebound, &operation));
        let mut lost_unknown = after.clone();
        lost_unknown.profiles[0].as_object_mut().unwrap().remove("unknownDesignSentinel");
        assert!(!valid_operation_delta(&before, &lost_unknown, &operation));
        let mut selected = after;
        selected.default_profile_id = uuid::Uuid::new_v4().to_string();
        assert!(!valid_operation_delta(&before, &selected, &operation));
    }

    #[test]
    fn binding_delta_requires_exact_semantic_sequence_and_element_mirrors() {
        use crate::draft_operation::{SemanticKeyStroke, SemanticModifier};
        use thumble_core::{KeyStroke, PersistentState};
        use thumble_protocol::KeypadElementID;

        let state = PersistentState::minimal("test-server").unwrap();
        let before = ConfigurationDocument::from_state(&state).unwrap();
        let profile_id = before.active_profile_id.clone();
        let operation = ConfigurationOperation::BindingSet {
            profile_id: profile_id.clone(),
            button: KeypadElementID::preset(5),
            sequence: vec![
                SemanticKeyStroke {
                    key: "B".to_owned(),
                    modifiers: vec![SemanticModifier::Control],
                },
                SemanticKeyStroke {
                    key: "H".to_owned(),
                    modifiers: vec![],
                },
            ],
        };
        let mut after = before.clone();
        let binding =
            KeyBinding::from_strokes(vec![KeyStroke::new(11, 8), KeyStroke::new(4, 0)]).unwrap();
        let keys = after.profile_key_bindings.get_mut(&profile_id).unwrap();
        keys.insert(KeypadElementID::preset(5), binding);
        let keys = keys.clone();
        let outputs = after.profile_output_bindings.get_mut(&profile_id).unwrap();
        apply_binding_mode_outputs(crate::draft_operation::ConfigurationOutputMode::Keyboard, &keys, outputs);
        let outputs = outputs.clone();
        after.key_bindings = keys;
        after.output_bindings = outputs.clone();
        let profile = after.profiles[0].as_object_mut().unwrap();
        profile.insert("updatedAt".to_owned(), Value::from(100));
        for element in profile["customization"]["elements"].as_array_mut().unwrap() {
            let id: KeypadElementID = serde_json::from_value(element["id"].clone()).unwrap();
            element.as_object_mut().unwrap().insert(
                "output".to_owned(),
                outputs.get(&id).unwrap().element_value(),
            );
        }
        assert!(valid_operation_delta(&before, &after, &operation));

        let mut legacy_without_profile_maps = before.clone();
        legacy_without_profile_maps
            .profile_key_bindings
            .remove(&profile_id);
        legacy_without_profile_maps
            .profile_output_bindings
            .remove(&profile_id);
        assert!(valid_operation_delta(
            &legacy_without_profile_maps,
            &after,
            &operation
        ));

        let mut substituted = after.clone();
        substituted
            .profile_key_bindings
            .get_mut(&profile_id)
            .unwrap()
            .insert(KeypadElementID::preset(5), KeyBinding::new(125, 0));
        substituted.key_bindings = substituted.profile_key_bindings[&profile_id].clone();
        assert!(!valid_operation_delta(&before, &substituted, &operation));

        let mut injected = after;
        injected.profiles[0]["customization"]["elements"][0]["label"] =
            Value::String("Injected".to_owned());
        assert!(!valid_operation_delta(&before, &injected, &operation));
    }

    #[test]
    fn binding_delta_reconciles_stale_sidecars_to_owned_outputs() {
        use thumble_protocol::KeypadElementID;
        let mut before = ConfigurationDocument::from_state(&thumble_core::PersistentState::minimal("server").unwrap()).unwrap();
        let profile_id = before.active_profile_id.clone();
        let stale_id = KeypadElementID::preset(5);
        let target_id = KeypadElementID::preset(6);
        let stale = OutputBinding::keyboard(KeyBinding::new(12, 0));
        before.profile_key_bindings.get_mut(&profile_id).unwrap().insert(stale_id, KeyBinding::new(12, 0));
        before.profile_output_bindings.get_mut(&profile_id).unwrap().insert(stale_id, stale);
        before.key_bindings = before.profile_key_bindings[&profile_id].clone();
        before.output_bindings = before.profile_output_bindings[&profile_id].clone();
        let operation = ConfigurationOperation::BindingSet {
            profile_id: profile_id.clone(), button: target_id,
            sequence: vec![crate::draft_operation::SemanticKeyStroke { key: "Tab".to_owned(), modifiers: Vec::new() }],
        };
        let mut after = before.clone();
        let mut outputs = thumble_core::profile_owned_outputs(&before.profiles[0]);
        let mut target = outputs.get(&target_id).unwrap().clone();
        target.keyboard = Some(KeyBinding::new(48, 0));
        outputs.insert(target_id, target);
        let mut keys = ButtonBindings::default();
        for (id, output) in outputs.iter_ids() {
            if let Some(keyboard) = &output.keyboard { keys.insert(id, keyboard.clone()); }
        }
        after.profile_key_bindings.insert(profile_id.clone(), keys.clone());
        after.profile_output_bindings.insert(profile_id.clone(), outputs.clone());
        after.key_bindings = keys;
        after.output_bindings = outputs.clone();
        after.profiles[0]["updatedAt"] = serde_json::json!(100);
        for element in after.profiles[0]["customization"]["elements"].as_array_mut().unwrap() {
            let id = KeypadElementID::parse(element["id"].as_str().unwrap()).unwrap();
            if let Some(output) = outputs.get(&id) { element["output"] = output.element_value(); }
        }
        assert!(valid_operation_delta(&before, &after, &operation));
        after.profile_output_bindings.get_mut(&profile_id).unwrap().insert(stale_id, OutputBinding::keyboard(KeyBinding::new(12, 0)));
        after.output_bindings = after.profile_output_bindings[&profile_id].clone();
        assert!(!valid_operation_delta(&before, &after, &operation));
    }

    #[test]
    fn reset_recommendations_use_declared_defaults_not_current_outputs() {
        let id = thumble_protocol::KeypadElementID::parse("B42A01DD-1782-445D-8CC5-CE0497198637").unwrap();
        let profile = serde_json::json!({"customization": {"elements": [{
            "id": id, "output": {"keyboard": {"keyCode": 23}, "gamepadButtons": ["south"]},
            "defaultOutput": {"keyboard": {"keyCode": 9}, "gamepadButtons": ["west"]}
        }]}});
        assert_eq!(thumble_core::profile_owned_outputs(&profile).get(&id).unwrap().keyboard.as_ref().unwrap().key_code, 23);
        let defaults = recommended_outputs(&profile);
        assert_eq!(defaults.get(&id).unwrap().keyboard.as_ref().unwrap().key_code, 9);
        assert!(defaults.get(&id).unwrap().gamepad_buttons.contains("west"));
        let no_defaults = serde_json::json!({"customization": {"elements": [{
            "id": id, "output": {"keyboard": {"keyCode": 23}}
        }]}});
        assert!(recommended_outputs(&no_defaults).is_empty());
    }

    #[test]
    fn output_delta_preserves_an_owned_clear_instead_of_restoring_defaults() {
        use crate::draft_operation::{GamepadOutputEdit, KeyboardOutputEdit, ConfigurationOutputMode};
        let before = ConfigurationDocument::from_state(&thumble_core::PersistentState::minimal("server").unwrap()).unwrap();
        let profile_id = before.active_profile_id.clone();
        let id = thumble_protocol::KeypadElementID::preset(5);
        let operation = ConfigurationOperation::OutputSet {
            profile_id: profile_id.clone(), button: id,
            keyboard_edit: KeyboardOutputEdit::Clear, gamepad_edit: GamepadOutputEdit::Clear,
        };
        let mut after = before.clone();
        after.profile_key_bindings.get_mut(&profile_id).unwrap().remove(id);
        after.profile_output_bindings.get_mut(&profile_id).unwrap().insert(id, OutputBinding::default());
        after.key_bindings = after.profile_key_bindings[&profile_id].clone();
        after.output_bindings = after.profile_output_bindings[&profile_id].clone();
        after.profiles[0]["outputMode"] = serde_json::json!(ConfigurationOutputMode::Custom);
        after.profiles[0]["updatedAt"] = serde_json::json!(100);
        for element in after.profiles[0]["customization"]["elements"].as_array_mut().unwrap() {
            if element["id"].as_str().is_some_and(|raw| thumble_protocol::KeypadElementID::parse(raw) == Some(id)) {
                element["output"] = OutputBinding::default().element_value();
            }
        }
        assert!(valid_operation_delta(&before, &after, &operation));
        after.profile_output_bindings.get_mut(&profile_id).unwrap().remove(id);
        after.output_bindings.remove(id);
        assert!(!valid_operation_delta(&before, &after, &operation));
    }

    #[test]
    fn element_output_delta_reconstructs_semantic_keys_and_rejects_raw_substitution() {
        use crate::draft_operation::{
            ElementInputPart, ElementOutputChanges, GamepadOutputEdit, KeyboardOutputEdit,
            SemanticKeyStroke,
        };

        let before = serde_json::json!({
            "output": {
                "keyboard": {"keyCode": 13, "modifiersRawValue": 2},
                "gamepadButtons": ["south"]
            },
            "partOutputs": []
        });
        let changes = ElementOutputChanges {
            part: ElementInputPart::Primary,
            keyboard_edit: KeyboardOutputEdit::Set {
                sequence: vec![SemanticKeyStroke {
                    key: "UpArrow".to_owned(),
                    modifiers: Vec::new(),
                }],
            },
            gamepad_edit: GamepadOutputEdit::Clear,
        };
        let exact = serde_json::json!({
            "output": {
                "keyboard": {"keyCode": 126, "modifiersRawValue": 0},
                "gamepadButtons": []
            },
            "partOutputs": []
        });
        assert!(element_output_change_is_exact(
            Some(&before),
            Some(&exact),
            Some(&changes)
        ));
        let mut substituted = exact.clone();
        substituted["output"]["keyboard"]["keyCode"] = serde_json::json!(125);
        assert!(!element_output_change_is_exact(
            Some(&before),
            Some(&substituted),
            Some(&changes)
        ));
        let part_changes = ElementOutputChanges {
            part: ElementInputPart::JoystickUp,
            keyboard_edit: KeyboardOutputEdit::Set {
                sequence: vec![SemanticKeyStroke {
                    key: "W".to_owned(),
                    modifiers: Vec::new(),
                }],
            },
            gamepad_edit: GamepadOutputEdit::Clear,
        };
        let part = serde_json::json!({
            "output": before["output"].clone(),
            "partOutputs": [
                "joystick_up",
                {"keyboard":{"keyCode":13,"modifiersRawValue":0},"gamepadButtons":[]}
            ]
        });
        assert!(element_output_change_is_exact(
            Some(&before),
            Some(&part),
            Some(&part_changes)
        ));
    }

    #[test]
    fn executable_checks_reject_symlinks_and_writable_files() {
        let directory = tempdir().unwrap();
        let executable = directory.path().join("bridge");
        fs::write(&executable, "#!/bin/sh\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(ConfigurationBridge::at_path(executable.clone()).is_ok());
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o775)).unwrap();
        assert!(matches!(
            ConfigurationBridge::at_path(executable.clone()),
            Err(ConfigurationBridgeError::InsecureExecutable)
        ));
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        let link = directory.path().join("bridge-link");
        symlink(&executable, &link).unwrap();
        assert!(matches!(
            ConfigurationBridge::at_path(link),
            Err(ConfigurationBridgeError::InsecureExecutable)
        ));
    }

    #[test]
    fn constrained_process_round_trip_validates_unchanged_document() {
        let directory = tempdir().unwrap();
        let executable = directory.path().join("bridge");
        fs::write(
            &executable,
            r##"#!/usr/bin/python3
import json,sys
request=json.loads(sys.stdin.readline())
print(json.dumps({"schemaVersion":1,"document":request["document"],"changed":False,"changedPaths":[]},separators=(",",":")))
"##,
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let bridge = ConfigurationBridge::at_path(executable).unwrap();
        let document = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let operation = ConfigurationOperation::ProfileSelect {
            profile_id: document.active_profile_id.clone(),
        };
        let (candidate, outcome) = bridge.apply(&document, &operation, 1).unwrap();
        assert_eq!(candidate, document);
        assert!(!outcome.changed);
        assert!(outcome.changed_paths.is_empty());
    }

    #[test]
    fn operation_specific_delta_rejects_unrelated_profile_mutation() {
        let directory = tempdir().unwrap();
        let executable = directory.path().join("bridge");
        fs::write(
            &executable,
            r##"#!/usr/bin/python3
import json,sys
request=json.loads(sys.stdin.readline())
request["document"]["profiles"][0]["name"]="injected"
print(json.dumps({"schemaVersion":1,"document":request["document"],"changed":True,"changedPaths":["/activeProfileID"]},separators=(",",":")))
"##,
        )
        .unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let bridge = ConfigurationBridge::at_path(executable).unwrap();
        let document = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let operation = ConfigurationOperation::ProfileSelect {
            profile_id: document.active_profile_id.clone(),
        };
        assert!(matches!(
            bridge.apply(&document, &operation, 1),
            Err(ConfigurationBridgeError::InvalidResponse)
        ));
    }

    #[test]
    fn customization_delta_accepts_only_primary_and_its_orientation_mirror() {
        let before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let mut after = before.clone();
        let profile = after.profiles[0].as_object_mut().unwrap();
        let changed_customization =
            serde_json::json!({"deviceCanvas":{"frameID":"iphone-17-pro-landscape"}});
        profile.insert("customization".to_owned(), changed_customization.clone());
        profile.insert("landscapeCustomization".to_owned(), changed_customization);
        profile.insert("updatedAt".to_owned(), serde_json::Value::from(1));
        let operation = ConfigurationOperation::ThemeApply {
            profile_id,
            variant: crate::draft_operation::ConfigurationVariant::Primary,
            preset: "cavern-glow".to_owned(),
        };
        assert!(valid_operation_delta(&before, &after, &operation));

        after.profiles[0]["name"] = serde_json::Value::String("injected".to_owned());
        assert!(!valid_operation_delta(&before, &after, &operation));
    }

    #[test]
    fn orientation_copy_delta_reconstructs_primary_fallback_and_rejects_injection() {
        use crate::draft_operation::OrientationVariant;

        let mut before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let hidden = serde_json::json!({
            "widthScale":1,
            "heightScale":1,
            "rotationDegrees":0,
            "zIndex":0,
            "shadowStrength":1,
            "isLocationLocked":false,
            "isHidden":true
        });
        let mut button_customizations = Vec::new();
        for button in ORIENTATION_BUILTINS {
            button_customizations.push(Value::String(button.to_owned()));
            button_customizations.push(hidden.clone());
        }
        let element_id = "00000000-0000-0000-0000-000000000991";
        let source_layout = serde_json::json!({
            "centerX":0.8,
            "centerY":0.25,
            "widthScale":1,
            "heightScale":1,
            "rotationDegrees":0,
            "zIndex":0,
            "shadowStrength":1,
            "isLocationLocked":false,
            "isHidden":false
        });
        let source = serde_json::json!({
            "deviceCanvas":{"frameID":"iphone-17-pro-landscape"},
            "buttonCustomizations":button_customizations,
            "customButtons":[{
                "id":element_id,
                "mappedButton":"custom1",
                "label":"Custom",
                "controlKind":"button",
                "layout":source_layout
            }],
            "elements":[{
                "id":element_id,
                "label":"Custom",
                "kind":"button",
                "layout":source_layout,
                "legacySlot":"custom1",
                "partOutputs":[]
            }],
            "topBarActivationRegion":{
                "centerX":0.5,
                "centerY":0.115,
                "widthScale":1,
                "heightScale":1,
                "rotationDegrees":0,
                "zIndex":100,
                "shape":"capsule",
                "accentStyle":"blue",
                "icon":{"source":"sf_symbol","value":"chevron.down","renderingMode":"template","placement":"center","scale":1},
                "cornerRadius":18,
                "shadowStrength":0.35,
                "isLocationLocked":false,
                "isHidden":true
            },
            "futureCustomization":{"kept":true}
        });
        before.profiles[0]["customization"] = source.clone();
        before.profiles[0]
            .as_object_mut()
            .unwrap()
            .remove("landscapeCustomization");
        before.profiles[0]
            .as_object_mut()
            .unwrap()
            .remove("portraitCustomization");

        let mut destination = source.clone();
        destination["deviceCanvas"]["frameID"] = Value::String("iphone-17-pro-portrait".to_owned());
        destination["customButtons"][0]["layout"]["centerX"] = Value::from(0.25);
        destination["customButtons"][0]["layout"]["centerY"] = Value::from(0.2);
        destination["elements"][0]["layout"]["centerX"] = Value::from(0.25);
        destination["elements"][0]["layout"]["centerY"] = Value::from(0.2);
        let mut after = before.clone();
        after.profiles[0]["landscapeCustomization"] = source.clone();
        after.profiles[0]["portraitCustomization"] = destination.clone();
        after.profiles[0]["customization"] = destination.clone();
        after.profiles[0]["updatedAt"] = Value::from(123);
        let operation = ConfigurationOperation::OrientationCopy {
            profile_id: profile_id.clone(),
            source: OrientationVariant::Landscape,
            destination: OrientationVariant::Portrait,
            automatically_arrange: true,
        };
        assert!(valid_operation_delta(&before, &after, &operation));

        let mut injected = after.clone();
        injected.profiles[0]["portraitCustomization"]["customButtons"][0]["layout"]["path"] =
            Value::String("/tmp/private".to_owned());
        injected.profiles[0]["customization"] =
            injected.profiles[0]["portraitCustomization"].clone();
        assert!(!valid_operation_delta(&before, &injected, &operation));

        let mut copied_without_arrangement = before.clone();
        let mut unarranged = source.clone();
        unarranged["deviceCanvas"]["frameID"] = Value::String("iphone-17-pro-portrait".to_owned());
        copied_without_arrangement.profiles[0]["landscapeCustomization"] = source;
        copied_without_arrangement.profiles[0]["portraitCustomization"] = unarranged.clone();
        copied_without_arrangement.profiles[0]["customization"] = unarranged;
        copied_without_arrangement.profiles[0]["updatedAt"] = Value::from(124);
        let no_arrange = ConfigurationOperation::OrientationCopy {
            profile_id,
            source: OrientationVariant::Landscape,
            destination: OrientationVariant::Portrait,
            automatically_arrange: false,
        };
        assert!(valid_operation_delta(
            &before,
            &copied_without_arrangement,
            &no_arrange
        ));
    }

    #[test]
    fn scalar_customization_delta_requires_the_exact_requested_fields() {
        use crate::draft_operation::{
            ConfigurationBackgroundEdit, ConfigurationLayoutMode, ConfigurationVariant,
            CustomizationChanges,
        };

        let before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let operation = ConfigurationOperation::CustomizationSet {
            profile_id,
            variant: ConfigurationVariant::Primary,
            changes: CustomizationChanges {
                layout_mode: Some(ConfigurationLayoutMode::Southpaw),
                control_scale: None,
                color_scheme: None,
                accent_style: None,
                shows_button_labels: None,
                background_edit: ConfigurationBackgroundEdit::Keep,
            },
        };
        let mut after = before.clone();
        let profile = after.profiles[0].as_object_mut().unwrap();
        let mut changed = profile["customization"].clone();
        changed["layoutMode"] = Value::String("southpaw".to_owned());
        profile.insert("customization".to_owned(), changed.clone());
        profile.insert("landscapeCustomization".to_owned(), changed.clone());
        profile.insert("updatedAt".to_owned(), Value::from(1));
        assert!(valid_operation_delta(&before, &after, &operation));

        let device = ConfigurationOperation::DeviceSet {
            profile_id: before.active_profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            frame_id: "iphone-15-pro-landscape".to_owned(),
        };
        let mut device_after = before.clone();
        let mut device_customization = device_after.profiles[0]["customization"].clone();
        device_customization["deviceCanvas"] =
            serde_json::json!({"frameID":"iphone-15-pro-landscape"});
        device_after.profiles[0]["customization"] = device_customization.clone();
        device_after.profiles[0]["landscapeCustomization"] = device_customization;
        device_after.profiles[0]["updatedAt"] = Value::from(1);
        assert!(valid_operation_delta(&before, &device_after, &device));

        after.profiles[0]["customization"]["accentStyle"] = Value::String("purple".to_owned());
        after.profiles[0]["landscapeCustomization"] = after.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &after, &operation));
    }

    #[test]
    fn device_set_accepts_only_source_preserving_current_orientation_mirrors() {
        let fixture: Value = thumble_protocol::decode_unique_json(include_bytes!(
            "../tests/fixtures/current-native-device-set-v1.json"
        )).unwrap();
        let before: ConfigurationDocument = serde_json::from_value(fixture["before"].clone()).unwrap();
        let after: ConfigurationDocument = serde_json::from_value(fixture["after"].clone()).unwrap();
        let operation: ConfigurationOperation = serde_json::from_value(fixture["operation"].clone()).unwrap();
        before.validate().unwrap();
        after.validate().unwrap();
        assert!(valid_operation_delta(&before, &after, &operation), "generic={}, constrained={}",
            customization_operation_delta(&before, &after, &before.active_profile_id, crate::draft_operation::ConfigurationVariant::Primary),
            constrained_customization_operation_delta(&before, &after, &operation));
        let index = profile_position(&after, &after.active_profile_id).unwrap();
        let mut lossy = after.clone();
        lossy.profiles[index]["landscapeCustomization"]["elements"][0]
            .as_object_mut().unwrap().remove("futureElement");
        assert!(!valid_operation_delta(&before, &lossy, &operation));
        let mut injected = after.clone();
        for field in ["customization", "landscapeCustomization"] {
            injected.profiles[index][field]["elements"][0]["output"] = serde_json::json!({"gamepadButtons":["south"]});
        }
        assert!(!valid_operation_delta(&before, &injected, &operation));
    }

    #[test]
    fn control_bar_collection_delta_reconstructs_sparse_defaults_and_variant_frames() {
        use crate::draft_operation::{ConfigurationControlBarItem, ConfigurationVariant};
        let before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let remove = ConfigurationOperation::ControlBarRemove {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            item: ConfigurationControlBarItem::Home,
        };
        let mut removed = before.clone();
        let mut customization = removed.profiles[0]["customization"].clone();
        customization["controlBarItems"] = serde_json::json!([
            "status",
            "profile_menu",
            "launch_target",
            "spacer",
            "edit_layout",
            "settings",
            "connection"
        ]);
        removed.profiles[0]["customization"] = customization.clone();
        removed.profiles[0]["landscapeCustomization"] = customization;
        removed.profiles[0]["updatedAt"] = Value::from(1);
        assert!(valid_operation_delta(&before, &removed, &remove));

        let portrait = ConfigurationOperation::ControlBarSet {
            profile_id,
            variant: ConfigurationVariant::Portrait,
            items: vec![ConfigurationControlBarItem::Home],
        };
        let mut portrait_result = before.clone();
        let original = portrait_result.profiles[0]["customization"].clone();
        let mut changed = original.clone();
        changed["controlBarItems"] = serde_json::json!(["home"]);
        changed["deviceCanvas"] = serde_json::json!({"frameID":"iphone-17-pro-portrait"});
        portrait_result.profiles[0]["customization"] = changed.clone();
        portrait_result.profiles[0]["portraitCustomization"] = changed;
        portrait_result.profiles[0]["landscapeCustomization"] = original;
        portrait_result.profiles[0]["updatedAt"] = Value::from(2);
        assert!(valid_operation_delta(&before, &portrait_result, &portrait));

        portrait_result.profiles[0]["customization"]["futurePath"] =
            Value::String("/tmp/injected".to_owned());
        portrait_result.profiles[0]["portraitCustomization"] =
            portrait_result.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &portrait_result, &portrait));
    }

    #[test]
    fn control_bar_item_set_delta_reconstructs_exact_target_and_rejects_injection() {
        use crate::draft_operation::{
            ConfigurationControlBarItem, ConfigurationVariant, ControlBarItemChanges,
        };

        let mut before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let mut customization = before.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        customization.insert(
            "controlBarItems".to_owned(),
            serde_json::json!(["home", "settings"]),
        );
        let mut home = default_button_layout();
        home.insert("widthScale".to_owned(), Value::from(1.1));
        let mut settings = default_button_layout();
        settings.insert("widthScale".to_owned(), Value::from(1.3));
        customization.insert(
            "controlBarItemCustomizations".to_owned(),
            serde_json::json!([
                {
                    "item":"home",
                    "appearance":home,
                    "futureSibling":{"kept":true}
                },
                {
                    "item":"settings",
                    "appearance":settings,
                    "futureEntry":{"kept":true}
                }
            ]),
        );
        before.profiles[0]["customization"] = Value::Object(customization.clone());
        before.profiles[0]["landscapeCustomization"] = Value::Object(customization.clone());

        let operation = ConfigurationOperation::ControlBarItemSet {
            profile_id,
            variant: ConfigurationVariant::Primary,
            item: ConfigurationControlBarItem::Settings,
            changes: Box::new(ControlBarItemChanges {
                width_scale: Some(1.8),
                is_hidden: Some(true),
                ..ControlBarItemChanges::default()
            }),
        };
        let mut changed_customization = customization;
        let values = changed_customization["controlBarItemCustomizations"]
            .as_array_mut()
            .unwrap();
        let target = values
            .iter_mut()
            .find(|value| value["item"] == "settings")
            .unwrap();
        target["appearance"]["widthScale"] = Value::from(1.8);
        target["appearance"]["isHidden"] = Value::Bool(true);
        let mut after = before.clone();
        let profile = after.profiles[0].as_object_mut().unwrap();
        profile.insert(
            "customization".to_owned(),
            Value::Object(changed_customization.clone()),
        );
        profile.insert(
            "landscapeCustomization".to_owned(),
            Value::Object(changed_customization),
        );
        profile.insert("updatedAt".to_owned(), Value::from(1));
        assert!(valid_operation_delta(&before, &after, &operation));

        let landscape_operation = ConfigurationOperation::ControlBarItemSet {
            profile_id: before.active_profile_id.clone(),
            variant: ConfigurationVariant::Landscape,
            item: ConfigurationControlBarItem::Settings,
            changes: Box::new(ControlBarItemChanges {
                is_hidden: Some(true),
                ..ControlBarItemChanges::default()
            }),
        };
        let mut landscape_customization = before.profiles[0]["landscapeCustomization"].clone();
        landscape_customization["controlBarItemCustomizations"][1]["appearance"]["isHidden"] =
            Value::Bool(true);
        let mut landscape_after = before.clone();
        landscape_after.profiles[0]["customization"] = landscape_customization.clone();
        landscape_after.profiles[0]["landscapeCustomization"] = landscape_customization;
        landscape_after.profiles[0]["updatedAt"] = Value::from(1);
        assert!(valid_operation_delta(
            &before,
            &landscape_after,
            &landscape_operation
        ));

        let mut sibling = after.clone();
        sibling.profiles[0]["customization"]["controlBarItemCustomizations"][0]["appearance"]
            ["widthScale"] = Value::from(9.0);
        sibling.profiles[0]["landscapeCustomization"] =
            sibling.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &sibling, &operation));

        for (path, value) in [
            ("path", serde_json::json!("/tmp/private")),
            ("assetID", serde_json::json!("secret-asset")),
            ("image", serde_json::json!({"data":"AAAA"})),
            ("launchTarget", serde_json::json!({"argv":["--secret"]})),
        ] {
            let mut injected = after.clone();
            injected.profiles[0]["customization"]["controlBarItemCustomizations"][1]
                ["appearance"][path] = value;
            injected.profiles[0]["landscapeCustomization"] =
                injected.profiles[0]["customization"].clone();
            assert!(
                !valid_operation_delta(&before, &injected, &operation),
                "{path}"
            );
        }

        let mut style_library = after.clone();
        style_library.profiles[0]["customization"]["styleLibrary"] =
            serde_json::json!({"styles":[{"id":"injected"}]});
        style_library.profiles[0]["landscapeCustomization"] =
            style_library.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &style_library, &operation));
        let mut profile_injection = after.clone();
        profile_injection.profiles[0]["name"] = Value::String("Injected".to_owned());
        assert!(!valid_operation_delta(
            &before,
            &profile_injection,
            &operation
        ));
    }

    #[test]
    fn layer_delta_requires_the_exact_requested_order_only() {
        use crate::draft_operation::{ConfigurationVariant, LayerMoveDestination};

        let mut before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let mut initial = before.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        let mut initial_order = normalized_layer_order(&initial).unwrap();
        let jump = initial_order
            .iter_mut()
            .find(|identity| layer_identity_key(identity).as_deref() == Some("builtin:00000000-0000-0000-0000-000000000105"))
            .unwrap();
        jump.as_object_mut().unwrap().insert(
            "futureIdentity".to_owned(),
            serde_json::json!({"kept": true}),
        );
        initial.insert(
            "designMetadata".to_owned(),
            serde_json::json!({
                "schemaVersion": 1,
                "layerOrder": initial_order,
                "groups": [],
                "grid": {
                    "gridSize": 16,
                    "showsGrid": false,
                    "snapToGrid": false,
                    "snapToObjects": true,
                    "snapTolerance": 6
                },
                "guides": [],
                "tags": []
            }),
        );
        before.profiles[0]["customization"] = Value::Object(initial);
        let profile_id = before.active_profile_id.clone();
        let operation = ConfigurationOperation::LayerMove {
            profile_id,
            variant: ConfigurationVariant::Primary,
            element_id: "00000000-0000-0000-0000-000000000105".to_owned(),
            destination: LayerMoveDestination::After {
                element_id: "00000000-0000-0000-0000-000000000106".to_owned(),
            },
        };
        let mut after = before.clone();
        let profile = after.profiles[0].as_object_mut().unwrap();
        let mut changed = profile["customization"].as_object().unwrap().clone();
        let mut order = normalized_layer_order(&changed).unwrap();
        let jump = resolve_layer_identity(&changed, "builtin.00000000-0000-0000-0000-000000000105").unwrap();
        let attack = resolve_layer_identity(&changed, "builtin.00000000-0000-0000-0000-000000000106").unwrap();
        let source = layer_order_position(&order, &jump).unwrap();
        let destination = layer_order_position(&order, &attack).unwrap() + 1;
        let moving = order.remove(source);
        order.insert(destination, moving);
        assert!(set_expected_layer_order(&mut changed, order));
        let changed = Value::Object(changed);
        profile.insert("customization".to_owned(), changed.clone());
        profile.insert("landscapeCustomization".to_owned(), changed);
        profile.insert("updatedAt".to_owned(), Value::from(1));
        assert!(valid_operation_delta(&before, &after, &operation));
        let moved_jump = after.profiles[0]["customization"]["designMetadata"]["layerOrder"]
            .as_array()
            .unwrap()
            .iter()
            .find(|identity| layer_identity_key(identity).as_deref() == Some("builtin:00000000-0000-0000-0000-000000000105"))
            .unwrap();
        assert_eq!(moved_jump["futureIdentity"]["kept"], true);

        let restore = ConfigurationOperation::LayerMove {
            profile_id: before.active_profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            element_id: "builtin.00000000-0000-0000-0000-000000000105".to_owned(),
            destination: LayerMoveDestination::Index { index: 5 },
        };
        let before_restore = after.clone();
        let mut restored = before_restore.clone();
        let profile = restored.profiles[0].as_object_mut().unwrap();
        let mut restored_customization = profile["customization"].as_object().unwrap().clone();
        let mut restored_order = normalized_layer_order(&restored_customization).unwrap();
        let jump = resolve_layer_identity(&restored_customization, "builtin.00000000-0000-0000-0000-000000000105").unwrap();
        let source = layer_order_position(&restored_order, &jump).unwrap();
        let moving = restored_order.remove(source);
        restored_order.insert(5, moving);
        assert!(set_expected_layer_order(
            &mut restored_customization,
            restored_order
        ));
        let restored_customization = Value::Object(restored_customization);
        profile.insert("customization".to_owned(), restored_customization.clone());
        profile.insert("landscapeCustomization".to_owned(), restored_customization);
        profile.insert("updatedAt".to_owned(), Value::from(2));
        assert!(valid_operation_delta(&before_restore, &restored, &restore));
        assert_eq!(
            restored.profiles[0]["customization"]["designMetadata"]["layerOrder"]
                .as_array()
                .unwrap()
                .iter()
                .find(|identity| {
                    layer_identity_key(identity).as_deref() == Some("builtin:00000000-0000-0000-0000-000000000105")
                })
                .unwrap()["futureIdentity"]["kept"],
            true
        );

        after.profiles[0]["customization"]["designMetadata"]["groups"] =
            serde_json::json!([{"id":"00000000-0000-0000-0000-000000000999"}]);
        after.profiles[0]["landscapeCustomization"] = after.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &after, &operation));
    }

    #[test]
    fn group_delta_requires_exact_membership_and_requested_metadata() {
        use crate::draft_operation::ConfigurationVariant;

        let before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let group_id = "00000000-0000-0000-0000-000000000701";
        let operation = ConfigurationOperation::GroupCreate {
            profile_id,
            variant: ConfigurationVariant::Primary,
            group_id: group_id.to_owned(),
            name: "Actions".to_owned(),
            element_ids: vec!["builtin.00000000-0000-0000-0000-000000000105".to_owned(), "builtin.00000000-0000-0000-0000-000000000106".to_owned()],
        };
        let mut after = before.clone();
        let mut customization = before.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        let jump = resolve_layer_identity(&customization, "builtin.00000000-0000-0000-0000-000000000105").unwrap();
        let attack = resolve_layer_identity(&customization, "builtin.00000000-0000-0000-0000-000000000106").unwrap();
        let group = serde_json::json!({
            "id": canonical_uuid_string(group_id),
            "name": "Actions",
            "children": [jump, attack],
            "isLocked": false,
            "isHidden": false
        })
        .as_object()
        .unwrap()
        .clone();
        assert!(set_expected_groups(&mut customization, vec![group]));
        let customization = Value::Object(customization);
        let profile = after.profiles[0].as_object_mut().unwrap();
        profile.insert("customization".to_owned(), customization.clone());
        profile.insert("landscapeCustomization".to_owned(), customization);
        profile.insert("updatedAt".to_owned(), Value::from(1));
        assert!(valid_operation_delta(&before, &after, &operation));

        let mut raw_metadata_before = before.clone();
        raw_metadata_before.profiles[0]["customization"]["designMetadata"] = serde_json::json!({
            "schemaVersion": 1,
            "layerOrder": [],
            "groups": [],
            "grid": {
                "gridSize": 16,
                "showsGrid": false,
                "snapToGrid": false,
                "snapToObjects": true,
                "snapTolerance": 6
            },
            "guides": [],
            "tags": [],
            "futureNested": {"kept": true}
        });
        let mut raw_metadata_after = raw_metadata_before.clone();
        let mut raw_customization = raw_metadata_before.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        let jump = resolve_layer_identity(&raw_customization, "builtin.00000000-0000-0000-0000-000000000105").unwrap();
        let attack = resolve_layer_identity(&raw_customization, "builtin.00000000-0000-0000-0000-000000000106").unwrap();
        let group = serde_json::json!({
            "id": canonical_uuid_string(group_id),
            "name": "Actions",
            "children": [jump, attack],
            "isLocked": false,
            "isHidden": false
        })
        .as_object()
        .unwrap()
        .clone();
        assert!(set_expected_groups(&mut raw_customization, vec![group]));
        raw_metadata_after.profiles[0]["customization"] = Value::Object(raw_customization.clone());
        raw_metadata_after.profiles[0]["landscapeCustomization"] = Value::Object(raw_customization);
        raw_metadata_after.profiles[0]["updatedAt"] = Value::from(1);
        assert!(valid_operation_delta(
            &raw_metadata_before,
            &raw_metadata_after,
            &operation
        ));

        let landscape_operation = ConfigurationOperation::GroupCreate {
            profile_id: raw_metadata_before.active_profile_id.clone(),
            variant: ConfigurationVariant::Landscape,
            group_id: group_id.to_owned(),
            name: "Actions".to_owned(),
            element_ids: vec!["builtin.00000000-0000-0000-0000-000000000105".to_owned(), "builtin.00000000-0000-0000-0000-000000000106".to_owned()],
        };
        let mut landscape_before = raw_metadata_before.clone();
        landscape_before.profiles[0]["landscapeCustomization"] =
            landscape_before.profiles[0]["customization"].clone();
        let mut landscape_after = raw_metadata_after.clone();
        landscape_after.profiles[0]["landscapeCustomization"] =
            raw_metadata_after.profiles[0]["customization"].clone();
        landscape_after.profiles[0]["customization"]["deviceCanvas"] =
            serde_json::json!({"frameID": "iphone-17-pro-landscape"});
        assert!(valid_operation_delta(
            &landscape_before,
            &landscape_after,
            &landscape_operation
        ));

        raw_metadata_after.profiles[0]["customization"]["designMetadata"]
            .as_object_mut()
            .unwrap()
            .remove("futureNested");
        raw_metadata_after.profiles[0]["landscapeCustomization"] =
            raw_metadata_after.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(
            &raw_metadata_before,
            &raw_metadata_after,
            &operation
        ));

        after.profiles[0]["customization"]["designMetadata"]["groups"][0]["name"] =
            Value::String("Injected".to_owned());
        after.profiles[0]["landscapeCustomization"] = after.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &after, &operation));
    }

    #[test]
    fn group_state_delta_reconstructs_children_and_rejects_unrelated_mutation() {
        use crate::draft_operation::ConfigurationVariant;

        let mut before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let group_id = "00000000-0000-0000-0000-000000000702";
        let mut customization = before.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        let children = vec![
            resolve_layer_identity(&customization, "builtin.00000000-0000-0000-0000-000000000105").unwrap(),
            resolve_layer_identity(&customization, "builtin.00000000-0000-0000-0000-000000000106").unwrap(),
        ];
        let group = serde_json::json!({
            "id": canonical_uuid_string(group_id),
            "name": "Actions",
            "children": children,
            "isLocked": false,
            "isHidden": false
        })
        .as_object()
        .unwrap()
        .clone();
        assert!(set_expected_groups(&mut customization, vec![group]));
        before.profiles[0]["customization"] = Value::Object(customization.clone());
        before.profiles[0]["landscapeCustomization"] = Value::Object(customization);

        let hide = ConfigurationOperation::GroupHide {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            group_id: group_id.to_owned(),
        };
        let mut hidden = before.clone();
        let mut hidden_customization = before.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        let mut groups = saved_layer_groups(&hidden_customization).unwrap();
        group_by_id_mut(&mut groups, group_id)
            .unwrap()
            .insert("isHidden".to_owned(), Value::Bool(true));
        assert!(set_expected_groups(&mut hidden_customization, groups));
        assert!(set_group_children_layout_state(
            &mut hidden_customization,
            &children,
            "isHidden",
            true
        ));
        let profile = hidden.profiles[0].as_object_mut().unwrap();
        profile.insert(
            "customization".to_owned(),
            Value::Object(hidden_customization.clone()),
        );
        profile.insert(
            "landscapeCustomization".to_owned(),
            Value::Object(hidden_customization),
        );
        profile.insert("updatedAt".to_owned(), Value::from(1));
        assert!(valid_operation_delta(&before, &hidden, &hide));

        let mut injected = hidden.clone();
        injected.profiles[0]["customization"]["accentStyle"] = Value::String("purple".to_owned());
        injected.profiles[0]["landscapeCustomization"] =
            injected.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &injected, &hide));

        let show = ConfigurationOperation::GroupShow {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            group_id: group_id.to_owned(),
        };
        let mut shown = hidden.clone();
        let mut shown_customization = hidden.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        let mut groups = saved_layer_groups(&shown_customization).unwrap();
        group_by_id_mut(&mut groups, group_id)
            .unwrap()
            .insert("isHidden".to_owned(), Value::Bool(false));
        assert!(set_expected_groups(&mut shown_customization, groups));
        assert!(set_group_children_layout_state(
            &mut shown_customization,
            &children,
            "isHidden",
            false
        ));
        let profile = shown.profiles[0].as_object_mut().unwrap();
        profile.insert(
            "customization".to_owned(),
            Value::Object(shown_customization.clone()),
        );
        profile.insert(
            "landscapeCustomization".to_owned(),
            Value::Object(shown_customization),
        );
        profile.insert("updatedAt".to_owned(), Value::from(2));
        assert!(valid_operation_delta(&hidden, &shown, &show));

        let mut state = shown;
        for (index, (operation, desired)) in [
            (
                ConfigurationOperation::GroupLock {
                    profile_id: profile_id.clone(),
                    variant: ConfigurationVariant::Primary,
                    group_id: group_id.to_owned(),
                },
                true,
            ),
            (
                ConfigurationOperation::GroupUnlock {
                    profile_id: profile_id.clone(),
                    variant: ConfigurationVariant::Primary,
                    group_id: group_id.to_owned(),
                },
                false,
            ),
        ]
        .into_iter()
        .enumerate()
        {
            let mut candidate = state.clone();
            let mut expected = state.profiles[0]["customization"]
                .as_object()
                .unwrap()
                .clone();
            let mut groups = saved_layer_groups(&expected).unwrap();
            group_by_id_mut(&mut groups, group_id)
                .unwrap()
                .insert("isLocked".to_owned(), Value::Bool(desired));
            assert!(set_expected_groups(&mut expected, groups));
            assert!(set_group_children_layout_state(
                &mut expected,
                &children,
                "isLocationLocked",
                desired
            ));
            let profile = candidate.profiles[0].as_object_mut().unwrap();
            profile.insert("customization".to_owned(), Value::Object(expected.clone()));
            profile.insert("landscapeCustomization".to_owned(), Value::Object(expected));
            profile.insert("updatedAt".to_owned(), Value::from(3 + index));
            assert!(valid_operation_delta(&state, &candidate, &operation));
            state = candidate;
        }
    }

    #[test]
    fn group_nudge_delta_reconstructs_requested_positions_and_rejects_injection() {
        use crate::draft_operation::ConfigurationVariant;

        let mut before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let group_id = "00000000-0000-0000-0000-000000000703";
        let mut customization = before.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        let children = vec![
            resolve_layer_identity(&customization, "builtin.00000000-0000-0000-0000-000000000105").unwrap(),
            resolve_layer_identity(&customization, "builtin.00000000-0000-0000-0000-000000000106").unwrap(),
        ];
        let group = serde_json::json!({
            "id": canonical_uuid_string(group_id),
            "name": "Actions",
            "children": children,
            "isLocked": false,
            "isHidden": false
        })
        .as_object()
        .unwrap()
        .clone();
        assert!(set_expected_groups(&mut customization, vec![group]));
        before.profiles[0]["customization"] = Value::Object(customization.clone());
        before.profiles[0]["landscapeCustomization"] = Value::Object(customization.clone());

        let operation = ConfigurationOperation::GroupNudge {
            profile_id,
            variant: ConfigurationVariant::Primary,
            group_id: group_id.to_owned(),
            canvas_frame_id: "iphone-17-pro-landscape".to_owned(),
            delta_x: 10.0,
            delta_y: -5.0,
        };
        let (canvas_width, canvas_height) = nudge_canvas_size("iphone-17-pro-landscape").unwrap();
        let mut moved = customization;
        for child in &children {
            let identity = layer_identity_key(child).unwrap();
            let snapshot =
                group_nudge_snapshot(&moved, &identity, canvas_width, canvas_height).unwrap();
            assert!(snapshot.eligible);
            assert!(set_group_child_position(
                &mut moved,
                &identity,
                (snapshot.center_x + 10.0) / canvas_width,
                (snapshot.center_y - 5.0) / canvas_height,
            ));
        }
        let mut after = before.clone();
        let profile = after.profiles[0].as_object_mut().unwrap();
        profile.insert("customization".to_owned(), Value::Object(moved.clone()));
        profile.insert("landscapeCustomization".to_owned(), Value::Object(moved));
        profile.insert("updatedAt".to_owned(), Value::from(1));
        assert!(valid_operation_delta(&before, &after, &operation));

        let mut injected = after.clone();
        injected.profiles[0]["customization"]["accentStyle"] = Value::String("purple".to_owned());
        injected.profiles[0]["landscapeCustomization"] =
            injected.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &injected, &operation));

        let mut wrong_distance = after;
        let mut wrong = wrong_distance.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        let identity = layer_identity_key(&children[0]).unwrap();
        let (x, y) = group_child_position(&wrong, &identity).unwrap();
        assert!(set_group_child_position(&mut wrong, &identity, x + 0.01, y));
        wrong_distance.profiles[0]["customization"] = Value::Object(wrong.clone());
        wrong_distance.profiles[0]["landscapeCustomization"] = Value::Object(wrong);
        assert!(!valid_operation_delta(&before, &wrong_distance, &operation));
    }

    #[test]
    fn style_delta_reconstructs_exact_token_and_rejects_injection() {
        use crate::draft_operation::{
            ConfigurationRgbaColor, StyleAppearance, StyleHaptic, StyleHapticKind,
            StyleHapticPattern, StyleIcon, StyleIconSource, StyleMaterialPreset, StyleShadow,
        };

        let before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let operation = ConfigurationOperation::StyleCreate {
            profile_id: profile_id.clone(),
            style_id: "agent-style".to_owned(),
            name: "Agent Style".to_owned(),
            appearance: Box::new(StyleAppearance {
                material_preset: Some(StyleMaterialPreset::SoftWhiteRaised),
                fill_color: Some(ConfigurationRgbaColor {
                    red: 0.1,
                    green: 0.2,
                    blue: 0.3,
                    alpha: 0.4,
                }),
                shadows: Some(vec![StyleShadow {
                    color: ConfigurationRgbaColor {
                        red: 0.2,
                        green: 0.3,
                        blue: 0.4,
                        alpha: 0.5,
                    },
                    radius: 6.0,
                    x: 2.0,
                    y: 3.0,
                    opacity: 0.4,
                }]),
                pressed_scale: Some(0.9),
                icon: Some(StyleIcon {
                    source: StyleIconSource::SfSymbol,
                    value: "star.fill".to_owned(),
                }),
                haptic: Some(StyleHaptic {
                    style: Some(StyleHapticKind::Rigid),
                    pattern: Some(StyleHapticPattern::Double),
                    intensity: Some(0.7),
                    sharpness: Some(0.8),
                    duration: Some(0.1),
                }),
                ..StyleAppearance::default()
            }),
        };
        let mut after = before.clone();
        let profile = after.profiles[0].as_object_mut().unwrap();
        let customization = profile
            .get_mut("customization")
            .and_then(Value::as_object_mut)
            .unwrap();
        assert!(apply_style_resource_operation(customization, &operation));
        profile.insert("updatedAt".to_owned(), Value::from(123));
        assert!(valid_operation_delta(&before, &after, &operation));

        let style = after.profiles[0]
            .get_mut("customization")
            .and_then(|value| value.get_mut("styleLibrary"))
            .and_then(|value| value.get_mut("styles"))
            .and_then(Value::as_array_mut)
            .and_then(|styles| styles.first_mut())
            .and_then(Value::as_object_mut)
            .unwrap();
        style.insert(
            "launchTarget".to_owned(),
            Value::String("injected".to_owned()),
        );
        assert!(!valid_operation_delta(&before, &after, &operation));
    }

    #[test]
    fn style_reference_cleanup_reconstructs_all_control_mirrors() {
        let custom_id = "00000000-0000-0000-0000-000000000901";
        let mut customization = serde_json::json!({
            "buttonCustomizations":["00000000-0000-0000-0000-000000000105",{
                "widthScale":1,"heightScale":1,"rotationDegrees":0,"zIndex":0,
                "shadowStrength":1,"isLocationLocked":false,"isHidden":false,
                "styleID":"target"
            }],
            "customButtons":[{"id":custom_id,"layout":{"styleID":"target"}}],
            "elements":[
                {"id":"00000000-0000-0000-0000-000000000105","kind":"button","layout":{"styleID":"target"}},
                {"id":custom_id,"layout":{"styleID":"target"}},
                {"id":"B79F4CF4-C998-47F3-98DC-64866576CA20","kind":"button","layout":{"styleID":"target"}}
            ],
            "topBarActivationRegion":{"styleID":"target"},
            "controlBarItemCustomizations":[
                {"item":"settings","appearance":{"styleID":"target"}}
            ]
        })
        .as_object()
        .cloned()
        .unwrap();
        assert!(clear_style_references(&mut customization, "target"));
        assert_eq!(
            customization.get("buttonCustomizations"),
            Some(&serde_json::json!([]))
        );
        assert!(customization["customButtons"][0]["layout"]
            .get("styleID")
            .is_none());
        assert!(customization["elements"]
            .as_array()
            .unwrap()
            .iter()
            .all(|element| element["layout"].get("styleID").is_none()));
        assert!(customization.get("topBarActivationRegion").is_none());
        assert!(customization.get("controlBarItemCustomizations").is_none());
    }

    #[test]
    fn group_duplicate_delta_requires_declared_exact_clones_and_rejects_injection() {
        use crate::draft_operation::ConfigurationVariant;

        let mut before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let group_id = "00000000-0000-0000-0000-000000000704";
        let new_group_id = "00000000-0000-0000-0000-000000000705";
        let new_ids = vec![
            "00000000-0000-0000-0000-000000000706".to_owned(),
            "00000000-0000-0000-0000-000000000707".to_owned(),
        ];
        let mut customization = before.profiles[0]["customization"]
            .as_object()
            .unwrap()
            .clone();
        let children = vec![
            resolve_layer_identity(&customization, "builtin.00000000-0000-0000-0000-000000000105").unwrap(),
            resolve_layer_identity(&customization, "builtin.00000000-0000-0000-0000-000000000106").unwrap(),
        ];
        let group = serde_json::json!({
            "id": canonical_uuid_string(group_id),
            "name": "Actions",
            "children": children,
            "isLocked": false,
            "isHidden": false
        })
        .as_object()
        .unwrap()
        .clone();
        assert!(set_expected_groups(&mut customization, vec![group]));
        before.profiles[0]["customization"] = Value::Object(customization.clone());
        before.profiles[0]["landscapeCustomization"] = Value::Object(customization.clone());

        let mut actual_seed = customization.clone();
        let (canvas_width, canvas_height) = customization_canvas_size(&customization).unwrap();
        let placeholders = children
            .iter()
            .zip(&new_ids)
            .map(|(child, id)| {
                let identity = layer_identity_key(child).unwrap();
                let snapshot =
                    group_nudge_snapshot(&customization, &identity, canvas_width, canvas_height)
                        .unwrap();
                serde_json::json!({
                    "id": id,
                    "layout": {
                        "centerX": (snapshot.center_x / canvas_width + 0.025).clamp(0.0, 1.0),
                        "centerY": (snapshot.center_y / canvas_height + 0.025).clamp(0.0, 1.0)
                    }
                })
            })
            .collect::<Vec<_>>();
        actual_seed.insert("customButtons".to_owned(), Value::Array(placeholders));
        let mut reconstructed = customization;
        let mut groups = saved_layer_groups(&reconstructed).unwrap();
        let source_group = group_by_id(&groups, group_id).unwrap().clone();
        assert!(apply_expected_group_duplicate(
            &mut reconstructed,
            &actual_seed,
            &mut groups,
            GroupDuplicateExpectation {
                source_group: &source_group,
                new_group_id,
                requested_name: Some("Actions Copy"),
                new_element_ids: &new_ids,
                offset_x: 0.025,
                offset_y: 0.025,
            },
        ));

        let operation = ConfigurationOperation::GroupDuplicate {
            profile_id,
            variant: ConfigurationVariant::Primary,
            group_id: group_id.to_owned(),
            new_group_id: new_group_id.to_owned(),
            name: Some("Actions Copy".to_owned()),
            new_element_ids: new_ids,
            offset_x: 0.025,
            offset_y: 0.025,
        };
        let mut after = before.clone();
        let profile = after.profiles[0].as_object_mut().unwrap();
        profile.insert(
            "customization".to_owned(),
            Value::Object(reconstructed.clone()),
        );
        profile.insert(
            "landscapeCustomization".to_owned(),
            Value::Object(reconstructed),
        );
        profile.insert("updatedAt".to_owned(), Value::from(1));
        assert!(valid_operation_delta(&before, &after, &operation));

        after.profiles[0]["customization"]["customButtons"][0]["label"] =
            Value::String("Injected".to_owned());
        after.profiles[0]["landscapeCustomization"] = after.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &after, &operation));
    }

    #[test]
    fn generated_install_delta_requires_exact_bindings_and_declared_ids() {
        use crate::draft_operation::{ControllerTemplate, GeneratedProfileDestination};

        assert!(template_id_matches(
            "softwhite",
            ControllerTemplate::SoftWhite
        ));
        assert!(template_id_matches(
            "gamecube",
            ControllerTemplate::GameCube
        ));
        assert!(!template_id_matches(
            "soft-white",
            ControllerTemplate::SoftWhite
        ));

        let before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = "00000000-0000-0000-0000-000000000901";
        let element_ids = vec![
            "00000000-0000-0000-0000-000000000911".to_owned(),
            "00000000-0000-0000-0000-000000000912".to_owned(),
        ];
        let operation = ConfigurationOperation::TemplateInstall {
            template: ControllerTemplate::Snes,
            template_revision: 2,
            destination: GeneratedProfileDestination::Create {
                new_profile_id: profile_id.to_owned(),
            },
            name: None,
            new_element_ids: element_ids.clone(),
            select: false,
            make_default: false,
        };
        let mut after = before.clone();
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/controller-templates/v1/snes.json");
        let fixture: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        let mut profile_json = serde_json::to_string(&fixture["profile"]).unwrap();
        for (source, destination) in fixture["customElementIDs"].as_array().unwrap().iter().zip(&element_ids) {
            profile_json = profile_json.replace(source.as_str().unwrap(), destination);
        }
        let mut profile: Value = serde_json::from_str(&profile_json).unwrap();
        profile["id"] = serde_json::json!(profile_id);
        profile["customization"]["designMetadata"]["sourceTemplateRevision"] = serde_json::json!(2);
        let outputs = thumble_core::profile_owned_outputs(&profile);
        let mut keys = ButtonBindings::default();
        for (id, output) in outputs.iter_ids() {
            if let Some(keyboard) = &output.keyboard {
                keys.insert(id, keyboard.clone());
            }
        }
        after.profiles.push(profile);
        after
            .profile_key_bindings
            .insert(profile_id.to_owned(), keys);
        after
            .profile_output_bindings
            .insert(profile_id.to_owned(), outputs);
        assert!(valid_operation_delta(&before, &after, &operation));

        let mut wrong_binding = after.clone();
        wrong_binding
            .profile_key_bindings
            .get_mut(profile_id)
            .unwrap()
            .insert(thumble_protocol::KeypadElementID::preset(5), KeyBinding::new(1, 0));
        assert!(!valid_operation_delta(&before, &wrong_binding, &operation));

        let mut undeclared_id = after.clone();
        undeclared_id.profiles[1]["customization"]["customButtons"][1]["id"] =
            serde_json::Value::String("00000000-0000-0000-0000-000000000999".to_owned());
        assert!(!valid_operation_delta(&before, &undeclared_id, &operation));

        let mut unrelated = after;
        unrelated.profiles[0]["name"] = serde_json::Value::String("injected".to_owned());
        assert!(!valid_operation_delta(&before, &unrelated, &operation));
    }

    #[test]
    fn blocked_stdin_write_is_covered_by_bridge_deadline() {
        let directory = tempdir().unwrap();
        let executable = directory.path().join("bridge");
        fs::write(&executable, "#!/bin/sh\nsleep 30\n").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
        let bridge = ConfigurationBridge::at_path(executable).unwrap();
        let mut document = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        document.profiles[0]["padding"] = serde_json::Value::String("x".repeat(1024 * 1024));
        let operation = ConfigurationOperation::ProfileSelect {
            profile_id: document.active_profile_id.clone(),
        };
        let started = Instant::now();
        assert!(matches!(
            bridge.apply(&document, &operation, 1),
            Err(ConfigurationBridgeError::TimedOut)
        ));
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[test]
    fn response_must_be_exactly_one_newline_terminated_line() {
        assert_eq!(single_line(b"{}\n").unwrap(), b"{}");
        assert!(single_line(b"{}").is_err());
        assert!(single_line(b"{}\n{}\n").is_err());
        assert!(single_line(b"\n").is_err());
    }

    #[test]
    fn element_only_operations_match_native_goldens_and_reject_injection() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../tests/fixtures/element-only-operations-v1.json"
        )).unwrap();
        fn mutate_active_customizations(document: &mut ConfigurationDocument, mut mutate: impl FnMut(&mut Value)) {
            let primary = document.profiles[0]["customization"].clone();
            for field in ["customization", "landscapeCustomization", "portraitCustomization"] {
                if document.profiles[0].get(field) == Some(&primary) {
                    mutate(&mut document.profiles[0][field]);
                }
            }
        }
        let mut rejected = Vec::new();
        for case in fixture["cases"].as_array().unwrap() {
            let before: ConfigurationDocument = serde_json::from_value(case["before"].clone()).unwrap();
            let after: ConfigurationDocument = serde_json::from_value(case["after"].clone()).unwrap();
            let operation: ConfigurationOperation = serde_json::from_value(case["operation"].clone()).unwrap();
            if !valid_operation_delta(&before, &after, &operation) {
                rejected.push(case["name"].as_str().unwrap());
                continue;
            }
            if matches!(operation, ConfigurationOperation::ElementAlign { .. } | ConfigurationOperation::ElementDistribute { .. } | ConfigurationOperation::ElementNudge { .. }) {
                let mut injected = after.clone();
                mutate_active_customizations(&mut injected, |customization| {
                    let id = customization["elements"][0]["id"].as_str().unwrap().to_owned();
                    customization["elements"][0]["layout"]["centerX"] = Value::from(0.94);
                    if let Some(mirrors) = customization.get_mut("customButtons").and_then(Value::as_array_mut) {
                        for mirror in mirrors {
                            if mirror["id"].as_str().is_some_and(|value| value.eq_ignore_ascii_case(&id)) {
                                mirror["layout"]["centerX"] = Value::from(0.94);
                            }
                        }
                    }
                    if let Some(mirrors) = customization.get_mut("buttonCustomizations").and_then(Value::as_array_mut) {
                        for pair in mirrors.chunks_exact_mut(2) {
                            if pair[0].as_str().is_some_and(|value| value.eq_ignore_ascii_case(&id)) {
                                pair[1]["centerX"] = Value::from(0.94);
                            }
                        }
                    }
                });
                assert!(!valid_operation_delta(&before, &injected, &operation), "mirror-consistent geometry injection: {}", case["name"]);
            }
            let mut injected = after.clone();
            injected.profiles[0]["name"] = Value::String("Injected".to_owned());
            assert!(!valid_operation_delta(&before, &injected, &operation), "profile injection: {}", case["name"]);
            if case["name"] != "element-only-delete" {
                for field in ["output", "defaultOutput", "futureControl"] {
                    let mut injected = after.clone();
                    mutate_active_customizations(&mut injected, |customization| {
                        customization["elements"][0][field] = serde_json::json!({"injected":true});
                    });
                    assert!(!valid_operation_delta(&before, &injected, &operation), "element field injection ({field}): {}", case["name"]);
                }
                let mut injected = after.clone();
                mutate_active_customizations(&mut injected, |customization| {
                    customization.as_object_mut().unwrap().entry("customButtons")
                        .or_insert_with(|| Value::Array(Vec::new())).as_array_mut().unwrap().push(serde_json::json!({
                        "id":"3C622DCB-64C9-4FF7-9B91-11464E2C274F", "label":"Injected", "controlKind":"button", "layout":{}
                    }));
                });
                assert!(!valid_operation_delta(&before, &injected, &operation), "undeclared mirror injection: {}", case["name"]);
            }
        }
        assert!(rejected.is_empty(), "native element-only operations rejected: {rejected:?}");
    }

    #[test]
    fn duplicate_preserves_source_future_metadata_and_rejects_replacement_or_loss() {
        let fixture: Value = thumble_protocol::decode_unique_json(include_bytes!("../tests/fixtures/element-only-operations-v1.json")).unwrap();
        let case = fixture["cases"].as_array().unwrap().iter().find(|case| case["operation"]["type"] == "element.duplicate").unwrap();
        let operation: ConfigurationOperation = serde_json::from_value(case["operation"].clone()).unwrap();
        let ConfigurationOperation::ElementDuplicate { element_ids, new_element_ids, .. } = &operation else { unreachable!() };
        let mut before: ConfigurationDocument = serde_json::from_value(case["before"].clone()).unwrap();
        let mut after: ConfigurationDocument = serde_json::from_value(case["after"].clone()).unwrap();
        let mut source = before.profiles[0]["customization"]["elements"].as_array().unwrap().iter()
            .find(|element| element["id"].as_str().unwrap().eq_ignore_ascii_case(&element_ids[0])).unwrap().clone();
        source["futureCopy"] = serde_json::json!({"vendor":"x"});
        let known = ["id", "label", "kind", "layout", "visualRole", "output", "defaultOutput", "partOutputs",
            "joystickMapping", "joystickOutputSettings", "triggerSettings", "trackpadSettings"];
        for document in [&mut before, &mut after] {
            let primary = document.profiles[0]["customization"].clone();
            for field in ["customization", "landscapeCustomization", "portraitCustomization"] {
                if document.profiles[0].get(field) != Some(&primary) { continue; }
                for element in document.profiles[0][field]["elements"].as_array_mut().unwrap() {
                    let id = element["id"].as_str().unwrap();
                    if id.eq_ignore_ascii_case(&element_ids[0]) || id.eq_ignore_ascii_case(&new_element_ids[0]) {
                        for (key, value) in source.as_object().unwrap().iter().filter(|(key, _)| !known.contains(&key.as_str())) {
                            element[key] = value.clone();
                        }
                    }
                }
            }
        }
        before.validate().unwrap(); after.validate().unwrap();
        assert!(valid_operation_delta(&before, &after, &operation));
        for replacement in [None, Some(serde_json::json!({"vendor":"injected"}))] {
            let mut bad = after.clone();
            for field in ["customization", "landscapeCustomization", "portraitCustomization"] {
                for element in bad.profiles[0][field]["elements"].as_array_mut().into_iter().flatten() {
                    if element["id"].as_str().is_some_and(|id| id.eq_ignore_ascii_case(&new_element_ids[0])) {
                        if let Some(value) = &replacement { element["futureCopy"] = value.clone(); }
                        else { element.as_object_mut().unwrap().remove("futureCopy"); }
                    }
                }
            }
            assert!(!valid_operation_delta(&before, &bad, &operation));
        }
    }

    #[test]
    fn duplicate_delete_reset_reject_exact_operation_injections() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../tests/fixtures/element-only-operations-v1.json"
        )).unwrap();
        let mut accepted = Vec::new();
        for case in fixture["cases"].as_array().unwrap() {
            let before: ConfigurationDocument = serde_json::from_value(case["before"].clone()).unwrap();
            let after: ConfigurationDocument = serde_json::from_value(case["after"].clone()).unwrap();
            let operation: ConfigurationOperation = serde_json::from_value(case["operation"].clone()).unwrap();
            let target_id = match &operation {
                ConfigurationOperation::ElementDuplicate { new_element_ids, .. } => Some(new_element_ids[0].as_str()),
                ConfigurationOperation::ElementReset { element_id, .. } => Some(element_id.as_str()),
                ConfigurationOperation::ElementDelete { .. } => None,
                _ => continue,
            };
            assert!(valid_operation_delta(&before, &after, &operation), "native case: {}", case["name"]);
            for attack in ["geometry", "label", "customization-metadata", "sibling-geometry", "sibling-metadata"] {
                let mut injected = after.clone();
                let primary = injected.profiles[0]["customization"].clone();
                let selected = primary["elements"].as_array().unwrap().iter().position(|element| {
                    element["id"].as_str().zip(target_id).is_some_and(|(id, target)| id.eq_ignore_ascii_case(target))
                });
                let sibling = primary["elements"].as_array().unwrap().iter().position(|element| {
                    element["id"].as_str().zip(target_id).is_none_or(|(id, target)| !id.eq_ignore_ascii_case(target))
                });
                let index = if attack.starts_with("sibling-") { sibling } else { selected };
                if attack != "customization-metadata" && index.is_none() { continue; }
                for field in ["customization", "landscapeCustomization", "portraitCustomization"] {
                    if injected.profiles[0].get(field) != Some(&primary) { continue; }
                    let customization = &mut injected.profiles[0][field];
                    if attack == "customization-metadata" {
                        customization["futureCustomization"] = serde_json::json!({"injected":true});
                        continue;
                    }
                    let index = index.unwrap();
                    let id = customization["elements"][index]["id"].as_str().unwrap().to_owned();
                    if attack == "sibling-metadata" {
                        customization["elements"][index]["futureControl"] = serde_json::json!({"injected":true});
                        continue;
                    }
                    let (key, value) = if attack == "label" {
                        ("label", Value::String("Injected".to_owned()))
                    } else {
                        ("centerX", Value::from(0.94))
                    };
                    if key == "label" { customization["elements"][index][key] = value.clone(); }
                    else { customization["elements"][index]["layout"][key] = value.clone(); }
                    if let Some(mirrors) = customization.get_mut("customButtons").and_then(Value::as_array_mut) {
                        for mirror in mirrors {
                            if mirror["id"].as_str().is_some_and(|value| value.eq_ignore_ascii_case(&id)) {
                                if key == "label" { mirror[key] = value.clone(); }
                                else { mirror["layout"][key] = value.clone(); }
                            }
                        }
                    }
                    if key != "label" {
                        if let Some(mirrors) = customization.get_mut("buttonCustomizations").and_then(Value::as_array_mut) {
                            for pair in mirrors.chunks_exact_mut(2) {
                                if pair[0].as_str().is_some_and(|value| value.eq_ignore_ascii_case(&id)) { pair[1][key] = value.clone(); }
                            }
                        }
                    }
                }
                if valid_operation_delta(&before, &injected, &operation) {
                    accepted.push(format!("{}:{attack}", case["name"].as_str().unwrap()));
                }
            }
        }
        assert!(accepted.is_empty(), "accepted exact-operation injections: {accepted:?}");
    }

    #[test]
    fn element_set_delta_accepts_compact_builtin_layout_storage() {
        use crate::draft_operation::{ConfigurationVariant, ElementChanges};

        let mut before = ConfigurationDocument::from_state(
            &thumble_core::PersistentState::minimal("server").unwrap(),
        )
        .unwrap();
        let profile_id = before.active_profile_id.clone();
        let jump_layout = serde_json::json!({
            "centerX":0.8,"centerY":0.6,"widthScale":1,"heightScale":1,
            "rotationDegrees":0,"zIndex":0,"shadowStrength":1,
            "isLocationLocked":false,"isHidden":false
        });
        let pause_layout = serde_json::json!({
            "centerX":0.5,"centerY":0.55,"widthScale":1,"heightScale":1,
            "rotationDegrees":0,"zIndex":0,"shadowStrength":1,
            "isLocationLocked":false,"isHidden":false
        });
        let customization = serde_json::json!({
            "buttonCustomizations":[
                "00000000-0000-0000-0000-000000000105",jump_layout,
                "00000000-0000-0000-0000-00000000010A",pause_layout
            ],
            "customButtons":[],
            "elements":[
                {
                    "id":"00000000-0000-0000-0000-000000000105",
                    "label":"A","kind":"button",
                    "layout":jump_layout,"partOutputs":[]
                },
                {
                    "id":"00000000-0000-0000-0000-00000000010A",
                    "label":"Start","kind":"button",
                    "layout":pause_layout,"partOutputs":[]
                }
            ]
        });
        before.profiles[0]["customization"] = customization.clone();
        before.profiles[0]
            .as_object_mut()
            .unwrap()
            .remove("landscapeCustomization");
        before.profiles[0]
            .as_object_mut()
            .unwrap()
            .remove("portraitCustomization");

        let mut changed = customization;
        changed["buttonCustomizations"][3]["centerY"] = Value::from(0.54);
        changed["elements"][1]["layout"]["centerY"] = Value::from(0.54);
        let mut after = before.clone();
        after.profiles[0]["customization"] = changed.clone();
        after.profiles[0]["landscapeCustomization"] = changed;
        after.profiles[0]["updatedAt"] = Value::from(123);
        let operation = ConfigurationOperation::ElementSet {
            profile_id,
            variant: ConfigurationVariant::Primary,
            element_id: "00000000-0000-0000-0000-00000000010A".to_owned(),
            changes: Box::new(ElementChanges {
                center_x: Some(0.5),
                center_y: Some(0.54),
                ..ElementChanges::default()
            }),
        };
        assert!(valid_operation_delta(&before, &after, &operation));

        let mut sibling_injection = after;
        sibling_injection.profiles[0]["customization"]["buttonCustomizations"][1]["centerY"] =
            Value::from(0.2);
        sibling_injection.profiles[0]["landscapeCustomization"] =
            sibling_injection.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(
            &before,
            &sibling_injection,
            &operation
        ));
    }
}

#[cfg(test)]
mod presentation_delta_regression_tests {
    use super::*;
    #[test]
    fn presentation_only_native_golden_preserves_full_custom_profile() {
        let request: Value = serde_json::from_str(include_str!("../tests/fixtures/presentation-only-request-v1.json")).unwrap();
        let response: Value = serde_json::from_str(include_str!("../tests/fixtures/presentation-only-response-v1.json")).unwrap();
        let before: ConfigurationDocument = serde_json::from_value(request["document"].clone()).unwrap();
        let after: ConfigurationDocument = serde_json::from_value(response["document"].clone()).unwrap();
        let operation: ConfigurationOperation = serde_json::from_value(request["operation"].clone()).unwrap();
        assert!(after.validate().is_ok(), "response document fails validation");
        assert!(operation.validate_bridge_input().is_ok());
        if let ConfigurationOperation::ElementSet { profile_id, variant, element_id, changes } = &operation {
            assert!(changes.is_presentation_only());
            assert!(constrained_raw_element_fields_delta(&before, &after, profile_id, *variant, element_id, changes), "raw metadata delta rejected");
        }
        assert!(valid_operation_delta(&before, &after, &operation));
        assert!(response["changedPaths"].as_array().unwrap().iter().all(|path| allowed_changed_path(&operation, path.as_str().unwrap())));
    }

    #[test]
    fn presentation_only_delta_preserves_sparse_orientation_mirrors_and_raw_data() {
        let id = "b6fd297d-7508-4ff4-aff7-97b3831f6ad0";
        let customization = serde_json::json!({"deviceCanvas":{"frameID":"iphone-17-pro-landscape"},
            "elements":[{"id":id,"kind":"button","layout":{},"label":"Legacy","futureControl":{"kept":true}}],
            "futureCanvas":{"kept":true}});
        let before: ConfigurationDocument = serde_json::from_value(serde_json::json!({
            "profiles":[{"id":id,"name":"Presentation","updatedAt":1,"customization":customization,
                "landscapeCustomization":customization,"futureProfile":{"kept":true}}],"activeProfileID":id,"defaultProfileID":id})).unwrap();
        let changes: crate::draft_operation::ElementChanges = serde_json::from_value(serde_json::json!({"presentation":{"legend":"Q"}})).unwrap();
        let mut after = before.clone();
        for key in ["customization", "landscapeCustomization"] {
            after.profiles[0][key]["elements"][0]["presentation"] = serde_json::to_value(changes.presentation.as_ref().unwrap()).unwrap();
        }
        after.profiles[0]["updatedAt"] = Value::from(2);
        assert!(constrained_raw_element_fields_delta(&before, &after, id, crate::draft_operation::ConfigurationVariant::Primary, id, &changes));
        let mut injected = after.clone(); injected.profiles[0]["customization"]["elements"][0]["layout"]["centerX"] = Value::from(0.5);
        assert!(!constrained_raw_element_fields_delta(&before, &injected, id, crate::draft_operation::ConfigurationVariant::Primary, id, &changes));
        injected = after.clone(); injected.profiles[0]["landscapeCustomization"] = before.profiles[0]["landscapeCustomization"].clone();
        assert!(!constrained_raw_element_fields_delta(&before, &injected, id, crate::draft_operation::ConfigurationVariant::Primary, id, &changes));
    }

    #[test]
    fn presentation_edits_require_exact_payload_and_preserve_routing() {
        let before = serde_json::json!({"id":"a","label":"Legacy","layout":{},"output":{"gamepadButtons":["south"]}});
        let changes: crate::draft_operation::ElementChanges = serde_json::from_value(serde_json::json!({"presentation":{
            "actionID":"ability.q","groupIDs":["abilities"],"legend":"Q"}})).unwrap();
        let mut after = before.clone();
        after["presentation"] = serde_json::to_value(changes.presentation.as_ref().unwrap()).unwrap();
        assert!(element_presentation_after_is_exact(Some(&before), Some(&after), &changes));
        assert!(element_presentation_after_is_exact(None, Some(&after), &changes));
        assert!(target_changed_keys_allowed(Some(&before), Some(&after), &changes, false));
        let mut injected = after.clone(); injected["output"]["gamepadButtons"] = serde_json::json!(["east"]);
        assert!(!target_changed_keys_allowed(Some(&before), Some(&injected), &changes, false));
        injected = after.clone(); injected["presentation"]["legend"] = Value::String("E".to_owned());
        assert!(!element_presentation_after_is_exact(Some(&before), Some(&injected), &changes));
        assert!(!target_changed_keys_allowed(Some(&before), Some(&injected), &changes, false));
        let clear = crate::draft_operation::ElementChanges { clear_presentation: true, ..Default::default() };
        assert!(element_presentation_after_is_exact(Some(&after), Some(&before), &clear));
        assert!(!element_presentation_after_is_exact(Some(&after), Some(&after), &clear));
        assert!(!element_presentation_after_is_exact(None, Some(&after), &Default::default()));
    }


    #[test]
    fn binding_sync_accepts_integral_json_number_spelling_but_rejects_layout_changes() {
        let id = "00000000-0000-0000-0000-000000000107";
        let before = serde_json::json!({"elements":[{"id":id,"kind":"button","layout":{"centerX":0.5,"shadowStrength":1.0},
            "defaultOutput":{"gamepadButtons":[]},"output":{"keyboard":{"keyCode":40,"modifiersRawValue":0},"gamepadButtons":[]}}]});
        let mut after = before.clone();
        after["elements"][0]["layout"]["shadowStrength"] = serde_json::json!(1);
        after["elements"][0]["output"]["keyboard"]["keyCode"] = serde_json::json!(49);
        let outputs: ButtonBindings<OutputBinding> = serde_json::from_value(serde_json::json!({id:{"keyboard":{"keyCode":49,"modifiers":0},"gamepadButtons":[]}})).unwrap();
        assert!(customization_output_sync_is_exact(Some(&before), Some(&after), &outputs));
        after["elements"][0]["layout"]["shadowStrength"] = serde_json::json!(0.9);
        assert!(!customization_output_sync_is_exact(Some(&before), Some(&after), &outputs));
        after["elements"][0]["layout"]["shadowStrength"] = serde_json::json!(1);
        after["elements"][0]["defaultOutput"]["gamepadButtons"] = serde_json::json!(["south"]);
        assert!(!customization_output_sync_is_exact(Some(&before), Some(&after), &outputs));
        assert!(json_semantically_equal(&serde_json::json!(1), &serde_json::json!(1.0)));
        assert!(!json_semantically_equal(&serde_json::json!(9_007_199_254_740_993_u64), &serde_json::json!(9_007_199_254_740_992_u64)));
        assert!(!json_semantically_equal(&serde_json::json!(9_007_199_254_740_993_u64), &serde_json::json!(9_007_199_254_740_992.0)));
    }

    #[test]
    fn output_only_native_golden_preserves_full_custom_profile() {
        let request: Value = serde_json::from_str(include_str!("../tests/fixtures/output-only-request-v1.json")).unwrap();
        let response: Value = serde_json::from_str(include_str!("../tests/fixtures/output-only-response-v1.json")).unwrap();
        let before: ConfigurationDocument = serde_json::from_value(request["document"].clone()).unwrap();
        let after: ConfigurationDocument = serde_json::from_value(response["document"].clone()).unwrap();
        let operation: ConfigurationOperation = serde_json::from_value(request["operation"].clone()).unwrap();
        after.validate().unwrap();
        operation.validate_bridge_input().unwrap();
        assert!(valid_operation_delta(&before, &after, &operation));
        assert!(response["changedPaths"].as_array().unwrap().iter().all(|path| allowed_changed_path(&operation, path.as_str().unwrap())));
    }

    #[test]
    fn output_only_delta_changes_exact_owner_and_keeps_all_other_fields() {
        let id = "00000000-0000-0000-0000-000000000107";
        let sibling = "b6fd297d-7508-4ff4-aff7-97b3831f6ad0";
        let customization = serde_json::json!({"elements":[
            {"id":sibling,"kind":"button","layout":{"centerX":0.3},"future":"kept"},
            {"id":id,"kind":"button","layout":{"centerX":0.7},"output":{"keyboard":{"keyCode":40,"modifiersRawValue":0},"gamepadButtons":[]},
                "defaultOutput":{"gamepadButtons":["south"]},"partOutputs":[]}]});
        let before: ConfigurationDocument = serde_json::from_value(serde_json::json!({"profiles":[{"id":id,"name":"Outputs","updatedAt":1,
            "customization":customization,"landscapeCustomization":customization,"portraitCustomization":customization}],"activeProfileID":id,"defaultProfileID":id})).unwrap();
        let operation: ConfigurationOperation = serde_json::from_value(serde_json::json!({"type":"element.set","profileID":id,"variant":"primary","elementID":id,
            "changes":{"output":{"part":"primary","keyboardEdit":{"action":"set","sequence":[{"key":"Space","modifiers":[]}]},"gamepadEdit":{"action":"keep"}}}})).unwrap();
        let mut after = before.clone();
        for key in ["customization","landscapeCustomization"] { after.profiles[0][key]["elements"][1]["output"]["keyboard"]["keyCode"] = Value::from(49); }
        after.profiles[0]["updatedAt"] = Value::from(2);
        assert!(valid_operation_delta(&before, &after, &operation));
        for field in ["layout","defaultOutput"] {
            let mut injected = after.clone(); injected.profiles[0]["customization"]["elements"][1][field] = serde_json::json!({"injected":true});
            assert!(!valid_operation_delta(&before, &injected, &operation));
        }
        let mut injected = after.clone(); injected.profiles[0]["customization"]["elements"].as_array_mut().unwrap().reverse();
        assert!(!valid_operation_delta(&before, &injected, &operation));
        injected = after.clone(); injected.profiles[0]["portraitCustomization"] = after.profiles[0]["customization"].clone();
        assert!(!valid_operation_delta(&before, &injected, &operation));
        injected = after.clone(); injected.profiles[0]["customization"]["elements"][1]["output"]["keyboard"]["keyCode"] = Value::from(0);
        assert!(!valid_operation_delta(&before, &injected, &operation));
        let changes: crate::draft_operation::ElementChanges = serde_json::from_value(serde_json::json!({"presentation":{"legend":"Q"},"isHidden":false})).unwrap();
        assert!(!changes.is_presentation_only());
        let mut part_before = before.clone();
        for key in ["customization", "landscapeCustomization"] { part_before.profiles[0][key]["elements"][1]["kind"] = Value::from("joystick"); }
        let part_operation: ConfigurationOperation = serde_json::from_value(serde_json::json!({"type":"element.set","profileID":id,"variant":"primary","elementID":id,
            "changes":{"output":{"part":"joystick_up","keyboardEdit":{"action":"set","sequence":[{"key":"Space","modifiers":[]}]},"gamepadEdit":{"action":"keep"}}}})).unwrap();
        let mut part_after = part_before.clone();
        for key in ["customization", "landscapeCustomization"] { part_after.profiles[0][key]["elements"][1]["partOutputs"] = serde_json::json!(["joystick_up",{"keyboard":{"keyCode":49,"modifiersRawValue":0},"gamepadButtons":[]}]); }
        part_after.profiles[0]["updatedAt"] = Value::from(2);
        assert!(valid_operation_delta(&part_before, &part_after, &part_operation));
        part_after.profiles[0]["customization"]["elements"][1]["output"]["keyboard"]["keyCode"] = Value::from(0);
        assert!(!valid_operation_delta(&part_before, &part_after, &part_operation));
    }

}
