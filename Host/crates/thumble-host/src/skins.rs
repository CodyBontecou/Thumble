//! Native skin interpretation with a private, atomic archive store. This module
//! never imports an archive's embedded profile, extracts ZIP paths, or owns HID.
use crate::bridge::ConfigurationBridge;
use crate::paths::HostPaths;
use base64::{engine::general_purpose::STANDARD, Engine};
use fs2::FileExt;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use uuid::Uuid;

const MAXIMUM_ARCHIVE_BYTES: usize = 40 * 1024 * 1024;
const MAXIMUM_SKIN_REQUEST_BYTES: usize = 64 * 1024 * 1024;
const MAXIMUM_PACKAGES: usize = 256;
const MAXIMUM_LIBRARY_BYTES: u64 = 512 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SkinReference {
    pub identifier: String,
    pub version: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SkinPackageInfo {
    pub reference: SkinReference,
    #[serde(rename = "archiveSHA256")]
    pub archive_sha256: String,
    pub storage_key: String,
    pub name: String,
}

#[derive(Debug)]
pub struct SkinError(pub &'static str);
impl std::fmt::Display for SkinError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.0)
    }
}
impl std::error::Error for SkinError {}

#[derive(Debug, Clone)]
pub struct SkinBridge(ConfigurationBridge);

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Response {
    schema_version: u32,
    #[serde(rename = "invocationID")]
    invocation_id: Uuid,
    reference: Option<SkinReference>,
    #[serde(rename = "archiveSHA256")]
    archive_sha256: Option<String>,
    storage_key: Option<String>,
    name: Option<String>,
    profile: Option<Value>,
}

/// Only the native decoder can construct a package accepted by the store.
#[derive(Debug, Clone)]
pub struct ValidatedSkinPackage {
    info: SkinPackageInfo,
    archive: Vec<u8>,
}
impl ValidatedSkinPackage {
    pub fn info(&self) -> &SkinPackageInfo {
        &self.info
    }
    pub fn archive(&self) -> &[u8] {
        &self.archive
    }
    pub fn wire_archive(&self) -> String {
        STANDARD.encode(&self.archive)
    }
}

impl SkinBridge {
    pub fn discover() -> Result<Self, SkinError> {
        Self::new(
            ConfigurationBridge::discover().map_err(|_| SkinError("skin_bridge_unavailable"))?,
        )
    }

    pub fn new(bridge: ConfigurationBridge) -> Result<Self, SkinError> {
        let bridge = Self(bridge);
        let response = bridge.invoke("capabilities", None, None, None, "light", 0)?;
        if response.reference.is_some()
            || response.archive_sha256.is_some()
            || response.storage_key.is_some()
            || response.name.is_some()
            || response.profile.is_some()
        {
            return Err(SkinError("invalid_skin_bridge_response"));
        }
        Ok(bridge)
    }

    fn invoke(
        &self,
        command: &str,
        archive: Option<&[u8]>,
        reference: Option<&SkinReference>,
        profile: Option<&Value>,
        color_scheme: &str,
        now_millis: i64,
    ) -> Result<Response, SkinError> {
        if now_millis < 0
            || !matches!(color_scheme, "light" | "dark")
            || archive.is_some_and(|data| data.is_empty() || data.len() > MAXIMUM_ARCHIVE_BYTES)
        {
            return Err(SkinError("invalid_skin_request"));
        }
        let nonce = Uuid::new_v4();
        let mut request = json!({"schemaVersion":1,"invocationID":nonce,"skinCommand":command,
            "colorScheme":color_scheme,"nowMillis":now_millis});
        if let Some(archive) = archive {
            request["packageData"] = json!(STANDARD.encode(archive));
        }
        if let Some(reference) = reference {
            request["reference"] = json!(reference);
        }
        if let Some(profile) = profile {
            request["profile"] = profile.clone();
        }
        self.execute_request(request, nonce)
    }

