//! Reject ambiguous JSON before ordinary collection decoding can discard keys.
use serde::de::{DeserializeOwned, MapAccess, SeqAccess, Visitor};
use serde::{Deserialize, Deserializer};
use std::collections::BTreeSet;
use std::fmt;
use unicode_normalization::UnicodeNormalization;

/// Decode a complete JSON value, rejecting repeated decoded object keys at every
/// depth (including unknown metadata and Unicode canonical equivalents, matching
/// Swift String-keyed collections). The first pass stores keys, not a second
/// payload tree, and retains serde_json's normal recursion and syntax limits.
pub fn decode_unique_json<T: DeserializeOwned>(data: &[u8]) -> Result<T, serde_json::Error> {
    validate_unique_json(data)?;
    serde_json::from_slice(data)
}

/// Validate raw JSON without collecting a payload tree.
pub fn validate_unique_json(data: &[u8]) -> Result<(), serde_json::Error> {
    let mut decoder = serde_json::Deserializer::from_slice(data);
    UniqueValue::deserialize(&mut decoder)?;
    decoder.end()
}

struct UniqueValue;
impl<'de> Deserialize<'de> for UniqueValue {
    fn deserialize<D: Deserializer<'de>>(decoder: D) -> Result<Self, D::Error> {
        decoder.deserialize_any(UniqueVisitor)
    }
}

struct UniqueVisitor;
impl<'de> Visitor<'de> for UniqueVisitor {
    type Value = UniqueValue;
    fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
        formatter.write_str("JSON with unique object keys")
    }
    fn visit_bool<E: serde::de::Error>(self, _: bool) -> Result<UniqueValue, E> {
        Ok(UniqueValue)
    }
    fn visit_i64<E: serde::de::Error>(self, _: i64) -> Result<UniqueValue, E> {
        Ok(UniqueValue)
    }
    fn visit_u64<E: serde::de::Error>(self, _: u64) -> Result<UniqueValue, E> {
        Ok(UniqueValue)
    }
    fn visit_f64<E: serde::de::Error>(self, _: f64) -> Result<UniqueValue, E> {
        Ok(UniqueValue)
    }
    fn visit_str<E: serde::de::Error>(self, _: &str) -> Result<UniqueValue, E> {
        Ok(UniqueValue)
    }
    fn visit_unit<E: serde::de::Error>(self) -> Result<UniqueValue, E> {
        Ok(UniqueValue)
    }
    fn visit_seq<A: SeqAccess<'de>>(self, mut sequence: A) -> Result<UniqueValue, A::Error> {
        while sequence.next_element::<UniqueValue>()?.is_some() {}
        Ok(UniqueValue)
    }
    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<UniqueValue, A::Error> {
        let mut keys = BTreeSet::new();
        while let Some(key) = map.next_key::<String>()? {
            if !keys.insert(key.nfc().collect::<String>()) {
                // Do not include arbitrary key contents: they may contain secrets.
                return Err(serde::de::Error::custom("duplicate JSON object key"));
            }
            map.next_value::<UniqueValue>()?;
        }
        Ok(UniqueValue)
    }
}

#[cfg(test)]
mod tests {
    use super::decode_unique_json;
    use serde_json::Value;

    #[test]
    fn decoded_keys_are_unique_within_each_object_not_across_siblings() {
        for raw in [
            r#"{"id":1,"id":2}"#,
            r#"{"id":1,"\u0069d":2}"#,
            r#"{"future":{"key":false,"key":true}}"#,
            r#"{"é":1,"e\u0301":2}"#,
            r#"{"\u00e9":1,"e\u0301":2}"#,
            r#"[{"id":1,"id":1}]"#,
        ] {
            assert!(decode_unique_json::<Value>(raw.as_bytes())
                .unwrap_err()
                .to_string()
                .contains("duplicate JSON object key"));
        }
        let raw = br#"[{"id":1},{"id":2,"n":18446744073709551615,"v":null,"ok":true,"s":"\\\""}]"#;
        assert_eq!(
            decode_unique_json::<Value>(raw).unwrap(),
            serde_json::from_slice::<Value>(raw).unwrap()
        );
        assert!(decode_unique_json::<Value>(b"{} {}").is_err());
    }
}
