//! Independent reconstruction for identity-preserving control lifecycle edits.
//! Appearance anchors are used only for declared button appearance; executable
//! outputs always come from the source element, never a label or anchor table.
use super::*;
use std::collections::{BTreeMap, HashSet};

pub(super) fn constrained_lifecycle_delta(
    source: &Map<String, Value>,
    result: &Map<String, Value>,
    operation: &ConfigurationOperation,
) -> bool {
    let mut expected = source.clone();
    if !materialize_declared_custom_mirrors(&mut expected) {
        return false;
    }
    let applied = match operation {
        ConfigurationOperation::ElementDuplicate {
            element_ids,
            new_element_ids,
            offset_x,
            offset_y,
            ..
        } => duplicate(
            &mut expected,
            result,
            element_ids,
            new_element_ids,
            *offset_x,
            *offset_y,
        ),
        ConfigurationOperation::ElementDelete { element_id, .. } => {
            delete(&mut expected, element_id)
        }
        ConfigurationOperation::ElementReset { element_id, .. } => reset(&mut expected, element_id),
        _ => false,
    };
    let variant = match operation {
        ConfigurationOperation::ElementDuplicate { variant, .. }
        | ConfigurationOperation::ElementDelete { variant, .. }
        | ConfigurationOperation::ElementReset { variant, .. } => *variant,
        _ => return false,
    };
    correct_customization_frame_orientation(&mut expected, variant);
    let pair = logical_customization(&expected).zip(logical_customization(result));
    applied
        && pair.is_some_and(|(expected, actual)| {
            json_semantically_equal(&Value::Object(expected), &Value::Object(actual))
        })
}

fn duplicate(
    expected: &mut Map<String, Value>,
    actual: &Map<String, Value>,
    ids: &[String],
    new_ids: &[String],
    offset_x: f64,
    offset_y: f64,
) -> bool {
    if ids.is_empty()
        || ids.len() != new_ids.len()
        || !offset_x.is_finite()
        || !offset_y.is_finite()
        || !(-1.0..=1.0).contains(&offset_x)
        || !(-1.0..=1.0).contains(&offset_y)
    {
        return false;
    }
    let Some((width, height)) = customization_canvas_size(expected) else {
        return false;
    };
    let Some(mut order) = normalized_layer_order(expected) else {
        return false;
    };
    let Some(mut groups) = saved_layer_groups(expected) else {
        return false;
    };
    let source = expected.clone();
    let mut seen = HashSet::new();
    let mut added = Vec::new();
    for (old_id, new_id) in ids.iter().zip(new_ids) {
        let Some(identity) = resolve_layer_identity(&source, old_id) else {
            return false;
        };
        let Some(key) = layer_identity_key(&identity) else {
            return false;
        };
        if !seen.insert(key.clone()) {
            return false;
        }
        let Some(element) = source
            .get("elements")
            .and_then(Value::as_array)
            .and_then(|elements| element_for_identity(elements, &key))
        else {
            return false;
        };
        let Some((kind, id)) = key.split_once(':') else {
            return false;
        };
        let mut button = match kind {
            "builtin" => {
                let Some(mut layout) = builtin_layout(&source, id).map(normalized_known_layout)
                else {
                    return false;
                };
                if !layout
                    .get("isHidden")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
                {
                    let Some(snapshot) = group_nudge_snapshot(&source, &key, width, height) else {
                        return false;
                    };
                    layout.insert("centerX".to_owned(), Value::from(snapshot.center_x / width));
                    layout.insert(
                        "centerY".to_owned(),
                        Value::from(snapshot.center_y / height),
                    );
                }
                let mut button = serde_json::json!({"id":new_id,"label":builtin_visual_label(&source,id),
                    "controlKind":"button","layout":layout});
                if let Some(role) = element.get("visualRole") {
                    button["visualRole"] = role.clone();
                }
                button.as_object().unwrap().clone()
            }
            "custom" => {
                let Some(button) = custom_button(&source, id).and_then(known_custom_button) else {
                    return false;
                };
                button
            }
            _ => return false,
        };
        let new_id = canonical_uuid_string(new_id);
        let Some(mut layout) = button
            .get("layout")
            .and_then(Value::as_object)
            .cloned()
            .map(normalized_known_layout)
        else {
            return false;
        };
        normalize_duplicate_kind_layout(&mut button, &mut layout);
        for (axis, offset) in [("centerX", offset_x), ("centerY", offset_y)] {
            let Some(center) = normalized_layout_center(&layout, axis, 0.5) else {
                return false;
            };
            let value = (center + offset).clamp(0.0, 1.0);
            // Adopt native floating-point spelling only after checking the
            // independently calculated coordinate, never an arbitrary response.
            let Some(actual_value) = custom_button(actual, &new_id)
                .and_then(|button| button.get("layout"))
                .and_then(|layout| layout.get(axis))
                .and_then(Value::as_f64)
                .filter(|actual| (*actual - value).abs() <= 1e-10)
            else {
                return false;
            };
            layout.insert(axis.to_owned(), Value::from(actual_value));
        }
        button.insert("id".to_owned(), Value::String(new_id.clone()));
        button.insert("layout".to_owned(), Value::Object(layout));
        let Some(copy) = duplicate_element_from_button(&button, element, &new_id) else {
            return false;
        };
        added.push(
            button
                .get("controlKind")
                .and_then(Value::as_str)
                .unwrap_or("button")
                .to_owned(),
        );
        expected
            .entry("customButtons")
            .or_insert_with(|| Value::Array(Vec::new()))
            .as_array_mut()
            .unwrap()
            .push(Value::Object(button));
        expected
            .get_mut("elements")
            .and_then(Value::as_array_mut)
            .unwrap()
            .push(Value::Object(copy));
        let new_identity = serde_json::json!({"kind":"custom","id":new_id});
        let Some(position) = layer_order_position(&order, &identity) else {
            return false;
        };
        order.insert(position + 1, new_identity.clone());
        for group in &mut groups {
            let Some(children) = group.get_mut("children").and_then(Value::as_array_mut) else {
                return false;
            };
            if let Some(position) = layer_order_position(children, &identity) {
                children.insert(position + 1, new_identity.clone());
            }
        }
    }
    if !valid_duplicate_kind_capacity(&source, &added)
        || !element_capacity_is_valid(expected)
        || !set_expected_groups(expected, groups)
    {
        return false;
    }
    set_expected_layer_order(expected, order)
}

