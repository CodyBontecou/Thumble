use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::sync::Arc;
use thumble_core::{
    ConfigurationDocument, ConfigurationDocumentError, PersistentState, ProfileResourceTable,
};

fn fixture() -> Value {
    serde_json::from_slice(include_bytes!(
        "../../../fixtures/profile-resources/v1/fixture.json"
    ))
    .unwrap()
}

fn expand(node: &Value, table: &ProfileResourceTable) -> Value {
    match node {
        Value::Object(object) if object.contains_key("resourceSHA256") => {
            Value::String(STANDARD.encode(table.data(node).unwrap()))
        }
        Value::Object(object) => Value::Object(
            object
                .iter()
                .filter(|(k, _)| {
                    !matches!(
                        k.as_str(),
                        "appearanceResources" | "appearanceResourceVersion"
                    )
                })
                .map(|(key, value)| (key.clone(), expand(value, table)))
                .collect(),
        ),
        Value::Array(values) => Value::Array(values.iter().map(|v| expand(v, table)).collect()),
        _ => node.clone(),
    }
}

#[test]
fn native_fixture_decodes_and_expands_without_altering_profile_or_outputs() {
    let fixture = fixture();
    let source = fixture["pooledProfile"].clone();
    let table = ProfileResourceTable::from_profile(&source)
        .unwrap()
        .unwrap();
    assert_eq!(expand(&source, &table), fixture["expandedProfile"]);
    assert_eq!(source, fixture["pooledProfile"]);
    let reference = &source["customization"]["assetLibrary"]["assets"][0]["data"];
    let first = table.data(reference).unwrap();
    let second = table.data(reference).unwrap();
    assert_eq!(&*first, b"fixture-image");
    assert!(Arc::ptr_eq(&first, &second));
}

#[test]
fn pruning_launch_metadata_keeps_shared_images_and_unknown_metadata() {
    let fixture = fixture();
    let table = ProfileResourceTable::from_profile(&fixture["pooledProfile"])
        .unwrap()
        .unwrap();
    let mut portable = fixture["pooledProfile"].clone();
    portable.as_object_mut().unwrap().remove("launchTarget");
    assert_eq!(
        table.pruning_unused(&portable).unwrap(),
        fixture["portableProfile"]
    );
    portable["futureMigrationMetadata"] = json!({"untouched": [1, "data", {"custom": true}]});
    let pruned = table.pruning_unused(&portable).unwrap();
    assert_eq!(
        pruned["futureMigrationMetadata"],
        portable["futureMigrationMetadata"]
    );
    assert_eq!(
        portable["appearanceResources"].as_object().unwrap().len(),
        2
    );
    assert_eq!(pruned["appearanceResources"].as_object().unwrap().len(), 1);
    portable["futureMigrationMetadata"] =
        json!({"resource": fixture["pooledProfile"]["launchTarget"]["bookmarkData"].clone()});
    let retained = table.pruning_unused(&portable).unwrap();
    assert_eq!(
        retained["futureMigrationMetadata"],
        portable["futureMigrationMetadata"]
    );
    assert_eq!(
        retained["appearanceResources"].as_object().unwrap().len(),
        2
    );
}

#[test]
fn integrity_and_reference_errors_do_not_become_missing_image_defaults() {
    let fixture = fixture();
    let original = &fixture["pooledProfile"];
    for version in [json!(99), json!("1"), Value::Null] {
        let mut profile = original.clone();
        profile["appearanceResourceVersion"] = version;
        assert!(ProfileResourceTable::from_profile(&profile).is_err());
    }
    let digest = original["appearanceResources"]
        .as_object()
        .unwrap()
        .keys()
        .next()
        .unwrap();
    let mut corrupt = original.clone();
    corrupt["appearanceResources"][digest] = json!(STANDARD.encode(b"corrupt"));
    assert!(ProfileResourceTable::from_profile(&corrupt).is_err());
    let mut missing = original.clone();
    missing["appearanceResources"] = json!({});
    assert!(ProfileResourceTable::from_profile(&missing).is_err());
    let mut malformed = original.clone();
    malformed["customization"]["assetLibrary"]["assets"][0]["data"]["extra"] = json!(true);
    assert!(ProfileResourceTable::from_profile(&malformed).is_err());
    let mut unmarked = original.clone();
    unmarked
        .as_object_mut()
        .unwrap()
        .remove("appearanceResourceVersion");
    assert!(ProfileResourceTable::from_profile(&unmarked).is_err());
    let mut numeric = original.clone();
    numeric["appearanceResourceVersion"] = json!(1.0);
    assert!(ProfileResourceTable::from_profile(&numeric)
        .unwrap()
        .is_some());
}

#[test]
fn unpooled_legacy_profiles_remain_unmodified_and_authority_stays_closed() {
    let fixture = fixture();
    assert!(
        ProfileResourceTable::from_profile(&fixture["expandedProfile"])
            .unwrap()
            .is_none()
    );
    let state = PersistentState::minimal("resource-test-host").unwrap();
    let mut document = ConfigurationDocument::from_state(&state).unwrap();
    for key in [
        "appearanceBank",
        "appearanceResources",
        "appearanceResourceVersion",
    ] {
        document.profiles[0][key] = fixture["pooledProfile"][key].clone();
    }
    assert_eq!(
        document.validate(),
        Err(ConfigurationDocumentError::UnsupportedAppearanceBank)
    );
    document.profiles[0]
        .as_object_mut()
        .unwrap()
        .remove("appearanceBank");
    assert_eq!(
        document.validate(),
        Err(ConfigurationDocumentError::UnsupportedAppearanceBank),
        "Resource markers alone also require v5 authority"
    );
    for key in ["appearanceResources", "appearanceResourceVersion"] {
        document.profiles[0].as_object_mut().unwrap().remove(key);
    }
    document.validate().unwrap();
    assert_eq!(
        state,
        PersistentState::minimal("resource-test-host").unwrap()
    );
}
