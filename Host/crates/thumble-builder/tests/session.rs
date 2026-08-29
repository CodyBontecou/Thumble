use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use thumble_builder::*;

const SESSION_ID: &str = "10000000-0000-0000-0000-000000000001";
const OP1: &str = "20000000-0000-0000-0000-000000000001";
const OP2: &str = "20000000-0000-0000-0000-000000000002";
const OP3: &str = "20000000-0000-0000-0000-000000000003";
const OP4: &str = "20000000-0000-0000-0000-000000000004";
const OP5: &str = "20000000-0000-0000-0000-000000000005";
const OP6: &str = "20000000-0000-0000-0000-000000000006";
const OP7: &str = "20000000-0000-0000-0000-000000000007";
const DEFAULT_JUMP: &str = "00000000-0000-0000-0000-000000000105";

/// Trusted persistence inspection used only by integration tests. Production
/// code has no raw document/operation accessor; tool projections use the
/// bounded status, preview, validation, and artifact APIs.
trait TrustedPersistenceTestExt {
    fn document(&self) -> &'static thumble_core::ConfigurationDocument;
    fn operations(&self) -> &'static [Value];
}

impl TrustedPersistenceTestExt for BuilderSession {
    fn document(&self) -> &'static thumble_core::ConfigurationDocument {
        let persisted: Value = serde_json::from_slice(&self.encode_json().unwrap()).unwrap();
        Box::leak(Box::new(
            serde_json::from_value(persisted["document"].clone()).unwrap(),
        ))
    }

    fn operations(&self) -> &'static [Value] {
        let persisted: Value = serde_json::from_slice(&self.encode_json().unwrap()).unwrap();
        Box::leak(
            persisted["operations"]
                .as_array()
                .unwrap()
                .clone()
                .into_boxed_slice(),
        )
    }
}

fn session() -> BuilderSession {
    BuilderSession::begin(SESSION_ID, 1_000, 10_000).unwrap()
}

fn operation_id(index: usize) -> String {
    format!("30000000-0000-0000-0000-{index:012x}")
}

fn refresh_document_digest(value: &mut Value) {
    let bytes = serde_json_canonicalizer::to_vec(&value["document"]).unwrap();
    value["documentDigest"] = json!(format!("{:x}", Sha256::digest(bytes)));
}

fn simple_spec() -> Vec<u8> {
    serde_json::to_vec(&json!({
        "schemaVersion": 1,
        "gameName": "Builder Game",
        "source": "RAW-SOURCE-MUST-NOT-LEAK",
        "notes": ["RAW-NOTE-MUST-NOT-LEAK"],
        "controls": [
            {"id":"primary", "button":"jump", "label":"Jump", "key":"space", "modifiers":["shift"], "x":0.75, "y":0.7},
            {"id":"extra", "button":"custom1", "label":"Extra", "key":"K", "modifiers":[], "x":0.55, "y":0.4}
        ]
    }))
    .unwrap()
}

#[test]
fn lifecycle_status_validate_preview_expiry_and_discard_boundaries() {
    let mut session = session();
    let status = session.status(1_000).unwrap();
    assert_eq!(status.state, BuilderSessionState::Active);
    assert_eq!(status.revision, 1);
    assert_eq!(status.profile_count, 1);
    assert_eq!(status.operation_count, 0);
    assert_eq!(status.profiles[0].name, "Default");

    let validation = session.validate(1_000).unwrap();
    assert!(validation.valid);
    let preview = session.preview(1_000).unwrap();
    assert_eq!(preview.profile.name, "Default");
    assert!(!preview.elements.is_empty());

    assert_eq!(
        session.status(11_000).unwrap().state,
        BuilderSessionState::Expired
    );
    assert_eq!(session.preview(10_999).unwrap().profile.name, "Default");
    assert_eq!(session.preview(11_000), Err(BuilderError::SessionExpired));

    let receipt = session.discard(1, 10_999).unwrap();
    assert_eq!(receipt.session_id, SESSION_ID);
    assert_eq!(
        session.status(10_999).unwrap().state,
        BuilderSessionState::Discarded
    );
    assert_eq!(
        session.apply_edit(
            OP1,
            1,
            BuilderEdit::ProfileRename { name: "No".into() },
            10_999,
        ),
        Err(BuilderError::SessionDiscarded)
    );
}

