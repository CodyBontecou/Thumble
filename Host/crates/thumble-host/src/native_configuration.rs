//! A native editor remains the authority while it holds runtime.lock. The CLI
//! evaluates its existing transactions against a credential-free snapshot, then
//! compare-and-swaps the result back to that editor. It never creates Rust state
//! or writes CFPreferences in this mode.
use crate::authority::{
    prepare_configuration_commit, ConfigurationCommitInput, PreparedConfigurationCommit,
};
use crate::cli_profile::{
    commit_failure, execute_profile_transaction, CliProfileRequest, CliProfileResponse,
};
use crate::drafts::DraftStore;
use crate::paths::HostPaths;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::io::{AsRawFd, FromRawFd};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use thumble_core::{ConfigurationDocument, PersistentState};
use uuid::Uuid;

pub const SOCKET_NAME: &str = "native-configuration.sock";
const MAX_FRAME: usize = 18 * 1024 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct NativeRequest<'a> {
    schema_version: u32,
    #[serde(rename = "requestID")]
    request_id: Uuid,
    action: &'a str,
    #[serde(rename = "instanceID", skip_serializing_if = "Option::is_none")]
    instance_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    expected_revision: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    expected_content_hash: Option<&'a str>,
    #[serde(rename = "invocationID")]
    invocation_id: Uuid,
    request_digest: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    document: Option<&'a ConfigurationDocument>,
    #[serde(rename = "replayResponse", skip_serializing_if = "Option::is_none")]
    replay_response: Option<&'a CliProfileResponse>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NativeResponse {
    schema_version: u32,
    #[serde(rename = "requestID")]
    request_id: Uuid,
    #[serde(rename = "instanceID")]
    instance_id: Uuid,
    configuration_revision: u64,
    content_hash: String,
    document: Option<ConfigurationDocument>,
    replay_response: Option<CliProfileResponse>,
    error: Option<NativeError>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NativeError {
    code: String,
    message: String,
}

/// Missing is distinct from an insecure, stale, or unreachable endpoint. The
/// latter must fail closed rather than silently elect a different authority.
fn socket_directory(paths: &HostPaths) -> Option<PathBuf> {
    let canonical = fs::canonicalize(&paths.state_dir).ok()?;
    use std::os::unix::ffi::OsStrExt;
    let digest = format!("{:x}", Sha256::digest(canonical.as_os_str().as_bytes()));
    Some(PathBuf::from(format!(
        "/tmp/tnc-{}-{}",
        unsafe { libc::geteuid() },
        &digest[..32]
    )))
}

pub fn endpoint_present(paths: &HostPaths) -> bool {
    if fs::symlink_metadata(&paths.control_socket).is_ok() {
        return false;
    }
    if !socket_directory(paths)
        .is_some_and(|directory| fs::symlink_metadata(directory.join(SOCKET_NAME)).is_ok())
    {
        return false;
    }
    match crate::runtime::AuthorityLock::try_acquire(paths) {
        Ok(Some(lease)) => {
            drop(lease);
            false
        } // Only a stale native endpoint remains.
        Ok(None) | Err(_) => true, // A live owner or security failure must not fall back.
    }
}

