//! Pure, unregistered phone editor DTO prerequisite. No I/O or write admission.
use serde::de::{DeserializeSeed, Error, MapAccess, SeqAccess, Visitor};
use serde_json::{Map, Value};
use std::{collections::BTreeSet, fmt};
pub const REQUEST_BYTES: usize = 2048;
pub const REPLY_BYTES: usize = 16384;
const INVALID: &str = "editor_invalid_request";
struct Seed<'a> {
    remaining: &'a mut usize,
    depth: usize,
    max_depth: usize,
}
impl<'de> DeserializeSeed<'de> for Seed<'_> {
    type Value = Value;
    fn deserialize<D: serde::Deserializer<'de>>(self, d: D) -> Result<Value, D::Error> {
        if self.depth > self.max_depth || *self.remaining == 0 {
            return Err(D::Error::custom(INVALID));
        }
        *self.remaining -= 1;
        d.deserialize_any(self)
    }
}
impl<'de> Visitor<'de> for Seed<'_> {
    type Value = Value;
    fn expecting(&self, f: &mut fmt::Formatter) -> fmt::Result {
        f.write_str("bounded editor JSON")
    }
    fn visit_bool<E: Error>(self, v: bool) -> Result<Value, E> {
        Ok(Value::Bool(v))
    }
    fn visit_unit<E: Error>(self) -> Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_u64<E: Error>(self, v: u64) -> Result<Value, E> {
        Ok(v.into())
    }
    fn visit_i64<E: Error>(self, v: i64) -> Result<Value, E> {
        if v < 0 {
            Err(E::custom(INVALID))
        } else {
            Ok(v.into())
        }
    }
    fn visit_str<E: Error>(self, v: &str) -> Result<Value, E> {
        if v.len() > 2048 {
            Err(E::custom(INVALID))
        } else {
            Ok(v.into())
        }
    }
    fn visit_string<E: Error>(self, v: String) -> Result<Value, E> {
        self.visit_str(&v)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut a: A) -> Result<Value, A::Error> {
        let mut out = Vec::new();
        while let Some(v) = a.next_element_seed(Seed {
            remaining: self.remaining,
            depth: self.depth + 1,
            max_depth: self.max_depth,
        })? {
            if out.len() == 8 {
                return Err(A::Error::custom(INVALID));
            }
            out.push(v);
        }
        Ok(Value::Array(out))
    }
    fn visit_map<A: MapAccess<'de>>(self, mut a: A) -> Result<Value, A::Error> {
        let mut out = Map::new();
        while let Some(k) = a.next_key::<String>()? {
            if k.len() > 64 || out.len() == 16 || out.contains_key(&k) {
                return Err(A::Error::custom(INVALID));
            }
            let v = a.next_value_seed(Seed {
                remaining: self.remaining,
                depth: self.depth + 1,
                max_depth: self.max_depth,
            })?;
            out.insert(k, v);
        }
        Ok(Value::Object(out))
    }
}
fn json(bytes: &[u8], limit: usize) -> Result<Value, &'static str> {
    bounded_json(bytes, limit, 4, 128)
}
pub(crate) fn parent_json(bytes: &[u8]) -> Result<Value, &'static str> {
    bounded_json(bytes, REPLY_BYTES + 4096, 9, 512)
}
fn bounded_json(
    bytes: &[u8],
    limit: usize,
    max_depth: usize,
    nodes: usize,
) -> Result<Value, &'static str> {
    if bytes.is_empty() || bytes.len() > limit {
        return Err(INVALID);
    }
    let mut remaining = nodes;
    let mut d = serde_json::Deserializer::from_slice(bytes);
    let value = Seed {
        remaining: &mut remaining,
        depth: 0,
        max_depth,
    }
    .deserialize(&mut d)
    .map_err(|_| INVALID)?;
    d.end().map_err(|_| INVALID)?;
    Ok(value)
}
fn fields<'a>(v: &'a Value, keys: &[&str]) -> Result<&'a Map<String, Value>, &'static str> {
    let row = v.as_object().ok_or(INVALID)?;
    if row.len() != keys.len() || keys.iter().any(|k| !row.contains_key(*k)) {
        return Err(INVALID);
    }
    Ok(row)
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str, &'static str> {
    v.get(key).and_then(Value::as_str).ok_or(INVALID)
}
fn counter(v: &str) -> Result<u64, &'static str> {
    if v.is_empty()
        || v.len() > 20
        || (v.len() > 1 && v.starts_with('0'))
        || !v.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(INVALID);
    }
    v.parse().map_err(|_| INVALID)
}
fn hash(v: &str) -> bool {
    v.len() == 64
        && v.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn uuid(v: &str) -> bool {
    v.len() == 36
        && v.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_digit() || (b'a'..=b'f').contains(&b)
            }
        })
}
fn identity(v: &str) -> bool {
    (1..=64).contains(&v.len()) && v.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}
