use crate::{packet_runtime::saved_profile, runtime};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeSet;
pub(super) const FRAME_BYTES: usize = 65_536;
pub(super) fn error(value: &str) -> bool {
    matches!(
        value,
        "saved_map_busy"
            | "saved_map_timeout"
            | "saved_map_unavailable"
            | "saved_map_reactivation_required"
            | "saved_map_unsupported_profile"
            | "saved_map_response_too_large"
    )
}
pub(super) fn hash(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
/// Nonnegative JSON-number text, deliberately matching the independent SDKs.
pub(super) fn number(value: &str) -> Option<f64> {
    let b = value.as_bytes();
    if b.is_empty() || b.len() > 32 {
        return None;
    }
    let mut at = 0;
    if b[0] == b'0' {
        at += 1;
    } else if (b'1'..=b'9').contains(&b[0]) {
        while at < b.len() && b[at].is_ascii_digit() {
            at += 1;
        }
    } else {
        return None;
    }
    if b.get(at) == Some(&b'.') {
        at += 1;
        let start = at;
        while at < b.len() && b[at].is_ascii_digit() {
            at += 1;
        }
        if start == at {
            return None;
        }
    }
    if b.get(at) == Some(&b'e') {
        at += 1;
        if matches!(b.get(at), Some(b'+' | b'-')) {
            at += 1;
        }
        let start = at;
        while at < b.len() && b[at].is_ascii_digit() {
            at += 1;
        }
        if start == at {
            return None;
        }
    }
    if at != b.len() {
        return None;
    }
    value
        .parse::<f64>()
        .ok()
        .filter(|v| v.is_finite() && *v >= 0.0)
}
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct Request {
    pub version: u8,
    pub command: String,
    pub connection_id: String,
    pub expected_configuration_revision: String,
    pub expected_source_hash: String,
    pub profile_id: String,
    pub generation: String,
    pub revision: String,
    pub viewport_width: String,
    pub viewport_height: String,
}
impl Request {
    pub fn valid(&self, connection: &str) -> bool {
        self.version == 1
            && self.command == "configuration-controls"
            && self.connection_id == connection
            && runtime::decimal(&self.expected_configuration_revision).is_ok_and(|n| n > 0)
            && hash(&self.expected_source_hash)
            && saved_profile(&self.profile_id)
            && runtime::decimal(&self.generation).is_ok_and(|n| n > 0)
            && runtime::decimal(&self.revision).is_ok()
            && number(&self.viewport_width)
                .zip(number(&self.viewport_height))
                .is_some_and(|(w, h)| h >= 240.0 && w >= h && w <= 4096.0 && h <= 4096.0)
    }
}
/// Dedicated management result codec; catalog's 64-key codec remains unchanged.
#[derive(Debug)]
pub(super) struct Scalars(pub Value);
impl<'de> Deserialize<'de> for Scalars {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Object;
        impl<'de> serde::de::Visitor<'de> for Object {
            type Value = Scalars;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a unique bounded scalar controls object")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut map: M,
            ) -> Result<Scalars, M::Error> {
                let mut values = Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if values.len() >= 845 || key.len() > 64 || values.contains_key(&key) {
                        return Err(serde::de::Error::custom(
                            "duplicate or excess controls field",
                        ));
                    }
                    #[derive(Deserialize)]
                    #[serde(untagged)]
                    enum Scalar {
                        Text(String),
                        Count(u64),
                    }
                    let value = match map.next_value::<Scalar>()? {
                        Scalar::Text(s) => Value::String(s),
                        Scalar::Count(n) => Value::from(n),
                    };
                    values.insert(key, value);
                }
                Ok(Scalars(Value::Object(values)))
            }
        }
        d.deserialize_map(Object)
    }
}
fn text<'a>(row: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    row.get(key)?.as_str()
}
fn numeric(row: &Map<String, Value>, key: &str) -> Option<f64> {
    number(text(row, key)?)
}
pub(super) fn result(value: &Value, request: &Request, authority: &str) -> bool {
    let Some(row) = value.as_object() else {
        return false;
    };
    if !serde_json::to_vec(value).is_ok_and(|bytes| bytes.len() <= FRAME_BYTES - 512) {
        return false;
    }

    if text(row, "kind") == Some("error") {
        return row.len() == 2 && text(row, "error").is_some_and(error);
    }
    let pairs = [
        ("kind", "controls"),
        ("authorityInstanceId", authority),
        (
            "configurationRevision",
            request.expected_configuration_revision.as_str(),
        ),
        ("sourceHash", request.expected_source_hash.as_str()),
        ("profileId", request.profile_id.as_str()),
        ("generation", request.generation.as_str()),
        ("revision", request.revision.as_str()),
        ("viewportWidth", request.viewport_width.as_str()),
        ("viewportHeight", request.viewport_height.as_str()),
    ];
    if pairs.iter().any(|(k, v)| text(row, k) != Some(*v))
        || !text(row, "configurationSha256").is_some_and(hash)
    {
        return false;
    }
    let Some(count) = row
        .get("controlCount")
        .and_then(Value::as_u64)
        .filter(|n| (1..=64).contains(n))
    else {
        return false;
    };
    let mut keys: BTreeSet<String> = pairs
        .iter()
        .map(|(k, _)| (*k).into())
        .chain(["configurationSha256".into(), "controlCount".into()])
        .collect();
    let mut ids = BTreeSet::new();
    for index in 0..count {
        let prefix = format!("control{index}");
        for suffix in ["Id", "Action", "X", "Y", "Width", "Height"] {
            keys.insert(format!("{prefix}{suffix}"));
        }
        let Some(id) = text(row, &format!("{prefix}Id")).filter(|id| runtime::identity(id)) else {
            return false;
        };
        if !ids.insert(id) {
            return false;
        }
        let Some(action) = text(row, &format!("{prefix}Action")) else {
            return false;
        };
        if !matches!(
            action,
            "leftStick" | "rightStick" | "leftTrigger" | "rightTrigger"
        ) && serde_json::from_value::<crate::generated::GamepadButton>(Value::String(
            action.into(),
        ))
        .is_err()
        {
            return false;
        }
        let Some((x, y, w, h)) = numeric(row, &format!("{prefix}X"))
            .zip(numeric(row, &format!("{prefix}Y")))
            .zip(numeric(row, &format!("{prefix}Width")))
            .zip(numeric(row, &format!("{prefix}Height")))
            .map(|(((x, y), w), h)| (x, y, w, h))
        else {
            return false;
        };
        if w < 0.001 || h < 0.001 || x + w > 1.0 || y + h > 1.0 {
            return false;
        }
        let haptic: [String; 5] = ["Style", "Pattern", "Intensity", "Sharpness", "Duration"]
            .map(|s| format!("{prefix}Haptic{s}"));
        if haptic.iter().any(|k| row.contains_key(k)) {
            keys.extend(haptic.iter().cloned());
            if !matches!(
                text(row, &haptic[0]),
                Some("none" | "light" | "medium" | "heavy" | "soft" | "rigid")
            ) || !matches!(
                text(row, &haptic[1]),
                Some("single" | "double" | "pulse" | "buzz")
            ) {
                return false;
            }
            let Some((i, s, d)) = numeric(row, &haptic[2])
                .zip(numeric(row, &haptic[3]))
                .zip(numeric(row, &haptic[4]))
                .map(|((i, s), d)| (i, s, d))
            else {
                return false;
            };
            if i > 1.0 || s > 1.0 || !(0.02..=0.30).contains(&d) {
                return false;
            }
        }
    }
    row.len() <= 845 && row.len() == keys.len() && row.keys().all(|k| keys.contains(k))
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../packages/fixtures/saved-controller-control-v8.json"
        ))
        .unwrap()
    }
    fn request() -> Request {
        serde_json::from_value(fixture()["request"].clone()).unwrap()
    }
    fn reply() -> Value {
        let mut value = fixture()["reply"].clone();
        for key in ["version", "command", "connectionId"] {
            value.as_object_mut().unwrap().remove(key);
        }
        value
    }
    #[test]
    fn shared_fixture_and_all_fixed_errors_match_strict_sdk_contract() {
        let request = request();
        assert!(request.valid(&request.connection_id));
        assert!(result(&reply(), &request, "synthetic-authority"));
        for error in fixture()["errors"].as_array().unwrap() {
            let mut value = error.clone();
            for key in ["version", "command", "connectionId"] {
                value.as_object_mut().unwrap().remove(key);
            }
            assert!(result(&value, &request, "synthetic-authority"));
        }
        for invalid in [
            "",
            "-0",
            "-1",
            "+1",
            "01",
            "1.",
            ".1",
            "1E0",
            "NaN",
            "Infinity",
            "1e999",
            " 1",
            "1 ",
            "1e",
            "1e+",
            "1".repeat(33).as_str(),
        ] {
            assert!(number(invalid).is_none(), "{invalid}");
        }
        for valid in ["0", "0.0", "1", "0.1", "1e0", "1e-1", "1e+1"] {
            assert!(number(valid).is_some(), "{valid}");
        }
    }
    #[test]
    fn controls_reject_projection_extras_stale_pins_partial_haptics_bad_geometry_and_coercion() {
        let request = request();
        let base = reply();
        for (key, value) in [
            ("sourceHash", Value::from("b".repeat(64))),
            ("viewportWidth", Value::from("874.0")),
            ("generation", Value::from("8")),
            ("configurationSha256", Value::from("A".repeat(64))),
            ("controlCount", Value::from(0)),
            ("controlCount", Value::from(65)),
            ("control1Id", Value::from("synthetic-south")),
            ("control1Width", Value::from("2")),
            ("control1Action", Value::from("system-command")),
            ("control0HapticDuration", Value::from("0.31")),
            ("control0HapticIntensity", Value::from(1)),
            ("token", Value::from("synthetic-secret")),
        ] {
            let mut patched = base.clone();
            patched[key] = value;
            assert!(!result(&patched, &request, "synthetic-authority"), "{key}");
        }
        let mut partial = base.clone();
        partial
            .as_object_mut()
            .unwrap()
            .remove("control0HapticStyle");
        assert!(!result(&partial, &request, "synthetic-authority"));
        for raw in [
            r#"{"kind":"controls","kind":"controls"}"#,
            r#"{"nested":{"secret":"forbidden"}}"#,
            r#"{"array":[]}"#,
            r#"{"boolean":true}"#,
            r#"{"null":null}"#,
        ] {
            assert!(serde_json::from_str::<Scalars>(raw).is_err());
        }
    }
    #[test]
    fn sixty_four_full_haptic_controls_stay_bounded_and_indexed_fields_are_exact() {
        let request = request();
        let base = reply();
        let mut value = base.clone();
        value
            .as_object_mut()
            .unwrap()
            .retain(|key, _| !key.starts_with("control") || key == "controlCount");
        value["controlCount"] = Value::from(64);
        for index in 0..64 {
            for suffix in [
                "Id",
                "Action",
                "X",
                "Y",
                "Width",
                "Height",
                "HapticStyle",
                "HapticPattern",
                "HapticIntensity",
                "HapticSharpness",
                "HapticDuration",
            ] {
                value[format!("control{index}{suffix}")] =
                    base[format!("control0{suffix}")].clone();
            }
            value[format!("control{index}Id")] = Value::from(format!("control-{index}"));
        }
        assert!(result(&value, &request, "synthetic-authority"));
        let bytes = serde_json::to_vec(&value).unwrap();
        assert!(bytes.len() < FRAME_BYTES - 512);
        assert!(serde_json::from_slice::<Scalars>(&bytes).is_ok());
        value["control64Id"] = Value::from("outside-index");
        assert!(!result(&value, &request, "synthetic-authority"));
    }
}
