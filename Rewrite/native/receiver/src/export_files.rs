//! Explicit local saved-configuration publication. No path is an authority or
//! input grant. Files are never replaced; retries require byte-for-byte equality.
use ring::{
    digest::{digest, SHA256},
    rand::{SecureRandom, SystemRandom},
};
use serde::Serialize;
#[cfg(windows)]
use std::fs;
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    path::{Component, Path},
};
const MAX_BYTES: usize = 8 * 1024 * 1024;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Publication {
    version: u8,
    artifact_hash: String,
    byte_count: usize,
    replayed: bool,
}
fn hash(bytes: &[u8]) -> String {
    digest(&SHA256, bytes)
        .as_ref()
        .iter()
        .map(|v| format!("{v:02x}"))
        .collect()
}
fn checked(file: &File) -> Result<(), &'static str> {
    let metadata = file
        .metadata()
        .map_err(|_| "configuration_export_file_unavailable")?;
    if !metadata.is_file() {
        return Err("configuration_export_file_unsafe");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        if metadata.uid() != unsafe { libc::geteuid() } || metadata.nlink() != 1 {
            return Err("configuration_export_file_unsafe");
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::io::AsRawHandle;
        use windows_sys::Win32::Storage::FileSystem::{
            GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION,
        };
        let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
        if unsafe { GetFileInformationByHandle(file.as_raw_handle().cast(), &mut info) } == 0
            || info.dwFileAttributes & 0x400 != 0
            || info.nNumberOfLinks != 1
        {
            return Err("configuration_export_file_unsafe");
        }
        windows_owned(file)?;
    }
    Ok(())
}
#[cfg(windows)]
fn windows_owned(file: &File) -> Result<(), &'static str> {
    use std::{os::windows::io::AsRawHandle, ptr};
    use windows_sys::Win32::{
        Foundation::{CloseHandle, LocalFree},
        Security::{Authorization::*, *},
        System::Threading::{GetCurrentProcess, OpenProcessToken},
    };
    unsafe {
        let mut token = ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err("configuration_export_file_unsafe");
        }
        let mut length = 0;
        GetTokenInformation(token, TokenUser, ptr::null_mut(), 0, &mut length);
        let mut storage = vec![0u64; (length as usize).div_ceil(8)];
        let result = GetTokenInformation(
            token,
            TokenUser,
            storage.as_mut_ptr().cast(),
            length,
            &mut length,
        );
        let mut owner_length = 0;
        GetTokenInformation(token, TokenOwner, ptr::null_mut(), 0, &mut owner_length);
        let mut owner_storage = vec![0u64; (owner_length as usize).div_ceil(8)];
        let owner_result = GetTokenInformation(
            token,
            TokenOwner,
            owner_storage.as_mut_ptr().cast(),
            owner_length,
            &mut owner_length,
        );
        CloseHandle(token);
        if result == 0 || owner_result == 0 {
            return Err("configuration_export_file_unsafe");
        }
        let user = (*(storage.as_ptr().cast::<TOKEN_USER>())).User.Sid;
        let default_owner = (*(owner_storage.as_ptr().cast::<TOKEN_OWNER>())).Owner;
        let mut owner = ptr::null_mut();
        let mut descriptor = ptr::null_mut();
        if GetSecurityInfo(
            file.as_raw_handle().cast(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            &mut owner,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            &mut descriptor,
        ) != 0
        {
            return Err("configuration_export_file_unsafe");
        }
        let owned = EqualSid(owner, user) != 0 || EqualSid(owner, default_owner) != 0;
        LocalFree(descriptor);
        if !owned {
            return Err("configuration_export_file_unsafe");
        }
    }
    Ok(())
}
struct Directory {
    #[cfg(windows)]
    path: std::path::PathBuf,
    #[cfg_attr(windows, allow(dead_code))]
    handle: File,
    #[cfg(windows)]
    _ancestors: Vec<File>,
}
impl Directory {
    fn open(path: &Path) -> Result<Self, &'static str> {
        if !path.is_absolute()
            || path
                .components()
                .any(|c| matches!(c, Component::ParentDir | Component::CurDir))
        {
            return Err("configuration_export_path_invalid");
        }
        #[cfg(windows)]
        let mut ancestors = Vec::new();
        #[cfg(windows)]
        for parent in path.ancestors() {
            let metadata = fs::symlink_metadata(parent)
                .map_err(|_| "configuration_export_directory_unavailable")?;
            if !metadata.is_dir() || metadata.file_type().is_symlink() {
                return Err("configuration_export_directory_unsafe");
            }
            #[cfg(windows)]
            {
                use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
                use windows_sys::Win32::Storage::FileSystem::{
                    FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
                    FILE_SHARE_WRITE,
                };
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err("configuration_export_directory_unsafe");
                }
                // Hold every component without delete-sharing, preventing directory
                // rename/junction substitution while paths are used below.
                let directory = OpenOptions::new()
                    .read(true)
                    .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
                    .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
                    .open(parent)
                    .map_err(|_| "configuration_export_directory_unavailable")?;
                if directory
                    .metadata()
                    .map_err(|_| "configuration_export_directory_unavailable")?
                    .file_attributes()
                    & 0x400
                    != 0
                {
                    return Err("configuration_export_directory_unsafe");
                }
                ancestors.push(directory);
            }
        }
        #[cfg(unix)]
        let handle = {
            use std::{
                ffi::CString,
                os::{
                    fd::{AsRawFd, FromRawFd},
                    unix::{
                        ffi::OsStrExt,
                        fs::{MetadataExt, OpenOptionsExt},
                    },
                },
            };
            // Pin each ancestor before resolving its child. A preflight lstat
            // followed by open(path) could follow a replaced intermediate name.
            let mut handle = OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_DIRECTORY | libc::O_CLOEXEC)
                .open("/")
                .map_err(|_| "configuration_export_directory_unavailable")?;
            for component in path.components() {
                let name = match component {
                    Component::RootDir => continue,
                    Component::Normal(name) => name,
                    _ => return Err("configuration_export_path_invalid"),
                };
                let name = CString::new(name.as_bytes())
                    .map_err(|_| "configuration_export_path_invalid")?;
                let fd = unsafe {
                    libc::openat(
                        handle.as_raw_fd(),
                        name.as_ptr(),
                        libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                    )
                };
                if fd < 0 {
                    let error = std::io::Error::last_os_error();
                    return Err(
                        if matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) {
                            "configuration_export_directory_unsafe"
                        } else {
                            "configuration_export_directory_unavailable"
                        },
                    );
                }
                // SAFETY: openat returned a new owned descriptor; replacing the
                // previous handle cannot redirect any already-resolved ancestor.
                handle = unsafe { File::from_raw_fd(fd) };
            }
            let metadata = handle
                .metadata()
                .map_err(|_| "configuration_export_directory_unavailable")?;
            if metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o022 != 0 {
                return Err("configuration_export_directory_unsafe");
            }
            handle
        };
        #[cfg(windows)]
        windows_owned(&ancestors[0]).map_err(|_| "configuration_export_directory_unsafe")?;
        #[cfg(windows)]
        let handle = ancestors[0]
            .try_clone()
            .map_err(|_| "configuration_export_directory_unavailable")?;
        Ok(Self {
            #[cfg(windows)]
            path: path.to_path_buf(),
            handle,
            #[cfg(windows)]
            _ancestors: ancestors,
        })
    }
    fn file(&self, name: &str, new: bool) -> Result<File, std::io::Error> {
        #[cfg(unix)]
        {
            use std::{
                ffi::CString,
                os::fd::{AsRawFd, FromRawFd},
            };
            let name = CString::new(name)
                .map_err(|_| std::io::Error::from(std::io::ErrorKind::InvalidInput))?;
            let flags = libc::O_NOFOLLOW
                | libc::O_CLOEXEC
                | libc::O_NONBLOCK
                | if new {
                    libc::O_RDWR | libc::O_CREAT | libc::O_EXCL
                } else {
                    libc::O_RDONLY
                };
            let fd = unsafe { libc::openat(self.handle.as_raw_fd(), name.as_ptr(), flags, 0o600) };
            if fd < 0 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(unsafe { File::from_raw_fd(fd) })
            }
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            use windows_sys::Win32::Storage::FileSystem::{
                FILE_FLAG_OPEN_REPARSE_POINT, FILE_SHARE_READ,
            };
            let mut options = OpenOptions::new();
            options
                .read(true)
                .write(new)
                .create_new(new)
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
                .share_mode(FILE_SHARE_READ);
            options.open(self.path.join(name))
        }
    }
    fn remove(&self, name: &str) {
        #[cfg(unix)]
        {
            use std::{ffi::CString, os::fd::AsRawFd};
            if let Ok(name) = CString::new(name) {
                unsafe { libc::unlinkat(self.handle.as_raw_fd(), name.as_ptr(), 0) };
            }
        }
        #[cfg(windows)]
        let _ = fs::remove_file(self.path.join(name));
    }
    fn publish(&self, pending: &str, destination: &str) -> Result<(), std::io::Error> {
        #[cfg(unix)]
        {
            use std::{ffi::CString, os::fd::AsRawFd};
            let from = CString::new(pending).unwrap();
            let to = CString::new(destination).unwrap();
            // Exclusive rename keeps the final inode single-linked even if the
            // helper dies immediately after publication. Ordinary rename would
            // replace a competing destination and is never a fallback.
            #[cfg(target_os = "macos")]
            let renamed = unsafe {
                libc::renameatx_np(
                    self.handle.as_raw_fd(),
                    from.as_ptr(),
                    self.handle.as_raw_fd(),
                    to.as_ptr(),
                    libc::RENAME_EXCL,
                )
            };
            #[cfg(target_os = "linux")]
            let renamed = unsafe {
                libc::renameat2(
                    self.handle.as_raw_fd(),
                    from.as_ptr(),
                    self.handle.as_raw_fd(),
                    to.as_ptr(),
                    libc::RENAME_NOREPLACE,
                )
            };
            #[cfg(not(any(target_os = "macos", target_os = "linux")))]
            return Err(std::io::Error::from(std::io::ErrorKind::Unsupported));
            #[cfg(any(target_os = "macos", target_os = "linux"))]
            if renamed != 0 {
                return Err(std::io::Error::last_os_error());
            }
            self.handle.sync_all()
        }
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt;
            use windows_sys::Win32::Storage::FileSystem::{MoveFileExW, MOVEFILE_WRITE_THROUGH};
            let from = self
                .path
                .join(pending)
                .as_os_str()
                .encode_wide()
                .chain(Some(0))
                .collect::<Vec<_>>();
            let to = self
                .path
                .join(destination)
                .as_os_str()
                .encode_wide()
                .chain(Some(0))
                .collect::<Vec<_>>();
            if unsafe { MoveFileExW(from.as_ptr(), to.as_ptr(), MOVEFILE_WRITE_THROUGH) } == 0 {
                Err(std::io::Error::last_os_error())
            } else {
                Ok(())
            }
        }
    }
    fn existing(&self, name: &str, expected: &[u8]) -> Result<bool, &'static str> {
        let file = match self.file(name, false) {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(false),
            Err(_) => return Err("configuration_export_file_unsafe"),
        };
        checked(&file)?;
        let before = file
            .metadata()
            .map_err(|_| "configuration_export_file_unavailable")?;
        if before.len() != expected.len() as u64 {
            return Err("configuration_export_exists");
        }
        let mut bytes = Vec::new();
        (&file)
            .take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| "configuration_export_file_unavailable")?;
        let after = file
            .metadata()
            .map_err(|_| "configuration_export_file_unavailable")?;
        checked(&file)?;
        if before.len() != after.len()
            || before.modified().ok() != after.modified().ok()
            || bytes != expected
        {
            return Err("configuration_export_exists");
        }
        #[cfg(unix)]
        self.handle
            .sync_all()
            .map_err(|_| "configuration_export_sync_failed")?;
        Ok(true)
    }
}
pub fn publish(path: &Path, bytes: &[u8]) -> Result<Publication, &'static str> {
    if bytes.is_empty() || bytes.len() > MAX_BYTES || std::str::from_utf8(bytes).is_err() {
        return Err("configuration_export_input_invalid");
    }
    let name = path
        .file_name()
        .and_then(|v| v.to_str())
        .filter(|v| !v.is_empty() && !v.starts_with(".thumble-export-"))
        .ok_or("configuration_export_path_invalid")?;
    #[cfg(windows)]
    if name.contains(':')
        || name.ends_with(['.', ' '])
        || name.split('.').next().is_some_and(|v| {
            let v = v.to_ascii_uppercase();
            matches!(v.as_str(), "CON" | "PRN" | "AUX" | "NUL")
                || (v.len() == 4
                    && (v.starts_with("COM") || v.starts_with("LPT"))
                    && v.as_bytes()[3].is_ascii_digit())
        })
    {
        return Err("configuration_export_path_invalid");
    }
    let parent = Directory::open(path.parent().ok_or("configuration_export_path_invalid")?)?;
    let result = |replayed| Publication {
        version: 1,
        artifact_hash: hash(bytes),
        byte_count: bytes.len(),
        replayed,
    };
    if parent.existing(name, bytes)? {
        return Ok(result(true));
    }
    let mut random = [0u8; 16];
    SystemRandom::new()
        .fill(&mut random)
        .map_err(|_| "configuration_export_random_failed")?;
    let pending = format!(".thumble-export-{}", hash(&random));
    let mut file = parent
        .file(&pending, true)
        .map_err(|_| "configuration_export_create_failed")?;
    let write = (|| {
        checked(&file)?;
        #[cfg(windows)]
        crate::windows_security::protect(&parent.path.join(&pending), false)
            .map_err(|_| "configuration_export_protection_failed")?;
        file.write_all(bytes)
            .and_then(|_| file.sync_all())
            .map_err(|_| "configuration_export_write_failed")
    })();
    drop(file);
    if let Err(error) = write {
        parent.remove(&pending);
        return Err(error);
    }
    match parent.publish(&pending, name) {
        Ok(()) => Ok(result(false)),
        Err(_) => {
            // A competing successful writer may have won. Exact equality is the
            // only replay proof; neither that file nor any other file is changed.
            parent.remove(&pending);
            if parent.existing(name, bytes)? {
                Ok(result(true))
            } else {
                Err("configuration_export_publish_failed")
            }
        }
    }
}
pub fn run(args: &[String]) -> Result<(), &'static str> {
    if args.len() != 2 {
        return Err("configuration_export_arguments_invalid");
    }
    let mut bytes = Vec::new();
    std::io::stdin()
        .take(MAX_BYTES as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "configuration_export_input_invalid")?;
    let result = publish(Path::new(&args[1]), &bytes)?;
    println!(
        "{}",
        serde_json::to_string(&result).map_err(|_| "configuration_export_response_invalid")?
    );
    Ok(())
}