fn delete(expected: &mut Map<String, Value>, id: &str) -> bool {
    let Some(identity) = resolve_layer_identity(expected, id) else {
        return false;
    };
    let Some(key) = layer_identity_key(&identity) else {
        return false;
    };
    if let Some(id) = key.strip_prefix("custom:") {
        for field in ["elements", "customButtons"] {
            let Some(values) = expected.get_mut(field).and_then(Value::as_array_mut) else {
                return false;
            };
            values.retain(|value| {
                !value
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|value| value.eq_ignore_ascii_case(id))
            });
        }
        if let Some(metadata) = expected
            .get_mut("designMetadata")
            .and_then(Value::as_object_mut)
        {
            if let Some(order) = metadata.get_mut("layerOrder").and_then(Value::as_array_mut) {
                order.retain(|value| layer_identity_key(value).as_deref() != Some(&key));
            }
            if let Some(groups) = metadata.get_mut("groups").and_then(Value::as_array_mut) {
                for group in groups.iter_mut() {
                    let Some(children) = group.get_mut("children").and_then(Value::as_array_mut)
                    else {
                        return false;
                    };
                    children.retain(|value| layer_identity_key(value).as_deref() != Some(&key));
                }
                groups.retain(|group| {
                    group
                        .get("children")
                        .and_then(Value::as_array)
                        .is_some_and(|children| !children.is_empty())
                });
            }
        }
        return true;
    }
    if let Some(id) = key.strip_prefix("builtin:") {
        let Some(mut layout) = builtin_layout(expected, id) else {
            return false;
        };
        layout.insert("isHidden".to_owned(), Value::Bool(true));
        return set_builtin_appearance(expected, id, layout, None);
    }
    if key == "system:top_bar_activation" {
        let mut layout = expected
            .get("topBarActivationRegion")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_else(default_top_bar_layout);
        layout.insert("isHidden".to_owned(), Value::Bool(true));
        expected.insert("topBarActivationRegion".to_owned(), Value::Object(layout));
        return true;
    }
    false
}