    fn execute_request(&self, request: Value, nonce: Uuid) -> Result<Response, SkinError> {
        let mut input =
            serde_json::to_vec(&request).map_err(|_| SkinError("invalid_skin_request"))?;
        if input.len() > MAXIMUM_SKIN_REQUEST_BYTES {
            return Err(SkinError("skin_request_too_large"));
        }
        input.push(b'\n');
        let output = self
            .0
            .execute_bounded(input, MAXIMUM_SKIN_REQUEST_BYTES)
            .map_err(|_| SkinError("skin_bridge_failed"))?;
        let response: Response = thumble_protocol::decode_unique_json(&output)
            .map_err(|_| SkinError("invalid_skin_bridge_response"))?;
        if response.schema_version != 1 || response.invocation_id != nonce {
            return Err(SkinError("invalid_skin_bridge_response"));
        }
        Ok(response)
    }

    pub fn storage_key(&self, reference: &SkinReference) -> Result<String, SkinError> {
        let response = self.invoke("reference", None, Some(reference), None, "light", 0)?;
        if response.reference.is_none()
            || response.archive_sha256.is_some()
            || response.name.is_some()
            || response.profile.is_some()
        {
            return Err(SkinError("invalid_skin_bridge_response"));
        }
        let key = response
            .storage_key
            .ok_or(SkinError("invalid_skin_bridge_response"))?;
        if !valid_hash(&key) {
            return Err(SkinError("invalid_skin_bridge_response"));
        }
        Ok(key)
    }

    pub fn inspect(&self, archive: Vec<u8>) -> Result<ValidatedSkinPackage, SkinError> {
        let response = self.invoke("inspect", Some(&archive), None, None, "light", 0)?;
        self.validated_inspection(archive, response)
    }

    pub fn inspect_for_install(
        &self,
        archive: Vec<u8>,
        policy: &str,
        installed: &[SkinPackageInfo],
    ) -> Result<ValidatedSkinPackage, SkinError> {
        if archive.is_empty()
            || archive.len() > MAXIMUM_ARCHIVE_BYTES
            || installed.len() > MAXIMUM_PACKAGES
            || !matches!(
                policy,
                "newerOnly" | "replaceSameVersion" | "allowDowngrade"
            )
        {
            return Err(SkinError("invalid_skin_request"));
        }
        let nonce = Uuid::new_v4();
        let installed = installed
            .iter()
            .map(|p| json!({"reference":p.reference,"archiveSHA256":p.archive_sha256}))
            .collect::<Vec<_>>();
        let request = json!({"schemaVersion":1,"invocationID":nonce,"skinCommand":"inspect","nowMillis":0,"packageData":STANDARD.encode(&archive),"installation":{"policy":policy,"installed":installed}});
        let response = self.execute_request(request, nonce)?;
        self.validated_inspection(archive, response)
    }

    fn validated_inspection(
        &self,
        archive: Vec<u8>,
        response: Response,
    ) -> Result<ValidatedSkinPackage, SkinError> {
        if response.profile.is_some() {
            return Err(SkinError("invalid_skin_bridge_response"));
        }
        let info = SkinPackageInfo {
            reference: response
                .reference
                .ok_or(SkinError("invalid_skin_bridge_response"))?,
            archive_sha256: response
                .archive_sha256
                .ok_or(SkinError("invalid_skin_bridge_response"))?,
            storage_key: response
                .storage_key
                .ok_or(SkinError("invalid_skin_bridge_response"))?,
            name: response
                .name
                .ok_or(SkinError("invalid_skin_bridge_response"))?,
        };
        if info.archive_sha256 != digest(&archive)
            || !valid_hash(&info.storage_key)
            || info.name.is_empty()
            || info.name.len() > 4096
            || self.storage_key(&info.reference)? != info.storage_key
        {
            return Err(SkinError("invalid_skin_bridge_response"));
        }
        Ok(ValidatedSkinPackage { info, archive })
    }

