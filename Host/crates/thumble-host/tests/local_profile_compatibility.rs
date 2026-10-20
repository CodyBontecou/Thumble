//! Native local profile normalization retains legacy outputs and unknown metadata.
use serde_json::json;
use std::path::PathBuf;

#[test]
#[ignore = "requires THUMBLE_TEST_ARTIFACT_RUNTIME_BIN with native compatibility bridge"]
fn native_legacy_inline_outputs_and_integral_float_metadata_round_trip_without_changes() {
    let bin = PathBuf::from(std::env::var_os("THUMBLE_TEST_ARTIFACT_RUNTIME_BIN").unwrap());
    let mut state = thumble_core::PersistentState::minimal("legacy-fixture").unwrap();
    state.profiles[0]["futureMetadata"] = json!({"scale":1.0,"count":2,"nested":[0.0,3.0]});
    let element = &mut state.profiles[0]["customization"]["elements"][0];
    element["output"] = json!({"gamepadButtons":[],"keyboard":{"keyCode":12,"modifiers":1,"sequence":[{"keyCode":12,"modifiers":1},{"keyCode":13,"modifiers":0}]}});
    element["defaultOutput"] = element["output"].clone();
    let mut second = state.profiles[0].clone();
    second["id"] = json!("00000000-0000-0000-0000-000000000202");
    second["futureMetadata"]["scale"] = json!(1);
    state.profiles.push(second);
    let doc = thumble_core::ConfigurationDocument::from_state(&state).unwrap();
    let bridge =
        thumble_host::bridge::ConfigurationBridge::at_path(bin.join("thumble-bridge")).unwrap();
    let operation = thumble_host::draft_operation::ConfigurationOperation::ProfileSelect {
        profile_id: state.active_profile_id,
    };
    let (response, _) = bridge.apply(&doc, &operation, 1234).unwrap();
    assert_eq!(response.profiles, doc.profiles);
    let reorder = thumble_host::draft_operation::ConfigurationOperation::ProfileMove {
        profile_id: "00000000-0000-0000-0000-000000000202".into(),
        index: 0,
    };
    let (reordered, _) = bridge.apply(&doc, &reorder, 1234).unwrap();
    assert_eq!(
        reordered.profiles,
        vec![doc.profiles[1].clone(), doc.profiles[0].clone()]
    );
}
