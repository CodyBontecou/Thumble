//! Per-user, bounded, atomic state storage. An unreadable record is fatal:
//! never replace an existing identity or pairing database with defaults.
use fs2::FileExt;
use serde::{de::DeserializeOwned, Serialize};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};
use thumble_core::{ConfigurationDocument, PersistentState};
#[cfg(windows)]
#[path = "windows_security.rs"]
mod windows_security;

pub const MAX_STATE_BYTES: u64 = 8 * 1024 * 1024;
#[derive(Clone)]
pub struct Store {
    pub directory: PathBuf,
}

impl Store {
    pub fn open(directory: Option<PathBuf>) -> Result<Self, String> {
        let directory = directory
            .or_else(|| {
                directories::ProjectDirs::from("com", "Thumble", "ThumbleReceiver")
                    .map(|d| d.data_local_dir().to_path_buf())
            })
            .ok_or("Cannot resolve user data directory")?;
        if directory.exists() {
            validate(&directory, true)?;
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(&directory)
                .map_err(|e| e.to_string())?;
        }
        #[cfg(windows)]
        fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
        protect(&directory, true)?;
        Ok(Self { directory })
    }
    pub fn lock(&self) -> Result<File, String> {
        let path = self.directory.join("receiver.lock");
        let file = private_options()
            .create(true)
            .truncate(false)
            .write(true)
            .read(true)
            .open(&path)
            .map_err(|e| e.to_string())?;
        validate(&path, false)?;
        protect(&path, false)?;
        file.try_lock_exclusive()
            .map_err(|_| "Receiver is already running or its state is in use".to_owned())?;
        Ok(file)
    }
    pub fn load(&self) -> Result<PersistentState, String> {
        let path = self.directory.join("state.json");
        match fs::symlink_metadata(&path) {
            Ok(_) => {
                let state: PersistentState = self.read("state.json")?;
                state
                    .validate()
                    .map_err(|e| format!("Invalid saved state: {e}"))?;
                Ok(state)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let state = PersistentState::minimal(uuid::Uuid::new_v4().to_string())
                    .map_err(|e| e.to_string())?;
                self.save(&state)?;
                Ok(state)
            }
            Err(e) => Err(format!("Inspect saved state: {e}")),
        }
    }
    pub fn save(&self, state: &PersistentState) -> Result<(), String> {
        state.validate().map_err(|e| e.to_string())?;
        self.write("state.json", state)
    }
    pub fn read<T: DeserializeOwned>(&self, name: &str) -> Result<T, String> {
        let path = self.directory.join(name);
        validate(&path, false)?;
        let file = private_options()
            .read(true)
            .open(&path)
            .map_err(|e| format!("Open {name}: {e}"))?;
        validate(&path, false)?;
        let mut bytes = Vec::new();
        file.take(MAX_STATE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_STATE_BYTES {
            return Err(format!("{name} exceeds size limit"));
        }
        thumble_protocol::decode_unique_json(&bytes)
            .map_err(|_| format!("Invalid {name}; existing file preserved"))
    }
    pub fn write<T: Serialize>(&self, name: &str, value: &T) -> Result<(), String> {
        let data = serde_json::to_vec(value).map_err(|e| e.to_string())?;
        if data.len() as u64 > MAX_STATE_BYTES {
            return Err("State exceeds size limit".into());
        }
        let path = self.directory.join(name);
        match fs::symlink_metadata(&path) {
            Ok(_) => validate(&path, false)?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
            Err(e) => return Err(e.to_string()),
        }
        let mut temp =
            tempfile::NamedTempFile::new_in(&self.directory).map_err(|e| e.to_string())?;
        protect(temp.path(), false)?;
        temp.write_all(&data)
            .and_then(|_| temp.as_file().sync_all())
            .map_err(|e| e.to_string())?;
        temp.persist(&path)
            .map_err(|e| format!("Atomic save {name}: {}", e.error))?;
        #[cfg(unix)]
        File::open(&self.directory)
            .and_then(|directory| directory.sync_all())
            .map_err(|e| e.to_string())?;
        Ok(())
    }
    pub fn import_configuration(&self, path: &Path) -> Result<(), String> {
        let _lock = self.lock()?;
        let mut bytes = Vec::new();
        File::open(path)
            .map_err(|e| e.to_string())?
            .take(MAX_STATE_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() as u64 > MAX_STATE_BYTES {
            return Err("Configuration exceeds size limit".into());
        }
        let document: ConfigurationDocument = thumble_protocol::decode_unique_json(&bytes)
            .map_err(|_| "Invalid ConfigurationDocument".to_owned())?;
        document.validate().map_err(|e| e.to_string())?;
        let mut state = self.load()?;
        document
            .install_into(&mut state)
            .map_err(|e| e.to_string())?;
        state
            .bump_configuration_revision()
            .map_err(|e| e.to_string())?;
        state.configuration_updated_at = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis().min(i64::MAX as u128) as i64)
            .unwrap_or(0);
        self.save(&state)
    }
}

fn private_options() -> OpenOptions {
    let mut options = OpenOptions::new();
    #[cfg(unix)]
    options
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
    }
    options
}
fn validate(path: &Path, directory: bool) -> Result<(), String> {
    let metadata = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if metadata.file_type().is_symlink()
        || (if directory {
            !metadata.is_dir()
        } else {
            !metadata.is_file()
        })
    {
        return Err("State path must be a real directory/regular file".into());
    }
    #[cfg(unix)]
    {
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err("State must be owned by the current user".into());
        }
        if metadata.mode() & 0o077 != 0 || (!directory && metadata.nlink() != 1) {
            return Err("State files must be private, without hard links".into());
        }
    }
    #[cfg(windows)]
    windows_security::protect(path, directory)?;
    Ok(())
}
fn protect(path: &Path, directory: bool) -> Result<(), String> {
    #[cfg(unix)]
    {
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if directory { 0o700 } else { 0o600 }),
        )
        .map_err(|e| e.to_string())
    }
    #[cfg(windows)]
    {
        windows_security::protect(path, directory)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identity_is_durable_and_corrupt_state_never_resets_it() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(Some(temp.path().join("state"))).unwrap();
        let _lock = store.lock().unwrap();
        assert!(store.lock().is_err());
        let state = store.load().unwrap();
        assert_eq!(store.load().unwrap(), state);
        fs::write(store.directory.join("state.json"), b"{bad").unwrap();
        assert!(store.load().is_err());
        assert_eq!(
            fs::read(store.directory.join("state.json")).unwrap(),
            b"{bad"
        );
    }
    #[test]
    fn configuration_import_preserves_identity_and_rejects_live_mutation() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(Some(temp.path().join("state"))).unwrap();
        let mut state = store.load().unwrap();
        state.trusted_clients.insert(
            "test-token".into(),
            thumble_core::TrustedClient {
                name: "Test".into(),
                created_at: 1,
                last_seen_at: 1,
            },
        );
        store.save(&state).unwrap();
        let mut document = ConfigurationDocument::from_state(&state).unwrap();
        document.profiles[0]["name"] = serde_json::json!("Imported Windows layout");
        let path = temp.path().join("configuration.json");
        fs::write(&path, serde_json::to_vec(&document).unwrap()).unwrap();
        let lock = store.lock().unwrap();
        assert!(store.import_configuration(&path).is_err());
        drop(lock);
        store.import_configuration(&path).unwrap();
        let imported = store.load().unwrap();
        assert_eq!(imported.server_id, state.server_id);
        assert_eq!(imported.trusted_clients, state.trusted_clients);
        assert_eq!(
            imported.configuration_revision,
            state.configuration_revision + 1
        );
        assert_eq!(imported.profiles[0]["name"], "Imported Windows layout");
        fs::write(&path, b"{bad").unwrap();
        assert!(store.import_configuration(&path).is_err());
        assert_eq!(store.load().unwrap(), imported);
    }
    #[cfg(unix)]
    #[test]
    fn symlink_and_world_readable_state_are_rejected() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(Some(temp.path().join("state"))).unwrap();
        store.load().unwrap();
        fs::set_permissions(
            store.directory.join("state.json"),
            fs::Permissions::from_mode(0o644),
        )
        .unwrap();
        assert!(store.load().is_err());
        let link = temp.path().join("link");
        std::os::unix::fs::symlink(&store.directory, &link).unwrap();
        assert!(Store::open(Some(link)).is_err());
    }
}
