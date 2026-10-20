//! Package-independent owned paint preparation. Authority/interchange activation
//! remains gated until every retained peer supports the complete migration contract.
use crate::{ProfileResourceError, ProfileResourceTable, MAXIMUM_CONFIGURATION_DOCUMENT_BYTES};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::Arc;
use thumble_protocol::KeypadElementID;

const SURFACE: &[&str] = &[
    "backgroundLightColor",
    "backgroundDarkColor",
    "backgroundFillStyle",
    "backgroundLightFillStyle",
    "backgroundDarkFillStyle",
    "accentStyle",
    "showsButtonLabels",
];
const OWNERS: &[&str] = &[
    "artworkLayers",
    "controls",
    "topBar",
    "controlBar",
    "styleLibrary",
    "assetLibrary",
];
const CONTROL: &[&str] = &[
    "shape",
    "accentStyle",
    "fillColor",
    "lightFillColor",
    "darkFillColor",
    "fillStyle",
    "lightFillStyle",
    "darkFillStyle",
    "joystickKnobColor",
    "lightJoystickKnobColor",
    "darkJoystickKnobColor",
    "joystickVisualStyle",
    "styleID",
    "visualStyle",
    "icon",
    "hapticStyle",
    "hapticFeedback",
    "cornerRadius",
    "cornerRadii",
    "shadowStrength",
    "showsIntegratedLabel",
];
const BARS: &[&str] = &[
    "status",
    "profile_menu",
    "launch_target",
    "spacer",
    "edit_layout",
    "settings",
    "home",
    "connection",
];
const ACTIONS: &[&str] = &["base", "left-trigger", "right-trigger", "both-triggers"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileAppearanceError {
    InvalidBank,
    InvalidState,
    InvalidSnapshot,
    InvalidControl,
    InvalidCollection,
    MissingAsset(String),
    TooLarge,
    Resource(ProfileResourceError),
}
impl std::fmt::Display for ProfileAppearanceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "owned profile appearance needs recovery: {self:?}")
    }
}
impl std::error::Error for ProfileAppearanceError {}
impl From<ProfileResourceError> for ProfileAppearanceError {
    fn from(value: ProfileResourceError) -> Self {
        Self::Resource(value)
    }
}

