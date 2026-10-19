use objc2_application_services::{
    kAXTrustedCheckOptionPrompt, AXIsProcessTrusted, AXIsProcessTrustedWithOptions,
};
use objc2_core_foundation::{CFBoolean, CFDictionary, CGPoint, CGRect};
use objc2_core_graphics::{
    CGDisplayBounds, CGEvent, CGEventField, CGEventFlags, CGEventSource, CGEventSourceStateID,
    CGEventTapLocation, CGEventType, CGGetActiveDisplayList, CGMouseButton, CGScrollEventUnit,
};
use std::collections::BTreeSet;
use std::process::{Command, Stdio};
use thumble_core::KeyStroke;
use thumble_protocol::ControllerPointerButton;

pub fn accessibility_trusted() -> bool {
    // SAFETY: This function takes no pointers and has no prompting side effects.
    unsafe { AXIsProcessTrusted() }
}

pub fn prompt_accessibility() -> bool {
    // SAFETY: kAXTrustedCheckOptionPrompt is a framework-owned immortal CFString.
    let key = unsafe { kAXTrustedCheckOptionPrompt };
    let value = CFBoolean::new(true);
    let options = CFDictionary::from_slices(&[key], &[value]);
    // SAFETY: The dictionary contains the documented CFString/CFBoolean pair.
    unsafe { AXIsProcessTrustedWithOptions(Some(options.as_ref())) }
}

pub fn open_accessibility_settings() -> Result<(), String> {
    Command::new("/usr/bin/open")
        .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map(|_| ())
        .map_err(|error| format!("open Accessibility settings: {error}"))
}

pub fn key_event(stroke: &KeyStroke, key_down: bool) -> Result<(), String> {
    if !accessibility_trusted() {
        return Err("Accessibility permission is not granted".to_owned());
    }
    let source = event_source()?;
    let event = CGEvent::new_keyboard_event(Some(&source), stroke.key_code, key_down)
        .ok_or_else(|| "create keyboard event".to_owned())?;
    CGEvent::set_flags(Some(&event), event_flags(stroke, key_down));
    CGEvent::post(CGEventTapLocation::HIDEventTap, Some(&event));
    Ok(())
}

pub fn pointer_move(
    delta_x: f64,
    delta_y: f64,
    held_buttons: &BTreeSet<String>,
) -> Result<(), String> {
    if !accessibility_trusted() || (delta_x.abs() < 0.01 && delta_y.abs() < 0.01) {
        return Ok(());
    }
    let source = event_source()?;
    let current = CGEvent::new(Some(&source))
        .map(|event| CGEvent::location(Some(&event)))
        .unwrap_or(CGPoint::ZERO);
    let target = clamp_to_displays(CGPoint::new(current.x + delta_x, current.y + delta_y));
    let (event_type, button) = if held_buttons.contains("left") {
        (CGEventType::LeftMouseDragged, CGMouseButton::Left)
    } else if held_buttons.contains("right") {
        (CGEventType::RightMouseDragged, CGMouseButton::Right)
    } else if held_buttons.contains("middle") {
        (CGEventType::OtherMouseDragged, CGMouseButton::Center)
    } else {
        (CGEventType::MouseMoved, CGMouseButton::Left)
    };
    let event = CGEvent::new_mouse_event(Some(&source), event_type, target, button)
        .ok_or_else(|| "create pointer movement event".to_owned())?;
    if button == CGMouseButton::Center {
        CGEvent::set_integer_value_field(Some(&event), CGEventField::MouseEventButtonNumber, 2);
    }
    CGEvent::post(CGEventTapLocation::HIDEventTap, Some(&event));
    Ok(())
}

pub fn pointer_scroll(delta_x: f64, delta_y: f64) -> Result<(), String> {
    if !accessibility_trusted() || (delta_x.abs() < 0.01 && delta_y.abs() < 0.01) {
        return Ok(());
    }
    let vertical = wheel_delta(-delta_y);
    let horizontal = wheel_delta(-delta_x);
    if vertical == 0 && horizontal == 0 {
        return Ok(());
    }
    let source = event_source()?;
    let event = CGEvent::new_scroll_wheel_event2(
        Some(&source),
        CGScrollEventUnit::Pixel,
        2,
        vertical,
        horizontal,
        0,
    )
    .ok_or_else(|| "create pointer scroll event".to_owned())?;
    CGEvent::post(CGEventTapLocation::HIDEventTap, Some(&event));
    Ok(())
}

