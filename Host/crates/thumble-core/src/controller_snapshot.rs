use crate::{semantic_key_name, PersistentState};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeSet;
use std::error::Error;
use std::fmt;

pub const MAXIMUM_CONTROLLER_SNAPSHOT_ELEMENTS: usize = 128;
pub const MAXIMUM_CONTROLLER_SNAPSHOT_LAYERS: usize = 128;
pub const MAXIMUM_CONTROLLER_SNAPSHOT_STYLES: usize = 64;
pub const MAXIMUM_CONTROLLER_SNAPSHOT_LAYOUT_ISSUES: usize = 128;
const MAXIMUM_LAYOUT_ISSUE_CONTROL_IDS: usize = 16;
const MAXIMUM_CONTROLLER_SOURCE_ELEMENTS: usize = 512;
const MAXIMUM_RAW_STRING_BYTES: usize = 1024;
const MAXIMUM_RAW_FRAME_ID_BYTES: usize = 512;
const MAXIMUM_IDENTIFIER_CHARACTERS: usize = 128;
const MAXIMUM_LABEL_CHARACTERS: usize = 64;
const MAXIMUM_PROFILE_NAME_CHARACTERS: usize = 256;
const DEFAULT_DEVICE_ID: &str = "iphone-17-pro";
const DEFAULT_FRAME_ID: &str = "iphone-17-pro-landscape";
const DEFAULT_PORTRAIT_WIDTH: f64 = 402.0;
const DEFAULT_PORTRAIT_HEIGHT: f64 = 874.0;

fn default_controller_color_scheme_preference() -> String {
    "system".to_owned()
}

fn default_controller_accent_style() -> String {
    "monochrome".to_owned()
}

const fn default_controller_shows_button_labels() -> bool {
    true
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerSnapshot {
    pub profile: ControllerProfileSnapshot,
    pub orientation: ControllerOrientation,
    #[serde(default = "default_controller_color_scheme_preference")]
    pub color_scheme_preference: String,
    #[serde(default = "default_controller_accent_style")]
    pub accent_style: String,
    #[serde(default = "default_controller_shows_button_labels")]
    pub shows_button_labels: bool,
    pub canvas: ControllerCanvasSnapshot,
    pub elements: Vec<ControllerElementSnapshot>,
    /// Canonical visible control-bar items with only safe effective appearance fields.
    pub control_bar_items: Vec<ControllerControlBarItemSnapshot>,
    /// Bounded, presentation-only z-order targets accepted by layer draft operations.
    pub layers: Vec<ControllerLayerSnapshot>,
    /// Bounded group metadata with children represented only by safe layer IDs.
    pub groups: Vec<ControllerGroupSnapshot>,
    /// Sanitized reusable style definitions. Asset/image/path-bearing content is omitted.
    pub styles: Vec<ControllerStyleSnapshot>,
    /// Bounded message-free quality diagnostics for selecting and verifying canonical repairs.
    #[serde(default)]
    pub layout_quality: ControllerLayoutQualitySnapshot,
}

impl fmt::Debug for ControllerSnapshot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ControllerSnapshot")
            .field("orientation", &self.orientation)
            .field("canvas_width", &self.canvas.width)
            .field("canvas_height", &self.canvas.height)
            .field("element_count", &self.elements.len())
            .field("control_bar_item_count", &self.control_bar_items.len())
            .field("layer_count", &self.layers.len())
            .field("group_count", &self.groups.len())
            .field("style_count", &self.styles.len())
            .field("layout_issue_count", &self.layout_quality.issues.len())
            .finish_non_exhaustive()
    }
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerProfileSnapshot {
    pub id: String,
    pub name: String,
    pub orientation_preference: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ControllerOrientation {
    Landscape,
    Portrait,
}

impl ControllerOrientation {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Landscape => "landscape",
            Self::Portrait => "portrait",
        }
    }
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerCanvasSnapshot {
    #[serde(rename = "frameID")]
    pub frame_id: String,
    pub width: f64,
    pub height: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dark_fill: Option<Value>,
    #[serde(default)]
    pub unsupported_content_omitted: bool,
}

