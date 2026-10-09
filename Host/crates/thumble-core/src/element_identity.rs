use serde::{Deserialize, Serialize};
use crate::{ButtonBindings, OutputBinding};
use serde_json::Value;
use thumble_protocol::KeypadElementID;

/// Descriptive native metadata, separate from labels used by legacy editors and from output routing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementPresentation {
    #[serde(default = "presentation_version")]
    pub schema_version: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "actionID")]
    pub action_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    #[serde(rename = "purposeID")]
    pub purpose_id: Option<String>,
    #[serde(default)]
    #[serde(rename = "groupIDs")]
    pub group_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legend: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub caption: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accessibility_name: Option<String>,
}
fn presentation_version() -> u32 { 1 }
impl ElementPresentation {
    pub fn is_valid(&self) -> bool {
        let tag = |s: &str| !s.is_empty() && s.len() <= 64
            && s.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"-._".contains(&b));
        let text = |s: &Option<String>, limit: usize| s.as_ref().is_none_or(|s|
            s.chars().count() <= limit && !s.chars().any(char::is_control));
        self.schema_version == 1 && self.action_id.as_deref().is_none_or(tag)
            && self.purpose_id.as_deref().is_none_or(tag)
            && self.group_ids.len() <= 16 && self.group_ids.iter().all(|s| tag(s))
            && self.group_ids.iter().collect::<std::collections::HashSet<_>>().len() == self.group_ids.len()
            && text(&self.legend, 64) && text(&self.caption, 128) && text(&self.accessibility_name, 128)
            && self.accessibility_name.as_ref().is_none_or(|s| !s.trim().is_empty())
    }
}

/// Reject slot-based schemas at every import/persistence boundary. Identity
/// fields are never inferred, remapped, or recovered from labels.
pub fn validate_element_identities(profile: &Value) -> bool {
    if !profile.get("customization").is_some_and(Value::is_object) {
        return false;
    }
    for name in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
        "skinBaselineCustomization",
        "landscapeSkinBaselineCustomization",
        "portraitSkinBaselineCustomization",
    ] {
        let Some(customization) = profile.get(name).filter(|value| !value.is_null()) else {
            continue;
        };
        if !customization.is_object()
            || customization
                .get("elements")
                .is_none_or(|value| !value.is_array())
        {
            return false;
        }
        let Some(elements) = customization.get("elements").and_then(Value::as_array) else {
            return false;
        };
        if elements.len() > 128 {
            return false;
        }
        for (kind, limit) in [("joystick", 2), ("trigger", 2), ("trackpad", 1)] {
            if elements
                .iter()
                .filter(|element| element.get("kind").and_then(Value::as_str) == Some(kind))
                .count()
                > limit
            {
                return false;
            }
        }
        let declared_ids: std::collections::BTreeSet<_> = elements
            .iter()
            .filter_map(|element| {
                element
                    .get("id")
                    .and_then(Value::as_str)
                    .and_then(KeypadElementID::parse)
            })
            .collect();
        for field in ["buttonCustomizations", "labelOverrides"] {
            if let Some(value) = customization.get(field).filter(|value| !value.is_null()) {
                let Some(keys) = uuid_map_keys(value) else {
                    return false;
                };
                if !keys.is_subset(&declared_ids) {
                    return false;
                }
            }
        }
        for field in ["elements", "customButtons"] {
            let Some(value) = customization.get(field) else {
                continue;
            };
            let Some(controls) = value.as_array() else {
                return false;
            };
            let mut identities = std::collections::BTreeSet::new();
            for element in controls {
                let Some(object) = element.as_object() else {
                    return false;
                };
                if let Some(presentation) = object.get("presentation").filter(|v| !v.is_null()) {
                    if !serde_json::from_value::<ElementPresentation>(presentation.clone()).is_ok_and(|p| p.is_valid()) {
                        return false;
                    }
                }
                let Some(id) = element
                    .get("id")
                    .and_then(Value::as_str)
                    .and_then(KeypadElementID::parse)
                else {
                    return false;
                };
                let kind_field = if field == "elements" {
                    "kind"
                } else {
                    "controlKind"
                };
                let Some(kind) = control_kind(element, kind_field) else {
                    return false;
                };
                if !identities.insert(id)
                    || (field == "customButtons"
                        && !elements.iter().any(|declared| {
                            declared
                                .get("id")
                                .and_then(Value::as_str)
                                .and_then(KeypadElementID::parse)
                                == Some(id)
                                && control_kind(declared, "kind") == Some(kind)
                        }))
                    || [
                        "button",
                        "mappedButton",
                        "builtInButton",
                        "legacySlot",
                        "inputID",
                        "defaultControlID",
                    ]
                    .iter()
                    .any(|key| object.contains_key(*key))
                {
                    return false;
                }
                if field == "customButtons" {
                    let declared = elements
                        .iter()
                        .find(|declared| {
                            declared
                                .get("id")
                                .and_then(Value::as_str)
                                .and_then(KeypadElementID::parse)
                                == Some(id)
                        })
                        .unwrap();
                    if !mirror_settings_match_declaration(element, declared) {
                        return false;
                    }
                }
                if let Some(mapping) = element
                    .get("joystickMapping")
                    .filter(|value| !value.is_null())
                {
                    let Some(mapping) = mapping.as_object() else {
                        return false;
                    };
                    if mapping.len() != 4
                        || ["up", "down", "left", "right"].iter().any(|direction| {
                            mapping
                                .get(*direction)
                                .is_none_or(|value| !valid_output(value))
                        })
                    {
                        return false;
                    }
                }
                if let Some(parts) = element.get("partOutputs").filter(|value| !value.is_null()) {
                    let valid_part = |key: &Value| {
                        serde_json::from_value::<thumble_protocol::KeypadElementInputPart>(
                            key.clone(),
                        )
                        .is_ok()
                    };
                    let valid = match parts {
                        Value::Object(map) => map.iter().all(|(key, value)| {
                            valid_part(&Value::String(key.clone())) && valid_output(value)
                        }),
                        Value::Array(values) => {
                            let mut identities = std::collections::BTreeSet::new();
                            values.len() % 2 == 0
                                && values.chunks_exact(2).all(|pair| {
                                    valid_part(&pair[0])
                                        && valid_output(&pair[1])
                                        && identities.insert(pair[0].as_str().unwrap())
                                })
                        }
                        _ => false,
                    };
                    if !valid {
                        return false;
                    }
                }
                for key in ["output", "defaultOutput"] {
                    if element
                        .get(key)
                        .is_some_and(|value| !value.is_null() && !valid_output(value))
                    {
                        return false;
                    }
                }
            }
        }
        if !valid_design_references(customization, elements) {
            return false;
        }
    }
    true
}