fn label(v: &Value, nullable: bool) -> bool {
    (nullable && v.is_null()) || v.as_str().is_some_and(|s| s.len() <= 128)
}
fn check(condition: bool) -> Result<(), &'static str> {
    if condition {
        Ok(())
    } else {
        Err(INVALID)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Context {
    pub connection_id: String,
    pub authority_instance_id: String,
}
impl Context {
    fn valid(&self) -> bool {
        self.connection_id.len() == 32
            && self
                .connection_id
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            && uuid(&self.authority_instance_id)
    }
    fn header(&self, v: &Value, command: &str) -> Result<(), &'static str> {
        check(
            self.valid()
                && v.get("version").and_then(Value::as_u64) == Some(1)
                && text(v, "connectionId")? == self.connection_id
                && text(v, "authorityInstanceId")? == self.authority_instance_id
                && text(v, "command")? == command,
        )
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LabelIntent {
    pub operation_id: String,
    pub expected_revision: u64,
    pub profile_id: String,
    pub control_id: String,
    pub label: Option<String>,
}
impl LabelIntent {
    fn parse(v: &Value, header: bool) -> Result<Self, &'static str> {
        if header {
            fields(
                v,
                &[
                    "version",
                    "command",
                    "connectionId",
                    "authorityInstanceId",
                    "operationId",
                    "expectedRevision",
                    "profileId",
                    "controlId",
                    "label",
                ],
            )?;
        } else {
            fields(
                v,
                &[
                    "command",
                    "operationId",
                    "expectedRevision",
                    "profileId",
                    "controlId",
                    "label",
                ],
            )?;
        }
        check(text(v, "command")? == "configuration-set-control-label")?;
        let operation_id = text(v, "operationId")?;
        let profile_id = text(v, "profileId")?;
        let control_id = text(v, "controlId")?;
        check(
            identity(operation_id)
                && uuid(profile_id)
                && uuid(control_id)
                && label(&v["label"], true),
        )?;
        Ok(Self {
            operation_id: operation_id.into(),
            expected_revision: counter(text(v, "expectedRevision")?)?,
            profile_id: profile_id.into(),
            control_id: control_id.into(),
            label: v["label"].as_str().map(str::to_owned),
        })
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Operation {
    Profile {
        revision: u64,
        source_hash: String,
        profile_id: String,
        offset: u64,
    },
    SetLabel(LabelIntent),
    LabelStatus(LabelIntent),
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub context: Context,
    pub operation: Operation,
}
impl Request {
    pub fn parse(bytes: &[u8], context: &Context) -> Result<Self, &'static str> {
        let v = json(bytes, REQUEST_BYTES)?;
        let command = text(&v, "command")?;
        context.header(&v, command)?;
        let operation = match command {
            "editor-profile" => {
                fields(
                    &v,
                    &[
                        "version",
                        "command",
                        "connectionId",
                        "authorityInstanceId",
                        "expectedRevision",
                        "expectedSourceHash",
                        "profileId",
                        "offset",
                    ],
                )?;
                let revision = counter(text(&v, "expectedRevision")?)?;
                let source_hash = text(&v, "expectedSourceHash")?;
                let profile_id = text(&v, "profileId")?;
                let offset = v["offset"].as_u64().ok_or(INVALID)?;
                check(hash(source_hash) && uuid(profile_id) && offset <= 120 && offset % 8 == 0)?;
                Operation::Profile {
                    revision,
                    source_hash: source_hash.into(),
                    profile_id: profile_id.into(),
                    offset,
                }
            }
            "configuration-set-control-label" => Operation::SetLabel(LabelIntent::parse(&v, true)?),
            "editor-label-status" => {
                fields(
                    &v,
                    &[
                        "version",
                        "command",
                        "connectionId",
                        "authorityInstanceId",
                        "intent",
                    ],
                )?;
                Operation::LabelStatus(LabelIntent::parse(&v["intent"], false)?)
            }
            _ => return Err(INVALID),
        };
        Ok(Self {
            context: context.clone(),
            operation,
        })
    }
    pub(crate) fn command(&self) -> &'static str {
        match self.operation {
            Operation::Profile { .. } => "editor-profile-result",
            Operation::SetLabel(_) => "configuration-set-control-label-result",
            Operation::LabelStatus(_) => "editor-label-status-result",
        }
    }
    fn intent(&self) -> Result<&LabelIntent, &'static str> {
        match &self.operation {
            Operation::SetLabel(i) | Operation::LabelStatus(i) => Ok(i),
            _ => Err(INVALID),
        }
    }
}
#[derive(Clone, Debug, PartialEq)]
pub struct Reply {
    pub kind: String,
    pub value: Value,
}
fn header_fields<'a>(extra: &[&'a str]) -> Vec<&'a str> {
    [
        "version",
        "command",
        "connectionId",
        "authorityInstanceId",
        "kind",
    ]
    .into_iter()
    .chain(extra.iter().copied())
    .collect()
}
fn receipt(v: &Value, intent: &LabelIntent) -> Result<(), &'static str> {
    fields(
        v,
        &[
            "version",
            "operationId",
            "resultingRevision",
            "contentHash",
            "affectedEntities",
        ],
    )?;
    check(
        v["version"].as_u64() == Some(1)
            && text(v, "operationId")? == intent.operation_id
            && counter(text(v, "resultingRevision")?)?
                == intent.expected_revision.checked_add(1).ok_or(INVALID)?
            && hash(text(v, "contentHash")?)
            && v["affectedEntities"] == serde_json::json!([intent.profile_id, intent.control_id]),
    )
}
fn js_whitespace(c: char) -> bool {
    matches!(c,'\u{0009}'..='\u{000d}'|'\u{0020}'|'\u{00a0}'|'\u{1680}'|'\u{2000}'..='\u{200a}'|'\u{2028}'|'\u{2029}'|'\u{202f}'|'\u{205f}'|'\u{3000}'|'\u{feff}')
}
impl Reply {
    pub fn parse(bytes: &[u8], request: &Request) -> Result<Self, &'static str> {
        let v = json(bytes, REPLY_BYTES)?;
        request.context.header(&v, request.command())?;
        let kind = text(&v, "kind")?;
        match kind {
            "error" => {
                fields(&v, &header_fields(&["error"]))?;
                check(matches!(
                    text(&v, "error")?,
                    "editor_busy"
                        | "editor_unavailable"
                        | "editor_invalid_request"
                        | "editor_access_denied"
                        | "editor_operation_reused"
                        | "editor_profile_not_found"
                        | "editor_control_not_found"
                        | "editor_source_changed"
                        | "editor_unsupported_profile"
                        | "editor_response_too_large"
                ))?;
            }
            "conflict" => {
                check(!matches!(request.operation, Operation::LabelStatus(_)))?;
                fields(&v, &header_fields(&["currentRevision"]))?;
                counter(text(&v, "currentRevision")?)?;
            }
            "editor-label-admitted" | "editor-label-pending" => {
                check(matches!(
                    (&request.operation, kind),
                    (Operation::SetLabel(_), "editor-label-admitted")
                        | (Operation::LabelStatus(_), "editor-label-pending")
                ))?;
                fields(&v, &header_fields(&["operationId"]))?;
                check(text(&v, "operationId")? == request.intent()?.operation_id)?;
            }
            "committed" | "editor-label-receipt" => {
                check(matches!(
                    (&request.operation, kind),
                    (Operation::SetLabel(_), "committed")
                        | (Operation::LabelStatus(_), "editor-label-receipt")
                ))?;
                fields(
                    &v,
                    &header_fields(if kind == "committed" {
                        &["receipt", "replayed"]
                    } else {
                        &["receipt"]
                    }),
                )?;
                if kind == "committed" {
                    check(v["replayed"].is_boolean())?;
                }
                receipt(&v["receipt"], request.intent()?)?;
            }
            "editor-profile" => {
                let Operation::Profile {
                    revision,
                    source_hash,
                    profile_id,
                    offset,
                } = &request.operation
                else {
                    return Err(INVALID);
                };
                fields(
                    &v,
                    &header_fields(&[
                        "revision",
                        "contentHash",
                        "profileId",
                        "name",
                        "offset",
                        "totalControls",
                        "nextOffset",
                        "controls",
                    ]),
                )?;
                check(
                    counter(text(&v, "revision")?)? == *revision
                        && text(&v, "contentHash")? == source_hash
                        && text(&v, "profileId")? == profile_id
                        && v["offset"].as_u64() == Some(*offset),
                )?;
                let name = text(&v, "name")?;
                check(
                    name.len() <= 1024
                        && name.chars().count() <= 256
                        && name.chars().any(|c| !js_whitespace(c)),
                )?;
                let total = v["totalControls"].as_u64().ok_or(INVALID)?;
                check(
                    total <= 128
                        && if total == 0 {
                            *offset == 0
                        } else {
                            *offset < total
                        },
                )?;
                let count = 8.min(total - *offset);
                let controls = v["controls"].as_array().ok_or(INVALID)?;
                check(controls.len() == count as usize)?;
                let next = if offset + count < total {
                    Value::from(offset + count)
                } else {
                    Value::Null
                };
                check(v["nextOffset"] == next)?;
                let mut ids = BTreeSet::new();
                for c in controls {
                    fields(c, &["id", "generatedLabel", "labelOverride"])?;
                    let id = text(c, "id")?;
                    check(
                        uuid(id)
                            && ids.insert(id)
                            && label(&c["generatedLabel"], false)
                            && label(&c["labelOverride"], true),
                    )?;
                }
            }
            _ => return Err(INVALID),
        }
        Ok(Self {
            kind: kind.into(),
            value: v,
        })
    }
}