#[test]
fn all_edit_variants_apply_and_keep_active_maps_synchronized() {
    let mut session = session();
    let rename = session
        .apply_edit(
            OP1,
            1,
            BuilderEdit::ProfileRename {
                name: "Arcade".into(),
            },
            1_001,
        )
        .unwrap();
    assert!(rename.changed);
    assert_eq!(rename.result_revision, 2);
    assert_eq!(session.document().profiles[0]["updatedAt"], 1_001);

    let layout = session
        .apply_edit(
            OP2,
            2,
            BuilderEdit::ControlLayout {
                element_id: DEFAULT_JUMP.into(),
                x: Some(0.8),
                y: Some(0.7),
                width: Some(1.25),
                height: Some(0.75),
                hidden: Some(true),
                locked: Some(true),
            },
            1_002,
        )
        .unwrap();
    assert!(layout.changed);
    let jump = session.document().profiles[0]["customization"]["elements"]
        .as_array()
        .unwrap()
        .iter()
        .find(|element| element["id"] == DEFAULT_JUMP)
        .unwrap();
    assert_eq!(jump["layout"]["centerX"], 0.8);
    assert_eq!(jump["layout"]["isHidden"], true);

    session
        .apply_edit(
            OP3,
            3,
            BuilderEdit::BindingSet {
                button: "jump".into(),
                key: "space-bar".into(),
                modifiers: vec!["cmd".into(), "control".into()],
            },
            1_003,
        )
        .unwrap();
    let active = session.document().active_profile_id.clone();
    let key = session.document().key_bindings.get_raw("jump").unwrap();
    assert_eq!(key.key_code, 49);
    assert_eq!(key.modifiers, 9);
    assert_eq!(
        session.document().profile_key_bindings[&active],
        session.document().key_bindings
    );
    assert_eq!(
        session
            .document()
            .output_bindings
            .get_raw("jump")
            .unwrap()
            .keyboard
            .as_ref(),
        Some(key)
    );

    session
        .apply_edit(
            OP4,
            4,
            BuilderEdit::BindingClear {
                button: "jump".into(),
            },
            1_004,
        )
        .unwrap();
    assert!(session.document().key_bindings.get_raw("jump").is_none());
    assert!(session.document().output_bindings.get_raw("jump").is_none());

    session
        .apply_edit(
            OP5,
            5,
            BuilderEdit::OutputMode {
                mode: BuilderOutputMode::Controller,
            },
            1_005,
        )
        .unwrap();
    assert_eq!(session.document().profiles[0]["outputMode"], "controller");
    session
        .apply_edit(
            OP6,
            6,
            BuilderEdit::OutputMode {
                mode: BuilderOutputMode::Custom,
            },
            1_006,
        )
        .unwrap();
    assert_eq!(session.document().profiles[0]["outputMode"], "custom");

    session
        .apply_edit(
            OP7,
            7,
            BuilderEdit::ControlRemove {
                element_id: DEFAULT_JUMP.into(),
            },
            1_007,
        )
        .unwrap();
    session
        .apply_edit(
            &operation_id(8),
            8,
            BuilderEdit::OutputMode {
                mode: BuilderOutputMode::Keyboard,
            },
            1_008,
        )
        .unwrap();
    assert_eq!(session.document().profiles[0]["outputMode"], "keyboard");
    assert!(!session.document().profiles[0]["customization"]["elements"]
        .as_array()
        .unwrap()
        .iter()
        .any(|element| element["id"] == DEFAULT_JUMP));
    session.validate(1_009).unwrap();
    session.preview(1_009).unwrap();
}

