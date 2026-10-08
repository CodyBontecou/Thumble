//! Validated, passive PNG attachments for locally installed game-controller profiles.
//!
//! This transforms a configuration snapshot only. Portable artifacts remain asset-free;
//! installation, drafts, persistence, and input emission belong to host adapters.

use crate::{
    plan_game_controller, ConfigurationDocument, ConfigurationDocumentError, GameControllerError,
    GameControllerPlan, GameControllerVisual, OutputBinding, ProfileArtifact,
    MAXIMUM_GAME_CONTROLLER_ASSETS,
};
use base64::{engine::general_purpose::STANDARD, Engine as _};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::error::Error;
use std::fmt;
use std::io::Cursor;
use unicode_segmentation::UnicodeSegmentation;
use uuid::Uuid;

pub const MAXIMUM_GAME_CONTROLLER_IMAGE_BYTES: usize = 2_500_000;
pub const MAXIMUM_GAME_CONTROLLER_TOTAL_IMAGE_BYTES: usize = 4 * 1024 * 1024;
pub const MAXIMUM_GAME_CONTROLLER_IMAGE_DIMENSION: u32 = 2048;
pub const MAXIMUM_GAME_CONTROLLER_TOTAL_IMAGE_PIXELS: usize = 16 * 1024 * 1024;
const MAXIMUM_DECODED_IMAGE_BYTES: usize = 16 * 1024 * 1024;
const ASSET_NAMESPACE: Uuid = Uuid::from_u128(0x7af09b4045e55bc99a23c1fae99d6ab5);

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerAssetImage {
    #[serde(rename = "assetID")]
    pub asset_id: String,
    pub png_base64: String,
}

// Debug output deliberately excludes image payloads and source manifest text.
impl fmt::Debug for GameControllerAssetImage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GameControllerAssetImage")
            .field("asset_id", &self.asset_id)
            .field("encoded_bytes", &self.png_base64.len())
            .finish()
    }
}

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerAssetAttachment {
    #[serde(rename = "manifestJSON")]
    pub manifest_json: String,
    #[serde(rename = "profileID")]
    pub profile_id: String,
    pub images: Vec<GameControllerAssetImage>,
}

impl fmt::Debug for GameControllerAssetAttachment {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("GameControllerAssetAttachment")
            .field("manifest_bytes", &self.manifest_json.len())
            .field("profile_id", &self.profile_id)
            .field("image_count", &self.images.len())
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerAssetMapping {
    #[serde(rename = "assetID")]
    pub asset_id: String,
    #[serde(rename = "nativeAssetID")]
    pub native_asset_id: String,
    pub sha256: String,
    pub byte_count: usize,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GameControllerAssetAttachmentSummary {
    #[serde(rename = "profileID")]
    pub profile_id: String,
    #[serde(rename = "manifestID")]
    pub manifest_id: String,
    /// The normalized manifest digest. Image identity is carried by asset_mappings.
    pub descriptor_digest: String,
    pub asset_mappings: Vec<GameControllerAssetMapping>,
    pub attached_control_count: usize,
    /// Includes the primary customization and each existing orientation variant.
    pub updated_variant_count: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GameControllerAssetAttachmentPlan {
    pub document: ConfigurationDocument,
    pub summary: GameControllerAssetAttachmentSummary,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GameControllerAssetAttachmentError {
    Manifest(GameControllerError),
    InvalidConfiguration(ConfigurationDocumentError),
    Invalid { path: String, message: &'static str },
}

impl fmt::Display for GameControllerAssetAttachmentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Manifest(error) => write!(f, "game-controller artwork manifest: {error}"),
            Self::InvalidConfiguration(error) => {
                write!(f, "game-controller artwork configuration: {error}")
            }
            Self::Invalid { path, message } => {
                write!(f, "game-controller artwork field {path}: {message}")
            }
        }
    }
}

impl Error for GameControllerAssetAttachmentError {}

type AttachmentResult<T> = Result<T, GameControllerAssetAttachmentError>;

struct PreparedAttachment {
    controller: GameControllerPlan,
    assets: Vec<Value>,
    summary: GameControllerAssetAttachmentSummary,
}

/// Fully validate image bytes and expose a stable, payload-free request identity.
/// No configuration or host state is required, making this suitable for replay checks.
pub fn validate_game_controller_asset_attachment(
    attachment: &GameControllerAssetAttachment,
) -> AttachmentResult<GameControllerAssetAttachmentSummary> {
    Ok(prepare(attachment)?.summary)
}

/// Attach validated PNGs to a matching locally installed controller, without I/O.
/// The returned candidate preserves bindings, selection, geometry, unrelated resources,
/// and all visual fields that are not explicitly supplied by the manifest.
pub fn attach_game_controller_assets(
    document: &ConfigurationDocument,
    attachment: &GameControllerAssetAttachment,
) -> AttachmentResult<GameControllerAssetAttachmentPlan> {
    document
        .validate()
        .map_err(GameControllerAssetAttachmentError::InvalidConfiguration)?;
    let mut prepared = prepare(attachment)?;
    let source = ProfileArtifact::decode_json(prepared.controller.artifact_json.as_bytes())
        .and_then(|artifact| artifact.to_configuration_document())
        .map_err(|_| invalid_error("manifestJSON", "compiled controller profile is invalid"))?;
    let index = document
        .profiles
        .iter()
        .position(|profile| {
            profile
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|id| id.eq_ignore_ascii_case(&attachment.profile_id))
        })
        .ok_or_else(|| invalid_error("profileID", "profile does not exist"))?;
    let target = &document.profiles[index];
    if target.get("outputMode") != source.profiles[0].get("outputMode") {
        return invalid(
            "profileID",
            "profile output mode differs from the compiled controller",
        );
    }
    verify_binding_maps(
        document,
        &source,
        &attachment.profile_id,
        &prepared.controller.profile_id,
    )?;
    let mut candidate = document.clone();
    let profile = candidate.profiles[index]
        .as_object_mut()
        .ok_or_else(|| invalid_error("profileID", "profile must be an object"))?;
    let expected = source.profiles[0]["customization"]["elements"]
        .as_array()
        .ok_or_else(|| invalid_error("manifestJSON", "compiled controller elements are invalid"))?;
    for variant in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let Some(customization) = profile.get_mut(variant).filter(|value| !value.is_null()) else {
            continue;
        };
        apply_variant(customization, expected, &prepared, variant)?;
        prepared.summary.updated_variant_count += 1;
    }
    candidate
        .validate()
        .map_err(GameControllerAssetAttachmentError::InvalidConfiguration)?;
    Ok(GameControllerAssetAttachmentPlan {
        document: candidate,
        summary: prepared.summary,
    })
}