pub fn pointer_button(button: ControllerPointerButton, pressed: bool) -> Result<(), String> {
    if !accessibility_trusted() {
        return Err("Accessibility permission is not granted".to_owned());
    }
    let source = event_source()?;
    let current = CGEvent::new(Some(&source))
        .map(|event| CGEvent::location(Some(&event)))
        .unwrap_or(CGPoint::ZERO);
    let (event_type, mouse_button) = match (button, pressed) {
        (ControllerPointerButton::Left, true) => (CGEventType::LeftMouseDown, CGMouseButton::Left),
        (ControllerPointerButton::Left, false) => (CGEventType::LeftMouseUp, CGMouseButton::Left),
        (ControllerPointerButton::Right, true) => {
            (CGEventType::RightMouseDown, CGMouseButton::Right)
        }
        (ControllerPointerButton::Right, false) => {
            (CGEventType::RightMouseUp, CGMouseButton::Right)
        }
        (ControllerPointerButton::Middle, true) => {
            (CGEventType::OtherMouseDown, CGMouseButton::Center)
        }
        (ControllerPointerButton::Middle, false) => {
            (CGEventType::OtherMouseUp, CGMouseButton::Center)
        }
    };
    let event = CGEvent::new_mouse_event(Some(&source), event_type, current, mouse_button)
        .ok_or_else(|| "create pointer button event".to_owned())?;
    if button == ControllerPointerButton::Middle {
        CGEvent::set_integer_value_field(Some(&event), CGEventField::MouseEventButtonNumber, 2);
    }
    CGEvent::post(CGEventTapLocation::HIDEventTap, Some(&event));
    Ok(())
}

fn event_source() -> Result<objc2_core_foundation::CFRetained<CGEventSource>, String> {
    CGEventSource::new(CGEventSourceStateID::HIDSystemState)
        .ok_or_else(|| "create HID event source".to_owned())
}

fn event_flags(stroke: &KeyStroke, key_down: bool) -> CGEventFlags {
    let mut flags = CGEventFlags::empty();
    if stroke.modifiers & 1 != 0 {
        flags.insert(CGEventFlags::MaskCommand);
    }
    if stroke.modifiers & 2 != 0 {
        flags.insert(CGEventFlags::MaskShift);
    }
    if stroke.modifiers & 4 != 0 {
        flags.insert(CGEventFlags::MaskAlternate);
    }
    if stroke.modifiers & 8 != 0 {
        flags.insert(CGEventFlags::MaskControl);
    }
    if key_down {
        if let Some(flag) = modifier_key_flag(stroke.key_code) {
            flags.insert(flag);
        }
    }
    flags
}

fn modifier_key_flag(key_code: u16) -> Option<CGEventFlags> {
    match key_code {
        54 | 55 => Some(CGEventFlags::MaskCommand),
        56 | 60 => Some(CGEventFlags::MaskShift),
        58 | 61 => Some(CGEventFlags::MaskAlternate),
        59 | 62 => Some(CGEventFlags::MaskControl),
        63 => Some(CGEventFlags::MaskSecondaryFn),
        _ => None,
    }
}

fn wheel_delta(value: f64) -> i32 {
    if !value.is_finite() {
        return 0;
    }
    let clamped = value.clamp(f64::from(i32::MIN), f64::from(i32::MAX));
    if clamped.abs() < 1.0 {
        if clamped.abs() >= 0.05 {
            return if clamped > 0.0 { 1 } else { -1 };
        }
        return 0;
    }
    clamped.round() as i32
}

fn clamp_to_displays(point: CGPoint) -> CGPoint {
    let Some(bounds) = active_display_bounds() else {
        return point;
    };
    let maximum = bounds.max();
    CGPoint::new(
        point.x.clamp(bounds.origin.x, maximum.x - 1.0),
        point.y.clamp(bounds.origin.y, maximum.y - 1.0),
    )
}

