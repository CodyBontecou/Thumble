use thumble_core::ProfileArtifact;

#[test]
fn checked_in_profile_artifact_matches_canonical_vector_and_hash() {
    let fixture = include_bytes!("../../../fixtures/profile-artifact/v1.json");
    let canonical = include_bytes!("../../../fixtures/profile-artifact/v1.canonical.json");
    let expected_hash = include_str!("../../../fixtures/profile-artifact/v1.sha256").trim();
    let artifact = ProfileArtifact::decode_json(fixture).unwrap();
    assert_eq!(artifact.content_hash.value, expected_hash);
    assert_eq!(
        artifact.canonical_content_bytes().unwrap().as_slice(),
        canonical.strip_suffix(b"\n").unwrap()
    );
    let mut pretty = artifact.encode_pretty_json().unwrap();
    pretty.push(b'\n');
    assert_eq!(pretty.as_slice(), fixture);
    assert_eq!(artifact.default_profile_id, None);
    assert_eq!(
        artifact.extensions["futureTopLevel"]["safeIntegerBoundary"],
        9_007_199_254_740_991_u64
    );
    let profile_id = "00000000-0000-0000-0000-000000000201";
    let element_id = "81C296ED-309D-4F05-BB11-F5A2E2027801";
    assert_eq!(
        artifact.profiles[0]["skinReference"]["identifier"],
        "com.codybontecou.thumble.fixture"
    );
    assert!(artifact.profiles[0]["landscapeCustomization"].is_object());
    assert!(artifact.profiles[0]["skinBaselineCustomization"].is_object());
    assert_eq!(
        artifact.profile_key_bindings[profile_id][element_id]["futureBindingField"]["label"],
        "保持"
    );
    assert_eq!(
        artifact.profile_key_bindings[profile_id][element_id]["sequence"][1]["futureStrokeField"],
        true
    );
    assert_eq!(
        artifact.profile_output_bindings[profile_id][element_id]["futureOutputField"]["mode"],
        "next"
    );
    let converted = artifact.to_configuration_document().unwrap();
    assert!(converted.profile_key_bindings[profile_id]
        .get_raw(element_id)
        .is_some());
    assert!(converted.profile_output_bindings[profile_id]
        .get_raw(element_id)
        .unwrap()
        .gamepad_buttons
        .contains("south"));
}

#[test]
fn literal_duplicate_profile_and_binding_fields_reject_before_integrity_projection() {
    let fixture: serde_json::Value =
        serde_json::from_slice(include_bytes!("../../../fixtures/profile-artifact/v1.json"))
            .unwrap();
    let raw = serde_json::to_string(&fixture).unwrap();
    for (original, duplicate) in [
        ("\"kind\":\"button\"", "\"kind\":\"joystick\",\"kind\":\"button\""),
        ("\"id\":\"81C296ED-309D-4F05-BB11-F5A2E2027801\"", "\"id\":\"00000000-0000-0000-0000-000000000105\",\"\\u0069d\":\"81C296ED-309D-4F05-BB11-F5A2E2027801\""),
        ("\"keyCode\":12", "\"keyCode\":49,\"keyCode\":12"),
    ] {
        assert!(raw.contains(original));
        let ambiguous = raw.replacen(original, duplicate, 1);
        // Last-wins JSON collection produces the original, valid hashed artifact.
        assert_eq!(serde_json::from_str::<serde_json::Value>(&ambiguous).unwrap(), fixture);
        assert!(ProfileArtifact::decode_json(ambiguous.as_bytes()).is_err(), "accepted {duplicate}");
        assert!(ProfileArtifact::decode_import_json(ambiguous.as_bytes()).is_err(), "accepted import {duplicate}");
    }
}

#[test]
fn named_binding_keys_are_rejected_even_in_portable_artifacts() {
    use sha2::{Digest, Sha256};
    use thumble_core::ProfileArtifactError;

    fn reseal(fixture: &mut serde_json::Value) -> Vec<u8> {
        // Seal raw content independently: the production sealer validates the
        // structure and would reject the named key before the decoder is tested.
        let mut content = fixture.clone();
        let fields = content.as_object_mut().unwrap();
        fields.remove("exportedAt");
        fields.remove("contentHash");
        let canonical = serde_json_canonicalizer::to_vec(&content).unwrap();
        fixture["contentHash"]["value"] =
            serde_json::Value::String(format!("{:x}", Sha256::digest(canonical)));
        serde_json::to_vec(fixture).unwrap()
    }

    let mut fixture: serde_json::Value =
        serde_json::from_slice(include_bytes!("../../../fixtures/profile-artifact/v1.json"))
            .unwrap();
    let profile_id = "00000000-0000-0000-0000-000000000201";
    let element_id = "81C296ED-309D-4F05-BB11-F5A2E2027801";
    fixture["profileKeyBindings"][profile_id] = serde_json::json!({element_id: {"keyCode": 49}});
    let current = reseal(&mut fixture);
    assert!(ProfileArtifact::decode_json(&current).is_ok());
    assert!(ProfileArtifact::decode_import_json(&current).is_ok());

    fixture["profileKeyBindings"][profile_id] = serde_json::json!({"jump": {"keyCode": 49}});
    let obsolete = reseal(&mut fixture);
    for error in [
        ProfileArtifact::decode_json(&obsolete).unwrap_err(),
        ProfileArtifact::decode_import_json(&obsolete).unwrap_err(),
    ] {
        assert_ne!(error, ProfileArtifactError::ContentHashMismatch);
    }
}