#[test]
fn edits_reject_unknown_fields_and_every_invalid_shape() {
    for value in [
        json!({"type":"profile.rename","name":"ok","owner":"bad"}),
        json!({"type":"control.layout","elementID":DEFAULT_JUMP,"z":1}),
        json!({"type":"arbitrary.patch","path":"/"}),
    ] {
        assert!(serde_json::from_value::<BuilderEdit>(value).is_err());
    }

    let invalid = [
        BuilderEdit::ProfileRename { name: " ".into() },
        BuilderEdit::ControlLayout {
            element_id: DEFAULT_JUMP.into(),
            x: None,
            y: None,
            width: None,
            height: None,
            hidden: None,
            locked: None,
        },
        BuilderEdit::ControlLayout {
            element_id: DEFAULT_JUMP.into(),
            x: Some(-0.1),
            y: None,
            width: None,
            height: None,
            hidden: None,
            locked: None,
        },
        BuilderEdit::ControlLayout {
            element_id: DEFAULT_JUMP.into(),
            x: None,
            y: None,
            width: Some(0.0),
            height: None,
            hidden: None,
            locked: None,
        },
        BuilderEdit::ControlRemove {
            element_id: "missing".into(),
        },
        BuilderEdit::BindingSet {
            button: "Jump".into(),
            key: "Space".into(),
            modifiers: vec![],
        },
        BuilderEdit::BindingSet {
            button: "jump".into(),
            key: "hyper-key".into(),
            modifiers: vec![],
        },
        BuilderEdit::BindingSet {
            button: "jump".into(),
            key: "Space".into(),
            modifiers: vec!["hyper".into()],
        },
        BuilderEdit::BindingClear {
            button: "south".into(),
        },
    ];
    for (index, edit) in invalid.into_iter().enumerate() {
        let mut session = session();
        assert!(session
            .apply_edit(&operation_id(index + 1), 1, edit, 1_001)
            .is_err());
        assert_eq!(session.revision(), 1);
        assert!(session.operations().is_empty());
    }
}

#[test]
fn replay_conflict_noop_and_expected_revision_contract() {
    let mut session = session();
    let edit = BuilderEdit::ProfileRename {
        name: "Replay".into(),
    };
    let first = session.apply_edit(OP1, 1, edit.clone(), 1_001).unwrap();
    let replay = session.apply_edit(OP1, 1, edit, 1_002).unwrap();
    assert_eq!(first, replay);
    assert_eq!(session.operations().len(), 1);
    assert_eq!(session.updated_at(), 1_001);

    assert_eq!(
        session.apply_edit(
            OP1,
            1,
            BuilderEdit::ProfileRename {
                name: "Conflict".into()
            },
            1_002,
        ),
        Err(BuilderError::OperationConflict)
    );
    assert!(matches!(
        session.apply_edit(
            OP2,
            1,
            BuilderEdit::ProfileRename {
                name: "Wrong base".into()
            },
            1_002,
        ),
        Err(BuilderError::RevisionConflict { .. })
    ));

    let noop = session
        .apply_edit(
            OP2,
            2,
            BuilderEdit::ProfileRename {
                name: "Replay".into(),
            },
            1_002,
        )
        .unwrap();
    assert!(!noop.changed);
    assert_eq!(noop.base_revision, noop.result_revision);
    assert!(noop.changed_paths.is_empty());
    assert_eq!(session.revision(), 2);
}

#[test]
fn operation_limit_allows_replay_but_rejects_new_operations() {
    let mut session = BuilderSession::begin(SESSION_ID, 0, 86_400).unwrap();
    for index in 1..=MAXIMUM_BUILDER_OPERATIONS {
        let record = session
            .apply_edit(
                &operation_id(index),
                1,
                BuilderEdit::ProfileRename {
                    name: "Default".into(),
                },
                index as i64,
            )
            .unwrap();
        assert!(!record.changed);
    }
    assert_eq!(session.operations().len(), MAXIMUM_BUILDER_OPERATIONS);
    assert_eq!(
        session.apply_edit(
            &operation_id(MAXIMUM_BUILDER_OPERATIONS + 1),
            1,
            BuilderEdit::ProfileRename {
                name: "Default".into()
            },
            300,
        ),
        Err(BuilderError::OperationLimitReached)
    );
    assert!(session
        .apply_edit(
            &operation_id(1),
            1,
            BuilderEdit::ProfileRename {
                name: "Default".into()
            },
            300,
        )
        .is_ok());
}