fn active_display_bounds() -> Option<CGRect> {
    let mut count = 0_u32;
    // SAFETY: count points to initialized writable storage; a null display list
    // is documented for the count query.
    if unsafe { CGGetActiveDisplayList(0, std::ptr::null_mut(), &mut count) }.0 != 0 || count == 0 {
        return None;
    }
    let mut displays = vec![0_u32; count as usize];
    // SAFETY: displays has capacity for count IDs and count is writable.
    if unsafe { CGGetActiveDisplayList(count, displays.as_mut_ptr(), &mut count) }.0 != 0 {
        return None;
    }
    let mut bounds: Option<CGRect> = None;
    for display in displays.into_iter().take(count as usize) {
        let display_bounds = CGDisplayBounds(display).standardize();
        if display_bounds.is_empty() {
            continue;
        }
        bounds = Some(match bounds {
            None => display_bounds,
            Some(current) => union(current, display_bounds),
        });
    }
    bounds
}

fn union(left: CGRect, right: CGRect) -> CGRect {
    let minimum_x = left.origin.x.min(right.origin.x);
    let minimum_y = left.origin.y.min(right.origin.y);
    let maximum_x = left.max().x.max(right.max().x);
    let maximum_y = left.max().y.max(right.max().y);
    CGRect::new(
        CGPoint::new(minimum_x, minimum_y),
        objc2_core_foundation::CGSize::new(maximum_x - minimum_x, maximum_y - minimum_y),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn modifier_bits_match_swift_mapping() {
        let flags = event_flags(&KeyStroke::new(40, 1 | 2 | 4 | 8), false);
        assert!(flags.contains(CGEventFlags::MaskCommand));
        assert!(flags.contains(CGEventFlags::MaskShift));
        assert!(flags.contains(CGEventFlags::MaskAlternate));
        assert!(flags.contains(CGEventFlags::MaskControl));
    }

    #[test]
    fn scroll_rounding_matches_swift_thresholds() {
        assert_eq!(wheel_delta(0.04), 0);
        assert_eq!(wheel_delta(0.05), 1);
        assert_eq!(wheel_delta(-0.5), -1);
        assert_eq!(wheel_delta(1.6), 2);
        assert_eq!(wheel_delta(f64::NAN), 0);
    }
}

/// Resolve only the target persisted on the Mac; remote requests carry a profile UUID.
pub fn resolve_application(
    target: &crate::application_launch::ApplicationTarget,
) -> Result<std::path::PathBuf, &'static str> {
    if let Some(bookmark) = target
        .bookmark
        .as_deref()
        .and_then(resolve_application_bookmark)
    {
        return checked_application_path(bookmark);
    }
    if let Some(raw) = &target.path {
        let path = if raw == "~" || raw.starts_with("~/") {
            std::path::PathBuf::from(std::env::var_os("HOME").ok_or("application_not_found")?)
                .join(raw.strip_prefix("~/").unwrap_or(""))
        } else {
            std::path::PathBuf::from(raw)
        };
        if path.exists() {
            return checked_application_path(path);
        }
    }
    if let Some(bundle) = &target.bundle {
        if let Some(path) = application_for_bundle(bundle) {
            return checked_application_path(path);
        }
    }
    Err("application_not_found")
}

fn checked_application_path(path: std::path::PathBuf) -> Result<std::path::PathBuf, &'static str> {
    let path = path.canonicalize().map_err(|_| "application_not_found")?;
    if !path.is_dir()
        || !path
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("app"))
    {
        return Err("invalid_application_bundle");
    }
    Ok(path)
}

fn resolve_application_bookmark(encoded: &str) -> Option<std::path::PathBuf> {
    use base64::Engine;
    use objc2_core_foundation::{
        CFData, CFError, CFRetained, CFURLBookmarkResolutionOptions, CFURLPathStyle, CFURL,
    };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .ok()?;
    let data = CFData::from_bytes(&bytes);
    let mut stale = 0;
    let mut error: *mut CFError = std::ptr::null_mut();
    // SAFETY: CoreFoundation accepts the default allocator and no relative URL/
    // requested properties. Data and both out-parameters live through the call.
    let url = unsafe {
        CFURL::new_by_resolving_bookmark_data(
            None,
            Some(&data),
            CFURLBookmarkResolutionOptions::CFURLBookmarkResolutionWithSecurityScope,
            None,
            None,
            &mut stale,
            &mut error,
        )
    };
    if let Some(error) = std::ptr::NonNull::new(error) {
        // SAFETY: A returned error follows the Create rule; release exactly once.
        drop(unsafe { CFRetained::from_raw(error) });
    }
    let url = url?;
    if url.scheme()?.to_string() != "file" {
        return None;
    }
    Some(std::path::PathBuf::from(
        url.file_system_path(CFURLPathStyle::CFURLPOSIXPathStyle)?
            .to_string(),
    ))
}

