use serde_json::{json, Value};
use thumble_core::{ConfigurationDocument, PersistentState};

const OTHER_PROFILE: &str = "4B6B62C7-367D-44C7-BA78-2AC30E6E22F4";
const ORPHAN: &str = "82782DD6-D823-44AD-B9FC-9655E16160B1";

fn invalid_documents() -> Vec<(&'static str, Value)> {
    let valid = serde_json::to_value(PersistentState::minimal("server").unwrap()).unwrap();
    let mut cases = Vec::new();
    macro_rules! case {
        ($name:literal, $body:expr) => {{
            let mut document = valid.clone();
            ($body)(&mut document);
            cases.push(($name, document));
        }};
    }
    case!("empty catalog", |d: &mut Value| d["profiles"] = json!([]));
    case!("duplicate profile", |d: &mut Value| {
        let mut duplicate = d["profiles"][0].clone();
        duplicate["id"] = json!(duplicate["id"].as_str().unwrap().to_lowercase());
        d["profiles"].as_array_mut().unwrap().push(duplicate);
    });
    case!("named profile", |d: &mut Value| {
        d["profiles"][0]["id"] = json!("current-setup");
        d["activeProfileID"] = json!("current-setup");
        d["defaultProfileID"] = json!("current-setup");
    });
    case!("missing profile identity", |d: &mut Value| {
        d["profiles"][0].as_object_mut().unwrap().remove("id");
    });
    case!("dangling active reference", |d: &mut Value| d
        ["activeProfileID"] =
        json!(OTHER_PROFILE));
    case!("dangling default reference", |d: &mut Value| d
        ["defaultProfileID"] =
        json!(OTHER_PROFILE));
    case!("orphan profile keyboard map", |d: &mut Value| d
        ["profileKeyBindings"][OTHER_PROFILE] =
        json!({}));
    case!("orphan profile output map", |d: &mut Value| d
        ["profileOutputBindings"][OTHER_PROFILE] =
        json!({}));
    for field in ["profileKeyBindings", "profileOutputBindings"] {
        let mut document = valid.clone();
        let id = document["profiles"][0]["id"].as_str().unwrap().to_owned();
        // The builtin default profile ID is numeric-only, so use a UUID whose
        // casing differs to exercise canonical duplicate map detection.
        document["profiles"][0]["id"] = json!(OTHER_PROFILE);
        document["activeProfileID"] = json!(OTHER_PROFILE);
        document["defaultProfileID"] = json!(OTHER_PROFILE);
        let keys = document["profileKeyBindings"][&id].clone();
        let outputs = document["profileOutputBindings"][&id].clone();
        document["profileKeyBindings"] = json!({OTHER_PROFILE: keys});
        document["profileOutputBindings"] = json!({OTHER_PROFILE: outputs});
        let duplicate = document[field][OTHER_PROFILE].clone();
        document[field][OTHER_PROFILE.to_lowercase()] = duplicate;
        cases.push((field, document));
    }
    for field in [
        "keyBindings",
        "outputBindings",
        "profileKeyBindings",
        "profileOutputBindings",
    ] {
        let mut document = valid.clone();
        let id = document["profiles"][0]["id"].as_str().unwrap().to_owned();
        let binding = if field.contains("Key") || field == "keyBindings" {
            json!({"keyCode":49,"modifiers":0})
        } else {
            json!({"gamepadButtons":[]})
        };
        if field.starts_with("profile") {
            document[field][id][ORPHAN] = binding;
        } else {
            document[field][ORPHAN] = binding;
        }
        cases.push((field, document));
    }
    cases
}

#[test]
fn persisted_reference_errors_reject_without_normalization_mutation() {
    for (name, document) in invalid_documents() {
        let mut state: PersistentState = serde_json::from_value(document).unwrap();
        let before = state.clone();
        assert!(state.normalize().is_err(), "accepted {name}");
        assert_eq!(state, before, "mutated rejected {name}");
    }
}

