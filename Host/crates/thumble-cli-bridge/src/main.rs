use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use thumble_host::cli_profile::{
    execute_offline_authority, execute_offline_generation_plan, CliProfileCommand,
    CliProfileRequest, CliProfileResponse, CLI_PROFILE_SCHEMA_VERSION,
    MAXIMUM_CLI_PROFILE_FRAME_BYTES,
};
use thumble_host::control::{send_request, ControlRequest};
use thumble_host::paths::HostPaths;
use thumble_host::runtime::AuthorityLock;
use uuid::Uuid;

fn main() {
    if std::env::args_os().len() != 1 {
        emit(&CliProfileResponse::transport_failure(
            Uuid::new_v4(),
            "none",
            "arguments_not_allowed",
            "thumble-cli-bridge accepts no command-line arguments",
        ));
        std::process::exit(2);
    }

    let mut request = match read_request()
        .and_then(|data| serde_json::from_slice::<CliProfileRequest>(&data).map_err(|_| ()))
    {
        Ok(request) => request,
        Err(()) => {
            emit(&CliProfileResponse::transport_failure(
                Uuid::new_v4(),
                "none",
                "invalid_request",
                "CLI helper requires one bounded newline-terminated typed JSON request",
            ));
            std::process::exit(2);
        }
    };
    let invocation_id = request.invocation_id.unwrap_or_else(Uuid::new_v4);
    request.invocation_id = Some(invocation_id);
    if let Some(response) = unsupported_schema_response(&request, invocation_id) {
        emit(&response);
        std::process::exit(1);
    }

    // The helper accepts no caller-selected state/control paths. Retain only a
    // securely owned, non-symlink HOME so tests and standard account homes can
    // derive the canonical Application Support location; clear everything else.
    let safe_home = sanitized_home();
    for key in std::env::vars_os().map(|(key, _)| key).collect::<Vec<_>>() {
        std::env::remove_var(key);
    }
    if let Some(home) = safe_home {
        std::env::set_var("HOME", home);
    }
    let paths = match HostPaths::discover() {
        Ok(paths) => paths,
        Err(_) => {
            emit(&CliProfileResponse::transport_failure(
                invocation_id,
                "none",
                "path_discovery_failed",
                "canonical Rust authority paths could not be discovered",
            ));
            std::process::exit(1);
        }
    };

    if matches!(request.command, CliProfileCommand::AuthorityStatus) {
        emit(&CliProfileResponse::authority_status(
            invocation_id,
            authority_artifacts_present(&paths),
        ));
        return;
    }

    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(_) => {
            emit(&CliProfileResponse::transport_failure(
                invocation_id,
                "none",
                "runtime_failed",
                "CLI helper runtime could not be initialized",
            ));
            std::process::exit(1);
        }
    };
    let online = runtime.block_on(send_request(
        &paths.control_socket,
        &ControlRequest::CliProfileTransaction {
            request: request.clone(),
        },
    ));
    if let Ok(response) = online {
        if let Some(response) = response.cli_profile {
            emit(&response);
            if !response.ok {
                std::process::exit(1);
            }
            return;
        }
        emit(&CliProfileResponse::transport_failure(
            invocation_id,
            "online",
            "invalid_host_response",
            "live host returned no typed CLI profile response",
        ));
        std::process::exit(1);
    }

    let response = execute_after_online_failure(&paths, &request);
    emit(&response);
    if !response.ok {
        std::process::exit(1);
    }
}

fn execute_after_online_failure(
    paths: &HostPaths,
    request: &CliProfileRequest,
) -> CliProfileResponse {
    if matches!(
        &request.command,
        CliProfileCommand::GenerationPlanSpec { .. }
    ) {
        return execute_offline_generation_plan(paths, request);
    }

    let invocation_id = request.invocation_id.unwrap_or_else(Uuid::new_v4);
    let authority = match AuthorityLock::try_acquire(paths) {
        Ok(Some(authority)) => authority,
        Ok(None) => {
            return CliProfileResponse::transport_failure(
                invocation_id,
                "online",
                "authority_unreachable",
                "Rust authority lock is held but its same-user control socket is unreachable",
            )
        }
        Err(_) => {
            return CliProfileResponse::transport_failure(
                invocation_id,
                "offline",
                "authority_lock_failed",
                "canonical Rust authority lock failed security validation",
            )
        }
    };
    let response = execute_offline_authority(paths, request);
    drop(authority);
    response
}

