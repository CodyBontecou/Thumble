//! Stable host TLS identity in an explicit private directory. Never auto-rotate an existing pin.
use crate::{control_tls::ServerIdentity, security};
use std::{
    fs,
    io::{Read, Write},
    path::Path,
};
const MAGIC: &[u8; 8] = b"THID1\0\0\0";
const MAX_DER: usize = 16_384;
const MAX_RECORD: usize = 16 + MAX_DER * 2;
fn encode(certificate: &[u8], key: &[u8]) -> Result<Vec<u8>, &'static str> {
    if certificate.is_empty()
        || key.is_empty()
        || certificate.len() > MAX_DER
        || key.len() > MAX_DER
    {
        return Err("host_identity_invalid");
    }
    let mut bytes = MAGIC.to_vec();
    bytes.extend((certificate.len() as u32).to_le_bytes());
    bytes.extend((key.len() as u32).to_le_bytes());
    bytes.extend(certificate);
    bytes.extend(key);
    Ok(bytes)
}
fn decode(bytes: &[u8]) -> Result<ServerIdentity, &'static str> {
    if bytes.len() < 16 || bytes.len() > MAX_RECORD || &bytes[..8] != MAGIC {
        return Err("host_identity_invalid");
    }
    let certificate = u32::from_le_bytes(
        bytes[8..12]
            .try_into()
            .map_err(|_| "host_identity_invalid")?,
    ) as usize;
    let key = u32::from_le_bytes(
        bytes[12..16]
            .try_into()
            .map_err(|_| "host_identity_invalid")?,
    ) as usize;
    if !(1..=MAX_DER).contains(&certificate)
        || !(1..=MAX_DER).contains(&key)
        || 16 + certificate + key != bytes.len()
    {
        return Err("host_identity_invalid");
    }
    let identity = ServerIdentity::from_der(
        bytes[16..16 + certificate].to_vec(),
        bytes[16 + certificate..].to_vec(),
    )
    .map_err(|_| "host_identity_invalid")?;
    identity
        .validate_current()
        .map_err(|_| "host_identity_certificate_invalid")?;
    Ok(identity)
}
fn exists(path: &Path) -> Result<bool, &'static str> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err("host_identity_unavailable"),
    }
}
fn read(path: &Path, maximum_links: u64) -> Result<Vec<u8>, &'static str> {
    let file = security::file(path, false)?;
    let metadata = file.metadata().map_err(|_| "host_identity_unavailable")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.nlink() > maximum_links {
            return Err("host_identity_link_rejected");
        }
    }
    #[cfg(not(unix))]
    let _ = maximum_links;
    if metadata.len() > MAX_RECORD as u64 {
        return Err("host_identity_invalid");
    }
    let mut bytes = Vec::new();
    file.take(MAX_RECORD as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "host_identity_unavailable")?;
    decode(&bytes)?;
    Ok(bytes)
}
fn sync_directory(root: &Path) -> Result<(), &'static str> {
    #[cfg(unix)]
    fs::File::open(root)
        .and_then(|f| f.sync_all())
        .map_err(|_| "host_identity_sync_failed")?;
    #[cfg(not(unix))]
    let _ = root;
    Ok(())
}
fn publish(root: &Path) -> Result<(), &'static str> {
    let pending = root.join("identity.pending");
    let record = root.join("identity.bin");
    // Atomic no-clobber publication. Both names stay in the same private directory.
    fs::hard_link(&pending, &record).map_err(|_| "host_identity_publish_failed")?;
    security::file(&record, false)?
        .sync_all()
        .map_err(|_| "host_identity_sync_failed")?;
    sync_directory(root)?;
    fs::remove_file(pending).map_err(|_| "host_identity_cleanup_failed")?;
    sync_directory(root)
}
/// Inspect an initialized identity without creating or recovering key material.
pub fn load_existing(root: &Path) -> Result<ServerIdentity, &'static str> {
    if !exists(root)?
        || !exists(&root.join("rewrite-host-identity-v1"))?
        || !exists(&root.join("identity.bin"))?
    {
        return Err("host_identity_not_initialized");
    }
    security::identity_directory(root)?;
    let lock = security::file(&root.join("identity.lock"), false)?;
    fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "host_identity_owner_exists")?;
    if exists(&root.join("identity.pending"))? {
        return Err("host_identity_recovery_required");
    }
    decode(&read(&root.join("identity.bin"), 1)?)
}
/// The caller chooses persistent application storage, never the disposable runtime directory.
/// Creates once; corrupt/expired/conflicting records fail without replacing trust or pin material.
pub fn load_or_create(root: &Path) -> Result<ServerIdentity, &'static str> {
    security::identity_directory(root)?;
    let lock = security::file(&root.join("identity.lock"), false)?;
    fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "host_identity_owner_exists")?;
    let record = root.join("identity.bin");
    let pending = root.join("identity.pending");
    if exists(&record)? {
        let staged = exists(&pending)?;
        let bytes = read(&record, if staged { 2 } else { 1 })?;
        if staged {
            if read(&pending, 2)? != bytes {
                return Err("host_identity_pending_conflict");
            }
            fs::remove_file(&pending).map_err(|_| "host_identity_cleanup_failed")?;
            sync_directory(root)?;
        }
        return decode(&read(&record, 1)?);
    }
    if exists(&pending)? {
        read(&pending, 1)?;
        publish(root)?;
        return decode(&read(&record, 1)?);
    }
    let (certificate, key) =
        ServerIdentity::generate_material().map_err(|_| "host_identity_generation_failed")?;
    let bytes = encode(&certificate, &key)?;
    decode(&bytes)?;
    let mut file = security::file(&pending, true)?;
    file.write_all(&bytes)
        .and_then(|_| file.sync_all())
        .map_err(|_| "host_identity_write_failed")?;
    drop(file);
    sync_directory(root)?;
    publish(root)?;
    decode(&read(&record, 1)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Directory(std::path::PathBuf);
    impl Directory {
        fn new() -> Self {
            Self(std::env::temp_dir().canonicalize().unwrap().join(format!(
                "thumble-native-identity-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            )))
        }
    }
    impl Drop for Directory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn material() -> Vec<u8> {
        let (cert, key) = ServerIdentity::generate_material().unwrap();
        encode(&cert, &key).unwrap()
    }
    fn stage(root: &Path, bytes: &[u8]) {
        let mut file = security::file(&root.join("identity.pending"), true).unwrap();
        file.write_all(bytes).unwrap();
        file.sync_all().unwrap();
    }
    #[test]
    fn inspection_never_initializes_or_recovers_key_material() {
        let root = Directory::new();
        assert_eq!(
            load_existing(&root.0).err(),
            Some("host_identity_not_initialized")
        );
        assert!(!root.0.exists());
        let identity = load_or_create(&root.0).unwrap();
        assert_eq!(load_existing(&root.0).unwrap().pin(), identity.pin());
        let bytes = fs::read(root.0.join("identity.bin")).unwrap();
        stage(&root.0, &bytes);
        assert_eq!(
            load_existing(&root.0).err(),
            Some("host_identity_recovery_required")
        );
        assert!(root.0.join("identity.pending").exists());
        assert_eq!(load_or_create(&root.0).unwrap().pin(), identity.pin());
    }
    #[test]
    fn stable_reload_and_distinct_isolated_hosts_keep_private_permissions() {
        let a = Directory::new();
        let b = Directory::new();
        let first = load_or_create(&a.0).unwrap();
        let bytes = fs::read(a.0.join("identity.bin")).unwrap();
        let second = load_or_create(&a.0).unwrap();
        assert_eq!(first.pin(), second.pin());
        assert_eq!(first.certificate_der(), second.certificate_der());
        assert_eq!(bytes, fs::read(a.0.join("identity.bin")).unwrap());
        assert_ne!(first.pin(), load_or_create(&b.0).unwrap().pin());
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&a.0).unwrap().permissions().mode() & 0o777,
                0o700
            );
            assert_eq!(
                fs::metadata(a.0.join("identity.bin"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
        assert!(!a.0.join("identity.pending").exists());
    }
    #[test]
    fn complete_staged_creation_recovers_the_same_key_and_pin() {
        let root = Directory::new();
        security::identity_directory(&root.0).unwrap();
        let bytes = material();
        let expected = decode(&bytes).unwrap().pin();
        stage(&root.0, &bytes);
        assert_eq!(load_or_create(&root.0).unwrap().pin(), expected);
        assert_eq!(fs::read(root.0.join("identity.bin")).unwrap(), bytes);
        assert!(!root.0.join("identity.pending").exists());
    }
    #[test]
    fn published_but_not_cleaned_creation_recovers_without_rotation() {
        let root = Directory::new();
        security::identity_directory(&root.0).unwrap();
        let bytes = material();
        stage(&root.0, &bytes);
        fs::hard_link(root.0.join("identity.pending"), root.0.join("identity.bin")).unwrap();
        assert_eq!(
            load_or_create(&root.0).unwrap().pin(),
            decode(&bytes).unwrap().pin()
        );
        assert!(!root.0.join("identity.pending").exists());
    }
    #[test]
    fn corrupt_or_partial_records_never_regenerate_or_overwrite_material() {
        for pending in [false, true] {
            let root = Directory::new();
            security::identity_directory(&root.0).unwrap();
            let path = root.0.join(if pending {
                "identity.pending"
            } else {
                "identity.bin"
            });
            let bytes = b"interrupted-private-record";
            security::file(&path, true)
                .unwrap()
                .write_all(bytes)
                .unwrap();
            assert!(load_or_create(&root.0).is_err());
            assert_eq!(fs::read(&path).unwrap(), bytes);
            if pending {
                assert!(!root.0.join("identity.bin").exists());
            }
        }
        let root = Directory::new();
        let identity = load_or_create(&root.0).unwrap();
        let original = fs::read(root.0.join("identity.bin")).unwrap();
        stage(&root.0, &material());
        assert_eq!(
            load_or_create(&root.0).err(),
            Some("host_identity_pending_conflict")
        );
        assert_eq!(fs::read(root.0.join("identity.bin")).unwrap(), original);
        assert_eq!(decode(&original).unwrap().pin(), identity.pin());
    }
    #[test]
    fn exclusive_identity_owner_and_separate_runtime_namespaces() {
        let root = Directory::new();
        security::identity_directory(&root.0).unwrap();
        let lock = security::file(&root.0.join("identity.lock"), false).unwrap();
        fs2::FileExt::try_lock_exclusive(&lock).unwrap();
        assert_eq!(
            load_or_create(&root.0).err(),
            Some("host_identity_owner_exists")
        );
        assert!(!root.0.join("identity.bin").exists());
        drop(lock);
        load_or_create(&root.0).unwrap();
        assert!(security::directory(&root.0).is_err());
        let runtime = Directory::new();
        security::directory(&runtime.0).unwrap();
        assert!(load_or_create(&runtime.0).is_err());
    }
    #[test]
    fn lengths_magic_trailing_bytes_wrong_keys_and_certificate_policy_fail() {
        let valid = material();
        for bad in [
            vec![],
            vec![0; 16],
            vec![0; MAX_RECORD + 1],
            valid[..valid.len() - 1].to_vec(),
            [valid.as_slice(), &[0]].concat(),
        ] {
            assert!(decode(&bad).is_err());
        }
        let (cert, _) = ServerIdentity::generate_material().unwrap();
        let (_, key) = ServerIdentity::generate_material().unwrap();
        assert!(decode(&encode(&cert, &key).unwrap()).is_err());
        for mode in 0..4 {
            let mut params = rcgen::CertificateParams::new(vec![if mode == 2 {
                "wrong.local"
            } else {
                crate::control_tls::CONTROL_SERVER_NAME
            }
            .into()])
            .unwrap();
            if mode == 0 {
                params.not_before = rcgen::date_time_ymd(2000, 1, 1);
                params.not_after = rcgen::date_time_ymd(2001, 1, 1);
            }
            if mode == 1 {
                params.not_before = rcgen::date_time_ymd(3000, 1, 1);
                params.not_after = rcgen::date_time_ymd(3001, 1, 1);
            }
            if mode == 3 {
                params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ClientAuth];
            }
            let key = rcgen::KeyPair::generate().unwrap();
            let cert = params.self_signed(&key).unwrap();
            assert!(decode(&encode(cert.der(), &key.serialize_der()).unwrap()).is_err());
        }
    }
    #[cfg(unix)]
    #[test]
    fn symlinks_and_external_hardlinks_are_rejected_without_changing_identity() {
        let root = Directory::new();
        let other = Directory::new();
        load_or_create(&other.0).unwrap();
        std::os::unix::fs::symlink(&other.0, &root.0).unwrap();
        assert!(load_or_create(&root.0).is_err());
        fs::remove_file(&root.0).unwrap();
        security::identity_directory(&root.0).unwrap();
        std::os::unix::fs::symlink(other.0.join("identity.bin"), root.0.join("identity.bin"))
            .unwrap();
        assert!(load_or_create(&root.0).is_err());
        fs::remove_file(root.0.join("identity.bin")).unwrap();
        fs::hard_link(other.0.join("identity.bin"), root.0.join("identity.bin")).unwrap();
        assert_eq!(
            load_or_create(&root.0).err(),
            Some("host_identity_link_rejected")
        );
    }
}