#[derive(Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ControllerElementSnapshot {
    pub id: String,
    pub label: String,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mapped_button: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub visual_role: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accent_style: Option<String>,
    pub shape: String,
    pub frame: ControllerFrameSnapshot,
    pub center_x: f64,
    pub center_y: f64,
    pub width_scale: f64,
    pub height_scale: f64,
    pub rotation_degrees: f64,
    pub z_index: i32,
    pub is_hidden: bool,
    pub is_location_locked: bool,
    pub shows_integrated_label: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hit_insets: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub corner_radius: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub corner_radii: Option<Value>,
    pub shadow_strength: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dark_fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thumb_fill: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_thumb_fill: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dark_thumb_fill: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub joystick_visual_style: Option<String>,
    #[serde(rename = "styleID", skip_serializing_if = "Option::is_none")]
    pub style_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inline_appearance: Option<ControllerStyleAppearanceSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<ControllerStyleIconSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub haptic: Option<ControllerStyleHapticSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub joystick_mapping: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub joystick_settings: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger_settings: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trackpad_settings: Option<Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub outputs: Vec<ControllerElementOutputSnapshot>,
    pub unsupported_content_omitted: bool,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerControlBarItemSnapshot {
    pub item: String,
    #[serde(rename = "targetID")]
    pub target_id: String,
    pub index: usize,
    pub is_hidden: bool,
    pub width_scale: f64,
    pub height_scale: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shape: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub accent_style: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub corner_radius: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub corner_radii: Option<Value>,
    pub shadow_strength: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dark_fill: Option<Value>,
    #[serde(rename = "styleID", skip_serializing_if = "Option::is_none")]
    pub style_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inline_appearance: Option<ControllerStyleAppearanceSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<ControllerStyleIconSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub haptic: Option<ControllerStyleHapticSnapshot>,
    pub unsupported_content_omitted: bool,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerSemanticKeyStrokeSnapshot {
    pub key: String,
    pub modifiers: Vec<String>,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerElementOutputSnapshot {
    pub part: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub keyboard: Vec<ControllerSemanticKeyStrokeSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gamepad_button: Option<String>,
    pub unsupported_content_omitted: bool,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerLayerSnapshot {
    /// ID accepted as `elementID` by the typed layer operations.
    #[serde(rename = "targetID")]
    pub target_id: String,
    /// Stable semantic identity, useful for hidden built-in and system controls.
    #[serde(rename = "stableID")]
    pub stable_id: String,
    pub label: String,
    pub kind: String,
    pub z_index: i32,
    pub is_hidden: bool,
    pub is_location_locked: bool,
    #[serde(rename = "styleID", skip_serializing_if = "Option::is_none")]
    pub style_id: Option<String>,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerStyleColorSnapshot {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerStyleShadowSnapshot {
    pub color: ControllerStyleColorSnapshot,
    pub radius: f64,
    pub x: f64,
    pub y: f64,
}

#[derive(Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ControllerStyleStateSnapshot {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fill_color: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub foreground_color: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stroke_color: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stroke_width: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shadow_color: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shadow_radius: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shadow_x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shadow_y: Option<f64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub shadows: Vec<ControllerStyleShadowSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub glow_color: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub glow_radius: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inner_shadow_color: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inner_shadow_radius: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inner_shadow_x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inner_shadow_y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub highlight_color: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub highlight_radius: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub highlight_x: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub highlight_y: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub highlight_opacity: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bevel_highlight_color: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bevel_shadow_color: Option<ControllerStyleColorSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub bevel_width: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub opacity: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scale: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub blur_radius: Option<f64>,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerStyleIconSnapshot {
    pub source: String,
    pub value: String,
    pub placement: String,
    pub scale: f64,
    pub rendering_mode: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tint_color: Option<ControllerStyleColorSnapshot>,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerStyleHapticSnapshot {
    pub style: String,
    pub pattern: String,
    pub intensity: f64,
    pub sharpness: f64,
    pub duration: f64,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerStyleAppearanceSnapshot {
    pub normal: ControllerStyleStateSnapshot,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub pressed: Option<ControllerStyleStateSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active: Option<ControllerStyleStateSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disabled: Option<ControllerStyleStateSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<ControllerStyleIconSnapshot>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub haptic_style: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub haptic: Option<ControllerStyleHapticSnapshot>,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerStyleSnapshot {
    pub id: String,
    pub name: String,
    pub applies_to: Vec<String>,
    pub appearance: ControllerStyleAppearanceSnapshot,
    pub unsupported_content_omitted: bool,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerLayoutQualityIssueSnapshot {
    pub code: String,
    pub severity: String,
    #[serde(rename = "controlIDs")]
    pub control_ids: Vec<String>,
    pub control_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metric: Option<f64>,
    pub suggested_repairs: Vec<String>,
}

#[derive(Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ControllerLayoutQualitySnapshot {
    pub issue_count: usize,
    pub error_count: usize,
    pub warning_count: usize,
    pub issues: Vec<ControllerLayoutQualityIssueSnapshot>,
    pub omitted_issue_count: usize,
}

#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ControllerGroupSnapshot {
    pub id: String,
    pub name: String,
    #[serde(rename = "childTargetIDs")]
    pub child_target_ids: Vec<String>,
    #[serde(rename = "childStableIDs")]
    pub child_stable_ids: Vec<String>,
    pub is_locked: bool,
    pub is_hidden: bool,
}

#[derive(Clone, Copy, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct ControllerFrameSnapshot {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControllerSnapshotError {
    MissingActiveProfile,
    MissingCustomization,
}

impl fmt::Display for ControllerSnapshotError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::MissingActiveProfile => "active profile is unavailable",
            Self::MissingCustomization => "active profile has no controller customization",
        })
    }
}

impl Error for ControllerSnapshotError {}

impl PersistentState {
    /// Produce a bounded, presentation-only view of the active controller.
    ///
    /// Only allowlisted geometry and labels cross this boundary. Bindings,
    /// outputs, assets, launch targets, and arbitrary profile fields are never
    /// copied into the snapshot.
    pub fn controller_snapshot(&self) -> Result<ControllerSnapshot, ControllerSnapshotError> {
        let auth_tokens = self
            .trusted_clients
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>();
        self.controller_snapshot_with_redactor(&|value| {
            if auth_tokens
                .iter()
                .any(|token| !token.is_empty() && value.contains(token))
            {
                "[REDACTED]".to_owned()
            } else {
                value.to_owned()
            }
        })
    }

    /// Transform every free-form string before truncation so no boundary can
    /// split a complete credential into an unrecognizable token prefix.
    fn controller_snapshot_with_redactor<F>(
        &self,
        redact: &F,
    ) -> Result<ControllerSnapshot, ControllerSnapshotError>
    where
        F: Fn(&str) -> String,
    {
        let profile = self
            .active_profile()
            .and_then(Value::as_object)
            .ok_or(ControllerSnapshotError::MissingActiveProfile)?;
        let primary = profile
            .get("customization")
            .and_then(Value::as_object)
            .ok_or(ControllerSnapshotError::MissingCustomization)?;
        let orientation_preference = allow_orientation_preference(
            profile.get("orientationPreference").and_then(Value::as_str),
        );
        let primary_orientation = canvas_orientation(primary);
        let orientation = match orientation_preference {
            "portrait" => ControllerOrientation::Portrait,
            "landscape" => ControllerOrientation::Landscape,
            _ => primary_orientation,
        };
        let variant_name = match orientation {
            ControllerOrientation::Landscape => "landscapeCustomization",
            ControllerOrientation::Portrait => "portraitCustomization",
        };
        let customization = profile
            .get(variant_name)
            .and_then(Value::as_object)
            .unwrap_or(primary);
        let canvas = resolved_canvas(customization, orientation, redact);
        let color_scheme_preference = customization
            .get("colorSchemePreference")
            .and_then(Value::as_str)
            .filter(|value| matches!(*value, "system" | "light" | "dark"))
            .unwrap_or("system");
        let accent_style = customization
            .get("accentStyle")
            .and_then(Value::as_str)
            .filter(|value| {
                matches!(
                    *value,
                    "monochrome" | "blue" | "green" | "purple" | "pink" | "amber"
                )
            })
            .unwrap_or("monochrome");
        let shows_button_labels = customization
            .get("showsButtonLabels")
            .and_then(Value::as_bool)
            .unwrap_or(true);
        let control_scale =
            control_scale_multiplier(customization.get("controlScale").and_then(Value::as_str));
        let layout_mode = customization
            .get("layoutMode")
            .and_then(Value::as_str)
            .filter(|mode| *mode == "southpaw")
            .unwrap_or("standard");
        let elements =
            resolved_elements(customization, &canvas, control_scale, layout_mode, redact);
        let control_bar_items = resolved_control_bar_items(customization, redact);
        let layers = resolved_layers(customization, redact);
        let groups = resolved_groups(customization, &layers, redact);
        let styles = resolved_styles(customization, redact);
        let layout_quality = resolved_layout_quality(&elements, &canvas, customization);

        Ok(ControllerSnapshot {
            profile: ControllerProfileSnapshot {
                id: redacted_bounded_string(
                    profile
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown"),
                    MAXIMUM_IDENTIFIER_CHARACTERS,
                    "unknown",
                    redact,
                ),
                name: redacted_bounded_string(
                    profile
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("Unnamed profile"),
                    MAXIMUM_PROFILE_NAME_CHARACTERS,
                    "Unnamed profile",
                    redact,
                ),
                orientation_preference: orientation_preference.to_owned(),
            },
            orientation,
            color_scheme_preference: color_scheme_preference.to_owned(),
            accent_style: accent_style.to_owned(),
            shows_button_labels,
            canvas,
            elements,
            control_bar_items,
            layers,
            groups,
            styles,
            layout_quality,
        })
    }
}

fn resolved_layout_quality(
    elements: &[ControllerElementSnapshot],
    canvas: &ControllerCanvasSnapshot,
    customization: &serde_json::Map<String, Value>,
) -> ControllerLayoutQualitySnapshot {
    let interactive = elements
        .iter()
        .filter(|element| !matches!(element.kind.as_str(), "text" | "decoration"))
        .collect::<Vec<_>>();
    let mut issues = Vec::new();
    if interactive.is_empty() {
        push_layout_issue(&mut issues, "no-visible-controls", "error", &[], None);
    }
    for element in &interactive {
        let shortest = element.frame.width.min(element.frame.height);
        if shortest < 44.0 {
            push_layout_issue(
                &mut issues,
                "small-control",
                "warning",
                std::slice::from_ref(element),
                Some(shortest),
            );
        }
        let margin = (canvas.width.min(canvas.height) * 0.006).max(2.0);
        if element.frame.x < margin
            || element.frame.y < margin
            || element.frame.x + element.frame.width > canvas.width - margin
            || element.frame.y + element.frame.height > canvas.height - margin
        {
            push_layout_issue(
                &mut issues,
                "edge-hugging-control",
                "warning",
                std::slice::from_ref(element),
                None,
            );
        }
    }
    for back_index in 0..interactive.len() {
        for front_index in back_index + 1..interactive.len() {
            let back = interactive[back_index];
            let front = interactive[front_index];
            let visual = positive_snapshot_intersection(&back.frame, &front.frame);
            let back_hit = snapshot_hit_frame(back);
            let front_hit = snapshot_hit_frame(front);
            let Some(hit) = positive_snapshot_intersection(&back_hit, &front_hit) else {
                continue;
            };
            let hit_ratio = snapshot_rect_area(&hit)
                / snapshot_rect_area(&back_hit)
                    .min(snapshot_rect_area(&front_hit))
                    .max(1.0);
            if let Some(visual) = visual {
                let ratio = snapshot_rect_area(&visual)
                    / snapshot_rect_area(&back.frame)
                        .min(snapshot_rect_area(&front.frame))
                        .max(1.0);
                if ratio > 0.015 {
                    push_layout_issue(
                        &mut issues,
                        "control-overlap",
                        "warning",
                        &[back, front],
                        Some(ratio),
                    );
                }
            } else {
                push_layout_issue(
                    &mut issues,
                    "expanded-hit-overlap",
                    "warning",
                    &[back, front],
                    Some(hit_ratio),
                );
            }
            let back_priority = snapshot_touch_priority(back);
            let front_priority = snapshot_touch_priority(front);
            let front_wins = front_priority < back_priority
                || (front_priority == back_priority
                    && snapshot_rect_area(&front_hit) < snapshot_rect_area(&back_hit) - 0.5);
            let equal = front_priority == back_priority
                && (snapshot_rect_area(&front_hit) - snapshot_rect_area(&back_hit)).abs() <= 0.5;
            if equal {
                push_layout_issue(
                    &mut issues,
                    "hit-region-z-order-ambiguous",
                    "warning",
                    &[back, front],
                    Some(hit_ratio),
                );
            } else if !front_wins {
                push_layout_issue(
                    &mut issues,
                    "hit-region-z-order-mismatch",
                    "warning",
                    &[back, front],
                    Some(hit_ratio),
                );
            }
        }
    }
    if interactive.len() >= 8 {
        if let Some(bounds) = snapshot_union_frame(&interactive) {
            let width_coverage = bounds.width / canvas.width.max(1.0);
            let height_coverage = bounds.height / canvas.height.max(1.0);
            let bottom_unused =
                (canvas.height - bounds.y - bounds.height).max(0.0) / canvas.height.max(1.0);
            if bottom_unused > 0.18 {
                push_layout_issue(
                    &mut issues,
                    "underused-bottom-space",
                    "warning",
                    &interactive,
                    Some(bottom_unused),
                );
            }
            if height_coverage < 0.70 {
                push_layout_issue(
                    &mut issues,
                    "low-vertical-coverage",
                    "warning",
                    &interactive,
                    Some(height_coverage),
                );
            }
            if width_coverage < 0.55 {
                push_layout_issue(
                    &mut issues,
                    "low-horizontal-coverage",
                    "warning",
                    &interactive,
                    Some(width_coverage),
                );
            }
        }
    }
    let reach_mode = snapshot_reach_mode(customization);
    let primary = interactive
        .iter()
        .copied()
        .filter(|element| snapshot_primary_role(element).is_some())
        .collect::<Vec<_>>();
    let portrait = canvas.height > canvas.width;
    for element in &primary {
        let role = snapshot_primary_role(element).unwrap_or(false);
        let x = (element.frame.x + element.frame.width / 2.0) / canvas.width.max(1.0);
        let y = (element.frame.y + element.frame.height / 2.0) / canvas.height.max(1.0);
        let anchor_x = match reach_mode {
            SnapshotReachMode::TwoHanded if role => {
                if portrait {
                    0.27
                } else {
                    0.18
                }
            }
            SnapshotReachMode::TwoHanded => {
                if portrait {
                    0.73
                } else {
                    0.82
                }
            }
            SnapshotReachMode::Left => {
                if portrait {
                    0.27
                } else {
                    0.25
                }
            }
            SnapshotReachMode::Right => {
                if portrait {
                    0.73
                } else {
                    0.75
                }
            }
        };
        let horizontal = if reach_mode == SnapshotReachMode::TwoHanded {
            if portrait {
                0.36
            } else {
                0.34
            }
        } else if portrait {
            0.48
        } else {
            0.50
        };
        let reach = ((x - anchor_x) / horizontal)
            .hypot((y - if portrait { 0.76 } else { 0.68 }) / if portrait { 0.38 } else { 0.43 });
        let issue = if y < if portrait { 0.24 } else { 0.20 } {
            Some(("primary-control-too-high", y))
        } else if reach_mode == SnapshotReachMode::TwoHanded
            && (0.40..=0.60).contains(&x)
            && y < if portrait { 0.78 } else { 0.74 }
        {
            Some(("primary-control-too-central", 0.5 - (x - 0.5).abs()))
        } else if reach > 1.25 {
            Some(("primary-control-out-of-reach", reach))
        } else {
            None
        };
        if let Some((code, metric)) = issue {
            push_layout_issue(
                &mut issues,
                code,
                "warning",
                std::slice::from_ref(element),
                Some(metric),
            );
        }
    }
    if portrait && reach_mode == SnapshotReachMode::TwoHanded && primary.len() >= 4 {
        let lower_left = primary
            .iter()
            .filter(|element| {
                element.frame.x + element.frame.width / 2.0 < canvas.width * 0.48
                    && element.frame.y + element.frame.height / 2.0 > canvas.height * 0.52
            })
            .count();
        let lower_right = primary
            .iter()
            .filter(|element| {
                element.frame.x + element.frame.width / 2.0 > canvas.width * 0.52
                    && element.frame.y + element.frame.height / 2.0 > canvas.height * 0.52
            })
            .count();
        if lower_left == 0 || lower_right == 0 {
            let imbalance = lower_left.abs_diff(lower_right) as f64 / primary.len().max(1) as f64;
            push_layout_issue(
                &mut issues,
                "portrait-primary-action-distribution",
                "warning",
                &primary,
                Some(imbalance),
            );
        }
    }
    if portrait && interactive.len() >= 6 {
        let gap = snapshot_largest_vertical_gap(&interactive, canvas.height);
        if gap > 0.30 {
            push_layout_issue(
                &mut issues,
                "portrait-dead-space",
                "warning",
                &interactive,
                Some(gap),
            );
        }
    }
    issues.sort_by(|left, right| {
        layout_severity_rank(&left.severity)
            .cmp(&layout_severity_rank(&right.severity))
            .then_with(|| left.code.cmp(&right.code))
            .then_with(|| left.control_ids.cmp(&right.control_ids))
    });
    let issue_count = issues.len();
    let error_count = issues
        .iter()
        .filter(|issue| issue.severity == "error")
        .count();
    let warning_count = issues
        .iter()
        .filter(|issue| issue.severity == "warning")
        .count();
    issues.truncate(MAXIMUM_CONTROLLER_SNAPSHOT_LAYOUT_ISSUES);
    ControllerLayoutQualitySnapshot {
        issue_count,
        error_count,
        warning_count,
        omitted_issue_count: issue_count.saturating_sub(issues.len()),
        issues,
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum SnapshotReachMode {
    TwoHanded,
    Left,
    Right,
}

fn snapshot_reach_mode(customization: &serde_json::Map<String, Value>) -> SnapshotReachMode {
    let tags = customization
        .get("designMetadata")
        .and_then(|value| value.get("tags"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .map(|tag| tag.trim().to_ascii_lowercase())
        .collect::<BTreeSet<_>>();
    if tags.contains("left-hand") || tags.contains("one-handed-left") {
        SnapshotReachMode::Left
    } else if tags.contains("right-hand") || tags.contains("one-handed-right") {
        SnapshotReachMode::Right
    } else {
        SnapshotReachMode::TwoHanded
    }
}

/// `Some(true)` is movement, `Some(false)` is action, and `None` is utility/exempt.
fn snapshot_primary_role(element: &ControllerElementSnapshot) -> Option<bool> {
    if matches!(element.kind.as_str(), "joystick" | "trigger" | "trackpad") {
        return None;
    }
    let label = element.label.trim().to_ascii_lowercase();
    let is_builtin = element.id.starts_with("00000000-0000-0000-0000-0000000001");
    if !is_builtin
        && (matches!(
            label.as_str(),
            "+" | "-"
                | "−"
                | "l"
                | "r"
                | "zl"
                | "zr"
                | "lb"
                | "rb"
                | "lt"
                | "rt"
                | "menu"
                | "start"
                | "select"
                | "back"
                | "home"
                | "options"
                | "share"
                | "coin"
                | "utility"
        ) || label.contains("shoulder")
            || label.contains("bumper"))
    {
        return None;
    }
    match element.mapped_button.as_deref() {
        Some("up" | "down" | "left" | "right") => Some(true),
        Some(
            "jump" | "attack" | "dash" | "focus" | "custom1" | "custom2" | "custom3" | "custom4"
            | "custom5" | "custom6" | "custom7" | "custom8",
        ) => Some(false),
        _ => None,
    }
}

fn snapshot_largest_vertical_gap(
    elements: &[&ControllerElementSnapshot],
    canvas_height: f64,
) -> f64 {
    let mut intervals = elements
        .iter()
        .filter_map(|element| {
            let start = element.frame.y.max(0.0);
            let end = (element.frame.y + element.frame.height).min(canvas_height);
            (end > start).then_some((start, end))
        })
        .collect::<Vec<_>>();
    intervals.sort_by(|left, right| {
        left.0
            .total_cmp(&right.0)
            .then_with(|| left.1.total_cmp(&right.1))
    });
    let Some(mut active) = intervals.first().copied() else {
        return 0.0;
    };
    let mut largest: f64 = 0.0;
    for interval in intervals.into_iter().skip(1) {
        if interval.0 > active.1 {
            largest = largest.max(interval.0 - active.1);
            active = interval;
        } else {
            active.1 = active.1.max(interval.1);
        }
    }
    largest / canvas_height.max(1.0)
}

fn push_layout_issue(
    issues: &mut Vec<ControllerLayoutQualityIssueSnapshot>,
    code: &str,
    severity: &str,
    controls: &[&ControllerElementSnapshot],
    metric: Option<f64>,
) {
    let suggested_repairs = match code {
        "no-visible-controls" => vec!["show-default-controls"],
        "small-control" => vec!["minimum-touch-target"],
        "edge-hugging-control" | "layout-displacement" => vec!["move-inside-safe-area"],
        "control-overlap" => vec!["resolve-overlap", "auto-arrange"],
        "expanded-hit-overlap" | "hit-region-z-order-ambiguous" | "hit-region-z-order-mismatch" => {
            vec!["separate-expanded-hit-targets"]
        }
        "primary-control-too-high"
        | "primary-control-too-central"
        | "primary-control-out-of-reach"
        | "portrait-primary-action-distribution"
        | "portrait-dead-space" => vec!["ergonomic-auto-arrange"],
        "underused-bottom-space" | "low-vertical-coverage" | "low-horizontal-coverage" => {
            vec!["auto-arrange"]
        }
        _ => Vec::new(),
    };
    let mut control_ids = controls
        .iter()
        .take(MAXIMUM_LAYOUT_ISSUE_CONTROL_IDS)
        .map(|element| element.id.clone())
        .collect::<Vec<_>>();
    if matches!(
        code,
        "portrait-primary-action-distribution" | "portrait-dead-space"
    ) {
        control_ids.sort();
    }
    issues.push(ControllerLayoutQualityIssueSnapshot {
        code: code.to_owned(),
        severity: severity.to_owned(),
        control_count: controls.len(),
        control_ids,
        metric: metric.filter(|value| value.is_finite()),
        suggested_repairs: suggested_repairs.into_iter().map(str::to_owned).collect(),
    });
}

fn layout_severity_rank(value: &str) -> u8 {
    match value {
        "error" => 0,
        "warning" => 1,
        _ => 2,
    }
}

fn snapshot_hit_frame(element: &ControllerElementSnapshot) -> ControllerFrameSnapshot {
    if let Some(insets) = element.hit_insets.as_ref().and_then(Value::as_object) {
        let value = |key: &str| insets.get(key).and_then(Value::as_f64).unwrap_or(0.0);
        let top = value("top");
        let leading = value("leading");
        let bottom = value("bottom");
        let trailing = value("trailing");
        return ControllerFrameSnapshot {
            x: element.frame.x - leading,
            y: element.frame.y - top,
            width: element.frame.width + leading + trailing,
            height: element.frame.height + top + bottom,
        };
    }
    if element.kind == "joystick" {
        let side = element.frame.width.min(element.frame.height);
        let hit_side = if element.joystick_visual_style.as_deref() == Some("thumbstick") {
            side.max(44.0)
        } else {
            (side + 20.0).max(side)
        };
        return ControllerFrameSnapshot {
            x: element.frame.x + element.frame.width / 2.0 - hit_side / 2.0,
            y: element.frame.y + element.frame.height / 2.0 - hit_side / 2.0,
            width: hit_side,
            height: hit_side,
        };
    }
    ControllerFrameSnapshot {
        x: element.frame.x - 10.0,
        y: element.frame.y - 10.0,
        width: element.frame.width + 20.0,
        height: element.frame.height + 20.0,
    }
}

fn positive_snapshot_intersection(
    left: &ControllerFrameSnapshot,
    right: &ControllerFrameSnapshot,
) -> Option<ControllerFrameSnapshot> {
    let x = left.x.max(right.x);
    let y = left.y.max(right.y);
    let width = (left.x + left.width).min(right.x + right.width) - x;
    let height = (left.y + left.height).min(right.y + right.height) - y;
    (width > 0.5 && height > 0.5).then_some(ControllerFrameSnapshot {
        x,
        y,
        width,
        height,
    })
}

fn snapshot_rect_area(frame: &ControllerFrameSnapshot) -> f64 {
    frame.width * frame.height
}

fn snapshot_touch_priority(element: &ControllerElementSnapshot) -> u8 {
    match element.kind.as_str() {
        "trigger" => 0,
        "joystick" => 1,
        "trackpad" => 3,
        _ => 2,
    }
}

fn snapshot_union_frame(
    elements: &[&ControllerElementSnapshot],
) -> Option<ControllerFrameSnapshot> {
    let first = elements.first()?.frame;
    Some(elements.iter().skip(1).fold(first, |bounds, element| {
        let min_x = bounds.x.min(element.frame.x);
        let min_y = bounds.y.min(element.frame.y);
        ControllerFrameSnapshot {
            x: min_x,
            y: min_y,
            width: (bounds.x + bounds.width).max(element.frame.x + element.frame.width) - min_x,
            height: (bounds.y + bounds.height).max(element.frame.y + element.frame.height) - min_y,
        }
    }))
}

fn resolved_control_bar_items(
    customization: &serde_json::Map<String, Value>,
    redact: &impl Fn(&str) -> String,
) -> Vec<ControllerControlBarItemSnapshot> {
    const CANONICAL_ITEMS: &[&str] = &[
        "status",
        "profile_menu",
        "launch_target",
        "spacer",
        "edit_layout",
        "settings",
        "home",
        "connection",
    ];
    let source_items = customization
        .get("controlBarItems")
        .and_then(Value::as_array)
        .map_or_else(
            || {
                CANONICAL_ITEMS
                    .iter()
                    .map(|item| Value::String((*item).to_owned()))
                    .collect()
            },
            Clone::clone,
        );
    let source_appearances = customization
        .get("controlBarItemCustomizations")
        .and_then(Value::as_array);
    let mut seen = BTreeSet::new();
    let mut result = Vec::new();
    for value in source_items {
        let Some(item) = value.as_str().filter(|item| CANONICAL_ITEMS.contains(item)) else {
            continue;
        };
        if !seen.insert(item.to_owned()) || result.len() >= CANONICAL_ITEMS.len() {
            continue;
        }
        let entry = source_appearances
            .into_iter()
            .flatten()
            .rev()
            .find(|entry| entry.get("item").and_then(Value::as_str) == Some(item));
        let layout = entry
            .and_then(|entry| entry.get("appearance"))
            .and_then(Value::as_object);
        let field = |name| layout.and_then(|layout| layout.get(name));
        let (fill, fill_omitted) = sanitize_element_fill(field("fillStyle"), field("fillColor"));
        let (light_fill, light_fill_omitted) =
            sanitize_element_fill(field("lightFillStyle"), field("lightFillColor"));
        let (dark_fill, dark_fill_omitted) =
            sanitize_element_fill(field("darkFillStyle"), field("darkFillColor"));
        let (inline_appearance, appearance_omitted) =
            sanitize_inline_appearance(field("visualStyle"), redact);
        let (icon, icon_omitted) = sanitize_style_icon(field("icon"), redact);
        let (_, haptic_style_omitted) = sanitize_allowed_string(
            field("hapticStyle"),
            &["none", "light", "medium", "heavy", "soft", "rigid"],
        );
        let (haptic, haptic_omitted) = sanitize_style_haptic(field("hapticFeedback"));
        let known_keys = [
            "widthScale",
            "heightScale",
            "shape",
            "accentStyle",
            "fillColor",
            "lightFillColor",
            "darkFillColor",
            "fillStyle",
            "lightFillStyle",
            "darkFillStyle",
            "styleID",
            "visualStyle",
            "icon",
            "hapticStyle",
            "hapticFeedback",
            "cornerRadius",
            "cornerRadii",
            "shadowStrength",
            "isHidden",
            "rotationDegrees",
            "zIndex",
            "isLocationLocked",
        ];
        let unsupported_keys = layout
            .is_some_and(|layout| layout.keys().any(|key| !known_keys.contains(&key.as_str())))
            || entry.is_some_and(|entry| {
                entry.as_object().is_some_and(|entry| {
                    entry
                        .keys()
                        .any(|key| !matches!(key.as_str(), "item" | "appearance"))
                })
            });
        let index = result.len();
        result.push(ControllerControlBarItemSnapshot {
            item: item.to_owned(),
            target_id: redacted_bounded_string(
                &format!("control_bar_item.{item}"),
                MAXIMUM_IDENTIFIER_CHARACTERS,
                "control_bar_item",
                redact,
            ),
            index,
            is_hidden: field("isHidden").and_then(Value::as_bool).unwrap_or(false),
            width_scale: bounded_number(field("widthScale"), 1.0, 0.001, 12.0),
            height_scale: bounded_number(field("heightScale"), 1.0, 0.001, 12.0),
            shape: allowed_shape(field("shape").and_then(Value::as_str)).map(str::to_owned),
            accent_style: field("accentStyle")
                .and_then(Value::as_str)
                .filter(|value| {
                    matches!(
                        *value,
                        "monochrome" | "blue" | "green" | "purple" | "pink" | "amber"
                    )
                })
                .map(str::to_owned),
            corner_radius: safe_style_number(field("cornerRadius"), 0.0, 1_024.0),
            corner_radii: sanitize_numeric_object(
                field("cornerRadii"),
                &[
                    "topLeading",
                    "topTrailing",
                    "bottomTrailing",
                    "bottomLeading",
                ],
                0.0,
                1_024.0,
            ),
            shadow_strength: bounded_number(field("shadowStrength"), 1.0, 0.0, 2.0),
            fill,
            light_fill,
            dark_fill,
            style_id: layer_style_id(layout),
            inline_appearance,
            icon,
            haptic,
            unsupported_content_omitted: fill_omitted
                || light_fill_omitted
                || dark_fill_omitted
                || appearance_omitted
                || icon_omitted
                || haptic_style_omitted
                || haptic_omitted
                || unsupported_keys,
        });
    }
    result
}

fn resolved_elements(
    customization: &serde_json::Map<String, Value>,
    canvas: &ControllerCanvasSnapshot,
    control_scale: f64,
    layout_mode: &str,
    redact: &impl Fn(&str) -> String,
) -> Vec<ControllerElementSnapshot> {
    let Some(source) = customization.get("elements").and_then(Value::as_array) else {
        return Vec::new();
    };
    let mut seen = BTreeSet::new();
    let mut elements = Vec::new();
    for (source_index, element) in source
        .iter()
        .take(MAXIMUM_CONTROLLER_SOURCE_ELEMENTS)
        .enumerate()
    {
        if elements.len() >= MAXIMUM_CONTROLLER_SNAPSHOT_ELEMENTS {
            break;
        }
        let Some(element) = element.as_object() else {
            continue;
        };
        let Some(raw_id) = element.get("id").and_then(Value::as_str) else {
            continue;
        };
        if raw_id.len() > MAXIMUM_RAW_STRING_BYTES {
            continue;
        }
        let id = redacted_bounded_string(raw_id, MAXIMUM_IDENTIFIER_CHARACTERS, "", redact);
        if id.is_empty() || !seen.insert(id.to_ascii_lowercase()) {
            continue;
        }
        let Some(kind) = allowed_kind(element.get("kind").and_then(Value::as_str)) else {
            continue;
        };
        let layout = element.get("layout").and_then(Value::as_object);
        let layout_field = |name| layout.and_then(|layout| layout.get(name));
        if layout_field("isHidden")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            continue;
        }
        let built_in = element
            .get("builtInButton")
            .and_then(Value::as_str)
            .and_then(allowed_button);
        let mapped_button = built_in.or_else(|| {
            element
                .get("legacySlot")
                .and_then(Value::as_str)
                .and_then(allowed_button)
        });
        let shape = allowed_shape(layout_field("shape").and_then(Value::as_str))
            .unwrap_or_else(|| default_shape(kind, mapped_button));
        let (base_width, base_height) = base_size(
            kind,
            mapped_button.unwrap_or("jump"),
            canvas.width,
            canvas.height,
            control_scale,
        );
        let width = (base_width * bounded_number(layout_field("widthScale"), 1.0, 0.001, 12.0))
            .clamp(1.0, canvas.width);
        let height = (base_height * bounded_number(layout_field("heightScale"), 1.0, 0.001, 12.0))
            .clamp(1.0, canvas.height);
        let default_center = built_in.map(|button| {
            default_normalized_center(
                button,
                layout_mode,
                width,
                height,
                canvas.width,
                canvas.height,
            )
        });
        let center_x = bounded_optional_number(layout_field("centerX"), 0.0, 1.0)
            .unwrap_or_else(|| default_center.map_or(0.5, |center| center.0));
        let center_y = bounded_optional_number(layout_field("centerY"), 0.0, 1.0)
            .unwrap_or_else(|| default_center.map_or(0.5, |center| center.1));
        let pixel_x = (center_x * canvas.width).clamp(width / 2.0, canvas.width - width / 2.0);
        let pixel_y = (center_y * canvas.height).clamp(height / 2.0, canvas.height - height / 2.0);
        let label = redacted_bounded_string(
            element.get("label").and_then(Value::as_str).unwrap_or(""),
            MAXIMUM_LABEL_CHARACTERS,
            default_label(kind, mapped_button),
            redact,
        );
        let z_index = layout_field("zIndex")
            .and_then(Value::as_i64)
            .unwrap_or(0)
            .clamp(-100, 100) as i32;
        let rotation_degrees = normalized_rotation(bounded_number(
            layout_field("rotationDegrees"),
            0.0,
            -36_000.0,
            36_000.0,
        ));
        let (fill, fill_omitted) =
            sanitize_element_fill(layout_field("fillStyle"), layout_field("fillColor"));
        let (light_fill, light_fill_omitted) = sanitize_element_fill(
            layout_field("lightFillStyle"),
            layout_field("lightFillColor"),
        );
        let (dark_fill, dark_fill_omitted) =
            sanitize_element_fill(layout_field("darkFillStyle"), layout_field("darkFillColor"));
        let (inline_appearance, appearance_omitted) =
            sanitize_inline_appearance(layout_field("visualStyle"), redact);
        let (icon, icon_omitted) = sanitize_style_icon(layout_field("icon"), redact);
        let (_, haptic_style_omitted) = sanitize_allowed_string(
            layout_field("hapticStyle"),
            &["none", "light", "medium", "heavy", "soft", "rigid"],
        );
        let (haptic, haptic_omitted) = sanitize_style_haptic(layout_field("hapticFeedback"));
        let (outputs, output_omitted) = sanitize_element_outputs(element);
        let (joystick_mapping, joystick_mapping_omitted) =
            sanitize_joystick_mapping(element.get("joystickMapping"));
        let (joystick_settings, joystick_settings_omitted) =
            sanitize_joystick_settings(element.get("joystickOutputSettings"));
        let (trigger_settings, trigger_settings_omitted) =
            sanitize_trigger_settings(element.get("triggerSettings"));
        let (trackpad_settings, trackpad_settings_omitted) =
            sanitize_trackpad_settings(element.get("trackpadSettings"));
        elements.push((
            z_index,
            source_index,
            ControllerElementSnapshot {
                id,
                label,
                kind: kind.to_owned(),
                mapped_button: mapped_button.map(str::to_owned),
                visual_role: element
                    .get("visualRole")
                    .and_then(Value::as_str)
                    .filter(|role| allowed_visual_role(role))
                    .map(str::to_owned),
                accent_style: layout_field("accentStyle")
                    .and_then(Value::as_str)
                    .filter(|value| {
                        matches!(
                            *value,
                            "monochrome" | "blue" | "green" | "purple" | "pink" | "amber"
                        )
                    })
                    .map(str::to_owned),
                shape: shape.to_owned(),
                frame: ControllerFrameSnapshot {
                    x: pixel_x - width / 2.0,
                    y: pixel_y - height / 2.0,
                    width,
                    height,
                },
                center_x,
                center_y,
                width_scale: bounded_number(layout_field("widthScale"), 1.0, 0.001, 12.0),
                height_scale: bounded_number(layout_field("heightScale"), 1.0, 0.001, 12.0),
                rotation_degrees,
                z_index,
                is_hidden: false,
                is_location_locked: layout_field("isLocationLocked")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                shows_integrated_label: layout_field("showsIntegratedLabel")
                    .and_then(Value::as_bool)
                    .unwrap_or(true),
                hit_insets: sanitize_numeric_object(
                    layout_field("hitInsets"),
                    &["top", "leading", "bottom", "trailing"],
                    0.0,
                    96.0,
                ),
                corner_radius: safe_style_number(layout_field("cornerRadius"), 0.0, 1_024.0),
                corner_radii: sanitize_numeric_object(
                    layout_field("cornerRadii"),
                    &[
                        "topLeading",
                        "topTrailing",
                        "bottomTrailing",
                        "bottomLeading",
                    ],
                    0.0,
                    1_024.0,
                ),
                shadow_strength: bounded_number(layout_field("shadowStrength"), 1.0, 0.0, 2.0),
                fill,
                light_fill,
                dark_fill,
                thumb_fill: sanitize_style_color(layout_field("joystickKnobColor")),
                light_thumb_fill: sanitize_style_color(layout_field("lightJoystickKnobColor")),
                dark_thumb_fill: sanitize_style_color(layout_field("darkJoystickKnobColor")),
                joystick_visual_style: layout_field("joystickVisualStyle")
                    .and_then(Value::as_str)
                    .filter(|value| matches!(*value, "pad" | "thumbstick"))
                    .map(str::to_owned),
                style_id: layer_style_id(layout),
                inline_appearance,
                icon,
                haptic,
                joystick_mapping,
                joystick_settings,
                trigger_settings,
                trackpad_settings,
                outputs,
                unsupported_content_omitted: fill_omitted
                    || light_fill_omitted
                    || dark_fill_omitted
                    || appearance_omitted
                    || icon_omitted
                    || haptic_style_omitted
                    || haptic_omitted
                    || output_omitted
                    || joystick_mapping_omitted
                    || joystick_settings_omitted
                    || trigger_settings_omitted
                    || trackpad_settings_omitted
                    || layout.is_some_and(|layout| {
                        layout.keys().any(|key| {
                            matches!(key.as_str(), "assetID" | "data" | "fileName" | "image")
                        })
                    }),
            },
        ));
    }
    elements.sort_by(|left, right| {
        left.0
            .cmp(&right.0)
            .then_with(|| left.1.cmp(&right.1))
            .then_with(|| left.2.id.cmp(&right.2.id))
    });
    elements
        .into_iter()
        .map(|(_, _, element)| element)
        .collect()
}

fn sanitize_element_fill(style: Option<&Value>, color: Option<&Value>) -> (Option<Value>, bool) {
    if let Some(style) = style {
        let Some(object) = style.as_object() else {
            return (None, true);
        };
        let Some(kind) = object.get("kind").and_then(Value::as_str) else {
            return (None, true);
        };
        let mut omitted = false;
        let result = match kind {
            "solid" => {
                let Some(color) = sanitize_style_color(object.get("color")) else {
                    return (None, true);
                };
                serde_json::json!({"kind":"solid","color":color})
            }
            "gradient" => {
                let Some(gradient) = object.get("gradient").and_then(Value::as_object) else {
                    return (None, true);
                };
                let Some(kind) = gradient
                    .get("type")
                    .and_then(Value::as_str)
                    .filter(|value| matches!(*value, "linear" | "radial"))
                else {
                    return (None, true);
                };
                let Some(angle) =
                    safe_style_number(gradient.get("angleDegrees"), -36_000.0, 36_000.0)
                else {
                    return (None, true);
                };
                let Some(stops) = gradient.get("stops").and_then(Value::as_array) else {
                    return (None, true);
                };
                if !(2..=8).contains(&stops.len()) {
                    return (None, true);
                }
                let mut safe_stops = Vec::with_capacity(stops.len());
                for stop in stops {
                    let Some(stop) = stop.as_object() else {
                        return (None, true);
                    };
                    let Some(offset) = safe_style_number(stop.get("offset"), 0.0, 1.0) else {
                        return (None, true);
                    };
                    let Some(color) = sanitize_style_color(stop.get("color")) else {
                        return (None, true);
                    };
                    safe_stops.push(serde_json::json!({"offset":offset,"color":color}));
                    omitted |= stop
                        .keys()
                        .any(|key| !matches!(key.as_str(), "offset" | "color"));
                }
                omitted |= gradient
                    .keys()
                    .any(|key| !matches!(key.as_str(), "type" | "angleDegrees" | "stops"));
                serde_json::json!({"kind":"gradient","type":kind,"angleDegrees":angle,"stops":safe_stops})
            }
            "tile" => {
                let Some(tile) = object.get("tile").and_then(Value::as_object) else {
                    return (None, true);
                };
                let Some(pattern) = tile
                    .get("pattern")
                    .and_then(Value::as_str)
                    .filter(|value| matches!(*value, "dots" | "grid" | "checker" | "diagonal"))
                else {
                    return (None, true);
                };
                let Some(foreground) = sanitize_style_color(tile.get("foregroundColor")) else {
                    return (None, true);
                };
                let Some(background) = sanitize_style_color(tile.get("backgroundColor")) else {
                    return (None, true);
                };
                let (Some(scale), Some(spacing_x), Some(spacing_y), Some(opacity)) = (
                    safe_style_number(tile.get("scale"), 0.25, 4.0),
                    safe_style_number(tile.get("spacingX"), 0.0, 2.0),
                    safe_style_number(tile.get("spacingY"), 0.0, 2.0),
                    safe_style_number(tile.get("opacity"), 0.0, 1.0),
                ) else {
                    return (None, true);
                };
                let alignment = tile
                    .get("alignment")
                    .and_then(Value::as_str)
                    .filter(|value| {
                        matches!(
                            *value,
                            "topLeading"
                                | "top"
                                | "topTrailing"
                                | "leading"
                                | "center"
                                | "trailing"
                                | "bottomLeading"
                                | "bottom"
                                | "bottomTrailing"
                        )
                    })
                    .unwrap_or("topLeading");
                omitted |= tile.keys().any(|key| {
                    !matches!(
                        key.as_str(),
                        "pattern"
                            | "foregroundColor"
                            | "backgroundColor"
                            | "scale"
                            | "spacingX"
                            | "spacingY"
                            | "alignment"
                            | "opacity"
                    )
                });
                serde_json::json!({"kind":"tile","pattern":pattern,"foregroundColor":foreground,"backgroundColor":background,"scale":scale,"spacingX":spacing_x,"spacingY":spacing_y,"alignment":alignment,"opacity":opacity})
            }
            "image" => return (None, true),
            _ => return (None, true),
        };
        omitted |= object.keys().any(|key| match kind {
            "solid" => !matches!(key.as_str(), "kind" | "color"),
            "gradient" => !matches!(key.as_str(), "kind" | "gradient"),
            "tile" => !matches!(key.as_str(), "kind" | "tile"),
            _ => true,
        });
        return (Some(result), omitted);
    }
    match sanitize_style_color(color) {
        Some(color) => (
            Some(serde_json::json!({"kind":"solid","color":color})),
            false,
        ),
        None => (None, color.is_some()),
    }
}

fn sanitize_inline_appearance(
    value: Option<&Value>,
    redact: &impl Fn(&str) -> String,
) -> (Option<ControllerStyleAppearanceSnapshot>, bool) {
    let Some(value) = value else {
        return (None, false);
    };
    let Some(visual) = value.as_object() else {
        return (None, true);
    };
    let Some((normal, mut omitted)) = sanitize_style_state(visual.get("normal")) else {
        return (None, true);
    };
    let (pressed, pressed_omitted) = sanitize_optional_style_state(visual.get("pressed"));
    let (active, active_omitted) = sanitize_optional_style_state(visual.get("active"));
    let (disabled, disabled_omitted) = sanitize_optional_style_state(visual.get("disabled"));
    let (icon, icon_omitted) = sanitize_style_icon(visual.get("icon"), redact);
    let haptic_style = visual
        .get("hapticStyle")
        .and_then(Value::as_str)
        .filter(|value| {
            matches!(
                *value,
                "none" | "light" | "medium" | "heavy" | "soft" | "rigid"
            )
        })
        .map(str::to_owned);
    let (haptic, haptic_omitted) = sanitize_style_haptic(visual.get("hapticFeedback"));
    omitted |=
        pressed_omitted || active_omitted || disabled_omitted || icon_omitted || haptic_omitted;
    omitted |= visual.keys().any(|key| {
        !matches!(
            key.as_str(),
            "normal"
                | "pressed"
                | "active"
                | "disabled"
                | "icon"
                | "hapticStyle"
                | "hapticFeedback"
        )
    });
    (
        Some(ControllerStyleAppearanceSnapshot {
            normal,
            pressed,
            active,
            disabled,
            icon,
            haptic_style,
            haptic,
        }),
        omitted,
    )
}

fn sanitize_allowed_string(value: Option<&Value>, allowed: &[&str]) -> (Option<String>, bool) {
    let Some(value) = value else {
        return (None, false);
    };
    match value.as_str().filter(|value| allowed.contains(value)) {
        Some(value) => (Some(value.to_owned()), false),
        None => (None, true),
    }
}

fn sanitize_numeric_object(
    value: Option<&Value>,
    keys: &[&str],
    minimum: f64,
    maximum: f64,
) -> Option<Value> {
    let object = value?.as_object()?;
    if object.keys().any(|key| !keys.contains(&key.as_str())) {
        return None;
    }
    let mut safe = serde_json::Map::new();
    for key in keys {
        safe.insert(
            (*key).to_owned(),
            Value::from(safe_style_number(object.get(*key), minimum, maximum)?),
        );
    }
    Some(Value::Object(safe))
}

fn allowed_visual_role(value: &str) -> bool {
    matches!(
        value,
        "movement"
            | "primary_action"
            | "secondary_action"
            | "utility"
            | "menu"
            | "custom"
            | "joystick"
            | "trigger"
            | "trackpad"
            | "decoration"
            | "system"
    )
}

fn sanitize_joystick_mapping(value: Option<&Value>) -> (Option<Value>, bool) {
    sanitize_enum_object(
        value,
        &[
            ("up", ALLOWED_BUTTONS),
            ("down", ALLOWED_BUTTONS),
            ("left", ALLOWED_BUTTONS),
            ("right", ALLOWED_BUTTONS),
        ],
    )
}

fn sanitize_joystick_settings(value: Option<&Value>) -> (Option<Value>, bool) {
    let Some(value) = value else {
        return (None, false);
    };
    let Some(object) = value.as_object() else {
        return (None, true);
    };
    let Some(target) = object
        .get("analogTarget")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "none" | "left_stick" | "right_stick"))
    else {
        return (None, true);
    };
    let (
        Some(digital),
        Some(dead_zone),
        Some(sensitivity),
        Some(invert_x),
        Some(invert_y),
        Some(snap),
    ) = (
        object
            .get("sendsDigitalDirections")
            .and_then(Value::as_bool),
        safe_style_number(object.get("deadZone"), 0.0, 0.85),
        safe_style_number(object.get("sensitivity"), 0.2, 3.0),
        object.get("invertX").and_then(Value::as_bool),
        object.get("invertY").and_then(Value::as_bool),
        object.get("snapToCardinal").and_then(Value::as_bool),
    )
    else {
        return (None, true);
    };
    let omitted = object.keys().any(|key| {
        !matches!(
            key.as_str(),
            "analogTarget"
                | "sendsDigitalDirections"
                | "deadZone"
                | "sensitivity"
                | "invertX"
                | "invertY"
                | "snapToCardinal"
        )
    });
    (
        Some(
            serde_json::json!({"analogTarget":target,"sendsDigitalDirections":digital,"deadZone":dead_zone,"sensitivity":sensitivity,"invertX":invert_x,"invertY":invert_y,"snapToCardinal":snap}),
        ),
        omitted,
    )
}

fn sanitize_trigger_settings(value: Option<&Value>) -> (Option<Value>, bool) {
    let Some(value) = value else {
        return (None, false);
    };
    let Some(object) = value.as_object() else {
        return (None, true);
    };
    let Some(target) = object
        .get("target")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "left" | "right"))
    else {
        return (None, true);
    };
    let Some(orientation) = object
        .get("orientation")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "vertical" | "horizontal"))
    else {
        return (None, true);
    };
    let (Some(dead_zone), Some(sensitivity), Some(digital), Some(threshold)) = (
        safe_style_number(object.get("deadZone"), 0.0, 0.85),
        safe_style_number(object.get("sensitivity"), 0.2, 3.0),
        object.get("sendsDigitalButton").and_then(Value::as_bool),
        safe_style_number(object.get("digitalThreshold"), 0.01, 1.0),
    ) else {
        return (None, true);
    };
    let omitted = object.keys().any(|key| {
        !matches!(
            key.as_str(),
            "target"
                | "orientation"
                | "deadZone"
                | "sensitivity"
                | "sendsDigitalButton"
                | "digitalThreshold"
        )
    });
    (
        Some(
            serde_json::json!({"target":target,"orientation":orientation,"deadZone":dead_zone,"sensitivity":sensitivity,"sendsDigitalButton":digital,"digitalThreshold":threshold}),
        ),
        omitted,
    )
}

