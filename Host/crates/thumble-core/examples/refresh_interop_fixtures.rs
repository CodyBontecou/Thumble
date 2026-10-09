//! Reauthor current-protocol fixtures: cargo run -p thumble-core --example refresh_interop_fixtures
//! This is not an import/migration adapter. All positive identities are explicit UUIDs.
use serde_json::{json, Value};
use std::{fs, path::Path};
use thumble_protocol::{ControllerMessage, ControllerWireCodec};

fn main() {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures");
    write(&directory.join("state/minimal-profile.json"), &thumble_core::minimal_default_profile());
    let mut fixture = json!({
        "schema": "com.codybontecou.pocketpad.wire-fixtures", "version": 1,
        "vectors": [
            {"name":"v3-button-up-negative-timestamp", "kind":"compact", "message":{
                "type":"button", "button":"F14D99D4-0690-4F01-A733-688B616B0D76", "state":"up", "timestamp":-42
            }},
            {"name":"v1-release-all", "kind":"compact", "message":{
                "type":"release_all", "timestamp":123456789
            }},
            {"name":"v3-independent-button-down-full-width", "kind":"compact", "message":{
                "type":"button", "button":"66FA21C9-4D00-4B11-8890-97D157F7881A", "state":"down", "timestamp":0,
                "inputProtocolVersion":3, "inputGeneration":72623859790382856_u64,
                "inputSequence":1234605616436508552_u64, "pressIdentifier":9833440827789222417_u64
            }},
            {"name":"json-pairing-request", "kind":"json", "json":{
                "type":"pairing_request", "timestamp":0, "clientName":"Fixture iPhone",
                "clientDeviceInfo":{
                    "deviceName":"Fixture iPhone", "systemName":"iOS", "systemVersion":"26.0",
                    "screenBoundsWidth":393, "screenBoundsHeight":852, "nativeBoundsWidth":1179,
                    "nativeBoundsHeight":2556, "scale":3, "nativeScale":3, "futureField":{"kept":true}
                }
            }},
            {"name":"v3-element-primary", "kind":"compact", "message":{
                "type":"element_input", "elementID":"66FA21C9-4D00-4B11-8890-97D157F7881A", "elementPart":"primary",
                "state":"down", "timestamp":0, "inputProtocolVersion":3, "inputGeneration":91,
                "inputSequence":42, "pressIdentifier":7
            }},
            {"name":"v3-independent-joystick-left", "kind":"compact", "message":{
                "type":"element_input", "elementID":"D57E214F-CB01-4143-9CB6-63418C5AE8E1", "elementPart":"joystick_left",
                "state":"up", "timestamp":123456, "inputProtocolVersion":3, "inputGeneration":92,
                "inputSequence":43, "pressIdentifier":8
            }},
            {"name":"reject-v1-slot-button", "kind":"rejected", "hex":"50500101d6ffffffffffffff0602"},
            {"name":"reject-v2-slot-button", "kind":"rejected", "hex":"5050020112010100080706050403020188776655443322111122334455667788"}
        ]
    });
    for vector in fixture["vectors"].as_array_mut().unwrap() {
        if vector["kind"] == "compact" {
            let message: ControllerMessage = serde_json::from_value(vector["message"].clone()).unwrap();
            let bytes = ControllerWireCodec::encode(&message).unwrap();
            assert_eq!(ControllerWireCodec::decode(&bytes).unwrap(), message);
            vector["hex"] = Value::String(bytes.iter().map(|byte| format!("{byte:02x}")).collect());
        }
    }
    write(&directory.join("wire/vectors.json"), &fixture);
}

fn write(path: &Path, value: &Value) {
    fs::write(path, format!("{}\n", serde_json::to_string_pretty(value).unwrap())).unwrap();
    println!("{}", path.display());
}
