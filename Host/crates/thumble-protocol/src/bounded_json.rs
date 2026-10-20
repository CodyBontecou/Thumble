//! Count or encode complete JSON documents without producing an oversized result.
use serde::Serialize;
use std::io::{self, Write};

#[derive(Debug)]
pub enum BoundedJsonError {
    TooLarge { maximum_bytes: usize },
    Json(serde_json::Error),
}

struct LimitedWriter<W> {
    target: W,
    count: usize,
    limit: usize,
    exceeded: bool,
}
impl<W: Write> Write for LimitedWriter<W> {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > self.limit.saturating_sub(self.count) {
            self.exceeded = true;
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "JSON size limit",
            ));
        }
        self.target.write_all(bytes)?;
        self.count += bytes.len();
        Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> {
        self.target.flush()
    }
}
fn encode<T: Serialize + ?Sized, W: Write>(
    value: &T,
    limit: usize,
    target: W,
) -> Result<LimitedWriter<W>, BoundedJsonError> {
    let mut writer = LimitedWriter {
        target,
        count: 0,
        limit,
        exceeded: false,
    };
    if let Err(error) = serde_json::to_writer(&mut writer, value) {
        return Err(if writer.exceeded {
            BoundedJsonError::TooLarge {
                maximum_bytes: limit,
            }
        } else {
            BoundedJsonError::Json(error)
        });
    }
    Ok(writer)
}

/// Exact compact UTF-8 size, counting keys, punctuation and JSON escapes too.
/// Stops at the limit without allocating another encoded document.
pub fn bounded_json_size<T: Serialize + ?Sized>(
    value: &T,
    limit: usize,
) -> Result<usize, BoundedJsonError> {
    encode(value, limit, io::sink()).map(|writer| writer.count)
}
/// Returns a complete bounded document, never a truncated prefix.
pub fn encode_bounded_json<T: Serialize + ?Sized>(
    value: &T,
    limit: usize,
) -> Result<Vec<u8>, BoundedJsonError> {
    encode(value, limit, Vec::new()).map(|writer| writer.target)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn complete_documents_count_unicode_escapes_keys_and_nested_resources() {
        let value = json!({"profiles":[{"unknown\nmetadata":["é🕹️", "\\\"\u{0001}", null, true, -17.5],"appearanceResources":{"digest":"YWJj"}}]});
        let expected = serde_json::to_vec(&value).unwrap();
        assert_eq!(
            bounded_json_size(&value, expected.len()).unwrap(),
            expected.len()
        );
        assert_eq!(
            encode_bounded_json(&value, expected.len()).unwrap(),
            expected
        );
        assert!(matches!(
            bounded_json_size(&value, expected.len() - 1),
            Err(BoundedJsonError::TooLarge { .. })
        ));
        assert!(matches!(
            encode_bounded_json(&value, expected.len() - 1),
            Err(BoundedJsonError::TooLarge { .. })
        ));
    }
    #[test]
    fn an_oversized_prefix_stops_before_serializing_later_fields() {
        struct MustNotSerialize;
        impl Serialize for MustNotSerialize {
            fn serialize<S: serde::Serializer>(&self, _: S) -> Result<S::Ok, S::Error> {
                panic!("bounded serialization must stop before the trailing field")
            }
        }
        let value = ("x".repeat(4096), MustNotSerialize);
        assert!(matches!(
            bounded_json_size(&value, 64),
            Err(BoundedJsonError::TooLarge { maximum_bytes: 64 })
        ));
        assert!(matches!(
            encode_bounded_json(&value, 64),
            Err(BoundedJsonError::TooLarge { maximum_bytes: 64 })
        ));
    }
}