fn reset(expected: &mut Map<String, Value>, id: &str) -> bool {
    let Some(identity) = resolve_layer_identity(expected, id) else {
        return false;
    };
    let Some(key) = layer_identity_key(&identity) else {
        return false;
    };
    if let Some(id) = key.strip_prefix("builtin:") {
        let label = builtin_visual_label(&Map::new(), id);
        if let Some(labels) = expected
            .get_mut("labelOverrides")
            .and_then(Value::as_array_mut)
        {
            let mut index = 0;
            while index + 1 < labels.len() {
                if labels[index]
                    .as_str()
                    .is_some_and(|value| value.eq_ignore_ascii_case(id))
                {
                    labels.drain(index..index + 2);
                } else {
                    index += 2;
                }
            }
        }
        return set_builtin_appearance(expected, id, default_button_layout(), Some(label));
    }
    if key == "system:top_bar_activation" {
        expected.insert(
            "topBarActivationRegion".to_owned(),
            Value::Object(default_top_bar_layout()),
        );
        return true;
    }
    let Some(id) = key.strip_prefix("custom:") else {
        return false;
    };
    let Some(mut button) = custom_button(expected, id).cloned() else {
        return false;
    };
    let kind = button
        .get("controlKind")
        .and_then(Value::as_str)
        .unwrap_or("button")
        .to_owned();
    let (label, mut layout) = match kind.as_str() {
        "button" => (
            "Shape",
            serde_json::json!({"centerX":0.5,"centerY":0.5,"widthScale":1,"heightScale":1,"shape":"rounded_rectangle","showsIntegratedLabel":false}),
        ),
        "joystick" => (
            "Joystick",
            serde_json::json!({"centerX":0.5,"centerY":0.5,"widthScale":1.35,"heightScale":1.35,"shape":"circle"}),
        ),
        "trackpad" => {
            button.remove("trackpadSettings");
            (
                "Trackpad",
                serde_json::json!({"centerX":0.5,"centerY":0.58,"widthScale":1.25,"heightScale":1,"shape":"rounded_rectangle","cornerRadius":18}),
            )
        }
        "trigger" => {
            let target = button
                .get("triggerSettings")
                .and_then(|settings| settings.get("target"))
                .and_then(Value::as_str)
                .unwrap_or("right")
                .to_owned();
            button.insert("triggerSettings".to_owned(), serde_json::json!({"target":target,"orientation":"horizontal","deadZone":0.03,"sensitivity":1,"sendsDigitalButton":false,"digitalThreshold":0.5}));
            (
                "Trigger",
                serde_json::json!({"centerX":if target=="left" {0.2} else {0.8},"centerY":0.14,"widthScale":1.08,"heightScale":0.42,"shape":"capsule","accentStyle":"monochrome"}),
            )
        }
        "text" => (
            "Text",
            serde_json::json!({"centerX":0.5,"centerY":0.5,"widthScale":1.4,"heightScale":0.7,"shape":"rectangle","shadowStrength":0,"showsIntegratedLabel":false}),
        ),
        "decoration" => {
            let style =
                material_visual_style(crate::draft_operation::StyleMaterialPreset::SoftWhitePlate);
            (
                "Decoration",
                serde_json::json!({"centerX":0.5,"centerY":0.5,"widthScale":2.2,"heightScale":1.2,"shape":"rounded_rectangle","cornerRadius":28,"shadowStrength":0,"fillColor":hex_color(0xF2EEF5,1.0),"visualStyle":style}),
            )
        }
        _ => return false,
    };
    let layout = layout.as_object_mut().unwrap();
    normalize_duplicate_kind_layout(&mut button, layout);
    button.insert("label".to_owned(), Value::String(label.to_owned()));
    button.insert("layout".to_owned(), Value::Object(layout.clone()));
    let Some(mirror) = expected
        .get_mut("customButtons")
        .and_then(Value::as_array_mut)
        .and_then(|values| {
            values.iter_mut().find(|value| {
                value["id"]
                    .as_str()
                    .is_some_and(|value| value.eq_ignore_ascii_case(id))
            })
        })
    else {
        return false;
    };
    overlay_appearance(mirror.as_object_mut().unwrap(), &button);
    let Some(element) = expected
        .get_mut("elements")
        .and_then(Value::as_array_mut)
        .and_then(|values| {
            values.iter_mut().find(|value| {
                value["id"]
                    .as_str()
                    .is_some_and(|value| value.eq_ignore_ascii_case(id))
            })
        })
    else {
        return false;
    };
    overlay_appearance(element.as_object_mut().unwrap(), &button);
    true
}

