#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::Path,
};

pub fn directory(path: &Path) -> Result<(), &'static str> {
    if !path.is_absolute() {
        return Err("runtime_directory_must_be_absolute");
    }
    // Refuse reparse/symlink components before creating or protecting storage.
    for component in path.ancestors() {
        if let Ok(metadata) = fs::symlink_metadata(component) {
            if metadata.file_type().is_symlink() {
                return Err("unsafe_runtime_directory");
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err("unsafe_runtime_directory");
                }
            }
        }
    }
    if !path.exists() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            fs::DirBuilder::new()
                .mode(0o700)
                .create(path)
                .map_err(|_| "runtime_directory_create_failed")?;
        }
        #[cfg(not(unix))]
        fs::create_dir(path).map_err(|_| "runtime_directory_create_failed")?;
    }
    let metadata = fs::symlink_metadata(path).map_err(|_| "runtime_directory_unavailable")?;
    if !metadata.is_dir() {
        return Err("unsafe_runtime_directory");
    }
    let marker = path.join("rewrite-runtime-v1");
    if !marker.exists()
        && fs::read_dir(path)
            .map_err(|_| "runtime_directory_unavailable")?
            .next()
            .is_some()
    {
        return Err("runtime_directory_not_isolated");
    }
    #[cfg(unix)]
    {
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err("runtime_directory_not_owned");
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))
            .map_err(|_| "runtime_directory_permissions_failed")?;
    }
    #[cfg(windows)]
    crate::windows_security::protect(path, true)
        .map_err(|_| "runtime_directory_permissions_failed")?;
    const MARKER: &[u8] = b"thumble-rewrite-runtime-v1\n";
    if !marker.exists() {
        if let Ok(mut created) = file(&marker, true) {
            created
                .write_all(MARKER)
                .map_err(|_| "runtime_marker_failed")?;
        }
    }
    let mut bytes = Vec::new();
    file(&marker, false)?
        .take(128)
        .read_to_end(&mut bytes)
        .map_err(|_| "runtime_marker_failed")?;
    if bytes != MARKER {
        return Err("runtime_marker_invalid");
    }
    Ok(())
}
pub fn file(path: &Path, exclusive: bool) -> Result<File, &'static str> {
    if let Ok(metadata) = fs::symlink_metadata(path) {
        if !metadata.is_file() || metadata.file_type().is_symlink() {
            return Err("unsafe_runtime_file");
        }
        #[cfg(unix)]
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err("runtime_file_not_owned");
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if metadata.file_attributes() & 0x400 != 0 {
                return Err("unsafe_runtime_file");
            }
        }
    }
    let mut options = OpenOptions::new();
    options.write(true).read(true);
    if exclusive {
        options.create_new(true);
    } else {
        options.create(true);
    }
    #[cfg(unix)]
    {
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let file = options.open(path).map_err(|_| "runtime_file_open_failed")?;
    #[cfg(unix)]
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|_| "runtime_file_permissions_failed")?;
    #[cfg(windows)]
    crate::windows_security::protect(path, false).map_err(|_| "runtime_file_permissions_failed")?;
    Ok(file)
}