fn prepare(attachment: &GameControllerAssetAttachment) -> AttachmentResult<PreparedAttachment> {
    let id = Uuid::parse_str(&attachment.profile_id)
        .map_err(|_| invalid_error("profileID", "must be a canonical UUID"))?;
    if !id
        .hyphenated()
        .to_string()
        .eq_ignore_ascii_case(&attachment.profile_id)
    {
        return invalid("profileID", "must be a canonical UUID");
    }
    let controller = plan_game_controller(attachment.manifest_json.as_bytes())
        .map_err(GameControllerAssetAttachmentError::Manifest)?;
    if controller.assets.is_empty() || controller.visual_attachments.is_empty() {
        return invalid(
            "manifestJSON",
            "requires at least one declared and referenced artwork asset",
        );
    }
    if attachment.images.len() > MAXIMUM_GAME_CONTROLLER_ASSETS {
        return invalid("images", "too many image entries");
    }
    let declared: BTreeMap<_, _> = controller
        .assets
        .iter()
        .map(|asset| (asset.id.as_str(), asset))
        .collect();
    let mut supplied = BTreeMap::new();
    let mut total_bytes = 0usize;
    let mut total_pixels = 0usize;
    for (index, image) in attachment.images.iter().enumerate() {
        let path = format!("images[{index}]");
        if !declared.contains_key(image.asset_id.as_str()) {
            return invalid(&path, "asset ID is not declared by the manifest");
        }
        if supplied.contains_key(image.asset_id.as_str()) {
            return invalid(&path, "duplicate asset ID");
        }
        let data = decode_base64(&image.png_base64, &path)?;
        total_bytes = total_bytes
            .checked_add(data.len())
            .ok_or_else(|| invalid_error("images", "combined image bytes exceed the limit"))?;
        if total_bytes > MAXIMUM_GAME_CONTROLLER_TOTAL_IMAGE_BYTES {
            return invalid("images", "combined image bytes exceed the limit");
        }
        let pixels = validate_png(&data, &path)?;
        total_pixels += pixels;
        if total_pixels > MAXIMUM_GAME_CONTROLLER_TOTAL_IMAGE_PIXELS {
            return invalid("images", "combined decoded image pixels exceed the limit");
        }
        supplied.insert(image.asset_id.as_str(), data);
    }
    if supplied.len() != declared.len() {
        return invalid("images", "every declared asset requires exactly one PNG");
    }
    let mut assets = Vec::with_capacity(supplied.len());
    let mut mappings = Vec::with_capacity(supplied.len());
    for (asset_id, data) in supplied {
        let native_id = native_asset_id(&controller.manifest.id, asset_id);
        let sha256 = hash(&data);
        let name: String = declared[asset_id]
            .alt
            .trim()
            .graphemes(true)
            .take(64)
            .collect();
        let background = controller.visual_attachments.iter().any(|attachment| {
            let visual = &attachment.visual;
            visual.background_asset_id.as_deref() == Some(asset_id)
                || visual.state_asset_ids.as_ref().is_some_and(|states| {
                    [&states.pressed, &states.active, &states.disabled]
                        .iter()
                        .any(|id| id.as_deref() == Some(asset_id))
                })
        });
        assets.push(json!({
            "id":native_id,"name":name,"fileName":format!("{native_id}.png"),
            "contentType":"image/png","data":STANDARD.encode(&data),"byteCount":data.len(),
            "hash":sha256,"role":if background { "background" } else { "icon" },
        }));
        mappings.push(GameControllerAssetMapping {
            asset_id: asset_id.to_owned(),
            native_asset_id: native_id,
            sha256,
            byte_count: data.len(),
        });
    }
    let summary = GameControllerAssetAttachmentSummary {
        profile_id: id.hyphenated().to_string(),
        manifest_id: controller.manifest.id.clone(),
        descriptor_digest: controller.descriptor_digest.clone(),
        asset_mappings: mappings,
        attached_control_count: controller.visual_attachments.len(),
        updated_variant_count: 0,
    };
    Ok(PreparedAttachment {
        controller,
        assets,
        summary,
    })
}

fn decode_base64(encoded: &str, path: &str) -> AttachmentResult<Vec<u8>> {
    if encoded.len() > MAXIMUM_GAME_CONTROLLER_IMAGE_BYTES.div_ceil(3) * 4 {
        return invalid(path, "PNG exceeds the native per-image byte limit");
    }
    let data = STANDARD
        .decode(encoded)
        .map_err(|_| invalid_error(path, "PNG must use canonical padded Base64"))?;
    if data.is_empty() || data.len() > MAXIMUM_GAME_CONTROLLER_IMAGE_BYTES {
        return invalid(
            path,
            "PNG must be nonempty and within the native per-image byte limit",
        );
    }
    if STANDARD.encode(&data) != encoded {
        return invalid(path, "PNG must use canonical padded Base64");
    }
    Ok(data)
}

