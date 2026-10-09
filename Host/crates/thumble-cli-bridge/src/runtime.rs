//! Restricted runtime IPC only: no profile transactions, offline mutation, or HID ownership.
use serde_json::Value;
use std::fs;
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::MetadataExt;
#[cfg(test)]
use std::os::unix::fs::PermissionsExt;
use thumble_host::control::{send_request, ControlRequest};
use thumble_host::paths::HostPaths;
use uuid::Uuid;

pub const MAXIMUM_FRAME_BYTES: usize = 64 * 1024;

#[derive(Debug)]
struct Request {
    schema_version: u64,
    invocation_id: Uuid,
    command: Command,
}

#[derive(Debug)]
enum Command {
    Status,
    ReleaseAll,
    GamepadStatus,
    GamepadRetry,
    TapControl { control_id: String },
    TestControl { control_id: String, pressed: bool },
}

struct Response {
    schema_version: u32,
    ok: bool,
    invocation_id: Uuid,
    owner: String,
    response: Option<Value>,
    error: Option<Failure>,
}

struct Failure {
    code: String,
    message: String,
}

impl Response {
    fn failure(id: Uuid, owner: &str, code: &str, message: &str) -> Self {
        Self {
            schema_version: 1,
            ok: false,
            invocation_id: id,
            owner: owner.into(),
            response: None,
            error: Some(Failure {
                code: code.into(),
                message: message.into(),
            }),
        }
    }
}

fn decode_request(data: &[u8]) -> Result<Request, ()> {
    if data.len() + 1 > MAXIMUM_FRAME_BYTES {
        return Err(());
    }
    let value: Value = thumble_protocol::decode_unique_json(data).map_err(|_| ())?;
    let envelope = value.as_object().ok_or(())?;
    if envelope.len() != 3
        || !envelope
            .keys()
            .all(|key| ["schemaVersion", "invocationID", "runtimeCommand"].contains(&key.as_str()))
    {
        return Err(());
    }
    let schema_version = envelope
        .get("schemaVersion")
        .and_then(Value::as_u64)
        .ok_or(())?;
    let id_text = envelope
        .get("invocationID")
        .and_then(Value::as_str)
        .ok_or(())?;
    if id_text.len() != 36 {
        return Err(());
    }
    let invocation_id = Uuid::parse_str(id_text).map_err(|_| ())?;
    let tagged = envelope
        .get("runtimeCommand")
        .and_then(Value::as_object)
        .ok_or(())?;
    let action = tagged.get("type").and_then(Value::as_str).ok_or(())?;
    let command = if matches!(action, "tap-control" | "test-control") {
        let expected_fields = if action == "test-control" { 3 } else { 2 };
        if tagged.len() != expected_fields || !tagged.contains_key("controlID") {
            return Err(());
        }
        let control_id = tagged.get("controlID").and_then(Value::as_str).ok_or(())?;
        if control_id.is_empty()
            || control_id.len() > 256
            || !control_id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b':' | b'.' | b'#'))
            || control_id.contains("..")
        {
            return Err(());
        }
        if action == "test-control" {
            let pressed = match tagged.get("state").and_then(Value::as_str) {
                Some("down") => true,
                Some("up") => false,
                _ => return Err(()),
            };
            Command::TestControl {
                control_id: control_id.into(),
                pressed,
            }
        } else {
            Command::TapControl {
                control_id: control_id.into(),
            }
        }
    } else {
        if tagged.len() != 1 {
            return Err(());
        }
        match action {
            "status" => Command::Status,
            "release-all" => Command::ReleaseAll,
            "gamepad-status" => Command::GamepadStatus,
            "gamepad-retry" => Command::GamepadRetry,
            _ => return Err(()),
        }
    };
    Ok(Request {
        schema_version,
        invocation_id,
        command,
    })
}

