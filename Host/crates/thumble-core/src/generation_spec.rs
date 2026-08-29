//! Deterministic planning for the portable generation-spec v1 subset.
//!
//! Appearance input is parsed manually so generated profiles remain asset-free,
//! bounded, and compatible with Swift's normalized control-style encoding.

use crate::{
    canonical_default_profile_key_bindings, generated_modifier_mask, generated_semantic_key_code,
    semantic_key_name, ButtonBindings, ControllerLayoutQualitySnapshot, KeyBinding, OutputBinding,
    PersistentState, ProfileArtifact, ProfileArtifactError, ProfileArtifactSelection,
};
use serde::Serialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashSet};
use std::error::Error;
use std::fmt;
use thumble_protocol::GameButton;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub const GENERATION_SPEC_SCHEMA_VERSION: u32 = 1;
pub const GENERATION_SPEC_CATALOG_REVISION: u32 = 1;
pub const GENERATION_SPEC_PLANNER_REVISION: u32 = 1;
pub const MAXIMUM_GENERATION_SPEC_BYTES: usize = 256 * 1024;
pub const MAXIMUM_GENERATION_SOURCE_CONTROLS: usize = 128;
pub const MAXIMUM_GENERATION_WARNINGS: usize = 128;
pub const MAXIMUM_GENERATION_OUTPUT_BYTES: usize = 8 * 1024 * 1024;
/// Fixed namespace used for every deterministic generation profile and custom element.
pub const GENERATION_UUID_NAMESPACE: Uuid = Uuid::from_u128(0x4f2f6c8b_2d0d_5b47_9fd5_67656e737031);

const MAX_NAME_CHARACTERS: usize = 256;
const NORMALIZED_LABEL_CHARACTERS: usize = 12;
const MAX_IDENTIFIER_BYTES: usize = 128;
const MAX_KEY_BYTES: usize = 128;
const MAX_SOURCE_BYTES: usize = 1024;
const MAX_NOTE_BYTES: usize = 1024;
const MAX_NOTES: usize = 128;
const MAX_ERROR_PATH_BYTES: usize = 256;

#[derive(Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationSpecPlan {
    pub schema_version: u32,
    pub catalog_revision: u32,
    pub planner_revision: u32,
    pub descriptor_digest: String,
    pub normalized_descriptor: Value,
    pub profile_id: String,
    pub requested_game_name: String,
    pub resolved_game_name: String,
    pub profile: Value,
    pub customization: Value,
    pub elements: Vec<Value>,
    pub generated_profile: Value,
    pub semantic_bindings: Vec<GeneratedSemanticBinding>,
    pub profile_key_bindings: ButtonBindings<KeyBinding>,
    pub profile_output_bindings: ButtonBindings<OutputBinding>,
    pub artifact: ProfileArtifact,
    #[serde(rename = "generatedJSON")]
    pub generated_json: String,
    #[serde(rename = "artifactJSON")]
    pub artifact_json: String,
    pub warnings: Vec<GenerationSpecWarning>,
    pub omitted_warning_count: usize,
    pub assigned_controls: Vec<GenerationAssignedControl>,
    pub dropped_controls: Vec<GenerationDroppedControl>,
    pub layout_quality: ControllerLayoutQualitySnapshot,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GeneratedSemanticBinding {
    pub source_ordinal: usize,
    pub button: String,
    pub key: String,
    pub canonical_key: String,
    pub key_code: u16,
    pub modifiers: Vec<String>,
    pub modifier_mask: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationSpecWarning {
    pub code: String,
    pub source_ordinal: usize,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationAssignedControl {
    pub source_ordinal: usize,
    pub button: String,
    pub element_id: String,
    pub kind: String,
    pub used_explicit_button: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerationDroppedControl {
    pub source_ordinal: usize,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GenerationSpecError {
    TooLarge(usize),
    DecodingFailed,
    TopLevelMustBeObject,
    UnknownField {
        path: String,
        field: String,
    },
    UnsafeField {
        path: String,
        field: String,
    },
    MissingControls,
    TooManyControls(usize),
    InvalidType {
        path: String,
        expected: &'static str,
    },
    InvalidRevision {
        field: &'static str,
        value: u64,
    },
    InvalidEnum {
        path: String,
        value: String,
    },
    InvalidNumber {
        path: String,
    },
    NumberOutOfBounds {
        path: String,
    },
    StringTooLong {
        path: String,
    },
    ControlCharacter {
        path: String,
    },
    TooManyNotes(usize),
    InvalidKey {
        source_ordinal: usize,
        key: String,
    },
    InvalidModifier {
        source_ordinal: usize,
        modifier: String,
    },
    CanonicalizationFailed,
    EncodingFailed,
    OutputTooLarge(usize),
    Artifact(ProfileArtifactError),
    LayoutEvaluationFailed,
}

impl fmt::Display for GenerationSpecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLarge(size) => write!(formatter, "generation spec is too large ({size} bytes)"),
            Self::DecodingFailed => formatter.write_str("generation spec JSON decoding failed"),
            Self::TopLevelMustBeObject => formatter.write_str("generation spec must be a JSON object"),
            Self::UnknownField { path, field } => write!(formatter, "unknown generation field {path}.{field}"),
            Self::UnsafeField { path, field } => write!(formatter, "unsafe generation field {path}.{field} is forbidden"),
            Self::MissingControls => formatter.write_str("generation spec controls are required"),
            Self::TooManyControls(count) => write!(formatter, "generation spec has {count} controls; maximum is {MAXIMUM_GENERATION_SOURCE_CONTROLS}"),
            Self::InvalidType { path, expected } => write!(formatter, "generation field {path} must be {expected}"),
            Self::InvalidRevision { field, value } => write!(formatter, "generation {field} revision {value} is unsupported"),
            Self::InvalidEnum { path, value } => write!(formatter, "generation field {path} has unsupported value {value:?}"),
            Self::InvalidNumber { path } => write!(formatter, "generation field {path} must be finite"),
            Self::NumberOutOfBounds { path } => write!(formatter, "generation field {path} is out of bounds"),
            Self::StringTooLong { path } => write!(formatter, "generation field {path} is too long"),
            Self::ControlCharacter { path } => write!(formatter, "generation field {path} contains a Unicode control character"),
            Self::TooManyNotes(count) => write!(formatter, "generation spec has too many notes ({count})"),
            Self::InvalidKey { source_ordinal, key } => write!(formatter, "control {source_ordinal} has unsupported semantic key {key:?}"),
            Self::InvalidModifier { source_ordinal, modifier } => write!(formatter, "control {source_ordinal} has unsupported modifier {modifier:?}"),
            Self::CanonicalizationFailed => formatter.write_str("generation descriptor canonicalization failed"),
            Self::EncodingFailed => formatter.write_str("generation output encoding failed"),
            Self::OutputTooLarge(size) => write!(formatter, "generation output is too large ({size} bytes)"),
            Self::Artifact(error) => write!(formatter, "generated artifact is invalid: {error}"),
            Self::LayoutEvaluationFailed => formatter.write_str("generated layout quality evaluation failed"),
        }
    }
}

impl Error for GenerationSpecError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Artifact(error) => Some(error),
            _ => None,
        }
    }
}