#[test]
fn configuration_documents_reject_all_invalid_saved_references() {
    for (name, document) in invalid_documents() {
        let state: PersistentState = serde_json::from_value(document).unwrap();
        assert!(
            ConfigurationDocument::from_state(&state).is_err(),
            "accepted {name}"
        );
    }
}

#[test]
fn binding_references_belong_to_their_target_profile_not_any_installed_profile() {
    let mut state = PersistentState::minimal("server").unwrap();
    let own_id = thumble_protocol::KeypadElementID::parse(ORPHAN).unwrap();
    state
        .profiles
        .push(json!({"id":OTHER_PROFILE,"name":"Other","customization":{
        "elements":[{"id":ORPHAN,"kind":"button"}]}}));
    state
        .profile_key_bindings
        .insert(OTHER_PROFILE.into(), Default::default());
    state
        .profile_output_bindings
        .insert(OTHER_PROFILE.into(), Default::default());
    state
        .key_bindings
        .insert(own_id, thumble_core::KeyBinding::new(49, 0));
    assert!(state.normalize().is_err());
    assert!(ConfigurationDocument::from_state(&state).is_err());
}

#[test]
fn every_orientation_can_own_128_independent_controls_and_binding_references() {
    let mut state = PersistentState::minimal("server").unwrap();
    for (variant, field) in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ]
    .into_iter()
    .enumerate()
    {
        let elements: Vec<Value> = (0..128).map(|ordinal| json!({
            "id":format!("368C1C47-7233-40C4-93E6-{:012X}", variant * 128 + ordinal),
            "kind":"button","label":"Independent","output":{"keyboard":{"keyCode":49,"modifiersRawValue":8},"gamepadButtons":[]}
        })).collect();
        state.profiles[0][field] = json!({"elements":elements});
    }
    let outputs = thumble_core::profile_owned_outputs(&state.profiles[0]);
    assert_eq!(outputs.len(), 384);
    let mut keys = thumble_core::ButtonBindings::default();
    for (id, output) in outputs.iter_ids() {
        keys.insert(id, output.keyboard.clone().unwrap());
    }
    state.output_bindings = outputs.clone();
    state.key_bindings = keys.clone();
    state
        .profile_output_bindings
        .insert(thumble_core::DEFAULT_PROFILE_ID.into(), outputs);
    state
        .profile_key_bindings
        .insert(thumble_core::DEFAULT_PROFILE_ID.into(), keys);
    state.normalize().unwrap();
    let document = ConfigurationDocument::from_state(&state).unwrap();
    let artifact = thumble_core::ProfileArtifact::from_configuration(
        &document,
        thumble_core::ProfileArtifactSelection::All,
        0,
    )
    .unwrap();
    assert_eq!(
        artifact
            .to_configuration_document()
            .unwrap()
            .key_bindings
            .len(),
        384
    );
}

#[test]
fn orientation_declarations_are_valid_binding_owners_and_empty_maps_stay_empty() {
    let mut state = PersistentState::minimal("server").unwrap();
    state.profiles[0]["portraitCustomization"] =
        json!({"elements":[{"id":ORPHAN,"kind":"button"}]});
    state.key_bindings.insert(
        thumble_protocol::KeypadElementID::parse(ORPHAN).unwrap(),
        thumble_core::KeyBinding::new(49, 0),
    );
    state.normalize().unwrap();
    ConfigurationDocument::from_state(&state).unwrap();
    state.profiles[0]["customization"] = json!({"elements":[]});
    state.profiles[0]
        .as_object_mut()
        .unwrap()
        .remove("portraitCustomization");
    state.key_bindings = Default::default();
    state.output_bindings = Default::default();
    state.profile_key_bindings.clear();
    state.profile_output_bindings.clear();
    let before = state.clone();
    state.normalize().unwrap();
    assert_eq!(state, before);
    ConfigurationDocument::from_state(&state).unwrap();
}