#[test]
fn generation_is_deterministic_sanitized_and_replayable() {
    let spec = simple_spec();
    let mut left = session();
    let mut right = session();
    let first = left
        .generate_from_spec(OP1, 1, &spec, Some("Builder Game"), 1_001)
        .unwrap();
    let second = right
        .generate_from_spec(OP1, 1, &spec, Some("Builder Game"), 1_001)
        .unwrap();
    assert_eq!(
        serde_json::to_value(&first).unwrap(),
        serde_json::to_value(&second).unwrap()
    );
    assert_eq!(left.document(), right.document());
    assert_eq!(first.base_revision, 1);
    assert_eq!(first.result_revision, 2);
    assert_eq!(first.profile_name, "Builder Game");

    let summary_json = serde_json::to_string(&first).unwrap();
    for forbidden in [
        "RAW-SOURCE-MUST-NOT-LEAK",
        "RAW-NOTE-MUST-NOT-LEAK",
        "artifactJSON",
        "generatedJSON",
        "keyCode",
        "normalizedDescriptor",
        "customization",
    ] {
        assert!(!summary_json.contains(forbidden), "{forbidden}");
    }
    let replay = left
        .generate_from_spec(OP1, 1, &spec, Some("Builder Game"), 1_002)
        .unwrap();
    assert_eq!(
        serde_json::to_value(first).unwrap(),
        serde_json::to_value(replay).unwrap()
    );
    assert_eq!(left.operations().len(), 1);
}

#[test]
fn generation_replacement_noop_conflict_and_emission_invalidation() {
    let spec = simple_spec();
    let mut session = session();
    session.emit_artifact(1, 1_001).unwrap();
    let replaced = session
        .generate_from_spec(OP1, 1, &spec, None, 1_002)
        .unwrap();
    assert!(replaced.changed);
    assert_eq!(replaced.result_revision, 2);
    assert!(session.emitted_artifact_receipt().is_none());
    assert_eq!(session.document().profiles.len(), 1);
    assert_eq!(session.document().profiles[0]["name"], "Builder Game");

    let noop = session
        .generate_from_spec(OP2, 2, &spec, None, 1_003)
        .unwrap();
    assert!(!noop.changed);
    assert_eq!(noop.base_revision, noop.result_revision);
    assert_eq!(session.revision(), 2);

    let mut changed_spec: Value = serde_json::from_slice(&spec).unwrap();
    changed_spec["gameName"] = json!("Other Game");
    assert!(matches!(
        session.generate_from_spec(
            OP2,
            2,
            &serde_json::to_vec(&changed_spec).unwrap(),
            None,
            1_004,
        ),
        Err(BuilderError::OperationConflict)
    ));
    assert_eq!(session.revision(), 2);
    assert_eq!(session.operations().len(), 2);
}

#[test]
fn generated_custom_layout_is_synchronized_and_generation_errors_are_atomic() {
    let mut session = session();
    let summary = session
        .generate_from_spec(OP1, 1, &simple_spec(), None, 1_001)
        .unwrap();
    let custom_id = summary
        .assigned_controls
        .iter()
        .find(|control| control.button == "custom1")
        .unwrap()
        .element_id
        .clone();
    session
        .apply_edit(
            OP2,
            2,
            BuilderEdit::ControlLayout {
                element_id: custom_id.clone(),
                x: Some(0.2),
                y: None,
                width: None,
                height: None,
                hidden: Some(true),
                locked: None,
            },
            1_002,
        )
        .unwrap();
    let customization = &session.document().profiles[0]["customization"];
    let element = customization["elements"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == custom_id)
        .unwrap();
    let custom = customization["customButtons"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == custom_id)
        .unwrap();
    assert_eq!(element["layout"]["centerX"], 0.2);
    assert_eq!(custom["layout"]["centerX"], 0.2);
    assert_eq!(custom["layout"]["isHidden"], true);

    let before = session.encode_json().unwrap();
    assert!(session
        .generate_from_spec(
            OP3,
            3,
            br#"{"controls":[],"unsafePath":"/tmp"}"#,
            None,
            1_003
        )
        .is_err());
    assert_eq!(session.encode_json().unwrap(), before);
}