fn validate_png(data: &[u8], path: &str) -> AttachmentResult<usize> {
    // Parse every chunk boundary before decoding; reject APNG, trailing bytes, and
    // truncation even if a decoder can display an initial frame successfully.
    if !data.starts_with(b"\x89PNG\r\n\x1a\n") {
        return invalid(path, "asset must be a PNG image");
    }
    let mut offset = 8usize;
    let mut ended = false;
    while offset < data.len() {
        let header = data
            .get(offset..offset.saturating_add(8))
            .ok_or_else(|| invalid_error(path, "PNG has a truncated chunk"))?;
        let length =
            u32::from_be_bytes(header[..4].try_into().expect("four-byte chunk length")) as usize;
        let kind = &header[4..8];
        if [b"acTL", b"fcTL", b"fdAT"]
            .iter()
            .any(|animated| kind == *animated)
        {
            return invalid(path, "animated PNG images are not supported");
        }
        let chunk_start = offset + 4;
        offset = offset
            .checked_add(12)
            .and_then(|offset| offset.checked_add(length))
            .ok_or_else(|| invalid_error(path, "PNG has an invalid chunk length"))?;
        if offset > data.len() {
            return invalid(path, "PNG has a truncated chunk");
        }
        let stored_crc =
            u32::from_be_bytes(data[offset - 4..offset].try_into().expect("four-byte CRC"));
        if crc32(&data[chunk_start..offset - 4]) != stored_crc {
            return invalid(path, "PNG chunk CRC is invalid");
        }
        if kind == b"IEND" {
            if length != 0 || offset != data.len() {
                return invalid(path, "PNG has invalid trailing content");
            }
            ended = true;
            break;
        }
    }
    if !ended {
        return invalid(path, "PNG must contain an end chunk");
    }
    let mut decoder = png::Decoder::new(Cursor::new(data));
    decoder.set_limits(png::Limits {
        bytes: MAXIMUM_DECODED_IMAGE_BYTES,
    });
    decoder.set_ignore_text_chunk(true);
    let mut reader = decoder
        .read_info()
        .map_err(|_| invalid_error(path, "PNG decoding failed"))?;
    let info = reader.info();
    if info.width == 0
        || info.height == 0
        || info.width > MAXIMUM_GAME_CONTROLLER_IMAGE_DIMENSION
        || info.height > MAXIMUM_GAME_CONTROLLER_IMAGE_DIMENSION
    {
        return invalid(path, "PNG dimensions must be between 1 and 2048 pixels");
    }
    let pixels = info.width as usize * info.height as usize;
    let buffer_size = reader.output_buffer_size();
    if buffer_size > MAXIMUM_DECODED_IMAGE_BYTES {
        return invalid(path, "decoded PNG exceeds the memory limit");
    }
    let mut buffer = vec![0; buffer_size];
    reader
        .next_frame(&mut buffer)
        .map_err(|_| invalid_error(path, "PNG decoding failed"))?;
    reader
        .finish()
        .map_err(|_| invalid_error(path, "PNG decoding failed"))?;
    Ok(pixels)
}

fn verify_binding_maps(
    actual: &ConfigurationDocument,
    expected: &ConfigurationDocument,
    actual_id: &str,
    expected_id: &str,
) -> AttachmentResult<()> {
    let keys: Vec<_> = actual
        .profile_key_bindings
        .iter()
        .filter(|(id, _)| id.eq_ignore_ascii_case(actual_id))
        .collect();
    let outputs: Vec<_> = actual
        .profile_output_bindings
        .iter()
        .filter(|(id, _)| id.eq_ignore_ascii_case(actual_id))
        .collect();
    if keys.len() != 1
        || outputs.len() != 1
        || Some(keys[0].1) != expected.profile_key_bindings.get(expected_id)
        || Some(outputs[0].1) != expected.profile_output_bindings.get(expected_id)
    {
        return invalid(
            "profileID",
            "profile bindings differ from the compiled controller",
        );
    }
    Ok(())
}

fn apply_variant(
    customization: &mut Value,
    expected: &[Value],
    prepared: &PreparedAttachment,
    path: &str,
) -> AttachmentResult<()> {
    let object = customization
        .as_object_mut()
        .ok_or_else(|| invalid_error(path, "customization must be an object"))?;
    let elements = object
        .get_mut("elements")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| invalid_error(path, "compiled controller elements are missing"))?;
    let mut seen = BTreeSet::new();
    for element in elements.iter() {
        let id = element
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid_error(path, "element ID is missing"))?;
        if !seen.insert(id.to_ascii_lowercase()) {
            return invalid(path, "duplicate element ID");
        }
    }
    let mut mirror_visuals = Vec::new();
    for source in expected {
        let id = source["id"].as_str().expect("compiled element ID");
        let element = elements
            .iter_mut()
            .find(|element| {
                element["id"]
                    .as_str()
                    .is_some_and(|value| value.eq_ignore_ascii_case(id))
            })
            .ok_or_else(|| invalid_error(path, "compiled controller element is missing"))?;
        verify_element(element, source, path)?;
        if let Some(attachment) = prepared
            .controller
            .visual_attachments
            .iter()
            .find(|attachment| attachment.element_id.eq_ignore_ascii_case(id))
        {
            let layout = element
                .get_mut("layout")
                .and_then(Value::as_object_mut)
                .ok_or_else(|| invalid_error(path, "element layout must be an object"))?;
            apply_visual(
                layout,
                &attachment.visual,
                &prepared.controller.manifest.id,
                path,
            )?;
            mirror_visuals.push((source.clone(), attachment.visual.clone()));
        }
    }
    for (source, visual) in mirror_visuals {
        let mapping = prepared
            .controller
            .control_mappings
            .iter()
            .find(|mapping| source["id"].as_str() == Some(mapping.element_id.as_str()))
            .expect("compiled controller mapping");
        mirror_layout(
            object,
            &source,
            &visual,
            &prepared.controller.manifest.id,
            &mapping.game_button,
            path,
        )?;
    }
    apply_assets(object, &prepared.assets, path)?;
    Ok(())
}

fn verify_element(actual: &Value, expected: &Value, path: &str) -> AttachmentResult<()> {
    for field in ["kind", "builtInButton", "legacySlot"] {
        if actual.get(field).filter(|value| !value.is_null())
            != expected.get(field).filter(|value| !value.is_null())
        {
            return invalid(
                path,
                "element control identity differs from the compiled controller",
            );
        }
    }
    let empty = json!({});
    let raw = actual
        .get("output")
        .filter(|value| !value.is_null())
        .unwrap_or(&empty);
    if raw.as_object().is_none_or(|object| {
        object
            .keys()
            .any(|key| !matches!(key.as_str(), "keyboard" | "gamepadButtons"))
    }) {
        return invalid(path, "element output contains unsupported fields");
    }
    let actual_output: OutputBinding = serde_json::from_value(raw.clone())
        .map_err(|_| invalid_error(path, "element output is invalid"))?;
    let expected_output: OutputBinding =
        serde_json::from_value(expected.get("output").cloned().unwrap_or_else(|| json!({})))
            .map_err(|_| invalid_error(path, "compiled element output is invalid"))?;
    if actual_output != expected_output {
        return invalid(path, "element output differs from the compiled controller");
    }
    if raw
        .get("keyboard")
        .filter(|value| !value.is_null())
        .is_some_and(|keyboard| {
            keyboard.as_object().is_none_or(|object| {
                object.keys().any(|key| {
                    !matches!(
                        key.as_str(),
                        "keyCode" | "modifiers" | "modifiersRawValue" | "sequence"
                    )
                })
            })
        })
    {
        return invalid(path, "element keyboard output contains unsupported fields");
    }
    if actual.get("partOutputs").is_some_and(|parts| {
        !(parts.is_null()
            || parts.as_array().is_some_and(Vec::is_empty)
            || parts.as_object().is_some_and(Map::is_empty))
    }) {
        return invalid(
            path,
            "element part outputs differ from the compiled controller",
        );
    }
    Ok(())
}

