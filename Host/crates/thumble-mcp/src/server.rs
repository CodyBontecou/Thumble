use crate::channel::SharedHostChannel;
use crate::rate_limit::PressRateLimiter;
use rmcp::{
    handler::server::{router::tool::ToolRouter, wrapper::Parameters},
    model::{
        Icon, Implementation, ListResourcesResult, MetaObject, PaginatedRequestParams,
        ReadResourceRequestParams, ReadResourceResponse, ReadResourceResult, Resource,
        ResourceContents, ServerCapabilities, ServerInfo,
    },
    schemars::{self, JsonSchema},
    service::RequestContext,
    tool, tool_handler, tool_router, ErrorData, Json, RoleServer, ServerHandler,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};
use thumble_core::ControllerSnapshot;
use thumble_host::control::{
    AccessibilityAction, ConfigurationDraftSummary, ControlRequest, ControlResponse, HostStatus,
};
const THUMBLE_ICON_URL: &str = "https://pocketpad-site.pages.dev/assets/app-icon.png?v=6eae962e";
const THUMBLE_WEBSITE_URL: &str = "https://pocketpad-site.pages.dev";

fn thumble_server_implementation() -> Implementation {
    Implementation::new("thumble-mcp", env!("CARGO_PKG_VERSION"))
        .with_title("Thumble MCP Controller")
        .with_description("Authenticated Thumble MCP connector for typed controller setup, preview, validation, and save; use MCP tools rather than Computer Use")
        .with_icons(vec![Icon::new(THUMBLE_ICON_URL)
            .with_mime_type("image/png")
            .with_sizes(vec!["1024x1024".to_owned()])])
        .with_website_url(THUMBLE_WEBSITE_URL)
}

use thumble_host::draft_operation::{
    ConfigurationAccentStyle, ConfigurationBackgroundEdit, ConfigurationBackgroundScope,
    ConfigurationColorScheme, ConfigurationControlBarItem, ConfigurationControlScale,
    ConfigurationGamepadButton, ConfigurationLayoutMode, ConfigurationOperation,
    ConfigurationOrientationPreference, ConfigurationOutputMode, ConfigurationRgbaColor,
    ConfigurationVariant, ControlAlignment, ControlBarItemChanges, ControlBarMoveDirection,
    ControlDistribution, ControllerTemplate, CustomizationChanges, ElementChanges,
    ElementCornerRadii, ElementFill, ElementGradientStop, ElementGradientType, ElementHitInsets,
    ElementInputPart, ElementJoystickAnalogTarget, ElementJoystickMapping, ElementJoystickSettings,
    ElementJoystickVisualStyle, ElementKind, ElementOutputChanges, ElementShape,
    ElementTileAlignment, ElementTilePattern, ElementTrackpadSettings, ElementTriggerOrientation,
    ElementTriggerSettings, ElementTriggerTarget, ElementVisualRole, GamepadOutputEdit,
    GeneratedProfileDestination, GenerationPreset, KeyboardOutputEdit, LayerMoveDestination,
    LayoutRepairCanvas, LayoutRepairKind, LayoutRepairTarget, OrientationVariant,
    SemanticKeyStroke, SemanticModifier, StyleAppearance, StyleHaptic, StyleHapticKind,
    StyleHapticPattern, StyleIcon, StyleIconSource, StyleMaterialPreset, StyleShadow,
};
use thumble_protocol::GameButton;

const CONTROLLER_UI_URI: &str = "ui://thumble/controller-builder-v1.html";
const CONTROLLER_UI_MIME_TYPE: &str = "text/html;profile=mcp-app";
const CONTROLLER_UI_HTML: &str = include_str!("../ui/controller-builder-v1.html");
const CONTROLLER_EDITOR_UI_URI: &str = "ui://thumble/controller-editor-v1.html";
const CONTROLLER_EDITOR_UI_HTML: &str = include_str!("../ui/controller-editor-v1.html");
const CONFIGURATION_OPERATION_SCHEMA_URI: &str = "thumble://schemas/configuration-operation-v1";
const CONFIGURATION_OPERATION_SCHEMA_JSON: &str =
    include_str!("../../../../docs/mcp/configuration-operation-v1.schema.json");
const CLI_CAPABILITIES_URI: &str = "thumble://capabilities/v1";
const CLI_CAPABILITIES_JSON: &str = include_str!("../../../../docs/mcp/cli-capabilities-v1.json");
const CONTROLLER_TEMPLATE_CATALOG_JSON: &str =
    include_str!("../../../../docs/mcp/controller-templates-v1.json");
const DEVICE_FRAME_CATALOG_JSON: &str = include_str!("../../../../docs/mcp/device-frames-v1.json");

fn controller_editor_ui_tool_meta() -> MetaObject {
    let value = serde_json::json!({
        "ui": {
            "resourceUri": CONTROLLER_EDITOR_UI_URI,
            "visibility": ["model", "app"]
        },
        "ui/resourceUri": CONTROLLER_EDITOR_UI_URI,
        "openai/outputTemplate": CONTROLLER_EDITOR_UI_URI
    });
    MetaObject(value.as_object().cloned().unwrap_or_default())
}