#[test]
fn artifact_repeat_hash_handoff_and_change_invalidation() {
    let mut session = session();
    let first = session.emit_artifact(1, 1_001).unwrap();
    let second = session.emit_artifact(1, 1_002).unwrap();
    assert_eq!(first, second);
    assert!(first.artifact_json.contains(&first.receipt.content_hash));
    let artifact: Value = serde_json::from_str(&first.artifact_json).unwrap();
    assert_eq!(artifact["exportedAt"], 0);
    let handoff = session.mark_emitted(1, 1_002).unwrap();
    assert!(handoff.delete_session);
    assert_eq!(handoff.content_hash, first.receipt.content_hash);

    session
        .apply_edit(
            OP1,
            1,
            BuilderEdit::ProfileRename {
                name: "Changed".into(),
            },
            1_003,
        )
        .unwrap();
    assert!(session.emitted_artifact_receipt().is_none());
    assert_eq!(
        session.mark_emitted(2, 1_003),
        Err(BuilderError::ArtifactNotEmitted)
    );
    let changed = session.emit_artifact(2, 1_004).unwrap();
    assert_ne!(changed.receipt.content_hash, first.receipt.content_hash);
}

#[test]
fn serialization_round_trip_rebuilds_cache_and_rejects_tampering() {
    let mut session = session();
    session.emit_artifact(1, 1_001).unwrap();
    let encoded = session.encode_json().unwrap();
    let mut decoded = BuilderSession::decode_json(&encoded).unwrap();
    assert_eq!(decoded, session);
    assert_eq!(
        decoded.emit_artifact(1, 1_002).unwrap().artifact_json,
        session.emit_artifact(1, 1_002).unwrap().artifact_json
    );

    let value: Value = serde_json::from_slice(&encoded).unwrap();
    let mut cases = Vec::new();
    let mut unknown = value.clone();
    unknown["owner"] = json!("principal");
    cases.push(unknown);
    let mut revision = value.clone();
    revision["revision"] = json!(2);
    cases.push(revision);
    let mut hash = value.clone();
    hash["emittedArtifactReceipt"]["contentHash"] = json!("0".repeat(64));
    cases.push(hash);
    let mut document_unknown = value.clone();
    document_unknown["document"]["credentials"] = json!(["secret"]);
    cases.push(document_unknown);
    let mut nested_credential = value.clone();
    nested_credential["document"]["profiles"][0]["future"]["accessToken"] = json!("secret");
    cases.push(nested_credential);
    let mut expiry = value;
    expiry["expiresAt"] = json!(1000 + MAXIMUM_BUILDER_SESSION_TTL_SECONDS + 1);
    cases.push(expiry);
    for case in cases {
        assert!(BuilderSession::decode_json(&serde_json::to_vec(&case).unwrap()).is_err());
    }
    assert_eq!(
        BuilderSession::decode_json(&vec![b' '; MAXIMUM_BUILDER_SESSION_JSON_BYTES + 1]),
        Err(BuilderError::SessionJsonTooLarge(
            MAXIMUM_BUILDER_SESSION_JSON_BYTES + 1
        ))
    );
}