const APPEARANCE_FIELDS: &[&str] = &[
    "label",
    "layout",
    "visualRole",
    "joystickMapping",
    "joystickOutputSettings",
    "triggerSettings",
    "trackpadSettings",
];
fn overlay_appearance(target: &mut Map<String, Value>, appearance: &Map<String, Value>) {
    for field in APPEARANCE_FIELDS {
        if let Some(value) = appearance.get(*field) {
            let value = if *field == "layout" {
                let raw = target
                    .get(*field)
                    .cloned()
                    .unwrap_or_else(|| Value::Object(Map::new()));
                let before = Value::Object(normalized_known_layout(
                    raw.as_object().cloned().unwrap_or_default(),
                ));
                let after = Value::Object(normalized_known_layout(
                    value.as_object().cloned().unwrap_or_default(),
                ));
                apply_expected_canonical_changes(&raw, &before, &after)
            } else {
                value.clone()
            };
            target.insert((*field).to_owned(), value);
        } else {
            target.remove(*field);
        }
    }
}

fn set_builtin_appearance(
    expected: &mut Map<String, Value>,
    id: &str,
    layout: Map<String, Value>,
    label: Option<String>,
) -> bool {
    let Some(element) = expected
        .get_mut("elements")
        .and_then(Value::as_array_mut)
        .and_then(|values| {
            values.iter_mut().find(|value| {
                value["id"]
                    .as_str()
                    .is_some_and(|value| value.eq_ignore_ascii_case(id))
            })
        })
    else {
        return false;
    };
    element["layout"] = Value::Object(layout.clone());
    if let Some(label) = label {
        element["label"] = Value::String(label);
    }
    let Some(mirrors) = expected
        .entry("buttonCustomizations")
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
    else {
        return false;
    };
    let position = mirrors.chunks_exact(2).position(|pair| {
        pair[0]
            .as_str()
            .is_some_and(|value| value.eq_ignore_ascii_case(id))
    });
    if let Some(position) = position {
        mirrors[position * 2 + 1] = Value::Object(layout);
    } else {
        mirrors.extend([
            Value::String(canonical_uuid_string(id)),
            Value::Object(layout),
        ]);
    }
    true
}