impl From<ProfileArtifactError> for GenerationSpecError {
    fn from(value: ProfileArtifactError) -> Self {
        Self::Artifact(value)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
enum Role {
    Movement,
    Primary,
    Secondary,
    Utility,
    System,
}

impl Role {
    fn visual_role(self, kind: Kind) -> &'static str {
        match kind {
            Kind::Joystick => "joystick",
            Kind::Trigger => "trigger",
            Kind::Trackpad => "trackpad",
            Kind::Text | Kind::Decoration => "decoration",
            Kind::Button => match self {
                Self::Movement => "movement",
                Self::Primary => "primary_action",
                Self::Secondary => "secondary_action",
                Self::Utility => "utility",
                Self::System => "system",
            },
        }
    }

    fn fill(self) -> Color {
        Color::from_hex(match self {
            Self::Movement => "1F2937",
            Self::Primary => "7C3AED",
            Self::Secondary => "0EA5E9",
            Self::Utility => "6B7280",
            Self::System => "374151",
        })
        .expect("fixed role color")
    }

    const fn accent(self) -> &'static str {
        match self {
            Self::Primary => "purple",
            Self::Secondary => "blue",
            Self::Movement | Self::Utility | Self::System => "monochrome",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum Kind {
    Button,
    Joystick,
    Trigger,
    Trackpad,
    Text,
    Decoration,
}

impl Kind {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Button => "button",
            Self::Joystick => "joystick",
            Self::Trigger => "trigger",
            Self::Trackpad => "trackpad",
            Self::Text => "text",
            Self::Decoration => "decoration",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct ParsedSpec {
    game_name: String,
    source: Option<String>,
    confidence: Option<String>,
    notes: Vec<String>,
    controls: Vec<ParsedControl>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct ParsedControl {
    id: Option<String>,
    button: Option<GameButton>,
    label: String,
    key: String,
    modifiers: Vec<String>,
    role: Option<Role>,
    center_x: Option<f64>,
    center_y: Option<f64>,
    width_scale: Option<f64>,
    height_scale: Option<f64>,
    shape: Option<String>,
    accent_style: Option<String>,
    fill_color: Option<Color>,
    joystick_knob_color: Option<Color>,
    joystick_visual_style: Option<String>,
    corner_radius: Option<f64>,
    shadow_strength: Option<f64>,
    is_hidden: Option<bool>,
    is_location_locked: Option<bool>,
    control_kind: Option<Kind>,
    joystick_mapping: Option<JoystickMapping>,
    trackpad_settings: Option<TrackpadSettings>,
    #[serde(skip_serializing_if = "Option::is_none")]
    style_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    visual_style: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    icon: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    haptic_style: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    haptic_feedback: Option<Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
struct Color {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
}

impl Color {
    fn from_hex(raw: &str) -> Option<Self> {
        let cleaned = raw
            .trim()
            .trim_matches(|character: char| !character.is_ascii_alphanumeric());
        if !matches!(cleaned.len(), 6 | 8) || !cleaned.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return None;
        }
        let value = u32::from_str_radix(cleaned, 16).ok()?;
        let (red, green, blue, alpha) = if cleaned.len() == 8 {
            (
                value >> 24,
                (value >> 16) & 255,
                (value >> 8) & 255,
                value & 255,
            )
        } else {
            (value >> 16, (value >> 8) & 255, value & 255, 255)
        };
        Some(
            Self {
                red: red as f64 / 255.0,
                green: green as f64 / 255.0,
                blue: blue as f64 / 255.0,
                alpha: alpha as f64 / 255.0,
            }
            .normalized(),
        )
    }

    fn normalized(self) -> Self {
        let red = (self.red * 255.0).round() as u32;
        let green = (self.green * 255.0).round() as u32;
        let blue = (self.blue * 255.0).round() as u32;
        let key = (red << 16) | (green << 8) | blue;
        let replacement = match key {
            0xFFF6DE | 0xFFF4CF | 0xFFF1C1 => Some(0xF5F5F5),
            0xFFDC73 | 0xFFC543 => Some(0xD4D4D4),
            0xFFA600 | 0xFFAE00 => Some(0xA3A3A3),
            0xFF9300 => Some(0x737373),
            0xAA4D00 => Some(0x525252),
            0x561900 => Some(0x262626),
            0x2A1700 => Some(0x1A1A1A),
            0x361900 => Some(0x1F1F1F),
            0x502800 => Some(0x292929),
            0x5B3000 => Some(0x2E2E2E),
            0x703E00 => Some(0x454545),
            0xED9A00 => Some(0x878787),
            0xFFF3D5 => Some(0xEDEDED),
            0xFDE68A => Some(0xE5E7EB),
            0xD97706 => Some(0x9CA3AF),
            0x78350F => Some(0x374151),
            0xFCD34D => Some(0xF3F4F6),
            0xF59E0B | 0xFACC15 | 0xEAB308 => Some(0xD1D5DB),
            0x451A03 => Some(0x111827),
            0xF97316 => Some(0x9CA3AF),
            _ => None,
        };
        if let Some(rgb) = replacement {
            Self {
                red: ((rgb >> 16) & 255) as f64 / 255.0,
                green: ((rgb >> 8) & 255) as f64 / 255.0,
                blue: (rgb & 255) as f64 / 255.0,
                alpha: self.alpha,
            }
        } else {
            self
        }
    }

    fn value(self) -> Value {
        json!({"red": self.red, "green": self.green, "blue": self.blue, "alpha": self.alpha})
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
struct JoystickMapping {
    up: GameButton,
    down: GameButton,
    left: GameButton,
    right: GameButton,
}

impl Default for JoystickMapping {
    fn default() -> Self {
        Self {
            up: GameButton::Up,
            down: GameButton::Down,
            left: GameButton::Left,
            right: GameButton::Right,
        }
    }
}

impl JoystickMapping {
    fn value(self) -> Value {
        json!({
            "up": button_name(self.up), "down": button_name(self.down),
            "left": button_name(self.left), "right": button_name(self.right)
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
struct TrackpadSettings {
    sensitivity: f64,
    scroll_sensitivity: f64,
    tap_to_click: bool,
    two_finger_scroll: bool,
    natural_scrolling: bool,
}

impl Default for TrackpadSettings {
    fn default() -> Self {
        Self {
            sensitivity: 1.2,
            scroll_sensitivity: 0.85,
            tap_to_click: true,
            two_finger_scroll: true,
            natural_scrolling: true,
        }
    }
}

impl TrackpadSettings {
    fn value(self) -> Value {
        json!({
            "sensitivity": self.sensitivity,
            "scrollSensitivity": self.scroll_sensitivity,
            "tapToClick": self.tap_to_click,
            "twoFingerScroll": self.two_finger_scroll,
            "naturalScrolling": self.natural_scrolling
        })
    }
}

#[derive(Debug, Clone, Copy)]
struct Layout {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    shape: &'static str,
}

struct Assigned<'a> {
    ordinal: usize,
    source: &'a ParsedControl,
    button: GameButton,
    kind: Kind,
    role: Role,
    layout: Layout,
    element_id: String,
    explicit: bool,
}

/// Parse, validate, and deterministically plan a generation-spec v1 document.
#[allow(non_snake_case)]
pub fn plan_generation_spec(
    spec_json: &[u8],
    requestedGameName: Option<&str>,
) -> Result<GenerationSpecPlan, GenerationSpecError> {
    if spec_json.len() > MAXIMUM_GENERATION_SPEC_BYTES {
        return Err(GenerationSpecError::TooLarge(spec_json.len()));
    }
    let value: Value =
        serde_json::from_slice(spec_json).map_err(|_| GenerationSpecError::DecodingFailed)?;
    scan_for_control_characters(&value, "$")?;
    if let Some(requested_game_name) = requestedGameName {
        ensure_no_control_characters(requested_game_name, "requestedGameName")?;
    }
    scan_for_unsafe_fields(&value, "$")?;
    let object = value
        .as_object()
        .ok_or(GenerationSpecError::TopLevelMustBeObject)?;
    reject_unknown(object, "$", TOP_FIELDS)?;
    for revision in ["schemaVersion", "catalogRevision", "plannerRevision"] {
        let actual = optional_u64(object, revision, "$.")?.unwrap_or(1);
        if actual != 1 {
            return Err(GenerationSpecError::InvalidRevision {
                field: revision,
                value: actual,
            });
        }
    }
    let parsed = parse_spec(object)?;
    let requested = requestedGameName.unwrap_or("");
    ensure_string_bound(requested, MAX_NAME_CHARACTERS, "requestedGameName")?;
    let requested_override = (!requested.trim().is_empty()).then(|| requested.trim().to_owned());
    let resolved_name = normalized_display_name(
        &parsed.game_name,
        requested_override
            .as_deref()
            .unwrap_or("Agent Generated Game"),
    );
    let requested_name = requestedGameName.map_or_else(
        || resolved_name.clone(),
        |name| normalized_display_name(name, &resolved_name),
    );

    let normalized_descriptor = json!({
        "schemaVersion": GENERATION_SPEC_SCHEMA_VERSION,
        "catalogRevision": GENERATION_SPEC_CATALOG_REVISION,
        "plannerRevision": GENERATION_SPEC_PLANNER_REVISION,
        "requestedGameName": requested_override,
        "spec": parsed,
    });
    let canonical = serde_json_canonicalizer::to_vec(&normalized_descriptor)
        .map_err(|_| GenerationSpecError::CanonicalizationFailed)?;
    let descriptor_digest = sha256_hex(&canonical);
    let profile_id = Uuid::new_v5(
        &GENERATION_UUID_NAMESPACE,
        format!("profile:{descriptor_digest}").as_bytes(),
    )
    .hyphenated()
    .to_string();

    let mut used = HashSet::new();
    let mut role_counts = BTreeMap::<Role, usize>::new();
    let mut joystick_count = 0usize;
    let mut trigger_count = 0usize;
    let mut trackpad_count = 0usize;
    let mut warnings = Vec::new();
    let mut omitted_warning_count = 0usize;
    let mut dropped_controls = Vec::new();
    let mut assigned = Vec::new();
    for (ordinal, control) in parsed.controls.iter().enumerate() {
        let kind = infer_kind(control);
        let specialized_capacity = match kind {
            Kind::Joystick => Some((joystick_count, 2usize)),
            Kind::Trigger => Some((trigger_count, 2usize)),
            Kind::Trackpad => Some((trackpad_count, 1usize)),
            _ => None,
        };
        if specialized_capacity.is_some_and(|(count, maximum)| count >= maximum) {
            push_warning(
                &mut warnings,
                &mut omitted_warning_count,
                "specialized-capacity-exceeded",
                ordinal,
                &format!(
                    "{} control dropped because Swift normalization capacity was exceeded",
                    kind.as_str()
                ),
            );
            dropped_controls.push(GenerationDroppedControl {
                source_ordinal: ordinal,
                reason: format!("specialized-capacity-exceeded:{}", kind.as_str()),
            });
            continue;
        }
        let explicit_available = control.button.filter(|button| !used.contains(button));
        let button = explicit_available.or_else(|| assign_fallback(control, kind, &used));
        let Some(button) = button else {
            push_warning(
                &mut warnings,
                &mut omitted_warning_count,
                "slot-exhaustion",
                ordinal,
                "control dropped because all 18 game-button slots are assigned",
            );
            dropped_controls.push(GenerationDroppedControl {
                source_ordinal: ordinal,
                reason: "slot-exhaustion".to_owned(),
            });
            continue;
        };
        if let Some(explicit_button) = control.button.filter(|_| explicit_available.is_none()) {
            push_warning(
                &mut warnings,
                &mut omitted_warning_count,
                "duplicate-explicit-button-fallback",
                ordinal,
                &format!(
                    "explicit button {} was already assigned; used {}",
                    button_name(explicit_button),
                    button_name(button)
                ),
            );
        }
        used.insert(button);
        match kind {
            Kind::Joystick => joystick_count += 1,
            Kind::Trigger => trigger_count += 1,
            Kind::Trackpad => trackpad_count += 1,
            _ => {}
        }
        let role = infer_role(control, button, kind);
        let index = *role_counts.get(&role).unwrap_or(&0);
        role_counts.insert(role, index + 1);
        let layout = match kind {
            Kind::Trackpad => {
                if trackpad_count > 1 {
                    push_warning(
                        &mut warnings,
                        &mut omitted_warning_count,
                        "reused-trackpad-layout-default",
                        ordinal,
                        "reused the fixed trackpad layout default",
                    );
                }
                Layout {
                    x: 0.50,
                    y: 0.58,
                    width: 1.25,
                    height: 1.0,
                    shape: "rounded_rectangle",
                }
            }
            Kind::Joystick => {
                if joystick_count > 1 {
                    push_warning(
                        &mut warnings,
                        &mut omitted_warning_count,
                        "reused-joystick-layout-default",
                        ordinal,
                        "reused the fixed joystick layout default",
                    );
                }
                if control.joystick_visual_style.as_deref() == Some("thumbstick") {
                    Layout {
                        x: 0.50,
                        y: 0.62,
                        width: 0.58,
                        height: 0.58,
                        shape: "circle",
                    }
                } else {
                    Layout {
                        x: 0.22,
                        y: 0.64,
                        width: 1.35,
                        height: 1.35,
                        shape: "circle",
                    }
                }
            }
            _ => {
                let (layout, reused) = role_layout(button, role, index);
                if reused {
                    push_warning(
                        &mut warnings,
                        &mut omitted_warning_count,
                        "reused-role-layout-default",
                        ordinal,
                        &format!("reused the final {} role layout default", role_name(role)),
                    );
                }
                layout
            }
        };
        let is_builtin = is_builtin(button) && kind == Kind::Button;
        let element_id = if is_builtin {
            built_in_id(button).to_owned()
        } else {
            Uuid::new_v5(
                &GENERATION_UUID_NAMESPACE,
                format!(
                    "element:{descriptor_digest}:{ordinal}:{}",
                    button_name(button)
                )
                .as_bytes(),
            )
            .hyphenated()
            .to_string()
        };
        assigned.push(Assigned {
            ordinal,
            source: control,
            button,
            kind,
            role,
            layout,
            element_id,
            explicit: explicit_available.is_some(),
        });
    }

    let elements = assigned.iter().map(element_value).collect::<Vec<_>>();
    let customization = customization_value(&assigned, &elements);
    let profile = json!({
        "id": profile_id,
        "name": resolved_name,
        "customization": customization,
        "orientationPreference": "automatic",
        "outputMode": "keyboard",
        "updatedAt": 0
    });

    let mut semantic_bindings = Vec::new();
    let mut generated_binding_pairs = Vec::new();
    let mut profile_key_bindings = canonical_default_profile_key_bindings();
    for control in &assigned {
        if matches!(control.kind, Kind::Text | Kind::Decoration)
            || control.source.key.trim().is_empty()
        {
            continue;
        }
        let key = control.source.key.trim();
        let key_code =
            generated_semantic_key_code(key).ok_or_else(|| GenerationSpecError::InvalidKey {
                source_ordinal: control.ordinal,
                key: key.to_owned(),
            })?;
        let modifier_mask =
            generated_modifier_mask(&control.source.modifiers).ok_or_else(|| {
                let modifier = control
                    .source
                    .modifiers
                    .iter()
                    .find(|modifier| generated_modifier_mask(&[modifier.as_str()]).is_none())
                    .cloned()
                    .unwrap_or_default();
                GenerationSpecError::InvalidModifier {
                    source_ordinal: control.ordinal,
                    modifier,
                }
            })?;
        let binding = KeyBinding::new(key_code, modifier_mask);
        profile_key_bindings.insert(control.button, binding);
        semantic_bindings.push(GeneratedSemanticBinding {
            source_ordinal: control.ordinal,
            button: button_name(control.button).to_owned(),
            key: key.to_owned(),
            canonical_key: semantic_key_name(key_code).unwrap_or(key).to_owned(),
            key_code,
            modifiers: control.source.modifiers.clone(),
            modifier_mask,
        });
        generated_binding_pairs.push((
            control.button,
            key.to_owned(),
            control.source.modifiers.clone(),
        ));
    }
    semantic_bindings.sort_by_key(|binding| button_rank_name(&binding.button));
    generated_binding_pairs.sort_by_key(|(button, _, _)| button_rank(*button));

    let mut profile_output_bindings = ButtonBindings::default();
    for button in GameButton::ALL {
        if let Some(binding) = profile_key_bindings.get(&button).cloned() {
            profile_output_bindings.insert(button, OutputBinding::keyboard(binding));
        }
    }

    let notes = if parsed.notes.is_empty() {
        vec!["Installed from an agent-provided keypad spec.".to_owned()]
    } else {
        parsed.notes.clone()
    };
    let generated_profile = json!({
        "requestedGameName": requested_name,
        "resolvedGameName": resolved_name,
        "profile": profile,
        "keyBindings": generated_bindings_value(&generated_binding_pairs),
        "source": parsed.source.clone().unwrap_or_else(|| "Agent-provided keypad spec".to_owned()),
        "confidence": parsed.confidence.clone().unwrap_or_else(|| "low".to_owned()),
        "notes": notes
    });
    let generated_json = pretty_string(&generated_profile)?;

    let document = crate::ConfigurationDocument {
        profiles: vec![profile.clone()],
        active_profile_id: profile_id.clone(),
        default_profile_id: profile_id.clone(),
        key_bindings: profile_key_bindings.clone(),
        output_bindings: profile_output_bindings.clone(),
        profile_key_bindings: BTreeMap::from([(profile_id.clone(), profile_key_bindings.clone())]),
        profile_output_bindings: BTreeMap::from([(
            profile_id.clone(),
            profile_output_bindings.clone(),
        )]),
    };
    document.validate().map_err(|error| {
        GenerationSpecError::Artifact(ProfileArtifactError::InvalidConfiguration(error))
    })?;
    let mut artifact =
        ProfileArtifact::from_configuration(&document, ProfileArtifactSelection::All, 0)?;
    artifact.extensions.insert(
        "generationMetadata".to_owned(),
        json!({
            "schemaVersion": GENERATION_SPEC_SCHEMA_VERSION,
            "catalogRevision": GENERATION_SPEC_CATALOG_REVISION,
            "plannerRevision": GENERATION_SPEC_PLANNER_REVISION,
            "descriptorDigest": descriptor_digest,
            "uuidNamespace": GENERATION_UUID_NAMESPACE.hyphenated().to_string()
        }),
    );
    artifact.refresh_content_hash()?;
    artifact.validate()?;
    let artifact_json = String::from_utf8(artifact.encode_pretty_json()?)
        .map_err(|_| GenerationSpecError::EncodingFailed)?;

    ensure_output_bound(generated_json.len())?;
    ensure_output_bound(artifact_json.len())?;
    let layout_quality = evaluate_layout_quality(&profile, &profile_id)?;
    let assigned_controls = assigned
        .iter()
        .map(|control| GenerationAssignedControl {
            source_ordinal: control.ordinal,
            button: button_name(control.button).to_owned(),
            element_id: control.element_id.clone(),
            kind: control.kind.as_str().to_owned(),
            used_explicit_button: control.explicit,
        })
        .collect();

    Ok(GenerationSpecPlan {
        schema_version: 1,
        catalog_revision: 1,
        planner_revision: 1,
        descriptor_digest,
        normalized_descriptor,
        profile_id,
        requested_game_name: requested_name,
        resolved_game_name: resolved_name,
        profile,
        customization,
        elements,
        generated_profile,
        semantic_bindings,
        profile_key_bindings,
        profile_output_bindings,
        artifact,
        generated_json,
        artifact_json,
        warnings,
        omitted_warning_count,
        assigned_controls,
        dropped_controls,
        layout_quality,
    })
}

const TOP_FIELDS: &[&str] = &[
    "gameName",
    "name",
    "game",
    "source",
    "confidence",
    "notes",
    "controls",
    "schemaVersion",
    "catalogRevision",
    "plannerRevision",
];

const CONTROL_FIELDS: &[&str] = &[
    "id",
    "button",
    "label",
    "key",
    "modifiers",
    "role",
    "centerX",
    "x",
    "centerY",
    "y",
    "widthScale",
    "width",
    "heightScale",
    "height",
    "shape",
    "accentStyle",
    "fillColor",
    "fill",
    "fillHex",
    "color",
    "joystickKnobColor",
    "knobColor",
    "thumbColor",
    "thumbFill",
    "joystickThumbFill",
    "joystickKnobFill",
    "joystickVisualStyle",
    "joystickStyle",
    "stickStyle",
    "thumbstick",
    "cornerRadius",
    "shadowStrength",
    "isHidden",
    "isLocationLocked",
    "controlKind",
    "kind",
    "joystickMapping",
    "up",
    "down",
    "left",
    "right",
    "trackpadSettings",
    "sensitivity",
    "cursorSensitivity",
    "pointerSensitivity",
    "scrollSensitivity",
    "tapToClick",
    "twoFingerScroll",
    "naturalScrolling",
    "naturalScroll",
    "styleID",
    "visualStyle",
    "material",
    "materialPreset",
    "icon",
    "iconName",
    "sfSymbol",
    "iconText",
    "hapticStyle",
    "hapticFeedback",
    "hapticPattern",
    "hapticIntensity",
    "hapticStrength",
    "hapticSharpness",
    "hapticDuration",
    "hapticDurationMS",
    "stroke",
    "strokeColor",
    "strokeWidth",
    "foreground",
    "foregroundColor",
    "textColor",
    "shadows",
    "glow",
    "glowColor",
    "glowRadius",
    "innerShadow",
    "innerShadowColor",
    "innerShadowRadius",
    "innerShadowX",
    "innerShadowY",
    "highlight",
    "highlightColor",
    "highlightRadius",
    "highlightX",
    "highlightY",
    "highlightOpacity",
    "bevelHighlight",
    "bevelHighlightColor",
    "bevelShadow",
    "bevelShadowColor",
    "bevelWidth",
    "pressedFill",
    "pressedColor",
    "opacity",
];

fn parse_spec(object: &Map<String, Value>) -> Result<ParsedSpec, GenerationSpecError> {
    let game_name = first_string(
        object,
        &["gameName", "name", "game"],
        "Agent Generated Game",
        "$.gameName",
    )?;
    ensure_string_bound(&game_name, MAX_NAME_CHARACTERS, "$.gameName")?;
    let source = optional_string(object, "source", "$.source")?;
    if let Some(source) = &source {
        ensure_byte_bound(source, MAX_SOURCE_BYTES, "$.source")?;
    }
    let confidence = optional_string(object, "confidence", "$.confidence")?;
    if let Some(value) = &confidence {
        if !matches!(value.as_str(), "high" | "medium" | "low") {
            return Err(GenerationSpecError::InvalidEnum {
                path: "$.confidence".to_owned(),
                value: value.clone(),
            });
        }
    }
    let notes = optional_string_array(object, "notes", "$.notes")?.unwrap_or_default();
    if notes.len() > MAX_NOTES {
        return Err(GenerationSpecError::TooManyNotes(notes.len()));
    }
    for (index, note) in notes.iter().enumerate() {
        ensure_byte_bound(note, MAX_NOTE_BYTES, &format!("$.notes[{index}]"))?;
    }
    let controls_value = object
        .get("controls")
        .ok_or(GenerationSpecError::MissingControls)?;
    let controls_array = controls_value
        .as_array()
        .ok_or_else(|| invalid_type("$.controls", "an array"))?;
    if controls_array.len() > MAXIMUM_GENERATION_SOURCE_CONTROLS {
        return Err(GenerationSpecError::TooManyControls(controls_array.len()));
    }
    let controls = controls_array
        .iter()
        .enumerate()
        .map(|(index, value)| parse_control(index, value))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ParsedSpec {
        game_name,
        source,
        confidence,
        notes,
        controls,
    })
}

fn parse_control(index: usize, value: &Value) -> Result<ParsedControl, GenerationSpecError> {
    let path = format!("$.controls[{index}]");
    let object = value
        .as_object()
        .ok_or_else(|| invalid_type(&path, "an object"))?;
    reject_unknown(object, &path, CONTROL_FIELDS)?;
    let id = optional_string(object, "id", &format!("{path}.id"))?;
    if let Some(id) = &id {
        ensure_byte_bound(id, MAX_IDENTIFIER_BYTES, &format!("{path}.id"))?;
    }
    let mut button = optional_button(object, "button", &format!("{path}.button"))?;
    if button.is_none() {
        button = id.as_deref().and_then(parse_button);
    }
    let default_label = button
        .map(button_display_name)
        .or(id.as_deref())
        .unwrap_or("Button");
    let label = first_string(object, &["label"], default_label, &format!("{path}.label"))?;
    let key = first_string(object, &["key"], "", &format!("{path}.key"))?;
    ensure_byte_bound(&key, MAX_KEY_BYTES, &format!("{path}.key"))?;
    let modifiers = optional_string_array(object, "modifiers", &format!("{path}.modifiers"))?
        .unwrap_or_default();
    if modifiers.len() > 16 {
        return Err(GenerationSpecError::NumberOutOfBounds {
            path: format!("{path}.modifiers"),
        });
    }
    for modifier in &modifiers {
        ensure_byte_bound(modifier, 32, &format!("{path}.modifiers"))?;
    }
    let role = optional_string(object, "role", &format!("{path}.role"))?
        .map(|value| parse_role(&value, &format!("{path}.role")))
        .transpose()?;
    let center_x = first_number(object, &["centerX", "x"], &format!("{path}.centerX"))?;
    let center_y = first_number(object, &["centerY", "y"], &format!("{path}.centerY"))?;
    validate_optional_range(center_x, 0.0, 1.0, &format!("{path}.centerX"))?;
    validate_optional_range(center_y, 0.0, 1.0, &format!("{path}.centerY"))?;
    let width_scale = first_number(
        object,
        &["widthScale", "width"],
        &format!("{path}.widthScale"),
    )?;
    let height_scale = first_number(
        object,
        &["heightScale", "height"],
        &format!("{path}.heightScale"),
    )?;
    validate_optional_range(width_scale, 0.001, 12.0, &format!("{path}.widthScale"))?;
    validate_optional_range(height_scale, 0.001, 12.0, &format!("{path}.heightScale"))?;
    let shape = optional_enum(
        object,
        "shape",
        &[
            "rounded_rectangle",
            "rectangle",
            "capsule",
            "circle",
            "ellipse",
            "polygon",
            "star",
        ],
        &path,
    )?;
    let accent_style = optional_enum(
        object,
        "accentStyle",
        &["monochrome", "blue", "green", "purple", "pink", "amber"],
        &path,
    )?;
    let fill_color = first_color(object, &["fillColor", "fill", "fillHex", "color"], &path)?;
    let joystick_knob_color = first_color(
        object,
        &[
            "joystickKnobColor",
            "knobColor",
            "thumbColor",
            "thumbFill",
            "joystickThumbFill",
            "joystickKnobFill",
        ],
        &path,
    )?;
    let joystick_visual_style = parse_joystick_style(object, &path)?;
    let corner_radius = first_number(object, &["cornerRadius"], &format!("{path}.cornerRadius"))?;
    let shadow_strength = first_number(
        object,
        &["shadowStrength"],
        &format!("{path}.shadowStrength"),
    )?;
    validate_optional_range(corner_radius, 0.0, 1024.0, &format!("{path}.cornerRadius"))?;
    validate_optional_range(shadow_strength, 0.0, 2.0, &format!("{path}.shadowStrength"))?;
    let is_hidden = optional_bool(object, "isHidden", &format!("{path}.isHidden"))?;
    let is_location_locked = optional_bool(
        object,
        "isLocationLocked",
        &format!("{path}.isLocationLocked"),
    )?;
    let control_kind = parse_kind(object, &path)?;
    let joystick_mapping = parse_joystick_mapping(object, &path)?;
    let trackpad_settings = parse_trackpad_settings(object, &path)?;
    let style_id = parse_style_id(object, &path)?;
    let visual_style = parse_control_visual_style(object, &path)?;
    let icon = parse_control_icon_aliases(object, &path)?;
    let (haptic_style, haptic_feedback) = parse_control_haptic(object, &path)?;
    Ok(ParsedControl {
        id,
        button,
        label,
        key,
        modifiers,
        role,
        center_x,
        center_y,
        width_scale,
        height_scale,
        shape,
        accent_style,
        fill_color,
        joystick_knob_color,
        joystick_visual_style,
        corner_radius,
        shadow_strength,
        is_hidden,
        is_location_locked,
        control_kind,
        joystick_mapping,
        trackpad_settings,
        style_id,
        visual_style,
        icon,
        haptic_style,
        haptic_feedback,
    })
}

fn parse_style_id(
    object: &Map<String, Value>,
    path: &str,
) -> Result<Option<String>, GenerationSpecError> {
    let Some(raw) = optional_string(object, "styleID", &format!("{path}.styleID"))? else {
        return Ok(None);
    };
    ensure_byte_bound(&raw, MAX_IDENTIFIER_BYTES, &format!("{path}.styleID"))?;
    let normalized = raw
        .trim()
        .chars()
        .map(|character| {
            if character.is_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '-'
            }
        })
        .collect::<String>()
        .trim_matches(['-', '.'])
        .to_owned();
    Ok((!normalized.is_empty()).then_some(normalized))
}

const VISUAL_STYLE_FIELDS: &[&str] = &[
    "normal",
    "pressed",
    "active",
    "disabled",
    "icon",
    "hapticStyle",
    "hapticFeedback",
];

const STATE_STYLE_FIELDS: &[&str] = &[
    "fillStyle",
    "foregroundColor",
    "strokeColor",
    "strokeWidth",
    "shadowColor",
    "shadowRadius",
    "shadowX",
    "shadowY",
    "shadows",
    "glowColor",
    "glowRadius",
    "innerShadowColor",
    "innerShadowRadius",
    "innerShadowX",
    "innerShadowY",
    "highlightColor",
    "highlightRadius",
    "highlightX",
    "highlightY",
    "highlightOpacity",
    "bevelHighlightColor",
    "bevelShadowColor",
    "bevelWidth",
    "opacity",
    "scale",
];

fn parse_control_visual_style(
    object: &Map<String, Value>,
    path: &str,
) -> Result<Option<Value>, GenerationSpecError> {
    if let Some(explicit) = object.get("visualStyle").filter(|value| !value.is_null()) {
        return parse_visual_style(explicit, &format!("{path}.visualStyle"));
    }

    let mut style = if let Some((field, material)) =
        first_present_string(object, &["material", "materialPreset"], path)?
    {
        material_visual_style(&material).ok_or_else(|| GenerationSpecError::InvalidEnum {
            path: format!("{path}.{field}"),
            value: material,
        })?
    } else {
        json!({"normal": {}})
    };
    let normal = style
        .get_mut("normal")
        .and_then(Value::as_object_mut)
        .expect("fixed visual style normal object");

    insert_color_alias(
        normal,
        "strokeColor",
        object,
        &["stroke", "strokeColor"],
        path,
    )?;
    insert_color_alias(
        normal,
        "foregroundColor",
        object,
        &["foreground", "foregroundColor", "textColor"],
        path,
    )?;
    insert_bounded_alias(
        normal,
        "strokeWidth",
        object,
        &["strokeWidth"],
        0.0,
        12.0,
        path,
    )?;
    if let Some(value) = object.get("shadows").filter(|value| !value.is_null()) {
        normal.insert(
            "shadows".to_owned(),
            Value::Array(parse_shadows(value, &format!("{path}.shadows"))?),
        );
    }
    insert_color_alias(normal, "glowColor", object, &["glow", "glowColor"], path)?;
    insert_bounded_alias(
        normal,
        "glowRadius",
        object,
        &["glowRadius"],
        0.0,
        64.0,
        path,
    )?;
    insert_color_alias(
        normal,
        "innerShadowColor",
        object,
        &["innerShadow", "innerShadowColor"],
        path,
    )?;
    insert_bounded_alias(
        normal,
        "innerShadowRadius",
        object,
        &["innerShadowRadius"],
        0.0,
        64.0,
        path,
    )?;
    insert_bounded_alias(
        normal,
        "innerShadowX",
        object,
        &["innerShadowX"],
        -64.0,
        64.0,
        path,
    )?;
    insert_bounded_alias(
        normal,
        "innerShadowY",
        object,
        &["innerShadowY"],
        -64.0,
        64.0,
        path,
    )?;
    insert_color_alias(
        normal,
        "highlightColor",
        object,
        &["highlight", "highlightColor"],
        path,
    )?;
    insert_bounded_alias(
        normal,
        "highlightRadius",
        object,
        &["highlightRadius"],
        0.0,
        64.0,
        path,
    )?;
    insert_bounded_alias(
        normal,
        "highlightX",
        object,
        &["highlightX"],
        -64.0,
        64.0,
        path,
    )?;
    insert_bounded_alias(
        normal,
        "highlightY",
        object,
        &["highlightY"],
        -64.0,
        64.0,
        path,
    )?;
    insert_bounded_alias(
        normal,
        "highlightOpacity",
        object,
        &["highlightOpacity"],
        0.0,
        1.0,
        path,
    )?;
    insert_color_alias(
        normal,
        "bevelHighlightColor",
        object,
        &["bevelHighlight", "bevelHighlightColor"],
        path,
    )?;
    insert_color_alias(
        normal,
        "bevelShadowColor",
        object,
        &["bevelShadow", "bevelShadowColor"],
        path,
    )?;
    insert_bounded_alias(
        normal,
        "bevelWidth",
        object,
        &["bevelWidth"],
        0.0,
        24.0,
        path,
    )?;
    insert_bounded_alias(normal, "opacity", object, &["opacity"], 0.0, 1.0, path)?;

    if let Some((_, color)) = first_present_color(object, &["pressedFill", "pressedColor"], path)? {
        let pressed = style
            .as_object_mut()
            .expect("fixed visual style object")
            .entry("pressed")
            .or_insert_with(|| json!({}));
        pressed
            .as_object_mut()
            .expect("fixed pressed style object")
            .insert("fillStyle".to_owned(), solid_fill(color));
    }

    if visual_style_is_empty(&style) {
        Ok(None)
    } else {
        Ok(Some(style))
    }
}

fn parse_visual_style(value: &Value, path: &str) -> Result<Option<Value>, GenerationSpecError> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_type(path, "an object"))?;
    reject_unknown(object, path, VISUAL_STYLE_FIELDS)?;
    let normal_value = object
        .get("normal")
        .ok_or_else(|| invalid_type(&format!("{path}.normal"), "an object"))?;
    let mut result = Map::new();
    result.insert(
        "normal".to_owned(),
        Value::Object(parse_state_style(normal_value, &format!("{path}.normal"))?),
    );
    for state in ["pressed", "active", "disabled"] {
        if let Some(value) = object.get(state).filter(|value| !value.is_null()) {
            result.insert(
                state.to_owned(),
                Value::Object(parse_state_style(value, &format!("{path}.{state}"))?),
            );
        }
    }
    if let Some(value) = object.get("icon").filter(|value| !value.is_null()) {
        if let Some(icon) = parse_icon(value, &format!("{path}.icon"))? {
            result.insert("icon".to_owned(), icon);
        }
    }
    if let Some(style) = optional_haptic_style(object, "hapticStyle", path)? {
        result.insert("hapticStyle".to_owned(), json!(style));
    }
    if let Some(value) = object
        .get("hapticFeedback")
        .filter(|value| !value.is_null())
    {
        result.insert(
            "hapticFeedback".to_owned(),
            parse_haptic_feedback(value, &format!("{path}.hapticFeedback"), None)?,
        );
    }
    let result = Value::Object(result);
    Ok((!visual_style_is_empty(&result)).then_some(result))
}

fn parse_state_style(value: &Value, path: &str) -> Result<Map<String, Value>, GenerationSpecError> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_type(path, "an object"))?;
    reject_unknown(object, path, STATE_STYLE_FIELDS)?;
    let mut result = Map::new();
    if let Some(fill) = object.get("fillStyle").filter(|value| !value.is_null()) {
        if let Some(fill) = parse_fill_style(fill, &format!("{path}.fillStyle"))? {
            result.insert("fillStyle".to_owned(), fill);
        }
    }
    for field in [
        "foregroundColor",
        "strokeColor",
        "shadowColor",
        "glowColor",
        "innerShadowColor",
        "highlightColor",
        "bevelHighlightColor",
        "bevelShadowColor",
    ] {
        if let Some(value) = object.get(field).filter(|value| !value.is_null()) {
            result.insert(
                field.to_owned(),
                parse_color_value(value, &format!("{path}.{field}"))?.value(),
            );
        }
    }
    for (field, lower, upper) in [
        ("strokeWidth", 0.0, 12.0),
        ("shadowRadius", 0.0, 48.0),
        ("shadowX", -64.0, 64.0),
        ("shadowY", -64.0, 64.0),
        ("glowRadius", 0.0, 64.0),
        ("innerShadowRadius", 0.0, 64.0),
        ("innerShadowX", -64.0, 64.0),
        ("innerShadowY", -64.0, 64.0),
        ("highlightRadius", 0.0, 64.0),
        ("highlightX", -64.0, 64.0),
        ("highlightY", -64.0, 64.0),
        ("highlightOpacity", 0.0, 1.0),
        ("bevelWidth", 0.0, 24.0),
        ("opacity", 0.0, 1.0),
        ("scale", 0.5, 1.5),
    ] {
        if let Some(number) = first_number(object, &[field], &format!("{path}.{field}"))? {
            validate_range(number, lower, upper, &format!("{path}.{field}"))?;
            result.insert(field.to_owned(), json!(number));
        }
    }
    if let Some(value) = object.get("shadows").filter(|value| !value.is_null()) {
        result.insert(
            "shadows".to_owned(),
            Value::Array(parse_shadows(value, &format!("{path}.shadows"))?),
        );
    }
    Ok(result)
}

fn parse_fill_style(value: &Value, path: &str) -> Result<Option<Value>, GenerationSpecError> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_type(path, "an object"))?;
    let kind = optional_string(object, "kind", &format!("{path}.kind"))?
        .ok_or_else(|| invalid_type(&format!("{path}.kind"), "a string"))?;
    match kind.as_str() {
        "none" => {
            reject_unknown(object, path, &["kind"])?;
            Ok(None)
        }
        "solid" => {
            reject_unknown(object, path, &["kind", "color"])?;
            let color = object
                .get("color")
                .ok_or_else(|| invalid_type(&format!("{path}.color"), "a color"))?;
            Ok(Some(solid_fill(parse_color_value(
                color,
                &format!("{path}.color"),
            )?)))
        }
        "gradient" => {
            reject_unknown(object, path, &["kind", "gradient"])?;
            let gradient = object
                .get("gradient")
                .ok_or_else(|| invalid_type(&format!("{path}.gradient"), "an object"))?;
            Ok(Some(json!({
                "kind": "gradient",
                "gradient": parse_gradient(gradient, &format!("{path}.gradient"))?
            })))
        }
        "tile" | "image" => Err(GenerationSpecError::InvalidEnum {
            path: format!("{path}.kind"),
            value: kind,
        }),
        _ => Err(GenerationSpecError::InvalidEnum {
            path: format!("{path}.kind"),
            value: kind,
        }),
    }
}

fn parse_gradient(value: &Value, path: &str) -> Result<Value, GenerationSpecError> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_type(path, "an object"))?;
    reject_unknown(object, path, &["type", "angleDegrees", "stops"])?;
    let gradient_type = optional_string(object, "type", &format!("{path}.type"))?
        .ok_or_else(|| invalid_type(&format!("{path}.type"), "a string"))?;
    if !matches!(gradient_type.as_str(), "linear" | "radial") {
        return Err(GenerationSpecError::InvalidEnum {
            path: format!("{path}.type"),
            value: gradient_type,
        });
    }
    let angle =
        first_number(object, &["angleDegrees"], &format!("{path}.angleDegrees"))?.unwrap_or(0.0);
    let angle = ((angle % 360.0) + 360.0) % 360.0;
    let stops_value = object
        .get("stops")
        .ok_or_else(|| invalid_type(&format!("{path}.stops"), "an array"))?;
    let stops = stops_value
        .as_array()
        .ok_or_else(|| invalid_type(&format!("{path}.stops"), "an array"))?;
    if stops.len() > 128 {
        return Err(GenerationSpecError::NumberOutOfBounds {
            path: format!("{path}.stops"),
        });
    }
    let mut parsed = stops
        .iter()
        .enumerate()
        .map(|(index, value)| parse_gradient_stop(value, &format!("{path}.stops[{index}]")))
        .collect::<Result<Vec<_>, _>>()?;
    parsed.sort_by(|lhs, rhs| {
        lhs["offset"]
            .as_f64()
            .partial_cmp(&rhs["offset"].as_f64())
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    if parsed.is_empty() {
        let color = Color {
            red: 0.07,
            green: 0.07,
            blue: 0.07,
            alpha: 1.0,
        }
        .value();
        let mixed_component = 0.07 + (1.0 - 0.07) * 0.42;
        parsed = vec![
            json!({"offset":0.0,"color":color}),
            json!({"offset":1.0,"color":{"red":mixed_component,"green":mixed_component,"blue":mixed_component,"alpha":1.0}}),
        ];
    } else if parsed.len() == 1 {
        let color = parsed[0]["color"].clone();
        parsed = vec![
            json!({"offset":0.0,"color":color}),
            json!({"offset":1.0,"color":parsed[0]["color"].clone()}),
        ];
    }
    Ok(json!({"type":gradient_type,"angleDegrees":angle,"stops":parsed}))
}

fn parse_gradient_stop(value: &Value, path: &str) -> Result<Value, GenerationSpecError> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_type(path, "an object"))?;
    reject_unknown(object, path, &["offset", "color"])?;
    let offset = required_number(object, "offset", path)?;
    validate_range(offset, 0.0, 1.0, &format!("{path}.offset"))?;
    let color = object
        .get("color")
        .ok_or_else(|| invalid_type(&format!("{path}.color"), "a color"))?;
    Ok(json!({"offset":offset,"color":parse_color_value(color, &format!("{path}.color"))?.value()}))
}