fn sanitize_trackpad_settings(value: Option<&Value>) -> (Option<Value>, bool) {
    let Some(value) = value else {
        return (None, false);
    };
    let Some(object) = value.as_object() else {
        return (None, true);
    };
    let (Some(sensitivity), Some(scroll), Some(tap), Some(two_finger), Some(natural)) = (
        safe_style_number(object.get("sensitivity"), 0.2, 4.0),
        safe_style_number(object.get("scrollSensitivity"), 0.1, 4.0),
        object.get("tapToClick").and_then(Value::as_bool),
        object.get("twoFingerScroll").and_then(Value::as_bool),
        object.get("naturalScrolling").and_then(Value::as_bool),
    ) else {
        return (None, true);
    };
    let omitted = object.keys().any(|key| {
        !matches!(
            key.as_str(),
            "sensitivity"
                | "scrollSensitivity"
                | "tapToClick"
                | "twoFingerScroll"
                | "naturalScrolling"
        )
    });
    (
        Some(
            serde_json::json!({"sensitivity":sensitivity,"scrollSensitivity":scroll,"tapToClick":tap,"twoFingerScroll":two_finger,"naturalScrolling":natural}),
        ),
        omitted,
    )
}

const ALLOWED_BUTTONS: &[&str] = &[
    "up", "down", "left", "right", "jump", "attack", "dash", "focus", "map", "pause", "custom1",
    "custom2", "custom3", "custom4", "custom5", "custom6", "custom7", "custom8",
];

