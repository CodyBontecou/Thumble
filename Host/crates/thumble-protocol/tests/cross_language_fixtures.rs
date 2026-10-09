use serde::Deserialize;
use serde_json::Value;
use thumble_protocol::{ControllerMessage, ControllerWireCodec};

#[derive(Debug, Deserialize)]
struct FixtureFile {
    schema: String,
    version: u32,
    vectors: Vec<Fixture>,
}

#[derive(Debug, Deserialize)]
struct Fixture {
    name: String,
    kind: String,
    hex: Option<String>,
    message: Option<ControllerMessage>,
    json: Option<Value>,
}

fn fixtures() -> FixtureFile {
    serde_json::from_str(include_str!("../../../fixtures/wire/vectors.json"))
        .expect("wire fixtures must be valid")
}

fn decode_hex(value: &str) -> Vec<u8> {
    assert_eq!(value.len() % 2, 0);
    value
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| {
            let text = std::str::from_utf8(pair).expect("fixture hex must be ASCII");
            u8::from_str_radix(text, 16).expect("fixture hex must contain bytes")
        })
        .collect()
}

#[test]
fn shared_wire_vectors_encode_and_decode_exactly() {
    let file = fixtures();
    assert_eq!(file.schema, "com.codybontecou.pocketpad.wire-fixtures");
    assert_eq!(file.version, 1);

    for fixture in file.vectors {
        match fixture.kind.as_str() {
            "compact" => {
                let expected = decode_hex(fixture.hex.as_deref().expect("compact fixture hex"));
                let message = fixture.message.expect("compact fixture message");
                assert_eq!(
                    ControllerWireCodec::encode(&message).expect("compact fixture encodes"),
                    expected,
                    "{} encode mismatch",
                    fixture.name
                );
                assert_eq!(
                    ControllerWireCodec::decode(&expected).expect("compact fixture decodes"),
                    message,
                    "{} decode mismatch",
                    fixture.name
                );
            }
            "json" => {
                let expected = fixture.json.expect("JSON fixture value");
                let bytes = serde_json::to_vec(&expected).expect("JSON fixture encodes");
                let decoded = ControllerWireCodec::decode(&bytes).expect("JSON fixture decodes");
                assert_eq!(
                    serde_json::to_value(decoded).expect("decoded fixture serializes"),
                    expected,
                    "{} JSON mismatch",
                    fixture.name
                );
            }
            "rejected" => {
                let bytes = decode_hex(fixture.hex.as_deref().expect("rejected fixture hex"));
                assert!(ControllerWireCodec::decode(&bytes).is_err(), "{} must be rejected", fixture.name);
            }
            other => panic!("unknown fixture kind {other:?}"),
        }
    }
}