fn parse_shadows(value: &Value, path: &str) -> Result<Vec<Value>, GenerationSpecError> {
    let values = value
        .as_array()
        .ok_or_else(|| invalid_type(path, "an array"))?;
    if values.len() > 8 {
        return Err(GenerationSpecError::NumberOutOfBounds {
            path: path.to_owned(),
        });
    }
    values
        .iter()
        .enumerate()
        .map(|(index, value)| parse_shadow(value, &format!("{path}[{index}]")))
        .collect()
}

fn parse_shadow(value: &Value, path: &str) -> Result<Value, GenerationSpecError> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_type(path, "an object"))?;
    reject_unknown(object, path, &["color", "radius", "x", "y", "opacity"])?;
    let color_value = object
        .get("color")
        .ok_or_else(|| invalid_type(&format!("{path}.color"), "a color"))?;
    let mut color = parse_color_value(color_value, &format!("{path}.color"))?;
    let radius = first_number(object, &["radius"], &format!("{path}.radius"))?.unwrap_or(0.0);
    let x = first_number(object, &["x"], &format!("{path}.x"))?.unwrap_or(0.0);
    let y = first_number(object, &["y"], &format!("{path}.y"))?.unwrap_or(0.0);
    let opacity = first_number(object, &["opacity"], &format!("{path}.opacity"))?.unwrap_or(1.0);
    validate_range(radius, 0.0, 96.0, &format!("{path}.radius"))?;
    validate_range(x, -96.0, 96.0, &format!("{path}.x"))?;
    validate_range(y, -96.0, 96.0, &format!("{path}.y"))?;
    validate_range(opacity, 0.0, 1.0, &format!("{path}.opacity"))?;
    color.alpha *= opacity;
    Ok(json!({"color":color.value(),"radius":radius,"x":x,"y":y}))
}