    pub fn transform(
        &self,
        profile: &Value,
        package: Option<&ValidatedSkinPackage>,
        detach: bool,
        color_scheme: &str,
        now_millis: i64,
    ) -> Result<Value, SkinError> {
        if !detach && package.is_none() {
            return Err(SkinError("skin_package_required"));
        }
        let response = self.invoke(
            if detach { "detach" } else { "apply" },
            package.map(|p| p.archive()),
            None,
            Some(profile),
            color_scheme,
            now_millis,
        )?;
        if response.reference.as_ref() != package.map(|p| &p.info.reference)
            || response.archive_sha256.as_ref() != package.map(|p| &p.info.archive_sha256)
            || response.storage_key.as_ref() != package.map(|p| &p.info.storage_key)
            || response.name.as_ref() != package.map(|p| &p.info.name)
        {
            return Err(SkinError("invalid_skin_bridge_response"));
        }
        let result = response
            .profile
            .ok_or(SkinError("invalid_skin_bridge_response"))?;
        let original_id = profile
            .get("id")
            .and_then(Value::as_str)
            .and_then(|id| Uuid::parse_str(id).ok());
        let result_id = result
            .get("id")
            .and_then(Value::as_str)
            .and_then(|id| Uuid::parse_str(id).ok());
        if original_id.is_none()
            || original_id != result_id
            || ["name", "outputMode", "launchTarget"].iter().any(|key| {
                profile
                    .get(key)
                    .is_some_and(|value| result.get(key) != Some(value))
            })
            || result.get("updatedAt").and_then(Value::as_i64) != Some(now_millis)
            || (detach && result.get("skinReference").is_some_and(|v| !v.is_null()))
        {
            return Err(SkinError("invalid_skin_bridge_response"));
        }
        if !detach {
            let installed: SkinReference = serde_json::from_value(
                result
                    .get("skinReference")
                    .cloned()
                    .ok_or(SkinError("invalid_skin_bridge_response"))?,
            )
            .map_err(|_| SkinError("invalid_skin_bridge_response"))?;
            if self.storage_key(&installed)? != package.unwrap().info.storage_key {
                return Err(SkinError("invalid_skin_bridge_response"));
            }
        }
        Ok(result)
    }
}

/// Expensive native work happens before taking the runtime input mutex. The
/// caller persists this candidate atomically before installing it in HostCore.
#[derive(Debug)]
pub struct PreparedSkinProfileChange {
    base_revision: u64,
    profile_id: Uuid,
    before: Value,
    after: Value,
    now_millis: i64,
}

impl PreparedSkinProfileChange {
    pub fn prepare(
        state: &thumble_core::PersistentState,
        profile_id: Uuid,
        bridge: &SkinBridge,
        package: Option<&ValidatedSkinPackage>,
        detach: bool,
        color_scheme: &str,
        now_millis: i64,
    ) -> Result<Self, SkinError> {
        // Never send credentials, or a profile containing a trusted token, to
        // the child process. All other profiles remain in the authority.
        let document = thumble_core::ConfigurationDocument::from_state(state)
            .map_err(|_| SkinError("invalid_skin_configuration"))?;
        let before = document
            .profiles
            .iter()
            .find(|profile| profile_uuid(profile) == Some(profile_id))
            .ok_or(SkinError("skin_profile_not_found"))?
            .clone();
        let after = bridge.transform(&before, package, detach, color_scheme, now_millis)?;
        Ok(Self {
            base_revision: state.configuration_revision,
            profile_id,
            before,
            after,
            now_millis,
        })
    }

    pub fn candidate(
        &self,
        current: &thumble_core::PersistentState,
    ) -> Result<Option<thumble_core::PersistentState>, SkinError> {
        if current.configuration_revision != self.base_revision {
            return Err(SkinError("configuration_revision_conflict"));
        }
        let mut document = thumble_core::ConfigurationDocument::from_state(current)
            .map_err(|_| SkinError("invalid_skin_configuration"))?;
        let profile = document
            .profiles
            .iter_mut()
            .find(|profile| profile_uuid(profile) == Some(self.profile_id))
            .ok_or(SkinError("skin_profile_not_found"))?;
        if *profile != self.before {
            return Err(SkinError("configuration_revision_conflict"));
        }
        if self.before == self.after {
            return Ok(None);
        }
        *profile = self.after.clone();
        document
            .validate()
            .map_err(|_| SkinError("invalid_skin_configuration"))?;
        document
            .refresh_global_binding_mirrors()
            .map_err(|_| SkinError("invalid_skin_configuration"))?;
        // Clone current state so pairing or liveness changes made while the
        // native helper was running cannot be overwritten by an old snapshot.
        let mut candidate = current.clone();
        document
            .install_into(&mut candidate)
            .map_err(|_| SkinError("invalid_skin_configuration"))?;
        thumble_core::ConfigurationDocument::from_state(&candidate)
            .map_err(|_| SkinError("invalid_skin_configuration"))?;
        candidate
            .bump_configuration_revision()
            .map_err(|_| SkinError("configuration_revision_exhausted"))?;
        candidate.configuration_updated_at = self.now_millis;
        Ok(Some(candidate))
    }
}