#[test]
fn custom_deserialize_rejects_valid_shape_document_and_history_tampering() {
    let mut session = session();
    session
        .apply_edit(
            OP1,
            1,
            BuilderEdit::ProfileRename {
                name: "Integrity".into(),
            },
            1_010,
        )
        .unwrap();
    let original = serde_json::to_value(&session).unwrap();

    let mut cases = Vec::new();
    let mut document = original.clone();
    document["document"]["profiles"][0]["name"] = json!("Valid but tampered");
    cases.push(document);
    let mut document_digest = original.clone();
    document_digest["documentDigest"] = json!("0".repeat(64));
    cases.push(document_digest);
    let mut descriptor = original.clone();
    descriptor["operations"][0]["descriptor"]["name"] = json!("Other");
    cases.push(descriptor);
    let mut descriptor_digest = original.clone();
    descriptor_digest["operations"][0]["descriptorDigest"] = json!("1".repeat(64));
    cases.push(descriptor_digest);
    let mut base_revision = original.clone();
    base_revision["operations"][0]["baseRevision"] = json!(2);
    cases.push(base_revision);
    let mut result_revision = original.clone();
    result_revision["operations"][0]["resultRevision"] = json!(1);
    cases.push(result_revision);
    let mut changed_paths = original.clone();
    changed_paths["operations"][0]["changedPaths"] =
        json!(["/profiles/active/outputMode", "/profiles/active/updatedAt"]);
    cases.push(changed_paths);
    let mut applied_at = original;
    applied_at["operations"][0]["appliedAt"] = json!(999);
    cases.push(applied_at);

    for case in cases {
        let text = serde_json::to_string(&case).unwrap();
        assert!(serde_json::from_str::<BuilderSession>(&text).is_err());
        assert!(BuilderSession::decode_json(text.as_bytes()).is_err());
    }
}

#[test]
fn canonical_active_profile_id_prevents_case_variant_binding_maps() {
    let session = session();
    let canonical_id = session.document().active_profile_id.clone();
    let mut persisted = serde_json::to_value(&session).unwrap();
    persisted["document"]["activeProfileID"] = json!(canonical_id.to_ascii_uppercase());
    refresh_document_digest(&mut persisted);
    let mut decoded: BuilderSession = serde_json::from_value(persisted).unwrap();
    decoded
        .apply_edit(
            OP1,
            1,
            BuilderEdit::BindingSet {
                button: "jump".into(),
                key: "space-bar".into(),
                modifiers: vec![],
            },
            1_001,
        )
        .unwrap();
    assert_eq!(decoded.document().active_profile_id, canonical_id);
    assert!(decoded
        .document()
        .profile_key_bindings
        .contains_key(&canonical_id));
    assert!(!decoded
        .document()
        .profile_key_bindings
        .keys()
        .any(|key| key != &canonical_id && key.eq_ignore_ascii_case(&canonical_id)));
}

#[test]
fn binding_edits_sync_all_variants_preview_and_preserve_gamepad_output() {
    let session = session();
    let mut persisted = serde_json::to_value(&session).unwrap();
    let customization = persisted["document"]["profiles"][0]["customization"].clone();
    persisted["document"]["profiles"][0]["landscapeCustomization"] = customization.clone();
    persisted["document"]["profiles"][0]["portraitCustomization"] = customization;
    refresh_document_digest(&mut persisted);
    let mut decoded: BuilderSession = serde_json::from_value(persisted).unwrap();

    decoded
        .apply_edit(
            OP1,
            1,
            BuilderEdit::BindingSet {
                button: "jump".into(),
                key: "space-bar".into(),
                modifiers: vec!["shift".into()],
            },
            1_001,
        )
        .unwrap();
    for key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let element = decoded.document().profiles[0][key]["elements"]
            .as_array()
            .unwrap()
            .iter()
            .find(|element| element["id"] == DEFAULT_JUMP)
            .unwrap();
        assert_eq!(element["output"]["keyboard"]["keyCode"], 49);
        assert_eq!(element["output"]["keyboard"]["modifiersRawValue"], 2);
    }
    let preview = serde_json::to_string(&decoded.preview(1_001).unwrap()).unwrap();
    assert!(preview.contains("Space"));

    let mut with_gamepad = serde_json::to_value(&decoded).unwrap();
    let active_id = decoded.document().active_profile_id.clone();
    for map in ["outputBindings", "profileOutputBindings"] {
        let output = if map == "outputBindings" {
            &mut with_gamepad["document"][map]["jump"]
        } else {
            &mut with_gamepad["document"][map][&active_id]["jump"]
        };
        output["gamepadButtons"] = json!(["south"]);
    }
    for key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let elements = with_gamepad["document"]["profiles"][0][key]["elements"]
            .as_array_mut()
            .unwrap();
        let element = elements
            .iter_mut()
            .find(|element| element["id"] == DEFAULT_JUMP)
            .unwrap();
        element["output"]["gamepadButtons"] = json!(["south"]);
    }
    refresh_document_digest(&mut with_gamepad);
    let mut decoded: BuilderSession = serde_json::from_value(with_gamepad).unwrap();
    decoded
        .apply_edit(
            OP2,
            2,
            BuilderEdit::BindingClear {
                button: "jump".into(),
            },
            1_002,
        )
        .unwrap();
    let output = decoded.document().output_bindings.get_raw("jump").unwrap();
    assert!(output.keyboard.is_none());
    assert!(output.gamepad_buttons.contains("south"));
    for key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let element = decoded.document().profiles[0][key]["elements"]
            .as_array()
            .unwrap()
            .iter()
            .find(|element| element["id"] == DEFAULT_JUMP)
            .unwrap();
        assert!(element["output"].get("keyboard").is_none());
        assert_eq!(element["output"]["gamepadButtons"], json!(["south"]));
    }
}