fn parse_control_icon_aliases(
    object: &Map<String, Value>,
    path: &str,
) -> Result<Option<Value>, GenerationSpecError> {
    if let Some(value) = object.get("icon").filter(|value| !value.is_null()) {
        return parse_icon(value, &format!("{path}.icon"));
    }
    for (field, source) in [("sfSymbol", "sf_symbol"), ("iconText", "text")] {
        if let Some(value) = optional_string(object, field, &format!("{path}.{field}"))? {
            return normalized_icon(
                source,
                &value,
                "center",
                1.0,
                None,
                "template",
                &format!("{path}.{field}"),
            );
        }
    }
    if let Some(value) = optional_string(object, "iconName", &format!("{path}.iconName"))? {
        let (source, value) = if let Some(value) = value.strip_prefix("sf:") {
            ("sf_symbol", value)
        } else if let Some(value) = value.strip_prefix("text:") {
            ("text", value)
        } else {
            ("sf_symbol", value.as_str())
        };
        return normalized_icon(
            source,
            value,
            "center",
            1.0,
            None,
            "template",
            &format!("{path}.iconName"),
        );
    }
    Ok(None)
}

fn parse_icon(value: &Value, path: &str) -> Result<Option<Value>, GenerationSpecError> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_type(path, "an object"))?;
    reject_unknown(
        object,
        path,
        &[
            "source",
            "value",
            "placement",
            "scale",
            "tintColor",
            "renderingMode",
        ],
    )?;
    let source = optional_string(object, "source", &format!("{path}.source"))?
        .ok_or_else(|| invalid_type(&format!("{path}.source"), "a string"))?;
    if !matches!(source.as_str(), "sf_symbol" | "text") {
        return Err(GenerationSpecError::InvalidEnum {
            path: format!("{path}.source"),
            value: source,
        });
    }
    let icon_value = optional_string(object, "value", &format!("{path}.value"))?
        .ok_or_else(|| invalid_type(&format!("{path}.value"), "a string"))?;
    let placement = optional_string(object, "placement", &format!("{path}.placement"))?
        .unwrap_or_else(|| "center".to_owned());
    if !matches!(
        placement.as_str(),
        "leading" | "trailing" | "top" | "bottom" | "center" | "background"
    ) {
        return Err(GenerationSpecError::InvalidEnum {
            path: format!("{path}.placement"),
            value: placement,
        });
    }
    let rendering = optional_string(object, "renderingMode", &format!("{path}.renderingMode"))?
        .unwrap_or_else(|| "template".to_owned());
    if !matches!(rendering.as_str(), "template" | "multicolor" | "original") {
        return Err(GenerationSpecError::InvalidEnum {
            path: format!("{path}.renderingMode"),
            value: rendering,
        });
    }
    let scale = first_number(object, &["scale"], &format!("{path}.scale"))?.unwrap_or(1.0);
    let tint = object
        .get("tintColor")
        .filter(|value| !value.is_null())
        .map(|value| parse_color_value(value, &format!("{path}.tintColor")))
        .transpose()?;
    normalized_icon(
        &source,
        &icon_value,
        &placement,
        scale,
        tint,
        &rendering,
        path,
    )
}