fn profile_uuid(profile: &Value) -> Option<Uuid> {
    profile
        .get("id")?
        .as_str()
        .and_then(|id| Uuid::parse_str(id).ok())
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StoredPackage {
    schema_version: u32,
    info: SkinPackageInfo,
    archive: String,
}

#[derive(Debug, Clone)]
pub struct SkinLibrary {
    root: PathBuf,
    bridge: SkinBridge,
}

impl SkinLibrary {
    pub fn open(paths: &HostPaths, bridge: SkinBridge) -> Result<Self, SkinError> {
        paths
            .ensure_state_dir()
            .map_err(|_| SkinError("skin_store_unavailable"))?;
        let root = paths.state_dir.join("skins");
        match fs::symlink_metadata(&root) {
            Ok(_) => validate_directory(&root)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                use std::os::unix::fs::DirBuilderExt;
                match fs::DirBuilder::new().mode(0o700).create(&root) {
                    Ok(()) => (),
                    Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => (),
                    Err(_) => return Err(SkinError("skin_store_unavailable")),
                }
                validate_directory(&root)?;
            }
            Err(_) => return Err(SkinError("skin_store_unavailable")),
        }
        Ok(Self { root, bridge })
    }

    fn lock(&self) -> Result<File, SkinError> {
        validate_directory(&self.root)?;
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.root.join("library.lock"))
            .map_err(|_| SkinError("skin_store_unavailable"))?;
        validate_file(&lock, 0)?;
        lock.lock_exclusive()
            .map_err(|_| SkinError("skin_store_unavailable"))?;
        Ok(lock)
    }

    pub fn install(&self, package: &ValidatedSkinPackage) -> Result<bool, SkinError> {
        let _lock = self.lock()?;
        let destination = self.root.join(format!("{}.json", package.info.storage_key));
        if let Some(existing) = self.read_key(&package.info.storage_key)? {
            if existing.info == package.info {
                return Ok(false);
            }
        }
        let data = serde_json::to_vec(&StoredPackage {
            schema_version: 1,
            info: package.info.clone(),
            archive: package.wire_archive(),
        })
        .map_err(|_| SkinError("skin_store_encoding_failed"))?;
        if data.len() > MAXIMUM_SKIN_REQUEST_BYTES {
            return Err(SkinError("skin_request_too_large"));
        }
        let entries = self.entries()?;
        let mut total = data.len() as u64;
        let mut count = 1;
        for path in entries {
            if path != destination {
                let metadata =
                    fs::symlink_metadata(path).map_err(|_| SkinError("skin_store_unavailable"))?;
                total = total.saturating_add(metadata.len());
                count += 1;
            }
        }
        if total > MAXIMUM_LIBRARY_BYTES || count > MAXIMUM_PACKAGES {
            return Err(SkinError("skin_library_full"));
        }
        let temporary = self.root.join(format!(".{}.tmp", Uuid::new_v4()));
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&temporary)
                .map_err(|_| SkinError("skin_store_write_failed"))?;
            file.write_all(&data)
                .and_then(|()| file.sync_all())
                .map_err(|_| SkinError("skin_store_write_failed"))?;
            fs::rename(&temporary, destination)
                .map_err(|_| SkinError("skin_store_write_failed"))?;
            File::open(&self.root)
                .and_then(|file| file.sync_all())
                .map_err(|_| SkinError("skin_store_write_failed"))?;
            Ok(true)
        })();
        if result.is_err() {
            let _ = fs::remove_file(temporary);
        }
        result
    }

    pub fn load(
        &self,
        reference: &SkinReference,
    ) -> Result<Option<ValidatedSkinPackage>, SkinError> {
        let key = self.bridge.storage_key(reference)?;
        let _lock = self.lock()?;
        self.read_key(&key)
    }

    pub fn list(&self) -> Result<Vec<SkinPackageInfo>, SkinError> {
        let _lock = self.lock()?;
        let mut result = Vec::new();
        for path in self.entries()? {
            let key = path
                .file_stem()
                .and_then(|v| v.to_str())
                .ok_or(SkinError("invalid_skin_store_entry"))?;
            let package = self
                .read_key(key)?
                .ok_or(SkinError("invalid_skin_store_entry"))?;
            result.push(package.info);
        }
        result.sort_by(|a, b| {
            a.reference
                .identifier
                .cmp(&b.reference.identifier)
                .then(a.reference.version.cmp(&b.reference.version))
        });
        Ok(result)
    }

    /// Caller must hold configuration authority and reject references still in use.
    pub fn remove(&self, reference: &SkinReference) -> Result<bool, SkinError> {
        let key = self.bridge.storage_key(reference)?;
        let _lock = self.lock()?;
        if self.read_key(&key)?.is_none() {
            return Ok(false);
        }
        fs::remove_file(self.root.join(format!("{key}.json")))
            .map_err(|_| SkinError("skin_store_write_failed"))?;
        File::open(&self.root)
            .and_then(|file| file.sync_all())
            .map_err(|_| SkinError("skin_store_write_failed"))?;
        Ok(true)
    }

    /// The caller already validated this package on a worker. Compare the exact
    /// stored record before unlinking, without launching native work under the
    /// runtime configuration lock.
    pub(crate) fn remove_validated(&self, package: &ValidatedSkinPackage) -> Result<(), SkinError> {
        let _lock = self.lock()?;
        let path = self.root.join(format!("{}.json", package.info.storage_key));
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&path)
            .map_err(|_| SkinError("skin_store_unavailable"))?;
        validate_file(&file, MAXIMUM_SKIN_REQUEST_BYTES as u64)?;
        let expected = serde_json::to_vec(&StoredPackage {
            schema_version: 1,
            info: package.info.clone(),
            archive: package.wire_archive(),
        })
        .map_err(|_| SkinError("skin_store_encoding_failed"))?;
        let mut actual = Vec::new();
        file.take(expected.len() as u64 + 1)
            .read_to_end(&mut actual)
            .map_err(|_| SkinError("skin_store_unavailable"))?;
        if actual != expected {
            return Err(SkinError("skin_package_changed"));
        }
        fs::remove_file(path).map_err(|_| SkinError("skin_store_write_failed"))?;
        File::open(&self.root)
            .and_then(|f| f.sync_all())
            .map_err(|_| SkinError("skin_store_write_failed"))
    }

    fn entries(&self) -> Result<Vec<PathBuf>, SkinError> {
        let mut result = Vec::new();
        for entry in fs::read_dir(&self.root).map_err(|_| SkinError("skin_store_unavailable"))? {
            let path = entry
                .map_err(|_| SkinError("skin_store_unavailable"))?
                .path();
            if path.extension().is_some_and(|v| v == "json") {
                result.push(path);
                if result.len() > MAXIMUM_PACKAGES {
                    return Err(SkinError("skin_library_full"));
                }
            }
        }
        Ok(result)
    }

    fn read_key(&self, key: &str) -> Result<Option<ValidatedSkinPackage>, SkinError> {
        if !valid_hash(key) {
            return Err(SkinError("invalid_skin_store_entry"));
        }
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(self.root.join(format!("{key}.json")))
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(SkinError("invalid_skin_store_entry")),
        };
        validate_file(&file, MAXIMUM_SKIN_REQUEST_BYTES as u64)?;
        let mut data = Vec::new();
        file.take(MAXIMUM_SKIN_REQUEST_BYTES as u64 + 1)
            .read_to_end(&mut data)
            .map_err(|_| SkinError("invalid_skin_store_entry"))?;
        if data.len() > MAXIMUM_SKIN_REQUEST_BYTES {
            return Err(SkinError("invalid_skin_store_entry"));
        }
        let record: StoredPackage = thumble_protocol::decode_unique_json(&data)
            .map_err(|_| SkinError("invalid_skin_store_entry"))?;
        if record.schema_version != 1 || record.info.storage_key != key {
            return Err(SkinError("invalid_skin_store_entry"));
        }
        let archive = STANDARD
            .decode(record.archive)
            .map_err(|_| SkinError("invalid_skin_store_entry"))?;
        let validated = self.bridge.inspect(archive)?;
        if validated.info != record.info {
            return Err(SkinError("invalid_skin_store_entry"));
        }
        Ok(Some(validated))
    }
}

