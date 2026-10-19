//! Private acceptance harness, never an installed receiver entry point. A scoped
//! bookmark belongs to its creating code identity, so create it in this runtime
//! process and exercise the production runtime through normal Android messages.
#[cfg(target_os = "macos")]
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    use base64::Engine;
    use objc2_core_foundation::{CFString, CFURLBookmarkCreationOptions, CFURLPathStyle, CFURL};
    use thumble_host::{
        paths::HostPaths,
        runtime::{run_runtime, RuntimeOptions},
        storage,
    };
    // Require explicit private paths; never fall back to the user's normal state.
    std::env::var("THUMBLE_HOST_STATE_DIR")?;
    std::env::var("THUMBLE_HOST_CONTROL_SOCKET")?;
    let application = std::env::var("THUMBLE_TEST_APPLICATION")?;
    let paths = HostPaths::discover()?;
    let mut state = storage::load(&paths.state_file)?;
    let path = CFString::from_str(&application);
    let url =
        CFURL::with_file_system_path(None, Some(&path), CFURLPathStyle::CFURLPOSIXPathStyle, true)
            .ok_or("invalid fixture URL")?;
    let mut error = std::ptr::null_mut();
    // SAFETY: Default allocator, retained file URL, no relative URL/properties,
    // and writable error output follow the CoreFoundation contract.
    let data = unsafe {
        CFURL::new_bookmark_data(
            None,
            Some(&url),
            CFURLBookmarkCreationOptions::WithSecurityScope,
            None,
            None,
            &mut error,
        )
    }
    .ok_or("fixture bookmark creation failed")?;
    if !error.is_null() {
        return Err("fixture bookmark creation failed".into());
    }
    let id = state.active_profile_id.clone();
    state.profile_mut(&id).ok_or("missing fixture profile")?["launchTarget"]["bookmarkData"] =
        serde_json::Value::String(base64::engine::general_purpose::STANDARD.encode(data.to_vec()));
    storage::save_atomic(&paths.state_file, &state)?;
    run_runtime(
        paths,
        RuntimeOptions {
            port: 0,
            bonjour: false,
            input: false,
            configuration_write: false,
        },
    )
    .await?;
    Ok(())
}
#[cfg(not(target_os = "macos"))]
fn main() {
    panic!("Application launch acceptance requires macOS");
}