fn unsupported_schema_response(
    request: &CliProfileRequest,
    invocation_id: Uuid,
) -> Option<CliProfileResponse> {
    (request.schema_version != CLI_PROFILE_SCHEMA_VERSION).then(|| {
        CliProfileResponse::transport_failure(
            invocation_id,
            "none",
            "unsupported_schema_version",
            "CLI profile helper schema version is unsupported",
        )
    })
}

fn sanitized_home() -> Option<std::path::PathBuf> {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from)?;
    if !home.is_absolute() {
        return None;
    }
    let metadata = fs::symlink_metadata(&home).ok()?;
    (!metadata.file_type().is_symlink()
        && metadata.is_dir()
        && metadata.uid() == unsafe { libc::geteuid() }
        && metadata.permissions().mode() & 0o022 == 0)
        .then_some(home)
}

fn authority_artifacts_present(paths: &HostPaths) -> bool {
    if fs::symlink_metadata(&paths.state_file).is_ok() {
        return true;
    }
    if fs::symlink_metadata(&paths.control_socket)
        .is_ok_and(|metadata| metadata.file_type().is_socket() || metadata.file_type().is_symlink())
    {
        return true;
    }
    if paths.lock_file.exists() {
        return match AuthorityLock::try_acquire(paths) {
            Ok(Some(authority)) => {
                drop(authority);
                false
            }
            Ok(None) | Err(_) => true,
        };
    }
    false
}

fn read_request() -> Result<Vec<u8>, ()> {
    let mut input = Vec::new();
    io::stdin()
        .take((MAXIMUM_CLI_PROFILE_FRAME_BYTES + 1) as u64)
        .read_to_end(&mut input)
        .map_err(|_| ())?;
    validate_request_frame(input)
}

fn validate_request_frame(mut input: Vec<u8>) -> Result<Vec<u8>, ()> {
    if input.is_empty()
        || input.len() > MAXIMUM_CLI_PROFILE_FRAME_BYTES
        || input.last() != Some(&b'\n')
    {
        return Err(());
    }
    input.pop();
    if input.is_empty() || input.contains(&b'\n') || input.contains(&b'\r') {
        return Err(());
    }
    Ok(input)
}

fn emit(response: &CliProfileResponse) {
    let _ = io::stdout().write_all(&encode_response_frame(response));
}

fn encode_response_frame(response: &CliProfileResponse) -> Vec<u8> {
    let mut output = serde_json::to_vec(response).unwrap_or_else(|_| {
        encode_fallback_response(
            response,
            "encoding_failed",
            "CLI helper response could not be encoded",
        )
    });
    output.push(b'\n');
    if output.len() > MAXIMUM_CLI_PROFILE_FRAME_BYTES {
        output = encode_fallback_response(
            response,
            "response_too_large",
            "CLI helper response exceeds its bound",
        );
        output.push(b'\n');
    }
    output
}