fn normalized_icon(
    source: &str,
    value: &str,
    placement: &str,
    scale: f64,
    tint: Option<Color>,
    rendering: &str,
    _path: &str,
) -> Result<Option<Value>, GenerationSpecError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    let value = trimmed.chars().take(80).collect::<String>();
    let mut icon = Map::from_iter([
        ("source".to_owned(), json!(source)),
        ("value".to_owned(), json!(value)),
        ("placement".to_owned(), json!(placement)),
        ("scale".to_owned(), json!(scale.clamp(0.2, 3.0))),
        ("renderingMode".to_owned(), json!(rendering)),
    ]);
    if let Some(tint) = tint {
        icon.insert("tintColor".to_owned(), tint.value());
    }
    Ok(Some(Value::Object(icon)))
}

fn parse_control_haptic(
    object: &Map<String, Value>,
    path: &str,
) -> Result<(Option<String>, Option<Value>), GenerationSpecError> {
    let style_override = optional_haptic_style(object, "hapticStyle", path)?;
    if let Some(value) = object
        .get("hapticFeedback")
        .filter(|value| !value.is_null())
    {
        let feedback = parse_haptic_feedback(
            value,
            &format!("{path}.hapticFeedback"),
            style_override.as_deref(),
        )?;
        let style =
            style_override.unwrap_or_else(|| feedback["style"].as_str().unwrap().to_owned());
        return Ok(normalized_layout_haptic(style, feedback));
    }

    let pattern = optional_haptic_pattern(object, "hapticPattern", path)?;
    let intensity = first_number(
        object,
        &["hapticIntensity", "hapticStrength"],
        &format!("{path}.hapticIntensity"),
    )?;
    let sharpness = first_number(
        object,
        &["hapticSharpness"],
        &format!("{path}.hapticSharpness"),
    )?;
    let mut duration = first_number(
        object,
        &["hapticDuration"],
        &format!("{path}.hapticDuration"),
    )?;
    if duration.is_none() {
        duration = first_number(
            object,
            &["hapticDurationMS"],
            &format!("{path}.hapticDurationMS"),
        )?
        .map(|value| value / 1_000.0);
    }
    if style_override.is_none()
        && pattern.is_none()
        && intensity.is_none()
        && sharpness.is_none()
        && duration.is_none()
    {
        return Ok((None, None));
    }
    let style = style_override.unwrap_or_else(|| "light".to_owned());
    let feedback = normalized_haptic(
        &style,
        pattern.as_deref().unwrap_or("single"),
        intensity.unwrap_or_else(|| haptic_default_intensity(&style)),
        sharpness.unwrap_or_else(|| haptic_default_sharpness(&style)),
        duration.unwrap_or(0.06),
    );
    Ok(normalized_layout_haptic(style, feedback))
}

fn normalized_layout_haptic(style: String, feedback: Value) -> (Option<String>, Option<Value>) {
    let is_default = feedback["style"] == "light"
        && feedback["pattern"] == "single"
        && feedback["intensity"]
            .as_f64()
            .is_some_and(|value| (value - 0.45).abs() < 0.001)
        && feedback["sharpness"]
            .as_f64()
            .is_some_and(|value| (value - 0.48).abs() < 0.001)
        && feedback["duration"]
            .as_f64()
            .is_some_and(|value| (value - 0.06).abs() < 0.001);
    (Some(style), (!is_default).then_some(feedback))
}

fn parse_haptic_feedback(
    value: &Value,
    path: &str,
    style_override: Option<&str>,
) -> Result<Value, GenerationSpecError> {
    let object = value
        .as_object()
        .ok_or_else(|| invalid_type(path, "an object"))?;
    reject_unknown(
        object,
        path,
        &["style", "pattern", "intensity", "sharpness", "duration"],
    )?;
    let decoded_style =
        optional_haptic_style(object, "style", path)?.unwrap_or_else(|| "light".to_owned());
    let style = style_override.unwrap_or(&decoded_style).to_owned();
    let pattern =
        optional_haptic_pattern(object, "pattern", path)?.unwrap_or_else(|| "single".to_owned());
    let intensity = first_number(object, &["intensity"], &format!("{path}.intensity"))?
        .unwrap_or_else(|| haptic_default_intensity(&style));
    let sharpness = first_number(object, &["sharpness"], &format!("{path}.sharpness"))?
        .unwrap_or_else(|| haptic_default_sharpness(&style));
    let duration =
        first_number(object, &["duration"], &format!("{path}.duration"))?.unwrap_or(0.06);
    Ok(normalized_haptic(
        &style, &pattern, intensity, sharpness, duration,
    ))
}

fn optional_haptic_style(
    object: &Map<String, Value>,
    field: &str,
    path: &str,
) -> Result<Option<String>, GenerationSpecError> {
    optional_string(object, field, &format!("{path}.{field}"))?
        .map(|style| {
            if matches!(
                style.as_str(),
                "none" | "light" | "medium" | "heavy" | "soft" | "rigid"
            ) {
                Ok(style)
            } else {
                Err(GenerationSpecError::InvalidEnum {
                    path: format!("{path}.{field}"),
                    value: style,
                })
            }
        })
        .transpose()
}

fn optional_haptic_pattern(
    object: &Map<String, Value>,
    field: &str,
    path: &str,
) -> Result<Option<String>, GenerationSpecError> {
    optional_string(object, field, &format!("{path}.{field}"))?
        .map(|pattern| {
            if matches!(pattern.as_str(), "single" | "double" | "pulse" | "buzz") {
                Ok(pattern)
            } else {
                Err(GenerationSpecError::InvalidEnum {
                    path: format!("{path}.{field}"),
                    value: pattern,
                })
            }
        })
        .transpose()
}

fn normalized_haptic(
    style: &str,
    pattern: &str,
    intensity: f64,
    sharpness: f64,
    duration: f64,
) -> Value {
    let (pattern, intensity, sharpness) = if style == "none" {
        ("single", 0.0, 0.0)
    } else {
        (
            pattern,
            intensity.clamp(0.0, 1.0),
            sharpness.clamp(0.0, 1.0),
        )
    };
    json!({
        "style": style,
        "pattern": pattern,
        "intensity": intensity,
        "sharpness": sharpness,
        "duration": duration.clamp(0.02, 0.30)
    })
}

fn haptic_default_intensity(style: &str) -> f64 {
    match style {
        "none" => 0.0,
        "light" => 0.45,
        "medium" => 0.62,
        "heavy" => 0.82,
        "soft" => 0.38,
        "rigid" => 0.70,
        _ => unreachable!("validated haptic style"),
    }
}

fn haptic_default_sharpness(style: &str) -> f64 {
    match style {
        "none" => 0.0,
        "light" => 0.48,
        "medium" => 0.56,
        "heavy" => 0.66,
        "soft" => 0.24,
        "rigid" => 0.92,
        _ => unreachable!("validated haptic style"),
    }
}

fn first_present_string(
    object: &Map<String, Value>,
    fields: &[&str],
    path: &str,
) -> Result<Option<(String, String)>, GenerationSpecError> {
    for field in fields {
        if let Some(value) = object.get(*field).filter(|value| !value.is_null()) {
            return value
                .as_str()
                .map(|value| Some(((*field).to_owned(), value.to_owned())))
                .ok_or_else(|| invalid_type(&format!("{path}.{field}"), "a string"));
        }
    }
    Ok(None)
}

fn first_present_color(
    object: &Map<String, Value>,
    fields: &[&str],
    path: &str,
) -> Result<Option<(String, Color)>, GenerationSpecError> {
    for field in fields {
        if let Some(value) = object.get(*field).filter(|value| !value.is_null()) {
            return Ok(Some((
                (*field).to_owned(),
                parse_color_value(value, &format!("{path}.{field}"))?,
            )));
        }
    }
    Ok(None)
}

fn insert_color_alias(
    output: &mut Map<String, Value>,
    output_field: &str,
    input: &Map<String, Value>,
    aliases: &[&str],
    path: &str,
) -> Result<(), GenerationSpecError> {
    if let Some((_, color)) = first_present_color(input, aliases, path)? {
        output.insert(output_field.to_owned(), color.value());
    }
    Ok(())
}

fn insert_bounded_alias(
    output: &mut Map<String, Value>,
    output_field: &str,
    input: &Map<String, Value>,
    aliases: &[&str],
    lower: f64,
    upper: f64,
    path: &str,
) -> Result<(), GenerationSpecError> {
    if let Some(value) = first_number(input, aliases, &format!("{path}.{output_field}"))? {
        validate_range(value, lower, upper, &format!("{path}.{output_field}"))?;
        output.insert(output_field.to_owned(), json!(value));
    }
    Ok(())
}

fn visual_style_is_empty(style: &Value) -> bool {
    let Some(object) = style.as_object() else {
        return true;
    };
    object.iter().all(|(field, value)| match field.as_str() {
        "normal" | "pressed" | "active" | "disabled" => value.as_object().is_none_or(Map::is_empty),
        _ => value.is_null(),
    })
}

fn solid_fill(color: Color) -> Value {
    json!({"kind":"solid","color":color.value()})
}

fn material_visual_style(value: &str) -> Option<Value> {
    match normalized_text(value).as_str() {
        "softwhite" | "softwhiteraised" | "raised" | "neumorphic" | "neumorphicraised" => {
            Some(soft_white_raised())
        }
        "softwhiteinset" | "inset" | "recessed" | "well" => Some(soft_white_inset()),
        "softwhiteplate" | "plate" | "panel" | "shell" => Some(soft_white_plate()),
        _ => None,
    }
}

fn color(hex: &str) -> Color {
    Color::from_hex(hex).expect("fixed material color")
}

fn color_alpha(hex: &str, alpha: f64) -> Color {
    Color {
        alpha,
        ..color(hex)
    }
}

fn preset_shadow(hex: &str, alpha: f64, radius: f64, x: f64, y: f64) -> Value {
    json!({"color":color_alpha(hex, alpha).value(),"radius":radius,"x":x,"y":y})
}

fn soft_white_raised() -> Value {
    json!({
        "normal": {
            "fillStyle": solid_fill(color("#F7F4F8")),
            "foregroundColor": color("#7C61A8").value(),
            "strokeColor": color_alpha("#FFFFFF", 0.68).value(),
            "strokeWidth": 1.0,
            "shadows": [
                preset_shadow("#FFFFFF", 0.96, 14.0, -7.0, -7.0),
                preset_shadow("#9B91AA", 0.24, 20.0, 8.0, 9.0)
            ],
            "highlightColor": color("#FFFFFF").value(),
            "highlightRadius": 10.0,
            "highlightX": -5.0,
            "highlightY": -5.0,
            "highlightOpacity": 0.34,
            "bevelHighlightColor": color_alpha("#FFFFFF", 0.70).value(),
            "bevelShadowColor": color_alpha("#C8C0D2", 0.50).value(),
            "bevelWidth": 1.25
        },
        "pressed": {
            "fillStyle": solid_fill(color("#EDE8F1")),
            "shadows": [
                preset_shadow("#A89DB7", 0.18, 8.0, 3.0, 3.0),
                preset_shadow("#FFFFFF", 0.74, 8.0, -2.0, -2.0)
            ],
            "innerShadowColor": color_alpha("#B5AFC1", 0.36).value(),
            "innerShadowRadius": 6.0,
            "innerShadowX": 2.0,
            "innerShadowY": 2.0,
            "highlightOpacity": 0.10,
            "bevelWidth": 0.6,
            "scale": 0.975
        },
        "hapticFeedback": normalized_haptic("soft", "single", 0.42, 0.22, 0.06)
    })
}

