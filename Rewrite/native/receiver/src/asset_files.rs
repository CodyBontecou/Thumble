//! Platform filesystem primitives for immutable content-addressed assets.
//! Configuration validity, revisions and committed receipts belong to the TS owner.
use crate::security;
use ring::digest::{digest, SHA256};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};
const MAX_BYTES: usize = 8 * 1024 * 1024;
const MAX_STORE_BYTES: u64 = 256 * 1024 * 1024;
const MAX_HEADER: usize = 65536;
const MAX_STAGES: usize = 64;
const MAX_ENTRIES: usize = 4354;
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Asset {
    pub sha256: String,
    pub byte_count: u32,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Header {
    version: u8,
    operation_id: String,
    payload_hash: String,
    assets: Vec<Asset>,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Preparation {
    pub version: u8,
    pub stage_id: String,
    pub operation_id: String,
    pub payload_hash: String,
    pub assets: Vec<Asset>,
    pub total_bytes: u32,
}
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Pending<'a> {
    stage_id: &'a str,
    operation_id: &'a str,
    payload_hash: &'a str,
    asset_count: usize,
    total_bytes: u32,
}
fn hash(bytes: &[u8]) -> String {
    digest(&SHA256, bytes)
        .as_ref()
        .iter()
        .map(|v| format!("{v:02x}"))
        .collect()
}
fn key(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
fn operation(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
}
fn stage_id(operation: &str, payload: &str) -> String {
    hash(format!("thumble-asset-stage-v1\0{operation}\0{payload}").as_bytes())
}
fn validate(header: &Header) -> Result<u32, &'static str> {
    if header.version != 1
        || !operation(&header.operation_id)
        || !key(&header.payload_hash)
        || header.assets.len() > 256
    {
        return Err("asset_request_invalid");
    }
    let mut total = 0usize;
    let mut previous: Option<&str> = None;
    for asset in &header.assets {
        if !key(&asset.sha256) || previous.is_some_and(|p| p >= asset.sha256.as_str()) {
            return Err("asset_request_invalid");
        }
        total = total
            .checked_add(asset.byte_count as usize)
            .ok_or("asset_batch_too_large")?;
        if total > MAX_BYTES {
            return Err("asset_batch_too_large");
        }
        previous = Some(&asset.sha256);
    }
    Ok(total as u32)
}
fn record(header: Header) -> Result<Preparation, &'static str> {
    let total_bytes = validate(&header)?;
    Ok(Preparation {
        version: 1,
        stage_id: stage_id(&header.operation_id, &header.payload_hash),
        operation_id: header.operation_id,
        payload_hash: header.payload_hash,
        assets: header.assets,
        total_bytes,
    })
}
fn decode_record(bytes: &[u8]) -> Result<Preparation, &'static str> {
    let value: Preparation = serde_json::from_slice(bytes).map_err(|_| "asset_stage_invalid")?;
    let expected = record(Header {
        version: value.version,
        operation_id: value.operation_id.clone(),
        payload_hash: value.payload_hash.clone(),
        assets: value.assets.clone(),
    })?;
    if value != expected {
        return Err("asset_stage_invalid");
    }
    Ok(value)
}
fn exists(path: &Path) -> Result<bool, &'static str> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => Err("asset_file_unavailable"),
    }
}
fn checked(file: &File, maximum_links: u64) -> Result<(), &'static str> {
    let metadata = file.metadata().map_err(|_| "asset_file_unavailable")?;
    if !metadata.is_file() {
        return Err("asset_file_unsafe");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != unsafe { libc::geteuid() }
            || metadata.nlink() == 0
            || metadata.nlink() > maximum_links
        {
            return Err("asset_file_unsafe");
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::{fs::MetadataExt, io::AsRawHandle};
        use windows_sys::Win32::Storage::FileSystem::{
            GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
        };
        let mut information: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        if metadata.file_attributes() & 0x400 != 0
            || unsafe { GetFileInformationByHandle(file.as_raw_handle().cast(), &mut information) }
                == 0
            || information.nNumberOfLinks == 0
            || u64::from(information.nNumberOfLinks) > maximum_links
        {
            return Err("asset_file_unsafe");
        }
    }
    Ok(())
}
fn file(path: &Path, new: bool, maximum_links: u64) -> Result<File, &'static str> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if metadata.file_type().is_symlink() || !metadata.is_file() {
            return Err("asset_file_unsafe");
        }
    }
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    if new {
        options.create_new(true);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OPEN_REPARSE_POINT);
    }
    let file = options.open(path).map_err(|_| "asset_file_unavailable")?;
    checked(&file, maximum_links)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .map_err(|_| "asset_file_protection_failed")?;
    }
    #[cfg(windows)]
    crate::windows_security::protect(path, false).map_err(|_| "asset_file_protection_failed")?;
    checked(&file, maximum_links)?;
    Ok(file)
}
fn read(path: &Path, maximum: usize, links: u64) -> Result<Vec<u8>, &'static str> {
    let file = file(path, false, links)?;
    if file.metadata().map_err(|_| "asset_file_unavailable")?.len() > maximum as u64 {
        return Err("asset_file_too_large");
    }
    let mut bytes = Vec::new();
    file.take(maximum as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "asset_file_unavailable")?;
    if bytes.len() > maximum {
        return Err("asset_file_too_large");
    }
    Ok(bytes)
}
fn sync_directory(path: &Path) -> Result<(), &'static str> {
    #[cfg(unix)]
    File::open(path)
        .and_then(|f| f.sync_all())
        .map_err(|_| "asset_sync_failed")?;
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}
fn publish(root: &Path, pending: &Path, destination: &Path) -> Result<(), &'static str> {
    #[cfg(unix)]
    {
        fs::hard_link(pending, destination).map_err(|_| "asset_publish_failed")?;
        sync_directory(root)?;
        fs::remove_file(pending).map_err(|_| "asset_publish_failed")?;
        sync_directory(root)?;
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_WRITE_THROUGH};
        let from = pending
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect::<Vec<_>>();
        let to = destination
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect::<Vec<_>>();
        // No replace/copy flags: immutable publication must not clobber a name.
        if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_WRITE_THROUGH) } == 0 {
            return Err("asset_publish_failed");
        }
        let _ = root;
    }
    Ok(())
}
struct Store {
    root: PathBuf,
    _lock: File,
}
impl Store {
    fn open(runtime: &Path) -> Result<Self, &'static str> {
        // Reject marker hard links before the existing directory protector can
        // change their permissions. No marker bytes or user filenames are accepted.
        let marker = runtime.join("rewrite-runtime-v1");
        if exists(&marker)? {
            checked(
                &OpenOptions::new()
                    .read(true)
                    .open(&marker)
                    .map_err(|_| "asset_file_unsafe")?,
                1,
            )?;
        }
        security::directory(runtime)?;
        let root = runtime.join("assets-v1");
        let marker = root.join("rewrite-assets-v1");
        if exists(&marker)? {
            checked(
                &OpenOptions::new()
                    .read(true)
                    .open(&marker)
                    .map_err(|_| "asset_file_unsafe")?,
                1,
            )?;
        }
        security::asset_directory(&root)?;
        file(&marker, false, 1)?
            .sync_all()
            .map_err(|_| "asset_sync_failed")?;
        file(&runtime.join("rewrite-runtime-v1"), false, 1)?
            .sync_all()
            .map_err(|_| "asset_sync_failed")?;
        sync_directory(&root)?;
        sync_directory(runtime)?;
        if let Some(parent) = runtime.parent() {
            sync_directory(parent)?;
        }
        let lock_path = root.join("asset-store.lock");
        let lock = match file(&lock_path, true, 1) {
            Ok(f) => f,
            Err(_) if exists(&lock_path)? => file(&lock_path, false, 1)?,
            Err(e) => return Err(e),
        };
        fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "asset_owner_busy")?;
        Ok(Self { root, _lock: lock })
    }
    fn path(&self, prefix: &str, key: &str, extension: &str) -> PathBuf {
        self.root.join(format!("{prefix}-{key}.{extension}"))
    }
    fn inventory(&self) -> Result<(u64, usize, usize), &'static str> {
        let mut count = 0;
        let mut bytes = 0u64;
        let mut stages = 0;
        #[cfg(unix)]
        let mut seen_files = std::collections::BTreeSet::new();
        for item in fs::read_dir(&self.root).map_err(|_| "asset_store_unavailable")? {
            count += 1;
            if count > MAX_ENTRIES {
                return Err("asset_storage_full");
            }
            let path = item.map_err(|_| "asset_store_unavailable")?.path();
            let name = path
                .file_name()
                .and_then(|v| v.to_str())
                .ok_or("asset_store_invalid")?;
            if name == "rewrite-assets-v1" || name == "asset-store.lock" {
                continue;
            }
            let recognized = [
                ("obj-", ".bin"),
                ("tmp-", ".bin"),
                ("stage-", ".json"),
                ("journal-", ".tmp"),
            ]
            .iter()
            .any(|(prefix, suffix)| {
                name.strip_prefix(prefix)
                    .and_then(|v| v.strip_suffix(suffix))
                    .is_some_and(key)
            });
            if !recognized {
                return Err("asset_store_invalid");
            }
            let metadata = fs::symlink_metadata(&path).map_err(|_| "asset_store_unavailable")?;
            if !metadata.is_file() || metadata.file_type().is_symlink() {
                return Err("asset_file_unsafe");
            }
            let binary = name.starts_with("obj-") || name.starts_with("tmp-");
            if metadata.len()
                > if binary {
                    MAX_BYTES as u64
                } else {
                    MAX_HEADER as u64
                }
            {
                return Err("asset_file_too_large");
            }
            #[cfg(unix)]
            let count_bytes = {
                use std::os::unix::fs::MetadataExt;
                seen_files.insert((metadata.dev(), metadata.ino()))
            };
            #[cfg(not(unix))]
            let count_bytes = true;
            if count_bytes {
                bytes = bytes
                    .checked_add(metadata.len())
                    .ok_or("asset_storage_full")?;
            }
            if name.starts_with("stage-") {
                stages += 1;
            }
        }
        if bytes > MAX_STORE_BYTES || stages > MAX_STAGES {
            return Err("asset_storage_full");
        }
        Ok((bytes, stages, count))
    }
    fn restore_link(&self, pending: &Path, destination: &Path) -> Result<(), &'static str> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if exists(pending)? && exists(destination)? {
                let a = fs::symlink_metadata(pending).map_err(|_| "asset_file_unavailable")?;
                let b = fs::symlink_metadata(destination).map_err(|_| "asset_file_unavailable")?;
                if a.is_file()
                    && !a.file_type().is_symlink()
                    && b.is_file()
                    && !b.file_type().is_symlink()
                    && a.dev() == b.dev()
                    && a.ino() == b.ino()
                    && a.nlink() == 2
                    && b.nlink() == 2
                {
                    checked(&file(destination, false, 2)?, 2)?;
                    fs::remove_file(pending).map_err(|_| "asset_publish_failed")?;
                    sync_directory(&self.root)?;
                }
            }
        }
        #[cfg(not(unix))]
        let _ = (pending, destination);
        Ok(())
    }
    fn install(&self, asset: &Asset, bytes: &[u8]) -> Result<(), &'static str> {
        let destination = self.path("obj", &asset.sha256, "bin");
        let pending = self.path("tmp", &asset.sha256, "bin");
        self.restore_link(&pending, &destination)?;
        if exists(&destination)? {
            let existing = read(&destination, MAX_BYTES, 1)?;
            if existing.len() != asset.byte_count as usize || hash(&existing) != asset.sha256 {
                return Err("asset_integrity_failed");
            }
            return Ok(());
        }
        if exists(&pending)? {
            // Only an unreferenced, private temporary object may be discarded.
            file(&pending, false, 1)?;
            fs::remove_file(&pending).map_err(|_| "asset_publish_failed")?;
        }
        let mut output = file(&pending, true, 1)?;
        output
            .write_all(bytes)
            .and_then(|_| output.sync_all())
            .map_err(|_| "asset_write_failed")?;
        drop(output);
        sync_directory(&self.root)?;
        publish(&self.root, &pending, &destination)
    }
    fn stages(&self) -> Result<Vec<Preparation>, &'static str> {
        self.inventory()?;
        let mut stages = Vec::new();
        for item in fs::read_dir(&self.root).map_err(|_| "asset_store_unavailable")? {
            let path = item.map_err(|_| "asset_store_unavailable")?.path();
            let Some(id) = path
                .file_name()
                .and_then(|v| v.to_str())
                .and_then(|v| v.strip_prefix("stage-"))
                .and_then(|v| v.strip_suffix(".json"))
            else {
                continue;
            };
            let pending = self.path("journal", id, "tmp");
            self.restore_link(&pending, &path)?;
            let value = decode_record(&read(&path, MAX_HEADER, 1)?)?;
            if value.stage_id != id {
                return Err("asset_stage_invalid");
            }
            stages.push(value);
        }
        stages.sort_by(|a, b| a.stage_id.cmp(&b.stage_id));
        Ok(stages)
    }
}
pub fn run(args: &[String]) -> Result<(), &'static str> {
    let mode = args.first().ok_or("asset_request_invalid")?.as_str();
    let expected = if matches!(mode, "assets-prepare" | "assets-pending") {
        2
    } else {
        3
    };
    if args.len() != expected {
        return Err("asset_request_invalid");
    }
    let runtime = Path::new(&args[1]);
    if mode == "assets-prepare" {
        let mut bytes = Vec::new();
        std::io::stdin()
            .take((MAX_BYTES + MAX_HEADER + 5) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| "asset_request_invalid")?;
        if bytes.len() < 4 || bytes.len() > MAX_BYTES + MAX_HEADER + 4 {
            return Err("asset_batch_too_large");
        }
        let size = u32::from_be_bytes(bytes[..4].try_into().unwrap()) as usize;
        if size == 0 || size > MAX_HEADER || size > bytes.len() - 4 {
            return Err("asset_request_invalid");
        }
        let header: Header =
            serde_json::from_slice(&bytes[4..4 + size]).map_err(|_| "asset_request_invalid")?;
        let value = record(header)?;
        if bytes.len() - 4 - size != value.total_bytes as usize {
            return Err("asset_request_invalid");
        }
        let mut offset = 4 + size;
        for asset in &value.assets {
            let end = offset + asset.byte_count as usize;
            if hash(&bytes[offset..end]) != asset.sha256 {
                return Err("asset_integrity_failed");
            }
            offset = end;
        }
        let store = Store::open(runtime)?;
        let (used, stages, entries) = store.inventory()?;
        let destination = store.path("stage", &value.stage_id, "json");
        let pending = store.path("journal", &value.stage_id, "tmp");
        store.restore_link(&pending, &destination)?;
        let mut additional = 0u64;
        let mut new_objects = 0usize;
        for asset in &value.assets {
            if !exists(&store.path("obj", &asset.sha256, "bin"))? {
                additional += u64::from(asset.byte_count);
                new_objects += 1;
            }
        }
        let encoded = serde_json::to_vec(&value).map_err(|_| "asset_stage_invalid")?;
        let new_stage = !exists(&destination)?;
        if new_stage {
            additional += encoded.len() as u64;
        }
        // Reserve final names plus one transient publication name. The lease
        // prevents another helper from consuming this bounded inventory.
        let extra_entries =
            new_objects + usize::from(new_stage) + usize::from(new_objects > 0 || new_stage);
        if used + additional > MAX_STORE_BYTES || entries + extra_entries > MAX_ENTRIES {
            return Err("asset_storage_full");
        }
        if exists(&destination)? {
            if decode_record(&read(&destination, MAX_HEADER, 1)?)? != value {
                return Err("asset_stage_conflict");
            }
        } else {
            if stages >= MAX_STAGES {
                return Err("asset_storage_full");
            }
            if exists(&pending)? {
                file(&pending, false, 1)?;
                fs::remove_file(&pending).map_err(|_| "asset_publish_failed")?;
            }
            let mut output = file(&pending, true, 1)?;
            output
                .write_all(&encoded)
                .and_then(|_| output.sync_all())
                .map_err(|_| "asset_write_failed")?;
            drop(output);
            sync_directory(&store.root)?;
            publish(&store.root, &pending, &destination)?;
        }
        let mut offset = 4 + size;
        for asset in &value.assets {
            let end = offset + asset.byte_count as usize;
            store.install(asset, &bytes[offset..end])?;
            offset = end;
        }
        println!(
            "{}",
            serde_json::to_string(&value).map_err(|_| "asset_stage_invalid")?
        );
        return Ok(());
    }
    if !matches!(
        mode,
        "assets-read" | "assets-pending" | "assets-manifest" | "assets-retire"
    ) {
        return Err("asset_request_invalid");
    }
    if expected == 3 && !key(&args[2]) {
        return Err("asset_request_invalid");
    }
    let store = Store::open(runtime)?;
    if mode == "assets-pending" {
        let records = store.stages()?;
        let pending = records
            .iter()
            .map(|v| Pending {
                stage_id: &v.stage_id,
                operation_id: &v.operation_id,
                payload_hash: &v.payload_hash,
                asset_count: v.assets.len(),
                total_bytes: v.total_bytes,
            })
            .collect::<Vec<_>>();
        println!(
            "{}",
            serde_json::to_string(&pending).map_err(|_| "asset_stage_invalid")?
        );
        return Ok(());
    }
    let id = &args[2];
    if mode == "assets-read" {
        store.inventory()?;
        let bytes = read(&store.path("obj", id, "bin"), MAX_BYTES, 1)?;
        if hash(&bytes) != *id {
            return Err("asset_integrity_failed");
        }
        std::io::stdout()
            .write_all(&bytes)
            .map_err(|_| "asset_output_failed")?;
        return Ok(());
    }
    let destination = store.path("stage", id, "json");
    store.restore_link(&store.path("journal", id, "tmp"), &destination)?;
    if mode == "assets-retire" && !exists(&destination)? {
        return Ok(());
    }
    let value = decode_record(&read(&destination, MAX_HEADER, 1)?)?;
    if value.stage_id != *id {
        return Err("asset_stage_invalid");
    }
    if mode == "assets-retire" {
        fs::remove_file(destination).map_err(|_| "asset_cleanup_failed")?;
        sync_directory(&store.root)?;
        return Ok(());
    }
    for asset in &value.assets {
        let bytes = read(&store.path("obj", &asset.sha256, "bin"), MAX_BYTES, 1)?;
        if bytes.len() != asset.byte_count as usize || hash(&bytes) != asset.sha256 {
            return Err("asset_integrity_failed");
        }
    }
    println!(
        "{}",
        serde_json::to_string(&value).map_err(|_| "asset_stage_invalid")?
    );
    Ok(())
}