fn application_for_bundle(bundle: &str) -> Option<std::path::PathBuf> {
    use core_foundation::{
        array::{CFArray, CFArrayRef},
        base::TCFType,
        string::{CFString, CFStringRef},
        url::CFURL,
    };
    #[link(name = "CoreServices", kind = "framework")]
    extern "C" {
        fn LSCopyApplicationURLsForBundleIdentifier(
            bundle: CFStringRef,
            error: *mut *const std::ffi::c_void,
        ) -> CFArrayRef;
    }
    let identifier = CFString::new(bundle);
    // SAFETY: Identifier lives through the call, error output is optional. The
    // returned retained array contains application CFURLs per LaunchServices.
    let raw = unsafe {
        LSCopyApplicationURLsForBundleIdentifier(
            identifier.as_concrete_TypeRef(),
            std::ptr::null_mut(),
        )
    };
    if raw.is_null() {
        return None;
    }
    let urls: CFArray<CFURL> = unsafe { TCFType::wrap_under_create_rule(raw) };
    urls.iter().find_map(|url| url.to_path())
}

/// `open` acknowledges the OS launch request; never wait for the app to exit.
pub fn open_application(path: &std::path::Path) -> Result<(), &'static str> {
    let mut child = Command::new("/usr/bin/open")
        .arg("-a")
        .arg(path)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "application_launch_failed")?;
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                return if status.success() {
                    Ok(())
                } else {
                    Err("application_launch_failed")
                }
            }
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(20))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("application_launch_timed_out");
            }
        }
    }
}

#[cfg(test)]
mod application_tests {
    use super::*;
    use crate::application_launch::ApplicationTarget;
    use serde_json::json;
    #[test]
    fn application_resolution_prefers_existing_path_and_rejects_non_applications() {
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("Space and $(literal).app");
        std::fs::create_dir(&app).unwrap();
        let target = ApplicationTarget::from_profile(&json!({"launchTarget":{
            "bookmarkData":"invalid bookmark", "filePath":app,
            "bundleIdentifier":"com.invalid.no.such.application"}}))
        .unwrap();
        assert_eq!(
            resolve_application(&target).unwrap(),
            app.canonicalize().unwrap()
        );
        let ordinary = dir.path().join("ordinary.txt");
        std::fs::write(&ordinary, b"not executable").unwrap();
        let target =
            ApplicationTarget::from_profile(&json!({"launchTarget":{"filePath":ordinary}}))
                .unwrap();
        assert_eq!(
            resolve_application(&target),
            Err("invalid_application_bundle")
        );
        let target = ApplicationTarget::from_profile(
            &json!({"launchTarget":{"filePath":"https://example.com/App.app"}}),
        )
        .unwrap();
        assert_eq!(resolve_application(&target), Err("application_not_found"));
    }
    #[test]
    fn bookmark_resolution_precedes_path_and_keeps_bookmark_data_private() {
        use base64::Engine;
        use objc2_core_foundation::{
            CFString, CFURLBookmarkCreationOptions, CFURLPathStyle, CFURL,
        };
        let dir = tempfile::tempdir().unwrap();
        let app = dir.path().join("Bookmark.app");
        std::fs::create_dir(&app).unwrap();
        let path = CFString::from_str(app.to_str().unwrap());
        let url = CFURL::with_file_system_path(
            None,
            Some(&path),
            CFURLPathStyle::CFURLPOSIXPathStyle,
            true,
        )
        .unwrap();
        let mut error = std::ptr::null_mut();
        // SAFETY: Default allocator, no resource properties or relative URL, valid
        // retained URL and writable error output follow the CoreFoundation contract.
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
        .unwrap();
        assert!(error.is_null());
        let target = ApplicationTarget::from_profile(&json!({"launchTarget":{
            "bookmarkData":base64::engine::general_purpose::STANDARD.encode(data.to_vec()),
            "filePath":"/missing/fallback.app"}}))
        .unwrap();
        assert_eq!(
            resolve_application(&target).unwrap(),
            app.canonicalize().unwrap()
        );
    }
}