fn mirror_settings_match_declaration(mirror: &Value, declared: &Value) -> bool {
    if let Some(mapping) = mirror
        .get("joystickMapping")
        .filter(|value| !value.is_null())
    {
        if control_kind(declared, "kind") != Some("joystick") {
            return false;
        }
        let Some(owned) = declared
            .get("joystickMapping")
            .filter(|value| !value.is_null())
        else {
            return false;
        };
        for direction in ["up", "down", "left", "right"] {
            let parse = |value: &Value| {
                value
                    .get(direction)
                    .and_then(|value| serde_json::from_value::<OutputBinding>(value.clone()).ok())
            };
            let (Some(actual), Some(expected)) = (parse(mapping), parse(owned)) else {
                return false;
            };
            if actual != expected {
                return false;
            }
        }
    }
    for (field, kind) in [
        ("joystickOutputSettings", "joystick"),
        ("triggerSettings", "trigger"),
        ("trackpadSettings", "trackpad"),
    ] {
        let Some(value) = mirror.get(field).filter(|value| !value.is_null()) else {
            continue;
        };
        if control_kind(declared, "kind") != Some(kind) {
            continue;
        }
        let (Some(actual), Some(expected)) = (
            normalized_settings(field, Some(value)),
            normalized_settings(field, declared.get(field)),
        ) else {
            return false;
        };
        if actual != expected {
            return false;
        }
    }
    true
}