fn apply_visual(
    layout: &mut Map<String, Value>,
    visual: &GameControllerVisual,
    manifest_id: &str,
    path: &str,
) -> AttachmentResult<()> {
    if let Some(id) = &visual.icon_asset_id {
        let icon = json!({"source":"asset","value":native_asset_id(manifest_id,id),"placement":"top","scale":1,"renderingMode":"original"});
        layout.insert("icon".to_owned(), icon);
    }
    if let Some(id) = &visual.background_asset_id {
        layout.insert(
            "fillStyle".to_owned(),
            image_fill(&native_asset_id(manifest_id, id)),
        );
    }
    let style = layout
        .entry("visualStyle")
        .or_insert_with(|| json!({"normal":{}}));
    if style.is_null() {
        *style = json!({"normal":{}});
    }
    let style = style
        .as_object_mut()
        .ok_or_else(|| invalid_error(path, "visual style must be an object"))?;
    let normal = style.entry("normal").or_insert_with(|| json!({}));
    if !normal.is_object() {
        return invalid(path, "normal style must be an object");
    }
    if let Some(id) = &visual.background_asset_id {
        normal["fillStyle"] = image_fill(&native_asset_id(manifest_id, id));
    }
    if let Some(id) = &visual.icon_asset_id {
        style.insert("icon".to_owned(), json!({"source":"asset","value":native_asset_id(manifest_id,id),"placement":"top","scale":1,"renderingMode":"original"}));
    }
    if let Some(states) = &visual.state_asset_ids {
        for (state, id) in [
            ("pressed", &states.pressed),
            ("active", &states.active),
            ("disabled", &states.disabled),
        ] {
            if let Some(id) = id {
                let value = style.entry(state).or_insert_with(|| json!({}));
                if value.is_null() {
                    *value = json!({});
                }
                if !value.is_object() {
                    return invalid(path, "state style must be an object");
                }
                value["fillStyle"] = image_fill(&native_asset_id(manifest_id, id));
            }
        }
    }
    Ok(())
}

fn image_fill(id: &str) -> Value {
    json!({"kind":"image","image":{"assetID":id,"contentMode":"fill","opacity":1,
        "exposure":0,"contrast":0,"saturation":0,"temperature":0,"tint":0,"highlights":0,"shadows":0}})
}

fn mirror_layout(
    customization: &mut Map<String, Value>,
    source: &Value,
    visual: &GameControllerVisual,
    manifest_id: &str,
    game_button: &str,
    path: &str,
) -> AttachmentResult<()> {
    if let Some(button) = source.get("builtInButton").and_then(Value::as_str) {
        let pairs = customization
            .get_mut("buttonCustomizations")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| invalid_error(path, "native button customization mirror is missing"))?;
        if pairs.len() % 2 != 0 {
            return invalid(path, "native button customization mirror is invalid");
        }
        let matches: Vec<_> = (0..pairs.len())
            .step_by(2)
            .filter(|index| pairs[*index].as_str() == Some(button))
            .collect();
        if matches.len() != 1 {
            return invalid(
                path,
                "native button customization mirror is missing or duplicated",
            );
        }
        let layout = pairs[matches[0] + 1].as_object_mut().ok_or_else(|| {
            invalid_error(path, "native button customization mirror layout is invalid")
        })?;
        apply_visual(layout, visual, manifest_id, path)?;
    } else {
        let id = source["id"].as_str().expect("compiled element ID");
        let controls = customization
            .get_mut("customButtons")
            .and_then(Value::as_array_mut)
            .ok_or_else(|| invalid_error(path, "native custom control mirror is missing"))?;
        let matches: Vec<_> = controls
            .iter()
            .enumerate()
            .filter(|(_, control)| {
                control["id"]
                    .as_str()
                    .is_some_and(|value| value.eq_ignore_ascii_case(id))
            })
            .map(|(index, _)| index)
            .collect();
        if matches.len() != 1 {
            return invalid(
                path,
                "native custom control mirror is missing or duplicated",
            );
        }
        let control = &mut controls[matches[0]];
        if control.get("controlKind") != source.get("kind") {
            return invalid(path, "native custom control mirror kind differs");
        }
        if control.get("mappedButton").and_then(Value::as_str) != Some(game_button) {
            return invalid(path, "native custom control mirror binding differs");
        }
        let layout = control
            .get_mut("layout")
            .and_then(Value::as_object_mut)
            .ok_or_else(|| invalid_error(path, "native custom control mirror layout is invalid"))?;
        apply_visual(layout, visual, manifest_id, path)?;
    }
    Ok(())
}