/// Canonicalize only omitted known appearance defaults. Unknown fields and
/// executable records remain in the comparison, so canonicalization cannot hide
/// response injections. Mirrors remain independently represented and compared.
fn logical_customization(raw: &Map<String, Value>) -> Option<Map<String, Value>> {
    let mut value = raw.clone();
    if !materialize_declared_custom_mirrors(&mut value) {
        return None;
    }
    let mut builtin_layouts = BTreeMap::new();
    for element in value.get_mut("elements")?.as_array_mut()? {
        let object = element.as_object_mut()?;
        let id = canonical_uuid_string(object.get("id")?.as_str()?);
        let kind = object
            .get("kind")
            .and_then(Value::as_str)
            .unwrap_or("button")
            .to_owned();
        let mut appearance = object.clone();
        appearance.insert("controlKind".to_owned(), Value::String(kind.clone()));
        let layout = logical_layout(
            &mut appearance,
            object
                .get("layout")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default(),
        );
        for field in APPEARANCE_FIELDS {
            if *field == "layout" {
                continue;
            }
            if let Some(value) = appearance.get(*field) {
                object.insert((*field).to_owned(), value.clone());
            } else {
                object.remove(*field);
            }
        }
        object.insert("id".to_owned(), Value::String(id.clone()));
        object.insert("kind".to_owned(), Value::String(kind.clone()));
        object.insert("layout".to_owned(), Value::Object(layout.clone()));
        let parts = element_part_outputs(&Value::Object(object.clone()))?;
        object.insert("partOutputs".to_owned(), serde_json::to_value(parts).ok()?);
        if kind == "button"
            && thumble_protocol::KeypadElementID::parse(&id)?
                .starter_index()
                .is_some()
        {
            builtin_layouts.insert(id, layout);
        }
    }
    let mut custom = BTreeMap::new();
    for button in value
        .get("customButtons")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
    {
        let mut button = button.as_object()?.clone();
        let id = canonical_uuid_string(button.get("id")?.as_str()?);
        let layout = button.get("layout")?.as_object()?.clone();
        let layout = logical_layout(&mut button, layout);
        button.insert("id".to_owned(), Value::String(id.clone()));
        button.insert("layout".to_owned(), Value::Object(layout));
        if custom.insert(id, button).is_some() {
            return None;
        }
    }
    value.insert(
        "customButtons".to_owned(),
        serde_json::to_value(custom).ok()?,
    );
    if let Some(mirrors) = value.get("buttonCustomizations") {
        let entries = mirrors.as_array()?;
        if entries.len() % 2 != 0 {
            return None;
        }
        let mut seen = HashSet::new();
        for pair in entries.chunks_exact(2) {
            let id = canonical_uuid_string(pair[0].as_str()?);
            if !seen.insert(id.clone()) {
                return None;
            }
            let mut appearance = serde_json::json!({"controlKind":"button"})
                .as_object()?
                .clone();
            let layout = logical_layout(&mut appearance, pair[1].as_object()?.clone());
            builtin_layouts.insert(id, layout);
        }
    }
    value.insert(
        "buttonCustomizations".to_owned(),
        serde_json::to_value(builtin_layouts).ok()?,
    );
    for field in ["labelOverrides"] {
        if value
            .get(field)
            .is_none_or(|value| value.is_null() || value.as_array().is_some_and(Vec::is_empty))
        {
            value.remove(field);
        }
    }
    if let Some(metadata) = value.get("designMetadata").and_then(Value::as_object) {
        let available = available_layer_identities(&value)?
            .iter()
            .filter_map(layer_identity_key)
            .collect::<HashSet<_>>();
        if let Some(order) = metadata.get("layerOrder").and_then(Value::as_array) {
            let mut seen = HashSet::new();
            for identity in order {
                let key = layer_identity_key(identity)?;
                if !available.contains(&key) || !seen.insert(key) {
                    return None;
                }
            }
        }
        if let Some(groups) = metadata.get("groups").and_then(Value::as_array) {
            for group in groups {
                for child in group.get("children")?.as_array()? {
                    if !available.contains(&layer_identity_key(child)?) {
                        return None;
                    }
                }
            }
        }
        let order = normalized_layer_order(&value)?;
        if !set_expected_layer_order(&mut value, order) {
            return None;
        }
    }
    if value.get("deviceCanvas") == Some(&serde_json::json!({"frameID":"iphone-17-pro-landscape"}))
    {
        value.remove("deviceCanvas");
    }
    Some(value)
}

fn logical_layout(
    appearance: &mut Map<String, Value>,
    mut raw: Map<String, Value>,
) -> Map<String, Value> {
    let mut known = normalized_known_layout(raw.clone());
    normalize_duplicate_kind_layout(appearance, &mut known);
    // Explicit defaults such as showsIntegratedLabel=true may be omitted by
    // native Codable; remove those known spellings before overlaying defaults.
    if raw.get("showsIntegratedLabel").and_then(Value::as_bool) == Some(true) {
        raw.remove("showsIntegratedLabel");
    }
    if raw.get("joystickVisualStyle").and_then(Value::as_str) == Some("pad") {
        raw.remove("joystickVisualStyle");
    }
    raw.extend(known);
    raw
}