pub fn execute(paths: &HostPaths, request: &CliProfileRequest) -> CliProfileResponse {
    let invocation_id = request.invocation_id.unwrap_or_else(Uuid::new_v4);
    let mut normalized_request = request.clone();
    normalized_request.invocation_id = Some(invocation_id);
    let fail = |code: &str, message: &str| {
        CliProfileResponse::transport_failure(invocation_id, "native", code, message)
    };
    let digest =
        match serde_json::to_vec(&(&request.command, request.expected_configuration_revision)) {
            Ok(bytes) => format!("{:x}", Sha256::digest(bytes)),
            Err(_) => {
                return fail(
                    "invalid_request",
                    "Native configuration request could not be encoded",
                )
            }
        };
    let snapshot_request = NativeRequest {
        schema_version: 1,
        request_id: Uuid::new_v4(),
        action: "snapshot",
        instance_id: None,
        expected_revision: None,
        expected_content_hash: None,
        invocation_id,
        request_digest: &digest,
        document: None,
        replay_response: None,
    };
    let snapshot = match exchange(paths, &snapshot_request) {
        Ok(response) => response,
        Err(_) => return fail(
            "native_authority_unreachable",
            "Native editor configuration endpoint is unavailable or failed same-user validation",
        ),
    };
    if let Some(error) = snapshot.error {
        return fail(&error.code, &error.message);
    }
    if let Some(mut replay) = snapshot.replay_response {
        if let Some(outcome) = replay.outcome.as_mut() { outcome.idempotent_replay = true; }
        return replay;
    }
    if matches!(
        request.command,
        crate::cli_profile::CliProfileCommand::AuthorityStatus
    ) {
        let mut response = CliProfileResponse::authority_status(invocation_id, false);
        response.authority_mode = "native".to_owned();
        return response;
    }
    let Some(document) = snapshot.document else {
        return fail(
            "invalid_native_response",
            "Native editor returned no validated configuration snapshot",
        );
    };
    let (mut response, candidate) = evaluate_with_drafts(
        &document, snapshot.configuration_revision, &normalized_request, Some(paths));
    if !response.ok {
        return response;
    }
    let Some(candidate) = candidate else {
        return response;
    };
    let commit_request = NativeRequest {
        schema_version: 1,
        request_id: Uuid::new_v4(),
        action: "commit",
        instance_id: Some(snapshot.instance_id),
        expected_revision: Some(snapshot.configuration_revision),
        expected_content_hash: Some(&snapshot.content_hash),
        invocation_id,
        request_digest: &digest,
        document: Some(&candidate),
        replay_response: Some(&response),
    };
    let committed = match exchange(paths, &commit_request) {
        Ok(response) => response,
        Err(_) => return fail("native_commit_unconfirmed", "Native configuration commit was not confirmed; retry with the same invocation ID while this editor instance remains active"),
    };
    if let Some(error) = committed.error {
        return fail(&error.code, &error.message);
    }
    if let Some(replay) = committed.replay_response {
        response = replay;
    }
    if response.ok {
        if let crate::cli_profile::CliProfileCommand::DesignApply { draft_id: Some(id), expected_draft_revision: Some(revision), .. } = &request.command {
            if let Some(committed_revision) = revision.checked_add(1) {
                let _ = DraftStore::new(paths).discard(&id.to_string(), committed_revision, crate::cli_profile::now_millis());
            }
        }
    }
    response
}

/// All existing read/projection/planning/delta checks are reused. Staging files
/// live only in an owned temporary directory, never in the authority's state dir.
pub fn evaluate(
    document: &ConfigurationDocument,
    revision: u64,
    request: &CliProfileRequest,
) -> (CliProfileResponse, Option<ConfigurationDocument>) {
    evaluate_with_drafts(document, revision, request, None)
}

fn evaluate_with_drafts(document: &ConfigurationDocument, revision: u64, request: &CliProfileRequest,
                        durable_paths: Option<&HostPaths>) -> (CliProfileResponse, Option<ConfigurationDocument>) {
    let invocation_id = request.invocation_id.unwrap_or_else(Uuid::new_v4);
    let fail = |code: &str, message: &str| {
        (
            CliProfileResponse::transport_failure(invocation_id, "native", code, message),
            None,
        )
    };
    if document.validate().is_err() || revision == 0 {
        return fail(
            "invalid_native_configuration",
            "Native configuration snapshot is invalid or obsolete",
        );
    }
    let mut state = PersistentState::minimal("native-cli-evaluation")
        .expect("fixed nonempty evaluation identity");
    if document.install_into(&mut state).is_err() {
        return fail(
            "invalid_native_configuration",
            "Native configuration snapshot could not be validated",
        );
    }
    state.configuration_revision = revision;
    let staging = match StagingDirectory::new() {
        Ok(directory) => directory,
        Err(_) => {
            return fail(
                "native_evaluation_failed",
                "Could not prepare private native transaction staging",
            )
        }
    };
    let ephemeral_paths = HostPaths::new(staging.0.clone(), staging.0.join("unused.sock"));
    use crate::cli_profile::CliProfileCommand;
    let durable = matches!(&request.command,
        CliProfileCommand::DesignSnapshot { create_draft: true, .. }
        | CliProfileCommand::DesignSnapshot { draft_id: Some(_), .. }
        | CliProfileCommand::DesignApply { draft_id: Some(_), .. });
    let paths = if durable {
        let Some(paths) = durable_paths else { return fail("private_draft_authority_required", "Private design drafts require the canonical native authority directory"); };
        paths
    } else { &ephemeral_paths };
    let captured_id = match &request.command {
        CliProfileCommand::DesignSnapshot { draft_id: Some(id), .. } | CliProfileCommand::DesignApply { draft_id: Some(id), .. } => Some(id),
        _ => None,
    };
    if let Some(id) = captured_id {
        let draft = match DraftStore::new(paths).get(&id.to_string(), crate::cli_profile::now_millis()) {
            Ok(draft) => draft,
            Err(_) => return fail("design_draft_unavailable", "Private design draft is unavailable"),
        };
        if draft.base_configuration_revision != revision || &draft.base_document != document {
            return fail("native_draft_base_conflict", "Native configuration differs from the private draft base; rebase explicitly before capturing or applying it");
        }
    }

    let mut candidate_document = None;
    let mut response = execute_profile_transaction(
        &paths,
        &state,
        request,
        "native",
        |draft_id, draft_revision, base_revision, commit_id, request_digest| {
            let store = DraftStore::new(&paths);
            let PreparedConfigurationCommit { candidate, summary } = prepare_configuration_commit(
                &state,
                &store,
                ConfigurationCommitInput {
                    draft_id,
                    expected_draft_revision: draft_revision,
                    expected_configuration_revision: base_revision,
                    commit_id,
                    client_request_digest: Some(request_digest),
                    now_millis: crate::cli_profile::now_millis(),
                },
            )
            .map_err(commit_failure)?;
            candidate_document = candidate
                .as_ref()
                .map(ConfigurationDocument::from_state)
                .transpose()
                .map_err(|_| {
                    crate::cli_profile::TransactionFailure::new(
                        "invalid_native_configuration",
                        "Native candidate could not be validated",
                    )
                })?;
            Ok(summary)
        },
    );
    // Temporary drafts are not resumable durable Rust-authority drafts.
    if !durable {
        if let Some(error) = response.error.as_mut() { error.draft_id = None; error.draft_revision = None; }
    }
    if !response.ok {
        candidate_document = None;
    }
    (response, candidate_document)
}