/// Called before profile decoding, so runtime envelopes can never become offline profile work.
pub fn run(data: &[u8]) -> bool {
    let id = thumble_protocol::decode_unique_json::<Value>(data)
        .ok()
        .and_then(|v| {
            v.get("invocationID")?
                .as_str()
                .and_then(|s| Uuid::parse_str(s).ok())
        })
        .unwrap_or_else(Uuid::new_v4);
    let request = match decode_request(data) {
        Ok(request) => request,
        Err(()) => {
            return emit(&Response::failure(
                id,
                "unreachable",
                "invalid_request",
                "Runtime helper requires one strict request within 64 KiB",
            ))
        }
    };
    if request.schema_version != 1 {
        return emit(&Response::failure(
            id,
            "unreachable",
            "unsupported_schema_version",
            "Runtime helper schema version is unsupported",
        ));
    }
    super::sanitize_environment();
    // HOME is the only retained account hint. Resolve its trusted, owned root
    // before deriving paths (macOS temporary homes often start with /var).
    if let Some(home) = std::env::var_os("HOME") {
        match fs::canonicalize(home) {
            Ok(home) => std::env::set_var("HOME", home),
            Err(_) => {
                return emit(&Response::failure(
                    id,
                    "unreachable",
                    "unsafe_runtime_path",
                    "Validated home could not be canonicalized",
                ))
            }
        }
    }
    let paths = match HostPaths::discover() {
        Ok(paths) => paths,
        Err(_) => {
            return emit(&Response::failure(
                id,
                "unreachable",
                "path_discovery_failed",
                "Canonical runtime paths could not be discovered",
            ))
        }
    };
    if !safe_parent_ancestry(&paths.state_dir) {
        return emit(&Response::failure(
            id,
            "unreachable",
            "unsafe_runtime_path",
            "Canonical runtime path ancestry failed security validation",
        ));
    }
    let control = match request.command {
        Command::Status => ControlRequest::Status,
        Command::ReleaseAll => ControlRequest::ReleaseAll,
        Command::GamepadStatus => ControlRequest::GamepadStatus,
        Command::GamepadRetry => ControlRequest::GamepadRetry,
        Command::TapControl { control_id } => ControlRequest::PressControl { control_id },
        Command::TestControl {
            control_id,
            pressed,
        } => ControlRequest::TestControl {
            control_id,
            pressed,
        },
    };
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(runtime) => runtime,
        Err(_) => {
            return emit(&Response::failure(
                id,
                "unreachable",
                "runtime_failed",
                "IPC executor could not be initialized",
            ))
        }
    };
    match runtime.block_on(send_request(&paths.control_socket, &control)) {
        Ok(host) => {
            let ok = host.ok;
            let error = (!ok).then(|| Failure {
                code: host.error_code.clone().unwrap_or_else(|| "host_rejected".into()),
                message: host.error.clone().unwrap_or_else(|| "Runtime rejected the command".into()),
            });
            let response = match serde_json::to_value(host) {
                Ok(response) => response,
                Err(_) => return emit(&Response::failure(id, "rust", "encoding_failed", "Runtime response could not be encoded")),
            };
            emit(&Response { schema_version: 1, ok, invocation_id: request.invocation_id,
                owner: "rust".into(), response: Some(response), error })
        }
        Err(_) => match ownership_after_failure(&paths) {
            Ownership::None => emit(&Response { schema_version: 1, ok: true, invocation_id: id,
                owner: "none".into(), response: None, error: None }),
            Ownership::LegacyCandidate => emit(&Response::failure(id, "unreachable", "legacy_owner_possible", "Authority lock is held without Rust runtime artifacts; correlated legacy verification is required")),
            Ownership::Unreachable => emit(&Response::failure(id, "unreachable", "authority_unreachable", "Runtime ownership is ambiguous or its same-user socket is unreachable")),
        },
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Ownership {
    None,
    LegacyCandidate,
    Unreachable,
}

/// Validate existing ancestors even if the runtime directory itself is absent.
/// Caller paths/overrides were already removed from the helper environment.
fn safe_parent_ancestry(path: &std::path::Path) -> bool {
    path.is_absolute()
        && path.parent().is_some_and(|parent| {
            parent
                .ancestors()
                .all(|ancestor| match fs::symlink_metadata(ancestor) {
                    Err(error) if error.kind() == io::ErrorKind::NotFound => true,
                    Ok(meta) => {
                        meta.is_dir()
                            && !meta.file_type().is_symlink()
                            && (meta.uid() == 0 || meta.uid() == unsafe { libc::geteuid() })
                            && meta.mode() & 0o022 == 0
                    }
                    Err(_) => false,
                })
        })
}

fn artifact_present(path: &std::path::Path) -> bool {
    !matches!(fs::symlink_metadata(path), Err(error) if error.kind() == io::ErrorKind::NotFound)
}

/// Read-only lock probe: never creates/chmods a directory, state, or lock file.
fn ownership_after_failure(paths: &HostPaths) -> Ownership {
    if [&paths.pid_file, &paths.runtime_file, &paths.control_socket]
        .into_iter()
        .any(|p| artifact_present(p))
    {
        return Ownership::Unreachable;
    }
    match fs::symlink_metadata(&paths.state_dir) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ownership::None,
        Ok(meta)
            if meta.is_dir()
                && !meta.file_type().is_symlink()
                && meta.uid() == unsafe { libc::geteuid() }
                && meta.mode() & 0o077 == 0 => {}
        _ => return Ownership::Unreachable,
    }
    let meta = match fs::symlink_metadata(&paths.lock_file) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ownership::None,
        Ok(meta)
            if meta.is_file()
                && !meta.file_type().is_symlink()
                && meta.uid() == unsafe { libc::geteuid() }
                && meta.mode() & 0o077 == 0 =>
        {
            meta
        }
        _ => return Ownership::Unreachable,
    };
    use std::os::unix::ffi::OsStrExt;
    let path = match std::ffi::CString::new(paths.lock_file.as_os_str().as_bytes()) {
        Ok(path) => path,
        Err(_) => return Ownership::Unreachable,
    };
    // SAFETY: NUL-terminated canonical path, no creation or following the final symlink.
    let fd = unsafe {
        libc::open(
            path.as_ptr(),
            libc::O_RDONLY | libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_NONBLOCK,
        )
    };
    if fd < 0 {
        return Ownership::Unreachable;
    }
    // SAFETY: fd is newly opened and ownership transfers exactly once to File.
    let file = unsafe { fs::File::from_raw_fd(fd) };
    if !file
        .metadata()
        .is_ok_and(|opened| opened.ino() == meta.ino() && opened.dev() == meta.dev())
    {
        return Ownership::Unreachable;
    }
    // SAFETY: valid live file descriptor; File closes it and releases any acquired lock.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return if io::Error::last_os_error().raw_os_error() == Some(libc::EWOULDBLOCK) {
            Ownership::LegacyCandidate
        } else {
            Ownership::Unreachable
        };
    }
    if [&paths.pid_file, &paths.runtime_file, &paths.control_socket]
        .into_iter()
        .any(|p| artifact_present(p))
    {
        return Ownership::Unreachable;
    }
    Ownership::None
}