fn soft_white_inset() -> Value {
    json!({
        "normal": {
            "fillStyle": solid_fill(color("#EFEAF2")),
            "foregroundColor": color("#8067A7").value(),
            "strokeColor": color_alpha("#FFFFFF", 0.42).value(),
            "strokeWidth": 1.0,
            "shadows": [
                preset_shadow("#FFFFFF", 0.62, 10.0, -3.0, -3.0),
                preset_shadow("#B0A7BC", 0.20, 12.0, 4.0, 5.0)
            ],
            "innerShadowColor": color_alpha("#AFA7BB", 0.30).value(),
            "innerShadowRadius": 8.0,
            "innerShadowX": 3.0,
            "innerShadowY": 3.0,
            "highlightColor": color("#FFFFFF").value(),
            "highlightRadius": 8.0,
            "highlightX": -4.0,
            "highlightY": -4.0,
            "highlightOpacity": 0.22,
            "bevelHighlightColor": color_alpha("#FFFFFF", 0.58).value(),
            "bevelShadowColor": color_alpha("#B7AEC4", 0.42).value(),
            "bevelWidth": 1.0
        },
        "pressed": {
            "innerShadowRadius": 10.0,
            "innerShadowX": 4.0,
            "innerShadowY": 4.0,
            "scale": 0.985
        },
        "hapticFeedback": normalized_haptic("soft", "single", 0.34, 0.18, 0.06)
    })
}

fn soft_white_plate() -> Value {
    json!({
        "normal": {
            "fillStyle": solid_fill(color("#F2EEF5")),
            "foregroundColor": color("#8169A7").value(),
            "strokeColor": color_alpha("#FFFFFF", 0.48).value(),
            "strokeWidth": 1.0,
            "shadows": [
                preset_shadow("#FFFFFF", 0.92, 26.0, -12.0, -12.0),
                preset_shadow("#998DAA", 0.22, 34.0, 14.0, 16.0)
            ],
            "highlightColor": color("#FFFFFF").value(),
            "highlightRadius": 22.0,
            "highlightX": -10.0,
            "highlightY": -10.0,
            "highlightOpacity": 0.26,
            "bevelHighlightColor": color_alpha("#FFFFFF", 0.64).value(),
            "bevelShadowColor": color_alpha("#C8C0D2", 0.42).value(),
            "bevelWidth": 1.4
        }
    })
}

fn parse_kind(
    object: &Map<String, Value>,
    path: &str,
) -> Result<Option<Kind>, GenerationSpecError> {
    if let Some(value) = optional_string(object, "controlKind", &format!("{path}.controlKind"))? {
        return parse_kind_value(&value, false)
            .ok_or_else(|| GenerationSpecError::InvalidEnum {
                path: format!("{path}.controlKind"),
                value,
            })
            .map(Some);
    }
    if let Some(value) = optional_string(object, "kind", &format!("{path}.kind"))? {
        return parse_kind_value(&value, true)
            .ok_or_else(|| GenerationSpecError::InvalidEnum {
                path: format!("{path}.kind"),
                value,
            })
            .map(Some);
    }
    Ok(None)
}

fn parse_kind_value(value: &str, aliases: bool) -> Option<Kind> {
    match value {
        "button" => Some(Kind::Button),
        "joystick" => Some(Kind::Joystick),
        "trigger" => Some(Kind::Trigger),
        "trackpad" => Some(Kind::Trackpad),
        "text" => Some(Kind::Text),
        "decoration" => Some(Kind::Decoration),
        _ if aliases => match normalized_text(value).as_str() {
            "shape" => Some(Kind::Button),
            "stick" => Some(Kind::Joystick),
            "touchpad" | "cursorpad" => Some(Kind::Trackpad),
            "decor" | "visual" | "plate" | "panel" | "ring" => Some(Kind::Decoration),
            _ => None,
        },
        _ => None,
    }
}

fn parse_joystick_style(
    object: &Map<String, Value>,
    path: &str,
) -> Result<Option<String>, GenerationSpecError> {
    if let Some(value) = optional_string(
        object,
        "joystickVisualStyle",
        &format!("{path}.joystickVisualStyle"),
    )? {
        if matches!(value.as_str(), "pad" | "thumbstick") {
            return Ok(Some(value));
        }
        return Err(GenerationSpecError::InvalidEnum {
            path: format!("{path}.joystickVisualStyle"),
            value,
        });
    }
    for field in ["joystickStyle", "stickStyle"] {
        if let Some(value) = optional_string(object, field, &format!("{path}.{field}"))? {
            let parsed = match normalized_text(&value).as_str() {
                "pad" | "fullpad" | "classic" | "joystick" => Some("pad"),
                "thumbstick" | "thumb" | "nub" | "stickball" | "ball" => Some("thumbstick"),
                _ => None,
            };
            return parsed.map(|value| Some(value.to_owned())).ok_or_else(|| {
                GenerationSpecError::InvalidEnum {
                    path: format!("{path}.{field}"),
                    value,
                }
            });
        }
    }
    if optional_bool(object, "thumbstick", &format!("{path}.thumbstick"))? == Some(true) {
        return Ok(Some("thumbstick".to_owned()));
    }
    Ok(None)
}

fn parse_joystick_mapping(
    object: &Map<String, Value>,
    path: &str,
) -> Result<Option<JoystickMapping>, GenerationSpecError> {
    let explicit = match object.get("joystickMapping") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let mapping = value
                .as_object()
                .ok_or_else(|| invalid_type(&format!("{path}.joystickMapping"), "an object"))?;
            reject_unknown(
                mapping,
                &format!("{path}.joystickMapping"),
                &["up", "down", "left", "right"],
            )?;
            Some(JoystickMapping {
                up: optional_button(mapping, "up", &format!("{path}.joystickMapping.up"))?
                    .unwrap_or(GameButton::Up),
                down: optional_button(mapping, "down", &format!("{path}.joystickMapping.down"))?
                    .unwrap_or(GameButton::Down),
                left: optional_button(mapping, "left", &format!("{path}.joystickMapping.left"))?
                    .unwrap_or(GameButton::Left),
                right: optional_button(mapping, "right", &format!("{path}.joystickMapping.right"))?
                    .unwrap_or(GameButton::Right),
            })
        }
    };
    let up = optional_button(object, "up", &format!("{path}.up"))?;
    let down = optional_button(object, "down", &format!("{path}.down"))?;
    let left = optional_button(object, "left", &format!("{path}.left"))?;
    let right = optional_button(object, "right", &format!("{path}.right"))?;
    if up.is_none() && down.is_none() && left.is_none() && right.is_none() {
        return Ok(explicit);
    }
    let base = explicit.unwrap_or_default();
    Ok(Some(JoystickMapping {
        up: up.unwrap_or(base.up),
        down: down.unwrap_or(base.down),
        left: left.unwrap_or(base.left),
        right: right.unwrap_or(base.right),
    }))
}

fn parse_trackpad_settings(
    object: &Map<String, Value>,
    path: &str,
) -> Result<Option<TrackpadSettings>, GenerationSpecError> {
    let explicit = match object.get("trackpadSettings") {
        None | Some(Value::Null) => None,
        Some(value) => {
            let settings = value
                .as_object()
                .ok_or_else(|| invalid_type(&format!("{path}.trackpadSettings"), "an object"))?;
            reject_unknown(
                settings,
                &format!("{path}.trackpadSettings"),
                &[
                    "sensitivity",
                    "scrollSensitivity",
                    "tapToClick",
                    "twoFingerScroll",
                    "naturalScrolling",
                ],
            )?;
            let defaults = TrackpadSettings::default();
            Some(TrackpadSettings {
                sensitivity: first_number(
                    settings,
                    &["sensitivity"],
                    &format!("{path}.trackpadSettings.sensitivity"),
                )?
                .unwrap_or(defaults.sensitivity),
                scroll_sensitivity: first_number(
                    settings,
                    &["scrollSensitivity"],
                    &format!("{path}.trackpadSettings.scrollSensitivity"),
                )?
                .unwrap_or(defaults.scroll_sensitivity),
                tap_to_click: optional_bool(
                    settings,
                    "tapToClick",
                    &format!("{path}.trackpadSettings.tapToClick"),
                )?
                .unwrap_or(defaults.tap_to_click),
                two_finger_scroll: optional_bool(
                    settings,
                    "twoFingerScroll",
                    &format!("{path}.trackpadSettings.twoFingerScroll"),
                )?
                .unwrap_or(defaults.two_finger_scroll),
                natural_scrolling: optional_bool(
                    settings,
                    "naturalScrolling",
                    &format!("{path}.trackpadSettings.naturalScrolling"),
                )?
                .unwrap_or(defaults.natural_scrolling),
            })
        }
    };
    let sensitivity = first_number(
        object,
        &["sensitivity", "cursorSensitivity", "pointerSensitivity"],
        &format!("{path}.sensitivity"),
    )?;
    let scroll = first_number(
        object,
        &["scrollSensitivity"],
        &format!("{path}.scrollSensitivity"),
    )?;
    let tap = optional_bool(object, "tapToClick", &format!("{path}.tapToClick"))?;
    let two = optional_bool(
        object,
        "twoFingerScroll",
        &format!("{path}.twoFingerScroll"),
    )?;
    let natural = first_bool(
        object,
        &["naturalScrolling", "naturalScroll"],
        &format!("{path}.naturalScrolling"),
    )?;
    if sensitivity.is_none()
        && scroll.is_none()
        && tap.is_none()
        && two.is_none()
        && natural.is_none()
    {
        if let Some(settings) = explicit {
            validate_trackpad(settings, path)?;
            return Ok(Some(settings));
        }
        return Ok(None);
    }
    let base = explicit.unwrap_or_default();
    let settings = TrackpadSettings {
        sensitivity: sensitivity.unwrap_or(base.sensitivity),
        scroll_sensitivity: scroll.unwrap_or(base.scroll_sensitivity),
        tap_to_click: tap.unwrap_or(base.tap_to_click),
        two_finger_scroll: two.unwrap_or(base.two_finger_scroll),
        natural_scrolling: natural.unwrap_or(base.natural_scrolling),
    };
    validate_trackpad(settings, path)?;
    Ok(Some(settings))
}

fn validate_trackpad(settings: TrackpadSettings, path: &str) -> Result<(), GenerationSpecError> {
    validate_range(
        settings.sensitivity,
        0.2,
        4.0,
        &format!("{path}.sensitivity"),
    )?;
    validate_range(
        settings.scroll_sensitivity,
        0.1,
        4.0,
        &format!("{path}.scrollSensitivity"),
    )
}

fn infer_kind(control: &ParsedControl) -> Kind {
    control.control_kind.unwrap_or_else(|| {
        if control.trackpad_settings.is_some() {
            Kind::Trackpad
        } else if control.joystick_mapping.is_some() || control.joystick_visual_style.is_some() {
            Kind::Joystick
        } else {
            Kind::Button
        }
    })
}

fn assign_fallback(
    control: &ParsedControl,
    kind: Kind,
    used: &HashSet<GameButton>,
) -> Option<GameButton> {
    if kind != Kind::Button {
        return custom_slots().find(|button| !used.contains(button));
    }
    let normalized = normalized_control_text(control);
    let preferred = if normalized.contains("left") || normalized.contains("arrowleft") {
        Some(GameButton::Left)
    } else if normalized.contains("right") || normalized.contains("arrowright") {
        Some(GameButton::Right)
    } else if normalized.contains("up") || normalized.contains("arrowup") {
        Some(GameButton::Up)
    } else if normalized.contains("down") || normalized.contains("arrowdown") {
        Some(GameButton::Down)
    } else if normalized.contains("jump") {
        Some(GameButton::Jump)
    } else if ["attack", "nail", "fire", "shoot"]
        .iter()
        .any(|word| normalized.contains(word))
    {
        Some(GameButton::Attack)
    } else if ["dash", "dodge", "sprint"]
        .iter()
        .any(|word| normalized.contains(word))
    {
        Some(GameButton::Dash)
    } else if ["focus", "cast", "special", "magic"]
        .iter()
        .any(|word| normalized.contains(word))
    {
        Some(GameButton::Focus)
    } else if normalized.contains("map") {
        Some(GameButton::Map)
    } else if ["pause", "escape", "menu"]
        .iter()
        .any(|word| normalized.contains(word))
    {
        Some(GameButton::Pause)
    } else {
        None
    };
    preferred
        .filter(|button| !used.contains(button))
        .or_else(|| custom_slots().find(|button| !used.contains(button)))
}

fn infer_role(control: &ParsedControl, button: GameButton, kind: Kind) -> Role {
    if let Some(role) = control.role {
        return role;
    }
    if kind != Kind::Button {
        return Role::Movement;
    }
    match button {
        GameButton::Up | GameButton::Down | GameButton::Left | GameButton::Right => Role::Movement,
        GameButton::Jump | GameButton::Attack | GameButton::Dash => Role::Primary,
        GameButton::Focus => Role::Secondary,
        GameButton::Map => Role::Utility,
        GameButton::Pause => Role::System,
        _ => {
            let normalized = normalized_control_text(control);
            if ["inventory", "map", "item"]
                .iter()
                .any(|word| normalized.contains(word))
            {
                Role::Utility
            } else if ["pause", "escape", "menu"]
                .iter()
                .any(|word| normalized.contains(word))
            {
                Role::System
            } else if ["focus", "cast", "special", "magic"]
                .iter()
                .any(|word| normalized.contains(word))
            {
                Role::Secondary
            } else {
                Role::Primary
            }
        }
    }
}

