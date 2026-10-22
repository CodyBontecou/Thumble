use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};
static FIXTURE_SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
fn fixture() -> PathBuf {
    let path = fs::canonicalize(std::env::temp_dir())
        .unwrap()
        .join(format!(
            "thumble-export-{}-{}-{}",
            FIXTURE_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
    fs::create_dir(&path).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    }
    path
}
fn run(path: &Path, bytes: &[u8]) -> std::process::Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_thumble-rewrite-receiver"))
        .arg("configuration-export-file")
        .arg(path)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(bytes).unwrap();
    child.wait_with_output().unwrap()
}
#[test]
fn publication_is_exact_private_no_clobber_and_verified_on_replay() {
    let root = fixture();
    let path = root.join("saved.json");
    let bytes = b"{\"opaque\":9007199254740993.0000}";
    let result = run(&path, bytes);
    assert!(result.status.success(), "{result:?}");
    let reply: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(reply["version"], 1);
    assert_eq!(reply["replayed"], false);
    assert_eq!(reply["byteCount"], bytes.len());
    assert_eq!(reply.as_object().unwrap().len(), 4);
    assert_eq!(fs::read(&path).unwrap(), bytes);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    let repeat = run(&path, bytes);
    assert!(repeat.status.success());
    let repeat: serde_json::Value = serde_json::from_slice(&repeat.stdout).unwrap();
    assert_eq!(repeat["replayed"], true);
    assert_eq!(repeat["artifactHash"], reply["artifactHash"]);
    let existing = run(&path, b"different");
    assert!(!existing.status.success());
    assert_eq!(
        String::from_utf8(existing.stderr).unwrap().trim(),
        "configuration_export_exists"
    );
    assert_eq!(fs::read(&path).unwrap(), bytes);
    assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn malformed_destinations_and_nonregular_or_linked_targets_are_refused() {
    let root = fixture();
    for path in [
        PathBuf::from("relative.json"),
        root.join("missing").join("saved.json"),
        root.clone(),
    ] {
        assert!(!run(&path, b"{}").status.success());
    }
    assert!(!run(&root.join("empty.json"), b"").status.success());
    assert!(!run(&root.join("utf8.json"), &[0xff]).status.success());
    let existing = root.join("existing.json");
    fs::write(&existing, b"{}").unwrap();
    let linked = root.join("linked.json");
    fs::hard_link(&existing, &linked).unwrap();
    assert!(!run(&linked, b"{}").status.success());
    #[cfg(unix)]
    {
        use std::os::unix::fs::{symlink, PermissionsExt};
        let symbolic = root.join("symbolic.json");
        symlink(&existing, &symbolic).unwrap();
        assert!(!run(&symbolic, b"{}").status.success());
        let directory = root.join("linked-directory");
        symlink(&root, &directory).unwrap();
        assert!(!run(&directory.join("new.json"), b"{}").status.success());
        let actual = root.join("actual");
        let nested = actual.join("nested");
        fs::create_dir(&actual).unwrap();
        fs::create_dir(&nested).unwrap();
        let intermediate = root.join("intermediate");
        symlink(&actual, &intermediate).unwrap();
        let redirected = run(&intermediate.join("nested").join("new.json"), b"{}");
        assert!(!redirected.status.success());
        assert_eq!(
            String::from_utf8(redirected.stderr).unwrap().trim(),
            "configuration_export_directory_unsafe"
        );
        assert!(!nested.join("new.json").exists());
        let unsafe_directory = root.join("writable");
        fs::create_dir(&unsafe_directory).unwrap();
        fs::set_permissions(&unsafe_directory, fs::Permissions::from_mode(0o777)).unwrap();
        assert!(!run(&unsafe_directory.join("new.json"), b"{}")
            .status
            .success());
    }
    fs::remove_dir_all(root).unwrap();
}
#[test]
fn simultaneous_publication_never_replaces_either_winners_bytes_or_an_existing_file() {
    let root = fixture();
    let path = root.join("race.json");
    let mut threads = vec![];
    for index in 0..8 {
        let path = path.clone();
        threads.push(std::thread::spawn(move || {
            let bytes = format!("{{\"writer\":{index}}}");
            let result = run(&path, bytes.as_bytes());
            (bytes, result)
        }));
    }
    let results = threads
        .into_iter()
        .map(|t| t.join().unwrap())
        .collect::<Vec<_>>();
    let winners = results
        .iter()
        .filter(|(_, result)| result.status.success())
        .collect::<Vec<_>>();
    assert_eq!(winners.len(), 1);
    assert_eq!(fs::read_to_string(&path).unwrap(), winners[0].0);
    assert_eq!(fs::read_dir(&root).unwrap().count(), 1);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn publication_retains_full_eight_mebibyte_limit_and_rejects_the_next_byte() {
    let root = fixture();
    let bytes = vec![b' '; 8 * 1024 * 1024];
    let path = root.join("limit.json");
    assert!(run(&path, &bytes).status.success());
    assert_eq!(fs::metadata(&path).unwrap().len(), bytes.len() as u64);
    let mut oversized = bytes;
    oversized.push(b' ');
    let path = root.join("oversized.json");
    let result = run(&path, &oversized);
    assert!(!result.status.success());
    assert!(!path.exists());
    fs::remove_dir_all(root).unwrap();
}
#[cfg(windows)]
#[test]
fn windows_junctions_alternate_streams_and_device_names_are_refused() {
    let root = fixture();
    let junction = root.join("junction");
    let result = Command::new("cmd")
        .args(["/C", "mklink", "/J"])
        .arg(&junction)
        .arg(&root)
        .output()
        .unwrap();
    assert!(result.status.success(), "{result:?}");
    assert!(!run(&junction.join("saved.json"), b"{}").status.success());
    fs::remove_dir(&junction).unwrap();
    for name in [
        "saved.json:stream",
        "NUL",
        "nul.json",
        "COM1.txt",
        "AUX",
        "trailing.json.",
    ] {
        assert!(!run(&root.join(name), b"{}").status.success());
    }
    fs::remove_dir_all(root).unwrap();
}