fn exchange(paths: &HostPaths, request: &NativeRequest<'_>) -> Result<NativeResponse, ()> {
    let socket_directory = socket_directory(paths).ok_or(())?;
    let socket = socket_directory.join(SOCKET_NAME);
    let source_directory = fs::symlink_metadata(&paths.state_dir).map_err(|_| ())?;
    if !source_directory.is_dir()
        || source_directory.file_type().is_symlink()
        || source_directory.uid() != unsafe { libc::geteuid() }
        || source_directory.permissions().mode() & 0o077 != 0
    {
        return Err(());
    }
    let directory = fs::symlink_metadata(&socket_directory).map_err(|_| ())?;
    let metadata = fs::symlink_metadata(&socket).map_err(|_| ())?;
    use std::os::unix::fs::FileTypeExt;
    if !directory.is_dir()
        || directory.file_type().is_symlink()
        || directory.uid() != unsafe { libc::geteuid() }
        || directory.permissions().mode() & 0o077 != 0
        || !metadata.file_type().is_socket()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(());
    }
    let mut stream = connect_stream(&socket, Duration::from_secs(10))?;
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .map_err(|_| ())?;
    stream
        .set_write_timeout(Some(Duration::from_secs(10)))
        .map_err(|_| ())?;
    #[cfg(target_os = "macos")]
    {
        let mut uid = 0;
        let mut gid = 0;
        if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0
            || uid != unsafe { libc::geteuid() }
        {
            return Err(());
        }
    }
    let mut frame = serde_json::to_vec(request).map_err(|_| ())?;
    if frame.len() + 1 > MAX_FRAME {
        return Err(());
    }
    frame.push(b'\n');
    stream.set_nonblocking(true).map_err(|_| ())?;
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut remaining = frame.as_slice();
    while !remaining.is_empty() {
        wait_ready(stream.as_raw_fd(), libc::POLLOUT, deadline)?;
        match stream.write(remaining) {
            Ok(0) => return Err(()),
            Ok(count) => remaining = &remaining[count..],
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                ) =>
            {
                continue
            }
            Err(_) => return Err(()),
        }
    }
    stream.shutdown(std::net::Shutdown::Write).map_err(|_| ())?;
    let mut output = read_frame(&mut stream, Duration::from_secs(10))?;
    if output.is_empty()
        || output.len() > MAX_FRAME
        || output.pop() != Some(b'\n')
        || output.contains(&b'\n')
        || output.contains(&b'\r')
    {
        return Err(());
    }
    let response: NativeResponse = thumble_protocol::decode_unique_json(&output).map_err(|_| ())?;
    if response.schema_version != 1
        || response.request_id != request.request_id
        || response.configuration_revision == 0
        || response.content_hash.len() != 64
        || !response
            .content_hash
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err(());
    }
    if let Some(document) = &response.document {
        document.validate().map_err(|_| ())?;
    }
    if let Some(replay) = &response.replay_response {
        if replay.invocation_id != request.invocation_id
            || replay.authority_mode != "native"
            || replay.schema_version != crate::cli_profile::CLI_PROFILE_SCHEMA_VERSION
            || !replay.ok
            || replay.error.is_some()
        {
            return Err(());
        }
    }
    Ok(response)
}

