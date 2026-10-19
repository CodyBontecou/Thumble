use std::collections::BTreeSet;
use thumble_core::KeyStroke;
use thumble_protocol::ControllerPointerButton;

pub fn accessibility_trusted() -> bool {
    false
}

pub fn prompt_accessibility() -> bool {
    false
}

pub fn open_accessibility_settings() -> Result<(), String> {
    Ok(())
}

pub fn key_event(_stroke: &KeyStroke, _key_down: bool) -> Result<(), String> {
    Ok(())
}

pub fn pointer_move(
    _delta_x: f64,
    _delta_y: f64,
    _held_buttons: &BTreeSet<String>,
) -> Result<(), String> {
    Ok(())
}

pub fn pointer_scroll(_delta_x: f64, _delta_y: f64) -> Result<(), String> {
    Ok(())
}

pub fn pointer_button(_button: ControllerPointerButton, _pressed: bool) -> Result<(), String> {
    Ok(())
}

pub fn resolve_application(
    _: &crate::application_launch::ApplicationTarget,
) -> Result<std::path::PathBuf, &'static str> {
    Err("application_launch_unsupported")
}
pub fn open_application(_: &std::path::Path) -> Result<(), &'static str> {
    Err("application_launch_unsupported")
}