fn encode_fallback_response(original: &CliProfileResponse, code: &str, message: &str) -> Vec<u8> {
    let fallback = CliProfileResponse::transport_failure(
        original.invocation_id,
        &original.authority_mode,
        code,
        message,
    );
    debug_assert_eq!(fallback.schema_version, CLI_PROFILE_SCHEMA_VERSION);
    serde_json::to_vec(&fallback).expect("typed bounded fallback response must encode")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_frame_accepts_exact_newline_inclusive_bound_and_rejects_invalid_frames() {
        let mut exact = vec![b'x'; MAXIMUM_CLI_PROFILE_FRAME_BYTES - 1];
        exact.push(b'\n');
        assert_eq!(
            validate_request_frame(exact).unwrap().len(),
            MAXIMUM_CLI_PROFILE_FRAME_BYTES - 1
        );
        let mut oversized = vec![b'x'; MAXIMUM_CLI_PROFILE_FRAME_BYTES];
        oversized.push(b'\n');
        assert!(validate_request_frame(oversized).is_err());
        assert!(validate_request_frame(b"{}\n{}\n".to_vec()).is_err());
        assert!(validate_request_frame(b"{}".to_vec()).is_err());
        assert_eq!(validate_request_frame(b"{}\n".to_vec()).unwrap(), b"{}");
    }

    #[test]
    fn response_frame_is_bounded_and_uses_current_fallback_schema() {
        let invocation_id = Uuid::parse_str("12345678-1234-5678-9234-567812345678").unwrap();
        let response = CliProfileResponse::transport_failure(
            invocation_id,
            "offline",
            "test",
            &"x".repeat(MAXIMUM_CLI_PROFILE_FRAME_BYTES),
        );
        let encoded = encode_response_frame(&response);
        assert!(encoded.len() < MAXIMUM_CLI_PROFILE_FRAME_BYTES);
        assert!(encoded.ends_with(b"\n"));
        let decoded: CliProfileResponse = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(decoded.schema_version, CLI_PROFILE_SCHEMA_VERSION);
        assert_eq!(decoded.invocation_id, invocation_id);
        assert_eq!(decoded.authority_mode, "offline");
        assert_eq!(decoded.error.unwrap().code, "response_too_large");
    }

    #[test]
    fn authority_status_rejects_wrong_schema_with_typed_current_schema_failure() {
        let invocation_id = Uuid::parse_str("12345678-1234-5678-9234-567812345678").unwrap();
        let request = CliProfileRequest {
            schema_version: CLI_PROFILE_SCHEMA_VERSION - 1,
            invocation_id: Some(invocation_id),
            expected_configuration_revision: None,
            command: CliProfileCommand::AuthorityStatus,
        };
        let response = unsupported_schema_response(&request, invocation_id).unwrap();
        assert_eq!(response.schema_version, CLI_PROFILE_SCHEMA_VERSION);
        assert_eq!(response.invocation_id, invocation_id);
        assert_eq!(response.authority_mode, "none");
        assert!(!response.ok);
        assert_eq!(response.error.unwrap().code, "unsupported_schema_version");
    }

    #[test]
    fn typed_request_denies_unknown_fields_and_raw_paths() {
        let unknown =
            br#"{"schemaVersion":8,"command":{"type":"profile.list"},"statePath":"/tmp/state"}"#;
        assert!(serde_json::from_slice::<CliProfileRequest>(unknown).is_err());
        let raw_profile =
            br#"{"schemaVersion":8,"command":{"type":"profile.reset","target":null,"profile":{}}}"#;
        assert!(serde_json::from_slice::<CliProfileRequest>(raw_profile).is_err());
        let raw_orientation = br#"{"schemaVersion":8,"command":{"type":"orientation.copy","target":{"kind":"active"},"source":"landscape","destination":"portrait","automaticallyArrange":true,"profile":{"customization":{}},"statePath":"/tmp/state"}}"#;
        assert!(serde_json::from_slice::<CliProfileRequest>(raw_orientation).is_err());
    }

    fn generation_request() -> CliProfileRequest {
        CliProfileRequest {
            schema_version: CLI_PROFILE_SCHEMA_VERSION,
            invocation_id: Some(Uuid::parse_str("12345678-1234-5678-9234-567812345678").unwrap()),
            expected_configuration_revision: None,
            command: CliProfileCommand::GenerationPlanSpec {
                spec_json: r#"{"gameName":"Read Only","controls":[]}"#.to_owned(),
                requested_game_name: None,
            },
        }
    }

    #[test]
    fn offline_generation_planning_in_a_fresh_home_creates_no_authority_artifacts() {
        let home = tempfile::tempdir().unwrap();
        let state_dir = home.path().join("Library/Application Support/ThumbleHost");
        let paths = HostPaths::new(state_dir.clone(), state_dir.join("control.sock"));

        let response = execute_after_online_failure(&paths, &generation_request());

        assert!(response.ok, "{:?}", response.error);
        assert_eq!(response.authority_mode, "offline");
        assert!(!state_dir.exists());
    }

    #[test]
    fn offline_generation_planning_normalizes_outdated_state_only_in_memory() {
        let home = tempfile::tempdir().unwrap();
        let state_dir = home.path().join("Library/Application Support/ThumbleHost");
        let paths = HostPaths::new(state_dir.clone(), state_dir.join("control.sock"));
        let state = thumble_core::PersistentState::minimal("server").unwrap();
        thumble_host::storage::save_atomic(&paths.state_file, &state).unwrap();
        let mut outdated = serde_json::to_value(state).unwrap();
        outdated["schemaVersion"] = serde_json::json!(1);
        let outdated = serde_json::to_vec_pretty(&outdated).unwrap();
        fs::write(&paths.state_file, &outdated).unwrap();
        fs::set_permissions(&paths.state_file, fs::Permissions::from_mode(0o600)).unwrap();

        let response = execute_after_online_failure(&paths, &generation_request());

        assert!(response.ok, "{:?}", response.error);
        assert_eq!(fs::read(&paths.state_file).unwrap(), outdated);
        assert!(!paths.lock_file.exists());
        assert!(!paths.drafts_dir.exists());
        assert_eq!(fs::read_dir(&state_dir).unwrap().count(), 1);
    }
}
