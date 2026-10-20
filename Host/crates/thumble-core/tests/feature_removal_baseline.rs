use serde_json::{json, Value};
use thumble_core::ConfigurationDocument;

#[test]
fn frozen_legacy_profiles_survive_host_validation_and_serialization() {
    let fixture: Value = serde_json::from_slice(include_bytes!(
        "../../../fixtures/feature-removal/v1/legacy-profiles.json"
    ))
    .unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 4);
    for case in cases {
        for key in ["input", "expected"] {
            let profile = &case[key];
            let document = json!({
                "profiles": [profile],
                "activeProfileID": profile["id"],
                "defaultProfileID": profile["id"],
                "keyBindings": {}, "outputBindings": {},
                "profileKeyBindings": {}, "profileOutputBindings": {}
            });
            let parsed: ConfigurationDocument = serde_json::from_value(document.clone()).unwrap();
            parsed.validate().unwrap();
            assert_eq!(serde_json::to_value(parsed).unwrap(), document);
        }
        assert_eq!(case["input"]["id"], case["expected"]["id"]);
        assert_eq!(case["input"]["outputMode"], case["expected"]["outputMode"]);
    }
}

#[test]
fn migration_inputs_preserve_unknown_metadata_and_unresolved_profiles() {
    let fixture: Value = serde_json::from_slice(include_bytes!(
        "../../../fixtures/feature-removal/v1/migration-cases.json"
    ))
    .unwrap();
    let cases = fixture["cases"].as_array().unwrap();
    assert_eq!(cases.len(), 3);
    for case in cases {
        let profile = &case["profile"];
        let document = json!({
            "profiles": [profile],
            "activeProfileID": profile["id"], "defaultProfileID": profile["id"],
            "keyBindings": {}, "outputBindings": {},
            "profileKeyBindings": {}, "profileOutputBindings": {}
        });
        let parsed: ConfigurationDocument = serde_json::from_value(document.clone()).unwrap();
        parsed.validate().unwrap();
        let encoded = serde_json::to_value(parsed).unwrap();
        assert_eq!(encoded, document);
        assert_eq!(
            encoded["profiles"][0]["futureMigrationMetadata"]["version"],
            7
        );
        if case["name"] == "missing-package" {
            assert_eq!(encoded["profiles"][0]["skinReference"]["version"], "99.0.0");
            assert_eq!(case["expectedDisposition"], "recovery-required");
        }
    }
}
