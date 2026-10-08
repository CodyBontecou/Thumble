//! Semantic game-controller manifests compiled into portable, asset-free profiles.
//!
//! Asset identifiers remain opaque sidecar references. This planner has no I/O,
//! installation, network, image-loading, or input-emission capabilities.

use crate::{
    plan_generation_spec, semantic_key_code, ButtonBindings, ControllerLayoutQualitySnapshot,
    GenerationSpecError, GenerationSpecWarning, KeyBinding, OutputBinding,
    ProfileArtifactContentHash, ProfileArtifactError, VirtualGamepadButton,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;
use thumble_protocol::GameButton;

pub const GAME_CONTROLLER_SCHEMA_VERSION: u32 = 1;
pub const GAME_CONTROLLER_PLANNER_REVISION: u32 = 1;
pub const MAXIMUM_GAME_CONTROLLER_BYTES: usize = 256 * 1024;
pub const MAXIMUM_GAME_CONTROLLER_ACTIONS: usize = 18;
pub const MAXIMUM_GAME_CONTROLLER_CONTROLS: usize = 18;
pub const MAXIMUM_GAME_CONTROLLER_ASSETS: usize = 90;
const MAXIMUM_ID_BYTES: usize = 64;
const MAXIMUM_DISPLAY_CHARACTERS: usize = 256;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerManifest {
    pub schema_version: u32,
    pub id: String,
    pub name: String,
    pub game: GameControllerGame,
    pub output_mode: GameControllerOutputMode,
    pub actions: Vec<GameControllerAction>,
    pub controls: Vec<GameControllerControl>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub assets: Vec<GameControllerAsset>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerGame {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GameControllerOutputMode {
    Keyboard,
    Controller,
    Custom,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerAction {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<GameControllerOutput>,
}

/// A single held key chord and/or one virtual gamepad button. No sequences or macros.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerOutput {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub modifiers: Vec<GameControllerModifier>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub gamepad_button: Option<VirtualGamepadButton>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GameControllerModifier {
    Ctrl,
    Shift,
    Option,
    Command,
}

impl GameControllerModifier {
    fn mask(self) -> u8 {
        match self {
            Self::Ctrl => 8,
            Self::Shift => 2,
            Self::Option => 4,
            Self::Command => 1,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerControl {
    pub id: String,
    #[serde(rename = "actionID")]
    pub action_id: String,
    pub kind: GameControllerControlKind,
    pub role: GameControllerRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub y: Option<f64>,
    /// Native widthScale, not a fraction of the device canvas.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width_scale: Option<f64>,
    /// Native heightScale, not a fraction of the device canvas.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height_scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub visual: Option<GameControllerVisual>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GameControllerControlKind {
    Button,
    Trackpad,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum GameControllerRole {
    Primary,
    Secondary,
    Utility,
    System,
    Movement,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerAsset {
    pub id: String,
    pub alt: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerVisual {
    #[serde(
        rename = "iconAssetID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub icon_asset_id: Option<String>,
    #[serde(
        rename = "backgroundAssetID",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub background_asset_id: Option<String>,
    #[serde(
        rename = "stateAssetIDs",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub state_asset_ids: Option<GameControllerStateAssetIDs>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerStateAssetIDs {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pressed: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub disabled: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GameControllerControlMapping {
    #[serde(rename = "controlID")]
    pub control_id: String,
    #[serde(rename = "actionID")]
    pub action_id: String,
    #[serde(rename = "elementID")]
    pub element_id: String,
    pub game_button: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GameControllerVisualAttachment {
    #[serde(rename = "controlID")]
    pub control_id: String,
    #[serde(rename = "actionID")]
    pub action_id: String,
    #[serde(rename = "elementID")]
    pub element_id: String,
    pub visual: GameControllerVisual,
}

#[derive(Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GameControllerPlan {
    pub schema_version: u32,
    pub planner_revision: u32,
    /// SHA-256 of the canonical, fully decoded manifest, including visual metadata.
    pub descriptor_digest: String,
    pub generation_descriptor_digest: String,
    pub artifact_content_hash: ProfileArtifactContentHash,
    /// Controller intent compiles as custom mode so native hosts honor explicit outputs.
    pub effective_output_mode: GameControllerOutputMode,
    pub manifest: GameControllerManifest,
    pub generation_spec: Value,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    #[serde(rename = "artifactJSON")]
    pub artifact_json: String,
    pub control_mappings: Vec<GameControllerControlMapping>,
    pub assets: Vec<GameControllerAsset>,
    pub visual_attachments: Vec<GameControllerVisualAttachment>,
    pub warnings: Vec<GenerationSpecWarning>,
    pub layout_quality: ControllerLayoutQualitySnapshot,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GameControllerError {
    TooLarge(usize),
    DecodingFailed,
    Validation { path: String, message: String },
    CanonicalizationFailed,
    EncodingFailed,
    CapacityLoss,
    Generation(GenerationSpecError),
    Artifact(ProfileArtifactError),
}

impl fmt::Display for GameControllerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::TooLarge(size) => write!(formatter, "game-controller manifest is too large ({size} bytes)"),
            Self::DecodingFailed => formatter.write_str("game-controller manifest JSON decoding failed; check required fields, enum values, and unknown fields"),
            Self::Validation { path, message } => write!(formatter, "game-controller field {path}: {message}"),
            Self::CanonicalizationFailed => formatter.write_str("game-controller manifest canonicalization failed"),
            Self::EncodingFailed => formatter.write_str("game-controller plan encoding failed"),
            Self::CapacityLoss => formatter.write_str("game-controller controls exceed available native slots"),
            Self::Generation(error) => write!(formatter, "game-controller generation failed: {error}"),
            Self::Artifact(error) => write!(formatter, "game-controller artifact failed: {error}"),
        }
    }
}

impl Error for GameControllerError {}

impl From<GenerationSpecError> for GameControllerError {
    fn from(error: GenerationSpecError) -> Self {
        Self::Generation(error)
    }
}

impl From<ProfileArtifactError> for GameControllerError {
    fn from(error: ProfileArtifactError) -> Self {
        Self::Artifact(error)
    }
}

/// Validate and plan a manifest without installing a profile or producing input.
pub fn plan_game_controller(
    manifest_json: &[u8],
) -> Result<GameControllerPlan, GameControllerError> {
    if manifest_json.len() > MAXIMUM_GAME_CONTROLLER_BYTES {
        return Err(GameControllerError::TooLarge(manifest_json.len()));
    }
    let manifest: GameControllerManifest =
        serde_json::from_slice(manifest_json).map_err(|_| GameControllerError::DecodingFailed)?;
    validate_manifest(&manifest)?;
    let canonical = serde_json_canonicalizer::to_vec(&manifest)
        .map_err(|_| GameControllerError::CanonicalizationFailed)?;
    let descriptor_digest = sha256_hex(&canonical);

    let actions: BTreeMap<_, _> = manifest
        .actions
        .iter()
        .map(|action| (action.id.as_str(), action))
        .collect();
    let mut controls: Vec<_> = manifest.controls.iter().collect();
    // Reserve the specialized custom slot before buttons can consume it. The
    // remaining sort is independent of manifest array order and asset metadata.
    controls.sort_by(|left, right| {
        let rank = |control: &GameControllerControl| match control.kind {
            GameControllerControlKind::Trackpad => 0,
            GameControllerControlKind::Button => 1,
        };
        rank(left).cmp(&rank(right)).then(left.id.cmp(&right.id))
    });

    // The underlying generator's inference fallback only covers custom slots;
    // allocate every physical slot explicitly to use the full native capacity.
    let button_slots = [
        GameButton::Jump,
        GameButton::Attack,
        GameButton::Dash,
        GameButton::Focus,
        GameButton::Custom1,
        GameButton::Custom2,
        GameButton::Custom3,
        GameButton::Custom4,
        GameButton::Custom5,
        GameButton::Custom6,
        GameButton::Custom7,
        GameButton::Custom8,
        GameButton::Map,
        GameButton::Pause,
        GameButton::Up,
        GameButton::Down,
        GameButton::Left,
        GameButton::Right,
    ];
    let has_trackpad = controls
        .iter()
        .any(|control| control.kind == GameControllerControlKind::Trackpad);
    let mut available_buttons = button_slots
        .into_iter()
        .filter(|button| !has_trackpad || *button != GameButton::Custom1);
    let generated_controls = controls
        .iter()
        .map(|control| {
            let action = actions[control.action_id.as_str()];
            let stable_id = sha256_hex(format!("{}:{}", control.id, action.id).as_bytes());
            let button = if control.kind == GameControllerControlKind::Trackpad {
                GameButton::Custom1
            } else {
                available_buttons
                    .next()
                    .expect("validated native control capacity")
            };
            let mut value = json!({
                "id": stable_id,
                "button": button,
                "label": action.label,
                "kind": control.kind,
                "role": control.role,
            });
            let object = value.as_object_mut().expect("literal is an object");
            for (key, number) in [
                ("x", control.x),
                ("y", control.y),
                ("widthScale", control.width_scale),
                ("heightScale", control.height_scale),
            ] {
                if let Some(number) = number {
                    object.insert(key.to_owned(), json!(number));
                }
            }
            if let Some(output) = &action.output {
                if let Some(key) = &output.key {
                    object.insert("key".to_owned(), json!(key));
                }
                object.insert("modifiers".to_owned(), json!(output.modifiers));
            }
            value
        })
        .collect::<Vec<_>>();
    // Gamepad semantics have no generation-spec output field; canonical notes
    // incorporate them into native generation identity without adding assets.
    let output_identity = controls
        .iter()
        .map(|control| {
            let action = actions[control.action_id.as_str()];
            json!({"controlID":control.id,"actionID":action.id,"output":action.output})
        })
        .collect::<Vec<_>>();
    let identity_note = serde_json::to_string(
        &json!({"outputMode":manifest.output_mode,"controls":output_identity}),
    )
    .map_err(|_| GameControllerError::EncodingFailed)?;
    // A single generation note is capped at 1024 bytes. Hashing the semantic
    // descriptor preserves identity while keeping generation input bounded.
    let generation_spec = json!({
        "schemaVersion":1,
        "gameName":manifest.name,
        "source":format!("game-controller:{}:{}", manifest.id, manifest.game.id),
        "notes":[format!("game-controller-output:{}", sha256_hex(identity_note.as_bytes()))],
        "controls":generated_controls,
    });
    let generation_bytes =
        serde_json::to_vec(&generation_spec).map_err(|_| GameControllerError::EncodingFailed)?;
    let generated = plan_generation_spec(&generation_bytes, None)?;
    if !generated.dropped_controls.is_empty() || generated.assigned_controls.len() != controls.len()
    {
        return Err(GameControllerError::CapacityLoss);
    }

    // Reset inherited generation defaults. Explicit empty outputs for all 18
    // legacy slots prevent a host's global fallback map from activating them.
    let mut key_bindings = ButtonBindings::<KeyBinding>::default();
    let mut output_bindings = ButtonBindings::<OutputBinding>::default();
    for button in GameButton::ALL {
        output_bindings.insert(button, OutputBinding::default());
    }
    let mut control_mappings = Vec::new();
    let mut visual_attachments = Vec::new();
    let mut element_outputs = BTreeMap::new();
    for assigned in &generated.assigned_controls {
        let control = controls[assigned.source_ordinal];
        let action = actions[control.action_id.as_str()];
        let output = compile_output(action.output.as_ref())?;
        if let Some(keyboard) = &output.keyboard {
            key_bindings.insert_raw(&assigned.button, keyboard.clone());
        }
        output_bindings.insert_raw(&assigned.button, output.clone());
        element_outputs.insert(assigned.element_id.clone(), output);
        control_mappings.push(GameControllerControlMapping {
            control_id: control.id.clone(),
            action_id: action.id.clone(),
            element_id: assigned.element_id.clone(),
            game_button: assigned.button.clone(),
        });
        if let Some(visual) = &control.visual {
            visual_attachments.push(GameControllerVisualAttachment {
                control_id: control.id.clone(),
                action_id: action.id.clone(),
                element_id: assigned.element_id.clone(),
                visual: visual.clone(),
            });
        }
    }
    let effective_output_mode = match manifest.output_mode {
        GameControllerOutputMode::Controller => GameControllerOutputMode::Custom,
        other => other,
    };
    let mut warnings = generated.warnings;
    if manifest.output_mode == GameControllerOutputMode::Controller {
        warnings.push(GenerationSpecWarning {
            code: "controller-output-uses-custom-mode".to_owned(),
            source_ordinal: 0,
            message: "Gamepad-only controller intent compiles in custom output mode so native hosts honor explicit gamepadButton mappings.".to_owned(),
        });
    }
    let mut artifact = generated.artifact;
    artifact.profiles[0]["outputMode"] = json!(effective_output_mode);
    let customization = &mut artifact.profiles[0]["customization"];
    if let Some(elements) = customization
        .get_mut("elements")
        .and_then(Value::as_array_mut)
    {
        for element in elements {
            if let Some(output) = element
                .get("id")
                .and_then(Value::as_str)
                .and_then(|id| element_outputs.get(id))
            {
                // Shared KeypadKeyboardBinding Codable uses modifiersRawValue;
                // Mac profile maps below use the separate modifiers spelling.
                let mut direct = json!({"gamepadButtons":output.gamepad_buttons});
                if let Some(keyboard) = &output.keyboard {
                    direct["keyboard"] =
                        json!({"keyCode":keyboard.key_code,"modifiersRawValue":keyboard.modifiers});
                }
                element["output"] = direct;
            }
            // A native trackpad emits pointer gestures, not a button action.
            // Omitting its legacy slot also prevents native visual fallback.
            if element.get("kind").and_then(Value::as_str) == Some("trackpad") {
                if let Some(object) = element.as_object_mut() {
                    object.remove("legacySlot");
                }
            }
        }
    }
    artifact.profile_key_bindings = BTreeMap::from([(
        generated.profile_id.clone(),
        serde_json::to_value(&key_bindings).map_err(|_| GameControllerError::EncodingFailed)?,
    )]);
    artifact.profile_output_bindings = BTreeMap::from([(
        generated.profile_id.clone(),
        serde_json::to_value(&output_bindings).map_err(|_| GameControllerError::EncodingFailed)?,
    )]);
    artifact.refresh_content_hash()?;
    artifact.validate()?;
    let artifact_json = String::from_utf8(artifact.encode_pretty_json()?)
        .map_err(|_| GameControllerError::EncodingFailed)?;
    Ok(GameControllerPlan {
        schema_version: GAME_CONTROLLER_SCHEMA_VERSION,
        planner_revision: GAME_CONTROLLER_PLANNER_REVISION,
        descriptor_digest,
        generation_descriptor_digest: generated.descriptor_digest,
        artifact_content_hash: artifact.content_hash.clone(),
        effective_output_mode,
        assets: manifest.assets.clone(),
        manifest,
        generation_spec,
        profile_id: generated.profile_id,
        artifact_json,
        control_mappings,
        visual_attachments,
        warnings,
        layout_quality: generated.layout_quality,
    })
}

fn validate_manifest(manifest: &GameControllerManifest) -> Result<(), GameControllerError> {
    if manifest.schema_version != GAME_CONTROLLER_SCHEMA_VERSION {
        return invalid("schemaVersion", "must be 1");
    }
    validate_id(&manifest.id, "id")?;
    validate_display(&manifest.name, "name")?;
    validate_id(&manifest.game.id, "game.id")?;
    validate_display(&manifest.game.name, "game.name")?;
    validate_count(
        manifest.actions.len(),
        MAXIMUM_GAME_CONTROLLER_ACTIONS,
        "actions",
        false,
    )?;
    validate_count(
        manifest.controls.len(),
        MAXIMUM_GAME_CONTROLLER_CONTROLS,
        "controls",
        false,
    )?;
    validate_count(
        manifest.assets.len(),
        MAXIMUM_GAME_CONTROLLER_ASSETS,
        "assets",
        true,
    )?;
    let mut actions = BTreeMap::new();
    for (index, action) in manifest.actions.iter().enumerate() {
        let path = format!("actions[{index}]");
        validate_id(&action.id, &format!("{path}.id"))?;
        validate_display(&action.label, &format!("{path}.label"))?;
        if actions.insert(action.id.as_str(), action).is_some() {
            return invalid(&format!("{path}.id"), "duplicate action ID");
        }
        if let Some(output) = &action.output {
            validate_output(output, manifest.output_mode, &format!("{path}.output"))?;
        }
    }
    let mut assets = BTreeSet::new();
    for (index, asset) in manifest.assets.iter().enumerate() {
        let path = format!("assets[{index}]");
        validate_id(&asset.id, &format!("{path}.id"))?;
        validate_display(&asset.alt, &format!("{path}.alt"))?;
        if !assets.insert(asset.id.as_str()) {
            return invalid(&format!("{path}.id"), "duplicate asset ID");
        }
    }
    let mut used_actions = BTreeSet::new();
    let mut used_assets = BTreeSet::new();
    let mut control_ids = BTreeSet::new();
    let mut trackpads = 0;
    for (index, control) in manifest.controls.iter().enumerate() {
        let path = format!("controls[{index}]");
        validate_id(&control.id, &format!("{path}.id"))?;
        validate_id(&control.action_id, &format!("{path}.actionID"))?;
        if !control_ids.insert(control.id.as_str()) {
            return invalid(&format!("{path}.id"), "duplicate control ID");
        }
        let Some(action) = actions.get(control.action_id.as_str()) else {
            return invalid(
                &format!("{path}.actionID"),
                "referenced action does not exist",
            );
        };
        if !used_actions.insert(control.action_id.as_str()) {
            return invalid(
                &format!("{path}.actionID"),
                "action is already assigned to another control",
            );
        }
        match control.kind {
            GameControllerControlKind::Button if action.output.is_none() => {
                return invalid(&format!("{path}.actionID"), "button action requires output")
            }
            GameControllerControlKind::Trackpad => {
                trackpads += 1;
                if trackpads > 1 {
                    return invalid(
                        &format!("{path}.kind"),
                        "only one native trackpad is supported",
                    );
                }
                if action.output.is_some() {
                    return invalid(
                        &format!("{path}.actionID"),
                        "native trackpad action must omit output",
                    );
                }
            }
            _ => {}
        }
        for (field, number, lower, upper) in [
            ("x", control.x, 0.0, 1.0),
            ("y", control.y, 0.0, 1.0),
            ("widthScale", control.width_scale, 0.001, 12.0),
            ("heightScale", control.height_scale, 0.001, 12.0),
        ] {
            if number
                .is_some_and(|number| !number.is_finite() || !(lower..=upper).contains(&number))
            {
                return invalid(
                    &format!("{path}.{field}"),
                    "outside supported native layout range",
                );
            }
        }
        if let Some(visual) = &control.visual {
            let visual_path = format!("{path}.visual");
            let mut references = Vec::new();
            if let Some(id) = &visual.icon_asset_id {
                references.push(("iconAssetID", id));
            }
            if let Some(id) = &visual.background_asset_id {
                references.push(("backgroundAssetID", id));
            }
            if let Some(states) = &visual.state_asset_ids {
                let mut states_count = 0;
                for (field, id) in [
                    ("stateAssetIDs.pressed", &states.pressed),
                    ("stateAssetIDs.active", &states.active),
                    ("stateAssetIDs.disabled", &states.disabled),
                ] {
                    if let Some(id) = id {
                        states_count += 1;
                        references.push((field, id));
                    }
                }
                if states_count == 0 {
                    return invalid(
                        &format!("{visual_path}.stateAssetIDs"),
                        "requires at least one asset reference",
                    );
                }
            }
            if references.is_empty() {
                return invalid(&visual_path, "requires at least one asset reference");
            }
            for (field, id) in references {
                let asset_path = format!("{visual_path}.{field}");
                validate_id(id, &asset_path)?;
                if !assets.contains(id.as_str()) {
                    return invalid(&asset_path, "referenced asset does not exist");
                }
                used_assets.insert(id.as_str());
            }
        }
    }
    if used_actions.len() != actions.len() {
        return invalid(
            "actions",
            "every action must be assigned to exactly one control",
        );
    }
    if used_assets.len() != assets.len() {
        return invalid(
            "assets",
            "every asset must be referenced by a control visual",
        );
    }
    Ok(())
}

fn validate_output(
    output: &GameControllerOutput,
    mode: GameControllerOutputMode,
    path: &str,
) -> Result<(), GameControllerError> {
    if output.key.is_none() && output.gamepad_button.is_none() {
        return invalid(path, "requires a key or gamepadButton");
    }
    if let Some(key) = &output.key {
        if key.len() > 128
            || key.trim() != key
            || key.chars().any(char::is_control)
            || semantic_key_code(key).is_none()
        {
            return invalid(&format!("{path}.key"), "unsupported semantic key");
        }
    } else if !output.modifiers.is_empty() {
        return invalid(&format!("{path}.modifiers"), "modifiers require a key");
    }
    let unique: BTreeSet<_> = output.modifiers.iter().collect();
    if output.modifiers.len() > 4 || unique.len() != output.modifiers.len() {
        return invalid(&format!("{path}.modifiers"), "modifiers must be unique");
    }
    match mode {
        GameControllerOutputMode::Keyboard if output.gamepad_button.is_some() => {
            invalid(path, "keyboard mode supports only key outputs")
        }
        GameControllerOutputMode::Controller if output.key.is_some() => {
            invalid(path, "controller mode supports only gamepadButton outputs")
        }
        _ => Ok(()),
    }
}

fn compile_output(
    output: Option<&GameControllerOutput>,
) -> Result<OutputBinding, GameControllerError> {
    let Some(output) = output else {
        return Ok(OutputBinding::default());
    };
    let keyboard = output.key.as_ref().map(|key| {
        let key_code = semantic_key_code(key).expect("validated semantic key");
        let modifiers = output
            .modifiers
            .iter()
            .fold(0, |mask, modifier| mask | modifier.mask());
        KeyBinding::new(key_code, modifiers)
    });
    let mut gamepad_buttons = BTreeSet::new();
    if let Some(button) = output.gamepad_button {
        let value =
            serde_json::to_value(button).map_err(|_| GameControllerError::EncodingFailed)?;
        gamepad_buttons.insert(
            value
                .as_str()
                .ok_or(GameControllerError::EncodingFailed)?
                .to_owned(),
        );
    }
    Ok(OutputBinding {
        keyboard,
        gamepad_buttons,
    })
}

fn validate_id(id: &str, path: &str) -> Result<(), GameControllerError> {
    if id.is_empty()
        || id.len() > MAXIMUM_ID_BYTES
        || id.split('-').any(|part| {
            part.is_empty()
                || !part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        })
    {
        return invalid(path, "must be a lowercase slug of 1 to 64 bytes");
    }
    Ok(())
}

fn validate_display(value: &str, path: &str) -> Result<(), GameControllerError> {
    if value.trim().is_empty()
        || value.chars().count() > MAXIMUM_DISPLAY_CHARACTERS
        || value.chars().any(char::is_control)
    {
        return invalid(
            path,
            "must be nonblank, control-free text of at most 256 characters",
        );
    }
    Ok(())
}

fn validate_count(
    count: usize,
    maximum: usize,
    path: &str,
    allow_empty: bool,
) -> Result<(), GameControllerError> {
    if count > maximum || (count == 0 && !allow_empty) {
        return invalid(
            path,
            &format!(
                "must contain {} to {maximum} entries",
                if allow_empty { 0 } else { 1 }
            ),
        );
    }
    Ok(())
}

fn invalid<T>(path: &str, message: &str) -> Result<T, GameControllerError> {
    Err(GameControllerError::Validation {
        path: path.to_owned(),
        message: message.to_owned(),
    })
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{PersistentState, ProfileArtifact};
    use thumble_protocol::KeypadElementInputPart;

    fn example() -> Value {
        json!({
            "schemaVersion":1,
            "id":"league-default",
            "name":"League Controller",
            "game":{"id":"league-of-legends","name":"League of Legends"},
            "outputMode":"keyboard",
            "actions":[
                {"id":"ability-q","label":"Ability Q","output":{"key":"Q","modifiers":["ctrl"]}},
                {"id":"pointer","label":"Pointer"}
            ],
            "controls":[
                {"id":"q-button","actionID":"ability-q","kind":"button","role":"primary","x":0.8,"y":0.7,"widthScale":1.0,"visual":{"iconAssetID":"ability-icon"}},
                {"id":"pointer-pad","actionID":"pointer","kind":"trackpad","role":"movement"}
            ],
            "assets":[{"id":"ability-icon","alt":"Placeholder: ability Q icon"}]
        })
    }

    fn plan(value: &Value) -> GameControllerPlan {
        plan_game_controller(&serde_json::to_vec(value).unwrap()).unwrap()
    }

    fn error(value: &Value) -> GameControllerError {
        match plan_game_controller(&serde_json::to_vec(value).unwrap()) {
            Err(error) => error,
            Ok(_) => panic!("expected manifest to be rejected"),
        }
    }

    fn assert_validation(value: &Value, expected_path: &str) {
        match error(value) {
            GameControllerError::Validation { path, .. } => assert_eq!(path, expected_path),
            error => panic!("unexpected error: {error}"),
        }
    }

    #[test]
    fn planning_is_deterministic_and_compiles_a_valid_portable_artifact() {
        let value = example();
        let first = plan(&value);
        let second = plan(&value);
        assert!(first == second);
        assert_eq!(
            serde_json::to_vec(&first).unwrap(),
            serde_json::to_vec(&second).unwrap()
        );
        let artifact = ProfileArtifact::decode_json(first.artifact_json.as_bytes()).unwrap();
        assert_eq!(artifact.content_hash, first.artifact_content_hash);
        artifact
            .to_configuration_document()
            .unwrap()
            .validate()
            .unwrap();
        assert_eq!(first.control_mappings.len(), 2);
        assert_eq!(first.visual_attachments.len(), 1);
        assert_eq!(artifact.profiles[0]["outputMode"], "keyboard");
        assert!(!first.generation_spec.to_string().contains("ability-icon"));
        assert!(!first.artifact_json.contains("ability-icon"));
    }

    #[test]
    fn asset_only_edits_preserve_the_executable_identity_and_change_the_sidecar_digest() {
        let first = plan(&example());
        let mut changed = example();
        changed["assets"][0]["id"] = json!("new-icon");
        changed["assets"][0]["alt"] = json!("Updated cosmetic asset description");
        changed["assets"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":"pressed-icon","alt":"Pressed Q"}));
        changed["controls"][0]["visual"] =
            json!({"backgroundAssetID":"new-icon","stateAssetIDs":{"pressed":"pressed-icon"}});
        let second = plan(&changed);
        assert_eq!(first.generation_spec, second.generation_spec);
        assert_eq!(
            first.generation_descriptor_digest,
            second.generation_descriptor_digest
        );
        assert_eq!(first.profile_id, second.profile_id);
        assert_eq!(first.control_mappings, second.control_mappings);
        assert_eq!(first.artifact_json, second.artifact_json);
        assert_eq!(first.artifact_content_hash, second.artifact_content_hash);
        assert_ne!(first.descriptor_digest, second.descriptor_digest);
        assert_ne!(first.visual_attachments, second.visual_attachments);
    }

    #[test]
    fn semantic_control_order_does_not_depend_on_input_array_order() {
        let first = plan(&example());
        let mut reordered = example();
        reordered["controls"].as_array_mut().unwrap().reverse();
        reordered["actions"].as_array_mut().unwrap().reverse();
        let second = plan(&reordered);
        assert_eq!(first.artifact_json, second.artifact_json);
        assert_eq!(first.control_mappings, second.control_mappings);
        assert_ne!(first.descriptor_digest, second.descriptor_digest);
    }

    #[test]
    fn fresh_output_maps_and_direct_outputs_override_inherited_default_keys() {
        let planned = plan(&example());
        let artifact = ProfileArtifact::decode_json(planned.artifact_json.as_bytes()).unwrap();
        let document = artifact.to_configuration_document().unwrap();
        let mut state = PersistentState::minimal("controller-test").unwrap();
        state.profiles = document.profiles;
        state.active_profile_id = document.active_profile_id;
        state.default_profile_id = document.default_profile_id;
        state.profile_key_bindings = document.profile_key_bindings;
        state.profile_output_bindings = document.profile_output_bindings;
        // Keep the state's old default global maps to prove local empty slots
        // prevent fallback even before adapters mirror imported maps globally.
        assert_eq!(state.profile_key_bindings[&planned.profile_id].len(), 1);
        assert_eq!(state.profile_output_bindings[&planned.profile_id].len(), 18);
        let q_mapping = planned
            .control_mappings
            .iter()
            .find(|mapping| mapping.action_id == "ability-q")
            .unwrap();
        let expected = OutputBinding::keyboard(KeyBinding::new(12, 8));
        assert_eq!(
            state.resolve_element_output(&q_mapping.element_id, KeypadElementInputPart::Primary),
            Some(expected.clone())
        );
        let q_element = state.profiles[0]["customization"]["elements"]
            .as_array()
            .unwrap()
            .iter()
            .find(|element| element["id"] == q_mapping.element_id)
            .unwrap();
        assert_eq!(q_element["output"]["keyboard"]["modifiersRawValue"], 8);
        assert!(q_element["output"]["keyboard"].get("modifiers").is_none());
        for button in GameButton::ALL {
            let output = state.resolve_button_output(button).unwrap();
            if crate::binding::button_name(button) == q_mapping.game_button {
                assert_eq!(output, expected);
            } else {
                assert_eq!(output, OutputBinding::default());
            }
        }
        let trackpad = state.profiles[0]["customization"]["elements"]
            .as_array()
            .unwrap()
            .iter()
            .find(|element| element["kind"] == "trackpad")
            .unwrap();
        assert!(trackpad.get("legacySlot").is_none());
        assert_eq!(
            state.resolve_element_output(
                trackpad["id"].as_str().unwrap(),
                KeypadElementInputPart::Primary
            ),
            Some(OutputBinding::default())
        );
    }

    #[test]
    fn controller_intent_compiles_custom_mode_with_exact_named_gamepad_mapping() {
        let mut value = example();
        value["outputMode"] = json!("controller");
        value["actions"][0]["output"] = json!({"gamepadButton":"north"});
        let planned = plan(&value);
        assert_eq!(
            planned.effective_output_mode,
            GameControllerOutputMode::Custom
        );
        assert_eq!(
            planned.manifest.output_mode,
            GameControllerOutputMode::Controller
        );
        assert!(planned
            .warnings
            .iter()
            .any(|warning| warning.code == "controller-output-uses-custom-mode"));
        let artifact = ProfileArtifact::decode_json(planned.artifact_json.as_bytes()).unwrap();
        let document = artifact.to_configuration_document().unwrap();
        assert!(document.profile_key_bindings[&planned.profile_id].is_empty());
        assert_eq!(artifact.profiles[0]["outputMode"], "custom");
        let mapping = planned
            .control_mappings
            .iter()
            .find(|mapping| mapping.action_id == "ability-q")
            .unwrap();
        let output = document.profile_output_bindings[&planned.profile_id]
            .get_raw(&mapping.game_button)
            .unwrap();
        assert!(output.keyboard.is_none());
        assert_eq!(output.gamepad_buttons, BTreeSet::from(["north".to_owned()]));
    }

    #[test]
    fn custom_mode_supports_one_held_chord_and_gamepad_button_together() {
        let mut value = example();
        value["outputMode"] = json!("custom");
        value["actions"][0]["output"] = json!({"key":"Space","modifiers":["command","shift","option","ctrl"],"gamepadButton":"south"});
        let planned = plan(&value);
        let artifact = ProfileArtifact::decode_json(planned.artifact_json.as_bytes()).unwrap();
        let document = artifact.to_configuration_document().unwrap();
        let output = document.profile_output_bindings[&planned.profile_id]
            .iter()
            .find_map(|(_, output)| output.keyboard.is_some().then_some(output))
            .unwrap();
        assert_eq!(output.keyboard, Some(KeyBinding::new(49, 15)));
        assert_eq!(output.gamepad_buttons, BTreeSet::from(["south".to_owned()]));
    }

    #[test]
    fn capacity_is_preserved_for_seventeen_buttons_and_a_last_trackpad() {
        let mut value = example();
        value["assets"] = json!([]);
        let actions = (0..17).map(|index| json!({"id":format!("action-{index:02}"),"label":format!("Action {index}"),"output":{"key":"Q"}})).chain(std::iter::once(json!({"id":"pointer","label":"Pointer"}))).collect::<Vec<_>>();
        let controls = (0..17).map(|index| json!({"id":format!("button-{index:02}"),"actionID":format!("action-{index:02}"),"kind":"button","role":"primary"})).chain(std::iter::once(json!({"id":"z-pointer","actionID":"pointer","kind":"trackpad","role":"movement"}))).collect::<Vec<_>>();
        value["actions"] = json!(actions);
        value["controls"] = json!(controls);
        let planned = plan(&value);
        assert_eq!(planned.control_mappings.len(), 18);
        assert_eq!(
            planned
                .control_mappings
                .iter()
                .map(|mapping| &mapping.game_button)
                .collect::<BTreeSet<_>>()
                .len(),
            18
        );
        assert_eq!(planned.control_mappings[0].control_id, "z-pointer");
        value["controls"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":"extra","actionID":"pointer","kind":"button","role":"primary"}));
        assert_validation(&value, "controls");
    }

    #[test]
    fn all_eighteen_arbitrary_buttons_receive_unique_native_slots() {
        let mut value = example();
        value["assets"] = json!([]);
        value["actions"] = json!((0..18).map(|index| json!({"id":format!("action-{index:02}"),"label":format!("Action {index}"),"output":{"key":"Q"}})).collect::<Vec<_>>());
        value["controls"] = json!((0..18).map(|index| json!({"id":format!("button-{index:02}"),"actionID":format!("action-{index:02}"),"kind":"button","role":"primary"})).collect::<Vec<_>>());
        let planned = plan(&value);
        assert_eq!(planned.control_mappings.len(), 18);
        assert_eq!(
            planned
                .control_mappings
                .iter()
                .map(|mapping| &mapping.game_button)
                .collect::<BTreeSet<_>>()
                .len(),
            18
        );
    }

    #[test]
    fn documented_league_and_wow_examples_compile_without_capacity_loss() {
        for bytes in [
            include_bytes!("../../../../docs/controllers/examples/league-of-legends.json")
                .as_slice(),
            include_bytes!("../../../../docs/controllers/examples/world-of-warcraft.json")
                .as_slice(),
        ] {
            let planned = plan_game_controller(bytes).unwrap();
            assert_eq!(
                planned.control_mappings.len(),
                planned.manifest.controls.len()
            );
            ProfileArtifact::decode_json(planned.artifact_json.as_bytes())
                .unwrap()
                .validate()
                .unwrap();
        }
    }

    #[test]
    fn action_and_asset_references_are_validated_without_silent_omissions() {
        let mut missing_action = example();
        missing_action["controls"][0]["actionID"] = json!("unknown");
        assert_validation(&missing_action, "controls[0].actionID");
        let mut duplicate_action = example();
        let duplicate = duplicate_action["actions"][0].clone();
        duplicate_action["actions"]
            .as_array_mut()
            .unwrap()
            .push(duplicate);
        assert_validation(&duplicate_action, "actions[2].id");
        let mut duplicate_use = example();
        duplicate_use["controls"][1]["actionID"] = json!("ability-q");
        assert_validation(&duplicate_use, "controls[1].actionID");
        let mut unused_action = example();
        unused_action["actions"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":"unused","label":"Unused","output":{"key":"W"}}));
        assert_validation(&unused_action, "actions");
        let mut missing_asset = example();
        missing_asset["controls"][0]["visual"]["iconAssetID"] = json!("missing");
        assert_validation(&missing_asset, "controls[0].visual.iconAssetID");
        let mut duplicate_asset = example();
        duplicate_asset["assets"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":"ability-icon","alt":"Duplicate"}));
        assert_validation(&duplicate_asset, "assets[1].id");
        let mut unused_asset = example();
        unused_asset["assets"]
            .as_array_mut()
            .unwrap()
            .push(json!({"id":"unused","alt":"Unused"}));
        assert_validation(&unused_asset, "assets");
    }

    #[test]
    fn incompatible_modes_unsupported_keys_and_macros_are_rejected() {
        for (mode, output) in [
            ("keyboard", json!({"gamepadButton":"south"})),
            ("controller", json!({"key":"Q"})),
            ("custom", json!({})),
        ] {
            let mut value = example();
            value["outputMode"] = json!(mode);
            value["actions"][0]["output"] = output;
            assert_validation(&value, "actions[0].output");
        }
        for key in ["not-a-key", "q", "12", "Q\n", " Q "] {
            let mut value = example();
            value["actions"][0]["output"]["key"] = json!(key);
            assert_validation(&value, "actions[0].output.key");
        }
        let mut modifiers = example();
        modifiers["actions"][0]["output"]["modifiers"] = json!(["ctrl", "ctrl"]);
        assert_validation(&modifiers, "actions[0].output.modifiers");
        modifiers["outputMode"] = json!("custom");
        modifiers["actions"][0]["output"] = json!({"gamepadButton":"south","modifiers":["ctrl"]});
        assert_validation(&modifiers, "actions[0].output.modifiers");
        let mut macros = example();
        macros["actions"][0]["output"]["sequence"] = json!(["Q", "W"]);
        assert_eq!(error(&macros), GameControllerError::DecodingFailed);
    }

    #[test]
    fn trackpad_buttons_metadata_and_layout_fail_closed() {
        let mut trackpad_output = example();
        trackpad_output["actions"][1]["output"] = json!({"key":"Q"});
        assert_validation(&trackpad_output, "controls[1].actionID");
        let mut missing_button_output = example();
        missing_button_output["actions"][0]
            .as_object_mut()
            .unwrap()
            .remove("output");
        assert_validation(&missing_button_output, "controls[0].actionID");
        for field in ["path", "url", "data"] {
            let mut unsafe_asset = example();
            unsafe_asset["assets"][0][field] = json!("value");
            assert_eq!(error(&unsafe_asset), GameControllerError::DecodingFailed);
        }
        let mut bad_id = example();
        bad_id["assets"][0]["id"] = json!("https://example.test/icon");
        assert_validation(&bad_id, "assets[0].id");
        let mut bad_name = example();
        bad_name["name"] = json!("Name\n");
        assert_validation(&bad_name, "name");
        let mut bad_layout = example();
        bad_layout["controls"][0]["x"] = json!(1.01);
        assert_validation(&bad_layout, "controls[0].x");
        bad_layout["controls"][0]["x"] = json!(0.8);
        bad_layout["controls"][0]["widthScale"] = json!(12.01);
        assert_validation(&bad_layout, "controls[0].widthScale");
        let mut empty_visual = example();
        empty_visual["controls"][0]["visual"] = json!({});
        assert_validation(&empty_visual, "controls[0].visual");
    }

    #[test]
    fn version_required_fields_unknown_fields_and_byte_bound_are_checked() {
        let mut wrong_version = example();
        wrong_version["schemaVersion"] = json!(2);
        assert_validation(&wrong_version, "schemaVersion");
        let mut missing_version = example();
        missing_version
            .as_object_mut()
            .unwrap()
            .remove("schemaVersion");
        assert_eq!(error(&missing_version), GameControllerError::DecodingFailed);
        let mut unknown = example();
        unknown["extension"] = json!(true);
        assert_eq!(error(&unknown), GameControllerError::DecodingFailed);
        let oversized = vec![b' '; MAXIMUM_GAME_CONTROLLER_BYTES + 1];
        assert_eq!(
            plan_game_controller(&oversized).err(),
            Some(GameControllerError::TooLarge(oversized.len()))
        );
    }
}