fn role_layout(button: GameButton, role: Role, index: usize) -> (Layout, bool) {
    let fixed = match button {
        GameButton::Up => Some(layout(0.20, 0.42, 1.12, 1.05, "rounded_rectangle")),
        GameButton::Down => Some(layout(0.20, 0.70, 1.12, 1.05, "rounded_rectangle")),
        GameButton::Left => Some(layout(0.066, 0.56, 1.12, 1.05, "rounded_rectangle")),
        GameButton::Right => Some(layout(0.334, 0.56, 1.12, 1.05, "rounded_rectangle")),
        GameButton::Map => Some(layout(0.29, 0.16, 1.0, 1.1, "capsule")),
        GameButton::Pause => Some(layout(0.78, 0.21, 0.95, 1.1, "capsule")),
        _ => None,
    };
    if let Some(layout) = fixed {
        return (layout, false);
    }
    let table: &[Layout] = match role {
        Role::Movement => &[
            layout(0.20, 0.42, 1.12, 1.05, "rounded_rectangle"),
            layout(0.20, 0.70, 1.12, 1.05, "rounded_rectangle"),
            layout(0.066, 0.56, 1.12, 1.05, "rounded_rectangle"),
            layout(0.334, 0.56, 1.12, 1.05, "rounded_rectangle"),
        ],
        Role::Primary => &[
            layout(0.82, 0.84, 1.42, 1.28, "rounded_rectangle"),
            layout(0.66, 0.62, 1.34, 1.20, "rounded_rectangle"),
            layout(0.93, 0.53, 1.24, 1.12, "rounded_rectangle"),
            layout(0.62, 0.32, 1.18, 1.06, "rounded_rectangle"),
            layout(0.60, 0.89, 1.12, 0.95, "rounded_rectangle"),
            layout(0.94, 0.42, 1.06, 0.94, "rounded_rectangle"),
        ],
        Role::Secondary => &[
            layout(0.94, 0.255, 1.06, 0.96, "rounded_rectangle"),
            layout(0.42, 0.86, 1.06, 0.94, "rounded_rectangle"),
            layout(0.68, 0.88, 1.06, 0.94, "rounded_rectangle"),
            layout(0.36, 0.74, 1.06, 0.94, "rounded_rectangle"),
        ],
        Role::Utility => &[
            layout(0.29, 0.16, 1.0, 1.1, "capsule"),
            layout(0.55, 0.86, 1.0, 0.94, "capsule"),
            layout(0.68, 0.90, 1.0, 0.94, "capsule"),
            layout(0.50, 0.90, 1.0, 0.94, "capsule"),
        ],
        Role::System => &[
            layout(0.78, 0.21, 0.95, 1.1, "capsule"),
            layout(0.68, 0.90, 0.90, 0.95, "capsule"),
        ],
    };
    (table[index.min(table.len() - 1)], index >= table.len())
}

const fn layout(x: f64, y: f64, width: f64, height: f64, shape: &'static str) -> Layout {
    Layout {
        x,
        y,
        width,
        height,
        shape,
    }
}

fn element_value(control: &Assigned<'_>) -> Value {
    let source = control.source;
    let shape = if control.kind == Kind::Joystick {
        "circle"
    } else {
        source.shape.as_deref().unwrap_or(control.layout.shape)
    };
    let fill = source.fill_color.unwrap_or_else(|| control.role.fill());
    let accent = source
        .accent_style
        .as_deref()
        .unwrap_or(control.role.accent());
    let corner = source.corner_radius.or_else(|| match shape {
        "capsule" | "circle" | "ellipse" => None,
        _ => Some(if control.kind == Kind::Trackpad {
            18.0
        } else {
            12.0
        }),
    });
    let shadow = source
        .shadow_strength
        .unwrap_or(if control.role == Role::Primary {
            1.25
        } else {
            1.0
        });
    let label_fallback = if control.kind == Kind::Trackpad {
        "Trackpad"
    } else {
        button_display_name(control.button)
    };
    let label = normalized_control_label(&source.label, label_fallback);
    let mut layout_object = Map::new();
    layout_object.insert(
        "centerX".to_owned(),
        json!(source.center_x.unwrap_or(control.layout.x)),
    );
    layout_object.insert(
        "centerY".to_owned(),
        json!(source.center_y.unwrap_or(control.layout.y)),
    );
    layout_object.insert(
        "widthScale".to_owned(),
        json!(source.width_scale.unwrap_or(control.layout.width)),
    );
    layout_object.insert(
        "heightScale".to_owned(),
        json!(source.height_scale.unwrap_or(control.layout.height)),
    );
    layout_object.insert("rotationDegrees".to_owned(), json!(0));
    layout_object.insert("zIndex".to_owned(), json!(0));
    layout_object.insert("shape".to_owned(), json!(shape));
    layout_object.insert("accentStyle".to_owned(), json!(accent));
    layout_object.insert("fillColor".to_owned(), fill.value());
    if let Some(color) = source.joystick_knob_color {
        layout_object.insert("joystickKnobColor".to_owned(), color.value());
    }
    if let Some(style) = &source.joystick_visual_style {
        layout_object.insert("joystickVisualStyle".to_owned(), json!(style));
    }
    if let Some(style_id) = &source.style_id {
        layout_object.insert("styleID".to_owned(), json!(style_id));
    }
    if let Some(visual_style) = &source.visual_style {
        layout_object.insert("visualStyle".to_owned(), visual_style.clone());
    }
    if let Some(icon) = &source.icon {
        layout_object.insert("icon".to_owned(), icon.clone());
    }
    if let Some(haptic_style) = &source.haptic_style {
        layout_object.insert("hapticStyle".to_owned(), json!(haptic_style));
    }
    if let Some(haptic_feedback) = &source.haptic_feedback {
        layout_object.insert("hapticFeedback".to_owned(), haptic_feedback.clone());
    }
    if let Some(corner) = corner {
        layout_object.insert("cornerRadius".to_owned(), json!(corner));
    }
    layout_object.insert(
        "shadowStrength".to_owned(),
        json!(if control.kind == Kind::Text {
            0.0
        } else {
            shadow
        }),
    );
    if control.kind == Kind::Text {
        layout_object.insert("showsIntegratedLabel".to_owned(), json!(false));
    }
    layout_object.insert(
        "isLocationLocked".to_owned(),
        json!(source.is_location_locked.unwrap_or(false)),
    );
    layout_object.insert(
        "isHidden".to_owned(),
        json!(source.is_hidden.unwrap_or(false)),
    );
    let mut element = Map::new();
    element.insert("id".to_owned(), json!(control.element_id));
    element.insert("label".to_owned(), json!(label));
    element.insert("kind".to_owned(), json!(control.kind.as_str()));
    element.insert("layout".to_owned(), Value::Object(layout_object));
    if is_builtin(control.button) && control.kind == Kind::Button {
        element.insert(
            "builtInButton".to_owned(),
            json!(button_name(control.button)),
        );
    }
    element.insert("legacySlot".to_owned(), json!(button_name(control.button)));
    element.insert(
        "visualRole".to_owned(),
        json!(control.role.visual_role(control.kind)),
    );
    // Swift encodes dictionaries with non-String enum keys as alternating
    // key/value arrays, including the empty dictionary.
    element.insert("partOutputs".to_owned(), json!([]));
    if control.kind == Kind::Joystick {
        element.insert(
            "joystickMapping".to_owned(),
            source.joystick_mapping.unwrap_or_default().value(),
        );
        element.insert("joystickOutputSettings".to_owned(), json!({"analogTarget":"none","sendsDigitalDirections":true,"deadZone":0.12,"sensitivity":1.0,"invertX":false,"invertY":false,"snapToCardinal":false}));
    }
    if control.kind == Kind::Trigger {
        element.insert(
            "triggerSettings".to_owned(),
            json!({
                "target": "right",
                "orientation": "vertical",
                "sensitivity": 1.0,
                "deadZone": 0.03,
                "sendsDigitalButton": false,
                "digitalThreshold": 0.5
            }),
        );
    }
    if control.kind == Kind::Trackpad {
        element.insert(
            "trackpadSettings".to_owned(),
            source.trackpad_settings.unwrap_or_default().value(),
        );
    }
    Value::Object(element)
}