fn sanitize_enum_object(
    value: Option<&Value>,
    fields: &[(&str, &[&str])],
) -> (Option<Value>, bool) {
    let Some(value) = value else {
        return (None, false);
    };
    let Some(object) = value.as_object() else {
        return (None, true);
    };
    if object
        .keys()
        .any(|key| !fields.iter().any(|(field, _)| key == field))
    {
        return (None, true);
    }
    let mut safe = serde_json::Map::new();
    for (field, allowed) in fields {
        let Some(value) = object
            .get(*field)
            .and_then(Value::as_str)
            .filter(|value| allowed.contains(value))
        else {
            return (None, true);
        };
        safe.insert((*field).to_owned(), Value::String(value.to_owned()));
    }
    (Some(Value::Object(safe)), false)
}

fn sanitize_element_outputs(
    element: &serde_json::Map<String, Value>,
) -> (Vec<ControllerElementOutputSnapshot>, bool) {
    let mut outputs = Vec::new();
    let mut omitted = false;
    if let Some(value) = element.get("output") {
        let (output, was_omitted) = sanitize_element_output("primary", value);
        omitted |= was_omitted;
        if let Some(output) = output {
            outputs.push(output)
        }
    }
    if let Some(parts) = element.get("partOutputs") {
        let Some(parts) = element_part_output_entries(parts) else {
            return (outputs, true);
        };
        for (part, value) in parts.iter().take(5) {
            if !matches!(
                *part,
                "joystick_up"
                    | "joystick_down"
                    | "joystick_left"
                    | "joystick_right"
                    | "trigger_digital"
            ) {
                omitted = true;
                continue;
            }
            let (output, was_omitted) = sanitize_element_output(part, value);
            omitted |= was_omitted;
            if let Some(output) = output {
                outputs.push(output)
            }
        }
        omitted |= parts.len() > 5;
    }
    (outputs, omitted)
}

fn element_part_output_entries(value: &Value) -> Option<Vec<(&str, &Value)>> {
    if let Some(object) = value.as_object() {
        return Some(
            object
                .iter()
                .map(|(key, value)| (key.as_str(), value))
                .collect(),
        );
    }
    let values = value.as_array()?;
    if values.len() % 2 != 0 {
        return None;
    }
    let mut entries = Vec::with_capacity(values.len() / 2);
    for pair in values.chunks_exact(2) {
        let key = pair[0].as_str()?;
        if entries.iter().any(|(existing, _)| *existing == key) {
            return None;
        }
        entries.push((key, &pair[1]));
    }
    Some(entries)
}

fn sanitize_element_output(
    part: &str,
    value: &Value,
) -> (Option<ControllerElementOutputSnapshot>, bool) {
    let Some(object) = value.as_object() else {
        return (None, true);
    };
    let (keyboard, keyboard_omitted) = sanitize_keyboard_binding(object.get("keyboard"));
    let mut omitted = keyboard_omitted
        || object
            .keys()
            .any(|key| !matches!(key.as_str(), "keyboard" | "gamepadButtons"));
    let gamepad_button = match object.get("gamepadButtons") {
        None => None,
        Some(Value::Array(values)) if values.len() == 1 => values[0]
            .as_str()
            .filter(|value| {
                matches!(
                    *value,
                    "south"
                        | "east"
                        | "west"
                        | "north"
                        | "leftShoulder"
                        | "rightShoulder"
                        | "leftTriggerButton"
                        | "rightTriggerButton"
                        | "select"
                        | "start"
                        | "home"
                        | "leftStickPress"
                        | "rightStickPress"
                        | "dpadUp"
                        | "dpadDown"
                        | "dpadLeft"
                        | "dpadRight"
                )
            })
            .map(str::to_owned),
        Some(Value::Array(values)) if values.is_empty() => None,
        Some(_) => {
            omitted = true;
            None
        }
    };
    if object.get("gamepadButtons").is_some()
        && gamepad_button.is_none()
        && object
            .get("gamepadButtons")
            .and_then(Value::as_array)
            .is_some_and(|values| !values.is_empty())
    {
        omitted = true;
    }
    if keyboard.is_empty() && gamepad_button.is_none() {
        return (None, omitted);
    }
    (
        Some(ControllerElementOutputSnapshot {
            part: part.to_owned(),
            keyboard,
            gamepad_button,
            unsupported_content_omitted: omitted,
        }),
        omitted,
    )
}