#[test]
fn receipt_history_is_exact_stable_after_decode_and_rejects_early_emission() {
    let mut session = session();
    session
        .apply_edit(
            OP1,
            1,
            BuilderEdit::ProfileRename {
                name: "Receipt".into(),
            },
            1_010,
        )
        .unwrap();
    let first = session.emit_artifact(2, 1_020).unwrap();
    assert_eq!(
        first.receipt.document_digest,
        session.configuration_digest()
    );
    let encoded = session.encode_json().unwrap();
    let mut decoded = BuilderSession::decode_json(&encoded).unwrap();
    let repeat = decoded.emit_artifact(2, 1_021).unwrap();
    assert_eq!(
        serde_json::to_vec(&repeat).unwrap(),
        serde_json::to_vec(&first).unwrap()
    );

    let mut early: Value = serde_json::from_slice(&encoded).unwrap();
    early["emittedArtifactReceipt"]["emittedAt"] = json!(1_009);
    assert!(serde_json::from_value::<BuilderSession>(early).is_err());
}

#[test]
fn generation_errors_are_structured_bounded_and_do_not_echo_user_input() {
    for (spec, secret) in [
        (
            json!({"controls":[], "unknown-field-SECRET": "value"}),
            "unknown-field-SECRET",
        ),
        (
            json!({"controls":[], format!("{}Path", "X".repeat(20_000)): "/secret"}),
            "/secret",
        ),
        (
            json!({"controls":[{"label":"x","key":"SECRET-KEY-VALUE"}]}),
            "SECRET-KEY-VALUE",
        ),
    ] {
        let mut session = session();
        let error = match session.generate_from_spec(
            OP1,
            1,
            &serde_json::to_vec(&spec).unwrap(),
            None,
            1_001,
        ) {
            Ok(_) => panic!("expected generation failure"),
            Err(error) => error,
        };
        let message = error.to_string();
        assert!(message.len() < 160, "{message}");
        assert!(!message.contains(secret), "{message}");
        let BuilderError::Generation(failure) = error else {
            panic!("expected structured generation error");
        };
        assert!(!failure.code.is_empty());
    }
}