fn normalized_settings(field: &str, value: Option<&Value>) -> Option<Value> {
    let mut defaults = match field {
        "joystickOutputSettings" => {
            serde_json::json!({"analogTarget":"none","sendsDigitalDirections":true,"deadZone":0.12,"sensitivity":1.0,"invertX":false,"invertY":false,"snapToCardinal":false})
        }
        "triggerSettings" => {
            serde_json::json!({"target":"right","orientation":"vertical","deadZone":0.03,"sensitivity":1.0,"sendsDigitalButton":false,"digitalThreshold":0.5})
        }
        "trackpadSettings" => {
            serde_json::json!({"sensitivity":1.2,"scrollSensitivity":0.85,"naturalScrolling":true,"tapToClick":true,"twoFingerScroll":true})
        }
        _ => return None,
    };
    if let Some(value) = value.filter(|value| !value.is_null()) {
        let object = value.as_object()?;
        for (key, default) in defaults.as_object_mut()? {
            let value = object.get(key)?;
            *default = if default.is_boolean() {
                Value::Bool(value.as_bool()?)
            } else if default.is_number() {
                let (lower, upper) = match key.as_str() {
                    "deadZone" => (0.0, 0.85),
                    "digitalThreshold" => (0.01, 1.0),
                    "scrollSensitivity" => (0.1, 4.0),
                    "sensitivity" if field == "trackpadSettings" => (0.2, 4.0),
                    "sensitivity" => (0.2, 3.0),
                    _ => return None,
                };
                Value::from(value.as_f64()?.clamp(lower, upper))
            } else {
                let allowed: &[&str] = match key.as_str() {
                    "analogTarget" => &["none", "left_stick", "right_stick"],
                    "target" => &["left", "right"],
                    "orientation" => &["vertical", "horizontal"],
                    _ => return None,
                };
                let text = value.as_str()?;
                if !allowed.contains(&text) {
                    return None;
                }
                Value::String(text.to_owned())
            };
        }
    }
    if field == "joystickOutputSettings" && defaults["analogTarget"] == "none" {
        defaults["sendsDigitalDirections"] = Value::Bool(true);
    }
    Some(defaults)
}

fn control_kind<'a>(element: &'a Value, field: &str) -> Option<&'a str> {
    let kind = match element.get(field).filter(|value| !value.is_null()) {
        Some(value) => value.as_str()?,
        None => "button",
    };
    [
        "button",
        "joystick",
        "trigger",
        "trackpad",
        "text",
        "decoration",
    ]
    .contains(&kind)
    .then_some(kind)
}

fn uuid_map_keys(value: &Value) -> Option<std::collections::BTreeSet<KeypadElementID>> {
    let keys: Vec<&str> = match value {
        Value::Object(map) => map.keys().map(String::as_str).collect(),
        Value::Array(values) if values.len() % 2 == 0 => values
            .chunks_exact(2)
            .map(|pair| pair[0].as_str())
            .collect::<Option<_>>()?,
        _ => return None,
    };
    let mut identities = std::collections::BTreeSet::new();
    for key in keys {
        if !identities.insert(KeypadElementID::parse(key)?) {
            return None;
        }
    }
    Some(identities)
}

fn valid_design_references(customization: &Value, elements: &[Value]) -> bool {
    let Some(metadata) = customization
        .get("designMetadata")
        .filter(|value| !value.is_null())
    else {
        return true;
    };
    if !metadata.is_object() {
        return false;
    }
    let mut available = std::collections::BTreeSet::from(["system.top_bar_activation".to_owned()]);
    for element in elements {
        let Some(id) = element
            .get("id")
            .and_then(Value::as_str)
            .and_then(KeypadElementID::parse)
        else {
            return false;
        };
        let builtin = control_kind(element, "kind") == Some("button")
            && (1..=10).any(|number| KeypadElementID::preset(number) == id);
        available.insert(format!(
            "{}.{id}",
            if builtin { "builtin" } else { "custom" }
        ));
    }
    let valid_controls = |value: &Value| {
        let Some(controls) = value.as_array() else {
            return false;
        };
        let mut seen = std::collections::BTreeSet::new();
        controls.iter().all(|control| {
            design_identity(control)
                .is_some_and(|identity| available.contains(&identity) && seen.insert(identity))
        })
    };
    if metadata
        .get("layerOrder")
        .is_some_and(|order| !valid_controls(order))
    {
        return false;
    }
    if let Some(groups) = metadata.get("groups") {
        let Some(groups) = groups.as_array() else {
            return false;
        };
        let mut seen = std::collections::BTreeSet::new();
        for group in groups {
            let Some(id) = group
                .get("id")
                .and_then(Value::as_str)
                .and_then(KeypadElementID::parse)
            else {
                return false;
            };
            if !seen.insert(id)
                || group
                    .get("children")
                    .is_none_or(|children| !valid_controls(children))
            {
                return false;
            }
        }
    }
    true
}