fn sanitize_keyboard_binding(
    value: Option<&Value>,
) -> (Vec<ControllerSemanticKeyStrokeSnapshot>, bool) {
    let Some(value) = value else {
        return (Vec::new(), false);
    };
    let Some(object) = value.as_object() else {
        return (Vec::new(), true);
    };
    let strokes: Vec<&Value> = object
        .get("sequence")
        .and_then(Value::as_array)
        .filter(|values| !values.is_empty())
        .map(|values| values.iter().take(32).collect())
        .unwrap_or_else(|| vec![value]);
    let mut result = Vec::with_capacity(strokes.len());
    for stroke in strokes {
        let Some(stroke) = stroke.as_object() else {
            return (Vec::new(), true);
        };
        let Some(code) = stroke
            .get("keyCode")
            .and_then(Value::as_u64)
            .and_then(|code| u16::try_from(code).ok())
        else {
            return (Vec::new(), true);
        };
        let Some(key) = semantic_key_name(code) else {
            return (Vec::new(), true);
        };
        let Some(mask) = stroke
            .get("modifiersRawValue")
            .and_then(Value::as_u64)
            .or(Some(0))
            .filter(|mask| *mask <= 15)
        else {
            return (Vec::new(), true);
        };
        let mut modifiers = Vec::new();
        for (bit, name) in [(1, "command"), (2, "shift"), (4, "option"), (8, "control")] {
            if mask & bit != 0 {
                modifiers.push(name.to_owned())
            }
        }
        result.push(ControllerSemanticKeyStrokeSnapshot {
            key: key.to_owned(),
            modifiers,
        });
    }
    let omitted = object
        .keys()
        .any(|key| !matches!(key.as_str(), "keyCode" | "modifiersRawValue" | "sequence"));
    (result, omitted)
}

#[derive(Clone)]
struct LayerSource {
    key: String,
    target_id: String,
    stable_id: String,
    label: String,
    kind: String,
    z_index: i32,
    is_hidden: bool,
    is_location_locked: bool,
    style_id: Option<String>,
}

fn resolved_layers(
    customization: &serde_json::Map<String, Value>,
    redact: &impl Fn(&str) -> String,
) -> Vec<ControllerLayerSnapshot> {
    let elements = customization
        .get("elements")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or_default();
    let mut sources = Vec::new();
    let top_bar_layout = customization
        .get("topBarActivationRegion")
        .and_then(Value::as_object);
    sources.push(LayerSource {
        key: "system:top_bar_activation".to_owned(),
        target_id: "system.top_bar_activation".to_owned(),
        stable_id: "system.top_bar_activation".to_owned(),
        label: "Control Bar Toggle".to_owned(),
        kind: "system".to_owned(),
        z_index: top_bar_layout
            .and_then(|layout| layout.get("zIndex"))
            .and_then(Value::as_i64)
            .unwrap_or(100)
            .clamp(-100, 100) as i32,
        is_hidden: layer_bool(top_bar_layout, "isHidden"),
        is_location_locked: layer_bool(top_bar_layout, "isLocationLocked"),
        style_id: layer_style_id(top_bar_layout),
    });

    for (index, button) in [
        "up", "down", "left", "right", "jump", "attack", "dash", "focus", "map", "pause",
    ]
    .into_iter()
    .enumerate()
    {
        let element = elements
            .iter()
            .take(MAXIMUM_CONTROLLER_SOURCE_ELEMENTS)
            .find_map(|value| {
                let object = value.as_object()?;
                (object.get("builtInButton").and_then(Value::as_str) == Some(button))
                    .then_some(object)
            });
        let layout = saved_button_layout(customization, button).or_else(|| {
            element
                .and_then(|element| element.get("layout"))
                .and_then(Value::as_object)
        });
        let fallback_id = format!("00000000-0000-0000-0000-{:012}", index + 101);
        let target_id = element
            .and_then(|element| element.get("id"))
            .and_then(Value::as_str)
            .filter(|id| valid_snapshot_identifier(id))
            .unwrap_or(&fallback_id)
            .to_owned();
        let label = element
            .and_then(|element| element.get("label"))
            .and_then(Value::as_str)
            .unwrap_or_else(|| default_label("button", Some(button)));
        sources.push(LayerSource {
            key: format!("builtin:{button}"),
            target_id,
            stable_id: format!("builtin.{button}"),
            label: label.to_owned(),
            kind: "button".to_owned(),
            z_index: layer_z_index(layout),
            is_hidden: layer_bool(layout, "isHidden"),
            is_location_locked: layer_bool(layout, "isLocationLocked"),
            style_id: layer_style_id(layout),
        });
    }

    for button in customization
        .get("customButtons")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .take(MAXIMUM_CONTROLLER_SOURCE_ELEMENTS)
    {
        let Some(button) = button.as_object() else {
            continue;
        };
        let Some(id) = button
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| valid_snapshot_identifier(id))
        else {
            continue;
        };
        let layout = button.get("layout").and_then(Value::as_object);
        let kind =
            allowed_kind(button.get("controlKind").and_then(Value::as_str)).unwrap_or("button");
        sources.push(LayerSource {
            key: format!("custom:{}", id.to_ascii_lowercase()),
            target_id: id.to_owned(),
            stable_id: format!("custom.{id}"),
            label: button
                .get("label")
                .and_then(Value::as_str)
                .unwrap_or_else(|| default_label(kind, None))
                .to_owned(),
            kind: kind.to_owned(),
            z_index: layer_z_index(layout),
            is_hidden: layer_bool(layout, "isHidden"),
            is_location_locked: layer_bool(layout, "isLocationLocked"),
            style_id: layer_style_id(layout),
        });
        if sources.len() >= MAXIMUM_CONTROLLER_SNAPSHOT_LAYERS {
            break;
        }
    }

    let source_by_key = sources
        .iter()
        .enumerate()
        .map(|(index, source)| (source.key.as_str(), index))
        .collect::<std::collections::BTreeMap<_, _>>();
    let mut seen = BTreeSet::new();
    let mut ordered_indices = Vec::with_capacity(sources.len());
    if let Some(saved) = customization
        .get("designMetadata")
        .and_then(|metadata| metadata.get("layerOrder"))
        .and_then(Value::as_array)
    {
        for identity in saved.iter().take(MAXIMUM_CONTROLLER_SOURCE_ELEMENTS) {
            let Some(key) = snapshot_layer_identity_key(identity) else {
                continue;
            };
            if seen.insert(key.clone()) {
                if let Some(index) = source_by_key.get(key.as_str()) {
                    ordered_indices.push(*index);
                }
            }
        }
    }
    for (index, source) in sources.iter().enumerate() {
        if seen.insert(source.key.clone()) {
            ordered_indices.push(index);
        }
    }
    ordered_indices.sort_by_key(|index| sources[*index].z_index);
    ordered_indices
        .into_iter()
        .take(MAXIMUM_CONTROLLER_SNAPSHOT_LAYERS)
        .map(|index| {
            let source = &sources[index];
            ControllerLayerSnapshot {
                target_id: redacted_bounded_string(
                    &source.target_id,
                    MAXIMUM_IDENTIFIER_CHARACTERS,
                    "unknown",
                    redact,
                ),
                stable_id: source.stable_id.clone(),
                label: redacted_bounded_string(
                    &source.label,
                    MAXIMUM_LABEL_CHARACTERS,
                    "Control",
                    redact,
                ),
                kind: source.kind.clone(),
                z_index: source.z_index,
                is_hidden: source.is_hidden,
                is_location_locked: source.is_location_locked,
                style_id: source.style_id.as_deref().map(|value| {
                    redacted_bounded_string(value, MAXIMUM_IDENTIFIER_CHARACTERS, "unknown", redact)
                }),
            }
        })
        .collect()
}

fn resolved_styles(
    customization: &serde_json::Map<String, Value>,
    redact: &impl Fn(&str) -> String,
) -> Vec<ControllerStyleSnapshot> {
    let Some(styles) = customization
        .get("styleLibrary")
        .and_then(|library| library.get("styles"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    styles
        .iter()
        .take(MAXIMUM_CONTROLLER_SNAPSHOT_STYLES)
        .filter_map(|value| sanitize_style(value, redact))
        .collect()
}

fn sanitize_style(
    value: &Value,
    redact: &impl Fn(&str) -> String,
) -> Option<ControllerStyleSnapshot> {
    let style = value.as_object()?;
    let id = style
        .get("id")?
        .as_str()
        .filter(|value| valid_snapshot_style_identifier(value))?;
    let name = style.get("name")?.as_str()?;
    let visual = style.get("visualStyle")?.as_object()?;
    let mut omitted = style
        .keys()
        .any(|key| !matches!(key.as_str(), "id" | "name" | "appliesTo" | "visualStyle"));
    let applies_to = style
        .get("appliesTo")
        .and_then(Value::as_array)
        .map(|values| {
            values
                .iter()
                .filter_map(Value::as_str)
                .filter(|value| {
                    matches!(
                        *value,
                        "button" | "decoration" | "joystick" | "text" | "trackpad" | "trigger"
                    )
                })
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default();
    let (normal, normal_omitted) = sanitize_style_state(visual.get("normal"))?;
    omitted |= normal_omitted;
    let (pressed, pressed_omitted) = sanitize_optional_style_state(visual.get("pressed"));
    let (active, active_omitted) = sanitize_optional_style_state(visual.get("active"));
    let (disabled, disabled_omitted) = sanitize_optional_style_state(visual.get("disabled"));
    omitted |= pressed_omitted || active_omitted || disabled_omitted;
    let (icon, icon_omitted) = sanitize_style_icon(visual.get("icon"), redact);
    omitted |= icon_omitted;
    let haptic_style = visual
        .get("hapticStyle")
        .and_then(Value::as_str)
        .filter(|value| {
            matches!(
                *value,
                "none" | "light" | "medium" | "heavy" | "soft" | "rigid"
            )
        })
        .map(str::to_owned);
    let (haptic, haptic_omitted) = sanitize_style_haptic(visual.get("hapticFeedback"));
    omitted |= haptic_omitted;
    omitted |= visual.keys().any(|key| {
        !matches!(
            key.as_str(),
            "normal"
                | "pressed"
                | "active"
                | "disabled"
                | "icon"
                | "hapticStyle"
                | "hapticFeedback"
        )
    });
    Some(ControllerStyleSnapshot {
        id: redacted_bounded_string(id, MAXIMUM_IDENTIFIER_CHARACTERS, "unknown", redact),
        name: redacted_bounded_string(name, 48, "Unnamed style", redact),
        applies_to,
        appearance: ControllerStyleAppearanceSnapshot {
            normal,
            pressed,
            active,
            disabled,
            icon,
            haptic_style,
            haptic,
        },
        unsupported_content_omitted: omitted,
    })
}

fn sanitize_optional_style_state(
    value: Option<&Value>,
) -> (Option<ControllerStyleStateSnapshot>, bool) {
    let Some(value) = value else {
        return (None, false);
    };
    match sanitize_style_state(Some(value)) {
        Some((state, omitted)) => (Some(state), omitted),
        None => (None, true),
    }
}

fn sanitize_style_state(value: Option<&Value>) -> Option<(ControllerStyleStateSnapshot, bool)> {
    let state = value?.as_object()?;
    let mut omitted = state.keys().any(|key| {
        !matches!(
            key.as_str(),
            "fillStyle"
                | "foregroundColor"
                | "strokeColor"
                | "strokeWidth"
                | "shadowColor"
                | "shadowRadius"
                | "shadowX"
                | "shadowY"
                | "shadows"
                | "glowColor"
                | "glowRadius"
                | "innerShadowColor"
                | "innerShadowRadius"
                | "innerShadowX"
                | "innerShadowY"
                | "highlightColor"
                | "highlightRadius"
                | "highlightX"
                | "highlightY"
                | "highlightOpacity"
                | "bevelHighlightColor"
                | "bevelShadowColor"
                | "bevelWidth"
                | "opacity"
                | "scale"
                | "blurRadius"
        )
    });
    let (sanitized_fill, fill_omitted) = sanitize_element_fill(state.get("fillStyle"), None);
    omitted |= fill_omitted;
    let fill_color = sanitized_fill
        .as_ref()
        .filter(|fill| fill.get("kind").and_then(Value::as_str) == Some("solid"))
        .and_then(|fill| sanitize_style_color(fill.get("color")));
    let fill =
        sanitized_fill.filter(|fill| fill.get("kind").and_then(Value::as_str) != Some("solid"));
    let mut shadows = Vec::new();
    if let Some(values) = state.get("shadows") {
        let Some(values) = values.as_array() else {
            omitted = true;
            return Some((ControllerStyleStateSnapshot::default(), omitted));
        };
        if values.len() > 8 {
            omitted = true;
        }
        for value in values.iter().take(8) {
            let Some(shadow) = value.as_object() else {
                omitted = true;
                continue;
            };
            let Some(color) = sanitize_style_color(shadow.get("color")) else {
                omitted = true;
                continue;
            };
            let (Some(radius), Some(x), Some(y)) = (
                safe_style_number(shadow.get("radius"), 0.0, 96.0),
                safe_style_number(shadow.get("x"), -96.0, 96.0),
                safe_style_number(shadow.get("y"), -96.0, 96.0),
            ) else {
                omitted = true;
                continue;
            };
            shadows.push(ControllerStyleShadowSnapshot {
                color,
                radius,
                x,
                y,
            });
        }
    }
    let snapshot = ControllerStyleStateSnapshot {
        fill,
        fill_color,
        foreground_color: sanitize_style_color(state.get("foregroundColor")),
        stroke_color: sanitize_style_color(state.get("strokeColor")),
        stroke_width: safe_style_number(state.get("strokeWidth"), 0.0, 12.0),
        shadow_color: sanitize_style_color(state.get("shadowColor")),
        shadow_radius: safe_style_number(state.get("shadowRadius"), 0.0, 64.0),
        shadow_x: safe_style_number(state.get("shadowX"), -64.0, 64.0),
        shadow_y: safe_style_number(state.get("shadowY"), -64.0, 64.0),
        shadows,
        glow_color: sanitize_style_color(state.get("glowColor")),
        glow_radius: safe_style_number(state.get("glowRadius"), 0.0, 64.0),
        inner_shadow_color: sanitize_style_color(state.get("innerShadowColor")),
        inner_shadow_radius: safe_style_number(state.get("innerShadowRadius"), 0.0, 64.0),
        inner_shadow_x: safe_style_number(state.get("innerShadowX"), -64.0, 64.0),
        inner_shadow_y: safe_style_number(state.get("innerShadowY"), -64.0, 64.0),
        highlight_color: sanitize_style_color(state.get("highlightColor")),
        highlight_radius: safe_style_number(state.get("highlightRadius"), 0.0, 64.0),
        highlight_x: safe_style_number(state.get("highlightX"), -64.0, 64.0),
        highlight_y: safe_style_number(state.get("highlightY"), -64.0, 64.0),
        highlight_opacity: safe_style_number(state.get("highlightOpacity"), 0.0, 1.0),
        bevel_highlight_color: sanitize_style_color(state.get("bevelHighlightColor")),
        bevel_shadow_color: sanitize_style_color(state.get("bevelShadowColor")),
        bevel_width: safe_style_number(state.get("bevelWidth"), 0.0, 24.0),
        opacity: safe_style_number(state.get("opacity"), 0.0, 1.0),
        scale: safe_style_number(state.get("scale"), 0.5, 1.5),
        blur_radius: safe_style_number(state.get("blurRadius"), 0.0, 24.0),
    };
    Some((snapshot, omitted))
}

fn sanitize_style_color(value: Option<&Value>) -> Option<ControllerStyleColorSnapshot> {
    let value = value?.as_object()?;
    let red = safe_style_number(value.get("red"), 0.0, 1.0)?;
    let green = safe_style_number(value.get("green"), 0.0, 1.0)?;
    let blue = safe_style_number(value.get("blue"), 0.0, 1.0)?;
    let alpha = safe_style_number(value.get("alpha"), 0.0, 1.0)?;
    Some(ControllerStyleColorSnapshot {
        red,
        green,
        blue,
        alpha,
    })
}

fn safe_style_number(value: Option<&Value>, minimum: f64, maximum: f64) -> Option<f64> {
    let value = value?.as_f64()?;
    (value.is_finite() && (minimum..=maximum).contains(&value)).then_some(value)
}

fn sanitize_style_icon(
    value: Option<&Value>,
    redact: &impl Fn(&str) -> String,
) -> (Option<ControllerStyleIconSnapshot>, bool) {
    let Some(value) = value else {
        return (None, false);
    };
    let Some(icon) = value.as_object() else {
        return (None, true);
    };
    let Some(source) = icon.get("source").and_then(Value::as_str) else {
        return (None, true);
    };
    if !matches!(source, "sf_symbol" | "text") {
        return (None, true);
    }
    let Some(raw_value) = icon.get("value").and_then(Value::as_str) else {
        return (None, true);
    };
    let placement = icon
        .get("placement")
        .and_then(Value::as_str)
        .filter(|value| {
            matches!(
                *value,
                "leading" | "trailing" | "top" | "bottom" | "center" | "background"
            )
        })
        .unwrap_or("center");
    let rendering_mode = icon
        .get("renderingMode")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "template" | "multicolor" | "original"))
        .unwrap_or("template");
    let scale = safe_style_number(icon.get("scale"), 0.2, 3.0).unwrap_or(1.0);
    (
        Some(ControllerStyleIconSnapshot {
            source: source.to_owned(),
            value: redacted_bounded_string(raw_value, 80, "icon", redact),
            placement: placement.to_owned(),
            scale,
            rendering_mode: rendering_mode.to_owned(),
            tint_color: sanitize_style_color(icon.get("tintColor")),
        }),
        icon.keys().any(|key| {
            !matches!(
                key.as_str(),
                "source" | "value" | "placement" | "scale" | "renderingMode" | "tintColor"
            )
        }),
    )
}

fn sanitize_style_haptic(value: Option<&Value>) -> (Option<ControllerStyleHapticSnapshot>, bool) {
    let Some(value) = value else {
        return (None, false);
    };
    let Some(haptic) = value.as_object() else {
        return (None, true);
    };
    let Some(style) = haptic.get("style").and_then(Value::as_str).filter(|value| {
        matches!(
            *value,
            "none" | "light" | "medium" | "heavy" | "soft" | "rigid"
        )
    }) else {
        return (None, true);
    };
    let Some(pattern) = haptic
        .get("pattern")
        .and_then(Value::as_str)
        .filter(|value| matches!(*value, "single" | "double" | "pulse" | "buzz"))
    else {
        return (None, true);
    };
    let (Some(intensity), Some(sharpness), Some(duration)) = (
        safe_style_number(haptic.get("intensity"), 0.0, 1.0),
        safe_style_number(haptic.get("sharpness"), 0.0, 1.0),
        safe_style_number(haptic.get("duration"), 0.02, 0.30),
    ) else {
        return (None, true);
    };
    (
        Some(ControllerStyleHapticSnapshot {
            style: style.to_owned(),
            pattern: pattern.to_owned(),
            intensity,
            sharpness,
            duration,
        }),
        haptic.keys().any(|key| {
            !matches!(
                key.as_str(),
                "style" | "pattern" | "intensity" | "sharpness" | "duration"
            )
        }),
    )
}

fn resolved_groups(
    customization: &serde_json::Map<String, Value>,
    layers: &[ControllerLayerSnapshot],
    redact: &impl Fn(&str) -> String,
) -> Vec<ControllerGroupSnapshot> {
    let layer_by_key = layers
        .iter()
        .filter_map(|layer| {
            snapshot_layer_identity_key(&Value::String(layer.stable_id.clone()))
                .map(|key| (key, layer))
        })
        .collect::<std::collections::BTreeMap<_, _>>();
    let Some(groups) = customization
        .get("designMetadata")
        .and_then(|metadata| metadata.get("groups"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    let mut seen_groups = BTreeSet::new();
    groups
        .iter()
        .take(MAXIMUM_CONTROLLER_SNAPSHOT_LAYERS)
        .filter_map(|group| {
            let group = group.as_object()?;
            let id = group
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| valid_snapshot_identifier(id))?;
            if !seen_groups.insert(id.to_ascii_lowercase()) {
                return None;
            }
            let mut seen_children = BTreeSet::new();
            let children = group.get("children").and_then(Value::as_array)?;
            let resolved = children
                .iter()
                .take(MAXIMUM_CONTROLLER_SNAPSHOT_LAYERS)
                .filter_map(|identity| {
                    let key = snapshot_layer_identity_key(identity)?;
                    if !seen_children.insert(key.clone()) {
                        return None;
                    }
                    layer_by_key.get(&key).copied()
                })
                .collect::<Vec<_>>();
            if resolved.is_empty() {
                return None;
            }
            Some(ControllerGroupSnapshot {
                id: id.to_owned(),
                name: redacted_bounded_string(
                    group.get("name").and_then(Value::as_str).unwrap_or("Group"),
                    48,
                    "Group",
                    redact,
                ),
                child_target_ids: resolved
                    .iter()
                    .map(|layer| layer.target_id.clone())
                    .collect(),
                child_stable_ids: resolved
                    .iter()
                    .map(|layer| layer.stable_id.clone())
                    .collect(),
                is_locked: group
                    .get("isLocked")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                is_hidden: group
                    .get("isHidden")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
            })
        })
        .collect()
}

fn saved_button_layout<'a>(
    customization: &'a serde_json::Map<String, Value>,
    button: &str,
) -> Option<&'a serde_json::Map<String, Value>> {
    let values = customization
        .get("buttonCustomizations")
        .and_then(Value::as_array)?;
    values.chunks_exact(2).find_map(|pair| {
        (pair[0].as_str() == Some(button))
            .then(|| pair[1].as_object())
            .flatten()
    })
}

fn layer_z_index(layout: Option<&serde_json::Map<String, Value>>) -> i32 {
    layout
        .and_then(|layout| layout.get("zIndex"))
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .clamp(-100, 100) as i32
}

fn layer_bool(layout: Option<&serde_json::Map<String, Value>>, key: &str) -> bool {
    layout
        .and_then(|layout| layout.get(key))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn layer_style_id(layout: Option<&serde_json::Map<String, Value>>) -> Option<String> {
    layout
        .and_then(|layout| layout.get("styleID"))
        .and_then(Value::as_str)
        .filter(|value| valid_snapshot_style_identifier(value))
        .map(str::to_owned)
}

fn valid_snapshot_style_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAXIMUM_RAW_STRING_BYTES
        && !value.starts_with(['.', '-'])
        && !value.ends_with(['.', '-'])
        && value
            .chars()
            .all(|character| character.is_alphanumeric() || matches!(character, '-' | '_' | '.'))
}

fn valid_snapshot_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAXIMUM_RAW_STRING_BYTES
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
}

