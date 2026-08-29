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
    assert_eq!(
        artifact.profiles[0]["skinReference"]["identifier"],
        "com.codybontecou.thumble.fixture"
    );
    assert!(artifact.profiles[0]["landscapeCustomization"].is_object());
    assert!(artifact.profiles[0]["skinBaselineCustomization"].is_object());
    assert_eq!(
        artifact.profile_key_bindings[profile_id]["futureButton"]["futureBindingField"]["label"],
        "保持"
    );
    assert_eq!(
        artifact.profile_key_bindings[profile_id]["futureButton"]["sequence"][1]
            ["futureStrokeField"],
        true
    );
    assert_eq!(
        artifact.profile_output_bindings[profile_id]["futureButton"]["futureOutputField"]["mode"],
        "next"
    );
    let converted = artifact.to_configuration_document().unwrap();
    assert!(converted.profile_key_bindings[profile_id]
        .get_raw("futureButton")
        .is_some());
    assert!(converted.profile_output_bindings[profile_id]
        .get_raw("futureButton")
        .unwrap()
        .gamepad_buttons
        .contains("south"));
}