#[test]
fn status_omits_profiles_over_projection_bound() {
    let session = session();
    let mut persisted = serde_json::to_value(&session).unwrap();
    let template = persisted["document"]["profiles"][0].clone();
    let profiles = persisted["document"]["profiles"].as_array_mut().unwrap();
    for index in 1..=MAXIMUM_BUILDER_STATUS_PROFILES {
        let mut profile = template.clone();
        profile["id"] = json!(format!("00000000-0000-0000-0001-{index:012x}"));
        profile["name"] = json!(format!("Profile {index}"));
        profiles.push(profile);
    }
    refresh_document_digest(&mut persisted);
    let decoded: BuilderSession = serde_json::from_value(persisted).unwrap();
    let status = decoded.status(1_001).unwrap();
    assert_eq!(status.profile_count, MAXIMUM_BUILDER_STATUS_PROFILES + 1);
    assert_eq!(status.profiles.len(), MAXIMUM_BUILDER_STATUS_PROFILES);
    assert_eq!(status.omitted_profile_count, 1);
    let encoded = serde_json::to_string(&status).unwrap();
    assert!(!encoded.contains("customization"));
}

#[test]
fn begin_emit_discard_and_edit_reject_non_i_json_timestamps_atomically() {
    let unsafe_integer = MAXIMUM_I_JSON_SAFE_INTEGER + 1;
    assert_eq!(
        BuilderSession::begin(SESSION_ID, unsafe_integer, 1),
        Err(BuilderError::TimestampOverflow)
    );
    assert_eq!(
        BuilderSession::begin(SESSION_ID, MAXIMUM_I_JSON_SAFE_INTEGER, 1),
        Err(BuilderError::TimestampOverflow)
    );

    let mut session = session();
    let before = session.encode_json().unwrap();
    assert_eq!(
        session.apply_edit(
            OP1,
            1,
            BuilderEdit::ProfileRename {
                name: "Must remain atomic".into(),
            },
            unsafe_integer,
        ),
        Err(BuilderError::TimestampOverflow)
    );
    assert_eq!(session.encode_json().unwrap(), before);
    assert_eq!(session.revision(), 1);
    assert!(session.operations().is_empty());
    assert_eq!(
        session.emit_artifact(1, unsafe_integer),
        Err(BuilderError::TimestampOverflow)
    );
    assert_eq!(session.encode_json().unwrap(), before);
    assert_eq!(
        session.discard(1, unsafe_integer),
        Err(BuilderError::TimestampOverflow)
    );
    assert_eq!(session.encode_json().unwrap(), before);
    assert_eq!(
        session.status(unsafe_integer),
        Err(BuilderError::TimestampOverflow)
    );
}

#[test]
fn begin_rejects_bad_ids_ttl_and_timestamp_overflow() {
    assert_eq!(
        BuilderSession::begin("not-a-uuid", 0, 1),
        Err(BuilderError::InvalidSessionId)
    );
    assert_eq!(
        BuilderSession::begin(SESSION_ID, 0, 0),
        Err(BuilderError::InvalidTtl(0))
    );
    assert_eq!(
        BuilderSession::begin(SESSION_ID, 0, MAXIMUM_BUILDER_SESSION_TTL_SECONDS + 1),
        Err(BuilderError::InvalidTtl(
            MAXIMUM_BUILDER_SESSION_TTL_SECONDS + 1
        ))
    );
    assert_eq!(
        BuilderSession::begin(SESSION_ID, i64::MAX, 1),
        Err(BuilderError::TimestampOverflow)
    );
}

#[test]
fn preview_and_status_are_sanitized_projections_and_persisted_host_fields_fail() {
    let session = session();
    let preview = serde_json::to_string(&session.preview(1_001).unwrap()).unwrap();
    let status = serde_json::to_string(&session.status(1_001).unwrap()).unwrap();
    for forbidden in [
        "credential-free-builder",
        "builder-preview",
        "serverID",
        "trustedClients",
        "launchTarget",
        "keyCode",
        "document",
        "operations",
    ] {
        assert!(!preview.contains(forbidden), "preview leaked {forbidden}");
        assert!(!status.contains(forbidden), "status leaked {forbidden}");
    }

    for field in [
        "launchTarget",
        "path",
        "data",
        "credentials",
        "deviceID",
        "pairingCode",
        "processID",
    ] {
        let mut persisted = serde_json::to_value(&session).unwrap();
        persisted["document"]["profiles"][0][field] = json!("sensitive-value");
        assert!(
            serde_json::from_value::<BuilderSession>(persisted).is_err(),
            "{field}"
        );
    }
}