fn snapshot_layer_identity_key(identity: &Value) -> Option<String> {
    if let Some(raw) = identity.as_str() {
        let lower = raw.to_ascii_lowercase();
        if let Some(button) = lower.strip_prefix("builtin.") {
            return Some(format!("builtin:{button}"));
        }
        if let Some(id) = lower.strip_prefix("custom.") {
            return Some(format!("custom:{id}"));
        }
        if let Some(system) = lower.strip_prefix("system.") {
            return Some(format!("system:{system}"));
        }
        return None;
    }
    let object = identity.as_object()?;
    match object.get("kind")?.as_str()? {
        "builtin" => Some(format!(
            "builtin:{}",
            object.get("button")?.as_str()?.to_ascii_lowercase()
        )),
        "custom" => Some(format!(
            "custom:{}",
            object.get("id")?.as_str()?.to_ascii_lowercase()
        )),
        "system" => Some(format!(
            "system:{}",
            object
                .get("system")
                .or_else(|| object.get("id"))?
                .as_str()?
                .to_ascii_lowercase()
        )),
        _ => None,
    }
}

fn resolved_canvas(
    customization: &serde_json::Map<String, Value>,
    orientation: ControllerOrientation,
    redact: &impl Fn(&str) -> String,
) -> ControllerCanvasSnapshot {
    let raw_frame_id = customization
        .get("deviceCanvas")
        .and_then(Value::as_object)
        .and_then(|canvas| canvas.get("frameID"))
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_FRAME_ID);
    let redacted_frame_id = if raw_frame_id.len() <= MAXIMUM_RAW_FRAME_ID_BYTES {
        redact(raw_frame_id)
    } else {
        DEFAULT_FRAME_ID.to_owned()
    };
    let (device_id, portrait_width, portrait_height) = device_dimensions(&redacted_frame_id)
        .unwrap_or_else(|| {
            (
                DEFAULT_DEVICE_ID.to_owned(),
                DEFAULT_PORTRAIT_WIDTH,
                DEFAULT_PORTRAIT_HEIGHT,
            )
        });
    let (width, height) = match orientation {
        ControllerOrientation::Landscape => (portrait_height, portrait_width),
        ControllerOrientation::Portrait => (portrait_width, portrait_height),
    };
    let (fill, fill_omitted) =
        sanitize_element_fill(customization.get("backgroundFillStyle"), None);
    let (light_fill, light_fill_omitted) = sanitize_element_fill(
        customization.get("backgroundLightFillStyle"),
        customization.get("backgroundLightColor"),
    );
    let (dark_fill, dark_fill_omitted) = sanitize_element_fill(
        customization.get("backgroundDarkFillStyle"),
        customization.get("backgroundDarkColor"),
    );
    let artwork_omitted = customization
        .get("artworkLayers")
        .and_then(Value::as_array)
        .is_some_and(|layers| !layers.is_empty());
    ControllerCanvasSnapshot {
        frame_id: format!("{device_id}-{}", orientation.as_str()),
        width,
        height,
        fill,
        light_fill,
        dark_fill,
        unsupported_content_omitted: fill_omitted
            || light_fill_omitted
            || dark_fill_omitted
            || artwork_omitted,
    }
}

fn canvas_orientation(customization: &serde_json::Map<String, Value>) -> ControllerOrientation {
    let frame_id = customization
        .get("deviceCanvas")
        .and_then(Value::as_object)
        .and_then(|canvas| canvas.get("frameID"))
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_FRAME_ID);
    if frame_id.len() > MAXIMUM_RAW_FRAME_ID_BYTES {
        return ControllerOrientation::Landscape;
    }
    let frame_id = frame_id.to_ascii_lowercase();
    if frame_id.ends_with("-portrait") || frame_id == "portrait" {
        ControllerOrientation::Portrait
    } else {
        ControllerOrientation::Landscape
    }
}

fn device_dimensions(frame_id: &str) -> Option<(String, f64, f64)> {
    let normalized = frame_id.trim().to_ascii_lowercase();
    let base = normalized
        .strip_suffix("-landscape")
        .or_else(|| normalized.strip_suffix("-portrait"))
        .unwrap_or(&normalized);
    if let Some(custom) = base.strip_prefix("custom-") {
        let (width, height) = custom.split_once('x')?;
        let width = width.parse::<f64>().ok()?.clamp(240.0, 1800.0);
        let height = height.parse::<f64>().ok()?.clamp(240.0, 1800.0);
        if !width.is_finite() || !height.is_finite() {
            return None;
        }
        return Some((
            format!(
                "custom-{}x{}",
                format_dimension(width.min(height)),
                format_dimension(width.max(height))
            ),
            width.min(height),
            width.max(height),
        ));
    }
    let dimensions = match base {
        "iphone-17-pro" | "iphone-17" | "iphone-16-pro" => (402.0, 874.0),
        "iphone-17-pro-max" | "iphone-16-pro-max" => (440.0, 956.0),
        "iphone-air" => (420.0, 912.0),
        "iphone-16" | "iphone-15-pro" | "iphone-15" | "iphone-14-pro" => (393.0, 852.0),
        "iphone-16-plus" | "iphone-15-pro-max" | "iphone-15-plus" | "iphone-14-pro-max" => {
            (430.0, 932.0)
        }
        "iphone-14-plus" | "iphone-13-pro-max" | "iphone-12-pro-max" => (428.0, 926.0),
        "iphone-17e" | "iphone-16e" | "iphone-14" | "iphone-13-pro" | "iphone-13"
        | "iphone-12-pro" | "iphone-12" => (390.0, 844.0),
        "iphone-se-3" | "iphone-se-2" => (375.0, 667.0),
        "iphone-13-mini" | "iphone-12-mini" | "iphone-11-pro" | "iphone-xs" => (375.0, 812.0),
        "iphone-11-pro-max" | "iphone-11" | "iphone-xr" | "iphone-xs-max" => (414.0, 896.0),
        _ => return None,
    };
    Some((
        bounded_string(base, MAXIMUM_IDENTIFIER_CHARACTERS, DEFAULT_DEVICE_ID),
        dimensions.0,
        dimensions.1,
    ))
}

fn base_size(
    kind: &str,
    mapped_button: &str,
    canvas_width: f64,
    canvas_height: f64,
    scale: f64,
) -> (f64, f64) {
    let landscape = canvas_width >= canvas_height;
    let shortest = canvas_width.min(canvas_height).max(1.0);
    match kind {
        "joystick" => {
            let side = (shortest * if landscape { 0.30 } else { 0.24 } * scale)
                .clamp(82.0 * scale, 128.0 * scale);
            (side, side)
        }
        "trigger" => (
            (shortest * if landscape { 0.30 } else { 0.24 } * scale)
                .clamp(86.0 * scale, 148.0 * scale),
            (shortest * if landscape { 0.11 } else { 0.09 } * scale)
                .clamp(34.0 * scale, 58.0 * scale),
        ),
        "trackpad" => (
            (shortest * if landscape { 0.48 } else { 0.42 } * scale)
                .clamp(142.0 * scale, 230.0 * scale),
            (shortest * if landscape { 0.28 } else { 0.24 } * scale)
                .clamp(92.0 * scale, 150.0 * scale),
        ),
        "text" => {
            let (width, height) = button_base_size("jump", shortest, landscape, scale);
            (width, (height * 0.58).max(24.0))
        }
        _ => button_base_size(mapped_button, shortest, landscape, scale),
    }
}

fn button_base_size(button: &str, shortest: f64, landscape: bool, scale: f64) -> (f64, f64) {
    let side =
        (shortest * if landscape { 0.24 } else { 0.20 } * scale).clamp(50.0 * scale, 86.0 * scale);
    match button {
        "map" => (side * 1.48, side * 0.72),
        "pause" => (side * 1.66, side * 0.72),
        _ => (side, side),
    }
}