#[derive(Debug, Clone)]
pub struct ProfileAppearanceBank {
    states: Arc<BTreeMap<(String, String), Value>>,
    resources: Option<ProfileResourceTable>,
}
impl ProfileAppearanceBank {
    pub fn from_profile(profile: &Value) -> Result<Option<Self>, ProfileAppearanceError> {
        budget(profile)?;
        let resources = ProfileResourceTable::from_profile(profile)?;
        let Some(raw) = field(profile, "appearanceBank") else {
            return Ok(None);
        };
        let object = raw.as_object().ok_or(ProfileAppearanceError::InvalidBank)?;
        if object
            .keys()
            .any(|k| !["schemaVersion", "variants"].contains(&k.as_str()))
            || raw["schemaVersion"].as_f64() != Some(1.0)
        {
            return Err(ProfileAppearanceError::InvalidBank);
        }
        let rows = raw["variants"]
            .as_array()
            .filter(|r| r.len() == 8)
            .ok_or(ProfileAppearanceError::InvalidBank)?;
        let mut states = BTreeMap::new();
        let mut control_ids = None;
        for row in rows {
            let scheme = row["colorScheme"]
                .as_str()
                .ok_or(ProfileAppearanceError::InvalidState)?;
            let action = row["actionSet"]
                .as_str()
                .ok_or(ProfileAppearanceError::InvalidState)?;
            state_key(scheme, action)?;
            let appearance = &row["appearance"];
            validate_snapshot(appearance, resources.as_ref())?;
            let ids: BTreeSet<_> = appearance["controls"]
                .as_object()
                .unwrap()
                .keys()
                .cloned()
                .collect();
            if control_ids.as_ref().is_some_and(|old| *old != ids) {
                return Err(ProfileAppearanceError::InvalidControl);
            }
            control_ids = Some(ids);
            if states
                .insert((scheme.into(), action.into()), appearance.clone())
                .is_some()
            {
                return Err(ProfileAppearanceError::InvalidState);
            }
        }
        Ok(Some(Self {
            states: Arc::new(states),
            resources,
        }))
    }
    /// Binary lookups share the validated immutable pool; render preparation does
    /// not expand image bytes into eight Base64 copies.
    pub fn resource_data(&self, reference: &Value) -> Result<Arc<[u8]>, ProfileAppearanceError> {
        Ok(self
            .resources
            .as_ref()
            .ok_or(ProfileAppearanceError::InvalidBank)?
            .data(reference)?)
    }
    /// A display projection of a validated canonical layout with explicit input
    /// owners and native mirror collections. Persist canonical input, never this paint.
    pub fn resolve_layout(
        &self,
        current: &Value,
        scheme: &str,
        action: &str,
    ) -> Result<Value, ProfileAppearanceError> {
        budget(current)?;
        state_key(scheme, action)?;
        let edited = snapshot(current)?;
        let baseline = &self.states[&("light".into(), "base".into())];
        let target = &self.states[&(scheme.into(), action.into())];
        let mut merged = target.clone();
        for key in SURFACE {
            set(
                &mut merged,
                key,
                picked(
                    field(&edited, key),
                    field(baseline, key),
                    field(target, key),
                ),
            );
        }
        merged["artworkLayers"] = collection(
            &edited["artworkLayers"],
            &baseline["artworkLayers"],
            &target["artworkLayers"],
            Merge::Fields,
        )?;
        let accent = merged["accentStyle"]
            .as_str()
            .unwrap_or("monochrome")
            .to_owned();
        for key in ["controls", "controlBar"] {
            merged[key] = controls(&edited[key], &baseline[key], &target[key], scheme, &accent)?;
        }
        merged["topBar"] = control(
            &edited["topBar"],
            &baseline["topBar"],
            &target["topBar"],
            scheme,
            &accent,
        );
        for (library, entries, merge) in [
            ("styleLibrary", "styles", Merge::Token),
            ("assetLibrary", "assets", Merge::Value),
        ] {
            merged[library] = json!({entries: collection(&edited[library][entries], &baseline[library][entries], &target[library][entries], merge)?});
        }
        applying(current, &merged)
    }
}
fn field<'a>(value: &'a Value, key: &str) -> Option<&'a Value> {
    value.get(key).filter(|v| !v.is_null())
}
fn set(value: &mut Value, key: &str, item: Option<Value>) {
    if let Some(item) = item {
        value.as_object_mut().unwrap().insert(key.into(), item);
    } else {
        value.as_object_mut().unwrap().remove(key);
    }
}
fn picked(e: Option<&Value>, b: Option<&Value>, t: Option<&Value>) -> Option<Value> {
    if e == b {
        t.cloned()
    } else {
        e.cloned()
    }
}
fn state_key(scheme: &str, action: &str) -> Result<(), ProfileAppearanceError> {
    if ["light", "dark"].contains(&scheme) && ACTIONS.contains(&action) {
        Ok(())
    } else {
        Err(ProfileAppearanceError::InvalidState)
    }
}
fn budget(value: &Value) -> Result<(), ProfileAppearanceError> {
    // Count serde_json's compact UTF-8 representation without serializing image
    // strings or allocating another complete document just to check its bound.
    fn string_bytes(value: &str) -> usize {
        value.bytes().fold(2usize, |size, byte| {
            size.saturating_add(match byte {
                b'"' | b'\\' | b'\n' | b'\r' | b'\t' | 8 | 12 => 2,
                0..=31 => 6,
                _ => 1,
            })
        })
    }
    let mut pending = vec![(value, 0usize)];
    let mut bytes = 0usize;
    while let Some((node, depth)) = pending.pop() {
        if depth > 128 {
            return Err(ProfileAppearanceError::TooLarge);
        }
        let local = match node {
            Value::String(s) => string_bytes(s),
            Value::Array(values) => {
                pending.extend(values.iter().map(|node| (node, depth + 1)));
                2 + values.len().saturating_sub(1)
            }
            Value::Object(fields) => {
                pending.extend(fields.values().map(|node| (node, depth + 1)));
                fields
                    .keys()
                    .fold(2 + fields.len().saturating_sub(1), |sum, key| {
                        sum.saturating_add(string_bytes(key) + 1)
                    })
            }
            Value::Number(number) => number.to_string().len(),
            Value::Bool(true) | Value::Null => 4,
            Value::Bool(false) => 5,
        };
        bytes = bytes.saturating_add(local);
        if bytes > MAXIMUM_CONFIGURATION_DOCUMENT_BYTES {
            return Err(ProfileAppearanceError::TooLarge);
        }
    }
    Ok(())
}
fn rows(value: &Value) -> Result<&Vec<Value>, ProfileAppearanceError> {
    value
        .as_array()
        .ok_or(ProfileAppearanceError::InvalidCollection)
}
fn keyed(value: &Value) -> Result<BTreeMap<&str, &Value>, ProfileAppearanceError> {
    let mut result = BTreeMap::new();
    for row in rows(value)? {
        let id = row["id"]
            .as_str()
            .filter(|s| !s.is_empty())
            .ok_or(ProfileAppearanceError::InvalidCollection)?;
        if result.insert(id, row).is_some() {
            return Err(ProfileAppearanceError::InvalidCollection);
        }
    }
    Ok(result)
}
fn has_data(
    value: Option<&Value>,
    table: Option<&ProfileResourceTable>,
) -> Result<bool, ProfileAppearanceError> {
    let Some(value) = value else { return Ok(false) };
    if let Some(encoded) = value.as_str() {
        let bytes = STANDARD
            .decode(encoded)
            .map_err(|_| ProfileAppearanceError::InvalidSnapshot)?;
        if STANDARD.encode(&bytes) != encoded {
            return Err(ProfileAppearanceError::InvalidSnapshot);
        }
        return Ok(!bytes.is_empty());
    }
    Ok(!table
        .ok_or(ProfileAppearanceError::InvalidSnapshot)?
        .data(value)?
        .is_empty())
}
fn validate_snapshot(
    value: &Value,
    table: Option<&ProfileResourceTable>,
) -> Result<(), ProfileAppearanceError> {
    let object = value
        .as_object()
        .ok_or(ProfileAppearanceError::InvalidSnapshot)?;
    if object
        .keys()
        .any(|key| !SURFACE.contains(&key.as_str()) && !OWNERS.contains(&key.as_str()))
        || !value["showsButtonLabels"].is_boolean()
        || !["monochrome", "blue", "green", "purple", "pink", "amber"]
            .contains(&value["accentStyle"].as_str().unwrap_or(""))
    {
        return Err(ProfileAppearanceError::InvalidSnapshot);
    }
    let controls = value["controls"]
        .as_object()
        .filter(|v| v.len() <= 2048)
        .ok_or(ProfileAppearanceError::InvalidControl)?;
    if controls.keys().any(|id| {
        KeypadElementID::parse(id).is_none_or(|parsed| parsed.to_string().to_lowercase() != *id)
    }) {
        return Err(ProfileAppearanceError::InvalidControl);
    }
    let bars = value["controlBar"]
        .as_object()
        .ok_or(ProfileAppearanceError::InvalidControl)?;
    if bars.keys().any(|id| !BARS.contains(&id.as_str())) {
        return Err(ProfileAppearanceError::InvalidControl);
    }
    for control in controls
        .values()
        .chain(bars.values())
        .chain([&value["topBar"]])
    {
        if control
            .as_object()
            .is_none_or(|o| o.keys().any(|k| !CONTROL.contains(&k.as_str())))
        {
            return Err(ProfileAppearanceError::InvalidControl);
        }
    }
    keyed(&value["artworkLayers"])?;
    keyed(&value["styleLibrary"]["styles"])?;
    let assets = keyed(&value["assetLibrary"]["assets"])?;
    let mut available = BTreeSet::new();
    for (id, asset) in assets {
        if has_data(field(asset, "data"), table)? {
            available.insert(id);
        }
    }
    let mut pending = vec![value];
    while let Some(node) = pending.pop() {
        if node.get("resourceSHA256").is_some() {
            table
                .ok_or(ProfileAppearanceError::InvalidSnapshot)?
                .data(node)?;
            continue;
        }
        if node["kind"] == "image" {
            let image = &node["image"];
            if let Some(id) = image["assetID"].as_str().filter(|id| !id.is_empty()) {
                if !available.contains(id) && !has_data(field(image, "data"), table)? {
                    return Err(ProfileAppearanceError::MissingAsset(id.into()));
                }
            }
        }
        if node["source"] == "asset" {
            let id = node["value"].as_str().unwrap_or("");
            if !available.contains(id) {
                return Err(ProfileAppearanceError::MissingAsset(id.into()));
            }
        }
        match node {
            Value::Object(o) => pending.extend(o.values()),
            Value::Array(a) => pending.extend(a),
            _ => {}
        }
    }
    Ok(())
}
fn normalize_artwork(layout: &mut Value) {
    if let Some(layers) = layout["artworkLayers"].as_array_mut() {
        layers.retain(|v| v["isHidden"].as_bool() != Some(true));
        layers.sort_by(|a, b| {
            a["plane"]
                .as_str()
                .unwrap_or("underlay")
                .cmp(b["plane"].as_str().unwrap_or("underlay"))
                .then_with(|| {
                    a["zIndex"]
                        .as_f64()
                        .unwrap_or(0.0)
                        .total_cmp(&b["zIndex"].as_f64().unwrap_or(0.0))
                })
                .then_with(|| a["id"].as_str().cmp(&b["id"].as_str()))
        });
    }
}
fn control_snapshot(layout: &Value) -> Value {
    let mut result = json!({});
    for key in CONTROL {
        set(&mut result, key, field(layout, key).cloned());
    }
    if field(&result, "shadowStrength").is_none() {
        result["shadowStrength"] = json!(1);
    }
    if result["showsIntegratedLabel"].as_bool().unwrap_or(true) {
        result
            .as_object_mut()
            .unwrap()
            .remove("showsIntegratedLabel");
    }
    if result["joystickVisualStyle"] == "pad" {
        result
            .as_object_mut()
            .unwrap()
            .remove("joystickVisualStyle");
    }
    result
}
fn top_bar() -> Value {
    json!({"centerX":0.5,"centerY":0.115,"widthScale":1,"heightScale":1,"zIndex":100,"shape":"capsule","accentStyle":"blue","cornerRadius":18,"shadowStrength":0.35,"icon":{"source":"sf_symbol","value":"chevron.down","placement":"center","scale":1,"renderingMode":"template"}})
}
fn pairs(value: &Value) -> Result<BTreeMap<String, Value>, ProfileAppearanceError> {
    let Some(value) = value.as_array() else {
        return Ok(BTreeMap::new());
    };
    if value.len() % 2 != 0 {
        return Err(ProfileAppearanceError::InvalidControl);
    }
    let mut map = BTreeMap::new();
    for pair in value.chunks_exact(2) {
        let id = pair[0]
            .as_str()
            .and_then(KeypadElementID::parse)
            .ok_or(ProfileAppearanceError::InvalidControl)?
            .to_string();
        if map.insert(id, pair[1].clone()).is_some() {
            return Err(ProfileAppearanceError::InvalidControl);
        }
    }
    Ok(map)
}
fn element_layout<'a>(
    element: &'a Value,
    overrides: &'a BTreeMap<String, Value>,
) -> Result<&'a Value, ProfileAppearanceError> {
    let id = element["id"]
        .as_str()
        .and_then(KeypadElementID::parse)
        .ok_or(ProfileAppearanceError::InvalidControl)?;
    Ok(
        if element["kind"] == "button" && id.starter_index().is_some() {
            overrides.get(&id.to_string()).unwrap_or(&element["layout"])
        } else {
            &element["layout"]
        },
    )
}
fn snapshot(layout: &Value) -> Result<Value, ProfileAppearanceError> {
    let mut result = json!({});
    for key in SURFACE {
        set(&mut result, key, field(layout, key).cloned());
    }
    if field(&result, "accentStyle").is_none() {
        result["accentStyle"] = json!("monochrome");
    }
    if field(&result, "showsButtonLabels").is_none() {
        result["showsButtonLabels"] = json!(true);
    }
    for (key, empty) in [
        ("artworkLayers", json!([])),
        ("styleLibrary", json!({"styles":[]})),
        ("assetLibrary", json!({"assets":[]})),
    ] {
        result[key] = field(layout, key).cloned().unwrap_or(empty);
    }
    let overrides = pairs(&layout["buttonCustomizations"])?;
    let mut controls = Map::new();
    for element in rows(&layout["elements"])? {
        let id = element["id"]
            .as_str()
            .and_then(KeypadElementID::parse)
            .ok_or(ProfileAppearanceError::InvalidControl)?
            .to_string()
            .to_lowercase();
        if controls
            .insert(id, control_snapshot(element_layout(element, &overrides)?))
            .is_some()
        {
            return Err(ProfileAppearanceError::InvalidControl);
        }
    }
    normalize_artwork(&mut result);
    result["controls"] = Value::Object(controls);
    result["topBar"] =
        control_snapshot(field(layout, "topBarActivationRegion").unwrap_or(&top_bar()));
    let mut bars = Map::new();
    if let Some(items) = layout["controlBarItemCustomizations"].as_array() {
        for item in items {
            let id = item["item"]
                .as_str()
                .ok_or(ProfileAppearanceError::InvalidControl)?;
            let paint = control_snapshot(&item["appearance"]);
            if paint != control_snapshot(&Value::Null) {
                bars.insert(id.into(), paint);
            }
        }
    }
    result["controlBar"] = Value::Object(bars);
    Ok(result)
}
#[derive(Clone, Copy)]
enum Merge {
    Fields,
    Token,
    Value,
    Visual,
    State,
    Content,
    Pointing,
}
fn fields(e: &Value, b: &Value, t: &Value, mode: Merge) -> Value {
    let mut result = t
        .as_object()
        .cloned()
        .map(Value::Object)
        .unwrap_or(json!({}));
    let keys: BTreeSet<_> = e
        .as_object()
        .into_iter()
        .flat_map(|o| o.keys())
        .chain(b.as_object().into_iter().flat_map(|o| o.keys()))
        .collect();
    for key in keys {
        let nested = match (mode, key.as_str()) {
            (Merge::Token, "visualStyle") => Some(Merge::Visual),
            (Merge::Visual, "normal" | "pressed" | "active" | "disabled") => Some(Merge::State),
            (Merge::State, "content") => Some(Merge::Content),
            (Merge::Content, "pointing") => Some(Merge::Pointing),
            _ => None,
        };
        let value = if let Some(mode) = nested {
            optional(field(e, key), field(b, key), field(t, key), mode)
        } else {
            picked(field(e, key), field(b, key), field(t, key))
        };
        set(&mut result, key, value);
    }
    result
}
fn optional(e: Option<&Value>, b: Option<&Value>, t: Option<&Value>, mode: Merge) -> Option<Value> {
    if e == b {
        return t.cloned();
    }
    let e = e?;
    let mut result = fields(
        e,
        b.unwrap_or(&Value::Null),
        t.unwrap_or(&Value::Null),
        mode,
    );
    // Native visual styles always own a nonoptional normal state, including
    // a new reusable style with edits only to pressed/active/disabled paint.
    if matches!(mode, Merge::Visual) && !result["normal"].is_object() {
        result["normal"] = json!({});
    }
    Some(result)
}
fn control(e: &Value, b: &Value, t: &Value, scheme: &str, accent: &str) -> Value {
    let mut result = fields(e, b, t, Merge::Fields);
    let target = if field(e, "styleID") == field(b, "styleID") {
        field(t, "visualStyle")
    } else {
        None
    };
    set(
        &mut result,
        "visualStyle",
        optional(
            field(e, "visualStyle"),
            field(b, "visualStyle"),
            target,
            Merge::Visual,
        ),
    );
    let keys = [
        "fillColor".into(),
        "fillStyle".into(),
        format!("{scheme}FillColor"),
        format!("{scheme}FillStyle"),
    ];
    if keys.iter().any(|k| field(e, k) != field(b, k)) {
        let fill = effective_fill(e, scheme, accent);
        if fill != effective_fill(b, scheme, accent) {
            ensure(&mut result, "visualStyle");
            ensure(&mut result["visualStyle"], "normal");
            result["visualStyle"]["normal"]["fillStyle"] = fill;
        }
    }
    if let Some(icon) = field(e, "icon").filter(|v| Some(*v) != field(b, "icon")) {
        ensure(&mut result, "visualStyle");
        for name in ["normal", "pressed", "active", "disabled"] {
            ensure(&mut result["visualStyle"], name);
            ensure(&mut result["visualStyle"][name], "content");
            result["visualStyle"][name]["content"]["icon"] = icon.clone();
        }
    }
    result
}
fn ensure(value: &mut Value, key: &str) {
    if !value[key].is_object() {
        value[key] = json!({});
    }
}
fn effective_fill(value: &Value, scheme: &str, accent: &str) -> Value {
    for key in [format!("{scheme}FillStyle"), "fillStyle".into()] {
        if let Some(fill) = field(value, &key) {
            return fill.clone();
        }
    }
    for key in [format!("{scheme}FillColor"), "fillColor".into()] {
        if let Some(color) = field(value, &key) {
            return json!({"kind":"solid","color":color});
        }
    }
    let dark = scheme == "dark";
    let hex = match (value["accentStyle"].as_str().unwrap_or(accent), dark) {
        ("blue", false) => "f0f7ff",
        ("blue", true) => "06193a",
        ("green", false) => "ecfdec",
        ("green", true) => "002608",
        ("purple", false) => "faf0ff",
        ("purple", true) => "290c33",
        ("pink", false) => "ffe8f6",
        ("pink", true) => "310d1e",
        (_, false) => "f2f2f2",
        (_, true) => "1a1a1a",
    };
    let rgb = u32::from_str_radix(hex, 16).unwrap();
    json!({"kind":"solid","color":{"red":((rgb>>16)&255) as f64/255.0,"green":((rgb>>8)&255) as f64/255.0,"blue":(rgb&255) as f64/255.0,"alpha":1}})
}
fn controls(
    e: &Value,
    b: &Value,
    t: &Value,
    scheme: &str,
    accent: &str,
) -> Result<Value, ProfileAppearanceError> {
    let e = e
        .as_object()
        .ok_or(ProfileAppearanceError::InvalidControl)?;
    let b = b.as_object().unwrap();
    let mut result = t.clone();
    for (id, original) in b {
        if let Some(current) = e.get(id) {
            if let Some(target) = t.get(id) {
                result[id] = control(current, original, target, scheme, accent);
            } else if current != original {
                result[id] = current.clone();
            }
        } else {
            result.as_object_mut().unwrap().remove(id);
        }
    }
    for (id, current) in e.iter().filter(|(id, _)| !b.contains_key(*id)) {
        result[id] = t
            .get(id)
            .map(|target| {
                control(
                    current,
                    &control_snapshot(&Value::Null),
                    target,
                    scheme,
                    accent,
                )
            })
            .unwrap_or_else(|| current.clone());
    }
    Ok(result)
}
fn collection(
    e: &Value,
    b: &Value,
    t: &Value,
    mode: Merge,
) -> Result<Value, ProfileAppearanceError> {
    let eb = keyed(e)?;
    let bb = keyed(b)?;
    keyed(t)?;
    if e == b {
        return Ok(t.clone());
    }
    if t == b || eb.is_empty() {
        return Ok(e.clone());
    }
    let mut result = Vec::new();
    let mut seen = BTreeSet::new();
    for item in rows(t)? {
        let id = item["id"].as_str().unwrap();
        seen.insert(id);
        if let Some(original) = bb.get(id) {
            if let Some(current) = eb.get(id) {
                result.push(if matches!(mode, Merge::Value) {
                    picked(Some(current), Some(original), Some(item)).unwrap()
                } else {
                    fields(current, original, item, mode)
                });
            }
        } else {
            result.push(eb.get(id).copied().unwrap_or(item).clone());
        }
    }
    for item in rows(e)? {
        let id = item["id"].as_str().unwrap();
        if seen.insert(id) && bb.get(id).copied() != Some(item) {
            result.push(item.clone());
        }
    }
    let order = |v: &Value| {
        rows(v)
            .unwrap()
            .iter()
            .filter_map(|item| {
                let id = item["id"].as_str().unwrap();
                (eb.contains_key(id) && bb.contains_key(id)).then_some(id.to_owned())
            })
            .collect::<Vec<_>>()
    };
    if order(e) != order(b) || eb.keys().any(|id| !bb.contains_key(id)) {
        let by_id: BTreeMap<_, _> = result
            .iter()
            .map(|v| (v["id"].as_str().unwrap(), v.clone()))
            .collect();
        let mut reordered = rows(e)?
            .iter()
            .filter_map(|v| by_id.get(v["id"].as_str().unwrap()))
            .cloned();
        result = result
            .iter()
            .map(|v| {
                if eb.contains_key(v["id"].as_str().unwrap()) {
                    reordered.next().unwrap_or_else(|| v.clone())
                } else {
                    v.clone()
                }
            })
            .collect();
    }
    Ok(Value::Array(result))
}
fn applying(current: &Value, paint: &Value) -> Result<Value, ProfileAppearanceError> {
    let mut result = current.clone();
    for key in SURFACE
        .iter()
        .copied()
        .chain(["artworkLayers", "styleLibrary", "assetLibrary"])
    {
        set(&mut result, key, field(paint, key).cloned());
    }
    let mut overrides = pairs(&current["buttonCustomizations"])?;
    for element in result["elements"]
        .as_array_mut()
        .ok_or(ProfileAppearanceError::InvalidControl)?
    {
        let id = element["id"]
            .as_str()
            .and_then(KeypadElementID::parse)
            .ok_or(ProfileAppearanceError::InvalidControl)?;
        if let Some(style) = paint["controls"].get(id.to_string().to_lowercase()) {
            let mut local = element_layout(element, &overrides)?.clone();
            if !local.is_object() {
                local = json!({});
            }
            for key in CONTROL {
                set(&mut local, key, field(style, key).cloned());
            }
            element["layout"] = local.clone();
            if element["kind"] == "button" && id.starter_index().is_some() {
                overrides.insert(id.to_string(), local);
            }
        }
    }
    if let Some(customs) = result["customButtons"].as_array_mut() {
        for custom in customs {
            if let Some(element) = result_element(current, custom) {
                if let Some(style) =
                    paint["controls"].get(element["id"].as_str().unwrap().to_lowercase())
                {
                    let layout = custom
                        .get_mut("layout")
                        .filter(|value| value.is_object())
                        .ok_or(ProfileAppearanceError::InvalidControl)?;
                    for key in CONTROL {
                        set(layout, key, field(style, key).cloned());
                    }
                }
            }
        }
    }
    result["buttonCustomizations"] = Value::Array(
        overrides
            .into_iter()
            .flat_map(|(k, v)| [Value::String(k), v])
            .collect(),
    );
    let mut top = field(current, "topBarActivationRegion")
        .cloned()
        .unwrap_or(top_bar());
    for key in CONTROL {
        set(&mut top, key, field(&paint["topBar"], key).cloned());
    }
    result["topBarActivationRegion"] = top;
    let old = current["controlBarItemCustomizations"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    let items = current["controlBarItems"]
        .as_array()
        .cloned()
        .unwrap_or_else(|| BARS.iter().map(|s| json!(s)).collect());
    let mut bars = Vec::new();
    for item in items {
        let id = item
            .as_str()
            .ok_or(ProfileAppearanceError::InvalidControl)?;
        let mut record = old
            .iter()
            .find(|v| v["item"] == id)
            .cloned()
            .unwrap_or(json!({"item":id,"appearance":{}}));
        let style = paint["controlBar"]
            .get(id)
            .cloned()
            .unwrap_or_else(|| control_snapshot(&Value::Null));
        ensure(&mut record, "appearance");
        for key in CONTROL {
            set(&mut record["appearance"], key, field(&style, key).cloned());
        }
        bars.push(record);
    }
    result["controlBarItemCustomizations"] = Value::Array(bars);
    normalize_artwork(&mut result);
    Ok(result)
}
fn result_element<'a>(current: &'a Value, custom: &Value) -> Option<&'a Value> {
    let id = custom["id"].as_str()?;
    current["elements"].as_array()?.iter().find(|e| {
        e["id"]
            .as_str()
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(id))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    fn difference(a: &Value, b: &Value, path: &str) -> Option<String> {
        if a == b {
            return None;
        }
        // SwiftUI/NSColor converts palette components through platform floats.
        // Only normalized color channels permit sub-8-bit conversion noise.
        if path.to_lowercase().contains("color")
            && ["/red", "/green", "/blue", "/alpha"]
                .iter()
                .any(|suffix| path.ends_with(suffix))
            && a.as_f64().zip(b.as_f64()).is_some_and(|(a, b)| {
                (0.0..=1.0).contains(&a) && (0.0..=1.0).contains(&b) && (a - b).abs() <= 0.000_000_2
            })
        {
            return None;
        }
        match (a, b) {
            (Value::Object(a), Value::Object(b)) => {
                let keys: BTreeSet<_> = a.keys().chain(b.keys()).collect();
                for k in keys {
                    match (a.get(k), b.get(k)) {
                        (Some(a), Some(b)) => {
                            if let Some(diff) = difference(a, b, &format!("{path}/{k}")) {
                                return Some(diff);
                            }
                        }
                        (a, b) => return Some(format!("{path}/{k}: actual {a:?}, expected {b:?}")),
                    }
                }
                None
            }
            (Value::Array(a), Value::Array(b)) if a.len() == b.len() => a
                .iter()
                .zip(b)
                .enumerate()
                .find_map(|(i, (a, b))| difference(a, b, &format!("{path}/{i}"))),
            _ => Some(format!("{path}: actual {a}, expected {b}")),
        }
    }
    fn resource_fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../fixtures/profile-resources/v1/fixture.json"
        ))
        .unwrap()
    }
    fn expanded(value: &Value, bank: &ProfileAppearanceBank) -> Value {
        match value {
            Value::Object(object) if object.contains_key("resourceSHA256") => {
                json!(STANDARD.encode(bank.resource_data(value).unwrap()))
            }
            Value::Object(object) => Value::Object(
                object
                    .iter()
                    .map(|(k, v)| (k.clone(), expanded(v, bank)))
                    .collect(),
            ),
            Value::Array(array) => Value::Array(array.iter().map(|v| expanded(v, bank)).collect()),
            _ => value.clone(),
        }
    }
    #[test]
    fn all_eight_pooled_states_resolve_without_package_lookup_or_source_mutation() {
        let profile = resource_fixture()["pooledProfile"].clone();
        let before = profile.clone();
        let bank = ProfileAppearanceBank::from_profile(&profile)
            .unwrap()
            .unwrap();
        for scheme in ["light", "dark"] {
            for action in ACTIONS {
                let current = &profile["customization"];
                let resolved = bank.resolve_layout(current, scheme, action).unwrap();
                assert_eq!(
                    resolved["elements"][0]["layout"]["icon"]["value"],
                    format!("{scheme}/{action}")
                );
                let before_element = &current["elements"][0];
                let after_element = &resolved["elements"][0];
                for key in [
                    "id",
                    "kind",
                    "output",
                    "defaultOutput",
                    "partOutputs",
                    "label",
                    "visualRole",
                ] {
                    assert_eq!(before_element[key], after_element[key]);
                }
                for key in [
                    "centerX",
                    "centerY",
                    "widthScale",
                    "heightScale",
                    "rotationDegrees",
                    "isHidden",
                ] {
                    assert_eq!(before_element["layout"][key], after_element["layout"][key]);
                }
                let reference = &resolved["assetLibrary"]["assets"][0]["data"];
                let a = bank.resource_data(reference).unwrap();
                let b = bank.resource_data(reference).unwrap();
                assert!(Arc::ptr_eq(&a, &b));
                assert_eq!(&*a, b"fixture-image");
            }
        }
        assert_eq!(before, profile);
        let default_bar = bank
            .resolve_layout(&profile["customization"], "light", "base")
            .unwrap();
        assert_eq!(default_bar["topBarActivationRegion"]["centerX"], 0.5);
        assert_eq!(default_bar["topBarActivationRegion"]["centerY"], 0.115);
        assert!(bank
            .resolve_layout(&profile["customization"], "unknown", "base")
            .is_err());
    }
    #[test]
    fn native_edit_oracles_match_every_scheme_and_action() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../fixtures/appearance-edits/v1/fixture.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let profile = &case["profile"];
            let before = profile.clone();
            let bank = ProfileAppearanceBank::from_profile(profile)
                .unwrap()
                .unwrap();
            for row in case["resolutions"].as_array().unwrap() {
                let result = bank
                    .resolve_layout(
                        &profile["customization"],
                        row["colorScheme"].as_str().unwrap(),
                        row["actionSet"].as_str().unwrap(),
                    )
                    .unwrap();
                let original_elements = profile["customization"]["elements"].as_array().unwrap();
                let resolved_elements = result["elements"].as_array().unwrap();
                assert_eq!(original_elements.len(), resolved_elements.len());
                for (original, resolved) in original_elements.iter().zip(resolved_elements) {
                    let mut original_owner = original.as_object().unwrap().clone();
                    let mut resolved_owner = resolved.as_object().unwrap().clone();
                    original_owner.remove("layout");
                    resolved_owner.remove("layout");
                    assert_eq!(original_owner, resolved_owner, "input owner changed");
                    let geometry = |v: &Value| {
                        v.as_object()
                            .unwrap()
                            .iter()
                            .filter(|(k, _)| !CONTROL.contains(&k.as_str()))
                            .map(|(k, v)| (k.clone(), v.clone()))
                            .collect::<BTreeMap<_, _>>()
                    };
                    assert_eq!(
                        geometry(&original["layout"]),
                        geometry(&resolved["layout"]),
                        "geometry changed"
                    );
                }
                let actual = expanded(&snapshot(&result).unwrap(), &bank);
                assert!(
                    difference(&actual, &row["expectedAppearance"], "").is_none(),
                    "{} {}/{}: {}",
                    case["name"],
                    row["colorScheme"],
                    row["actionSet"],
                    difference(&actual, &row["expectedAppearance"], "").unwrap()
                );
            }
            assert_eq!(profile, &before);
        }
    }
    #[test]
    fn corrupt_banks_assets_resources_and_geometry_in_paint_require_recovery() {
        let original = resource_fixture()["pooledProfile"].clone();
        let mutations: Vec<fn(&mut Value)> = vec![
            |p| p["appearanceBank"]["schemaVersion"] = json!(99),
            |p| {
                p["appearanceBank"]["variants"]
                    .as_array_mut()
                    .unwrap()
                    .pop();
            },
            |p| p["appearanceBank"]["variants"][0] = p["appearanceBank"]["variants"][1].clone(),
            |p| p["appearanceBank"]["variants"][0]["appearance"]["elements"] = json!([]),
            |p| {
                p["appearanceBank"]["variants"][0]["appearance"]["controls"]["not-a-control"] =
                    json!({})
            },
            |p| p["appearanceBank"]["variants"][0]["appearance"]["topBar"]["centerX"] = json!(0.2),
            |p| p["appearanceResources"] = json!({}),
            |p| {
                p["appearanceBank"]["variants"][0]["appearance"]["topBar"]["icon"] =
                    json!({"source":"asset","value":"missing"})
            },
            |p| {
                p["appearanceBank"]["variants"][0]["appearance"]["artworkLayers"] =
                    json!([{"id":"same"},{"id":"same"}])
            },
        ];
        for mutate in mutations {
            let mut profile = original.clone();
            mutate(&mut profile);
            let before = profile.clone();
            assert!(ProfileAppearanceBank::from_profile(&profile).is_err());
            assert_eq!(profile, before);
        }
        assert!(
            ProfileAppearanceBank::from_profile(&json!({"customization":{}}))
                .unwrap()
                .is_none()
        );
        let too_large =
            json!({"appearanceBank":{"future":"x".repeat(MAXIMUM_CONFIGURATION_DOCUMENT_BYTES)}});
        assert_eq!(
            ProfileAppearanceBank::from_profile(&too_large).unwrap_err(),
            ProfileAppearanceError::TooLarge
        );
    }
    #[test]
    fn byte_budget_matches_compact_json_including_escapes_without_rejecting_the_boundary() {
        let sample = json!({"escaped\nkey": ["é\t\\\"", true, false, null, 1.25]});
        assert!(budget(&sample).is_ok());
        let mut nested = Value::Null;
        for _ in 0..130 {
            nested = json!({"future":nested});
        }
        assert_eq!(
            ProfileAppearanceBank::from_profile(&nested).unwrap_err(),
            ProfileAppearanceError::TooLarge
        );
        let overhead = serde_json::to_vec(&json!({"future":""})).unwrap().len();
        let mut profile =
            json!({"future":"x".repeat(MAXIMUM_CONFIGURATION_DOCUMENT_BYTES-overhead)});
        assert!(ProfileAppearanceBank::from_profile(&profile)
            .unwrap()
            .is_none());
        profile["future"] = json!("x".repeat(MAXIMUM_CONFIGURATION_DOCUMENT_BYTES - overhead + 1));
        assert_eq!(
            ProfileAppearanceBank::from_profile(&profile).unwrap_err(),
            ProfileAppearanceError::TooLarge
        );
    }
    #[test]
    fn future_layout_metadata_and_later_geometry_edits_survive_resolution() {
        let mut profile = resource_fixture()["pooledProfile"].clone();
        let bank = ProfileAppearanceBank::from_profile(&profile)
            .unwrap()
            .unwrap();
        profile["customization"]["futureMetadata"] = json!({"owner":"keep","nullable":null});
        profile["customization"]["elements"][0]["layout"]["centerX"] = json!(0.81);
        // Starter button mirrors are authoritative in the native model.
        profile["customization"]["buttonCustomizations"][1]["centerX"] = json!(0.81);
        let result = bank
            .resolve_layout(&profile["customization"], "dark", "both-triggers")
            .unwrap();
        assert_eq!(
            result["futureMetadata"],
            profile["customization"]["futureMetadata"]
        );
        assert_eq!(result["elements"][0]["layout"]["centerX"], 0.81);
        assert_eq!(
            result["buttonCustomizations"][1],
            result["elements"][0]["layout"]
        );
        let mut malformed = profile["customization"].clone();
        malformed["customButtons"] = json!([{"id":malformed["elements"][0]["id"],"layout":null}]);
        let before = malformed.clone();
        assert!(bank.resolve_layout(&malformed, "dark", "base").is_err());
        assert_eq!(malformed, before);
    }
}
