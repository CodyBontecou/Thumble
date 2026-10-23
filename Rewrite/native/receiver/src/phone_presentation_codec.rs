use super::Protocol;
use crate::{packet_runtime::saved_profile, runtime};
use serde::Deserialize;
use serde_json::{Map, Value};
use std::collections::BTreeSet;
pub(super) const FRAME_BYTES: usize = 32_768;
pub(super) const BASE: [&str; 10] = [
    "authorityInstanceId",
    "expectedConfigurationRevision",
    "expectedSourceHash",
    "profileId",
    "generation",
    "revision",
    "viewportWidth",
    "viewportHeight",
    "configurationSha256",
    "colorScheme",
];
const ICON: [&str; 4] = [
    "presentationRevision",
    "presentationSourceHash",
    "controlId",
    "iconSHA256",
];
pub(super) fn error(v: &str) -> bool {
    matches!(
        v,
        "presentation_busy"
            | "presentation_timeout"
            | "presentation_unavailable"
            | "presentation_reactivation_required"
            | "presentation_unsupported_profile"
            | "presentation_response_too_large"
            | "presentation_stale"
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
/// Dedicated management result codec; catalog's 64-key codec remains unchanged.
#[derive(Debug)]
pub(super) struct Scalars(pub Value);
impl<'de> Deserialize<'de> for Scalars {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        struct Object;
        impl<'de> serde::de::Visitor<'de> for Object {
            type Value = Scalars;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("a unique bounded scalar presentation object")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut map: M,
            ) -> Result<Scalars, M::Error> {
                let mut values = Map::new();
                while let Some(key) = map.next_key::<String>()? {
                    if values.len() >= 384 || key.len() > 64 || values.contains_key(&key) {
                        return Err(serde::de::Error::custom(
                            "duplicate or excess presentation field",
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
fn positive(v: Option<&str>) -> bool {
    v.is_some_and(|v| runtime::decimal(v).is_ok_and(|n| n > 0))
}
fn label(v: Option<&str>) -> bool {
    v.is_some_and(|v| v.len() <= 128)
}
#[derive(Clone)]
pub(super) struct Request {
    pub row: Map<String, Value>,
    protocol: Protocol,
}
impl Request {
    pub fn text(&self, k: &str) -> &str {
        self.row.get(k).and_then(Value::as_str).unwrap_or("")
    }
    pub fn icon(&self) -> bool {
        self.text("command") == "configuration-presentation-icon"
    }
    fn bank(&self) -> &str {
        if self.protocol == Protocol::BanksV2 {
            self.text("bank")
        } else {
            "base"
        }
    }
    pub fn parse(bytes: &[u8], connection: &str, protocol: Protocol) -> Result<Self, &'static str> {
        if bytes.len() > 2048 {
            return Err("presentation_request_invalid");
        }
        let Scalars(v) =
            serde_json::from_slice(bytes).map_err(|_| "presentation_request_invalid")?;
        let row = v
            .as_object()
            .cloned()
            .ok_or("presentation_request_invalid")?;
        let r = Self { row, protocol };
        let mut keys: BTreeSet<&str> = BASE
            .into_iter()
            .filter(|k| *k != "authorityInstanceId")
            .chain(["version", "command", "connectionId"])
            .collect();
        if protocol == Protocol::BanksV2 {
            keys.insert("bank");
        }
        if r.icon() {
            keys.extend(ICON)
        }
        if r.row.len() != keys.len()
            || keys.iter().any(|k| !r.row.contains_key(*k))
            || r.row.get("version").and_then(Value::as_u64) != Some(protocol.wire_version().into())
            || (protocol == Protocol::BanksV2
                && !matches!(
                    r.bank(),
                    "base" | "left-trigger" | "right-trigger" | "both-triggers"
                ))
            || !matches!(
                r.text("command"),
                "configuration-presentation" | "configuration-presentation-icon"
            )
            || r.text("connectionId") != connection
            || !positive(Some(r.text("expectedConfigurationRevision")))
            || !hash(r.text("expectedSourceHash"))
            || !saved_profile(r.text("profileId"))
            || !positive(Some(r.text("generation")))
            || runtime::decimal(r.text("revision")).is_err()
            || !hash(r.text("configurationSha256"))
            || !matches!(r.text("colorScheme"), "light" | "dark")
            || !number(r.text("viewportWidth"))
                .zip(number(r.text("viewportHeight")))
                .is_some_and(|(w, h)| h >= 240.0 && w >= h && w <= 4096.0 && h <= 4096.0)
        {
            return Err("presentation_request_invalid");
        }
        if r.icon()
            && (!positive(Some(r.text("presentationRevision")))
                || !hash(r.text("presentationSourceHash"))
                || !runtime::identity(r.text("controlId"))
                || !hash(r.text("iconSHA256"))
                || runtime::decimal(r.text("presentationRevision")).unwrap()
                    < runtime::decimal(r.text("expectedConfigurationRevision")).unwrap())
        {
            return Err("presentation_request_invalid");
        }
        Ok(r)
    }
    pub fn event(&self, authority: &str, id: &str) -> Value {
        let mut row = self.row.clone();
        for k in ["command", "connectionId"] {
            row.remove(k);
        }
        row.insert("event".into(), Value::String("phone-presentation".into()));
        row.insert("eventId".into(), Value::String(id.into()));
        row.insert(
            "authorityInstanceId".into(),
            Value::String(authority.into()),
        );
        row.insert(
            "kind".into(),
            Value::String(if self.icon() { "icon" } else { "metadata" }.into()),
        );
        Value::Object(row)
    }
}
pub(super) fn icon_bytes(v: &str) -> Option<Vec<u8>> {
    if v.is_empty() || v.len() > 10924 || v.len() % 4 != 0 {
        return None;
    }
    let b = v.as_bytes();
    let pad = if v.ends_with("==") {
        2
    } else if v.ends_with('=') {
        1
    } else {
        0
    };
    let size = v.len() / 4 * 3 - pad;
    if size > 8192 {
        return None;
    }
    let abc = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::with_capacity(size);
    for i in (0..b.len()).step_by(4) {
        let a = abc.iter().position(|n| *n == b[i])? as u32;
        let bb = abc.iter().position(|n| *n == b[i + 1])? as u32;
        let c = if i + 2 >= b.len() - pad {
            0
        } else {
            abc.iter().position(|n| *n == b[i + 2])? as u32
        };
        let d = if i + 3 >= b.len() - pad {
            0
        } else {
            abc.iter().position(|n| *n == b[i + 3])? as u32
        };
        if i + 4 == b.len() && ((pad == 2 && bb & 15 != 0) || (pad == 1 && c & 3 != 0)) {
            return None;
        }
        let word = (a << 18) | (bb << 12) | (c << 6) | d;
        for shift in [16, 8, 0] {
            if out.len() < size {
                out.push((word >> shift) as u8)
            }
        }
    }
    if out.len() < 33
        || out[..8] != [137, 80, 78, 71, 13, 10, 26, 10]
        || out[8..16] != [0, 0, 0, 13, 73, 72, 68, 82]
        || out[16..24] != [0, 0, 0, 32, 0, 0, 0, 32]
    {
        return None;
    }
    Some(out)
}
pub(super) fn result(value: &Value, r: &Request, authority: &str) -> bool {
    let Some(row) = value.as_object() else {
        return false;
    };
    let limit = if r.icon() { 16384 } else { FRAME_BYTES };
    if !serde_json::to_vec(value).is_ok_and(|b| b.len() <= limit - 512) {
        return false;
    }
    if text(row, "kind") == Some("error") {
        return row.len() == 2 && text(row, "error").is_some_and(error);
    }
    if text(row, "kind") != Some(if r.icon() { "icon" } else { "presentation" }) {
        return false;
    }
    for k in BASE {
        let expected = if k == "authorityInstanceId" {
            authority
        } else {
            r.text(k)
        };
        if text(row, k) != Some(expected) {
            return false;
        }
    }
    let mut keys: BTreeSet<String> = BASE
        .into_iter()
        .map(str::to_owned)
        .chain(["kind".into()])
        .collect();
    if r.protocol == Protocol::BanksV2 {
        keys.insert("bank".into());
        if text(row, "bank") != Some(r.bank()) {
            return false;
        }
    }
    if r.icon() {
        for k in ICON {
            if text(row, k) != Some(r.text(k)) {
                return false;
            }
            keys.insert(k.into());
        }
        keys.extend(["byteCount".into(), "pngBase64".into()]);
        let Some(bytes) = text(row, "pngBase64").and_then(icon_bytes) else {
            return false;
        };
        if row.get("byteCount").and_then(Value::as_u64) != Some(bytes.len() as u64)
            || super::hex(ring::digest::digest(&ring::digest::SHA256, &bytes).as_ref())
                != r.text("iconSHA256")
        {
            return false;
        }
    } else {
        keys.extend(
            [
                "bank",
                "profileName",
                "presentationRevision",
                "presentationSourceHash",
                "freshness",
                "controlCount",
            ]
            .map(str::to_owned),
        );
        if text(row, "bank") != Some(r.bank())
            || !label(text(row, "profileName"))
            || !positive(text(row, "presentationRevision"))
            || !text(row, "presentationSourceHash").is_some_and(hash)
            || !matches!(
                text(row, "freshness"),
                Some("observed" | "stale" | "not-evaluated")
            )
            || runtime::decimal(text(row, "presentationRevision").unwrap()).unwrap()
                < runtime::decimal(r.text("expectedConfigurationRevision")).unwrap()
        {
            return false;
        }
        let Some(count) = row
            .get("controlCount")
            .and_then(Value::as_u64)
            .filter(|v| (1..=64).contains(v))
        else {
            return false;
        };
        let mut ids = BTreeSet::new();
        for i in 0..count {
            let p = format!("control{i}");
            let id = format!("{p}Id");
            let l = format!("{p}Label");
            let Some(v) = text(row, &id).filter(|v| runtime::identity(v)) else {
                return false;
            };
            if !ids.insert(v) || !label(text(row, &l)) {
                return false;
            }
            keys.extend([id, l]);
            let icon = [
                format!("{p}IconSHA256"),
                format!("{p}IconByteCount"),
                format!("{p}IconName"),
            ];
            if icon.iter().any(|k| row.contains_key(k)) {
                if !text(row, &icon[0]).is_some_and(hash)
                    || !label(text(row, &icon[2]))
                    || !row
                        .get(&icon[1])
                        .and_then(Value::as_u64)
                        .is_some_and(|n| (1..=8192).contains(&n))
                {
                    return false;
                }
                keys.extend(icon);
            }
        }
    }
    row.len() == keys.len() && keys.iter().all(|k| row.contains_key(k))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../packages/fixtures/saved-controller-presentation-control-v10.json"
        ))
        .unwrap()
    }
    fn request(icon: bool) -> Request {
        let f = fixture();
        Request::parse(
            &serde_json::to_vec(&f[if icon { "iconRequest" } else { "request" }]).unwrap(),
            "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
            Protocol::BaseV1,
        )
        .unwrap()
    }
    fn reply(icon: bool) -> Value {
        let mut v = fixture()[if icon { "iconReply" } else { "reply" }].clone();
        for k in ["version", "command", "connectionId"] {
            v.as_object_mut().unwrap().remove(k);
        }
        v
    }
    #[test]
    fn shared_scalar_fixture_and_icon_digest_are_exact() {
        for icon in [false, true] {
            assert!(result(&reply(icon), &request(icon), "synthetic-authority"));
        }
        let mut v = reply(true);
        let bytes = icon_bytes(v["pngBase64"].as_str().unwrap()).unwrap();
        assert_eq!(bytes.len() as u64, v["byteCount"].as_u64().unwrap());
        v["iconSHA256"] = json!("d".repeat(64));
        assert!(!result(&v, &request(true), "synthetic-authority"));
    }
    #[test]
    fn shared_banked_fixture_covers_all_banks_and_themes() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../packages/fixtures/saved-controller-presentation-control-v11.json"
        ))
        .unwrap();
        let variants = fixture["variants"].as_array().unwrap();
        assert_eq!(variants.len(), 8);
        let mut scopes = std::collections::BTreeSet::new();
        for variant in variants {
            for icon in [false, true] {
                let wire = &variant[if icon { "iconRequest" } else { "request" }];
                let request = Request::parse(
                    &serde_json::to_vec(wire).unwrap(),
                    "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                    Protocol::BanksV2,
                )
                .unwrap();
                let mut reply = variant[if icon { "iconReply" } else { "reply" }].clone();
                for key in ["version", "command", "connectionId"] {
                    reply.as_object_mut().unwrap().remove(key);
                }
                assert!(result(&reply, &request, "synthetic-authority"));
                assert!(Request::parse(
                    &serde_json::to_vec(wire).unwrap(),
                    "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                    Protocol::BaseV1,
                )
                .is_err());
            }
            scopes.insert((
                variant["request"]["bank"].as_str().unwrap(),
                variant["request"]["colorScheme"].as_str().unwrap(),
            ));
        }
        assert_eq!(scopes.len(), 8);
    }
    #[test]
    fn strict_request_rejects_null_icon_fields_duplicates_unknowns_and_noncanonical_pins() {
        let f = fixture();
        for (key, value) in [
            ("generation", json!("0")),
            ("revision", json!("02")),
            ("colorScheme", json!("system")),
            ("configurationSha256", json!("A".repeat(64))),
            ("presentationRevision", Value::Null),
            ("extra", json!(1)),
        ] {
            let mut v = f["request"].clone();
            v[key] = value;
            assert!(Request::parse(
                &serde_json::to_vec(&v).unwrap(),
                "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                Protocol::BaseV1
            )
            .is_err());
        }
        let text =
            serde_json::to_string(&f["request"])
                .unwrap()
                .replacen("{", "{\"version\":1,", 1);
        assert!(Request::parse(
            text.as_bytes(),
            "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
            Protocol::BaseV1
        )
        .is_err());
        let mut v = f["iconRequest"].clone();
        v["presentationRevision"] = json!("2");
        assert!(Request::parse(
            &serde_json::to_vec(&v).unwrap(),
            "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
            Protocol::BaseV1
        )
        .is_err());
    }
    #[test]
    fn malformed_parent_scalars_and_partial_icons_fail_without_widening_other_codecs() {
        for text in [
            "{\"kind\":\"presentation\",\"kind\":\"icon\"}",
            "{\"kind\":{}}",
            "{\"controlCount\":1.0}",
            "{\"controlCount\":true}",
        ] {
            assert!(serde_json::from_str::<Scalars>(text).is_err());
        }
        for (key, value) in [
            ("control0Label", json!("🙂".repeat(33))),
            ("control0IconName", Value::Null),
            ("control0IconByteCount", json!(8193)),
            ("bank", json!("lt")),
            ("freshness", json!("live")),
            ("presentationRevision", json!("2")),
            ("control1Id", json!("synthetic-south")),
            ("control0Action", json!("south")),
        ] {
            let mut v = reply(false);
            v[key] = value;
            assert!(!result(&v, &request(false), "synthetic-authority"));
        }
        let mut v = reply(false);
        v.as_object_mut().unwrap().remove("control0IconName");
        assert!(!result(&v, &request(false), "synthetic-authority"));
        for s in ["", "AA=A", "A===", "AAAA"] {
            assert!(icon_bytes(s).is_none());
        }
    }
    #[test]
    fn banked_protocol_requires_exact_bank_and_negotiated_wire_version() {
        let f = fixture();
        for bank in ["base", "left-trigger", "right-trigger", "both-triggers"] {
            for icon in [false, true] {
                let mut v = f[if icon { "iconRequest" } else { "request" }].clone();
                v["version"] = json!(2);
                v["bank"] = json!(bank);
                let r = Request::parse(
                    &serde_json::to_vec(&v).unwrap(),
                    "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                    Protocol::BanksV2,
                )
                .unwrap();
                let event = r.event("synthetic-authority", "1");
                assert_eq!(event["version"], 2);
                assert_eq!(event["bank"], bank);
                assert!(event.get("presentationProtocol").is_none());
                assert!(Request::parse(
                    &serde_json::to_vec(&v).unwrap(),
                    "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                    Protocol::BaseV1
                )
                .is_err());
                let mut response = reply(icon);
                response["bank"] = json!(bank);
                assert!(result(&response, &r, "synthetic-authority"));
                for bad in [
                    json!("shift"),
                    json!("left_trigger"),
                    json!(""),
                    json!(1),
                    Value::Null,
                ] {
                    let mut bad_request = v.clone();
                    bad_request["bank"] = bad;
                    assert!(Request::parse(
                        &serde_json::to_vec(&bad_request).unwrap(),
                        "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                        Protocol::BanksV2
                    )
                    .is_err());
                }
                for key in ["bank", "version"] {
                    let mut missing = v.clone();
                    missing.as_object_mut().unwrap().remove(key);
                    assert!(Request::parse(
                        &serde_json::to_vec(&missing).unwrap(),
                        "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                        Protocol::BanksV2
                    )
                    .is_err());
                }
                let mut old = v.clone();
                old["version"] = json!(1);
                assert!(Request::parse(
                    &serde_json::to_vec(&old).unwrap(),
                    "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                    Protocol::BanksV2
                )
                .is_err());
                let mut wrong = response.clone();
                wrong["bank"] = json!(if bank == "base" {
                    "left-trigger"
                } else {
                    "base"
                });
                assert!(!result(&wrong, &r, "synthetic-authority"));
                let mut missing = response.clone();
                missing.as_object_mut().unwrap().remove("bank");
                assert!(!result(&missing, &r, "synthetic-authority"));
                let mut extra = response;
                extra["presentationProtocol"] = json!(2);
                assert!(!result(&extra, &r, "synthetic-authority"));
                let duplicate =
                    serde_json::to_string(&v)
                        .unwrap()
                        .replacen("{", "{\"bank\":\"base\",", 1);
                assert!(Request::parse(
                    duplicate.as_bytes(),
                    "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                    Protocol::BanksV2
                )
                .is_err());
            }
        }
    }
    #[test]
    fn legacy_base_protocol_rejects_bank_in_requests_and_icon_results() {
        let f = fixture();
        for icon in [false, true] {
            let v = f[if icon { "iconRequest" } else { "request" }].clone();
            assert!(Request::parse(
                &serde_json::to_vec(&v).unwrap(),
                "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                Protocol::BanksV2
            )
            .is_err());
            let mut extra = v;
            extra["bank"] = json!("base");
            assert!(Request::parse(
                &serde_json::to_vec(&extra).unwrap(),
                "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd",
                Protocol::BaseV1
            )
            .is_err());
        }
        let mut icon = reply(true);
        icon["bank"] = json!("base");
        assert!(!result(&icon, &request(true), "synthetic-authority"));
        assert!(request(false)
            .event("synthetic-authority", "1")
            .get("bank")
            .is_none());
    }
}