fn apply_assets(
    customization: &mut Map<String, Value>,
    incoming: &[Value],
    path: &str,
) -> AttachmentResult<()> {
    let library = customization
        .entry("assetLibrary")
        .or_insert_with(|| json!({"assets":[]}));
    if library.is_null() {
        *library = json!({"assets":[]});
    }
    let assets = library
        .get_mut("assets")
        .and_then(Value::as_array_mut)
        .ok_or_else(|| invalid_error(path, "asset library must contain an assets array"))?;
    let mut ids = BTreeSet::new();
    for asset in assets.iter() {
        let id = asset
            .get("id")
            .and_then(Value::as_str)
            .ok_or_else(|| invalid_error(path, "asset library ID is missing"))?;
        if !ids.insert(id) {
            return invalid(path, "asset library has duplicate IDs");
        }
    }
    for asset in incoming {
        if let Some(index) = assets
            .iter()
            .position(|existing| existing.get("id") == asset.get("id"))
        {
            let old = &assets[index];
            if old.get("contentType").and_then(Value::as_str) != Some("image/png")
                || old.get("fileName") != asset.get("fileName")
            {
                return invalid(path, "managed asset ID collides with an unrelated resource");
            }
            let encoded = old
                .get("data")
                .and_then(Value::as_str)
                .ok_or_else(|| invalid_error(path, "managed asset is missing image bytes"))?;
            let data = decode_base64(encoded, path)?;
            if old.get("hash").and_then(Value::as_str) != Some(hash(&data).as_str())
                || old.get("byteCount").and_then(Value::as_u64) != Some(data.len() as u64)
            {
                return invalid(path, "managed asset integrity is invalid");
            }
            validate_png(&data, path)?;
            assets[index] = asset.clone();
        } else {
            assets.push(asset.clone());
        }
    }
    Ok(())
}

fn native_asset_id(manifest_id: &str, asset_id: &str) -> String {
    let name = format!("{manifest_id}:{asset_id}");
    format!(
        "gc-{}",
        Uuid::new_v5(&ASSET_NAMESPACE, name.as_bytes()).hyphenated()
    )
}

