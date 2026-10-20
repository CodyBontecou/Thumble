use serde_json::Value;
use thumble_core::{
    ConfigurationDocument, OwnedConfigurationDocument, PersistentState, ProfileAppearanceBank,
};

const DOCUMENT: &[u8] = include_bytes!("../../../fixtures/owned-configuration/v1/document.json");
#[test]
fn shared_version_five_contract_and_rejected_mutations() {
    let original: Value = serde_json::from_slice(DOCUMENT).unwrap();
    let matrix: Value = serde_json::from_str(include_str!(
        "../../../fixtures/owned-configuration/v1/cases.json"
    ))
    .unwrap();
    for row in matrix["cases"].as_array().unwrap() {
        let mut candidate = original.clone();
        let path = row["path"].as_array().unwrap();
        if let Some((last, parents)) = path.split_last() {
            let mut target = &mut candidate;
            for key in parents {
                target = if let Some(index) = key.as_u64() {
                    &mut target[index as usize]
                } else {
                    &mut target[key.as_str().unwrap()]
                };
            }
            let key = last.as_str().unwrap();
            if row["action"] == "remove" {
                target.as_object_mut().unwrap().remove(key);
            } else {
                target[key] = row["value"].clone();
            }
        }
        let bytes = serde_json::to_vec(&candidate).unwrap();
        assert_eq!(
            OwnedConfigurationDocument::decode(&bytes).is_ok(),
            row["allowed"].as_bool().unwrap(),
            "{}",
            row["name"]
        );
    }
}
#[test]
fn exact_source_metadata_resources_and_all_states_survive_without_packages() {
    let document = OwnedConfigurationDocument::decode(DOCUMENT).unwrap();
    assert_eq!(document.original_bytes(), DOCUMENT);
    assert_eq!(document.profiles().len(), 2);
    assert_eq!(
        document.active_profile_id(),
        document.profiles()[0]["id"].as_str().unwrap()
    );
    assert_eq!(
        document.default_profile_id(),
        document.profiles()[1]["id"].as_str()
    );
    let raw = &document.profiles()[0];
    assert_eq!(
        raw["futureProfileMetadata"]["opaque"][2].as_u64(),
        Some(u64::MAX)
    );
    let bank = ProfileAppearanceBank::from_profile(raw).unwrap().unwrap();
    for scheme in ["light", "dark"] {
        for action in ["base", "left-trigger", "right-trigger", "both-triggers"] {
            let layout = bank
                .resolve_layout(&raw["customization"], scheme, action)
                .unwrap();
            for (actual, canonical) in layout["elements"]
                .as_array()
                .unwrap()
                .iter()
                .zip(raw["customization"]["elements"].as_array().unwrap())
            {
                for field in ["id", "kind", "output", "defaultOutput", "partOutputs"] {
                    assert_eq!(actual[field], canonical[field]);
                }
                for field in [
                    "centerX",
                    "centerY",
                    "widthScale",
                    "heightScale",
                    "rotationDegrees",
                    "isHidden",
                ] {
                    assert_eq!(actual["layout"][field], canonical["layout"][field]);
                }
            }
            assert_eq!(
                layout["elements"][0]["layout"]["icon"]["value"],
                format!("{scheme}/{action}")
            );
            assert_eq!(layout["deviceCanvas"], raw["customization"]["deviceCanvas"]);
        }
    }
    // The codec is explicit. Reading a destination cannot authorize an install
    // through the still-v4 persistent-state boundary or change the live format offer.
    let mut state = PersistentState::minimal("owned-codec-test").unwrap();
    state.profiles = document.profiles().to_vec();
    state.active_profile_id = document.active_profile_id().into();
    state.default_profile_id = document.default_profile_id().unwrap().into();
    assert!(ConfigurationDocument::from_state(&state).is_err());
    assert_eq!(thumble_protocol::SUPPORTED_PROFILE_FORMATS, &[4]);
}
#[test]
fn duplicate_keys_invalid_utf8_and_complete_document_overflow_are_rejected() {
    let source = std::str::from_utf8(DOCUMENT).unwrap();
    let duplicate = source.replacen("\"version\": 5", "\"version\": 5, \"version\": 4", 1);
    assert!(OwnedConfigurationDocument::decode(duplicate.as_bytes()).is_err());
    assert!(OwnedConfigurationDocument::decode(&[0xff]).is_err());
    let mut maximum = DOCUMENT.to_vec();
    maximum.resize(thumble_core::MAXIMUM_CONFIGURATION_DOCUMENT_BYTES, b' ');
    assert!(OwnedConfigurationDocument::decode(&maximum).is_ok());
    maximum.push(b' ');
    assert!(OwnedConfigurationDocument::decode(&maximum).is_err());
}