fn validate_directory(path: &Path) -> Result<(), SkinError> {
    let metadata = fs::symlink_metadata(path).map_err(|_| SkinError("skin_store_unavailable"))?;
    if !metadata.is_dir()
        || metadata.file_type().is_symlink()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(SkinError("skin_store_unavailable"));
    }
    Ok(())
}
fn validate_file(file: &File, maximum: u64) -> Result<(), SkinError> {
    let metadata = file
        .metadata()
        .map_err(|_| SkinError("invalid_skin_store_entry"))?;
    if !metadata.is_file()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
        || metadata.len() > maximum
    {
        return Err(SkinError("invalid_skin_store_entry"));
    }
    Ok(())
}
fn digest(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}
fn valid_hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::{symlink, PermissionsExt};
    use tempfile::TempDir;

    fn fixture() -> (TempDir, SkinBridge, HostPaths) {
        let directory = tempfile::tempdir().unwrap();
        let helper = directory.path().join("bridge");
        // Store tests use a deterministic protocol peer. Native ZIP/model
        // semantics are exercised separately by native_bridge_acceptance.
        fs::write(&helper, r#"#!/usr/bin/python3
import sys,json,hashlib,base64,unicodedata
r=json.load(sys.stdin)
o={'schemaVersion':1,'invocationID':r['invocationID']}
c=r['skinCommand']
if c != 'capabilities':
    ref=r.get('reference',{'identifier':'com.example.skin','version':'1.0.0'})
    ref={'identifier':ref['identifier'].strip().lower(),'version':ref['version'].strip()}
    o['reference']=ref
    o['storageKey']=hashlib.sha256(unicodedata.normalize('NFC',ref['identifier']+'\0'+ref['version']).encode()).hexdigest()
    if 'packageData' in r:
        o['archiveSHA256']=hashlib.sha256(base64.b64decode(r['packageData'])).hexdigest()
        o['name']='Store fixture'
print(json.dumps(o))
"#).unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
        let bridge = SkinBridge::new(ConfigurationBridge::at_path(helper).unwrap()).unwrap();
        let paths = HostPaths::new(
            directory.path().join("state"),
            directory.path().join("control.sock"),
        );
        (directory, bridge, paths)
    }

    #[test]
    fn atomic_library_roundtrip_exact_export_idempotence_and_removal() {
        let (_directory, bridge, paths) = fixture();
        let package = bridge.inspect(b"opaque archive bytes".to_vec()).unwrap();
        let library = SkinLibrary::open(&paths, bridge.clone()).unwrap();
        assert!(library.install(&package).unwrap());
        assert!(!library.install(&package).unwrap());
        assert_eq!(library.list().unwrap(), vec![package.info.clone()]);
        let loaded = library.load(&package.info.reference).unwrap().unwrap();
        assert_eq!(loaded.archive(), package.archive());
        let reopened = SkinLibrary::open(&paths, bridge).unwrap();
        assert_eq!(
            reopened
                .load(&package.info.reference)
                .unwrap()
                .unwrap()
                .info,
            package.info
        );
        assert!(reopened.remove(&package.info.reference).unwrap());
        assert!(!reopened.remove(&package.info.reference).unwrap());
        assert!(reopened.list().unwrap().is_empty());
        assert_eq!(
            fs::metadata(paths.state_dir.join("skins")).unwrap().mode() & 0o777,
            0o700
        );
    }

    #[test]
    fn replacement_is_atomic_and_corruption_never_becomes_a_valid_package() {
        let (_directory, bridge, paths) = fixture();
        let first = bridge.inspect(b"first".to_vec()).unwrap();
        let second = bridge.inspect(b"second".to_vec()).unwrap();
        let library = SkinLibrary::open(&paths, bridge).unwrap();
        library.install(&first).unwrap();
        library.install(&second).unwrap();
        assert_eq!(
            library
                .load(&first.info.reference)
                .unwrap()
                .unwrap()
                .archive(),
            b"second"
        );
        let path = library
            .root
            .join(format!("{}.json", first.info.storage_key));
        let mut record: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        record["archive"] = json!(STANDARD.encode(b"tampered"));
        fs::write(path, serde_json::to_vec(&record).unwrap()).unwrap();
        assert!(library.load(&first.info.reference).is_err());
        assert!(library.list().is_err());
    }

    #[test]
    fn symlinked_directory_archive_and_lock_are_rejected() {
        let (directory, bridge, paths) = fixture();
        paths.ensure_state_dir().unwrap();
        symlink(directory.path(), paths.state_dir.join("skins")).unwrap();
        assert!(SkinLibrary::open(&paths, bridge.clone()).is_err());
        fs::remove_file(paths.state_dir.join("skins")).unwrap();
        let package = bridge.inspect(b"first".to_vec()).unwrap();
        let library = SkinLibrary::open(&paths, bridge).unwrap();
        let outside = directory.path().join("outside");
        fs::write(&outside, b"keep").unwrap();
        symlink(
            &outside,
            library
                .root
                .join(format!("{}.json", package.info.storage_key)),
        )
        .unwrap();
        assert!(library.install(&package).is_err());
        assert!(library.load(&package.info.reference).is_err());
        assert_eq!(fs::read(&outside).unwrap(), b"keep");
        fs::remove_file(library.root.join("library.lock")).unwrap();
        symlink(&outside, library.root.join("library.lock")).unwrap();
        assert!(library.list().is_err());
    }

    #[test]
    fn private_modes_and_duplicate_metadata_keys_are_enforced() {
        let (_directory, bridge, paths) = fixture();
        let package = bridge.inspect(b"first".to_vec()).unwrap();
        let library = SkinLibrary::open(&paths, bridge).unwrap();
        library.install(&package).unwrap();
        let path = library
            .root
            .join(format!("{}.json", package.info.storage_key));
        assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        assert!(library.load(&package.info.reference).is_err());
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        fs::write(path, b"{\"schemaVersion\":1,\"schemaVersion\":1}").unwrap();
        assert!(library.load(&package.info.reference).is_err());
    }

    #[test]
    fn canonical_reference_keys_never_contain_path_characters() {
        let (_directory, bridge, _paths) = fixture();
        let composed = SkinReference {
            identifier: " COM.EXAMPLE.SKIN ".into(),
            version: "1.0.0-café".into(),
        };
        let decomposed = SkinReference {
            identifier: "com.example.skin".into(),
            version: "1.0.0-cafe\u{301}".into(),
        };
        assert_eq!(
            bridge.storage_key(&composed).unwrap(),
            bridge.storage_key(&decomposed).unwrap()
        );
        let traversal = SkinReference {
            identifier: "com.example.skin".into(),
            version: "1.0.0-../../outside".into(),
        };
        assert!(valid_hash(&bridge.storage_key(&traversal).unwrap()));
    }

    #[test]
    fn old_or_replayed_bridge_cannot_advertise_skin_capability() {
        let (directory, _bridge, _paths) = fixture();
        let helper = directory.path().join("old-bridge");
        fs::write(&helper, "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"schemaVersion\":1,\"invocationID\":\"00000000-0000-0000-0000-000000000000\"}'\n").unwrap();
        fs::set_permissions(&helper, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(SkinBridge::new(ConfigurationBridge::at_path(helper).unwrap()).is_err());
    }

    #[test]
    fn prepared_changes_preserve_new_pairing_state_and_reject_concurrent_edits() {
        let state = thumble_core::PersistentState::minimal("server").unwrap();
        let before = state.profiles[0].clone();
        let mut after = before.clone();
        after["skinReference"] = json!({"identifier":"com.example.skin","version":"1.0.0"});
        let prepared = PreparedSkinProfileChange {
            base_revision: state.configuration_revision,
            profile_id: profile_uuid(&before).unwrap(),
            before,
            after,
            now_millis: 123,
        };
        let mut current = state.clone();
        current.trusted_clients.insert(
            "new-private-token".into(),
            thumble_core::TrustedClient {
                name: "New phone".into(),
                created_at: 100,
                last_seen_at: 122,
            },
        );
        let candidate = prepared.candidate(&current).unwrap().unwrap();
        assert_eq!(candidate.trusted_clients, current.trusted_clients);
        assert_eq!(
            candidate.configuration_revision,
            current.configuration_revision + 1
        );
        assert_eq!(candidate.configuration_updated_at, 123);
        assert_eq!(candidate.server_id, current.server_id);
        assert_eq!(candidate.default_profile_id, current.default_profile_id);
        current.profiles[0]["name"] = json!("Concurrent edit");
        assert!(prepared.candidate(&current).is_err());
        current = state;
        current.bump_configuration_revision().unwrap();
        assert!(prepared.candidate(&current).is_err());
    }

    #[test]
    #[ignore = "requires THUMBLE_TEST_SKIN_BRIDGE pointing to the built native executable"]
    fn native_bridge_acceptance() {
        let helper = std::env::var_os("THUMBLE_TEST_SKIN_BRIDGE").expect("native helper required");
        let bridge = SkinBridge::new(ConfigurationBridge::at_path(helper.into()).unwrap()).unwrap();
        let repository = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../..");
        let archive = fs::read(
            repository
                .join("Host/fixtures/legacy-skin-packages/solar-sumi-1.0.0-edbecde5b708.pocketpad"),
        )
        .unwrap();
        let package = bridge.inspect(archive.clone()).unwrap();
        let fixture: Value = serde_json::from_slice(
            &fs::read(
                repository.join("Host/fixtures/controller-templates/v1/productivityStarter.json"),
            )
            .unwrap(),
        )
        .unwrap();
        let profile = &fixture["profile"];
        let applied = bridge
            .transform(profile, Some(&package), false, "light", 123)
            .unwrap();
        let mut state = thumble_core::PersistentState::minimal("native-test-server").unwrap();
        state.profiles = vec![profile.clone()];
        state.active_profile_id = profile["id"].as_str().unwrap().into();
        state.default_profile_id = state.active_profile_id.clone();
        state.key_bindings = serde_json::from_value(fixture["profileKeyBindings"].clone()).unwrap();
        state.output_bindings =
            serde_json::from_value(fixture["profileOutputBindings"].clone()).unwrap();
        state.profile_key_bindings.clear();
        state.profile_output_bindings.clear();
        state
            .profile_key_bindings
            .insert(state.active_profile_id.clone(), state.key_bindings.clone());
        state.profile_output_bindings.insert(
            state.active_profile_id.clone(),
            state.output_bindings.clone(),
        );
        state.validate().unwrap();
        let prepared = PreparedSkinProfileChange::prepare(
            &state,
            profile_uuid(profile).unwrap(),
            &bridge,
            Some(&package),
            false,
            "light",
            123,
        )
        .unwrap();
        assert_eq!(
            prepared.candidate(&state).unwrap().unwrap().profiles[0],
            applied
        );
        assert!(applied.get("skinReference").is_some());
        let detached = bridge
            .transform(&applied, Some(&package), true, "light", 124)
            .unwrap();
        assert!(detached.get("skinReference").is_none());
        let missing = bridge.transform(&applied, None, true, "dark", 125).unwrap();
        assert!(missing.get("skinReference").is_none());
        assert!(bridge.inspect(b"invalid ZIP".to_vec()).is_err());
        let directory = tempfile::tempdir().unwrap();
        let paths = HostPaths::new(
            directory.path().join("state"),
            directory.path().join("control.sock"),
        );
        let library = SkinLibrary::open(&paths, bridge).unwrap();
        library.install(&package).unwrap();
        assert_eq!(
            library
                .load(&package.info.reference)
                .unwrap()
                .unwrap()
                .archive(),
            archive
        );
        assert!(!library.install(&package).unwrap());
        assert_eq!(library.list().unwrap().len(), 1);
    }
}