fn default_normalized_center(
    button: &str,
    layout_mode: &str,
    width: f64,
    height: f64,
    canvas_width: f64,
    canvas_height: f64,
) -> (f64, f64) {
    let landscape = canvas_width >= canvas_height;
    let x_step = ((width * 1.12) / canvas_width).clamp(0.08, 0.18);
    let y_step = ((height * 1.12) / canvas_height).clamp(0.10, 0.26);
    if landscape {
        let dpad_x = if layout_mode == "southpaw" {
            0.82
        } else {
            0.18
        };
        let action_x = if layout_mode == "southpaw" {
            0.18
        } else {
            0.82
        };
        let y = 0.56;
        match button {
            "up" => (dpad_x, y - y_step),
            "down" => (dpad_x, y + y_step),
            "left" => (dpad_x - x_step, y),
            "right" => (dpad_x + x_step, y),
            "focus" => (action_x - x_step * 0.55, y - y_step * 0.55),
            "dash" => (action_x + x_step * 0.55, y - y_step * 0.55),
            "attack" => (action_x - x_step * 0.55, y + y_step * 0.55),
            "jump" => (action_x + x_step * 0.55, y + y_step * 0.55),
            "map" => (0.43, y),
            "pause" => (0.57, y),
            _ => (0.5, y),
        }
    } else {
        let dpad_y = if layout_mode == "southpaw" {
            0.74
        } else {
            0.28
        };
        let action_y = if layout_mode == "southpaw" {
            0.28
        } else {
            0.74
        };
        let portrait_x_step = ((width * 1.16) / canvas_width).clamp(0.13, 0.22);
        let portrait_y_step = ((height * 1.10) / canvas_height).clamp(0.08, 0.12);
        match button {
            "up" => (0.5, dpad_y - portrait_y_step),
            "down" => (0.5, dpad_y + portrait_y_step),
            "left" => (0.5 - portrait_x_step, dpad_y),
            "right" => (0.5 + portrait_x_step, dpad_y),
            "focus" => (
                0.5 - portrait_x_step * 0.55,
                action_y - portrait_y_step * 0.75,
            ),
            "dash" => (
                0.5 + portrait_x_step * 0.55,
                action_y - portrait_y_step * 0.75,
            ),
            "attack" => (
                0.5 - portrait_x_step * 0.55,
                action_y + portrait_y_step * 0.75,
            ),
            "jump" => (
                0.5 + portrait_x_step * 0.55,
                action_y + portrait_y_step * 0.75,
            ),
            "map" => (0.36, 0.51),
            "pause" => (0.64, 0.51),
            _ => (0.5, 0.51),
        }
    }
}

fn allow_orientation_preference(value: Option<&str>) -> &'static str {
    match value {
        Some("portrait") => "portrait",
        Some("landscape") => "landscape",
        _ => "automatic",
    }
}

fn control_scale_multiplier(value: Option<&str>) -> f64 {
    match value {
        Some("compact") => 0.86,
        Some("large") => 1.14,
        _ => 1.0,
    }
}

fn allowed_kind(value: Option<&str>) -> Option<&'static str> {
    match value? {
        "button" => Some("button"),
        "joystick" => Some("joystick"),
        "trigger" => Some("trigger"),
        "trackpad" => Some("trackpad"),
        "text" => Some("text"),
        "decoration" => Some("decoration"),
        _ => None,
    }
}

fn allowed_shape(value: Option<&str>) -> Option<&'static str> {
    match value? {
        "rounded_rectangle" => Some("rounded_rectangle"),
        "rectangle" => Some("rectangle"),
        "capsule" => Some("capsule"),
        "circle" => Some("circle"),
        "ellipse" => Some("ellipse"),
        "polygon" => Some("polygon"),
        "star" => Some("star"),
        _ => None,
    }
}

fn allowed_button(value: &str) -> Option<&str> {
    match value {
        "up" | "down" | "left" | "right" | "jump" | "attack" | "dash" | "focus" | "map"
        | "pause" | "custom1" | "custom2" | "custom3" | "custom4" | "custom5" | "custom6"
        | "custom7" | "custom8" => Some(value),
        _ => None,
    }
}

fn default_shape(kind: &str, mapped_button: Option<&str>) -> &'static str {
    match kind {
        "joystick" => "circle",
        "trigger" => "capsule",
        "trackpad" | "button" | "decoration" => {
            if matches!(mapped_button, Some("map" | "pause")) {
                "capsule"
            } else {
                "rounded_rectangle"
            }
        }
        "text" => "rectangle",
        _ => "rounded_rectangle",
    }
}

fn default_label(kind: &str, mapped_button: Option<&str>) -> &'static str {
    match mapped_button {
        Some("up") => "Up",
        Some("down") => "Down",
        Some("left") => "Left",
        Some("right") => "Right",
        Some("jump") => "Jump",
        Some("attack") => "Attack",
        Some("dash") => "Dash",
        Some("focus") => "Focus",
        Some("map") => "Map",
        Some("pause") => "Pause",
        _ => match kind {
            "joystick" => "Joystick",
            "trigger" => "Trigger",
            "trackpad" => "Trackpad",
            "text" => "Text",
            "decoration" => "Decoration",
            _ => "Button",
        },
    }
}

fn redacted_bounded_string(
    value: &str,
    maximum: usize,
    fallback: &str,
    redact: &impl Fn(&str) -> String,
) -> String {
    if value.len() > MAXIMUM_RAW_STRING_BYTES {
        return fallback.to_owned();
    }
    bounded_string(&redact(value), maximum, fallback)
}

fn bounded_string(value: &str, maximum: usize, fallback: &str) -> String {
    let trimmed = value.trim();
    let value = if trimmed.is_empty() {
        fallback
    } else {
        trimmed
    };
    value.chars().take(maximum).collect()
}

fn bounded_number(value: Option<&Value>, fallback: f64, minimum: f64, maximum: f64) -> f64 {
    bounded_optional_number(value, minimum, maximum).unwrap_or(fallback)
}

fn bounded_optional_number(value: Option<&Value>, minimum: f64, maximum: f64) -> Option<f64> {
    value
        .and_then(Value::as_f64)
        .filter(|value| value.is_finite())
        .map(|value| value.clamp(minimum, maximum))
}

fn normalized_rotation(value: f64) -> f64 {
    let normalized = value.rem_euclid(360.0);
    if normalized > 180.0 {
        normalized - 360.0
    } else {
        normalized
    }
}