fn customization_value(assigned: &[Assigned<'_>], elements: &[Value]) -> Value {
    let mut button_pairs = Vec::new();
    let mut label_pairs = Vec::new();
    let mut custom_buttons = Vec::new();
    for button in GameButton::ALL.into_iter().take(10) {
        if let Some(control) = assigned
            .iter()
            .find(|control| control.button == button && control.kind == Kind::Button)
        {
            let element = element_value(control);
            button_pairs.push(Value::String(button_name(button).to_owned()));
            button_pairs.push(element["layout"].clone());
            label_pairs.push(Value::String(button_name(button).to_owned()));
            label_pairs.push(element["label"].clone());
        } else {
            button_pairs.push(Value::String(button_name(button).to_owned()));
            button_pairs.push(json!({"widthScale":1.0,"heightScale":1.0,"rotationDegrees":0,"zIndex":0,"shadowStrength":1.0,"isLocationLocked":false,"isHidden":true}));
        }
    }
    for control in assigned
        .iter()
        .filter(|control| !(is_builtin(control.button) && control.kind == Kind::Button))
    {
        let element = element_value(control);
        let mut custom = Map::new();
        custom.insert("id".to_owned(), element["id"].clone());
        custom.insert(
            "mappedButton".to_owned(),
            json!(button_name(control.button)),
        );
        custom.insert("label".to_owned(), element["label"].clone());
        custom.insert("layout".to_owned(), element["layout"].clone());
        custom.insert("controlKind".to_owned(), json!(control.kind.as_str()));
        custom.insert("visualRole".to_owned(), element["visualRole"].clone());
        for field in [
            "joystickMapping",
            "joystickOutputSettings",
            "triggerSettings",
            "trackpadSettings",
        ] {
            if let Some(value) = element.get(field) {
                custom.insert(field.to_owned(), value.clone());
            }
        }
        custom_buttons.push(Value::Object(custom));
    }
    json!({
        "layoutMode":"standard", "controlScale":"standard", "colorSchemePreference":"system",
        "deviceCanvas":{"frameID":"iphone-17-pro-landscape"}, "accentStyle":"purple",
        "showsButtonLabels":true, "labelOverrides":label_pairs, "buttonCustomizations":button_pairs,
        "customButtons":custom_buttons, "elements":elements, "updatedAt":0
    })
}

fn generated_bindings_value(bindings: &[(GameButton, String, Vec<String>)]) -> Value {
    let mut values = Vec::with_capacity(bindings.len() * 2);
    for (button, key, modifiers) in bindings {
        values.push(json!(button_name(*button)));
        values.push(json!({"key":key,"modifiers":modifiers}));
    }
    Value::Array(values)
}

fn evaluate_layout_quality(
    profile: &Value,
    profile_id: &str,
) -> Result<ControllerLayoutQualitySnapshot, GenerationSpecError> {
    let mut state = PersistentState::minimal("generation-planner")
        .map_err(|_| GenerationSpecError::LayoutEvaluationFailed)?;
    state.profiles = vec![profile.clone()];
    state.active_profile_id = profile_id.to_owned();
    state.default_profile_id = profile_id.to_owned();
    state
        .controller_snapshot()
        .map(|snapshot| snapshot.layout_quality)
        .map_err(|_| GenerationSpecError::LayoutEvaluationFailed)
}

fn first_color(
    object: &Map<String, Value>,
    fields: &[&str],
    path: &str,
) -> Result<Option<Color>, GenerationSpecError> {
    for field in fields {
        let Some(value) = object.get(*field).filter(|value| !value.is_null()) else {
            continue;
        };
        return parse_color_value(value, &format!("{path}.{field}")).map(Some);
    }
    Ok(None)
}

fn parse_color_value(value: &Value, path: &str) -> Result<Color, GenerationSpecError> {
    if let Some(string) = value.as_str() {
        return Color::from_hex(string).ok_or_else(|| GenerationSpecError::InvalidEnum {
            path: path.to_owned(),
            value: string.to_owned(),
        });
    }
    let color = value
        .as_object()
        .ok_or_else(|| invalid_type(path, "a color object or hex string"))?;
    reject_unknown(color, path, &["red", "green", "blue", "alpha"])?;
    let red = required_number(color, "red", path)?;
    let green = required_number(color, "green", path)?;
    let blue = required_number(color, "blue", path)?;
    let alpha = first_number(color, &["alpha"], &format!("{path}.alpha"))?.unwrap_or(1.0);
    for (name, component) in [
        ("red", red),
        ("green", green),
        ("blue", blue),
        ("alpha", alpha),
    ] {
        validate_range(component, 0.0, 1.0, &format!("{path}.{name}"))?;
    }
    Ok(Color {
        red,
        green,
        blue,
        alpha,
    }
    .normalized())
}

fn reject_unknown(
    object: &Map<String, Value>,
    path: &str,
    allowed: &[&str],
) -> Result<(), GenerationSpecError> {
    if let Some(field) = object
        .keys()
        .find(|field| !allowed.contains(&field.as_str()))
    {
        return Err(GenerationSpecError::UnknownField {
            path: path.to_owned(),
            field: field.clone(),
        });
    }
    Ok(())
}

fn scan_for_control_characters(value: &Value, path: &str) -> Result<(), GenerationSpecError> {
    match value {
        Value::String(string) => ensure_no_control_characters(string, path),
        Value::Array(values) => {
            for (index, child) in values.iter().enumerate() {
                scan_for_control_characters(
                    child,
                    &bounded_error_path(&format!("{path}[{index}]")),
                )?;
            }
            Ok(())
        }
        Value::Object(object) => {
            for (field, child) in object {
                if field.chars().any(char::is_control) {
                    return Err(GenerationSpecError::ControlCharacter {
                        path: bounded_error_path(&format!("{path}.<field>")),
                    });
                }
                scan_for_control_characters(
                    child,
                    &bounded_error_path(&format!("{path}.{field}")),
                )?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn ensure_no_control_characters(value: &str, path: &str) -> Result<(), GenerationSpecError> {
    if value.chars().any(char::is_control) {
        Err(GenerationSpecError::ControlCharacter {
            path: bounded_error_path(path),
        })
    } else {
        Ok(())
    }
}

fn bounded_error_path(path: &str) -> String {
    if path.len() <= MAX_ERROR_PATH_BYTES {
        return path.to_owned();
    }
    let suffix = "...";
    let mut end = MAX_ERROR_PATH_BYTES - suffix.len();
    while !path.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{suffix}", &path[..end])
}

fn scan_for_unsafe_fields(value: &Value, path: &str) -> Result<(), GenerationSpecError> {
    match value {
        Value::Object(object) => {
            for (field, child) in object {
                let normalized = normalized_text(field);
                if is_unsafe_field(&normalized) {
                    return Err(GenerationSpecError::UnsafeField {
                        path: path.to_owned(),
                        field: field.clone(),
                    });
                }
                scan_for_unsafe_fields(child, &format!("{path}.{field}"))?;
            }
        }
        Value::Array(values) => {
            for (index, child) in values.iter().enumerate() {
                scan_for_unsafe_fields(child, &format!("{path}[{index}]"))?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn is_unsafe_field(field: &str) -> bool {
    matches!(
        field,
        "path"
            | "filepath"
            | "data"
            | "asset"
            | "assets"
            | "assetid"
            | "assetlibrary"
            | "bookmarkdata"
            | "iconpngdata"
            | "imagedata"
            | "thumbnaildata"
            | "binarydata"
            | "image"
            | "tile"
    ) || field.ends_with("path")
        || field.ends_with("data")
        || field.ends_with("url")
}

fn optional_string(
    object: &Map<String, Value>,
    field: &str,
    path: &str,
) -> Result<Option<String>, GenerationSpecError> {
    match object.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(invalid_type(path, "a string")),
    }
}

fn first_string(
    object: &Map<String, Value>,
    fields: &[&str],
    fallback: &str,
    path: &str,
) -> Result<String, GenerationSpecError> {
    for field in fields {
        match object.get(*field) {
            None | Some(Value::Null) => continue,
            Some(Value::String(value)) => return Ok(value.clone()),
            Some(_) => return Err(invalid_type(&format!("{path} ({field})"), "a string")),
        }
    }
    Ok(fallback.to_owned())
}

fn optional_string_array(
    object: &Map<String, Value>,
    field: &str,
    path: &str,
) -> Result<Option<Vec<String>>, GenerationSpecError> {
    let Some(value) = object.get(field) else {
        return Ok(None);
    };
    if value.is_null() {
        return Ok(None);
    }
    let values = value
        .as_array()
        .ok_or_else(|| invalid_type(path, "an array of strings"))?;
    values
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| invalid_type(path, "an array of strings"))
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Some)
}

fn optional_bool(
    object: &Map<String, Value>,
    field: &str,
    path: &str,
) -> Result<Option<bool>, GenerationSpecError> {
    match object.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid_type(path, "a boolean")),
    }
}

fn first_bool(
    object: &Map<String, Value>,
    fields: &[&str],
    path: &str,
) -> Result<Option<bool>, GenerationSpecError> {
    for field in fields {
        if object.contains_key(*field) {
            if let Some(value) = optional_bool(object, field, &format!("{path} ({field})"))? {
                return Ok(Some(value));
            }
        }
    }
    Ok(None)
}

fn first_number(
    object: &Map<String, Value>,
    fields: &[&str],
    path: &str,
) -> Result<Option<f64>, GenerationSpecError> {
    for field in fields {
        match object.get(*field) {
            None | Some(Value::Null) => continue,
            Some(Value::Number(value)) => {
                let number = value
                    .as_f64()
                    .ok_or_else(|| GenerationSpecError::InvalidNumber {
                        path: path.to_owned(),
                    })?;
                if !number.is_finite() {
                    return Err(GenerationSpecError::InvalidNumber {
                        path: path.to_owned(),
                    });
                }
                return Ok(Some(number));
            }
            Some(_) => return Err(invalid_type(&format!("{path} ({field})"), "a number")),
        }
    }
    Ok(None)
}

fn required_number(
    object: &Map<String, Value>,
    field: &str,
    path: &str,
) -> Result<f64, GenerationSpecError> {
    first_number(object, &[field], &format!("{path}.{field}"))?
        .ok_or_else(|| invalid_type(&format!("{path}.{field}"), "a number"))
}

fn optional_u64(
    object: &Map<String, Value>,
    field: &str,
    path: &str,
) -> Result<Option<u64>, GenerationSpecError> {
    match object.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid_type(&format!("{path}{field}"), "a nonnegative integer")),
        Some(_) => Err(invalid_type(
            &format!("{path}{field}"),
            "a nonnegative integer",
        )),
    }
}

fn optional_button(
    object: &Map<String, Value>,
    field: &str,
    path: &str,
) -> Result<Option<GameButton>, GenerationSpecError> {
    optional_string(object, field, path)?
        .map(|value| {
            parse_button(&value).ok_or_else(|| GenerationSpecError::InvalidEnum {
                path: path.to_owned(),
                value,
            })
        })
        .transpose()
}

fn optional_enum(
    object: &Map<String, Value>,
    field: &str,
    allowed: &[&str],
    path: &str,
) -> Result<Option<String>, GenerationSpecError> {
    optional_string(object, field, &format!("{path}.{field}"))?
        .map(|value| {
            if allowed.contains(&value.as_str()) {
                Ok(value)
            } else {
                Err(GenerationSpecError::InvalidEnum {
                    path: format!("{path}.{field}"),
                    value,
                })
            }
        })
        .transpose()
}

fn parse_role(value: &str, path: &str) -> Result<Role, GenerationSpecError> {
    match value {
        "movement" => Ok(Role::Movement),
        "primary" => Ok(Role::Primary),
        "secondary" => Ok(Role::Secondary),
        "utility" => Ok(Role::Utility),
        "system" => Ok(Role::System),
        _ => Err(GenerationSpecError::InvalidEnum {
            path: path.to_owned(),
            value: value.to_owned(),
        }),
    }
}

fn validate_optional_range(
    value: Option<f64>,
    lower: f64,
    upper: f64,
    path: &str,
) -> Result<(), GenerationSpecError> {
    value.map_or(Ok(()), |value| validate_range(value, lower, upper, path))
}
fn validate_range(
    value: f64,
    lower: f64,
    upper: f64,
    path: &str,
) -> Result<(), GenerationSpecError> {
    if !value.is_finite() {
        Err(GenerationSpecError::InvalidNumber {
            path: path.to_owned(),
        })
    } else if !(lower..=upper).contains(&value) {
        Err(GenerationSpecError::NumberOutOfBounds {
            path: path.to_owned(),
        })
    } else {
        Ok(())
    }
}

fn ensure_byte_bound(value: &str, maximum: usize, path: &str) -> Result<(), GenerationSpecError> {
    if value.len() > maximum {
        Err(GenerationSpecError::StringTooLong {
            path: path.to_owned(),
        })
    } else {
        Ok(())
    }
}
fn ensure_string_bound(value: &str, maximum: usize, path: &str) -> Result<(), GenerationSpecError> {
    if value.chars().count() > maximum {
        Err(GenerationSpecError::StringTooLong {
            path: path.to_owned(),
        })
    } else {
        Ok(())
    }
}
fn ensure_output_bound(size: usize) -> Result<(), GenerationSpecError> {
    if size > MAXIMUM_GENERATION_OUTPUT_BYTES {
        Err(GenerationSpecError::OutputTooLarge(size))
    } else {
        Ok(())
    }
}
fn invalid_type(path: &str, expected: &'static str) -> GenerationSpecError {
    GenerationSpecError::InvalidType {
        path: path.to_owned(),
        expected,
    }
}

fn normalized_display_name(value: &str, fallback: &str) -> String {
    let trimmed = value.trim();
    if !trimmed.is_empty() {
        return trimmed.to_owned();
    }
    let fallback = fallback.trim();
    if fallback.is_empty() {
        "Agent Generated Game".to_owned()
    } else {
        fallback.to_owned()
    }
}
fn normalized_text(value: &str) -> String {
    value
        .to_lowercase()
        .chars()
        .filter(|character| character.is_alphanumeric())
        .collect()
}
fn normalized_control_label(value: &str, fallback: &str) -> String {
    let trimmed = value.trim();
    let resolved = if trimmed.is_empty() {
        fallback.trim()
    } else {
        trimmed
    };
    UnicodeSegmentation::graphemes(resolved, true)
        .take(NORMALIZED_LABEL_CHARACTERS)
        .collect()
}
fn normalized_control_text(control: &ParsedControl) -> String {
    normalized_text(
        &[
            control.id.as_deref(),
            control.button.map(button_name),
            Some(control.label.as_str()),
            Some(control.key.as_str()),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" "),
    )
}

fn parse_button(value: &str) -> Option<GameButton> {
    GameButton::ALL
        .into_iter()
        .find(|button| button_name(*button) == value)
}
fn custom_slots() -> impl Iterator<Item = GameButton> {
    GameButton::ALL.into_iter().skip(10)
}
fn is_builtin(button: GameButton) -> bool {
    button_rank(button) < 10
}
fn button_rank(button: GameButton) -> usize {
    GameButton::ALL
        .iter()
        .position(|candidate| *candidate == button)
        .unwrap_or(usize::MAX)
}
fn button_rank_name(button: &str) -> usize {
    parse_button(button).map_or(usize::MAX, button_rank)
}
fn button_name(button: GameButton) -> &'static str {
    match button {
        GameButton::Up => "up",
        GameButton::Down => "down",
        GameButton::Left => "left",
        GameButton::Right => "right",
        GameButton::Jump => "jump",
        GameButton::Attack => "attack",
        GameButton::Dash => "dash",
        GameButton::Focus => "focus",
        GameButton::Map => "map",
        GameButton::Pause => "pause",
        GameButton::Custom1 => "custom1",
        GameButton::Custom2 => "custom2",
        GameButton::Custom3 => "custom3",
        GameButton::Custom4 => "custom4",
        GameButton::Custom5 => "custom5",
        GameButton::Custom6 => "custom6",
        GameButton::Custom7 => "custom7",
        GameButton::Custom8 => "custom8",
    }
}
fn button_display_name(button: GameButton) -> &'static str {
    match button {
        GameButton::Up => "Up",
        GameButton::Down => "Down",
        GameButton::Left => "Left",
        GameButton::Right => "Right",
        GameButton::Jump => "Jump",
        GameButton::Attack => "Attack",
        GameButton::Dash => "Dash",
        GameButton::Focus => "Focus",
        GameButton::Map => "Map",
        GameButton::Pause => "Pause",
        GameButton::Custom1 => "Custom 1",
        GameButton::Custom2 => "Custom 2",
        GameButton::Custom3 => "Custom 3",
        GameButton::Custom4 => "Custom 4",
        GameButton::Custom5 => "Custom 5",
        GameButton::Custom6 => "Custom 6",
        GameButton::Custom7 => "Custom 7",
        GameButton::Custom8 => "Custom 8",
    }
}
fn built_in_id(button: GameButton) -> &'static str {
    match button {
        GameButton::Up => "00000000-0000-0000-0000-000000000101",
        GameButton::Down => "00000000-0000-0000-0000-000000000102",
        GameButton::Left => "00000000-0000-0000-0000-000000000103",
        GameButton::Right => "00000000-0000-0000-0000-000000000104",
        GameButton::Jump => "00000000-0000-0000-0000-000000000105",
        GameButton::Attack => "00000000-0000-0000-0000-000000000106",
        GameButton::Dash => "00000000-0000-0000-0000-000000000107",
        GameButton::Focus => "00000000-0000-0000-0000-000000000108",
        GameButton::Map => "00000000-0000-0000-0000-000000000109",
        GameButton::Pause => "00000000-0000-0000-0000-000000000110",
        _ => unreachable!("custom buttons have generated IDs"),
    }
}
fn role_name(role: Role) -> &'static str {
    match role {
        Role::Movement => "movement",
        Role::Primary => "primary",
        Role::Secondary => "secondary",
        Role::Utility => "utility",
        Role::System => "system",
    }
}
fn push_warning(
    warnings: &mut Vec<GenerationSpecWarning>,
    omitted_warning_count: &mut usize,
    code: &str,
    source_ordinal: usize,
    message: &str,
) {
    if warnings.len() < MAXIMUM_GENERATION_WARNINGS {
        warnings.push(GenerationSpecWarning {
            code: code.to_owned(),
            source_ordinal,
            message: message.to_owned(),
        });
    } else {
        *omitted_warning_count += 1;
    }
}
fn pretty_string(value: &Value) -> Result<String, GenerationSpecError> {
    serde_json::to_string_pretty(value).map_err(|_| GenerationSpecError::EncodingFailed)
}
fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}