fn hash(data: &[u8]) -> String {
    Sha256::digest(data)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn crc32(bytes: &[u8]) -> u32 {
    const TABLE: [u32; 256] = {
        let mut table = [0; 256];
        let mut index = 0;
        while index < 256 {
            let mut value = index as u32;
            let mut bit = 0;
            while bit < 8 {
                value = (value >> 1) ^ (0xedb8_8320 & (0u32.wrapping_sub(value & 1)));
                bit += 1;
            }
            table[index] = value;
            index += 1;
        }
        table
    };
    let mut value = !0u32;
    for byte in bytes {
        value = (value >> 8) ^ TABLE[((value as u8) ^ byte) as usize];
    }
    !value
}

fn invalid_error(path: &str, message: &'static str) -> GameControllerAssetAttachmentError {
    GameControllerAssetAttachmentError::Invalid {
        path: path.to_owned(),
        message,
    }
}

fn invalid<T>(path: &str, message: &'static str) -> AttachmentResult<T> {
    Err(invalid_error(path, message))
}

#[cfg(test)]
mod tests {
    use super::*;

    const TINY_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==";

    fn manifest() -> Value {
        json!({
            "schemaVersion":1,"id":"asset-controller","name":"Asset Controller",
            "game":{"id":"game","name":"Game"},"outputMode":"keyboard",
            "actions":[{"id":"cast-q","label":"Q","output":{"key":"Q"}},{"id":"pointer","label":"Aim"}],
            "controls":[
                {"id":"cast-q-button","actionID":"cast-q","kind":"button","role":"primary",
                 "visual":{"iconAssetID":"q-icon","backgroundAssetID":"q-background",
                           "stateAssetIDs":{"pressed":"q-pressed","active":"q-active","disabled":"q-disabled"}}},
                {"id":"pointer-pad","actionID":"pointer","kind":"trackpad","role":"movement",
                 "visual":{"backgroundAssetID":"q-background"}}
            ],
            "assets":[{"id":"q-icon","alt":"Ability Q"},{"id":"q-background","alt":"Q background"},
                      {"id":"q-pressed","alt":"Q pressed"},{"id":"q-active","alt":"Q active"},
                      {"id":"q-disabled","alt":"Q disabled"}]
        })
    }

    fn fixture() -> (ConfigurationDocument, GameControllerAssetAttachment) {
        let manifest = manifest();
        let manifest_json = manifest.to_string();
        let controller = plan_game_controller(manifest_json.as_bytes()).unwrap();
        let document = ProfileArtifact::decode_json(controller.artifact_json.as_bytes())
            .unwrap()
            .to_configuration_document()
            .unwrap();
        let images = manifest["assets"]
            .as_array()
            .unwrap()
            .iter()
            .map(|asset| GameControllerAssetImage {
                asset_id: asset["id"].as_str().unwrap().to_owned(),
                png_base64: TINY_PNG.to_owned(),
            })
            .collect();
        let attachment = GameControllerAssetAttachment {
            manifest_json,
            profile_id: controller.profile_id,
            images,
        };
        (document, attachment)
    }

    fn rgba_png(width: u32, height: u32) -> Vec<u8> {
        let mut encoded = Vec::new();
        let mut encoder = png::Encoder::new(&mut encoded, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder.write_header().unwrap();
        writer
            .write_image_data(&vec![127; width as usize * height as usize * 4])
            .unwrap();
        drop(writer);
        encoded
    }

    fn chunk(kind: &[u8; 4], data: &[u8]) -> Vec<u8> {
        let mut encoded = (data.len() as u32).to_be_bytes().to_vec();
        encoded.extend_from_slice(kind);
        encoded.extend_from_slice(data);
        let crc = crc32(&encoded[4..]);
        encoded.extend_from_slice(&crc.to_be_bytes());
        encoded
    }

    fn assert_invalid(result: AttachmentResult<GameControllerAssetAttachmentPlan>, message: &str) {
        let error = result.unwrap_err();
        assert!(error.to_string().contains(message), "{error}");
    }

    #[test]
    fn attachments_have_complete_native_shapes_and_preserve_nonvisual_state() {
        let (mut document, attachment) = fixture();
        let customization = &mut document.profiles[0]["customization"];
        let q = customization["elements"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|value| value["kind"] == "button")
            .unwrap();
        q["layout"]["centerX"] = json!(0.31);
        q["layout"]["visualStyle"] =
            json!({"normal":{"strokeWidth":3},"pressed":{"opacity":0.8},"hapticStyle":"heavy"});
        let pairs = customization["buttonCustomizations"]
            .as_array_mut()
            .unwrap();
        let index = pairs.iter().position(|value| value == "jump").unwrap() + 1;
        pairs[index]["centerX"] = json!(0.62);
        pairs[index]["visualStyle"] =
            json!({"normal":{"strokeWidth":5},"disabled":{"opacity":0.2}});
        customization["assetLibrary"] = json!({"assets":[{"id":"other","name":"Other","contentType":"image/png","data":TINY_PNG,"byteCount":70,"role":"reference"}]});
        customization["styleLibrary"] = json!({"styles":[{"id":"custom","future":true}]});
        document.profiles[0]["skinReference"] = json!({"identifier":"preserved","version":"1"});
        let plan = attach_game_controller_assets(&document, &attachment).unwrap();
        assert_eq!(plan.summary.attached_control_count, 2);
        assert_eq!(plan.summary.updated_variant_count, 1);
        assert_eq!(
            plan.document.profile_key_bindings,
            document.profile_key_bindings
        );
        assert_eq!(
            plan.document.profile_output_bindings,
            document.profile_output_bindings
        );
        assert_eq!(plan.document.key_bindings, document.key_bindings);
        assert_eq!(plan.document.output_bindings, document.output_bindings);
        assert_eq!(plan.document.active_profile_id, document.active_profile_id);
        assert_eq!(
            plan.document.default_profile_id,
            document.default_profile_id
        );
        assert_eq!(
            plan.document.profiles[0]["skinReference"],
            document.profiles[0]["skinReference"]
        );
        let customization = &plan.document.profiles[0]["customization"];
        assert_eq!(
            customization["styleLibrary"],
            document.profiles[0]["customization"]["styleLibrary"]
        );
        assert_eq!(
            customization["assetLibrary"]["assets"][0],
            document.profiles[0]["customization"]["assetLibrary"]["assets"][0]
        );
        let q = customization["elements"]
            .as_array()
            .unwrap()
            .iter()
            .find(|value| value["kind"] == "button")
            .unwrap();
        assert_eq!(q["layout"]["centerX"], 0.31);
        assert_eq!(q["layout"]["visualStyle"]["normal"]["strokeWidth"], 3);
        assert_eq!(q["layout"]["visualStyle"]["pressed"]["opacity"], 0.8);
        assert_eq!(q["layout"]["visualStyle"]["hapticStyle"], "heavy");
        assert_eq!(q["layout"]["icon"]["placement"], "top");
        assert_eq!(q["layout"]["icon"], q["layout"]["visualStyle"]["icon"]);
        assert_eq!(
            q["layout"]["fillStyle"],
            q["layout"]["visualStyle"]["normal"]["fillStyle"]
        );
        for state in ["normal", "pressed", "active", "disabled"] {
            let image = &q["layout"]["visualStyle"][state]["fillStyle"]["image"];
            assert!(image["assetID"].as_str().unwrap().starts_with("gc-"));
            assert_eq!(image["contentMode"], "fill");
            assert_eq!(image["opacity"], 1);
            for field in [
                "exposure",
                "contrast",
                "saturation",
                "temperature",
                "tint",
                "highlights",
                "shadows",
            ] {
                assert_eq!(image[field], 0);
            }
            assert!(image.get("data").is_none());
        }
        let pairs = customization["buttonCustomizations"].as_array().unwrap();
        let mirror = &pairs[index];
        assert_eq!(mirror["centerX"], 0.62);
        assert_eq!(mirror["visualStyle"]["normal"]["strokeWidth"], 5);
        assert_eq!(mirror["visualStyle"]["disabled"]["opacity"], 0.2);
        assert_eq!(mirror["icon"], q["layout"]["icon"]);
        let pad = customization["customButtons"]
            .as_array()
            .unwrap()
            .iter()
            .find(|control| control["controlKind"] == "trackpad")
            .unwrap();
        assert!(pad["layout"]["fillStyle"]["image"]["assetID"].is_string());
        assert!(
            ProfileArtifact::from_configuration(
                &plan.document,
                crate::ProfileArtifactSelection::All,
                0
            )
            .is_err(),
            "local image bytes must remain forbidden in portable artifacts"
        );
    }

    #[test]
    fn repeated_attachment_is_byte_identical_and_image_order_does_not_matter() {
        let (document, mut attachment) = fixture();
        let first = attach_game_controller_assets(&document, &attachment).unwrap();
        attachment.images.reverse();
        let reordered = attach_game_controller_assets(&document, &attachment).unwrap();
        let repeated = attach_game_controller_assets(&first.document, &attachment).unwrap();
        assert_eq!(first, reordered);
        assert_eq!(first, repeated);
        assert_eq!(
            serde_json::to_vec(&first.document).unwrap(),
            serde_json::to_vec(&repeated.document).unwrap()
        );
    }

    #[test]
    fn omitted_appearances_and_unrelated_managed_resources_are_preserved() {
        let (document, mut attachment) = fixture();
        let first = attach_game_controller_assets(&document, &attachment).unwrap();
        let mut manifest = manifest();
        manifest["controls"][0]["visual"] = json!({"iconAssetID":"q-icon"});
        manifest["controls"][1]
            .as_object_mut()
            .unwrap()
            .remove("visual");
        manifest["assets"] = json!([{"id":"q-icon","alt":"é".repeat(70)}]);
        attachment.manifest_json = manifest.to_string();
        attachment.images.retain(|image| image.asset_id == "q-icon");
        let updated = attach_game_controller_assets(&first.document, &attachment).unwrap();
        assert_eq!(updated.summary.attached_control_count, 1);
        let first_q = &first.document.profiles[0]["customization"]["elements"][1]["layout"];
        let updated_q = &updated.document.profiles[0]["customization"]["elements"][1]["layout"];
        assert_eq!(updated_q["fillStyle"], first_q["fillStyle"]);
        for state in ["normal", "pressed", "active", "disabled"] {
            assert_eq!(
                updated_q["visualStyle"][state],
                first_q["visualStyle"][state]
            );
        }
        let assets = updated.document.profiles[0]["customization"]["assetLibrary"]["assets"]
            .as_array()
            .unwrap();
        assert_eq!(assets.len(), 5);
        let native_id = &updated.summary.asset_mappings[0].native_asset_id;
        let asset = assets
            .iter()
            .find(|asset| asset["id"].as_str() == Some(native_id))
            .unwrap();
        assert_eq!(asset["name"].as_str().unwrap().graphemes(true).count(), 64);
        assert_eq!(
            updated.document.profiles[0]["customization"]["customButtons"],
            first.document.profiles[0]["customization"]["customButtons"]
        );
    }

    #[test]
    fn existing_orientation_variants_are_all_updated_and_missing_control_is_atomic() {
        let (mut document, attachment) = fixture();
        let primary = document.profiles[0]["customization"].clone();
        document.profiles[0]["portraitCustomization"] = primary.clone();
        document.profiles[0]["landscapeCustomization"] = primary;
        document.profiles[0]["portraitCustomization"]["deviceCanvas"] =
            json!({"frameID":"iphone-17-pro-portrait"});
        let applied = attach_game_controller_assets(&document, &attachment).unwrap();
        assert_eq!(applied.summary.updated_variant_count, 3);
        for variant in [
            "customization",
            "portraitCustomization",
            "landscapeCustomization",
        ] {
            assert_eq!(
                applied.document.profiles[0][variant]["assetLibrary"]["assets"]
                    .as_array()
                    .unwrap()
                    .len(),
                5
            );
        }
        assert_eq!(
            applied.document.profiles[0]["portraitCustomization"]["deviceCanvas"],
            document.profiles[0]["portraitCustomization"]["deviceCanvas"]
        );
        document.profiles[0]["portraitCustomization"]["elements"]
            .as_array_mut()
            .unwrap()
            .remove(0);
        let before = document.clone();
        assert_invalid(
            attach_game_controller_assets(&document, &attachment),
            "element is missing",
        );
        assert_eq!(before, document);
    }

    #[test]
    fn import_copy_ids_and_geometry_edits_are_supported() {
        let (mut document, mut attachment) = fixture();
        let copied = "aaaaaaaa-bbbb-5ccc-8ddd-eeeeeeeeeeee".to_owned();
        let keys = document
            .profile_key_bindings
            .remove(&attachment.profile_id)
            .unwrap();
        let outputs = document
            .profile_output_bindings
            .remove(&attachment.profile_id)
            .unwrap();
        document.profile_key_bindings.insert(copied.clone(), keys);
        document
            .profile_output_bindings
            .insert(copied.clone(), outputs);
        document.active_profile_id = copied.clone();
        document.default_profile_id = copied.clone();
        document.profiles[0]["id"] = json!(copied);
        document.profiles[0]["name"] = json!("My edited copy");
        document.profiles[0]["updatedAt"] = json!(123);
        document.profiles[0]["customization"]["elements"][0]["layout"]["widthScale"] = json!(1.8);
        attachment.profile_id = copied.to_uppercase();
        let result = attach_game_controller_assets(&document, &attachment).unwrap();
        assert_eq!(result.document.profiles[0]["name"], "My edited copy");
        assert_eq!(result.document.profiles[0]["updatedAt"], 123);
        assert_eq!(
            result.document.profiles[0]["customization"]["elements"][0]["layout"]["widthScale"],
            1.8
        );
        assert_eq!(result.summary.profile_id, copied);
    }

    #[test]
    fn changed_mode_keys_outputs_kinds_and_mirror_bindings_are_rejected() {
        let (document, attachment) = fixture();
        let mut changed = document.clone();
        changed.profiles[0]["outputMode"] = json!("custom");
        assert_invalid(
            attach_game_controller_assets(&changed, &attachment),
            "output mode differs",
        );
        let mut changed = document.clone();
        changed
            .profile_key_bindings
            .get_mut(&attachment.profile_id)
            .unwrap()
            .insert_raw("jump", crate::KeyBinding::new(0, 0));
        assert_invalid(
            attach_game_controller_assets(&changed, &attachment),
            "bindings differ",
        );
        let mut changed = document.clone();
        changed
            .profile_output_bindings
            .get_mut(&attachment.profile_id)
            .unwrap()
            .insert_raw("jump", OutputBinding::default());
        assert_invalid(
            attach_game_controller_assets(&changed, &attachment),
            "bindings differ",
        );
        let mut changed = document.clone();
        changed.profiles[0]["customization"]["elements"][0]["output"] =
            json!({"keyboard":{"keyCode":0,"modifiersRawValue":0},"gamepadButtons":[]});
        assert_invalid(
            attach_game_controller_assets(&changed, &attachment),
            "output differs",
        );
        let mut changed = document.clone();
        changed.profiles[0]["customization"]["elements"][0]["kind"] = json!("button");
        assert_invalid(
            attach_game_controller_assets(&changed, &attachment),
            "control identity differs",
        );
        let mut changed = document.clone();
        changed.profiles[0]["customization"]["customButtons"][0]["mappedButton"] = json!("custom2");
        assert_invalid(
            attach_game_controller_assets(&changed, &attachment),
            "mirror binding differs",
        );
    }

    #[test]
    fn requires_exact_asset_set_and_strict_contract_fields() {
        let (document, attachment) = fixture();
        let mut changed = attachment.clone();
        changed.images.pop();
        assert_invalid(
            attach_game_controller_assets(&document, &changed),
            "exactly one PNG",
        );
        let mut changed = attachment.clone();
        changed.images[0].asset_id = "undeclared".to_owned();
        assert_invalid(
            attach_game_controller_assets(&document, &changed),
            "not declared",
        );
        let mut changed = attachment.clone();
        changed.images.push(changed.images[0].clone());
        assert_invalid(
            attach_game_controller_assets(&document, &changed),
            "duplicate asset ID",
        );
        let mut changed = attachment.clone();
        let mut manifest = manifest();
        manifest["assets"] = json!([]);
        for control in manifest["controls"].as_array_mut().unwrap() {
            control.as_object_mut().unwrap().remove("visual");
        }
        changed.manifest_json = manifest.to_string();
        changed.images.clear();
        assert_invalid(
            attach_game_controller_assets(&document, &changed),
            "at least one",
        );
        let mut raw = serde_json::to_value(&attachment).unwrap();
        raw["filePath"] = json!("image.png");
        assert!(serde_json::from_value::<GameControllerAssetAttachment>(raw).is_err());
        let mut raw = serde_json::to_value(&attachment.images[0]).unwrap();
        raw["url"] = json!("https://example.test/image.png");
        assert!(serde_json::from_value::<GameControllerAssetImage>(raw).is_err());
    }

    #[test]
    fn base64_png_corruption_animations_trailing_content_and_dimensions_are_rejected() {
        let (document, attachment) = fixture();
        for encoded in [
            "not base64".to_owned(),
            TINY_PNG.trim_end_matches('=').to_owned(),
            format!("{TINY_PNG}\n"),
        ] {
            let mut changed = attachment.clone();
            changed.images[0].png_base64 = encoded;
            assert!(attach_game_controller_assets(&document, &changed).is_err());
        }
        let original = STANDARD.decode(TINY_PNG).unwrap();
        let mut crc = original.clone();
        *crc.last_mut().unwrap() ^= 1;
        let mut truncated = original.clone();
        truncated.pop();
        let mut trailing = original.clone();
        trailing.push(0);
        let mut animated = original.clone();
        animated.splice(33..33, chunk(b"acTL", &[0, 0, 0, 1, 0, 0, 0, 0]));
        let mut ancillary_crc = original.clone();
        let mut ancillary = chunk(b"vpAg", &[1, 2, 3]);
        *ancillary.last_mut().unwrap() ^= 1;
        ancillary_crc.splice(33..33, ancillary);
        let mut invalid_stream = original.clone();
        invalid_stream[41] = 0;
        let idat_crc = crc32(&invalid_stream[37..54]);
        invalid_stream[54..58].copy_from_slice(&idat_crc.to_be_bytes());
        for data in [
            b"JPEG".to_vec(),
            crc,
            truncated,
            trailing,
            animated,
            ancillary_crc,
            invalid_stream,
            rgba_png(2049, 1),
        ] {
            let mut changed = attachment.clone();
            changed.images[0].png_base64 = STANDARD.encode(data);
            assert!(attach_game_controller_assets(&document, &changed).is_err());
        }
        let valid = rgba_png(2048, 1);
        assert_eq!(validate_png(&valid, "image").unwrap(), 2048);
    }

    #[test]
    fn encoded_bytes_batch_pixels_and_candidate_configuration_have_bounded_sizes() {
        assert!(decode_base64(
            &STANDARD.encode(vec![0; MAXIMUM_GAME_CONTROLLER_IMAGE_BYTES]),
            "image"
        )
        .is_ok());
        assert!(decode_base64(
            &STANDARD.encode(vec![0; MAXIMUM_GAME_CONTROLLER_IMAGE_BYTES + 1]),
            "image"
        )
        .is_err());
        let (document, mut attachment) = fixture();
        let large = STANDARD.encode(rgba_png(2048, 2048));
        for image in &mut attachment.images {
            image.png_base64 = large.clone();
        }
        assert_invalid(
            attach_game_controller_assets(&document, &attachment),
            "combined decoded image pixels",
        );
        let (document, mut attachment) = fixture();
        let mut large_raw = STANDARD.decode(TINY_PNG).unwrap();
        large_raw.splice(33..33, chunk(b"vpAg", &vec![0; 900_000]));
        let encoded = STANDARD.encode(large_raw);
        for image in &mut attachment.images {
            image.png_base64 = encoded.clone();
        }
        assert_invalid(
            attach_game_controller_assets(&document, &attachment),
            "combined image bytes",
        );
        let (mut document, attachment) = fixture();
        let baseline_bytes = serde_json::to_vec(&document).unwrap().len();
        document.profiles[0]["future"] =
            json!("x".repeat(crate::MAXIMUM_CONFIGURATION_DOCUMENT_BYTES - baseline_bytes - 1000));
        document.validate().unwrap();
        assert!(attach_game_controller_assets(&document, &attachment).is_err());
    }

    #[test]
    fn managed_ids_update_valid_existing_resources_and_reject_collision_or_corruption() {
        let (document, mut attachment) = fixture();
        let first = attach_game_controller_assets(&document, &attachment).unwrap();
        let first_id = first.summary.asset_mappings[0].native_asset_id.clone();
        attachment
            .images
            .iter_mut()
            .find(|image| image.asset_id == first.summary.asset_mappings[0].asset_id)
            .unwrap()
            .png_base64 = STANDARD.encode(rgba_png(1, 1));
        let updated = attach_game_controller_assets(&first.document, &attachment).unwrap();
        assert_eq!(updated.summary.asset_mappings[0].native_asset_id, first_id);
        assert_ne!(
            updated.summary.asset_mappings[0].sha256,
            first.summary.asset_mappings[0].sha256
        );
        assert_eq!(
            updated.document.profiles[0]["customization"]["assetLibrary"]["assets"]
                .as_array()
                .unwrap()
                .len(),
            5
        );
        let mut collision = document.clone();
        collision.profiles[0]["customization"]["assetLibrary"] = json!({"assets":[{"id":first_id,"name":"Unrelated","fileName":"other.png","contentType":"image/png","data":TINY_PNG}]});
        assert_invalid(
            attach_game_controller_assets(&collision, &attachment),
            "collides",
        );
        let mut invalid_hash = first.document.clone();
        invalid_hash.profiles[0]["customization"]["assetLibrary"]["assets"][0]["hash"] =
            json!("0".repeat(64));
        assert_invalid(
            attach_game_controller_assets(&invalid_hash, &attachment),
            "integrity is invalid",
        );
    }

    #[test]
    fn request_validation_is_payload_free_and_manifest_digest_is_cosmetic() {
        let (_, mut attachment) = fixture();
        let first = validate_game_controller_asset_attachment(&attachment).unwrap();
        assert_eq!(first.updated_variant_count, 0);
        let serialized = serde_json::to_string(&first).unwrap();
        assert!(!serialized.contains(TINY_PNG));
        assert_eq!(
            first
                .asset_mappings
                .iter()
                .map(|mapping| mapping.asset_id.as_str())
                .collect::<Vec<_>>(),
            vec![
                "q-active",
                "q-background",
                "q-disabled",
                "q-icon",
                "q-pressed"
            ]
        );
        attachment.images[0].png_base64 = STANDARD.encode(rgba_png(1, 1));
        let changed = validate_game_controller_asset_attachment(&attachment).unwrap();
        assert_eq!(changed.descriptor_digest, first.descriptor_digest);
        assert_ne!(changed.asset_mappings, first.asset_mappings);
        assert!(!format!("{attachment:?}").contains(TINY_PNG));
    }
}