fn connect_stream(path: &std::path::Path, timeout: Duration) -> Result<UnixStream, ()> {
    use std::os::unix::ffi::OsStrExt;
    let deadline = Instant::now() + timeout;
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    #[cfg(target_os = "macos")]
    {
        address.sun_len = std::mem::size_of::<libc::sockaddr_un>() as u8;
    }
    let bytes = path.as_os_str().as_bytes();
    if bytes.len() >= address.sun_path.len() {
        return Err(());
    }
    for (destination, source) in address.sun_path.iter_mut().zip(bytes) {
        *destination = *source as libc::c_char;
    }
    let fd = unsafe { libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0) };
    if fd < 0 {
        return Err(());
    }
    let stream = unsafe { UnixStream::from_raw_fd(fd) }; // Closes on every error path.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
        return Err(());
    }
    stream.set_nonblocking(true).map_err(|_| ())?;
    #[cfg(target_os = "macos")]
    {
        let one: libc::c_int = 1;
        if unsafe {
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_NOSIGPIPE,
                &one as *const _ as *const libc::c_void,
                std::mem::size_of_val(&one) as libc::socklen_t,
            )
        } != 0
        {
            return Err(());
        }
    }
    let result = unsafe {
        libc::connect(
            fd,
            &address as *const _ as *const libc::sockaddr,
            std::mem::size_of_val(&address) as libc::socklen_t,
        )
    };
    if result != 0 {
        let code = std::io::Error::last_os_error().raw_os_error();
        if !matches!(code, Some(libc::EINPROGRESS | libc::EINTR | libc::EAGAIN)) {
            return Err(());
        }
        wait_ready(fd, libc::POLLOUT, deadline)?;
        if stream.take_error().map_err(|_| ())?.is_some() {
            return Err(());
        }
    }
    stream.peer_addr().map_err(|_| ())?;
    Ok(stream)
}

fn time_remaining(deadline: Instant) -> Result<Duration, ()> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or(())
}

fn wait_ready(fd: std::os::fd::RawFd, events: libc::c_short, deadline: Instant) -> Result<(), ()> {
    let mut descriptor = libc::pollfd {
        fd,
        events,
        revents: 0,
    };
    loop {
        let duration = time_remaining(deadline)?;
        let milliseconds = duration.as_millis().saturating_add(1).min(i32::MAX as u128) as i32;
        let result = unsafe { libc::poll(&mut descriptor, 1, milliseconds) };
        if result > 0 {
            return if descriptor.revents & libc::POLLNVAL == 0 {
                Ok(())
            } else {
                Err(())
            };
        }
        if result < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        return Err(());
    }
}

fn read_frame(stream: &mut UnixStream, timeout: Duration) -> Result<Vec<u8>, ()> {
    stream.set_nonblocking(true).map_err(|_| ())?;
    let deadline = Instant::now() + timeout;
    let mut output = Vec::new();
    let mut bytes = [0_u8; 8192];
    loop {
        wait_ready(stream.as_raw_fd(), libc::POLLIN, deadline)?;
        match stream.read(&mut bytes) {
            Ok(0) => return Ok(output),
            Ok(count) => {
                if output.len() + count > MAX_FRAME {
                    return Err(());
                }
                output.extend_from_slice(&bytes[..count]);
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                ) =>
            {
                continue
            }
            Err(_) => return Err(()),
        }
    }
}

