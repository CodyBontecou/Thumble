use ring::digest::{digest, SHA256};
use std::{
    fs::{self, OpenOptions},
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
    sync::atomic::{AtomicU64, Ordering},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let name = format!(
            "thumble-asset-process-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        Self(std::env::temp_dir().canonicalize().unwrap().join(name))
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn invoke(root: &Directory, mode: &str, key: Option<&str>, input: &[u8]) -> std::process::Output {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_thumble-rewrite-receiver"));
    cmd.arg(mode).arg(&root.0);
    if let Some(key) = key {
        cmd.arg(key);
    }
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    child.wait_with_output().unwrap()
}
fn frame(header: &str, payload: &[u8]) -> Vec<u8> {
    let mut frame = (header.len() as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(header.as_bytes());
    frame.extend_from_slice(payload);
    frame
}
fn sha(bytes: &[u8]) -> String {
    digest(&SHA256, bytes)
        .as_ref()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect()
}
#[test]
fn assets_have_a_real_cross_process_exclusive_lease_and_closed_cli_arguments() {
    let root = Directory::new();
    assert!(invoke(&root, "assets-pending", None, &[]).status.success());
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .open(root.0.join("assets-v1/asset-store.lock"))
        .unwrap();
    fs2::FileExt::try_lock_exclusive(&lock).unwrap();
    let denied = invoke(&root, "assets-pending", None, &[]);
    assert!(!denied.status.success());
    assert_eq!(
        String::from_utf8(denied.stderr).unwrap().trim(),
        "asset_owner_busy"
    );
    drop(lock);
    assert!(invoke(&root, "assets-pending", None, &[]).status.success());
    let invalid = Directory::new();
    assert!(!invoke(&invalid, "assets-pending", Some("unexpected"), &[])
        .status
        .success());
    assert!(!invalid.0.exists());
}
#[test]
fn malformed_binary_requests_and_hash_mismatches_fail_before_touching_the_namespace() {
    let payload = b"synthetic asset";
    let key = sha(payload);
    let header=format!("{{\"version\":1,\"operationId\":\"test\",\"payloadHash\":\"{}\",\"assets\":[{{\"sha256\":\"{key}\",\"byteCount\":{}}}]}}","a".repeat(64),payload.len());
    for input in [
        frame(&header, b"bad"),
        frame(&header, &vec![b'x'; payload.len()]),
        frame(
            &header.replace("\"version\":1", "\"version\":1,\"version\":1"),
            payload,
        ),
        vec![0xff, 0xff, 0xff, 0xff],
    ] {
        let root = Directory::new();
        let reply = invoke(&root, "assets-prepare", None, &input);
        assert!(!reply.status.success());
        assert!(reply.stdout.is_empty());
        assert!(!root.0.exists());
    }
    let root = Directory::new();
    let reply = invoke(&root, "assets-prepare", None, &frame(&header, payload));
    assert!(reply.status.success());
    assert_eq!(
        invoke(&root, "assets-read", Some(&key), &[]).stdout,
        payload
    );
}

#[test]
fn shared_binary_frame_and_preparation_vector_match_the_native_helper() {
    let vector: serde_json::Value = serde_json::from_str(include_str!(
        "../../../packages/fixtures/asset-files-v1/vector.json"
    ))
    .unwrap();
    let hex = vector["frameHex"].as_str().unwrap();
    let bytes = hex
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
        .collect::<Vec<_>>();
    let root = Directory::new();
    let reply = invoke(&root, "assets-prepare", None, &bytes);
    assert!(
        reply.status.success(),
        "{}",
        String::from_utf8_lossy(&reply.stderr)
    );
    let preparation: serde_json::Value = serde_json::from_slice(&reply.stdout).unwrap();
    assert_eq!(preparation, vector["preparation"]);
    for object in vector["objects"].as_array().unwrap() {
        let reply = invoke(
            &root,
            "assets-read",
            Some(object["sha256"].as_str().unwrap()),
            &[],
        );
        assert!(reply.status.success());
        let expected = object["bytes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|n| u8::try_from(n.as_u64().unwrap()).unwrap())
            .collect::<Vec<_>>();
        assert_eq!(reply.stdout, expected);
    }
}

#[test]
fn byte_and_entry_quotas_reject_new_preparations_before_writing_a_journal() {
    for entry_limit in [false, true] {
        let root = Directory::new();
        assert!(invoke(&root, "assets-pending", None, &[]).status.success());
        let count = if entry_limit { 4352 } else { 32 };
        for i in 0..count {
            let path = root.0.join("assets-v1").join(format!("obj-{i:064x}.bin"));
            let file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(path)
                .unwrap();
            if !entry_limit {
                file.set_len(8 * 1024 * 1024).unwrap();
            }
        }
        let header = format!(
            "{{\"version\":1,\"operationId\":\"quota\",\"payloadHash\":\"{}\",\"assets\":[]}}",
            "a".repeat(64)
        );
        let reply = invoke(&root, "assets-prepare", None, &frame(&header, &[]));
        assert!(!reply.status.success());
        assert_eq!(
            String::from_utf8(reply.stderr).unwrap().trim(),
            "asset_storage_full"
        );
        assert!(reply.stdout.is_empty());
        assert_eq!(
            fs::read_dir(root.0.join("assets-v1")).unwrap().count(),
            count + 2
        );
    }
}