fn controller_ui_tool_meta() -> MetaObject {
    let value = serde_json::json!({
        "ui": {
            "resourceUri": CONTROLLER_UI_URI,
            "visibility": ["model", "app"]
        },
        "ui/resourceUri": CONTROLLER_UI_URI,
        "openai/outputTemplate": CONTROLLER_UI_URI
    });
    MetaObject(value.as_object().cloned().unwrap_or_default())
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct BonjourStatusResult {
    pub enabled: bool,
    pub registered: bool,
    pub state: String,
    pub service_name: String,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct CoreStatusResult {
    pub paired: bool,
    pub client_name: Option<String>,
    pub pairing_pending: bool,
    pub active_profile_id: String,
    pub default_profile_id: String,
    pub configuration_revision: u64,
    pub pressed_buttons: Vec<String>,
    pub pressed_elements: Vec<String>,
    pub status_text: String,
    pub counters: Value,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct OutputStatusResult {
    pub mode: String,
    pub events_executed: u64,
    pub held_key_count: usize,
    pub pending_key_release_count: usize,
    pub held_pointer_buttons: Vec<String>,
    pub pending_pointer_releases: Vec<String>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct HostStatusResult {
    pub running: bool,
    pub pid: u32,
    pub version: String,
    pub port: u16,
    pub bonjour: BonjourStatusResult,
    pub service_name: String,
    pub accessibility_trusted: bool,
    pub input_enabled: bool,
    pub configuration_write_enabled: bool,
    pub server_id: String,
    pub core: CoreStatusResult,
    pub output: OutputStatusResult,
}

impl HostStatusResult {
    fn from_host(status: HostStatus) -> Self {
        let pressed_buttons = status
            .core
            .pressed_buttons
            .iter()
            .filter_map(|button| serde_json::to_value(button).ok())
            .filter_map(|button| button.as_str().map(str::to_owned))
            .collect();
        Self {
            running: status.core.running,
            pid: status.pid,
            version: status.version,
            port: status.port,
            bonjour: BonjourStatusResult {
                enabled: status.bonjour.enabled,
                registered: status.bonjour.registered,
                state: status.bonjour.state,
                service_name: status.bonjour.service_name,
                error: status.bonjour.error,
            },
            service_name: status.service_name,
            accessibility_trusted: status.accessibility_trusted,
            input_enabled: status.input_enabled,
            configuration_write_enabled: status.configuration_write_enabled,
            server_id: status.server_id,
            core: CoreStatusResult {
                paired: status.core.paired,
                client_name: status.core.client_name,
                pairing_pending: status.core.pairing_pending,
                active_profile_id: status.core.active_profile_id,
                default_profile_id: status.core.default_profile_id,
                configuration_revision: status.core.configuration_revision,
                pressed_buttons,
                pressed_elements: status.core.pressed_elements,
                status_text: status.core.status_text,
                counters: serde_json::to_value(status.core.counters).unwrap_or(Value::Null),
            },
            output: OutputStatusResult {
                mode: status.output.mode,
                events_executed: status.output.events_executed,
                held_key_count: status.output.held_key_count,
                pending_key_release_count: status.output.pending_key_release_count,
                held_pointer_buttons: status.output.held_pointer_buttons,
                pending_pointer_releases: status.output.pending_pointer_releases,
            },
        }
    }
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct AccessibilityStatusResult {
    pub trusted: bool,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PairingCodeParams {
    /// Rotate the six-digit pairing code before returning it.
    #[serde(default)]
    pub rotate: Option<bool>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PairingCodeResult {
    pub pairing_code: String,
    pub rotated: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ProfileResult {
    pub id: String,
    pub name: String,
    pub active: bool,
    pub default: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ListProfilesResult {
    pub configuration_revision: u64,
    pub active_profile_id: String,
    pub profiles: Vec<ProfileResult>,
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum CatalogInput {
    ControllerTemplates,
    DeviceFrames,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QueryCatalogParams {
    pub catalog: CatalogInput,
    /// Optional exact template ID, valid only for controller-templates.
    pub template: Option<ControllerTemplateInput>,
    /// Optional exact checked-in frame ID, valid only for device-frames.
    #[serde(rename = "frameID")]
    pub frame_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ControllerTemplateCatalogEntry {
    pub id: String,
    pub name: String,
    pub description: String,
    pub revision: u32,
    #[serde(rename = "customElementIDCount")]
    pub custom_element_id_count: usize,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct ControllerTemplateCatalogManifest {
    schema: String,
    version: u32,
    templates: Vec<ControllerTemplateCatalogEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DeviceFrameCatalogEntry {
    pub id: String,
    pub device: String,
    pub orientation: String,
    pub width: f64,
    pub height: f64,
    pub frame_style: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct DeviceFrameCatalogManifest {
    schema: String,
    version: u32,
    frames: Vec<DeviceFrameCatalogEntry>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct QueryCatalogResult {
    pub catalog: String,
    pub version: u32,
    pub templates: Vec<ControllerTemplateCatalogEntry>,
    pub device_frames: Vec<DeviceFrameCatalogEntry>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct InstalledControlResult {
    pub control_id: String,
    pub label: String,
    pub kind: String,
    pub part: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ListControlsResult {
    pub configuration_revision: u64,
    pub active_profile_id: String,
    pub controls: Vec<InstalledControlResult>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerProfileResult {
    pub id: String,
    pub name: String,
    pub orientation_preference: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerCanvasResult {
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
    pub unsupported_content_omitted: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerFrameResult {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerElementResult {
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
    pub frame: ControllerFrameResult,
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
    pub thumb_fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub light_thumb_fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub dark_thumb_fill: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub joystick_visual_style: Option<String>,
    #[serde(rename = "styleID", skip_serializing_if = "Option::is_none")]
    pub style_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub inline_appearance: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub haptic: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub joystick_mapping: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub joystick_settings: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trigger_settings: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trackpad_settings: Option<Value>,
    pub outputs: Vec<Value>,
    pub unsupported_content_omitted: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerControlBarItemResult {
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
    pub inline_appearance: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub haptic: Option<Value>,
    pub unsupported_content_omitted: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerLayerResult {
    #[serde(rename = "targetID")]
    pub target_id: String,
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

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerStyleResult {
    pub id: String,
    pub name: String,
    pub applies_to: Vec<String>,
    /// Sanitized typed appearance containing only bounded colors, scalar effects, safe text/SF-symbol icons, and haptics.
    pub appearance: Value,
    pub unsupported_content_omitted: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerLayoutQualityIssueResult {
    pub code: String,
    pub severity: String,
    #[serde(rename = "controlIDs")]
    pub control_ids: Vec<String>,
    pub control_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub metric: Option<f64>,
    pub suggested_repairs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerLayoutQualityResult {
    pub issue_count: usize,
    pub error_count: usize,
    pub warning_count: usize,
    pub issues: Vec<ControllerLayoutQualityIssueResult>,
    pub omitted_issue_count: usize,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ControllerGroupResult {
    pub id: String,
    pub name: String,
    #[serde(rename = "childTargetIDs")]
    pub child_target_ids: Vec<String>,
    #[serde(rename = "childStableIDs")]
    pub child_stable_ids: Vec<String>,
    pub is_locked: bool,
    pub is_hidden: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct RenderControllerResult {
    pub configuration_revision: u64,
    pub profile: ControllerProfileResult,
    pub orientation: String,
    pub color_scheme_preference: String,
    pub accent_style: String,
    pub shows_button_labels: bool,
    pub canvas: ControllerCanvasResult,
    pub elements: Vec<ControllerElementResult>,
    pub control_bar_items: Vec<ControllerControlBarItemResult>,
    pub layers: Vec<ControllerLayerResult>,
    pub groups: Vec<ControllerGroupResult>,
    pub styles: Vec<ControllerStyleResult>,
    pub layout_quality: ControllerLayoutQualityResult,
}

impl RenderControllerResult {
    fn from_snapshot(snapshot: ControllerSnapshot, configuration_revision: u64) -> Self {
        Self {
            configuration_revision,
            profile: ControllerProfileResult {
                id: snapshot.profile.id,
                name: snapshot.profile.name,
                orientation_preference: snapshot.profile.orientation_preference,
            },
            orientation: snapshot.orientation.as_str().to_owned(),
            color_scheme_preference: snapshot.color_scheme_preference,
            accent_style: snapshot.accent_style,
            shows_button_labels: snapshot.shows_button_labels,
            canvas: ControllerCanvasResult {
                frame_id: snapshot.canvas.frame_id,
                width: snapshot.canvas.width,
                height: snapshot.canvas.height,
                fill: snapshot.canvas.fill,
                light_fill: snapshot.canvas.light_fill,
                dark_fill: snapshot.canvas.dark_fill,
                unsupported_content_omitted: snapshot.canvas.unsupported_content_omitted,
            },
            layout_quality: ControllerLayoutQualityResult {
                issue_count: snapshot.layout_quality.issue_count,
                error_count: snapshot.layout_quality.error_count,
                warning_count: snapshot.layout_quality.warning_count,
                omitted_issue_count: snapshot.layout_quality.omitted_issue_count,
                issues: snapshot
                    .layout_quality
                    .issues
                    .into_iter()
                    .map(|issue| ControllerLayoutQualityIssueResult {
                        code: issue.code,
                        severity: issue.severity,
                        control_ids: issue.control_ids,
                        control_count: issue.control_count,
                        metric: issue.metric,
                        suggested_repairs: issue.suggested_repairs,
                    })
                    .collect(),
            },
            styles: snapshot
                .styles
                .into_iter()
                .map(|style| ControllerStyleResult {
                    id: style.id,
                    name: style.name,
                    applies_to: style.applies_to,
                    appearance: serde_json::to_value(style.appearance)
                        .unwrap_or_else(|_| serde_json::json!({})),
                    unsupported_content_omitted: style.unsupported_content_omitted,
                })
                .collect(),
            control_bar_items: snapshot
                .control_bar_items
                .into_iter()
                .map(|item| ControllerControlBarItemResult {
                    item: item.item,
                    target_id: item.target_id,
                    index: item.index,
                    is_hidden: item.is_hidden,
                    width_scale: item.width_scale,
                    height_scale: item.height_scale,
                    shape: item.shape,
                    accent_style: item.accent_style,
                    corner_radius: item.corner_radius,
                    corner_radii: item.corner_radii,
                    shadow_strength: item.shadow_strength,
                    fill: item.fill,
                    light_fill: item.light_fill,
                    dark_fill: item.dark_fill,
                    style_id: item.style_id,
                    inline_appearance: item
                        .inline_appearance
                        .and_then(|value| serde_json::to_value(value).ok()),
                    icon: item.icon.and_then(|value| serde_json::to_value(value).ok()),
                    haptic: item
                        .haptic
                        .and_then(|value| serde_json::to_value(value).ok()),
                    unsupported_content_omitted: item.unsupported_content_omitted,
                })
                .collect(),
            groups: snapshot
                .groups
                .into_iter()
                .map(|group| ControllerGroupResult {
                    id: group.id,
                    name: group.name,
                    child_target_ids: group.child_target_ids,
                    child_stable_ids: group.child_stable_ids,
                    is_locked: group.is_locked,
                    is_hidden: group.is_hidden,
                })
                .collect(),
            layers: snapshot
                .layers
                .into_iter()
                .map(|layer| ControllerLayerResult {
                    target_id: layer.target_id,
                    stable_id: layer.stable_id,
                    label: layer.label,
                    kind: layer.kind,
                    z_index: layer.z_index,
                    is_hidden: layer.is_hidden,
                    is_location_locked: layer.is_location_locked,
                    style_id: layer.style_id,
                })
                .collect(),
            elements: snapshot
                .elements
                .into_iter()
                .map(|element| ControllerElementResult {
                    id: element.id,
                    label: element.label,
                    kind: element.kind,
                    mapped_button: element.mapped_button,
                    visual_role: element.visual_role,
                    accent_style: element.accent_style,
                    shape: element.shape,
                    frame: ControllerFrameResult {
                        x: element.frame.x,
                        y: element.frame.y,
                        width: element.frame.width,
                        height: element.frame.height,
                    },
                    center_x: element.center_x,
                    center_y: element.center_y,
                    width_scale: element.width_scale,
                    height_scale: element.height_scale,
                    rotation_degrees: element.rotation_degrees,
                    z_index: element.z_index,
                    is_hidden: element.is_hidden,
                    is_location_locked: element.is_location_locked,
                    shows_integrated_label: element.shows_integrated_label,
                    hit_insets: element.hit_insets,
                    corner_radius: element.corner_radius,
                    corner_radii: element.corner_radii,
                    shadow_strength: element.shadow_strength,
                    fill: element.fill,
                    light_fill: element.light_fill,
                    dark_fill: element.dark_fill,
                    thumb_fill: element
                        .thumb_fill
                        .and_then(|value| serde_json::to_value(value).ok()),
                    light_thumb_fill: element
                        .light_thumb_fill
                        .and_then(|value| serde_json::to_value(value).ok()),
                    dark_thumb_fill: element
                        .dark_thumb_fill
                        .and_then(|value| serde_json::to_value(value).ok()),
                    joystick_visual_style: element.joystick_visual_style,
                    style_id: element.style_id,
                    inline_appearance: element
                        .inline_appearance
                        .and_then(|value| serde_json::to_value(value).ok()),
                    icon: element
                        .icon
                        .and_then(|value| serde_json::to_value(value).ok()),
                    haptic: element
                        .haptic
                        .and_then(|value| serde_json::to_value(value).ok()),
                    joystick_mapping: element.joystick_mapping,
                    joystick_settings: element.joystick_settings,
                    trigger_settings: element.trigger_settings,
                    trackpad_settings: element.trackpad_settings,
                    outputs: element
                        .outputs
                        .into_iter()
                        .filter_map(|value| serde_json::to_value(value).ok())
                        .collect(),
                    unsupported_content_omitted: element.unsupported_content_omitted,
                })
                .collect(),
        }
    }
}

type PreviewColor = [f64; 4];

fn preview_color(value: Option<&Value>) -> Option<PreviewColor> {
    let color = value?.as_object()?;
    let channels = ["red", "green", "blue", "alpha"].map(|key| {
        color
            .get(key)
            .and_then(Value::as_f64)
            .filter(|value| value.is_finite() && (0.0..=1.0).contains(value))
    });
    Some([channels[0]?, channels[1]?, channels[2]?, channels[3]?])
}

fn preview_fill_representative(value: Option<&Value>) -> Option<PreviewColor> {
    let fill = value?.as_object()?;
    match fill.get("kind")?.as_str()? {
        "solid" => preview_color(fill.get("color")),
        "gradient" => {
            let gradient = fill
                .get("gradient")
                .and_then(Value::as_object)
                .unwrap_or(fill);
            let stops = gradient.get("stops")?.as_array()?;
            let colors = stops
                .iter()
                .filter_map(|stop| preview_color(stop.get("color")))
                .collect::<Vec<_>>();
            if colors.len() != stops.len() || colors.is_empty() {
                return None;
            }
            let divisor = colors.len() as f64;
            Some(colors.into_iter().fold([0.0; 4], |mut result, color| {
                for index in 0..4 {
                    result[index] += color[index] / divisor;
                }
                result
            }))
        }
        "tile" => {
            let tile = fill.get("tile").and_then(Value::as_object).unwrap_or(fill);
            let background = preview_color(tile.get("backgroundColor"))?;
            let foreground = preview_color(tile.get("foregroundColor"))?;
            let opacity = tile
                .get("opacity")
                .and_then(Value::as_f64)
                .filter(|value| value.is_finite() && (0.0..=1.0).contains(value))?;
            Some([
                background[0] * 0.72 + foreground[0] * 0.28,
                background[1] * 0.72 + foreground[1] * 0.28,
                background[2] * 0.72 + foreground[2] * 0.28,
                opacity,
            ])
        }
        _ => None,
    }
}

fn preview_selected_fill<'a>(
    fill: Option<&'a Value>,
    light_fill: Option<&'a Value>,
    dark_fill: Option<&'a Value>,
    dark: bool,
) -> Option<&'a Value> {
    if dark {
        dark_fill.or(fill)
    } else {
        light_fill.or(fill)
    }
}

fn preview_hex(red: u8, green: u8, blue: u8, alpha: f64) -> PreviewColor {
    [
        f64::from(red) / 255.0,
        f64::from(green) / 255.0,
        f64::from(blue) / 255.0,
        alpha,
    ]
}

fn preview_accent_fill(accent: &str, dark: bool) -> PreviewColor {
    match (accent, dark) {
        ("blue", true) => preview_hex(0x06, 0x19, 0x3a, 1.0),
        ("green", true) => preview_hex(0x00, 0x26, 0x08, 1.0),
        ("purple", true) => preview_hex(0x29, 0x0c, 0x33, 1.0),
        ("pink", true) => preview_hex(0x31, 0x0d, 0x1e, 1.0),
        ("blue", false) => preview_hex(0xf0, 0xf7, 0xff, 1.0),
        ("green", false) => preview_hex(0xec, 0xfd, 0xec, 1.0),
        ("purple", false) => preview_hex(0xfa, 0xf0, 0xff, 1.0),
        ("pink", false) => preview_hex(0xff, 0xe8, 0xf6, 1.0),
        (_, true) => preview_hex(0x1a, 0x1a, 0x1a, 1.0),
        (_, false) => preview_hex(0xf2, 0xf2, 0xf2, 1.0),
    }
}

fn preview_accent_foreground(accent: &str, dark: bool) -> PreviewColor {
    match (accent, dark) {
        ("blue", true) => preview_hex(0x47, 0xa8, 0xff, 1.0),
        ("green", true) => preview_hex(0x00, 0xca, 0x50, 1.0),
        ("purple", true) => preview_hex(0xc4, 0x72, 0xfb, 1.0),
        ("pink", true) => preview_hex(0xff, 0x4d, 0x8d, 1.0),
        ("blue", false) => preview_hex(0x00, 0x5f, 0xf2, 1.0),
        ("green", false) => preview_hex(0x10, 0x7d, 0x32, 1.0),
        ("purple", false) => preview_hex(0x7d, 0x00, 0xcc, 1.0),
        ("pink", false) => preview_hex(0xc4, 0x15, 0x62, 1.0),
        (_, true) => preview_hex(0xed, 0xed, 0xed, 1.0),
        (_, false) => preview_hex(0x17, 0x17, 0x17, 1.0),
    }
}

fn preview_accent_stroke(accent: &str, dark: bool) -> PreviewColor {
    match (accent, dark) {
        ("blue", true) => preview_hex(0x00, 0x36, 0x74, 1.0),
        ("green", true) => preview_hex(0x00, 0x46, 0x15, 1.0),
        ("purple", true) => preview_hex(0x54, 0x1a, 0x76, 1.0),
        ("pink", true) => preview_hex(0x5d, 0x0c, 0x34, 1.0),
        ("blue", false) => preview_hex(0xca, 0xe7, 0xff, 1.0),
        ("green", false) => preview_hex(0xb9, 0xf5, 0xbc, 1.0),
        ("purple", false) => preview_hex(0xf2, 0xd9, 0xff, 1.0),
        ("pink", false) => preview_hex(0xff, 0xd3, 0xe1, 1.0),
        (_, true) => preview_hex(0xff, 0xff, 0xff, 0.14),
        (_, false) => preview_hex(0x00, 0x00, 0x00, 0.08),
    }
}

fn preview_color_css(color: PreviewColor) -> String {
    format!(
        "rgba({:.0},{:.0},{:.0},{:.3})",
        color[0] * 255.0,
        color[1] * 255.0,
        color[2] * 255.0,
        color[3]
    )
}

fn preview_foreground(color: PreviewColor) -> PreviewColor {
    if 0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2] > 0.56 {
        [0.0, 0.0, 0.0, 1.0]
    } else {
        [1.0, 1.0, 1.0, 1.0]
    }
}

fn preview_stroke(color: PreviewColor) -> PreviewColor {
    [
        color[0] * 0.76,
        color[1] * 0.76,
        color[2] * 0.76,
        (color[3] + 0.14).clamp(0.32, 1.0),
    ]
}

fn preview_style_states<'a>(
    controller: &'a RenderControllerResult,
    element: &'a ControllerElementResult,
) -> Vec<&'a serde_json::Map<String, Value>> {
    let mut states = Vec::with_capacity(2);
    if let Some(style_id) = element.style_id.as_deref() {
        if let Some(normal) = controller
            .styles
            .iter()
            .find(|style| {
                style.id == style_id && style.applies_to.iter().any(|kind| kind == &element.kind)
            })
            .and_then(|style| style.appearance.get("normal"))
            .and_then(Value::as_object)
        {
            states.push(normal);
        }
    }
    if let Some(normal) = element
        .inline_appearance
        .as_ref()
        .and_then(|appearance| appearance.get("normal"))
        .and_then(Value::as_object)
    {
        states.push(normal);
    }
    states
}

fn controller_preview_svg(controller: &RenderControllerResult) -> Result<String, String> {
    let width = controller.canvas.width;
    let height = controller.canvas.height;
    if !width.is_finite() || !height.is_finite() || width <= 0.0 || height <= 0.0 {
        return Err("Thumble Host returned invalid preview dimensions".to_owned());
    }
    let dark = controller.color_scheme_preference != "light";
    let default_canvas = if dark {
        [0.0, 0.0, 0.0, 1.0]
    } else {
        [1.0, 1.0, 1.0, 1.0]
    };
    let canvas_fill = preview_fill_representative(preview_selected_fill(
        controller.canvas.fill.as_ref(),
        controller.canvas.light_fill.as_ref(),
        controller.canvas.dark_fill.as_ref(),
        dark,
    ))
    .unwrap_or(default_canvas);
    let mut svg = format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {width:.3} {height:.3}\" width=\"{width:.3}\" height=\"{height:.3}\" role=\"img\" aria-label=\"{} controller preview\"><title>{}</title><rect width=\"100%\" height=\"100%\" rx=\"24\" fill=\"{}\"/>",
        xml_escape(&controller.profile.name),
        xml_escape(&controller.profile.name),
        preview_color_css(canvas_fill)
    );
    for element in &controller.elements {
        let frame = &element.frame;
        let center_x = frame.x + frame.width / 2.0;
        let center_y = frame.y + frame.height / 2.0;
        let accent = element
            .accent_style
            .as_deref()
            .unwrap_or(&controller.accent_style);
        let explicit_fill = preview_fill_representative(preview_selected_fill(
            element.fill.as_ref(),
            element.light_fill.as_ref(),
            element.dark_fill.as_ref(),
            dark,
        ));
        let mut fill = explicit_fill.unwrap_or_else(|| preview_accent_fill(accent, dark));
        let mut foreground = explicit_fill.map_or_else(
            || preview_accent_foreground(accent, dark),
            preview_foreground,
        );
        let mut stroke =
            explicit_fill.map_or_else(|| preview_accent_stroke(accent, dark), preview_stroke);
        let mut stroke_width = 1.0;
        for state in preview_style_states(controller, element) {
            if let Some(next_fill) = preview_fill_representative(state.get("fill"))
                .or_else(|| preview_color(state.get("fillColor")))
            {
                fill = next_fill;
            }
            if let Some(color) = preview_color(state.get("foregroundColor")) {
                foreground = color;
            }
            if let Some(color) = preview_color(state.get("strokeColor")) {
                stroke = color;
            }
            if let Some(width) = state
                .get("strokeWidth")
                .and_then(Value::as_f64)
                .filter(|value| value.is_finite() && (0.0..=12.0).contains(value))
            {
                stroke_width = width;
            }
        }
        let fill_css = preview_color_css(fill);
        let stroke_css = preview_color_css(stroke);
        let foreground_css = preview_color_css(foreground);
        let transform = format!(
            "rotate({:.3} {:.3} {:.3})",
            element.rotation_degrees, center_x, center_y
        );
        svg.push_str(&format!(
            "<g transform=\"{transform}\" aria-label=\"{}\">",
            xml_escape(&element.label)
        ));
        let geometry = match element.shape.as_str() {
            "circle" | "ellipse" => format!(
                "<ellipse cx=\"{center_x:.3}\" cy=\"{center_y:.3}\" rx=\"{:.3}\" ry=\"{:.3}\" fill=\"{fill_css}\" stroke=\"{stroke_css}\" stroke-width=\"{stroke_width:.3}\"/>",
                frame.width / 2.0,
                frame.height / 2.0
            ),
            "polygon" | "star" => {
                let count = if element.shape == "star" { 10 } else { 3 };
                let mut points = Vec::with_capacity(count);
                for index in 0..count {
                    let radius = if element.shape == "star" && index % 2 == 1 {
                        0.45
                    } else {
                        1.0
                    };
                    let angle = std::f64::consts::TAU * index as f64 / count as f64
                        - std::f64::consts::FRAC_PI_2;
                    points.push(format!(
                        "{:.3},{:.3}",
                        center_x + angle.cos() * frame.width / 2.0 * radius,
                        center_y + angle.sin() * frame.height / 2.0 * radius
                    ));
                }
                format!(
                    "<polygon points=\"{}\" fill=\"{fill_css}\" stroke=\"{stroke_css}\" stroke-width=\"{stroke_width:.3}\"/>",
                    points.join(" ")
                )
            }
            _ => {
                let radius = element.corner_radius.unwrap_or_else(|| {
                    if element.shape == "capsule" {
                        frame.width.min(frame.height) / 2.0
                    } else if element.shape == "rectangle" {
                        0.0
                    } else {
                        frame.width.min(frame.height) * 0.15
                    }
                });
                format!(
                    "<rect x=\"{:.3}\" y=\"{:.3}\" width=\"{:.3}\" height=\"{:.3}\" rx=\"{radius:.3}\" fill=\"{fill_css}\" stroke=\"{stroke_css}\" stroke-width=\"{stroke_width:.3}\"/>",
                    frame.x, frame.y, frame.width, frame.height
                )
            }
        };
        svg.push_str(&geometry);
        if element.kind == "joystick" {
            let thumb = preview_color(if dark {
                element.dark_thumb_fill.as_ref()
            } else {
                element.light_thumb_fill.as_ref()
            })
            .or_else(|| preview_color(element.thumb_fill.as_ref()))
            .unwrap_or([
                foreground[0],
                foreground[1],
                foreground[2],
                if dark { 0.30 } else { 0.18 },
            ]);
            let ratio = if element.joystick_visual_style.as_deref() == Some("thumbstick") {
                0.72
            } else {
                0.34
            };
            svg.push_str(&format!(
                "<circle cx=\"{center_x:.3}\" cy=\"{center_y:.3}\" r=\"{:.3}\" fill=\"{}\" stroke=\"{}\" stroke-width=\"1\"/>",
                frame.width.min(frame.height) * ratio / 2.0,
                preview_color_css(thumb),
                preview_color_css(preview_stroke(thumb))
            ));
        }
        let label_characters = element.label.chars().count();
        let show_label = element.kind == "text"
            || (element.kind != "joystick"
                && element.kind != "decoration"
                && controller.shows_button_labels
                && element.shows_integrated_label);
        if show_label {
            let font_size = if element.kind == "text" {
                (frame.height * 0.72).max(10.0)
            } else if label_characters <= 2 {
                (frame.height * 0.55)
                    .min(frame.width / label_characters.max(1) as f64 * 0.72)
                    .clamp(10.0, 32.0)
            } else {
                (frame.height * 0.34)
                    .min(frame.width / label_characters.max(4) as f64 * 1.55)
                    .clamp(10.0, 16.0)
            };
            svg.push_str(&format!(
                "<text x=\"{center_x:.3}\" y=\"{center_y:.3}\" text-anchor=\"middle\" dominant-baseline=\"middle\" font-family=\"system-ui,sans-serif\" font-size=\"{font_size:.3}\" font-weight=\"700\" fill=\"{foreground_css}\">{}</text>",
                xml_escape(&element.label)
            ));
        }
        svg.push_str("</g>");
    }
    svg.push_str("</svg>");
    if svg.len() > 128 * 1024 {
        return Err("controller preview SVG exceeds the 128 KiB safety limit".to_owned());
    }
    Ok(svg)
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SelectProfileParams {
    /// Exact installed profile ID returned by list_profiles.
    pub profile_id: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SelectProfileResult {
    pub profile_id: String,
    pub changed: bool,
    pub configuration_revision: u64,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PressControlParams {
    /// Exact opaque control ID returned by list_controls.
    pub control_id: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PressControlResult {
    pub control_id: String,
    pub executed: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ReleaseAllResult {
    pub released: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ConfigurationStatusResult {
    pub configuration_revision: u64,
    pub profile_count: usize,
    pub active_profile_id: String,
    pub default_profile_id: String,
    pub maximum_live_drafts: usize,
    pub draft_lifetime_millis: i64,
    pub operation_schema_version: u32,
    pub bridge_available: bool,
    pub configuration_write_enabled: bool,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ConfigurationDraftResult {
    pub draft_id: String,
    pub base_configuration_revision: u64,
    pub draft_revision: u64,
    pub profile_count: usize,
    pub active_profile_id: String,
    pub default_profile_id: String,
    pub operation_count: usize,
    pub created_at: i64,
    pub updated_at: i64,
    pub expires_at: i64,
}

impl From<ConfigurationDraftSummary> for ConfigurationDraftResult {
    fn from(summary: ConfigurationDraftSummary) -> Self {
        Self {
            draft_id: summary.draft_id,
            base_configuration_revision: summary.base_configuration_revision,
            draft_revision: summary.draft_revision,
            profile_count: summary.profile_count,
            active_profile_id: summary.active_profile_id,
            default_profile_id: summary.default_profile_id,
            operation_count: summary.operation_count,
            created_at: summary.created_at,
            updated_at: summary.updated_at,
            expires_at: summary.expires_at,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BeginConfigurationDraftParams {
    /// Exact configuration revision returned by configuration_status.
    pub expected_configuration_revision: u64,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GetConfigurationDraftParams {
    /// Exact opaque draft ID returned by begin_configuration_draft.
    pub draft_id: String,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DiscardConfigurationDraftParams {
    /// Exact opaque draft ID returned by begin_configuration_draft.
    pub draft_id: String,
    /// Exact current draft revision returned by the latest draft operation.
    pub expected_draft_revision: u64,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct DiscardConfigurationDraftResult {
    pub draft_id: String,
    pub discarded: bool,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(tag = "type", deny_unknown_fields)]
pub enum ConfigurationOperationInput {
    #[serde(rename = "profile.rename")]
    ProfileRename {
        /// Exact profile UUID from list_profiles or the draft summary.
        #[serde(rename = "profileID")]
        profile_id: String,
        /// New display name, limited to 256 characters.
        name: String,
    },
    #[serde(rename = "element.add")]
    ElementAdd {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        /// Caller-generated UUID for deterministic retries and synchronized mirrors.
        #[serde(rename = "elementID")]
        element_id: String,
        kind: ElementKindInput,
        #[serde(rename = "mappedButton")]
        mapped_button: Option<GameButtonInput>,
        changes: Box<ElementChangesInput>,
    },
    #[serde(rename = "element.set")]
    ElementSet {
        /// Exact profile UUID containing the element.
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        /// Exact element ID returned by a controller preview.
        #[serde(rename = "elementID")]
        element_id: String,
        changes: Box<ElementChangesInput>,
    },
    #[serde(rename = "binding.set")]
    BindingSet {
        /// Exact profile UUID whose semantic button binding will change.
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButtonInput,
        /// One through 32 semantic key strokes. Numeric key codes are rejected.
        sequence: Vec<SemanticKeyStrokeInput>,
    },
    #[serde(rename = "binding.clear")]
    BindingClear {
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButtonInput,
    },
    #[serde(rename = "binding.reset")]
    BindingReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButtonInput,
    },
    #[serde(rename = "binding.reset-all")]
    BindingResetAll {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "output.mode")]
    OutputMode {
        #[serde(rename = "profileID")]
        profile_id: String,
        mode: ConfigurationOutputModeInput,
    },
    #[serde(rename = "output.set")]
    OutputSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButtonInput,
        #[serde(rename = "keyboardEdit")]
        keyboard_edit: KeyboardOutputEditInput,
        #[serde(rename = "gamepadEdit")]
        gamepad_edit: GamepadOutputEditInput,
    },
    #[serde(rename = "output.reset")]
    OutputReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButtonInput,
    },
    #[serde(rename = "output.reset-all")]
    OutputResetAll {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "profile.reset")]
    ProfileReset {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "customization.set")]
    CustomizationSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        changes: CustomizationChangesInput,
    },
    #[serde(rename = "customization.reset")]
    CustomizationReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
    },
    #[serde(rename = "customization.fix")]
    CustomizationFix {
        /// Exact profile UUID containing the layout variant to repair.
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        /// Deterministic suggested/all orchestration or one canonical repair.
        target: Box<LayoutRepairTargetInput>,
        /// Exactly one safe canvas source: stored, checked-in frame, or bounded size.
        canvas: Box<LayoutRepairCanvasInput>,
        /// Matches CLI --unlock/--include-locked.
        #[serde(rename = "includeLocked")]
        include_locked: bool,
    },
    #[serde(rename = "orientation.set")]
    OrientationSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        preference: ConfigurationOrientationPreferenceInput,
    },
    #[serde(rename = "device.set")]
    DeviceSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        /// Exact frame ID returned by query_catalog(device-frames); custom dimensions are rejected.
        #[serde(rename = "frameID")]
        frame_id: String,
    },
    #[serde(rename = "control-bar.set")]
    ControlBarSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        items: Vec<ConfigurationControlBarItemInput>,
    },
    #[serde(rename = "control-bar.add")]
    ControlBarAdd {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        item: ConfigurationControlBarItemInput,
    },
    #[serde(rename = "control-bar.remove")]
    ControlBarRemove {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        item: ConfigurationControlBarItemInput,
    },
    #[serde(rename = "control-bar.move")]
    ControlBarMove {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        item: ConfigurationControlBarItemInput,
        direction: ControlBarMoveDirectionInput,
    },
    #[serde(rename = "control-bar.item.set")]
    ControlBarItemSet {
        /// Exact profile UUID containing the selected control-bar variant.
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        /// One of the eight canonical control-bar items; it must already be present.
        item: ConfigurationControlBarItemInput,
        /// Nonempty, bounded, rendering-effective non-file appearance changes.
        changes: Box<ControlBarItemChangesInput>,
    },
    #[serde(rename = "style.create")]
    StyleCreate {
        #[serde(rename = "profileID")]
        profile_id: String,
        /// Canonical reusable style identifier using only letters, digits, dash, underscore, and period.
        #[serde(rename = "styleID")]
        style_id: String,
        /// Bounded display name.
        name: String,
        /// Complete typed non-file appearance. Raw style JSON and asset icons are rejected.
        appearance: Box<StyleAppearanceInput>,
    },
    #[serde(rename = "style.rename")]
    StyleRename {
        #[serde(rename = "profileID")]
        profile_id: String,
        #[serde(rename = "styleID")]
        style_id: String,
        name: String,
    },
    #[serde(rename = "style.apply")]
    StyleApply {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "styleID")]
        style_id: String,
        /// Exact preview element ID or stable built-in/custom/system control ID.
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "style.detach")]
    StyleDetach {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "style.delete")]
    StyleDelete {
        #[serde(rename = "profileID")]
        profile_id: String,
        #[serde(rename = "styleID")]
        style_id: String,
    },
    #[serde(rename = "layer.move")]
    LayerMove {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        /// Exact preview element ID or stable built-in/custom/system control ID.
        #[serde(rename = "elementID")]
        element_id: String,
        destination: LayerMoveDestinationInput,
    },
    #[serde(rename = "layer.forward")]
    LayerForward {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "layer.backward")]
    LayerBackward {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "layer.front")]
    LayerFront {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "layer.back")]
    LayerBack {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "group.create")]
    GroupCreate {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        /// Caller-generated group UUID for deterministic retries.
        #[serde(rename = "groupID")]
        group_id: String,
        name: String,
        /// Unique exact targets from the draft preview layer list.
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
    },
    #[serde(rename = "group.rename")]
    GroupRename {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
        name: String,
    },
    #[serde(rename = "group.duplicate")]
    GroupDuplicate {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
        /// Caller-generated UUID for the new group.
        #[serde(rename = "newGroupID")]
        new_group_id: String,
        /// Optional duplicate name; defaults to the source name plus “Copy”.
        name: Option<String>,
        /// Caller-generated UUIDs in exact source-child order, one for every child.
        #[serde(rename = "newElementIDs")]
        new_element_ids: Vec<String>,
        /// Optional normalized horizontal offset (-1 through 1), default 0.025.
        #[serde(rename = "offsetX")]
        #[schemars(range(min = -1.0, max = 1.0))]
        offset_x: Option<f64>,
        /// Optional normalized vertical offset (-1 through 1), default 0.025.
        #[serde(rename = "offsetY")]
        #[schemars(range(min = -1.0, max = 1.0))]
        offset_y: Option<f64>,
    },
    #[serde(rename = "group.ungroup")]
    GroupUngroup {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.hide")]
    GroupHide {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.show")]
    GroupShow {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.lock")]
    GroupLock {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.unlock")]
    GroupUnlock {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.nudge")]
    GroupNudge {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
        /// Optional exact frame ID from query_catalog(device-frames). Defaults to the standalone CLI's iPhone 17 Pro landscape canvas.
        #[serde(rename = "canvasFrameID")]
        canvas_frame_id: Option<String>,
        /// Requested horizontal movement in device-canvas points (-1000 through 1000).
        #[serde(rename = "deltaX")]
        #[schemars(range(min = -1000.0, max = 1000.0))]
        delta_x: f64,
        /// Requested vertical movement in device-canvas points (-1000 through 1000).
        #[serde(rename = "deltaY")]
        #[schemars(range(min = -1000.0, max = 1000.0))]
        delta_y: f64,
    },
    #[serde(rename = "group.forward")]
    GroupForward {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.backward")]
    GroupBackward {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.front")]
    GroupFront {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.back")]
    GroupBack {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "control-bar.reset")]
    ControlBarReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
    },
    #[serde(rename = "control-bar.item.reset")]
    ControlBarItemReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        item: ConfigurationControlBarItemInput,
    },
    #[serde(rename = "generation.generate")]
    GenerationGenerate {
        /// Canonical built-in generation preset.
        preset: GenerationPresetInput,
        /// Exact installed preset revision. Hollow Knight is revision 2 (thumb-sized controls).
        #[serde(rename = "presetRevision")]
        preset_revision: u32,
        destination: GeneratedProfileDestinationInput,
        /// Exactly four unique caller-generated UUIDs for Hollow Knight custom controls.
        #[serde(rename = "newElementIDs")]
        new_element_ids: Vec<String>,
        select: bool,
        #[serde(rename = "makeDefault")]
        make_default: bool,
    },
    #[serde(rename = "template.install")]
    TemplateInstall {
        template: ControllerTemplateInput,
        /// Exact installed template revision. SNES is revision 2; all others are revision 1.
        #[serde(rename = "templateRevision")]
        template_revision: u32,
        destination: GeneratedProfileDestinationInput,
        /// Optional bounded override for the installed profile display name.
        name: Option<String>,
        /// Exact caller-generated UUID list required by this template.
        #[serde(rename = "newElementIDs")]
        new_element_ids: Vec<String>,
        select: bool,
        #[serde(rename = "makeDefault")]
        make_default: bool,
    },
    #[serde(rename = "profile.select")]
    ProfileSelect {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "profile.default")]
    ProfileSetDefault {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "profile.duplicate")]
    ProfileDuplicate {
        #[serde(rename = "profileID")]
        profile_id: String,
        /// Caller-generated UUID for deterministic retry behavior.
        #[serde(rename = "newProfileID")]
        new_profile_id: String,
        name: String,
    },
    #[serde(rename = "profile.delete")]
    ProfileDelete {
        #[serde(rename = "profileID")]
        profile_id: String,
        /// Caller-generated UUID required only when deleting the final profile.
        #[serde(rename = "replacementProfileID")]
        replacement_profile_id: Option<String>,
    },
    #[serde(rename = "profile.move")]
    ProfileMove {
        #[serde(rename = "profileID")]
        profile_id: String,
        index: usize,
    },
    #[serde(rename = "profile.create")]
    ProfileCreate {
        name: String,
        /// Caller-generated UUID for deterministic retry behavior.
        #[serde(rename = "newProfileID")]
        new_profile_id: String,
        #[serde(rename = "sourceProfileID")]
        source_profile_id: Option<String>,
        select: bool,
        #[serde(rename = "makeDefault")]
        make_default: bool,
    },
    #[serde(rename = "theme.apply")]
    ThemeApply {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        /// Allowlisted built-in theme name or alias.
        preset: String,
    },
    #[serde(rename = "orientation.copy")]
    OrientationCopy {
        #[serde(rename = "profileID")]
        profile_id: String,
        source: OrientationVariantInput,
        destination: OrientationVariantInput,
        #[serde(rename = "automaticallyArrange")]
        automatically_arrange: bool,
    },
    #[serde(rename = "element.duplicate")]
    ElementDuplicate {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
        /// Caller-generated UUIDs, one per source element, for deterministic retries.
        #[serde(rename = "newElementIDs")]
        new_element_ids: Vec<String>,
        #[serde(rename = "offsetX")]
        offset_x: f64,
        #[serde(rename = "offsetY")]
        offset_y: f64,
    },
    #[serde(rename = "element.align")]
    ElementAlign {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
        alignment: ControlAlignmentInput,
    },
    #[serde(rename = "element.distribute")]
    ElementDistribute {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
        distribution: ControlDistributionInput,
    },
    #[serde(rename = "element.nudge")]
    ElementNudge {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
        #[serde(rename = "deltaX")]
        delta_x: f64,
        #[serde(rename = "deltaY")]
        delta_y: f64,
    },
    #[serde(rename = "element.delete")]
    ElementDelete {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "element.reset")]
    ElementReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariantInput,
        #[serde(rename = "elementID")]
        element_id: String,
    },
}

impl From<ConfigurationOperationInput> for ConfigurationOperation {
    fn from(input: ConfigurationOperationInput) -> Self {
        match input {
            ConfigurationOperationInput::ProfileRename { profile_id, name } => {
                Self::ProfileRename { profile_id, name }
            }
            ConfigurationOperationInput::ElementAdd {
                profile_id,
                variant,
                element_id,
                kind,
                mapped_button,
                changes,
            } => Self::ElementAdd {
                profile_id,
                variant: variant.into(),
                element_id,
                kind: kind.into(),
                mapped_button: mapped_button.map(Into::into),
                changes: Box::new((*changes).into()),
            },
            ConfigurationOperationInput::ElementSet {
                profile_id,
                variant,
                element_id,
                changes,
            } => Self::ElementSet {
                profile_id,
                variant: variant.into(),
                element_id,
                changes: Box::new((*changes).into()),
            },
            ConfigurationOperationInput::BindingSet {
                profile_id,
                button,
                sequence,
            } => Self::BindingSet {
                profile_id,
                button: button.into(),
                sequence: sequence.into_iter().map(Into::into).collect(),
            },
            ConfigurationOperationInput::BindingClear { profile_id, button } => {
                Self::BindingClear {
                    profile_id,
                    button: button.into(),
                }
            }
            ConfigurationOperationInput::BindingReset { profile_id, button } => {
                Self::BindingReset {
                    profile_id,
                    button: button.into(),
                }
            }
            ConfigurationOperationInput::BindingResetAll { profile_id } => {
                Self::BindingResetAll { profile_id }
            }
            ConfigurationOperationInput::OutputMode { profile_id, mode } => Self::OutputMode {
                profile_id,
                mode: mode.into(),
            },
            ConfigurationOperationInput::OutputSet {
                profile_id,
                button,
                keyboard_edit,
                gamepad_edit,
            } => Self::OutputSet {
                profile_id,
                button: button.into(),
                keyboard_edit: keyboard_edit.into(),
                gamepad_edit: gamepad_edit.into(),
            },
            ConfigurationOperationInput::OutputReset { profile_id, button } => Self::OutputReset {
                profile_id,
                button: button.into(),
            },
            ConfigurationOperationInput::OutputResetAll { profile_id } => {
                Self::OutputResetAll { profile_id }
            }
            ConfigurationOperationInput::ProfileReset { profile_id } => {
                Self::ProfileReset { profile_id }
            }
            ConfigurationOperationInput::CustomizationSet {
                profile_id,
                variant,
                changes,
            } => Self::CustomizationSet {
                profile_id,
                variant: variant.into(),
                changes: changes.into(),
            },
            ConfigurationOperationInput::CustomizationReset {
                profile_id,
                variant,
            } => Self::CustomizationReset {
                profile_id,
                variant: variant.into(),
            },
            ConfigurationOperationInput::CustomizationFix {
                profile_id,
                variant,
                target,
                canvas,
                include_locked,
            } => Self::CustomizationFix {
                profile_id,
                variant: variant.into(),
                target: Box::new((*target).into()),
                canvas: Box::new((*canvas).into()),
                include_locked,
            },
            ConfigurationOperationInput::OrientationSet {
                profile_id,
                preference,
            } => Self::OrientationSet {
                profile_id,
                preference: preference.into(),
            },
            ConfigurationOperationInput::DeviceSet {
                profile_id,
                variant,
                frame_id,
            } => Self::DeviceSet {
                profile_id,
                variant: variant.into(),
                frame_id,
            },
            ConfigurationOperationInput::ControlBarSet {
                profile_id,
                variant,
                items,
            } => Self::ControlBarSet {
                profile_id,
                variant: variant.into(),
                items: items.into_iter().map(Into::into).collect(),
            },
            ConfigurationOperationInput::ControlBarAdd {
                profile_id,
                variant,
                item,
            } => Self::ControlBarAdd {
                profile_id,
                variant: variant.into(),
                item: item.into(),
            },
            ConfigurationOperationInput::ControlBarRemove {
                profile_id,
                variant,
                item,
            } => Self::ControlBarRemove {
                profile_id,
                variant: variant.into(),
                item: item.into(),
            },
            ConfigurationOperationInput::ControlBarMove {
                profile_id,
                variant,
                item,
                direction,
            } => Self::ControlBarMove {
                profile_id,
                variant: variant.into(),
                item: item.into(),
                direction: direction.into(),
            },
            ConfigurationOperationInput::ControlBarItemSet {
                profile_id,
                variant,
                item,
                changes,
            } => Self::ControlBarItemSet {
                profile_id,
                variant: variant.into(),
                item: item.into(),
                changes: Box::new((*changes).into()),
            },
            ConfigurationOperationInput::StyleCreate {
                profile_id,
                style_id,
                name,
                appearance,
            } => Self::StyleCreate {
                profile_id,
                style_id,
                name,
                appearance: Box::new((*appearance).into()),
            },
            ConfigurationOperationInput::StyleRename {
                profile_id,
                style_id,
                name,
            } => Self::StyleRename {
                profile_id,
                style_id,
                name,
            },
            ConfigurationOperationInput::StyleApply {
                profile_id,
                variant,
                style_id,
                element_id,
            } => Self::StyleApply {
                profile_id,
                variant: variant.into(),
                style_id,
                element_id,
            },
            ConfigurationOperationInput::StyleDetach {
                profile_id,
                variant,
                element_id,
            } => Self::StyleDetach {
                profile_id,
                variant: variant.into(),
                element_id,
            },
            ConfigurationOperationInput::StyleDelete {
                profile_id,
                style_id,
            } => Self::StyleDelete {
                profile_id,
                style_id,
            },
            ConfigurationOperationInput::LayerMove {
                profile_id,
                variant,
                element_id,
                destination,
            } => Self::LayerMove {
                profile_id,
                variant: variant.into(),
                element_id,
                destination: destination.into(),
            },
            ConfigurationOperationInput::LayerForward {
                profile_id,
                variant,
                element_id,
            } => Self::LayerForward {
                profile_id,
                variant: variant.into(),
                element_id,
            },
            ConfigurationOperationInput::LayerBackward {
                profile_id,
                variant,
                element_id,
            } => Self::LayerBackward {
                profile_id,
                variant: variant.into(),
                element_id,
            },
            ConfigurationOperationInput::LayerFront {
                profile_id,
                variant,
                element_id,
            } => Self::LayerFront {
                profile_id,
                variant: variant.into(),
                element_id,
            },
            ConfigurationOperationInput::LayerBack {
                profile_id,
                variant,
                element_id,
            } => Self::LayerBack {
                profile_id,
                variant: variant.into(),
                element_id,
            },
            ConfigurationOperationInput::GroupCreate {
                profile_id,
                variant,
                group_id,
                name,
                element_ids,
            } => Self::GroupCreate {
                profile_id,
                variant: variant.into(),
                group_id,
                name,
                element_ids,
            },
            ConfigurationOperationInput::GroupRename {
                profile_id,
                variant,
                group_id,
                name,
            } => Self::GroupRename {
                profile_id,
                variant: variant.into(),
                group_id,
                name,
            },
            ConfigurationOperationInput::GroupDuplicate {
                profile_id,
                variant,
                group_id,
                new_group_id,
                name,
                new_element_ids,
                offset_x,
                offset_y,
            } => Self::GroupDuplicate {
                profile_id,
                variant: variant.into(),
                group_id,
                new_group_id,
                name,
                new_element_ids,
                offset_x: offset_x.unwrap_or(0.025),
                offset_y: offset_y.unwrap_or(0.025),
            },
            ConfigurationOperationInput::GroupUngroup {
                profile_id,
                variant,
                group_id,
            } => Self::GroupUngroup {
                profile_id,
                variant: variant.into(),
                group_id,
            },
            ConfigurationOperationInput::GroupHide {
                profile_id,
                variant,
                group_id,
            } => Self::GroupHide {
                profile_id,
                variant: variant.into(),
                group_id,
            },
            ConfigurationOperationInput::GroupShow {
                profile_id,
                variant,
                group_id,
            } => Self::GroupShow {
                profile_id,
                variant: variant.into(),
                group_id,
            },
            ConfigurationOperationInput::GroupLock {
                profile_id,
                variant,
                group_id,
            } => Self::GroupLock {
                profile_id,
                variant: variant.into(),
                group_id,
            },
            ConfigurationOperationInput::GroupUnlock {
                profile_id,
                variant,
                group_id,
            } => Self::GroupUnlock {
                profile_id,
                variant: variant.into(),
                group_id,
            },
            ConfigurationOperationInput::GroupNudge {
                profile_id,
                variant,
                group_id,
                canvas_frame_id,
                delta_x,
                delta_y,
            } => Self::GroupNudge {
                profile_id,
                variant: variant.into(),
                group_id,
                canvas_frame_id: canvas_frame_id
                    .unwrap_or_else(|| "iphone-17-pro-landscape".to_owned()),
                delta_x,
                delta_y,
            },
            ConfigurationOperationInput::GroupForward {
                profile_id,
                variant,
                group_id,
            } => Self::GroupForward {
                profile_id,
                variant: variant.into(),
                group_id,
            },
            ConfigurationOperationInput::GroupBackward {
                profile_id,
                variant,
                group_id,
            } => Self::GroupBackward {
                profile_id,
                variant: variant.into(),
                group_id,
            },
            ConfigurationOperationInput::GroupFront {
                profile_id,
                variant,
                group_id,
            } => Self::GroupFront {
                profile_id,
                variant: variant.into(),
                group_id,
            },
            ConfigurationOperationInput::GroupBack {
                profile_id,
                variant,
                group_id,
            } => Self::GroupBack {
                profile_id,
                variant: variant.into(),
                group_id,
            },
            ConfigurationOperationInput::ControlBarReset {
                profile_id,
                variant,
            } => Self::ControlBarReset {
                profile_id,
                variant: variant.into(),
            },
            ConfigurationOperationInput::ControlBarItemReset {
                profile_id,
                variant,
                item,
            } => Self::ControlBarItemReset {
                profile_id,
                variant: variant.into(),
                item: item.into(),
            },
            ConfigurationOperationInput::GenerationGenerate {
                preset,
                preset_revision,
                destination,
                new_element_ids,
                select,
                make_default,
            } => Self::GenerationGenerate {
                preset: preset.into(),
                preset_revision,
                destination: destination.into(),
                new_element_ids,
                select,
                make_default,
            },
            ConfigurationOperationInput::TemplateInstall {
                template,
                template_revision,
                destination,
                name,
                new_element_ids,
                select,
                make_default,
            } => Self::TemplateInstall {
                template: template.into(),
                template_revision,
                destination: destination.into(),
                name,
                new_element_ids,
                select,
                make_default,
            },
            ConfigurationOperationInput::ProfileSelect { profile_id } => {
                Self::ProfileSelect { profile_id }
            }
            ConfigurationOperationInput::ProfileSetDefault { profile_id } => {
                Self::ProfileSetDefault { profile_id }
            }
            ConfigurationOperationInput::ProfileDuplicate {
                profile_id,
                new_profile_id,
                name,
            } => Self::ProfileDuplicate {
                profile_id,
                new_profile_id,
                name,
            },
            ConfigurationOperationInput::ProfileDelete {
                profile_id,
                replacement_profile_id,
            } => Self::ProfileDelete {
                profile_id,
                replacement_profile_id,
            },
            ConfigurationOperationInput::ProfileMove { profile_id, index } => {
                Self::ProfileMove { profile_id, index }
            }
            ConfigurationOperationInput::ProfileCreate {
                name,
                new_profile_id,
                source_profile_id,
                select,
                make_default,
            } => Self::ProfileCreate {
                name,
                new_profile_id,
                source_profile_id,
                select,
                make_default,
            },
            ConfigurationOperationInput::ThemeApply {
                profile_id,
                variant,
                preset,
            } => Self::ThemeApply {
                profile_id,
                variant: variant.into(),
                preset,
            },
            ConfigurationOperationInput::OrientationCopy {
                profile_id,
                source,
                destination,
                automatically_arrange,
            } => Self::OrientationCopy {
                profile_id,
                source: source.into(),
                destination: destination.into(),
                automatically_arrange,
            },
            ConfigurationOperationInput::ElementDuplicate {
                profile_id,
                variant,
                element_ids,
                new_element_ids,
                offset_x,
                offset_y,
            } => Self::ElementDuplicate {
                profile_id,
                variant: variant.into(),
                element_ids,
                new_element_ids,
                offset_x,
                offset_y,
            },
            ConfigurationOperationInput::ElementAlign {
                profile_id,
                variant,
                element_ids,
                alignment,
            } => Self::ElementAlign {
                profile_id,
                variant: variant.into(),
                element_ids,
                alignment: alignment.into(),
            },
            ConfigurationOperationInput::ElementDistribute {
                profile_id,
                variant,
                element_ids,
                distribution,
            } => Self::ElementDistribute {
                profile_id,
                variant: variant.into(),
                element_ids,
                distribution: distribution.into(),
            },
            ConfigurationOperationInput::ElementNudge {
                profile_id,
                variant,
                element_ids,
                delta_x,
                delta_y,
            } => Self::ElementNudge {
                profile_id,
                variant: variant.into(),
                element_ids,
                delta_x,
                delta_y,
            },
            ConfigurationOperationInput::ElementDelete {
                profile_id,
                variant,
                element_id,
            } => Self::ElementDelete {
                profile_id,
                variant: variant.into(),
                element_id,
            },
            ConfigurationOperationInput::ElementReset {
                profile_id,
                variant,
                element_id,
            } => Self::ElementReset {
                profile_id,
                variant: variant.into(),
                element_id,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum GenerationPresetInput {
    HollowKnight,
}

impl From<GenerationPresetInput> for GenerationPreset {
    fn from(value: GenerationPresetInput) -> Self {
        match value {
            GenerationPresetInput::HollowKnight => Self::HollowKnight,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ControllerTemplateInput {
    ProductivityStarter,
    ProductivityOneHandedLeft,
    ProductivityOneHandedRight,
    Nes,
    Snes,
    Nintendo64,
    GameCube,
    GameBoy,
    GameBoyAdvance,
    GenesisSixButton,
    Saturn,
    Dreamcast,
    ArcadeStick,
    Psp,
    PlayStation,
    Xbox,
    SoftWhite,
}

impl From<ControllerTemplateInput> for ControllerTemplate {
    fn from(value: ControllerTemplateInput) -> Self {
        match value {
            ControllerTemplateInput::ProductivityStarter => Self::ProductivityStarter,
            ControllerTemplateInput::ProductivityOneHandedLeft => Self::ProductivityOneHandedLeft,
            ControllerTemplateInput::ProductivityOneHandedRight => Self::ProductivityOneHandedRight,
            ControllerTemplateInput::Nes => Self::Nes,
            ControllerTemplateInput::Snes => Self::Snes,
            ControllerTemplateInput::Nintendo64 => Self::Nintendo64,
            ControllerTemplateInput::GameCube => Self::GameCube,
            ControllerTemplateInput::GameBoy => Self::GameBoy,
            ControllerTemplateInput::GameBoyAdvance => Self::GameBoyAdvance,
            ControllerTemplateInput::GenesisSixButton => Self::GenesisSixButton,
            ControllerTemplateInput::Saturn => Self::Saturn,
            ControllerTemplateInput::Dreamcast => Self::Dreamcast,
            ControllerTemplateInput::ArcadeStick => Self::ArcadeStick,
            ControllerTemplateInput::Psp => Self::Psp,
            ControllerTemplateInput::PlayStation => Self::PlayStation,
            ControllerTemplateInput::Xbox => Self::Xbox,
            ControllerTemplateInput::SoftWhite => Self::SoftWhite,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum GeneratedProfileDestinationInput {
    Create {
        /// Caller-generated profile UUID; must not already exist.
        #[serde(rename = "newProfileID")]
        new_profile_id: String,
    },
    Replace {
        /// Exact existing profile UUID whose current name matches the generated profile name.
        #[serde(rename = "profileID")]
        profile_id: String,
    },
}

impl From<GeneratedProfileDestinationInput> for GeneratedProfileDestination {
    fn from(value: GeneratedProfileDestinationInput) -> Self {
        match value {
            GeneratedProfileDestinationInput::Create { new_profile_id } => {
                Self::Create { new_profile_id }
            }
            GeneratedProfileDestinationInput::Replace { profile_id } => {
                Self::Replace { profile_id }
            }
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationVariantInput {
    Primary,
    Portrait,
    Landscape,
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum LayoutRepairKindInput {
    ShowDefaultControls,
    MoveInsideSafeArea,
    MinimumTouchTarget,
    ResolveOverlap,
    AutoArrange,
    SeparateExpandedHitTargets,
    ErgonomicAutoArrange,
}

impl From<LayoutRepairKindInput> for LayoutRepairKind {
    fn from(value: LayoutRepairKindInput) -> Self {
        match value {
            LayoutRepairKindInput::ShowDefaultControls => Self::ShowDefaultControls,
            LayoutRepairKindInput::MoveInsideSafeArea => Self::MoveInsideSafeArea,
            LayoutRepairKindInput::MinimumTouchTarget => Self::MinimumTouchTarget,
            LayoutRepairKindInput::ResolveOverlap => Self::ResolveOverlap,
            LayoutRepairKindInput::AutoArrange => Self::AutoArrange,
            LayoutRepairKindInput::SeparateExpandedHitTargets => Self::SeparateExpandedHitTargets,
            LayoutRepairKindInput::ErgonomicAutoArrange => Self::ErgonomicAutoArrange,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum LayoutRepairTargetInput {
    All {},
    Repair { repair: LayoutRepairKindInput },
}

impl From<LayoutRepairTargetInput> for LayoutRepairTarget {
    fn from(value: LayoutRepairTargetInput) -> Self {
        match value {
            LayoutRepairTargetInput::All {} => Self::All {},
            LayoutRepairTargetInput::Repair { repair } => Self::Repair {
                repair: repair.into(),
            },
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(tag = "source", rename_all = "lowercase", deny_unknown_fields)]
pub enum LayoutRepairCanvasInput {
    Stored {},
    Frame {
        /// Exact ID from query_catalog(device-frames).
        #[serde(rename = "frameID")]
        frame_id: String,
    },
    Size {
        #[schemars(range(min = 240.0, max = 1800.0))]
        width: f64,
        #[schemars(range(min = 240.0, max = 1800.0))]
        height: f64,
    },
}

impl From<LayoutRepairCanvasInput> for LayoutRepairCanvas {
    fn from(value: LayoutRepairCanvasInput) -> Self {
        match value {
            LayoutRepairCanvasInput::Stored {} => Self::Stored {},
            LayoutRepairCanvasInput::Frame { frame_id } => Self::Frame { frame_id },
            LayoutRepairCanvasInput::Size { width, height } => Self::Size { width, height },
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationOrientationPreferenceInput {
    Automatic,
    Portrait,
    Landscape,
}

impl From<ConfigurationOrientationPreferenceInput> for ConfigurationOrientationPreference {
    fn from(value: ConfigurationOrientationPreferenceInput) -> Self {
        match value {
            ConfigurationOrientationPreferenceInput::Automatic => Self::Automatic,
            ConfigurationOrientationPreferenceInput::Portrait => Self::Portrait,
            ConfigurationOrientationPreferenceInput::Landscape => Self::Landscape,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationLayoutModeInput {
    Standard,
    Southpaw,
}

impl From<ConfigurationLayoutModeInput> for ConfigurationLayoutMode {
    fn from(value: ConfigurationLayoutModeInput) -> Self {
        match value {
            ConfigurationLayoutModeInput::Standard => Self::Standard,
            ConfigurationLayoutModeInput::Southpaw => Self::Southpaw,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationControlScaleInput {
    Compact,
    Standard,
    Large,
}

impl From<ConfigurationControlScaleInput> for ConfigurationControlScale {
    fn from(value: ConfigurationControlScaleInput) -> Self {
        match value {
            ConfigurationControlScaleInput::Compact => Self::Compact,
            ConfigurationControlScaleInput::Standard => Self::Standard,
            ConfigurationControlScaleInput::Large => Self::Large,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationColorSchemeInput {
    System,
    Light,
    Dark,
}

impl From<ConfigurationColorSchemeInput> for ConfigurationColorScheme {
    fn from(value: ConfigurationColorSchemeInput) -> Self {
        match value {
            ConfigurationColorSchemeInput::System => Self::System,
            ConfigurationColorSchemeInput::Light => Self::Light,
            ConfigurationColorSchemeInput::Dark => Self::Dark,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationAccentStyleInput {
    Monochrome,
    Blue,
    Green,
    Purple,
    Pink,
    Amber,
}

impl From<ConfigurationAccentStyleInput> for ConfigurationAccentStyle {
    fn from(value: ConfigurationAccentStyleInput) -> Self {
        match value {
            ConfigurationAccentStyleInput::Monochrome => Self::Monochrome,
            ConfigurationAccentStyleInput::Blue => Self::Blue,
            ConfigurationAccentStyleInput::Green => Self::Green,
            ConfigurationAccentStyleInput::Purple => Self::Purple,
            ConfigurationAccentStyleInput::Pink => Self::Pink,
            ConfigurationAccentStyleInput::Amber => Self::Amber,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationBackgroundScopeInput {
    All,
    Light,
    Dark,
}

impl From<ConfigurationBackgroundScopeInput> for ConfigurationBackgroundScope {
    fn from(value: ConfigurationBackgroundScopeInput) -> Self {
        match value {
            ConfigurationBackgroundScopeInput::All => Self::All,
            ConfigurationBackgroundScopeInput::Light => Self::Light,
            ConfigurationBackgroundScopeInput::Dark => Self::Dark,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConfigurationRgbaColorInput {
    #[schemars(range(min = 0.0, max = 1.0))]
    pub red: f64,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub green: f64,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub blue: f64,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub alpha: f64,
}

impl From<ConfigurationRgbaColorInput> for ConfigurationRgbaColor {
    fn from(value: ConfigurationRgbaColorInput) -> Self {
        Self {
            red: value.red,
            green: value.green,
            blue: value.blue,
            alpha: value.alpha,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum StyleMaterialPresetInput {
    SoftWhiteRaised,
    SoftWhiteInset,
    SoftWhitePlate,
}

impl From<StyleMaterialPresetInput> for StyleMaterialPreset {
    fn from(value: StyleMaterialPresetInput) -> Self {
        match value {
            StyleMaterialPresetInput::SoftWhiteRaised => Self::SoftWhiteRaised,
            StyleMaterialPresetInput::SoftWhiteInset => Self::SoftWhiteInset,
            StyleMaterialPresetInput::SoftWhitePlate => Self::SoftWhitePlate,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum StyleIconSourceInput {
    SfSymbol,
    Text,
}

impl From<StyleIconSourceInput> for StyleIconSource {
    fn from(value: StyleIconSourceInput) -> Self {
        match value {
            StyleIconSourceInput::SfSymbol => Self::SfSymbol,
            StyleIconSourceInput::Text => Self::Text,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StyleIconInput {
    pub source: StyleIconSourceInput,
    #[schemars(length(min = 1, max = 80))]
    pub value: String,
}

impl From<StyleIconInput> for StyleIcon {
    fn from(value: StyleIconInput) -> Self {
        Self {
            source: value.source.into(),
            value: value.value,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum StyleHapticKindInput {
    None,
    Light,
    Medium,
    Heavy,
    Soft,
    Rigid,
}

impl From<StyleHapticKindInput> for StyleHapticKind {
    fn from(value: StyleHapticKindInput) -> Self {
        match value {
            StyleHapticKindInput::None => Self::None,
            StyleHapticKindInput::Light => Self::Light,
            StyleHapticKindInput::Medium => Self::Medium,
            StyleHapticKindInput::Heavy => Self::Heavy,
            StyleHapticKindInput::Soft => Self::Soft,
            StyleHapticKindInput::Rigid => Self::Rigid,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum StyleHapticPatternInput {
    Single,
    Double,
    Pulse,
    Buzz,
}

impl From<StyleHapticPatternInput> for StyleHapticPattern {
    fn from(value: StyleHapticPatternInput) -> Self {
        match value {
            StyleHapticPatternInput::Single => Self::Single,
            StyleHapticPatternInput::Double => Self::Double,
            StyleHapticPatternInput::Pulse => Self::Pulse,
            StyleHapticPatternInput::Buzz => Self::Buzz,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StyleHapticInput {
    pub style: Option<StyleHapticKindInput>,
    pub pattern: Option<StyleHapticPatternInput>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub intensity: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub sharpness: Option<f64>,
    #[schemars(range(min = 0.02, max = 0.30))]
    pub duration: Option<f64>,
}

impl From<StyleHapticInput> for StyleHaptic {
    fn from(value: StyleHapticInput) -> Self {
        Self {
            style: value.style.map(Into::into),
            pattern: value.pattern.map(Into::into),
            intensity: value.intensity,
            sharpness: value.sharpness,
            duration: value.duration,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StyleShadowInput {
    pub color: ConfigurationRgbaColorInput,
    #[schemars(range(min = 0.0, max = 96.0))]
    pub radius: f64,
    #[schemars(range(min = -96.0, max = 96.0))]
    pub x: f64,
    #[schemars(range(min = -96.0, max = 96.0))]
    pub y: f64,
    #[serde(default = "default_style_shadow_opacity_input")]
    #[schemars(range(min = 0.0, max = 1.0))]
    pub opacity: f64,
}

const fn default_style_shadow_opacity_input() -> f64 {
    1.0
}

impl From<StyleShadowInput> for StyleShadow {
    fn from(value: StyleShadowInput) -> Self {
        Self {
            color: value.color.into(),
            radius: value.radius,
            x: value.x,
            y: value.y,
            opacity: value.opacity,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StyleAppearanceInput {
    pub material_preset: Option<StyleMaterialPresetInput>,
    pub fill_color: Option<ConfigurationRgbaColorInput>,
    pub foreground_color: Option<ConfigurationRgbaColorInput>,
    pub stroke_color: Option<ConfigurationRgbaColorInput>,
    #[schemars(range(min = 0.0, max = 12.0))]
    pub stroke_width: Option<f64>,
    pub glow_color: Option<ConfigurationRgbaColorInput>,
    #[schemars(range(min = 0.0, max = 64.0))]
    pub glow_radius: Option<f64>,
    pub inner_shadow_color: Option<ConfigurationRgbaColorInput>,
    #[schemars(range(min = 0.0, max = 64.0))]
    pub inner_shadow_radius: Option<f64>,
    #[schemars(range(min = -64.0, max = 64.0))]
    pub inner_shadow_x: Option<f64>,
    #[schemars(range(min = -64.0, max = 64.0))]
    pub inner_shadow_y: Option<f64>,
    pub highlight_color: Option<ConfigurationRgbaColorInput>,
    #[schemars(range(min = 0.0, max = 64.0))]
    pub highlight_radius: Option<f64>,
    #[schemars(range(min = -64.0, max = 64.0))]
    pub highlight_x: Option<f64>,
    #[schemars(range(min = -64.0, max = 64.0))]
    pub highlight_y: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub highlight_opacity: Option<f64>,
    pub bevel_highlight_color: Option<ConfigurationRgbaColorInput>,
    pub bevel_shadow_color: Option<ConfigurationRgbaColorInput>,
    #[schemars(range(min = 0.0, max = 24.0))]
    pub bevel_width: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub opacity: Option<f64>,
    #[schemars(length(max = 8))]
    pub shadows: Option<Vec<StyleShadowInput>>,
    pub pressed_fill_color: Option<ConfigurationRgbaColorInput>,
    #[schemars(range(min = 0.5, max = 1.5))]
    pub pressed_scale: Option<f64>,
    pub icon: Option<StyleIconInput>,
    pub haptic: Option<StyleHapticInput>,
}

impl From<StyleAppearanceInput> for StyleAppearance {
    fn from(value: StyleAppearanceInput) -> Self {
        Self {
            material_preset: value.material_preset.map(Into::into),
            fill_color: value.fill_color.map(Into::into),
            foreground_color: value.foreground_color.map(Into::into),
            stroke_color: value.stroke_color.map(Into::into),
            stroke_width: value.stroke_width,
            glow_color: value.glow_color.map(Into::into),
            glow_radius: value.glow_radius,
            inner_shadow_color: value.inner_shadow_color.map(Into::into),
            inner_shadow_radius: value.inner_shadow_radius,
            inner_shadow_x: value.inner_shadow_x,
            inner_shadow_y: value.inner_shadow_y,
            highlight_color: value.highlight_color.map(Into::into),
            highlight_radius: value.highlight_radius,
            highlight_x: value.highlight_x,
            highlight_y: value.highlight_y,
            highlight_opacity: value.highlight_opacity,
            bevel_highlight_color: value.bevel_highlight_color.map(Into::into),
            bevel_shadow_color: value.bevel_shadow_color.map(Into::into),
            bevel_width: value.bevel_width,
            opacity: value.opacity,
            shadows: value
                .shadows
                .map(|shadows| shadows.into_iter().map(Into::into).collect()),
            pressed_fill_color: value.pressed_fill_color.map(Into::into),
            pressed_scale: value.pressed_scale,
            icon: value.icon.map(Into::into),
            haptic: value.haptic.map(Into::into),
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum ConfigurationBackgroundEditInput {
    Keep,
    Clear,
    Set {
        scope: ConfigurationBackgroundScopeInput,
        color: ConfigurationRgbaColorInput,
    },
}

impl From<ConfigurationBackgroundEditInput> for ConfigurationBackgroundEdit {
    fn from(value: ConfigurationBackgroundEditInput) -> Self {
        match value {
            ConfigurationBackgroundEditInput::Keep => Self::Keep,
            ConfigurationBackgroundEditInput::Clear => Self::Clear,
            ConfigurationBackgroundEditInput::Set { scope, color } => Self::Set {
                scope: scope.into(),
                color: color.into(),
            },
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CustomizationChangesInput {
    pub layout_mode: Option<ConfigurationLayoutModeInput>,
    pub control_scale: Option<ConfigurationControlScaleInput>,
    pub color_scheme: Option<ConfigurationColorSchemeInput>,
    pub accent_style: Option<ConfigurationAccentStyleInput>,
    pub shows_button_labels: Option<bool>,
    pub background_edit: ConfigurationBackgroundEditInput,
}

impl From<CustomizationChangesInput> for CustomizationChanges {
    fn from(value: CustomizationChangesInput) -> Self {
        Self {
            layout_mode: value.layout_mode.map(Into::into),
            control_scale: value.control_scale.map(Into::into),
            color_scheme: value.color_scheme.map(Into::into),
            accent_style: value.accent_style.map(Into::into),
            shows_button_labels: value.shows_button_labels,
            background_edit: value.background_edit.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ControlBarMoveDirectionInput {
    Up,
    Down,
}

impl From<ControlBarMoveDirectionInput> for ControlBarMoveDirection {
    fn from(value: ControlBarMoveDirectionInput) -> Self {
        match value {
            ControlBarMoveDirectionInput::Up => Self::Up,
            ControlBarMoveDirectionInput::Down => Self::Down,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum LayerMoveDestinationInput {
    Index {
        index: i32,
    },
    Before {
        #[serde(rename = "elementID")]
        element_id: String,
    },
    After {
        #[serde(rename = "elementID")]
        element_id: String,
    },
}

impl From<LayerMoveDestinationInput> for LayerMoveDestination {
    fn from(value: LayerMoveDestinationInput) -> Self {
        match value {
            LayerMoveDestinationInput::Index { index } => Self::Index { index },
            LayerMoveDestinationInput::Before { element_id } => Self::Before { element_id },
            LayerMoveDestinationInput::After { element_id } => Self::After { element_id },
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationOutputModeInput {
    Keyboard,
    Controller,
    Custom,
}

impl From<ConfigurationOutputModeInput> for ConfigurationOutputMode {
    fn from(value: ConfigurationOutputModeInput) -> Self {
        match value {
            ConfigurationOutputModeInput::Keyboard => Self::Keyboard,
            ConfigurationOutputModeInput::Controller => Self::Controller,
            ConfigurationOutputModeInput::Custom => Self::Custom,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ConfigurationControlBarItemInput {
    Status,
    ProfileMenu,
    LaunchTarget,
    Spacer,
    EditLayout,
    Settings,
    Home,
    Connection,
}

impl From<ConfigurationControlBarItemInput> for ConfigurationControlBarItem {
    fn from(value: ConfigurationControlBarItemInput) -> Self {
        match value {
            ConfigurationControlBarItemInput::Status => Self::Status,
            ConfigurationControlBarItemInput::ProfileMenu => Self::ProfileMenu,
            ConfigurationControlBarItemInput::LaunchTarget => Self::LaunchTarget,
            ConfigurationControlBarItemInput::Spacer => Self::Spacer,
            ConfigurationControlBarItemInput::EditLayout => Self::EditLayout,
            ConfigurationControlBarItemInput::Settings => Self::Settings,
            ConfigurationControlBarItemInput::Home => Self::Home,
            ConfigurationControlBarItemInput::Connection => Self::Connection,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ControlBarItemChangesInput {
    #[schemars(range(min = 0.001, max = 12.0))]
    pub width_scale: Option<f64>,
    #[schemars(range(min = 0.001, max = 12.0))]
    pub height_scale: Option<f64>,
    pub is_hidden: Option<bool>,
    pub shape: Option<ElementShapeInput>,
    pub accent_style: Option<ConfigurationAccentStyleInput>,
    #[schemars(range(min = 0.0, max = 1024.0))]
    pub corner_radius: Option<f64>,
    pub corner_radii: Option<ElementCornerRadiiInput>,
    #[schemars(range(min = 0.0, max = 2.0))]
    pub shadow_strength: Option<f64>,
    pub fill: Option<ElementFillInput>,
    #[serde(default)]
    pub clear_fill: bool,
    pub light_fill: Option<ElementFillInput>,
    #[serde(default)]
    pub clear_light_fill: bool,
    pub dark_fill: Option<ElementFillInput>,
    #[serde(default)]
    pub clear_dark_fill: bool,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub fill_opacity: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub light_fill_opacity: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub dark_fill_opacity: Option<f64>,
    #[serde(rename = "styleID")]
    pub style_id: Option<String>,
    #[serde(default)]
    pub clear_style: bool,
    pub appearance: Option<Box<StyleAppearanceInput>>,
    pub icon: Option<StyleIconInput>,
    #[serde(default)]
    pub clear_icon: bool,
    pub haptic: Option<StyleHapticInput>,
    #[serde(default)]
    pub clear_haptic: bool,
}

impl From<ControlBarItemChangesInput> for ControlBarItemChanges {
    fn from(value: ControlBarItemChangesInput) -> Self {
        Self {
            width_scale: value.width_scale,
            height_scale: value.height_scale,
            is_hidden: value.is_hidden,
            shape: value.shape.map(Into::into),
            accent_style: value.accent_style.map(Into::into),
            corner_radius: value.corner_radius,
            corner_radii: value.corner_radii.map(Into::into),
            shadow_strength: value.shadow_strength,
            fill: value.fill.map(Into::into),
            clear_fill: value.clear_fill,
            light_fill: value.light_fill.map(Into::into),
            clear_light_fill: value.clear_light_fill,
            dark_fill: value.dark_fill.map(Into::into),
            clear_dark_fill: value.clear_dark_fill,
            fill_opacity: value.fill_opacity,
            light_fill_opacity: value.light_fill_opacity,
            dark_fill_opacity: value.dark_fill_opacity,
            style_id: value.style_id,
            clear_style: value.clear_style,
            appearance: value
                .appearance
                .map(|appearance| Box::new((*appearance).into())),
            icon: value.icon.map(Into::into),
            clear_icon: value.clear_icon,
            haptic: value.haptic.map(Into::into),
            clear_haptic: value.clear_haptic,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum KeyboardOutputEditInput {
    Keep,
    Clear,
    Set {
        sequence: Vec<SemanticKeyStrokeInput>,
    },
}

impl From<KeyboardOutputEditInput> for KeyboardOutputEdit {
    fn from(value: KeyboardOutputEditInput) -> Self {
        match value {
            KeyboardOutputEditInput::Keep => Self::Keep,
            KeyboardOutputEditInput::Clear => Self::Clear,
            KeyboardOutputEditInput::Set { sequence } => Self::Set {
                sequence: sequence.into_iter().map(Into::into).collect(),
            },
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum GamepadOutputEditInput {
    Keep,
    Clear,
    Set {
        button: ConfigurationGamepadButtonInput,
    },
}

impl From<GamepadOutputEditInput> for GamepadOutputEdit {
    fn from(value: GamepadOutputEditInput) -> Self {
        match value {
            GamepadOutputEditInput::Keep => Self::Keep,
            GamepadOutputEditInput::Clear => Self::Clear,
            GamepadOutputEditInput::Set { button } => Self::Set {
                button: button.into(),
            },
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ConfigurationGamepadButtonInput {
    South,
    East,
    West,
    North,
    LeftShoulder,
    RightShoulder,
    LeftTriggerButton,
    RightTriggerButton,
    Select,
    Start,
    Home,
    LeftStickPress,
    RightStickPress,
    DpadUp,
    DpadDown,
    DpadLeft,
    DpadRight,
}

impl From<ConfigurationGamepadButtonInput> for ConfigurationGamepadButton {
    fn from(value: ConfigurationGamepadButtonInput) -> Self {
        match value {
            ConfigurationGamepadButtonInput::South => Self::South,
            ConfigurationGamepadButtonInput::East => Self::East,
            ConfigurationGamepadButtonInput::West => Self::West,
            ConfigurationGamepadButtonInput::North => Self::North,
            ConfigurationGamepadButtonInput::LeftShoulder => Self::LeftShoulder,
            ConfigurationGamepadButtonInput::RightShoulder => Self::RightShoulder,
            ConfigurationGamepadButtonInput::LeftTriggerButton => Self::LeftTriggerButton,
            ConfigurationGamepadButtonInput::RightTriggerButton => Self::RightTriggerButton,
            ConfigurationGamepadButtonInput::Select => Self::Select,
            ConfigurationGamepadButtonInput::Start => Self::Start,
            ConfigurationGamepadButtonInput::Home => Self::Home,
            ConfigurationGamepadButtonInput::LeftStickPress => Self::LeftStickPress,
            ConfigurationGamepadButtonInput::RightStickPress => Self::RightStickPress,
            ConfigurationGamepadButtonInput::DpadUp => Self::DpadUp,
            ConfigurationGamepadButtonInput::DpadDown => Self::DpadDown,
            ConfigurationGamepadButtonInput::DpadLeft => Self::DpadLeft,
            ConfigurationGamepadButtonInput::DpadRight => Self::DpadRight,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum OrientationVariantInput {
    Portrait,
    Landscape,
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ControlAlignmentInput {
    Left,
    HorizontalCenters,
    Right,
    Top,
    VerticalCenters,
    Bottom,
}

impl From<ControlAlignmentInput> for ControlAlignment {
    fn from(value: ControlAlignmentInput) -> Self {
        match value {
            ControlAlignmentInput::Left => Self::Left,
            ControlAlignmentInput::HorizontalCenters => Self::HorizontalCenters,
            ControlAlignmentInput::Right => Self::Right,
            ControlAlignmentInput::Top => Self::Top,
            ControlAlignmentInput::VerticalCenters => Self::VerticalCenters,
            ControlAlignmentInput::Bottom => Self::Bottom,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "kebab-case")]
pub enum ControlDistributionInput {
    HorizontalCenters,
    VerticalCenters,
    HorizontalSpacing,
    VerticalSpacing,
}

impl From<ControlDistributionInput> for ControlDistribution {
    fn from(value: ControlDistributionInput) -> Self {
        match value {
            ControlDistributionInput::HorizontalCenters => Self::HorizontalCenters,
            ControlDistributionInput::VerticalCenters => Self::VerticalCenters,
            ControlDistributionInput::HorizontalSpacing => Self::HorizontalSpacing,
            ControlDistributionInput::VerticalSpacing => Self::VerticalSpacing,
        }
    }
}

impl From<OrientationVariantInput> for OrientationVariant {
    fn from(value: OrientationVariantInput) -> Self {
        match value {
            OrientationVariantInput::Portrait => Self::Portrait,
            OrientationVariantInput::Landscape => Self::Landscape,
        }
    }
}

impl From<ConfigurationVariantInput> for ConfigurationVariant {
    fn from(value: ConfigurationVariantInput) -> Self {
        match value {
            ConfigurationVariantInput::Primary => Self::Primary,
            ConfigurationVariantInput::Portrait => Self::Portrait,
            ConfigurationVariantInput::Landscape => Self::Landscape,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ElementKindInput {
    Button,
    Joystick,
    Trigger,
    Trackpad,
    Text,
    Decoration,
}
impl From<ElementKindInput> for ElementKind {
    fn from(value: ElementKindInput) -> Self {
        match value {
            ElementKindInput::Button => Self::Button,
            ElementKindInput::Joystick => Self::Joystick,
            ElementKindInput::Trigger => Self::Trigger,
            ElementKindInput::Trackpad => Self::Trackpad,
            ElementKindInput::Text => Self::Text,
            ElementKindInput::Decoration => Self::Decoration,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ElementVisualRoleInput {
    Movement,
    PrimaryAction,
    SecondaryAction,
    Utility,
    Menu,
    Custom,
    Joystick,
    Trigger,
    Trackpad,
    Decoration,
    System,
}
impl From<ElementVisualRoleInput> for ElementVisualRole {
    fn from(value: ElementVisualRoleInput) -> Self {
        match value {
            ElementVisualRoleInput::Movement => Self::Movement,
            ElementVisualRoleInput::PrimaryAction => Self::PrimaryAction,
            ElementVisualRoleInput::SecondaryAction => Self::SecondaryAction,
            ElementVisualRoleInput::Utility => Self::Utility,
            ElementVisualRoleInput::Menu => Self::Menu,
            ElementVisualRoleInput::Custom => Self::Custom,
            ElementVisualRoleInput::Joystick => Self::Joystick,
            ElementVisualRoleInput::Trigger => Self::Trigger,
            ElementVisualRoleInput::Trackpad => Self::Trackpad,
            ElementVisualRoleInput::Decoration => Self::Decoration,
            ElementVisualRoleInput::System => Self::System,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ElementShapeInput {
    RoundedRectangle,
    Rectangle,
    Capsule,
    Circle,
    Ellipse,
    Polygon,
    Star,
}
impl From<ElementShapeInput> for ElementShape {
    fn from(value: ElementShapeInput) -> Self {
        match value {
            ElementShapeInput::RoundedRectangle => Self::RoundedRectangle,
            ElementShapeInput::Rectangle => Self::Rectangle,
            ElementShapeInput::Capsule => Self::Capsule,
            ElementShapeInput::Circle => Self::Circle,
            ElementShapeInput::Ellipse => Self::Ellipse,
            ElementShapeInput::Polygon => Self::Polygon,
            ElementShapeInput::Star => Self::Star,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementHitInsetsInput {
    #[schemars(range(min = 0.0, max = 96.0))]
    pub top: f64,
    #[schemars(range(min = 0.0, max = 96.0))]
    pub leading: f64,
    #[schemars(range(min = 0.0, max = 96.0))]
    pub bottom: f64,
    #[schemars(range(min = 0.0, max = 96.0))]
    pub trailing: f64,
}
impl From<ElementHitInsetsInput> for ElementHitInsets {
    fn from(v: ElementHitInsetsInput) -> Self {
        Self {
            top: v.top,
            leading: v.leading,
            bottom: v.bottom,
            trailing: v.trailing,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementCornerRadiiInput {
    #[schemars(range(min = 0.0, max = 1024.0))]
    pub top_leading: f64,
    #[schemars(range(min = 0.0, max = 1024.0))]
    pub top_trailing: f64,
    #[schemars(range(min = 0.0, max = 1024.0))]
    pub bottom_trailing: f64,
    #[schemars(range(min = 0.0, max = 1024.0))]
    pub bottom_leading: f64,
}
impl From<ElementCornerRadiiInput> for ElementCornerRadii {
    fn from(v: ElementCornerRadiiInput) -> Self {
        Self {
            top_leading: v.top_leading,
            top_trailing: v.top_trailing,
            bottom_trailing: v.bottom_trailing,
            bottom_leading: v.bottom_leading,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ElementGradientTypeInput {
    Linear,
    Radial,
}
impl From<ElementGradientTypeInput> for ElementGradientType {
    fn from(v: ElementGradientTypeInput) -> Self {
        match v {
            ElementGradientTypeInput::Linear => Self::Linear,
            ElementGradientTypeInput::Radial => Self::Radial,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementGradientStopInput {
    #[schemars(range(min = 0.0, max = 1.0))]
    pub offset: f64,
    pub color: ConfigurationRgbaColorInput,
}
impl From<ElementGradientStopInput> for ElementGradientStop {
    fn from(v: ElementGradientStopInput) -> Self {
        Self {
            offset: v.offset,
            color: v.color.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ElementTilePatternInput {
    Dots,
    Grid,
    Checker,
    Diagonal,
}
impl From<ElementTilePatternInput> for ElementTilePattern {
    fn from(v: ElementTilePatternInput) -> Self {
        match v {
            ElementTilePatternInput::Dots => Self::Dots,
            ElementTilePatternInput::Grid => Self::Grid,
            ElementTilePatternInput::Checker => Self::Checker,
            ElementTilePatternInput::Diagonal => Self::Diagonal,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub enum ElementTileAlignmentInput {
    TopLeading,
    Top,
    TopTrailing,
    Leading,
    Center,
    Trailing,
    BottomLeading,
    Bottom,
    BottomTrailing,
}
impl From<ElementTileAlignmentInput> for ElementTileAlignment {
    fn from(v: ElementTileAlignmentInput) -> Self {
        match v {
            ElementTileAlignmentInput::TopLeading => Self::TopLeading,
            ElementTileAlignmentInput::Top => Self::Top,
            ElementTileAlignmentInput::TopTrailing => Self::TopTrailing,
            ElementTileAlignmentInput::Leading => Self::Leading,
            ElementTileAlignmentInput::Center => Self::Center,
            ElementTileAlignmentInput::Trailing => Self::Trailing,
            ElementTileAlignmentInput::BottomLeading => Self::BottomLeading,
            ElementTileAlignmentInput::Bottom => Self::Bottom,
            ElementTileAlignmentInput::BottomTrailing => Self::BottomTrailing,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum ElementFillInput {
    Solid {
        color: ConfigurationRgbaColorInput,
    },
    Gradient {
        #[serde(rename = "type")]
        gradient_type: ElementGradientTypeInput,
        #[serde(rename = "angleDegrees")]
        #[schemars(range(min = -36000.0, max = 36000.0))]
        angle_degrees: f64,
        #[schemars(length(min = 2, max = 8))]
        stops: Vec<ElementGradientStopInput>,
    },
    Tile {
        pattern: ElementTilePatternInput,
        #[serde(rename = "foregroundColor")]
        foreground_color: ConfigurationRgbaColorInput,
        #[serde(rename = "backgroundColor")]
        background_color: ConfigurationRgbaColorInput,
        #[schemars(range(min = 0.25, max = 4.0))]
        scale: f64,
        #[serde(rename = "spacingX")]
        #[schemars(range(min = 0.0, max = 2.0))]
        spacing_x: f64,
        #[serde(rename = "spacingY")]
        #[schemars(range(min = 0.0, max = 2.0))]
        spacing_y: f64,
        alignment: ElementTileAlignmentInput,
        #[schemars(range(min = 0.0, max = 1.0))]
        opacity: f64,
    },
}
impl From<ElementFillInput> for ElementFill {
    fn from(v: ElementFillInput) -> Self {
        match v {
            ElementFillInput::Solid { color } => Self::Solid {
                color: color.into(),
            },
            ElementFillInput::Gradient {
                gradient_type,
                angle_degrees,
                stops,
            } => Self::Gradient {
                gradient_type: gradient_type.into(),
                angle_degrees,
                stops: stops.into_iter().map(Into::into).collect(),
            },
            ElementFillInput::Tile {
                pattern,
                foreground_color,
                background_color,
                scale,
                spacing_x,
                spacing_y,
                alignment,
                opacity,
            } => Self::Tile {
                pattern: pattern.into(),
                foreground_color: foreground_color.into(),
                background_color: background_color.into(),
                scale,
                spacing_x,
                spacing_y,
                alignment: alignment.into(),
                opacity,
            },
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ElementJoystickVisualStyleInput {
    Pad,
    Thumbstick,
}
impl From<ElementJoystickVisualStyleInput> for ElementJoystickVisualStyle {
    fn from(v: ElementJoystickVisualStyleInput) -> Self {
        match v {
            ElementJoystickVisualStyleInput::Pad => Self::Pad,
            ElementJoystickVisualStyleInput::Thumbstick => Self::Thumbstick,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementJoystickMappingInput {
    pub up: GameButtonInput,
    pub down: GameButtonInput,
    pub left: GameButtonInput,
    pub right: GameButtonInput,
}
impl From<ElementJoystickMappingInput> for ElementJoystickMapping {
    fn from(v: ElementJoystickMappingInput) -> Self {
        Self {
            up: v.up.into(),
            down: v.down.into(),
            left: v.left.into(),
            right: v.right.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ElementJoystickAnalogTargetInput {
    None,
    LeftStick,
    RightStick,
}
impl From<ElementJoystickAnalogTargetInput> for ElementJoystickAnalogTarget {
    fn from(v: ElementJoystickAnalogTargetInput) -> Self {
        match v {
            ElementJoystickAnalogTargetInput::None => Self::None,
            ElementJoystickAnalogTargetInput::LeftStick => Self::LeftStick,
            ElementJoystickAnalogTargetInput::RightStick => Self::RightStick,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementJoystickSettingsInput {
    pub analog_target: Option<ElementJoystickAnalogTargetInput>,
    pub sends_digital_directions: Option<bool>,
    #[schemars(range(min = 0.0, max = 0.85))]
    pub dead_zone: Option<f64>,
    #[schemars(range(min = 0.2, max = 3.0))]
    pub sensitivity: Option<f64>,
    pub invert_x: Option<bool>,
    pub invert_y: Option<bool>,
    pub snap_to_cardinal: Option<bool>,
}
impl From<ElementJoystickSettingsInput> for ElementJoystickSettings {
    fn from(v: ElementJoystickSettingsInput) -> Self {
        Self {
            analog_target: v.analog_target.map(Into::into),
            sends_digital_directions: v.sends_digital_directions,
            dead_zone: v.dead_zone,
            sensitivity: v.sensitivity,
            invert_x: v.invert_x,
            invert_y: v.invert_y,
            snap_to_cardinal: v.snap_to_cardinal,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ElementTriggerTargetInput {
    Left,
    Right,
}
impl From<ElementTriggerTargetInput> for ElementTriggerTarget {
    fn from(v: ElementTriggerTargetInput) -> Self {
        match v {
            ElementTriggerTargetInput::Left => Self::Left,
            ElementTriggerTargetInput::Right => Self::Right,
        }
    }
}
#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum ElementTriggerOrientationInput {
    Vertical,
    Horizontal,
}
impl From<ElementTriggerOrientationInput> for ElementTriggerOrientation {
    fn from(v: ElementTriggerOrientationInput) -> Self {
        match v {
            ElementTriggerOrientationInput::Vertical => Self::Vertical,
            ElementTriggerOrientationInput::Horizontal => Self::Horizontal,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementTriggerSettingsInput {
    pub target: Option<ElementTriggerTargetInput>,
    pub orientation: Option<ElementTriggerOrientationInput>,
    #[schemars(range(min = 0.0, max = 0.85))]
    pub dead_zone: Option<f64>,
    #[schemars(range(min = 0.2, max = 3.0))]
    pub sensitivity: Option<f64>,
    pub sends_digital_button: Option<bool>,
    #[schemars(range(min = 0.01, max = 1.0))]
    pub digital_threshold: Option<f64>,
}
impl From<ElementTriggerSettingsInput> for ElementTriggerSettings {
    fn from(v: ElementTriggerSettingsInput) -> Self {
        Self {
            target: v.target.map(Into::into),
            orientation: v.orientation.map(Into::into),
            dead_zone: v.dead_zone,
            sensitivity: v.sensitivity,
            sends_digital_button: v.sends_digital_button,
            digital_threshold: v.digital_threshold,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementTrackpadSettingsInput {
    #[schemars(range(min = 0.2, max = 4.0))]
    pub sensitivity: Option<f64>,
    #[schemars(range(min = 0.1, max = 4.0))]
    pub scroll_sensitivity: Option<f64>,
    pub tap_to_click: Option<bool>,
    pub two_finger_scroll: Option<bool>,
    pub natural_scrolling: Option<bool>,
}
impl From<ElementTrackpadSettingsInput> for ElementTrackpadSettings {
    fn from(v: ElementTrackpadSettingsInput) -> Self {
        Self {
            sensitivity: v.sensitivity,
            scroll_sensitivity: v.scroll_sensitivity,
            tap_to_click: v.tap_to_click,
            two_finger_scroll: v.two_finger_scroll,
            natural_scrolling: v.natural_scrolling,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum ElementInputPartInput {
    Primary,
    JoystickUp,
    JoystickDown,
    JoystickLeft,
    JoystickRight,
    TriggerDigital,
}
impl From<ElementInputPartInput> for ElementInputPart {
    fn from(v: ElementInputPartInput) -> Self {
        match v {
            ElementInputPartInput::Primary => Self::Primary,
            ElementInputPartInput::JoystickUp => Self::JoystickUp,
            ElementInputPartInput::JoystickDown => Self::JoystickDown,
            ElementInputPartInput::JoystickLeft => Self::JoystickLeft,
            ElementInputPartInput::JoystickRight => Self::JoystickRight,
            ElementInputPartInput::TriggerDigital => Self::TriggerDigital,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementOutputChangesInput {
    pub part: ElementInputPartInput,
    pub keyboard_edit: KeyboardOutputEditInput,
    pub gamepad_edit: GamepadOutputEditInput,
}
impl From<ElementOutputChangesInput> for ElementOutputChanges {
    fn from(v: ElementOutputChangesInput) -> Self {
        Self {
            part: v.part.into(),
            keyboard_edit: v.keyboard_edit.into(),
            gamepad_edit: v.gamepad_edit.into(),
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementChangesInput {
    #[schemars(length(max = 64))]
    pub label: Option<String>,
    #[serde(default)]
    pub clear_label: bool,
    pub kind: Option<ElementKindInput>,
    pub mapped_button: Option<GameButtonInput>,
    pub visual_role: Option<ElementVisualRoleInput>,
    #[serde(default)]
    pub clear_visual_role: bool,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub center_x: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub center_y: Option<f64>,
    #[schemars(range(min = 0.001, max = 12.0))]
    pub width_scale: Option<f64>,
    #[schemars(range(min = 0.001, max = 12.0))]
    pub height_scale: Option<f64>,
    #[schemars(range(min = -36000.0, max = 36000.0))]
    pub rotation_degrees: Option<f64>,
    pub shape: Option<ElementShapeInput>,
    pub is_hidden: Option<bool>,
    pub is_location_locked: Option<bool>,
    pub shows_integrated_label: Option<bool>,
    #[schemars(range(min = -100, max = 100))]
    pub z_index: Option<i32>,
    pub hit_insets: Option<ElementHitInsetsInput>,
    #[serde(default)]
    pub clear_hit_insets: bool,
    #[schemars(range(min = 0.0, max = 1024.0))]
    pub corner_radius: Option<f64>,
    pub corner_radii: Option<ElementCornerRadiiInput>,
    #[schemars(range(min = 0.0, max = 2.0))]
    pub shadow_strength: Option<f64>,
    pub fill: Option<ElementFillInput>,
    #[serde(default)]
    pub clear_fill: bool,
    pub light_fill: Option<ElementFillInput>,
    #[serde(default)]
    pub clear_light_fill: bool,
    pub dark_fill: Option<ElementFillInput>,
    #[serde(default)]
    pub clear_dark_fill: bool,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub fill_opacity: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub light_fill_opacity: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub dark_fill_opacity: Option<f64>,
    pub thumb_fill: Option<ConfigurationRgbaColorInput>,
    #[serde(default)]
    pub clear_thumb_fill: bool,
    pub light_thumb_fill: Option<ConfigurationRgbaColorInput>,
    #[serde(default)]
    pub clear_light_thumb_fill: bool,
    pub dark_thumb_fill: Option<ConfigurationRgbaColorInput>,
    #[serde(default)]
    pub clear_dark_thumb_fill: bool,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub thumb_opacity: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub light_thumb_opacity: Option<f64>,
    #[schemars(range(min = 0.0, max = 1.0))]
    pub dark_thumb_opacity: Option<f64>,
    pub joystick_visual_style: Option<ElementJoystickVisualStyleInput>,
    #[serde(rename = "styleID")]
    pub style_id: Option<String>,
    #[serde(default)]
    pub clear_style: bool,
    pub appearance: Option<Box<StyleAppearanceInput>>,
    pub icon: Option<StyleIconInput>,
    #[serde(default)]
    pub clear_icon: bool,
    pub haptic: Option<StyleHapticInput>,
    #[serde(default)]
    pub clear_haptic: bool,
    pub joystick_mapping: Option<ElementJoystickMappingInput>,
    pub joystick_settings: Option<ElementJoystickSettingsInput>,
    pub trigger_settings: Option<ElementTriggerSettingsInput>,
    pub trackpad_settings: Option<ElementTrackpadSettingsInput>,
    pub output: Option<ElementOutputChangesInput>,
}

impl From<ElementChangesInput> for ElementChanges {
    fn from(v: ElementChangesInput) -> Self {
        Self {
            label: v.label,
            clear_label: v.clear_label,
            kind: v.kind.map(Into::into),
            mapped_button: v.mapped_button.map(Into::into),
            visual_role: v.visual_role.map(Into::into),
            clear_visual_role: v.clear_visual_role,
            center_x: v.center_x,
            center_y: v.center_y,
            width_scale: v.width_scale,
            height_scale: v.height_scale,
            rotation_degrees: v.rotation_degrees,
            shape: v.shape.map(Into::into),
            is_hidden: v.is_hidden,
            is_location_locked: v.is_location_locked,
            shows_integrated_label: v.shows_integrated_label,
            z_index: v.z_index,
            hit_insets: v.hit_insets.map(Into::into),
            clear_hit_insets: v.clear_hit_insets,
            corner_radius: v.corner_radius,
            corner_radii: v.corner_radii.map(Into::into),
            shadow_strength: v.shadow_strength,
            fill: v.fill.map(Into::into),
            clear_fill: v.clear_fill,
            light_fill: v.light_fill.map(Into::into),
            clear_light_fill: v.clear_light_fill,
            dark_fill: v.dark_fill.map(Into::into),
            clear_dark_fill: v.clear_dark_fill,
            fill_opacity: v.fill_opacity,
            light_fill_opacity: v.light_fill_opacity,
            dark_fill_opacity: v.dark_fill_opacity,
            thumb_fill: v.thumb_fill.map(Into::into),
            clear_thumb_fill: v.clear_thumb_fill,
            light_thumb_fill: v.light_thumb_fill.map(Into::into),
            clear_light_thumb_fill: v.clear_light_thumb_fill,
            dark_thumb_fill: v.dark_thumb_fill.map(Into::into),
            clear_dark_thumb_fill: v.clear_dark_thumb_fill,
            thumb_opacity: v.thumb_opacity,
            light_thumb_opacity: v.light_thumb_opacity,
            dark_thumb_opacity: v.dark_thumb_opacity,
            joystick_visual_style: v.joystick_visual_style.map(Into::into),
            style_id: v.style_id,
            clear_style: v.clear_style,
            appearance: v.appearance.map(|value| Box::new((*value).into())),
            icon: v.icon.map(Into::into),
            clear_icon: v.clear_icon,
            haptic: v.haptic.map(Into::into),
            clear_haptic: v.clear_haptic,
            joystick_mapping: v.joystick_mapping.map(Into::into),
            joystick_settings: v.joystick_settings.map(Into::into),
            trigger_settings: v.trigger_settings.map(Into::into),
            trackpad_settings: v.trackpad_settings.map(Into::into),
            output: v.output.map(Into::into),
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SemanticKeyStrokeInput {
    /// Allowlisted semantic key name such as A, Space, Return, or LeftArrow.
    pub key: String,
    pub modifiers: Vec<SemanticModifierInput>,
}

impl From<SemanticKeyStrokeInput> for SemanticKeyStroke {
    fn from(value: SemanticKeyStrokeInput) -> Self {
        Self {
            key: value.key,
            modifiers: value.modifiers.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum SemanticModifierInput {
    Command,
    Shift,
    Option,
    Control,
}

impl From<SemanticModifierInput> for SemanticModifier {
    fn from(value: SemanticModifierInput) -> Self {
        match value {
            SemanticModifierInput::Command => Self::Command,
            SemanticModifierInput::Shift => Self::Shift,
            SemanticModifierInput::Option => Self::Option,
            SemanticModifierInput::Control => Self::Control,
        }
    }
}

#[derive(Debug, Clone, Copy, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum GameButtonInput {
    Up,
    Down,
    Left,
    Right,
    Jump,
    Attack,
    Dash,
    Focus,
    Map,
    Pause,
    Custom1,
    Custom2,
    Custom3,
    Custom4,
    Custom5,
    Custom6,
    Custom7,
    Custom8,
}

impl From<GameButtonInput> for GameButton {
    fn from(value: GameButtonInput) -> Self {
        match value {
            GameButtonInput::Up => Self::Up,
            GameButtonInput::Down => Self::Down,
            GameButtonInput::Left => Self::Left,
            GameButtonInput::Right => Self::Right,
            GameButtonInput::Jump => Self::Jump,
            GameButtonInput::Attack => Self::Attack,
            GameButtonInput::Dash => Self::Dash,
            GameButtonInput::Focus => Self::Focus,
            GameButtonInput::Map => Self::Map,
            GameButtonInput::Pause => Self::Pause,
            GameButtonInput::Custom1 => Self::Custom1,
            GameButtonInput::Custom2 => Self::Custom2,
            GameButtonInput::Custom3 => Self::Custom3,
            GameButtonInput::Custom4 => Self::Custom4,
            GameButtonInput::Custom5 => Self::Custom5,
            GameButtonInput::Custom6 => Self::Custom6,
            GameButtonInput::Custom7 => Self::Custom7,
            GameButtonInput::Custom8 => Self::Custom8,
        }
    }
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EditConfigurationDraftParams {
    pub draft_id: String,
    pub expected_draft_revision: u64,
    /// Caller-generated UUID used for exact retry idempotency.
    pub operation_id: String,
    pub operation: ConfigurationOperationInput,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct EditConfigurationDraftResult {
    pub draft: ConfigurationDraftResult,
    pub changed: bool,
    pub changed_paths: Vec<String>,
    pub idempotent_replay: bool,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RebaseConfigurationDraftParams {
    pub draft_id: String,
    pub expected_draft_revision: u64,
    pub expected_configuration_revision: u64,
    /// Caller-generated UUID used for exact retry idempotency.
    pub rebase_id: String,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DraftRevisionParams {
    pub draft_id: String,
    pub expected_draft_revision: u64,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ValidateConfigurationDraftResult {
    pub draft_id: String,
    pub draft_revision: u64,
    pub valid: bool,
    pub error_count: u32,
    pub warning_count: u32,
    pub validator: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct PreviewConfigurationDraftResult {
    pub draft: ConfigurationDraftResult,
    pub editable_variant: String,
    pub controller: RenderControllerResult,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExportControllerPreviewParams {
    pub draft_id: String,
    pub expected_draft_revision: u64,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct ExportControllerPreviewResult {
    pub draft_id: String,
    pub draft_revision: u64,
    pub profile_id: String,
    pub profile_name: String,
    pub mime_type: String,
    pub byte_length: u64,
    pub sha256: String,
    /// Self-contained, script-free SVG containing only the bounded controller preview.
    pub svg: String,
}

#[derive(Debug, Clone, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SaveConfigurationDraftParams {
    pub draft_id: String,
    pub expected_draft_revision: u64,
    pub expected_configuration_revision: u64,
    /// Caller-generated UUID used for durable exact retry idempotency.
    pub commit_id: String,
}

#[derive(Debug, Clone, Serialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct SaveConfigurationDraftResult {
    pub draft_id: String,
    pub commit_id: String,
    pub base_configuration_revision: u64,
    pub configuration_revision: u64,
    pub draft_revision: u64,
    pub changed: bool,
    pub idempotent_replay: bool,
    pub phone_sync_queued: bool,
}

#[derive(Clone)]
pub struct ThumbleMcp {
    tool_router: ToolRouter<Self>,
    channel: SharedHostChannel,
    allow_input: bool,
    allow_config_write: bool,
    press_limiter: Arc<Mutex<PressRateLimiter>>,
}

impl std::fmt::Debug for ThumbleMcp {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ThumbleMcp")
            .field("host_channel", &"[CONFIGURED]")
            .field("allow_input", &self.allow_input)
            .field("allow_config_write", &self.allow_config_write)
            .finish_non_exhaustive()
    }
}

#[tool_router(router = tool_router)]
impl ThumbleMcp {
    pub fn new(
        control_socket: std::path::PathBuf,
        allow_input: bool,
        allow_config_write: bool,
    ) -> Self {
        Self::with_channel(
            std::sync::Arc::new(crate::channel::UnixHostChannel::new(control_socket)),
            allow_input,
            allow_config_write,
        )
    }

    /// Build the server over a custom host channel (relay transport).
    pub fn with_channel(
        channel: SharedHostChannel,
        allow_input: bool,
        allow_config_write: bool,
    ) -> Self {
        Self {
            tool_router: Self::tool_router(),
            channel,
            allow_input,
            allow_config_write,
            press_limiter: Arc::new(Mutex::new(PressRateLimiter::new())),
        }
    }

    #[tool(
        description = "Return a credential-free Thumble Host health, connection, discovery, Accessibility, active-profile, and held-output summary. Pairing codes and raw key codes are intentionally omitted.",
        annotations(
            title = "Thumble host status",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn host_status(&self) -> Result<Json<HostStatusResult>, String> {
        let response = self.request("host_status", ControlRequest::Status).await?;
        let status = response
            .status
            .ok_or_else(|| "Thumble Host returned no status".to_owned())?;
        Ok(Json(HostStatusResult::from_host(status)))
    }

    #[tool(
        description = "Check whether the running Thumble Host currently has macOS Accessibility permission. This tool never opens settings or prompts.",
        annotations(
            title = "Thumble Accessibility status",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn accessibility_status(&self) -> Result<Json<AccessibilityStatusResult>, String> {
        let response = self
            .request(
                "accessibility_status",
                ControlRequest::Accessibility {
                    action: AccessibilityAction::Status,
                },
            )
            .await?;
        Ok(Json(AccessibilityStatusResult {
            trusted: response.accessibility_trusted.unwrap_or(false),
        }))
    }

    #[tool(
        description = "Return the authoritative configuration revision and bounded draft capability status. Use this revision when beginning revision-safe controller work.",
        annotations(
            title = "Thumble configuration status",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn configuration_status(&self) -> Result<Json<ConfigurationStatusResult>, String> {
        let response = self
            .request("configuration_status", ControlRequest::ConfigurationStatus)
            .await?;
        let status = response
            .configuration
            .ok_or_else(|| "Thumble Host returned no configuration status".to_owned())?;
        Ok(Json(ConfigurationStatusResult {
            configuration_revision: status.configuration_revision,
            profile_count: status.profile_count,
            active_profile_id: status.active_profile_id,
            default_profile_id: status.default_profile_id,
            maximum_live_drafts: status.maximum_live_drafts,
            draft_lifetime_millis: status.draft_lifetime_millis,
            operation_schema_version: status.operation_schema_version,
            bridge_available: status.bridge_available,
            configuration_write_enabled: status.configuration_write_enabled,
        }))
    }

    #[tool(
        description = "Begin a private, non-authoritative controller configuration draft from an exact configuration revision. This does not change the active profile or paired phone.",
        annotations(
            title = "Begin Thumble configuration draft",
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = false,
            open_world_hint = false
        )
    )]
    pub async fn begin_configuration_draft(
        &self,
        Parameters(params): Parameters<BeginConfigurationDraftParams>,
    ) -> Result<Json<ConfigurationDraftResult>, String> {
        let response = self
            .request(
                "begin_configuration_draft",
                ControlRequest::BeginConfigurationDraft {
                    expected_configuration_revision: params.expected_configuration_revision,
                },
            )
            .await?;
        Ok(Json(
            response
                .draft
                .ok_or_else(|| "Thumble Host returned no configuration draft".to_owned())?
                .into(),
        ))
    }

    #[tool(
        description = "Return bounded metadata for an existing private controller configuration draft. Raw profile JSON, bindings, paths, and credentials are omitted.",
        annotations(
            title = "Get Thumble configuration draft",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn get_configuration_draft(
        &self,
        Parameters(params): Parameters<GetConfigurationDraftParams>,
    ) -> Result<Json<ConfigurationDraftResult>, String> {
        let response = self
            .request(
                "get_configuration_draft",
                ControlRequest::GetConfigurationDraft {
                    draft_id: params.draft_id,
                },
            )
            .await?;
        Ok(Json(
            response
                .draft
                .ok_or_else(|| "Thumble Host returned no configuration draft".to_owned())?
                .into(),
        ))
    }

    #[tool(
        description = "Apply one typed, allowlisted operation to a private configuration draft. Requires the exact current draft revision and a caller-generated operation UUID; exact retries are idempotent. Supports versioned built-in generation and template installation plus profile, deterministic seven-kind layout repair, theme, orientation, element, layer-order, layer-group, and semantic-binding operations published in the configuration operation schema, without arbitrary JSON patches, raw key codes, paths, or commands.",
        annotations(
            title = "Edit Thumble configuration draft",
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = false,
            open_world_hint = false
        )
    )]
    pub async fn edit_configuration_draft(
        &self,
        Parameters(params): Parameters<EditConfigurationDraftParams>,
    ) -> Result<Json<EditConfigurationDraftResult>, String> {
        let response = self
            .request(
                "edit_configuration_draft",
                ControlRequest::EditConfigurationDraft {
                    draft_id: params.draft_id,
                    expected_draft_revision: params.expected_draft_revision,
                    operation_id: params.operation_id,
                    operation: params.operation.into(),
                },
            )
            .await?;
        let draft = response
            .draft
            .ok_or_else(|| "Thumble Host returned no edited draft".to_owned())?;
        let outcome = response
            .draft_operation
            .ok_or_else(|| "Thumble Host returned no draft operation outcome".to_owned())?;
        Ok(Json(EditConfigurationDraftResult {
            draft: draft.into(),
            changed: outcome.changed,
            changed_paths: outcome.changed_paths,
            idempotent_replay: response.idempotent_replay.unwrap_or(false),
        }))
    }

    #[tool(
        description = "Explicitly rebase a stale private draft onto an exact current authoritative configuration revision using a lossless three-way semantic merge. Disjoint changes and stable-ID collections merge; overlapping scalar edits, delete-versus-edit, and incompatible reorders return bounded conflict paths without changing the draft. Exact rebase UUID retries are idempotent.",
        annotations(
            title = "Rebase Thumble configuration draft",
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = false,
            open_world_hint = false
        )
    )]
    pub async fn rebase_configuration_draft(
        &self,
        Parameters(params): Parameters<RebaseConfigurationDraftParams>,
    ) -> Result<Json<EditConfigurationDraftResult>, String> {
        let response = self
            .request(
                "rebase_configuration_draft",
                ControlRequest::RebaseConfigurationDraft {
                    draft_id: params.draft_id,
                    expected_draft_revision: params.expected_draft_revision,
                    expected_configuration_revision: params.expected_configuration_revision,
                    rebase_id: params.rebase_id,
                },
            )
            .await?;
        let draft = response
            .draft
            .ok_or_else(|| "Thumble Host returned no rebased draft".to_owned())?;
        let outcome = response
            .draft_operation
            .ok_or_else(|| "Thumble Host returned no rebase outcome".to_owned())?;
        Ok(Json(EditConfigurationDraftResult {
            draft: draft.into(),
            changed: outcome.changed,
            changed_paths: outcome.changed_paths,
            idempotent_replay: response.idempotent_replay.unwrap_or(false),
        }))
    }

    #[tool(
        description = "Validate a private configuration draft at an exact draft revision. Returns structural and canonical-validator status without changing the authoritative configuration or phone.",
        annotations(
            title = "Validate Thumble configuration draft",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn validate_configuration_draft(
        &self,
        Parameters(params): Parameters<DraftRevisionParams>,
    ) -> Result<Json<ValidateConfigurationDraftResult>, String> {
        let response = self
            .request(
                "validate_configuration_draft",
                ControlRequest::ValidateConfigurationDraft {
                    draft_id: params.draft_id,
                    expected_draft_revision: params.expected_draft_revision,
                },
            )
            .await?;
        let validation = response
            .validation
            .ok_or_else(|| "Thumble Host returned no draft validation".to_owned())?;
        Ok(Json(ValidateConfigurationDraftResult {
            draft_id: validation.draft_id,
            draft_revision: validation.draft_revision,
            valid: validation.valid,
            error_count: validation.error_count,
            warning_count: validation.warning_count,
            validator: validation.validator,
        }))
    }

    #[tool(
        description = "Render a private draft at an exact draft revision as bounded controller geometry, ordered layers/groups, style assignments, and sanitized reusable style definitions. Asset/image/path-bearing style content is omitted. The authoritative active profile and paired phone are not changed.",
        meta = controller_editor_ui_tool_meta(),
        annotations(
            title = "Preview Thumble configuration draft",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn preview_configuration_draft(
        &self,
        Parameters(params): Parameters<DraftRevisionParams>,
    ) -> Result<Json<PreviewConfigurationDraftResult>, String> {
        let response = self
            .request(
                "preview_configuration_draft",
                ControlRequest::PreviewConfigurationDraft {
                    draft_id: params.draft_id,
                    expected_draft_revision: params.expected_draft_revision,
                },
            )
            .await?;
        let draft = response
            .draft
            .ok_or_else(|| "Thumble Host returned no preview draft metadata".to_owned())?;
        let controller = response
            .controller
            .ok_or_else(|| "Thumble Host returned no draft controller preview".to_owned())?;
        let editable_variant = response
            .editable_variant
            .ok_or_else(|| "Thumble Host returned no editable draft variant".to_owned())?;
        Ok(Json(PreviewConfigurationDraftResult {
            controller: RenderControllerResult::from_snapshot(
                controller,
                draft.base_configuration_revision,
            ),
            draft: draft.into(),
            editable_variant,
        }))
    }

    #[tool(
        description = "Export an exact private draft revision as a bounded self-contained script-free SVG preview. The export includes only credential-free controller geometry and labels; it excludes bindings, outputs, assets, launch targets, raw profile JSON, and host secrets. It never changes the authoritative configuration or paired phone.",
        annotations(
            title = "Export Thumble controller draft preview",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn export_controller_preview(
        &self,
        Parameters(params): Parameters<ExportControllerPreviewParams>,
    ) -> Result<Json<ExportControllerPreviewResult>, String> {
        let response = self
            .request(
                "export_controller_preview",
                ControlRequest::PreviewConfigurationDraft {
                    draft_id: params.draft_id,
                    expected_draft_revision: params.expected_draft_revision,
                },
            )
            .await?;
        let draft = response
            .draft
            .ok_or_else(|| "Thumble Host returned no export draft metadata".to_owned())?;
        let controller = response
            .controller
            .ok_or_else(|| "Thumble Host returned no export controller preview".to_owned())?;
        let rendered =
            RenderControllerResult::from_snapshot(controller, draft.base_configuration_revision);
        let svg = controller_preview_svg(&rendered)?;
        let digest = Sha256::digest(svg.as_bytes());
        Ok(Json(ExportControllerPreviewResult {
            draft_id: draft.draft_id,
            draft_revision: draft.draft_revision,
            profile_id: rendered.profile.id,
            profile_name: rendered.profile.name,
            mime_type: "image/svg+xml".to_owned(),
            byte_length: u64::try_from(svg.len()).unwrap_or(u64::MAX),
            sha256: format!("{digest:x}"),
            svg,
        }))
    }

    #[tool(
        description = "Atomically save a validated private configuration draft using exact draft and authoritative revisions plus a caller-generated commit UUID. This may change or delete controller configuration and synchronizes the committed state to a paired phone. Requires independent config-write opt-in on both thumble-mcp and thumble-host.",
        annotations(
            title = "Save Thumble configuration draft",
            read_only_hint = false,
            destructive_hint = true,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn save_configuration_draft(
        &self,
        Parameters(params): Parameters<SaveConfigurationDraftParams>,
    ) -> Result<Json<SaveConfigurationDraftResult>, String> {
        if !self.allow_config_write {
            audit("save_configuration_draft", "rejected");
            return Err(
                "MCP configuration writes are disabled; restart thumble-mcp with --allow-config-write after explicit user approval"
                    .to_owned(),
            );
        }
        let response = self
            .request(
                "save_configuration_draft",
                ControlRequest::SaveConfigurationDraft {
                    draft_id: params.draft_id,
                    expected_draft_revision: params.expected_draft_revision,
                    expected_configuration_revision: params.expected_configuration_revision,
                    commit_id: params.commit_id,
                },
            )
            .await?;
        let save = response
            .save
            .ok_or_else(|| "Thumble Host returned no configuration commit result".to_owned())?;
        Ok(Json(SaveConfigurationDraftResult {
            draft_id: save.draft_id,
            commit_id: save.commit_id,
            base_configuration_revision: save.base_configuration_revision,
            configuration_revision: save.configuration_revision,
            draft_revision: save.draft_revision,
            changed: save.changed,
            idempotent_replay: save.idempotent_replay,
            phone_sync_queued: save.phone_sync_queued,
        }))
    }

    #[tool(
        description = "Discard unsaved controller configuration work using the exact current draft revision. This never changes the authoritative host configuration or paired phone.",
        annotations(
            title = "Discard Thumble configuration draft",
            read_only_hint = false,
            destructive_hint = true,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn discard_configuration_draft(
        &self,
        Parameters(params): Parameters<DiscardConfigurationDraftParams>,
    ) -> Result<Json<DiscardConfigurationDraftResult>, String> {
        let response = self
            .request(
                "discard_configuration_draft",
                ControlRequest::DiscardConfigurationDraft {
                    draft_id: params.draft_id,
                    expected_draft_revision: params.expected_draft_revision,
                },
            )
            .await?;
        Ok(Json(DiscardConfigurationDraftResult {
            draft_id: response
                .discarded_draft_id
                .ok_or_else(|| "Thumble Host returned no discarded draft ID".to_owned())?,
            discarded: true,
        }))
    }

    #[tool(
        description = "Return the host's six-digit iPhone pairing code. Set rotate=true only when the user explicitly asks for a new code. Never persist or publish the returned code.",
        annotations(
            title = "Thumble pairing code",
            read_only_hint = false,
            destructive_hint = true,
            idempotent_hint = false,
            open_world_hint = false
        )
    )]
    pub async fn pairing_code(
        &self,
        Parameters(params): Parameters<PairingCodeParams>,
    ) -> Result<Json<PairingCodeResult>, String> {
        let rotate = params.rotate.unwrap_or(false);
        let response = self
            .request("pairing_code", ControlRequest::PairingCode { rotate })
            .await?;
        Ok(Json(PairingCodeResult {
            pairing_code: response
                .pairing_code
                .ok_or_else(|| "Thumble Host returned no pairing code".to_owned())?,
            rotated: response.rotated.unwrap_or(rotate),
        }))
    }

    #[tool(
        description = "Return a bounded built-in controller-template or device-frame catalog, optionally filtered by exact ID. Results contain only safe display metadata and checked-in IDs; no raw profile JSON, bindings, custom dimensions, assets, paths, or credentials are returned.",
        annotations(
            title = "Query Thumble built-in catalog",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn query_catalog(
        &self,
        Parameters(params): Parameters<QueryCatalogParams>,
    ) -> Result<Json<QueryCatalogResult>, String> {
        match params.catalog {
            CatalogInput::ControllerTemplates => {
                if params.frame_id.is_some() {
                    return Err("frameID is valid only for the device-frames catalog".to_owned());
                }
                let manifest: ControllerTemplateCatalogManifest =
                    serde_json::from_str(CONTROLLER_TEMPLATE_CATALOG_JSON)
                        .map_err(|_| "Thumble template catalog is unavailable".to_owned())?;
                if manifest.schema != "com.codybontecou.thumble.controller-templates"
                    || manifest.version != 1
                    || manifest.templates.len() != ControllerTemplate::ALL.len()
                    || manifest.templates.iter().zip(ControllerTemplate::ALL).any(
                        |(entry, template)| {
                            entry.id != template.id()
                                || entry.name != template.display_name()
                                || entry.revision != template.revision()
                                || entry.custom_element_id_count
                                    != template.custom_element_id_count()
                                || entry.description.is_empty()
                                || entry.description.chars().count() > 512
                        },
                    )
                {
                    return Err("Thumble template catalog is invalid".to_owned());
                }
                let template_id = params.template.map(|template| {
                    let template: ControllerTemplate = template.into();
                    template.id()
                });
                let templates = manifest
                    .templates
                    .into_iter()
                    .filter(|entry| template_id.is_none_or(|id| entry.id == id))
                    .collect::<Vec<_>>();
                if template_id.is_some() && templates.len() != 1 {
                    return Err("Requested Thumble template is unavailable".to_owned());
                }
                Ok(Json(QueryCatalogResult {
                    catalog: "controller-templates".to_owned(),
                    version: manifest.version,
                    templates,
                    device_frames: Vec::new(),
                }))
            }
            CatalogInput::DeviceFrames => {
                if params.template.is_some() {
                    return Err(
                        "template is valid only for the controller-templates catalog".to_owned(),
                    );
                }
                let manifest: DeviceFrameCatalogManifest =
                    serde_json::from_str(DEVICE_FRAME_CATALOG_JSON)
                        .map_err(|_| "Thumble device-frame catalog is unavailable".to_owned())?;
                let mut ids = std::collections::HashSet::new();
                if manifest.schema != "com.codybontecou.thumble.device-frames"
                    || manifest.version != 1
                    || manifest.frames.len() != 68
                    || manifest.frames.iter().any(|entry| {
                        !thumble_host::draft_operation::is_supported_device_frame_id(&entry.id)
                            || !ids.insert(entry.id.as_str())
                            || entry.device.is_empty()
                            || entry.device.chars().count() > 128
                            || !matches!(entry.orientation.as_str(), "portrait" | "landscape")
                            || !entry.id.ends_with(&format!("-{}", entry.orientation))
                            || !(240.0..=1800.0).contains(&entry.width)
                            || !(240.0..=1800.0).contains(&entry.height)
                            || !matches!(
                                entry.frame_style.as_str(),
                                "dynamicIsland" | "notch" | "homeButton"
                            )
                    })
                {
                    return Err("Thumble device-frame catalog is invalid".to_owned());
                }
                if let Some(frame_id) = params.frame_id.as_deref() {
                    if !thumble_host::draft_operation::is_supported_device_frame_id(frame_id) {
                        return Err("Requested Thumble device frame is unavailable".to_owned());
                    }
                }
                let frames = manifest
                    .frames
                    .into_iter()
                    .filter(|entry| params.frame_id.as_ref().is_none_or(|id| entry.id == *id))
                    .collect::<Vec<_>>();
                if params.frame_id.is_some() && frames.len() != 1 {
                    return Err("Requested Thumble device frame is unavailable".to_owned());
                }
                Ok(Json(QueryCatalogResult {
                    catalog: "device-frames".to_owned(),
                    version: manifest.version,
                    templates: Vec::new(),
                    device_frames: frames,
                }))
            }
        }
    }

    #[tool(
        description = "List installed Thumble profiles using only IDs, names, and active/default flags. Raw profile JSON and keyboard bindings are never returned.",
        annotations(
            title = "List Thumble profiles",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn list_profiles(&self) -> Result<Json<ListProfilesResult>, String> {
        let response = self
            .request("list_profiles", ControlRequest::ListProfiles)
            .await?;
        Ok(Json(ListProfilesResult {
            configuration_revision: response
                .configuration_revision
                .ok_or_else(|| "Thumble Host returned no configuration revision".to_owned())?,
            active_profile_id: response
                .active_profile_id
                .ok_or_else(|| "Thumble Host returned no active profile ID".to_owned())?,
            profiles: response
                .profiles
                .unwrap_or_default()
                .into_iter()
                .map(|profile| ProfileResult {
                    id: profile.id,
                    name: profile.name,
                    active: profile.active,
                    default: profile.default,
                })
                .collect(),
        }))
    }

    #[tool(
        description = "List the active profile's executable keyboard controls. Use the returned opaque controlId verbatim with press_control; never guess or construct an ID. Raw key codes are never returned.",
        annotations(
            title = "List active Thumble controls",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn list_controls(&self) -> Result<Json<ListControlsResult>, String> {
        let response = self
            .request("list_controls", ControlRequest::ListControls)
            .await?;
        Ok(Json(ListControlsResult {
            configuration_revision: response
                .configuration_revision
                .ok_or_else(|| "Thumble Host returned no configuration revision".to_owned())?,
            active_profile_id: response
                .active_profile_id
                .ok_or_else(|| "Thumble Host returned no active profile ID".to_owned())?,
            controls: response
                .controls
                .unwrap_or_default()
                .into_iter()
                .map(|control| InstalledControlResult {
                    control_id: control.control_id,
                    label: control.label,
                    kind: control.kind,
                    part: element_part_name(control.part).to_owned(),
                })
                .collect(),
        }))
    }

    #[tool(
        description = "Render the active Thumble controller as a read-only interactive MCP App. Returns bounded profile identity, canvas geometry, control frames, labels, kinds, shapes, ordered layers/groups, style assignments, and sanitized reusable style definitions; bindings, outputs, assets, paths, and credentials are omitted.",
        meta = controller_ui_tool_meta(),
        annotations(
            title = "Render Thumble controller",
            read_only_hint = true,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn render_controller(&self) -> Result<Json<RenderControllerResult>, String> {
        let response = self
            .request("render_controller", ControlRequest::RenderController)
            .await?;
        let controller = response
            .controller
            .ok_or_else(|| "Thumble Host returned no controller snapshot".to_owned())?;
        let configuration_revision = response
            .configuration_revision
            .ok_or_else(|| "Thumble Host returned no configuration revision".to_owned())?;
        Ok(Json(RenderControllerResult::from_snapshot(
            controller,
            configuration_revision,
        )))
    }

    #[tool(
        description = "Select an installed Thumble profile by an exact profileId from list_profiles. This releases held controls before changing profiles and synchronizes an attached iPhone.",
        annotations(
            title = "Select Thumble profile",
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn select_profile(
        &self,
        Parameters(params): Parameters<SelectProfileParams>,
    ) -> Result<Json<SelectProfileResult>, String> {
        let response = self
            .request(
                "select_profile",
                ControlRequest::SelectProfile {
                    profile_id: params.profile_id,
                },
            )
            .await?;
        Ok(Json(SelectProfileResult {
            profile_id: response
                .selected_profile_id
                .ok_or_else(|| "Thumble Host returned no selected profile ID".to_owned())?,
            changed: response.profile_changed.unwrap_or(false),
            configuration_revision: response
                .configuration_revision
                .ok_or_else(|| "Thumble Host returned no configuration revision".to_owned())?,
        }))
    }

    #[tool(
        description = "Tap one installed active-profile control, automatically releasing it. Requires thumble-mcp --allow-input, host input mode, and macOS Accessibility permission. Accepts only an exact opaque controlId returned by list_controls; arbitrary keys, text, and shell commands are impossible.",
        annotations(
            title = "Press Thumble control",
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = false,
            open_world_hint = true
        )
    )]
    pub async fn press_control(
        &self,
        Parameters(params): Parameters<PressControlParams>,
    ) -> Result<Json<PressControlResult>, String> {
        if !self.allow_input {
            audit("press_control", "rejected");
            return Err(
                "MCP input is disabled; restart thumble-mcp with --allow-input after explicit user approval"
                    .to_owned(),
            );
        }
        self.press_limiter
            .lock()
            .map_err(|_| "MCP input rate limiter failed".to_owned())?
            .allow()
            .inspect_err(|_| audit("press_control", "rate-limited"))?;
        let response = self
            .request(
                "press_control",
                ControlRequest::PressControl {
                    control_id: params.control_id,
                },
            )
            .await?;
        Ok(Json(PressControlResult {
            control_id: response
                .pressed_control_id
                .ok_or_else(|| "Thumble Host returned no pressed control ID".to_owned())?,
            executed: true,
        }))
    }

    #[tool(
        description = "Emergency release of every keyboard key and pointer button tracked by Thumble Host. This remains available even when MCP input is disabled or rate-limited.",
        annotations(
            title = "Release all Thumble input",
            read_only_hint = false,
            destructive_hint = false,
            idempotent_hint = true,
            open_world_hint = false
        )
    )]
    pub async fn release_all(&self) -> Result<Json<ReleaseAllResult>, String> {
        let response = self
            .request("release_all", ControlRequest::ReleaseAll)
            .await?;
        Ok(Json(ReleaseAllResult {
            released: response.released.unwrap_or(false),
        }))
    }

    async fn request(
        &self,
        tool_name: &'static str,
        request: ControlRequest,
    ) -> Result<ControlResponse, String> {
        audit(tool_name, "started");
        let response = match self.channel.request(request).await {
            Ok(response) => response,
            Err(error) => {
                audit(tool_name, "unavailable");
                return Err(format!(
                    "Thumble Host is unavailable: {error}. Start thumble-host first"
                ));
            }
        };
        if !response.ok {
            audit(tool_name, "failed");
            let mut error = response
                .error
                .unwrap_or_else(|| "Thumble Host rejected the request".to_owned());
            if let Some(code) = response.error_code {
                error.push_str(&format!(" [code={code}]"));
            }
            if let (Some(expected), Some(actual)) =
                (response.expected_revision, response.actual_revision)
            {
                error.push_str(&format!(
                    " [expectedRevision={expected}, actualRevision={actual}]"
                ));
            }
            if let Some(paths) = response.conflict_paths {
                error.push_str(&format!(" [conflictPaths={}]", paths.join(",")));
            }
            return Err(error);
        }
        audit(tool_name, "succeeded");
        Ok(response)
    }
}

#[tool_handler(router = self.tool_router)]
impl ServerHandler for ThumbleMcp {
    fn get_info(&self) -> ServerInfo {
        ServerInfo::new(
            ServerCapabilities::builder()
                .enable_resources()
                .enable_tools()
                .build(),
        )
        .with_server_info(thumble_server_implementation())
        .with_instructions(
            "Control a running local Thumble Host through installed profiles and revision-safe private configuration drafts. Call configuration_status before beginning draft work and pass every exact revision returned by the host. Use render_controller for the authoritative read-only visual preview. Input injection is disabled unless the server was explicitly launched with --allow-input. Always call list_controls before press_control, never guess IDs, and use release_all if control state is uncertain. Authentication tokens, raw key codes, arbitrary process arguments, typed input text, and shell execution are not exposed.",
        )
    }

    async fn list_resources(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListResourcesResult, ErrorData> {
        let preview_size = u64::try_from(CONTROLLER_UI_HTML.len()).unwrap_or(u64::MAX);
        let editor_size = u64::try_from(CONTROLLER_EDITOR_UI_HTML.len()).unwrap_or(u64::MAX);
        let operation_schema_size =
            u64::try_from(CONFIGURATION_OPERATION_SCHEMA_JSON.len()).unwrap_or(u64::MAX);
        let capabilities_size = u64::try_from(CLI_CAPABILITIES_JSON.len()).unwrap_or(u64::MAX);
        Ok(ListResourcesResult::with_all_items(vec![
            Resource::new(CONTROLLER_UI_URI, "thumble-controller-builder")
                .with_title("Thumble Controller Preview")
                .with_description(
                    "Read-only interactive visualization of a Thumble controller snapshot",
                )
                .with_mime_type(CONTROLLER_UI_MIME_TYPE)
                .with_size(preview_size),
            Resource::new(CONTROLLER_EDITOR_UI_URI, "thumble-controller-editor")
                .with_title("Thumble Controller Draft Editor")
                .with_description(
                    "Revision-safe controller draft editor with explicit validation, save, and discard",
                )
                .with_mime_type(CONTROLLER_UI_MIME_TYPE)
                .with_size(editor_size),
            Resource::new(
                CONFIGURATION_OPERATION_SCHEMA_URI,
                "thumble-configuration-operation-schema",
            )
            .with_title("Thumble Configuration Operation Schema v1")
            .with_description("Typed allowlisted draft operations accepted by the current host")
            .with_mime_type("application/schema+json")
            .with_size(operation_schema_size),
            Resource::new(CLI_CAPABILITIES_URI, "thumble-cli-capabilities")
                .with_title("Thumble CLI Capability Ledger v1")
                .with_description(
                    "Machine-readable current, partial, foundation, and planned MCP parity status",
                )
                .with_mime_type("application/json")
                .with_size(capabilities_size),
        ]))
    }

    async fn read_resource(
        &self,
        request: ReadResourceRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<ReadResourceResponse, ErrorData> {
        let (content, mime_type) = match request.uri.as_str() {
            CONTROLLER_UI_URI => (CONTROLLER_UI_HTML, CONTROLLER_UI_MIME_TYPE),
            CONTROLLER_EDITOR_UI_URI => (CONTROLLER_EDITOR_UI_HTML, CONTROLLER_UI_MIME_TYPE),
            CONFIGURATION_OPERATION_SCHEMA_URI => (
                CONFIGURATION_OPERATION_SCHEMA_JSON,
                "application/schema+json",
            ),
            CLI_CAPABILITIES_URI => (CLI_CAPABILITIES_JSON, "application/json"),
            _ => {
                return Err(ErrorData::resource_not_found(
                    "controller UI resource not found",
                    None,
                ));
            }
        };
        let resource_meta = serde_json::json!({
            "ui": {
                "prefersBorder": false
            }
        });
        Ok(
            ReadResourceResult::new(vec![ResourceContents::text(content, request.uri)
                .with_mime_type(mime_type)
                .with_meta(MetaObject(
                    resource_meta.as_object().cloned().unwrap_or_default(),
                ))])
            .into(),
        )
    }
}

fn audit(tool_name: &'static str, outcome: &'static str) {
    eprintln!("thumble-mcp tool={tool_name} outcome={outcome}");
}

const fn element_part_name(part: thumble_protocol::KeypadElementInputPart) -> &'static str {
    match part {
        thumble_protocol::KeypadElementInputPart::Primary => "primary",
        thumble_protocol::KeypadElementInputPart::JoystickUp => "joystick_up",
        thumble_protocol::KeypadElementInputPart::JoystickDown => "joystick_down",
        thumble_protocol::KeypadElementInputPart::JoystickLeft => "joystick_left",
        thumble_protocol::KeypadElementInputPart::JoystickRight => "joystick_right",
        thumble_protocol::KeypadElementInputPart::TriggerDigital => "trigger_digital",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rmcp::{
        model::{CallToolRequestParams, ProtocolVersion},
        ServiceExt,
    };
    use std::os::unix::fs::PermissionsExt;
    use std::path::PathBuf;
    use std::sync::Arc;
    use tempfile::tempdir;
    use thumble_host::control::{
        bind_control_socket, remove_control_socket, serve_control, ControlHandler,
    };
    use tokio::sync::watch;

    struct FakeHost;

    impl ControlHandler for FakeHost {
        fn handle(&self, request: ControlRequest) -> ControlResponse {
            match request {
                ControlRequest::Accessibility { .. } => {
                    let mut response = ControlResponse::success();
                    response.accessibility_trusted = Some(true);
                    response
                }
                ControlRequest::RenderController => {
                    let mut response = ControlResponse::success();
                    response.configuration_revision = Some(1);
                    response.controller = Some(thumble_core::ControllerSnapshot {
                        profile: thumble_core::ControllerProfileSnapshot {
                            id: "profile-safe".to_owned(),
                            name: "Arcade Layout".to_owned(),
                            orientation_preference: "automatic".to_owned(),
                        },
                        orientation: thumble_core::ControllerOrientation::Landscape,
                        color_scheme_preference: "dark".to_owned(),
                        accent_style: "purple".to_owned(),
                        shows_button_labels: true,
                        canvas: thumble_core::ControllerCanvasSnapshot {
                            frame_id: "iphone-17-pro-landscape".to_owned(),
                            width: 874.0,
                            height: 402.0,
                            fill: None,
                            light_fill: None,
                            dark_fill: Some(serde_json::json!({
                                "kind":"solid",
                                "color":{"red":0.02,"green":0.03,"blue":0.04,"alpha":1}
                            })),
                            unsupported_content_omitted: false,
                        },
                        control_bar_items: vec![thumble_core::ControllerControlBarItemSnapshot {
                            item: "settings".to_owned(),
                            target_id: "control_bar_item.settings".to_owned(),
                            index: 0,
                            is_hidden: false,
                            width_scale: 1.5,
                            height_scale: 1.0,
                            shape: Some("capsule".to_owned()),
                            accent_style: Some("purple".to_owned()),
                            corner_radius: None,
                            corner_radii: None,
                            shadow_strength: 0.5,
                            fill: Some(serde_json::json!({
                                "kind":"solid",
                                "color":{"red":0.1,"green":0.2,"blue":0.3,"alpha":1}
                            })),
                            light_fill: None,
                            dark_fill: None,
                            style_id: Some("soft-white-raised".to_owned()),
                            inline_appearance: None,
                            icon: None,
                            haptic: None,
                            unsupported_content_omitted: false,
                        }],
                        groups: vec![thumble_core::ControllerGroupSnapshot {
                            id: "00000000-0000-0000-0000-000000000701".to_owned(),
                            name: "Actions".to_owned(),
                            child_target_ids: vec!["element-safe".to_owned()],
                            child_stable_ids: vec!["builtin.jump".to_owned()],
                            is_locked: false,
                            is_hidden: false,
                        }],
                        layers: vec![thumble_core::ControllerLayerSnapshot {
                            target_id: "element-safe".to_owned(),
                            stable_id: "builtin.jump".to_owned(),
                            label: "Jump".to_owned(),
                            kind: "button".to_owned(),
                            z_index: 1,
                            is_hidden: false,
                            is_location_locked: false,
                            style_id: Some("soft-white-raised".to_owned()),
                        }],
                        styles: Vec::new(),
                        layout_quality: thumble_core::ControllerLayoutQualitySnapshot::default(),
                        elements: vec![thumble_core::ControllerElementSnapshot {
                            id: "element-safe".to_owned(),
                            label: "Jump".to_owned(),
                            kind: "button".to_owned(),
                            shape: "circle".to_owned(),
                            frame: thumble_core::ControllerFrameSnapshot {
                                x: 700.0,
                                y: 250.0,
                                width: 72.0,
                                height: 72.0,
                            },
                            rotation_degrees: 0.0,
                            z_index: 1,
                            ..Default::default()
                        }],
                    });
                    response
                }
                ControlRequest::PreviewConfigurationDraft { .. } => {
                    let mut response = ControlResponse::success();
                    response.draft = Some(ConfigurationDraftSummary {
                        draft_id: "00000000-0000-0000-0000-000000000301".to_owned(),
                        base_configuration_revision: 1,
                        draft_revision: 2,
                        profile_count: 1,
                        active_profile_id: "profile-safe".to_owned(),
                        default_profile_id: "profile-safe".to_owned(),
                        operation_count: 1,
                        created_at: 1,
                        updated_at: 2,
                        expires_at: 86_400_001,
                    });
                    response.editable_variant = Some("primary".to_owned());
                    response.controller = Some(thumble_core::ControllerSnapshot {
                        profile: thumble_core::ControllerProfileSnapshot {
                            id: "profile-safe".to_owned(),
                            name: "Draft <Arcade>".to_owned(),
                            orientation_preference: "automatic".to_owned(),
                        },
                        orientation: thumble_core::ControllerOrientation::Landscape,
                        color_scheme_preference: "system".to_owned(),
                        accent_style: "monochrome".to_owned(),
                        shows_button_labels: true,
                        canvas: thumble_core::ControllerCanvasSnapshot {
                            frame_id: "iphone-17-pro-landscape".to_owned(),
                            width: 874.0,
                            height: 402.0,
                            fill: None,
                            light_fill: None,
                            dark_fill: None,
                            unsupported_content_omitted: false,
                        },
                        control_bar_items: Vec::new(),
                        groups: Vec::new(),
                        layers: vec![thumble_core::ControllerLayerSnapshot {
                            target_id: "element-safe".to_owned(),
                            stable_id: "builtin.jump".to_owned(),
                            label: "<script>alert(1)</script>& Jump".to_owned(),
                            kind: "button".to_owned(),
                            z_index: 1,
                            is_hidden: false,
                            is_location_locked: false,
                            style_id: None,
                        }],
                        styles: Vec::new(),
                        layout_quality: thumble_core::ControllerLayoutQualitySnapshot::default(),
                        elements: vec![thumble_core::ControllerElementSnapshot {
                            id: "element-safe".to_owned(),
                            label: "<script>alert(1)</script>& Jump".to_owned(),
                            kind: "button".to_owned(),
                            shape: "circle".to_owned(),
                            frame: thumble_core::ControllerFrameSnapshot {
                                x: 700.0,
                                y: 250.0,
                                width: 72.0,
                                height: 72.0,
                            },
                            rotation_degrees: 0.0,
                            z_index: 1,
                            shows_integrated_label: true,
                            fill: Some(serde_json::json!({
                                "kind":"solid",
                                "color":{"red":0.12,"green":0.34,"blue":0.78,"alpha":1}
                            })),
                            ..Default::default()
                        }],
                    });
                    response
                }
                ControlRequest::ConfigurationStatus => {
                    let mut response = ControlResponse::success();
                    response.configuration =
                        Some(thumble_host::control::ConfigurationStatusSummary {
                            configuration_revision: 1,
                            profile_count: 1,
                            active_profile_id: "profile-safe".to_owned(),
                            default_profile_id: "profile-safe".to_owned(),
                            maximum_live_drafts: 8,
                            draft_lifetime_millis: 86_400_000,
                            operation_schema_version: 1,
                            bridge_available: false,
                            configuration_write_enabled: true,
                        });
                    response
                }
                ControlRequest::BeginConfigurationDraft {
                    expected_configuration_revision: 1,
                }
                | ControlRequest::GetConfigurationDraft { .. } => {
                    let mut response = ControlResponse::success();
                    response.draft = Some(ConfigurationDraftSummary {
                        draft_id: "00000000-0000-0000-0000-000000000301".to_owned(),
                        base_configuration_revision: 1,
                        draft_revision: 1,
                        profile_count: 1,
                        active_profile_id: "profile-safe".to_owned(),
                        default_profile_id: "profile-safe".to_owned(),
                        operation_count: 0,
                        created_at: 1,
                        updated_at: 1,
                        expires_at: 86_400_001,
                    });
                    response
                }
                ControlRequest::EditConfigurationDraft { .. } => {
                    let mut response = ControlResponse::success();
                    response.draft = Some(ConfigurationDraftSummary {
                        draft_id: "00000000-0000-0000-0000-000000000301".to_owned(),
                        base_configuration_revision: 1,
                        draft_revision: 2,
                        profile_count: 1,
                        active_profile_id: "profile-safe".to_owned(),
                        default_profile_id: "profile-safe".to_owned(),
                        operation_count: 1,
                        created_at: 1,
                        updated_at: 2,
                        expires_at: 86_400_001,
                    });
                    response.draft_operation = Some(
                        thumble_host::draft_operation::ConfigurationOperationOutcome {
                            changed: true,
                            changed_paths: vec!["profiles/profile-safe/name".to_owned()],
                        },
                    );
                    response.idempotent_replay = Some(false);
                    response
                }
                ControlRequest::RebaseConfigurationDraft { .. } => {
                    let mut response = ControlResponse::success();
                    response.draft = Some(ConfigurationDraftSummary {
                        draft_id: "00000000-0000-0000-0000-000000000301".to_owned(),
                        base_configuration_revision: 2,
                        draft_revision: 3,
                        profile_count: 1,
                        active_profile_id: "profile-safe".to_owned(),
                        default_profile_id: "profile-safe".to_owned(),
                        operation_count: 2,
                        created_at: 1,
                        updated_at: 3,
                        expires_at: 86_400_001,
                    });
                    response.draft_operation = Some(
                        thumble_host::draft_operation::ConfigurationOperationOutcome {
                            changed: true,
                            changed_paths: vec!["/profiles".to_owned()],
                        },
                    );
                    response.idempotent_replay = Some(false);
                    response
                }
                ControlRequest::ValidateConfigurationDraft { .. } => {
                    let mut response = ControlResponse::success();
                    response.validation =
                        Some(thumble_host::control::ConfigurationValidationSummary {
                            draft_id: "00000000-0000-0000-0000-000000000301".to_owned(),
                            draft_revision: 2,
                            valid: true,
                            error_count: 0,
                            warning_count: 1,
                            validator: "rust-structural-v1".to_owned(),
                        });
                    response
                }
                ControlRequest::SaveConfigurationDraft { commit_id, .. } => {
                    let mut response = ControlResponse::success();
                    response.save = Some(thumble_host::control::ConfigurationSaveSummary {
                        draft_id: "00000000-0000-0000-0000-000000000301".to_owned(),
                        commit_id,
                        base_configuration_revision: 1,
                        configuration_revision: 2,
                        draft_revision: 2,
                        changed: true,
                        idempotent_replay: false,
                        phone_sync_queued: true,
                    });
                    response
                }
                ControlRequest::DiscardConfigurationDraft { draft_id, .. } => {
                    let mut response = ControlResponse::success();
                    response.discarded_draft_id = Some(draft_id);
                    response
                }
                ControlRequest::PressControl { control_id } if control_id == "button:jump" => {
                    let mut response = ControlResponse::success();
                    response.pressed_control_id = Some(control_id);
                    response
                }
                ControlRequest::PressControl { .. } => {
                    ControlResponse::error("control is not installed in the active profile")
                }
                ControlRequest::ReleaseAll => {
                    let mut response = ControlResponse::success();
                    response.released = Some(true);
                    response
                }
                _ => ControlResponse::error("unexpected fake-host request"),
            }
        }
    }

    #[test]
    fn style_input_is_typed_and_rejects_assets_paths_and_raw_payloads() {
        let base = serde_json::json!({
            "type":"style.create",
            "profileID":"00000000-0000-0000-0000-000000000001",
            "styleID":"agent-style",
            "name":"Agent Style",
            "appearance":{
                "materialPreset":"soft-white-raised",
                "icon":{"source":"sf_symbol","value":"star.fill"},
                "haptic":{"style":"soft","pattern":"double"}
            }
        });
        let operation: ConfigurationOperationInput = serde_json::from_value(base.clone()).unwrap();
        let host: ConfigurationOperation = operation.into();
        assert_eq!(host.validate_bridge_input(), Ok(()));
        for appearance in [
            serde_json::json!({"assetID":"private"}),
            serde_json::json!({"path":"/tmp/private.png"}),
            serde_json::json!({"icon":{"source":"asset","value":"private"}}),
            serde_json::json!({"raw":{"normal":{}}}),
        ] {
            let mut invalid = base.clone();
            invalid["appearance"] = appearance;
            assert!(serde_json::from_value::<ConfigurationOperationInput>(invalid).is_err());
        }
    }

    #[test]
    fn control_bar_item_set_input_converts_only_typed_non_file_changes() {
        let base = serde_json::json!({
            "type":"control-bar.item.set",
            "profileID":"00000000-0000-0000-0000-000000000001",
            "variant":"primary",
            "item":"settings",
            "changes":{
                "widthScale":1.5,
                "shape":"capsule",
                "fill":{"kind":"solid","color":{"red":0.1,"green":0.2,"blue":0.3,"alpha":1}},
                "icon":{"source":"sf_symbol","value":"gearshape.fill"},
                "haptic":{"style":"rigid","pattern":"double"}
            }
        });
        let input: ConfigurationOperationInput = serde_json::from_value(base.clone()).unwrap();
        let host: ConfigurationOperation = input.into();
        assert_eq!(host.validate_bridge_input(), Ok(()));
        assert!(matches!(
            host,
            ConfigurationOperation::ControlBarItemSet { changes, .. }
                if changes.width_scale == Some(1.5) && changes.icon.is_some()
        ));
        for (field, value) in [
            ("path", serde_json::json!("/tmp/private")),
            ("assetID", serde_json::json!("private")),
            ("fillImage", serde_json::json!({"data":"AAAA"})),
            ("raw", serde_json::json!({"isHidden":true})),
            ("centerX", serde_json::json!(0.5)),
            ("keyCode", serde_json::json!(49)),
        ] {
            let mut invalid = base.clone();
            invalid["changes"][field] = value;
            assert!(
                serde_json::from_value::<ConfigurationOperationInput>(invalid).is_err(),
                "{field}"
            );
        }
    }

    #[test]
    fn controller_apps_render_native_snapshot_appearance_instead_of_a_fixed_palette() {
        for field in [
            "colorSchemePreference",
            "accentStyle",
            "showsButtonLabels",
            "darkFill",
            "lightFill",
            "cornerRadii",
            "shadowStrength",
            "thumbFill",
            "inlineAppearance",
            "styleID",
        ] {
            assert!(
                CONTROLLER_UI_HTML.contains(field),
                "read-only UI missing {field}"
            );
            assert!(
                CONTROLLER_EDITOR_UI_HTML.contains(field),
                "draft editor UI missing {field}"
            );
        }
        assert!(CONTROLLER_UI_HTML.contains("const count = element.shape === \"star\" ? 10 : 3"));
        assert!(CONTROLLER_EDITOR_UI_HTML.contains("const count=element.shape===\"star\"?10:3"));
        assert!(CONTROLLER_UI_HTML.contains("const radians = parts.angleDegrees * Math.PI / 180"));
        assert!(!CONTROLLER_UI_HTML.contains("index < 6"));
        assert!(!CONTROLLER_UI_HTML.contains("parts.angleDegrees - 90"));
        assert!(!CONTROLLER_EDITOR_UI_HTML.contains("select(state.selectedId);setBusy(false)"));
    }

    #[test]
    fn tool_router_exposes_only_the_twenty_curated_tools() {
        let server = ThumbleMcp::new(PathBuf::from("/tmp/not-used"), false, false);
        let tools = server.tool_router.list_all();
        let schema_json = serde_json::to_string(&tools).unwrap();
        assert!(!schema_json.contains("authToken"));
        assert!(!schema_json.contains("keyCode"));
        assert!(!schema_json.contains("PocketPad"));
        assert!(!schema_json.contains("pocketpad-"));
        assert_eq!(tools.len(), 20);
        for operation in [
            "generation.generate",
            "template.install",
            "binding.clear",
            "binding.reset",
            "binding.reset-all",
            "output.mode",
            "output.set",
            "output.reset",
            "output.reset-all",
            "profile.reset",
            "customization.reset",
            "control-bar.reset",
            "control-bar.item.reset",
            "control-bar.item.set",
            "element.reset",
            "style.create",
            "style.rename",
            "style.apply",
            "style.detach",
            "style.delete",
            "group.create",
            "group.rename",
            "group.duplicate",
            "group.ungroup",
            "group.hide",
            "group.show",
            "group.lock",
            "group.unlock",
            "group.nudge",
            "group.forward",
            "group.backward",
            "group.front",
            "group.back",
        ] {
            assert!(schema_json.contains(operation));
        }
        let press_annotations = tools
            .iter()
            .find(|tool| tool.name == "press_control")
            .and_then(|tool| tool.annotations.as_ref())
            .unwrap();
        assert_eq!(press_annotations.read_only_hint, Some(false));
        assert_eq!(press_annotations.open_world_hint, Some(true));
        let render = tools
            .iter()
            .find(|tool| tool.name == "render_controller")
            .unwrap();
        assert_eq!(
            render
                .annotations
                .as_ref()
                .and_then(|annotations| annotations.read_only_hint),
            Some(true)
        );
        let render_meta = &render.meta.as_ref().unwrap().0;
        assert_eq!(
            render_meta
                .get("ui")
                .and_then(Value::as_object)
                .and_then(|ui| ui.get("resourceUri"))
                .and_then(Value::as_str),
            Some(CONTROLLER_UI_URI)
        );
        assert_eq!(
            render_meta
                .get("openai/outputTemplate")
                .and_then(Value::as_str),
            Some(CONTROLLER_UI_URI)
        );
        let editor = tools
            .iter()
            .find(|tool| tool.name == "preview_configuration_draft")
            .unwrap();
        assert_eq!(
            editor
                .meta
                .as_ref()
                .and_then(|meta| meta.0.get("ui"))
                .and_then(Value::as_object)
                .and_then(|ui| ui.get("resourceUri"))
                .and_then(Value::as_str),
            Some(CONTROLLER_EDITOR_UI_URI)
        );
        let names = tools
            .into_iter()
            .map(|tool| tool.name.into_owned())
            .collect::<Vec<_>>();
        assert_eq!(
            names,
            vec![
                "accessibility_status",
                "begin_configuration_draft",
                "configuration_status",
                "discard_configuration_draft",
                "edit_configuration_draft",
                "export_controller_preview",
                "get_configuration_draft",
                "host_status",
                "list_controls",
                "list_profiles",
                "pairing_code",
                "press_control",
                "preview_configuration_draft",
                "query_catalog",
                "rebase_configuration_draft",
                "release_all",
                "render_controller",
                "save_configuration_draft",
                "select_profile",
                "validate_configuration_draft",
            ]
        );
    }

    #[test]
    fn customization_fix_input_is_strict_canonical_and_bounded_after_conversion() {
        let valid = serde_json::json!({
            "type":"customization.fix",
            "profileID":"00000000-0000-0000-0000-000000000201",
            "variant":"portrait",
            "target":{"kind":"repair","repair":"ergonomic-auto-arrange"},
            "canvas":{"source":"size","width":600,"height":300},
            "includeLocked":false
        });
        let input: ConfigurationOperationInput = serde_json::from_value(valid).unwrap();
        let operation: ConfigurationOperation = input.into();
        assert_eq!(operation.validate_bridge_input(), Ok(()));

        for invalid in [
            serde_json::json!({
                "type":"customization.fix",
                "profileID":"00000000-0000-0000-0000-000000000201",
                "variant":"primary", "target":{"kind":"all","path":"/tmp/x"},
                "canvas":{"source":"stored"}, "includeLocked":false
            }),
            serde_json::json!({
                "type":"customization.fix",
                "profileID":"00000000-0000-0000-0000-000000000201",
                "variant":"primary", "target":{"kind":"repair","repair":"minimum-size"},
                "canvas":{"source":"stored"}, "includeLocked":false
            }),
            serde_json::json!({
                "type":"customization.fix",
                "profileID":"00000000-0000-0000-0000-000000000201",
                "variant":"primary", "target":{"kind":"all"},
                "canvas":{"source":"size","width":600}, "includeLocked":false
            }),
        ] {
            assert!(serde_json::from_value::<ConfigurationOperationInput>(invalid).is_err());
        }

        let out_of_bounds: ConfigurationOperationInput =
            serde_json::from_value(serde_json::json!({
                "type":"customization.fix",
                "profileID":"00000000-0000-0000-0000-000000000201",
                "variant":"primary", "target":{"kind":"all"},
                "canvas":{"source":"size","width":239,"height":300}, "includeLocked":false
            }))
            .unwrap();
        assert!(ConfigurationOperation::from(out_of_bounds)
            .validate_bridge_input()
            .is_err());
    }

    #[tokio::test]
    async fn disabled_input_fails_before_touching_the_control_socket() {
        let server = ThumbleMcp::new(
            PathBuf::from("/definitely/missing/control.sock"),
            false,
            false,
        );
        let error = match server
            .press_control(Parameters(PressControlParams {
                control_id: "button:jump".to_owned(),
            }))
            .await
        {
            Ok(_) => panic!("disabled input unexpectedly succeeded"),
            Err(error) => error,
        };
        assert!(error.contains("--allow-input"));
        assert!(!error.contains("control.sock"));
    }

    #[tokio::test]
    async fn disabled_configuration_write_fails_before_touching_the_control_socket() {
        let server = ThumbleMcp::new(
            PathBuf::from("/definitely/missing/control.sock"),
            false,
            false,
        );
        let error = match server
            .save_configuration_draft(Parameters(SaveConfigurationDraftParams {
                draft_id: "00000000-0000-0000-0000-000000000301".to_owned(),
                expected_draft_revision: 1,
                expected_configuration_revision: 1,
                commit_id: "00000000-0000-0000-0000-000000000501".to_owned(),
            }))
            .await
        {
            Ok(_) => panic!("disabled configuration write unexpectedly succeeded"),
            Err(error) => error,
        };
        assert!(error.contains("--allow-config-write"));
        assert!(!error.contains("control.sock"));
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn official_client_initializes_lists_tools_and_calls_over_mcp() {
        let directory = tempdir().unwrap();
        std::fs::set_permissions(directory.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let socket = directory.path().join("control.sock");
        let listener = bind_control_socket(&socket).await.unwrap();
        let (shutdown_tx, shutdown_rx) = watch::channel(false);
        let control_task = tokio::spawn(serve_control(listener, Arc::new(FakeHost), shutdown_rx));

        let (server_transport, client_transport) = tokio::io::duplex(16 * 1024);
        let server = ThumbleMcp::new(socket.clone(), true, true);
        let mcp_task = tokio::spawn(async move {
            server
                .serve(server_transport)
                .await
                .unwrap()
                .waiting()
                .await
                .unwrap();
        });
        let client = ().serve(client_transport).await.unwrap();
        assert_eq!(
            client.peer_info().unwrap().protocol_version,
            ProtocolVersion::V_2025_11_25
        );
        let peer_info = client.peer_info().unwrap();
        assert!(peer_info.capabilities.resources.is_some());
        let server_info = peer_info
            .server_info
            .as_ref()
            .expect("server implementation metadata");
        assert_eq!(server_info.title.as_deref(), Some("Thumble MCP Controller"));
        assert_eq!(
            server_info.website_url.as_deref(),
            Some(THUMBLE_WEBSITE_URL)
        );
        let icons = server_info.icons.as_ref().expect("branded server icon");
        assert_eq!(icons.len(), 1);
        assert_eq!(icons[0].src, THUMBLE_ICON_URL);
        assert_eq!(icons[0].mime_type.as_deref(), Some("image/png"));
        assert_eq!(
            icons[0].sizes.as_deref(),
            Some(["1024x1024".to_owned()].as_slice())
        );
        let tools = client.list_all_tools().await.unwrap();
        assert_eq!(tools.len(), 20);

        let resources = client.list_all_resources().await.unwrap();
        assert_eq!(resources.len(), 4);
        assert_eq!(resources[0].uri, CONTROLLER_UI_URI);
        assert_eq!(resources[1].uri, CONTROLLER_EDITOR_UI_URI);
        assert_eq!(resources[2].uri, CONFIGURATION_OPERATION_SCHEMA_URI);
        assert_eq!(resources[3].uri, CLI_CAPABILITIES_URI);
        assert_eq!(
            resources[0].mime_type.as_deref(),
            Some(CONTROLLER_UI_MIME_TYPE)
        );
        let resource = client
            .read_resource(ReadResourceRequestParams::new(CONTROLLER_UI_URI))
            .await
            .unwrap();
        assert_eq!(resource.contents.len(), 1);
        let resource_json = serde_json::to_value(&resource.contents[0]).unwrap();
        assert_eq!(
            resource_json.get("mimeType").and_then(Value::as_str),
            Some(CONTROLLER_UI_MIME_TYPE)
        );
        let html = resource_json.get("text").and_then(Value::as_str).unwrap();
        assert!(html.contains("ui/initialize"));
        assert!(html.contains("ui/notifications/tool-result"));
        assert!(html.contains("message.result.protocolVersion !== \"2026-01-26\""));
        assert!(html.contains("typeof message.method !== \"string\""));
        assert!(html
            .contains("Object.prototype.hasOwnProperty.call(message.result, \"protocolVersion\")"));
        assert!(html.contains("state.initializeId = undefined"));
        assert!(html.contains("<svg"));
        assert!(html.contains("Read-only live preview"));
        assert!(!html.contains("https://"));
        assert!(!html.contains("src=\"http"));
        assert!(!html.contains("fetch("));
        assert!(!html.contains("XMLHttpRequest"));
        assert!(!html.contains("innerHTML"));
        assert!(!html.contains("eval("));
        assert!(!html.contains("press_control"));
        let editor_resource = client
            .read_resource(ReadResourceRequestParams::new(CONTROLLER_EDITOR_UI_URI))
            .await
            .unwrap();
        let editor_json = serde_json::to_value(&editor_resource.contents[0]).unwrap();
        let editor_html = editor_json.get("text").and_then(Value::as_str).unwrap();
        for required in [
            "tools/call",
            "edit_configuration_draft",
            "validate_configuration_draft",
            "rebase_configuration_draft",
            "preview_configuration_draft",
            "save_configuration_draft",
            "discard_configuration_draft",
            "expectedDraftRevision",
            "expectedConfigurationRevision",
            "configuration_revision_conflict",
            "configuration_bridge_failed",
        ] {
            assert!(editor_html.contains(required));
        }
        for forbidden in [
            "https://",
            "src=\"http",
            "fetch(",
            "XMLHttpRequest",
            "innerHTML",
            "eval(",
            "localStorage",
            "sessionStorage",
            "press_control",
            "keyCode",
            "authToken",
        ] {
            assert!(!editor_html.contains(forbidden));
        }
        let operation_schema = client
            .read_resource(ReadResourceRequestParams::new(
                CONFIGURATION_OPERATION_SCHEMA_URI,
            ))
            .await
            .unwrap();
        let schema_json = serde_json::to_value(&operation_schema.contents[0]).unwrap();
        assert_eq!(
            schema_json.get("mimeType").and_then(Value::as_str),
            Some("application/schema+json")
        );
        let schema_text = schema_json.get("text").and_then(Value::as_str).unwrap();
        assert!(schema_text.contains("profile.rename"));
        assert!(schema_text.contains("element.set"));
        assert!(schema_text.contains("binding.set"));
        assert!(schema_text.contains("generation.generate"));
        assert!(schema_text.contains("template.install"));
        assert!(schema_text.contains("customization.set"));
        assert!(schema_text.contains("customization.fix"));
        assert!(schema_text.contains("show-default-controls"));
        assert!(schema_text.contains("ergonomic-auto-arrange"));
        assert!(schema_text.contains("includeLocked"));
        assert!(schema_text.contains("orientation.set"));
        assert!(schema_text.contains("device.set"));
        assert!(schema_text.contains("control-bar.move"));
        assert!(schema_text.contains("control-bar.item.set"));
        assert!(!schema_text.contains("keyCode"));
        assert!(client
            .read_resource(ReadResourceRequestParams::new("ui://thumble/unknown.html"))
            .await
            .is_err());

        let catalog = client
            .call_tool(
                CallToolRequestParams::new("query_catalog").with_arguments(
                    serde_json::json!({"catalog":"controller-templates","template":"snes"})
                        .as_object()
                        .unwrap()
                        .clone(),
                ),
            )
            .await
            .unwrap();
        let catalog_json = serde_json::to_value(&catalog).unwrap();
        assert!(catalog_json.to_string().contains("Super Nintendo"));
        assert!(!catalog_json.to_string().contains("keyCode"));

        let device_catalog = client
            .call_tool(
                CallToolRequestParams::new("query_catalog").with_arguments(
                    serde_json::json!({
                        "catalog":"device-frames",
                        "frameID":"iphone-16-pro-landscape"
                    })
                    .as_object()
                    .unwrap()
                    .clone(),
                ),
            )
            .await
            .unwrap();
        let device_catalog_json = serde_json::to_value(&device_catalog).unwrap();
        assert!(device_catalog_json
            .to_string()
            .contains("iphone-16-pro-landscape"));
        assert!(!device_catalog_json.to_string().contains("custom-"));

        let result = client
            .call_tool(CallToolRequestParams::new("accessibility_status"))
            .await
            .unwrap();
        assert_eq!(
            result
                .structured_content
                .as_ref()
                .and_then(|value| value.get("trusted"))
                .and_then(Value::as_bool),
            Some(true)
        );
        let configuration = client
            .call_tool(CallToolRequestParams::new("configuration_status"))
            .await
            .unwrap();
        assert_eq!(
            configuration
                .structured_content
                .as_ref()
                .and_then(|value| value.get("configurationRevision"))
                .and_then(Value::as_u64),
            Some(1)
        );
        let begin = client
            .call_tool(
                CallToolRequestParams::new("begin_configuration_draft").with_arguments(
                    serde_json::Map::from_iter([(
                        "expectedConfigurationRevision".to_owned(),
                        Value::from(1),
                    )]),
                ),
            )
            .await
            .unwrap();
        let draft_id = begin
            .structured_content
            .as_ref()
            .and_then(|value| value.get("draftId"))
            .and_then(Value::as_str)
            .unwrap()
            .to_owned();
        let get = client
            .call_tool(
                CallToolRequestParams::new("get_configuration_draft").with_arguments(
                    serde_json::Map::from_iter([(
                        "draftId".to_owned(),
                        Value::String(draft_id.clone()),
                    )]),
                ),
            )
            .await
            .unwrap();
        assert_eq!(
            get.structured_content
                .as_ref()
                .and_then(|value| value.get("draftRevision"))
                .and_then(Value::as_u64),
            Some(1)
        );
        let edit = client
            .call_tool(
                CallToolRequestParams::new("edit_configuration_draft").with_arguments(
                    serde_json::Map::from_iter([
                        ("draftId".to_owned(), Value::String(draft_id.clone())),
                        ("expectedDraftRevision".to_owned(), Value::from(1)),
                        (
                            "operationId".to_owned(),
                            Value::String("00000000-0000-0000-0000-000000000401".to_owned()),
                        ),
                        (
                            "operation".to_owned(),
                            serde_json::json!({
                                "type":"profile.rename",
                                "profileID":"00000000-0000-0000-0000-000000000201",
                                "name":"Arcade"
                            }),
                        ),
                    ]),
                ),
            )
            .await
            .unwrap();
        assert_eq!(
            edit.structured_content
                .as_ref()
                .and_then(|value| value.get("draft"))
                .and_then(|value| value.get("draftRevision"))
                .and_then(Value::as_u64),
            Some(2)
        );
        let validation = client
            .call_tool(
                CallToolRequestParams::new("validate_configuration_draft").with_arguments(
                    serde_json::Map::from_iter([
                        ("draftId".to_owned(), Value::String(draft_id.clone())),
                        ("expectedDraftRevision".to_owned(), Value::from(2)),
                    ]),
                ),
            )
            .await
            .unwrap();
        assert_eq!(
            validation
                .structured_content
                .as_ref()
                .and_then(|value| value.get("valid"))
                .and_then(Value::as_bool),
            Some(true)
        );
        let export = client
            .call_tool(
                CallToolRequestParams::new("export_controller_preview").with_arguments(
                    serde_json::Map::from_iter([
                        ("draftId".to_owned(), Value::String(draft_id.clone())),
                        ("expectedDraftRevision".to_owned(), Value::from(2)),
                    ]),
                ),
            )
            .await
            .unwrap();
        let exported = export.structured_content.as_ref().unwrap();
        assert_eq!(
            exported.get("mimeType").and_then(Value::as_str),
            Some("image/svg+xml")
        );
        assert_eq!(
            exported.get("sha256").and_then(Value::as_str).map(str::len),
            Some(64)
        );
        let svg = exported.get("svg").and_then(Value::as_str).unwrap();
        assert!(svg.starts_with("<svg "));
        assert!(svg.contains("&lt;script&gt;alert(1)&lt;/script&gt;&amp; Jump"));
        assert!(svg.contains("fill=\"rgba(31,87,199,1.000)\""));
        assert!(!svg.contains("fill=\"#393b38\""));
        assert!(!svg.contains("<script"));
        assert!(!svg.contains("href="));
        assert!(!svg.contains("authToken"));

        let save = client
            .call_tool(
                CallToolRequestParams::new("save_configuration_draft").with_arguments(
                    serde_json::Map::from_iter([
                        ("draftId".to_owned(), Value::String(draft_id.clone())),
                        ("expectedDraftRevision".to_owned(), Value::from(2)),
                        ("expectedConfigurationRevision".to_owned(), Value::from(1)),
                        (
                            "commitId".to_owned(),
                            Value::String("00000000-0000-0000-0000-000000000501".to_owned()),
                        ),
                    ]),
                ),
            )
            .await
            .unwrap();
        assert_eq!(
            save.structured_content
                .as_ref()
                .and_then(|value| value.get("configurationRevision"))
                .and_then(Value::as_u64),
            Some(2)
        );
        let discard = client
            .call_tool(
                CallToolRequestParams::new("discard_configuration_draft").with_arguments(
                    serde_json::Map::from_iter([
                        ("draftId".to_owned(), Value::String(draft_id)),
                        ("expectedDraftRevision".to_owned(), Value::from(1)),
                    ]),
                ),
            )
            .await
            .unwrap();
        assert_eq!(
            discard
                .structured_content
                .as_ref()
                .and_then(|value| value.get("discarded"))
                .and_then(Value::as_bool),
            Some(true)
        );

        let render = client
            .call_tool(CallToolRequestParams::new("render_controller"))
            .await
            .unwrap();
        assert_eq!(render.is_error, Some(false));
        let controller = render.structured_content.as_ref().unwrap();
        assert_eq!(
            controller
                .get("configurationRevision")
                .and_then(Value::as_u64),
            Some(1)
        );
        assert_eq!(
            controller
                .get("colorSchemePreference")
                .and_then(Value::as_str),
            Some("dark")
        );
        assert_eq!(
            controller.get("accentStyle").and_then(Value::as_str),
            Some("purple")
        );
        assert_eq!(
            controller
                .get("canvas")
                .and_then(|canvas| canvas.get("darkFill"))
                .and_then(|fill| fill.get("kind"))
                .and_then(Value::as_str),
            Some("solid")
        );
        assert_eq!(
            controller
                .get("profile")
                .and_then(|profile| profile.get("name"))
                .and_then(Value::as_str),
            Some("Arcade Layout")
        );
        assert_eq!(
            controller
                .get("elements")
                .and_then(Value::as_array)
                .map(Vec::len),
            Some(1)
        );
        assert_eq!(
            controller
                .get("controlBarItems")
                .and_then(Value::as_array)
                .and_then(|items| items.first())
                .and_then(|item| item.get("targetID"))
                .and_then(Value::as_str),
            Some("control_bar_item.settings")
        );
        assert_eq!(
            controller
                .get("layers")
                .and_then(Value::as_array)
                .and_then(|layers| layers.first())
                .and_then(|layer| layer.get("stableID"))
                .and_then(Value::as_str),
            Some("builtin.jump")
        );
        assert_eq!(
            controller
                .get("layers")
                .and_then(Value::as_array)
                .and_then(|layers| layers.first())
                .and_then(|layer| layer.get("styleID"))
                .and_then(Value::as_str),
            Some("soft-white-raised")
        );
        assert_eq!(
            controller
                .get("styles")
                .and_then(Value::as_array)
                .map(Vec::len),
            Some(0)
        );
        assert_eq!(
            controller
                .get("layoutQuality")
                .and_then(|quality| quality.get("issueCount"))
                .and_then(Value::as_u64),
            Some(0)
        );
        assert_eq!(
            controller
                .get("groups")
                .and_then(Value::as_array)
                .and_then(|groups| groups.first())
                .and_then(|group| group.get("childStableIDs"))
                .and_then(Value::as_array)
                .and_then(|children| children.first())
                .and_then(Value::as_str),
            Some("builtin.jump")
        );
        let encoded_controller = serde_json::to_string(controller).unwrap();
        for forbidden in [
            "authToken",
            "keyCode",
            "modifiers",
            "partOutputs",
            "message",
        ] {
            assert!(!encoded_controller.contains(forbidden));
        }
        let press = client
            .call_tool(CallToolRequestParams::new("press_control").with_arguments(
                serde_json::Map::from_iter([(
                    "controlId".to_owned(),
                    Value::String("button:jump".to_owned()),
                )]),
            ))
            .await
            .unwrap();
        assert_eq!(press.is_error, Some(false));
        assert_eq!(
            press
                .structured_content
                .as_ref()
                .and_then(|value| value.get("controlId"))
                .and_then(Value::as_str),
            Some("button:jump")
        );
        let forged = client
            .call_tool(CallToolRequestParams::new("press_control").with_arguments(
                serde_json::Map::from_iter([(
                    "controlId".to_owned(),
                    Value::String("shell:rm -rf /".to_owned()),
                )]),
            ))
            .await
            .unwrap();
        assert_eq!(forged.is_error, Some(true));

        let release = client
            .call_tool(CallToolRequestParams::new("release_all"))
            .await
            .unwrap();
        assert_eq!(
            release
                .structured_content
                .as_ref()
                .and_then(|value| value.get("released"))
                .and_then(Value::as_bool),
            Some(true)
        );

        client.cancel().await.unwrap();
        mcp_task.await.unwrap();
        shutdown_tx.send(true).unwrap();
        control_task.await.unwrap();
        remove_control_socket(&socket);
    }
}