fn encode_response(response: &Response) -> Vec<u8> {
    let mut data = serde_json::to_vec(&response_value(response)).expect("runtime envelope encodes");
    if data.len() + 1 > MAXIMUM_FRAME_BYTES {
        data = serde_json::to_vec(&response_value(&Response::failure(
            response.invocation_id,
            &response.owner,
            "response_too_large",
            "Runtime response exceeds 64 KiB",
        )))
        .expect("bounded fallback encodes");
    }
    data.push(b'\n');
    data
}

fn response_value(response: &Response) -> Value {
    let mut value = serde_json::json!({
        "schemaVersion": response.schema_version, "ok": response.ok,
        "invocationID": response.invocation_id.to_string(), "owner": response.owner,
    });
    if let Some(control) = &response.response {
        value["response"] = control.clone();
    }
    if let Some(error) = &response.error {
        value["error"] = serde_json::json!({"code": error.code, "message": error.message});
    }
    value
}

fn emit(response: &Response) -> bool {
    let _ = io::stdout().write_all(&encode_response(response));
    response.ok
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(command: serde_json::Value) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "schemaVersion": 1,
            "invocationID": "aaaaaaaa-bbbb-5ccc-8ddd-eeeeeeeeeeee",
            "runtimeCommand": command
        }))
        .unwrap()
    }

    #[test]
    fn runtime_envelope_is_tagged_strict_and_bounded() {
        for action in ["status", "release-all", "gamepad-status", "gamepad-retry"] {
            assert!(decode_request(&request(serde_json::json!({"type": action}))).is_ok());
        }
        assert!(decode_request(&request(
            serde_json::json!({"type":"tap-control","controlID":"jump"})
        ))
        .is_ok());
        for state in ["down", "up"] {
            assert!(decode_request(&request(
                serde_json::json!({"type":"test-control", "controlID":"button:jump", "state":state})
            ))
            .is_ok());
        }
        for command in [
            serde_json::json!({"type":"tap-control","controlID":""}),
            serde_json::json!({"type":"tap-control","controlID":"../raw"}),
            serde_json::json!({"type":"tap-control","controlID":"x".repeat(257)}),
            serde_json::json!({"type":"status","socketPath":"/tmp/evil"}),
            serde_json::json!({"type":"test-control","controlID":"jump","state":"stuck"}),
            serde_json::json!({"type":"test-control","controlID":"jump","state":"down","duration":999999}),
        ] {
            assert!(decode_request(&request(command)).is_err());
        }
        assert!(decode_request(&vec![b' '; MAXIMUM_FRAME_BYTES]).is_err());
        let mut exact = request(serde_json::json!({"type":"status"}));
        exact.resize(MAXIMUM_FRAME_BYTES - 1, b' ');
        assert!(decode_request(&exact).is_ok());
        exact.push(b' ');
        assert!(decode_request(&exact).is_err());
        let duplicate = br#"{"schemaVersion":1,"invocationID":"aaaaaaaa-bbbb-5ccc-8ddd-eeeeeeeeeeee","runtimeCommand":{"type":"status","type":"release-all"}}"#;
        assert!(decode_request(duplicate).is_err());
        let escaped_duplicate = br#"{"schemaVersion":1,"invocationID":"aaaaaaaa-bbbb-5ccc-8ddd-eeeeeeeeeeee","runtimeCommand":{"type":"status","\u0074ype":"release-all"}}"#;
        assert!(decode_request(escaped_duplicate).is_err());
        let mut caller_path: Value =
            serde_json::from_slice(&request(serde_json::json!({"type":"status"}))).unwrap();
        caller_path["socketPath"] = Value::String("/tmp/evil".into());
        assert!(decode_request(&serde_json::to_vec(&caller_path).unwrap()).is_err());
    }

    #[test]
    fn failure_frame_preserves_schema_correlation_and_owner_within_bound() {
        let id = Uuid::new_v4();
        let response = Response::failure(id, "rust", "test", &"x".repeat(MAXIMUM_FRAME_BYTES));
        let frame = encode_response(&response);
        assert!(frame.len() <= MAXIMUM_FRAME_BYTES);
        assert_eq!(frame.last(), Some(&b'\n'));
        let decoded: serde_json::Value = serde_json::from_slice(&frame).unwrap();
        assert_eq!(decoded["invocationID"], id.to_string());
        assert_eq!(decoded["schemaVersion"], 1);
        assert_eq!(decoded["owner"], "rust");
        assert_eq!(decoded["error"]["code"], "response_too_large");
    }

    #[test]
    fn persistent_profile_state_is_not_a_runtime_owner_and_probe_creates_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let paths = HostPaths::new(
            dir.path().join("host"),
            dir.path().join("host/control.sock"),
        );
        assert_eq!(ownership_after_failure(&paths), Ownership::None);
        assert!(!paths.state_dir.exists());
        fs::create_dir(&paths.state_dir).unwrap();
        fs::set_permissions(&paths.state_dir, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(&paths.state_file, b"{}").unwrap();
        assert_eq!(ownership_after_failure(&paths), Ownership::None);
        assert_eq!(fs::read_dir(&paths.state_dir).unwrap().count(), 1);
    }

    #[test]
    fn any_runtime_artifact_fails_closed_even_if_stale_or_not_a_socket() {
        let dir = tempfile::tempdir().unwrap();
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let paths = HostPaths::new(dir.path().into(), dir.path().join("control.sock"));
        for artifact in [&paths.pid_file, &paths.runtime_file, &paths.control_socket] {
            fs::write(artifact, b"stale").unwrap();
            assert_eq!(ownership_after_failure(&paths), Ownership::Unreachable);
            fs::remove_file(artifact).unwrap();
        }
        std::os::unix::fs::symlink("missing", &paths.control_socket).unwrap();
        assert_eq!(ownership_after_failure(&paths), Ownership::Unreachable);
    }

    #[test]
    fn held_authority_without_rust_artifacts_is_only_a_legacy_candidate() {
        let dir = tempfile::tempdir().unwrap();
        let paths = HostPaths::new(dir.path().into(), dir.path().join("control.sock"));
        let lock = thumble_host::runtime::AuthorityLock::try_acquire(&paths)
            .unwrap()
            .unwrap();
        assert_eq!(ownership_after_failure(&paths), Ownership::LegacyCandidate);
        drop(lock);
        assert_eq!(ownership_after_failure(&paths), Ownership::None);
    }

    #[test]
    fn insecure_state_directory_and_symlink_lock_fail_closed() {
        let dir = tempfile::tempdir().unwrap();
        let paths = HostPaths::new(dir.path().into(), dir.path().join("control.sock"));
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o777)).unwrap();
        assert_eq!(ownership_after_failure(&paths), Ownership::Unreachable);
        fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
        std::os::unix::fs::symlink("missing", &paths.lock_file).unwrap();
        assert_eq!(ownership_after_failure(&paths), Ownership::Unreachable);
    }
}