fn design_identity(value: &Value) -> Option<String> {
    let (kind, raw) = if let Some(raw) = value.as_str() {
        if let Some(pair) = raw.split_once('.') {
            pair
        } else if raw == "top_bar_activation" {
            ("system", raw)
        } else {
            ("builtin", raw)
        }
    } else {
        let kind = value.get("kind")?.as_str()?;
        let field = match kind {
            "builtin" => "button",
            "custom" => "id",
            "system" => "system",
            _ => return None,
        };
        let raw = value
            .get(field)
            .or_else(|| (kind == "system").then(|| value.get("id")).flatten())?
            .as_str()?;
        (kind, raw)
    };
    match kind {
        "builtin" | "custom" => Some(format!("{kind}.{}", KeypadElementID::parse(raw)?)),
        "system" if raw == "top_bar_activation" => Some("system.top_bar_activation".to_owned()),
        _ => None,
    }
}

fn valid_output(value: &Value) -> bool {
    value.is_object() && serde_json::from_value::<OutputBinding>(value.clone()).is_ok()
}

/// Configured bindings (or an owned default when absent) come only from declared controls.
pub fn profile_owned_outputs(profile: &Value) -> ButtonBindings<OutputBinding> {
    profile_element_outputs(profile, "output", true)
}

/// Explicit owned configurations, including clears, override stale sidecar mirrors.
pub fn profile_configured_outputs(profile: &Value) -> ButtonBindings<OutputBinding> {
    profile_element_outputs(profile, "output", false)
}

/// An explicit reset restores declared defaults, not the currently configured output.
pub fn profile_default_outputs(profile: &Value) -> ButtonBindings<OutputBinding> {
    profile_element_outputs(profile, "defaultOutput", false)
}

fn profile_element_outputs(
    profile: &Value,
    field: &str,
    default_fallback: bool,
) -> ButtonBindings<OutputBinding> {
    let mut outputs = ButtonBindings::default();
    for name in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let Some(elements) = profile
            .get(name)
            .and_then(|value| value.get("elements"))
            .and_then(Value::as_array)
        else {
            continue;
        };
        for element in elements {
            let Some(id) = element
                .get("id")
                .and_then(Value::as_str)
                .and_then(KeypadElementID::parse)
            else {
                continue;
            };
            let value = element
                .get(field)
                .filter(|value| !value.is_null())
                .or_else(|| {
                    default_fallback
                        .then(|| element.get("defaultOutput"))
                        .flatten()
                });
            let Some(value) = value.filter(|value| !value.is_null()) else {
                continue;
            };
            if outputs.get(&id).is_none() {
                if let Ok(output) = serde_json::from_value(value.clone()) {
                    outputs.insert(id, output);
                }
            }
        }
    }
    outputs
}

#[cfg(test)]
mod presentation_regression_tests {
    use super::*;
    #[test]
    fn persistent_presentation_validates_at_import_and_keeps_acronym_wire_fields() {
        let metadata = serde_json::json!({"actionID":"ability.q","purposeID":"primary","groupIDs":["abilities"],
            "legend":"Q","caption":"Light Binding","accessibilityName":"Cast Light Binding"});
        let parsed: ElementPresentation = serde_json::from_value(metadata.clone()).unwrap();
        assert!(parsed.is_valid());
        let wire = serde_json::to_value(parsed).unwrap();
        assert_eq!(wire["actionID"], "ability.q");
        assert_eq!(wire["groupIDs"], serde_json::json!(["abilities"]));
        let mut profile = serde_json::json!({"customization":{"elements":[{"id":"b6fd297d-7508-4ff4-aff7-97b3831f6ad0",
            "kind":"button","label":"Legacy","presentation":metadata}]}});
        assert!(validate_element_identities(&profile));
        for invalid in [serde_json::json!({"schemaVersion":2}), serde_json::json!({"actionID":"Q"}),
            serde_json::json!({"actionId":"ability.q"}), serde_json::json!({"groupIDs":["a","a"]}),
            serde_json::json!({"legend":"x".repeat(65)}), serde_json::json!({"caption":"line\nbreak"}),
            serde_json::json!({"accessibilityName":" "}), serde_json::json!({"legend":"Q","output":{}})] {
            profile["customization"]["elements"][0]["presentation"] = invalid;
            assert!(!validate_element_identities(&profile));
        }
    }
}