fn format_dimension(value: f64) -> String {
    if value.fract().abs() < 0.001 {
        format!("{value:.0}")
    } else {
        format!("{value:.1}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{minimal_default_customization, PersistentState, TrustedClient};
    use serde_json::json;

    fn state_with_profile(profile: Value) -> PersistentState {
        let mut state = PersistentState::minimal("server").unwrap();
        let id = profile.get("id").unwrap().as_str().unwrap().to_owned();
        state.profiles = vec![profile];
        state.active_profile_id = id.clone();
        state.default_profile_id = id;
        state
    }

    #[test]
    fn minimal_profile_resolves_default_landscape_geometry_without_outputs() {
        let state = PersistentState::minimal("server").unwrap();
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.orientation, ControllerOrientation::Landscape);
        assert_eq!(snapshot.canvas.width, 874.0);
        assert_eq!(snapshot.canvas.height, 402.0);
        assert_eq!(snapshot.color_scheme_preference, "system");
        assert_eq!(snapshot.accent_style, "monochrome");
        assert!(snapshot.shows_button_labels);
        assert!(snapshot.canvas.fill.is_none());
        assert!(snapshot.canvas.light_fill.is_none());
        assert!(snapshot.canvas.dark_fill.is_none());
        assert!(!snapshot.canvas.unsupported_content_omitted);
        assert_eq!(snapshot.elements.len(), 10);
        assert_eq!(snapshot.layers.len(), 11);
        assert_eq!(snapshot.layers[0].stable_id, "builtin.up");
        assert_eq!(
            snapshot.layers[0].target_id,
            "00000000-0000-0000-0000-000000000101"
        );
        assert_eq!(
            snapshot.layers.last().unwrap().stable_id,
            "system.top_bar_activation"
        );
        assert!(snapshot.elements.iter().all(|element| {
            element.frame.x >= 0.0
                && element.frame.y >= 0.0
                && element.frame.x + element.frame.width <= snapshot.canvas.width
                && element.frame.y + element.frame.height <= snapshot.canvas.height
        }));
        let encoded = serde_json::to_string(&snapshot).unwrap();
        for forbidden in ["partOutputs", "keyCode", "modifiersRawValue", "authToken"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn appearance_snapshot_fields_decode_with_rolling_upgrade_defaults() {
        let snapshot = PersistentState::minimal("server")
            .unwrap()
            .controller_snapshot()
            .unwrap();
        let mut encoded = serde_json::to_value(snapshot).unwrap();
        let object = encoded.as_object_mut().unwrap();
        object.remove("colorSchemePreference");
        object.remove("accentStyle");
        object.remove("showsButtonLabels");
        object
            .get_mut("canvas")
            .and_then(Value::as_object_mut)
            .unwrap()
            .remove("unsupportedContentOmitted");
        let decoded: ControllerSnapshot = serde_json::from_value(encoded).unwrap();
        assert_eq!(decoded.color_scheme_preference, "system");
        assert_eq!(decoded.accent_style, "monochrome");
        assert!(decoded.shows_button_labels);
        assert!(!decoded.canvas.unsupported_content_omitted);
    }

    #[test]
    fn canvas_snapshot_preserves_safe_native_appearance_and_marks_omitted_artwork() {
        let secret = "private-background-asset";
        let mut customization = minimal_default_customization();
        customization["colorSchemePreference"] = json!("dark");
        customization["accentStyle"] = json!("purple");
        customization["showsButtonLabels"] = json!(false);
        customization["backgroundFillStyle"] = json!({
            "kind":"image",
            "image":{"assetID":secret,"path":"/tmp/private.png"}
        });
        customization["backgroundDarkFillStyle"] = json!({
            "kind":"gradient",
            "gradient":{
                "type":"linear","angleDegrees":35,
                "stops":[
                    {"offset":0,"color":{"red":0.02,"green":0.03,"blue":0.05,"alpha":1}},
                    {"offset":1,"color":{"red":0.12,"green":0.08,"blue":0.18,"alpha":1}}
                ]
            }
        });
        customization["artworkLayers"] = json!([{
            "id":"artwork","assetID":secret,"plane":"underlay"
        }]);
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Appearance",
            "customization":customization
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.color_scheme_preference, "dark");
        assert_eq!(snapshot.accent_style, "purple");
        assert!(!snapshot.shows_button_labels);
        assert!(snapshot.canvas.fill.is_none());
        assert_eq!(
            snapshot
                .canvas
                .dark_fill
                .as_ref()
                .and_then(|fill| fill.get("kind"))
                .and_then(Value::as_str),
            Some("gradient")
        );
        assert!(snapshot.canvas.unsupported_content_omitted);
        let encoded = serde_json::to_string(&snapshot.canvas).unwrap();
        assert!(!encoded.contains(secret));
        assert!(!encoded.contains("/tmp/private.png"));
        assert!(!encoded.contains("assetID"));
    }

    #[test]
    fn layout_quality_snapshot_is_bounded_typed_and_message_free() {
        let mut customization = minimal_default_customization();
        let elements = customization["elements"].as_array_mut().unwrap();
        for element in elements.iter_mut().take(2) {
            element["layout"] = json!({
                "centerX":0.01,"centerY":0.01,
                "widthScale":0.2,"heightScale":0.2,
                "path":"/tmp/private-layout"
            });
            element["label"] = json!("uncontrolled diagnostic text");
        }
        let state = state_with_profile(json!({
            "id":"00000000-0000-0000-0000-000000000511",
            "name":"Quality",
            "customization":customization
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert!(snapshot.layout_quality.issue_count > 0);
        assert!(snapshot.layout_quality.issues.len() <= MAXIMUM_CONTROLLER_SNAPSHOT_LAYOUT_ISSUES);
        assert!(snapshot.layout_quality.issues.iter().all(|issue| {
            matches!(issue.severity.as_str(), "error" | "warning" | "info")
                && issue.metric.is_none_or(f64::is_finite)
                && issue.control_ids.len() <= MAXIMUM_LAYOUT_ISSUE_CONTROL_IDS
                && issue.suggested_repairs.iter().all(|repair| {
                    matches!(
                        repair.as_str(),
                        "show-default-controls"
                            | "move-inside-safe-area"
                            | "minimum-touch-target"
                            | "resolve-overlap"
                            | "auto-arrange"
                            | "separate-expanded-hit-targets"
                            | "ergonomic-auto-arrange"
                    )
                })
        }));
        let encoded = serde_json::to_string(&snapshot.layout_quality).unwrap();
        assert!(!encoded.contains("message"));
        assert!(!encoded.contains("uncontrolled diagnostic text"));
        assert!(!encoded.contains("/tmp/private-layout"));
    }

    #[test]
    fn control_bar_snapshot_is_typed_ordered_and_redacts_unsupported_content() {
        let secret = "private-control-bar-asset";
        let mut customization = minimal_default_customization();
        customization["controlBarItems"] = json!(["settings", "launch_target", "settings"]);
        customization["controlBarItemCustomizations"] = json!([
            {
                "item":"settings",
                "appearance":{
                    "widthScale":1.5,"heightScale":1.2,"isHidden":true,
                    "shape":"capsule","accentStyle":"purple","shadowStrength":0.4,
                    "fillStyle":{"kind":"gradient","gradient":{
                        "type":"linear","angleDegrees":45,
                        "stops":[
                            {"offset":0,"color":{"red":0.1,"green":0.2,"blue":0.3,"alpha":1}},
                            {"offset":1,"color":{"red":0.8,"green":0.7,"blue":0.6,"alpha":1}}
                        ]
                    }},
                    "styleID":"safe-style",
                    "icon":{"source":"sf_symbol","value":"gearshape.fill","placement":"center","scale":1,"renderingMode":"template"},
                    "hapticFeedback":{"style":"rigid","pattern":"double","intensity":0.7,"sharpness":0.8,"duration":0.09}
                }
            },
            {
                "item":"launch_target",
                "appearance":{
                    "fillStyle":{"kind":"image","image":{"assetID":secret,"fileName":"/tmp/private.png"}},
                    "icon":{"source":"asset","value":secret},
                    "path":"/tmp/private.png"
                }
            }
        ]);
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Control Bar",
            "launchTarget":{"path":"/Applications/Secret.app","arguments":[secret]},
            "customization":customization
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.control_bar_items.len(), 2);
        let settings = &snapshot.control_bar_items[0];
        assert_eq!(settings.item, "settings");
        assert_eq!(settings.target_id, "control_bar_item.settings");
        assert_eq!(settings.index, 0);
        assert!(settings.is_hidden);
        assert_eq!(settings.width_scale, 1.5);
        assert_eq!(settings.height_scale, 1.2);
        assert_eq!(settings.shape.as_deref(), Some("capsule"));
        assert_eq!(settings.accent_style.as_deref(), Some("purple"));
        assert_eq!(settings.style_id.as_deref(), Some("safe-style"));
        assert_eq!(settings.icon.as_ref().unwrap().source, "sf_symbol");
        assert_eq!(settings.haptic.as_ref().unwrap().pattern, "double");
        assert!(!settings.unsupported_content_omitted);
        let launch = &snapshot.control_bar_items[1];
        assert_eq!(launch.item, "launch_target");
        assert!(launch.fill.is_none());
        assert!(launch.icon.is_none());
        assert!(launch.unsupported_content_omitted);
        let encoded = serde_json::to_string(&snapshot.control_bar_items).unwrap();
        for forbidden in [
            secret,
            "/tmp/private.png",
            "/Applications/Secret.app",
            "assetID",
        ] {
            assert!(!encoded.contains(forbidden), "{forbidden}");
        }
    }

    #[test]
    fn explicit_layout_is_bounded_and_hidden_or_unknown_elements_are_skipped() {
        let mut customization = minimal_default_customization();
        let elements = customization
            .get_mut("elements")
            .unwrap()
            .as_array_mut()
            .unwrap();
        elements[0]["layout"] = json!({
            "centerX": -5,
            "centerY": 9,
            "widthScale": 20,
            "heightScale": 0,
            "rotationDegrees": 725,
            "zIndex": 900,
            "shape": "star",
            "output": {"keyCode": 42}
        });
        elements[1]["layout"]["isHidden"] = json!(true);
        elements.push(json!({"id":"unknown","label":"Bad","kind":"shell","layout":{}}));
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Bounds",
            "customization":customization,
            "orientationPreference":"automatic",
            "output":{"keyCode":99}
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.elements.len(), 9);
        let first = snapshot
            .elements
            .iter()
            .find(|element| element.label == "Up")
            .unwrap();
        assert_eq!(first.shape, "star");
        assert_eq!(first.rotation_degrees, 5.0);
        assert_eq!(first.z_index, 100);
        assert!(first.frame.x >= 0.0);
        assert!(first.frame.y >= 0.0);
        assert!(first.frame.width <= snapshot.canvas.width);
        assert!(first.frame.height >= 1.0);
    }

    #[test]
    fn layer_snapshot_exposes_hidden_and_custom_targets_in_effective_z_order() {
        let mut customization = minimal_default_customization();
        customization["elements"][4]["layout"] = json!({"zIndex": 3, "isHidden": true});
        customization["customButtons"] = json!([{
            "id":"00000000-0000-0000-0000-000000000901",
            "mappedButton":"custom1",
            "label":"Hidden custom",
            "controlKind":"decoration",
            "layout":{"zIndex":-2,"isHidden":true,"isLocationLocked":true}
        }]);
        customization["elements"]
            .as_array_mut()
            .unwrap()
            .push(json!({
                "id":"00000000-0000-0000-0000-000000000901",
                "label":"Hidden custom",
                "kind":"decoration",
                "layout":{"zIndex":-2,"isHidden":true,"isLocationLocked":true},
                "legacySlot":"custom1",
                "partOutputs":[]
            }));
        customization["designMetadata"] = json!({
            "layerOrder":[
                {"kind":"builtin","button":"jump"},
                {"kind":"custom","id":"00000000-0000-0000-0000-000000000901"}
            ],
            "groups":[{
                "id":"00000000-0000-0000-0000-000000000902",
                "name":"Hidden pair",
                "children":[
                    {"kind":"builtin","button":"jump"},
                    {"kind":"custom","id":"00000000-0000-0000-0000-000000000901"}
                ],
                "isLocked":true,
                "isHidden":true
            }]
        });
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Layers",
            "customization":customization
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.layers.len(), 12);
        assert_eq!(
            snapshot.layers[0].stable_id,
            "custom.00000000-0000-0000-0000-000000000901"
        );
        assert!(snapshot.layers[0].is_hidden);
        assert!(snapshot.layers[0].is_location_locked);
        let jump = snapshot
            .layers
            .iter()
            .find(|layer| layer.stable_id == "builtin.jump")
            .unwrap();
        assert!(jump.is_hidden);
        assert_eq!(snapshot.groups.len(), 1);
        assert_eq!(snapshot.groups[0].name, "Hidden pair");
        assert_eq!(
            snapshot.groups[0].child_stable_ids,
            [
                "builtin.jump".to_owned(),
                "custom.00000000-0000-0000-0000-000000000901".to_owned()
            ]
        );
        assert!(snapshot.groups[0].is_hidden);
        assert!(snapshot.groups[0].is_locked);
        assert_eq!(jump.z_index, 3);
        let encoded = serde_json::to_string(&snapshot.layers).unwrap();
        for forbidden in ["output", "keyCode", "asset", "launchTarget"] {
            assert!(!encoded.contains(forbidden));
        }
    }

    #[test]
    fn style_snapshot_is_bounded_typed_and_omits_asset_content() {
        let secret = "private-asset-token";
        let mut customization = minimal_default_customization();
        customization["buttonCustomizations"] = json!([
            "jump", {
                "widthScale":1,"heightScale":1,"rotationDegrees":0,"zIndex":0,
                "shadowStrength":1,"isLocationLocked":false,"isHidden":false,
                "styleID":"safe-style"
            }
        ]);
        let mut styles = vec![
            json!({
                "id":"safe-style",
                "name":"Safe Style",
                "appliesTo":["button"],
                "visualStyle":{
                    "normal":{
                        "fillStyle":{"kind":"solid","color":{"red":0.1,"green":0.2,"blue":0.3,"alpha":1}},
                        "strokeWidth":2,
                        "shadows":[{"color":{"red":0,"green":0,"blue":0,"alpha":0.4},"radius":6,"x":2,"y":3}]
                    },
                    "pressed":{"scale":0.9},
                    "icon":{"source":"sf_symbol","value":"star.fill","placement":"center","scale":1,"renderingMode":"template"},
                    "hapticFeedback":{"style":"rigid","pattern":"double","intensity":0.7,"sharpness":0.8,"duration":0.1}
                }
            }),
            json!({
                "id":"gradient-style",
                "name":"Gradient Style",
                "appliesTo":["button"],
                "visualStyle":{
                    "normal":{
                        "fillStyle":{"kind":"gradient","gradient":{
                            "type":"linear","angleDegrees":90,
                            "stops":[
                                {"offset":0,"color":{"red":0.1,"green":0.2,"blue":0.3,"alpha":1}},
                                {"offset":1,"color":{"red":0.7,"green":0.8,"blue":0.9,"alpha":1}}
                            ]
                        }},
                        "shadowColor":{"red":0,"green":0,"blue":0,"alpha":0.5},
                        "shadowRadius":8,"shadowX":2,"shadowY":4
                    }
                }
            }),
            json!({
                "id":"unsafe-style",
                "name":"Unsafe Style",
                "visualStyle":{
                    "normal":{"fillStyle":{"kind":"image","image":{"assetID":secret,"path":"/tmp/private.png"}}},
                    "icon":{"source":"asset","value":secret}
                }
            }),
        ];
        for index in 0..70 {
            styles.push(json!({
                "id":format!("extra-{index}"),
                "name":format!("Extra {index}"),
                "visualStyle":{"normal":{"opacity":1}}
            }));
        }
        customization["styleLibrary"] = json!({"styles": styles});
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Styles",
            "customization":customization
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.styles.len(), MAXIMUM_CONTROLLER_SNAPSHOT_STYLES);
        let safe = snapshot
            .styles
            .iter()
            .find(|style| style.id == "safe-style")
            .unwrap();
        assert_eq!(safe.appearance.normal.stroke_width, Some(2.0));
        assert_eq!(safe.appearance.pressed.as_ref().unwrap().scale, Some(0.9));
        assert_eq!(safe.appearance.icon.as_ref().unwrap().source, "sf_symbol");
        assert!(!safe.unsupported_content_omitted);
        let gradient = snapshot
            .styles
            .iter()
            .find(|style| style.id == "gradient-style")
            .unwrap();
        assert_eq!(
            gradient
                .appearance
                .normal
                .fill
                .as_ref()
                .and_then(|fill| fill.get("kind"))
                .and_then(Value::as_str),
            Some("gradient")
        );
        assert_eq!(gradient.appearance.normal.shadow_radius, Some(8.0));
        assert_eq!(gradient.appearance.normal.shadow_x, Some(2.0));
        assert_eq!(gradient.appearance.normal.shadow_y, Some(4.0));
        assert!(!gradient.unsupported_content_omitted);
        let unsafe_style = snapshot
            .styles
            .iter()
            .find(|style| style.id == "unsafe-style")
            .unwrap();
        assert!(unsafe_style.unsupported_content_omitted);
        assert!(unsafe_style.appearance.normal.fill.is_none());
        assert!(unsafe_style.appearance.normal.fill_color.is_none());
        assert!(unsafe_style.appearance.icon.is_none());
        assert_eq!(
            snapshot
                .layers
                .iter()
                .find(|layer| layer.stable_id == "builtin.jump")
                .unwrap()
                .style_id
                .as_deref(),
            Some("safe-style")
        );
        let encoded = serde_json::to_string(&snapshot).unwrap();
        assert!(!encoded.contains(secret));
        assert!(!encoded.contains("/tmp/private.png"));
        assert!(!encoded.contains("assetID"));
    }

    #[test]
    fn element_snapshot_exposes_only_semantic_outputs_and_flags_unsupported_content() {
        let secret = "private-output-asset";
        let mut customization = minimal_default_customization();
        let jump = customization["elements"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|element| element.get("builtInButton").and_then(Value::as_str) == Some("jump"))
            .unwrap();
        jump["output"] = json!({
            "keyboard": {"keyCode": 13, "modifiersRawValue": 10},
            "gamepadButtons": ["south"],
            "path": "/tmp/private"
        });
        jump["partOutputs"] = json!({
            "trigger_digital": {"keyboard": {"keyCode": 65535}},
            "unknown_part": {"assetID": secret}
        });
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Semantic outputs",
            "customization":customization
        }));
        let snapshot = state.controller_snapshot().unwrap();
        let jump = snapshot
            .elements
            .iter()
            .find(|element| element.id == "00000000-0000-0000-0000-000000000105")
            .unwrap();
        assert_eq!(jump.outputs.len(), 1);
        assert_eq!(jump.outputs[0].part, "primary");
        assert_eq!(jump.outputs[0].keyboard[0].key, "W");
        assert_eq!(jump.outputs[0].keyboard[0].modifiers, ["shift", "control"]);
        assert_eq!(jump.outputs[0].gamepad_button.as_deref(), Some("south"));
        assert!(jump.outputs[0].unsupported_content_omitted);
        assert!(jump.unsupported_content_omitted);
        let encoded = serde_json::to_string(&snapshot).unwrap();
        for forbidden in [
            secret,
            "/tmp/private",
            "assetID",
            "keyCode",
            "modifiersRawValue",
            "65535",
        ] {
            assert!(!encoded.contains(forbidden), "{forbidden}");
        }
    }

    #[test]
    fn locked_portrait_uses_portrait_variant_and_canvas() {
        let mut portrait = minimal_default_customization();
        portrait["deviceCanvas"] = json!({"frameID":"iphone-15-pro-portrait"});
        portrait["elements"][0]["label"] = json!("Portrait Up");
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Both",
            "orientationPreference":"portrait",
            "customization":minimal_default_customization(),
            "portraitCustomization":portrait
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.orientation, ControllerOrientation::Portrait);
        assert_eq!(snapshot.canvas.frame_id, "iphone-15-pro-portrait");
        assert_eq!(snapshot.canvas.width, 393.0);
        assert_eq!(snapshot.canvas.height, 852.0);
        assert!(snapshot
            .elements
            .iter()
            .any(|element| element.label == "Portrait Up"));
    }

    #[test]
    fn custom_canvas_is_parsed_and_unknown_canvas_fails_closed() {
        let mut custom = minimal_default_customization();
        custom["deviceCanvas"] = json!({"frameID":"custom-500x1000-landscape"});
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Custom",
            "customization":custom
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.canvas.frame_id, "custom-500x1000-landscape");
        assert_eq!(snapshot.canvas.width, 1000.0);
        assert_eq!(snapshot.canvas.height, 500.0);

        let mut unknown = minimal_default_customization();
        unknown["deviceCanvas"] = json!({"frameID":"https://evil.invalid/frame"});
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Unknown",
            "customization":unknown
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.canvas.frame_id, DEFAULT_FRAME_ID);
        assert_eq!(snapshot.canvas.width, 874.0);
    }

    #[test]
    fn locked_orientation_canonicalizes_reused_and_fallback_frame_ids() {
        let mut primary = minimal_default_customization();
        primary["deviceCanvas"] = json!({"frameID":"iphone-15-pro-landscape"});
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Portrait fallback",
            "orientationPreference":"portrait",
            "customization":primary
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.orientation, ControllerOrientation::Portrait);
        assert_eq!(snapshot.canvas.frame_id, "iphone-15-pro-portrait");
        assert_eq!(
            (snapshot.canvas.width, snapshot.canvas.height),
            (393.0, 852.0)
        );

        let mut unknown = minimal_default_customization();
        unknown["deviceCanvas"] = json!({"frameID":"unknown-portrait"});
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"Unknown portrait",
            "orientationPreference":"portrait",
            "customization":unknown
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.canvas.frame_id, "iphone-17-pro-portrait");
        assert_eq!(
            (snapshot.canvas.width, snapshot.canvas.height),
            (402.0, 874.0)
        );
    }

    #[test]
    fn redaction_precedes_every_free_form_string_boundary() {
        let token = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-_";
        let profile_id = format!("{}{}", "p".repeat(100), token);
        let mut customization = minimal_default_customization();
        customization["deviceCanvas"] = json!({
            "frameID": format!("iphone-17-pro-{token}-landscape")
        });
        customization["elements"][0]["id"] = json!(format!("{}{}", "i".repeat(100), token));
        customization["elements"][0]["label"] = json!(format!("{}{}", "🕹️".repeat(20), token));
        let mut state = state_with_profile(json!({
            "id":profile_id,
            "name":format!("{}{}", "n".repeat(230), token),
            "customization":customization
        }));
        state.trusted_clients.insert(
            token.to_owned(),
            TrustedClient {
                name: "Boundary client".to_owned(),
                created_at: 0,
                last_seen_at: 0,
            },
        );
        let snapshot = state.controller_snapshot().unwrap();
        let encoded = serde_json::to_string(&snapshot).unwrap();
        assert!(encoded.contains("[REDACTED]"));
        assert!(!encoded.contains(token));
        assert!(!encoded.contains(&token[..32]));
    }

    #[test]
    fn malformed_source_scanning_and_raw_strings_are_independently_bounded() {
        let mut invalid_elements =
            vec![json!({"kind":"button"}); MAXIMUM_CONTROLLER_SOURCE_ELEMENTS];
        invalid_elements.push(json!({
            "id":"too-late",
            "label":"Must not be scanned",
            "kind":"button",
            "layout":{}
        }));
        let state = state_with_profile(json!({
            "id":"profile",
            "name":"x".repeat(MAXIMUM_RAW_STRING_BYTES + 1),
            "customization":{
                "deviceCanvas":{"frameID":"x".repeat(MAXIMUM_RAW_FRAME_ID_BYTES + 1)},
                "elements":invalid_elements
            }
        }));
        let snapshot = state.controller_snapshot().unwrap();
        assert_eq!(snapshot.profile.name, "Unnamed profile");
        assert_eq!(snapshot.canvas.frame_id, DEFAULT_FRAME_ID);
        assert!(snapshot.elements.is_empty());
    }
}
