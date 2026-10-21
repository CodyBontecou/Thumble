//! Restrict receiver records and the control credential to the owning user and
//! SYSTEM. Never accept a reparse point or a directory owned by another user.
use std::{os::windows::ffi::OsStrExt, path::Path, ptr};
use windows_sys::Win32::{
    Foundation::{CloseHandle, LocalFree},
    Security::{Authorization::*, *},
    System::Threading::{GetCurrentProcess, OpenProcessToken},
};
fn error() -> String {
    format!(
        "Protect Windows receiver state: {}",
        std::io::Error::last_os_error()
    )
}

pub fn protect(path: &Path, directory: bool) -> Result<(), String> {
    use std::os::windows::fs::MetadataExt;
    if std::fs::symlink_metadata(path)
        .map_err(|e| e.to_string())?
        .file_attributes()
        & 0x400
        != 0
    {
        return Err("Reparse points are not permitted in receiver state".into());
    }
    let wide = path
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    // SAFETY: Windows outputs have owned backing storage below, all returned
    // handles/descriptors are released, and SID pointers live with that storage.
    unsafe {
        let mut token = ptr::null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return Err(error());
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
            return Err(error());
        }
        let sid = (*(storage.as_ptr().cast::<TOKEN_USER>())).User.Sid;
        let mut owner = ptr::null_mut();
        let mut descriptor = ptr::null_mut();
        let status = GetNamedSecurityInfoW(
            wide.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION,
            &mut owner,
            ptr::null_mut(),
            ptr::null_mut(),
            ptr::null_mut(),
            &mut descriptor,
        );
        if status != 0 {
            return Err(format!("Read Windows state owner: {status}"));
        }
        // Elevated Windows tokens can default new filesystem ownership to the
        // token's owner group. Normalize that owner to the actual user SID too.
        let default_owner = (*(owner_storage.as_ptr().cast::<TOKEN_OWNER>())).Owner;
        let owned = EqualSid(owner, sid) != 0 || EqualSid(owner, default_owner) != 0;
        LocalFree(descriptor);
        if !owned {
            return Err("Receiver state must be owned by the current user".into());
        }
        let mut sid_text = ptr::null_mut();
        if ConvertSidToStringSidW(sid, &mut sid_text) == 0 {
            return Err(error());
        }
        let mut count = 0;
        while *sid_text.add(count) != 0 {
            count += 1;
        }
        let sid_string = String::from_utf16_lossy(std::slice::from_raw_parts(sid_text, count));
        LocalFree(sid_text.cast());
        let inherit = if directory { "OICI" } else { "" };
        let sddl = format!("D:P(A;{inherit};FA;;;{sid_string})(A;{inherit};FA;;;SY)")
            .encode_utf16()
            .chain(Some(0))
            .collect::<Vec<_>>();
        let mut descriptor = ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        ) == 0
        {
            return Err(error());
        }
        let mut present = 0;
        let mut defaulted = 0;
        let mut dacl = ptr::null_mut();
        if GetSecurityDescriptorDacl(descriptor, &mut present, &mut dacl, &mut defaulted) == 0
            || present == 0
            || dacl.is_null()
        {
            LocalFree(descriptor);
            return Err(error());
        }
        let result = SetNamedSecurityInfoW(
            wide.as_ptr(),
            SE_FILE_OBJECT,
            OWNER_SECURITY_INFORMATION
                | DACL_SECURITY_INFORMATION
                | PROTECTED_DACL_SECURITY_INFORMATION,
            sid,
            ptr::null_mut(),
            dacl,
            ptr::null(),
        );
        LocalFree(descriptor);
        if result != 0 {
            return Err(format!("Restrict Windows state ACL: {result}"));
        }
    }
    Ok(())
}