struct StagingDirectory(PathBuf);
impl StagingDirectory {
    fn new() -> std::io::Result<Self> {
        let path = std::env::temp_dir().join(format!("thumble-native-cli-{}", Uuid::new_v4()));
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(Self(path))
    }
}
impl Drop for StagingDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cli_profile::{CliProfileCommand, ProfileSelector, CLI_PROFILE_SCHEMA_VERSION};

    fn request(command: CliProfileCommand) -> CliProfileRequest {
        CliProfileRequest {
            schema_version: CLI_PROFILE_SCHEMA_VERSION,
            invocation_id: Some(Uuid::new_v4()),
            expected_configuration_revision: None,
            command,
        }
    }

    #[test]
    fn native_design_private_capture_is_durable_and_checks_the_entire_base() {
        let root = StagingDirectory::new().unwrap();
        let paths = HostPaths::new(root.0.clone(), root.0.join("unused.sock"));
        let state = PersistentState::minimal("native-design-test").unwrap();
        let document = ConfigurationDocument::from_state(&state).unwrap();
        let mut capture = request(CliProfileCommand::DesignSnapshot { target: ProfileSelector::Active,
            create_draft: true, draft_id: None, expected_draft_revision: None });
        capture.expected_configuration_revision = Some(17);
        let (response, candidate) = evaluate_with_drafts(&document, 17, &capture, Some(&paths));
        assert!(response.ok, "{:?}", response.error);
        assert!(candidate.is_none());
        assert!(!paths.state_file.exists());
        let snapshot = response.design_snapshot.unwrap();
        let id = snapshot.draft_id.unwrap();
        assert_eq!(snapshot.draft_revision, Some(1));
        let draft = DraftStore::new(&paths).get(&id.to_string(), crate::cli_profile::now_millis()).unwrap();
        assert_eq!(draft.base_document, document);
        let mut resume = request(CliProfileCommand::DesignSnapshot { target: ProfileSelector::Active,
            create_draft: false, draft_id: Some(id), expected_draft_revision: Some(1) });
        resume.expected_configuration_revision = Some(17);
        let (response, candidate) = evaluate_with_drafts(&document, 17, &resume, Some(&paths));
        assert!(response.ok, "{:?}", response.error);
        assert!(candidate.is_none());
        assert_eq!(response.design_snapshot.unwrap().draft_id, Some(id));
        let mut changed = document.clone();
        changed.profiles[0]["name"] = serde_json::json!("Changed without reusing an old base");
        let (rejected, _) = evaluate_with_drafts(&changed, 17, &resume, Some(&paths));
        assert_eq!(rejected.error.unwrap().code, "native_draft_base_conflict");
        let (rejected, _) = evaluate(&document, 17, &capture);
        assert_eq!(rejected.error.unwrap().code, "private_draft_authority_required");
        assert!(!paths.state_file.exists());
    }

    #[test]
    fn missing_invocation_id_is_assigned_once_for_snapshot_evaluation_and_commit() {
        use std::net::Shutdown;
        use std::os::unix::net::UnixListener;
        let staging = StagingDirectory::new().unwrap();
        let paths = HostPaths::new(staging.0.clone(), staging.0.join("unused.sock"));
        let directory = socket_directory(&paths).unwrap();
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let listener = UnixListener::bind(directory.join(SOCKET_NAME)).unwrap();
        fs::set_permissions(
            directory.join(SOCKET_NAME),
            fs::Permissions::from_mode(0o600),
        )
        .unwrap();
        let state = PersistentState::minimal("native-test").unwrap();
        let document = ConfigurationDocument::from_state(&state).unwrap();
        let worker = std::thread::spawn(move || {
            let instance = Uuid::new_v4();
            let mut invocation = None;
            for index in 0..2 {
                let (mut stream, _) = listener.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut bytes = Vec::new();
                stream.read_to_end(&mut bytes).unwrap();
                let input: serde_json::Value =
                    thumble_protocol::decode_unique_json(&bytes).unwrap();
                let id = input["invocationID"].clone();
                let mut response = serde_json::json!({"schemaVersion":1,"requestID":input["requestID"],"instanceID":instance,
                    "configurationRevision":12,"contentHash":"a".repeat(64)});
                if index == 0 {
                    invocation = Some(id);
                    response["document"] = serde_json::to_value(&document).unwrap();
                } else {
                    assert_eq!(Some(id.clone()), invocation);
                    if input["replayResponse"]["invocationID"] == id {
                        response["replayResponse"] = input["replayResponse"].clone();
                    } else {
                        response["error"] = serde_json::json!({"code":"invalid_native_configuration","message":"replay invocation differs"});
                    }
                }
                let mut bytes = serde_json::to_vec(&response).unwrap();
                bytes.push(b'\n');
                stream.write_all(&bytes).unwrap();
                stream.shutdown(Shutdown::Write).unwrap();
            }
        });
        let mut req = request(CliProfileCommand::Rename {
            target: ProfileSelector::Active,
            name: "Once".to_owned(),
        });
        req.invocation_id = None;
        let response = execute(&paths, &req);
        worker.join().unwrap();
        fs::remove_dir_all(directory).unwrap();
        assert!(response.ok, "{:?}", response.error);
        assert!(
            req.invocation_id.is_none(),
            "Caller request must remain unchanged"
        );
        assert!(!paths.state_file.exists());
    }

    #[test]
    fn saturated_connection_queue_cannot_escape_the_connection_deadline() {
        use std::os::unix::net::UnixListener;
        let staging = StagingDirectory::new().unwrap();
        let paths = HostPaths::new(staging.0.clone(), staging.0.join("unused.sock"));
        let directory = socket_directory(&paths).unwrap();
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let socket_directory_guard = StagingDirectory(directory);
        let path = socket_directory_guard.0.join("blocked.sock");
        let listener = UnixListener::bind(&path).unwrap();
        assert_eq!(unsafe { libc::listen(listener.as_raw_fd(), 1) }, 0);
        let mut pending = Vec::new();
        let mut saturated = false;
        for _ in 0..128 {
            match connect_stream(&path, Duration::from_millis(5)) {
                Ok(stream) => pending.push(stream),
                Err(()) => {
                    saturated = true;
                    break;
                }
            }
        }
        assert!(saturated, "Fixture must actually fill the unaccepted queue");
        let started = Instant::now();
        assert!(connect_stream(&path, Duration::from_millis(120)).is_err());
        assert!(started.elapsed() < Duration::from_millis(300));
        assert!(!pending.is_empty());
    }

    #[test]
    fn frame_deadline_is_not_extended_by_partial_reads() {
        let (mut reader, mut writer) = UnixStream::pair().unwrap();
        let worker = std::thread::spawn(move || {
            for _ in 0..30 {
                writer.write_all(b" ").unwrap();
                std::thread::sleep(Duration::from_millis(15));
            }
        });
        let started = Instant::now();
        assert!(read_frame(&mut reader, Duration::from_millis(120)).is_err());
        assert!(started.elapsed() < Duration::from_millis(300));
        worker.join().unwrap();
    }

    #[test]
    fn evaluation_reads_owned_configuration_without_a_persistent_store() {
        let state = PersistentState::minimal("test-native").unwrap();
        let document = ConfigurationDocument::from_state(&state).unwrap();
        let original = document.clone();
        let (response, candidate) = evaluate(&document, 12, &request(CliProfileCommand::List));
        assert!(response.ok, "{:?}", response.error);
        assert_eq!(response.authority_mode, "native");
        assert_eq!(response.catalog.unwrap().configuration_revision, 12);
        assert!(candidate.is_none());
        assert_eq!(document, original);
    }

    #[test]
    fn evaluation_returns_a_valid_candidate_and_keeps_the_source_unchanged() {
        let state = PersistentState::minimal("test-native").unwrap();
        let document = ConfigurationDocument::from_state(&state).unwrap();
        let (response, candidate) = evaluate(
            &document,
            12,
            &request(CliProfileCommand::Rename {
                target: ProfileSelector::Active,
                name: "Native independently owned".to_owned(),
            }),
        );
        assert!(response.ok, "{:?}", response.error);
        let candidate = candidate.unwrap();
        candidate.validate().unwrap();
        assert_eq!(candidate.profiles[0]["name"], "Native independently owned");
        assert_eq!(document.profiles[0]["name"], "Default");
        assert_eq!(response.outcome.unwrap().configuration_revision, 13);
    }

    #[test]
    fn invalid_native_sources_and_revision_conflicts_never_return_candidates() {
        let state = PersistentState::minimal("test-native").unwrap();
        let mut document = ConfigurationDocument::from_state(&state).unwrap();
        let mut req = request(CliProfileCommand::Rename {
            target: ProfileSelector::Active,
            name: "Reject".to_owned(),
        });
        req.expected_configuration_revision = Some(10);
        let (response, candidate) = evaluate(&document, 12, &req);
        assert!(!response.ok);
        assert!(candidate.is_none());
        assert_eq!(
            response.error.unwrap().code,
            "configuration_revision_conflict"
        );
        document.profiles[0]["customization"]["elements"][0]["id"] = serde_json::json!("jump");
        let original = document.clone();
        let (response, candidate) = evaluate(&document, 12, &req);
        assert!(!response.ok);
        assert!(candidate.is_none());
        assert_eq!(response.error.unwrap().code, "invalid_native_configuration");
        assert_eq!(document, original);
    }
}
