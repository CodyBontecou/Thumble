use serde_json::{json, Value};
use std::collections::BTreeSet;
use thumble_builder::*;
use thumble_core::ProfileArtifact;
use uuid::Uuid;

const SESSION: &str = "10000000-0000-5000-8000-000000000001";
const OTHER_SESSION: &str = "10000000-0000-5000-8000-000000000002";
const OPERATION: &str = "20000000-0000-5000-8000-000000000001";
const OTHER_OPERATION: &str = "20000000-0000-5000-8000-000000000002";
const CANONICAL_PROFILE: &str = "0F38B980-9D36-56B6-8425-826EA40B149D";
/// Trusted persistence inspection used only by integration tests. Production
/// code intentionally exposes no raw configuration or operation accessor.
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

const CANONICAL_CUSTOM_IDS: [&str; 15] = [
    "C5EC51F7-C610-572F-9171-A8699D614ED6",
    "0371280B-F6EE-5EB4-BA12-89D240745D3C",
    "D0DE67B0-4F62-5ED1-B421-2B5AAF3CD2A1",
    "A91AA704-1EDD-5E98-925A-40708B689194",
    "BAC5A253-EE3E-56CA-9D16-8C04ED39DAA1",
    "B3DB7E55-B514-522B-BBFD-AB2754BF0522",
    "EFD4CC6A-AD8A-51FE-B17E-0A2C672989D2",
    "DE252A56-0FF1-5086-AA0E-798E72E3032A",
    "0F671A9F-3933-52ED-90E6-9A03264B0E8A",
    "9B0368A6-A8D1-582C-A0DF-46D26639F8AC",
    "95C3643D-784D-5F89-BB9E-BC6F6E3CDBBE",
    "D78CC1A8-D829-5EAB-B8C7-E3058FE7B1AE",
    "1CF4C828-7A75-5FC1-AAD4-0956B6C8E6D1",
    "0210198D-7601-58A7-9FA1-BD1B7DA94DA2",
    "65264172-F6F4-52FF-AE72-85D4E70A3682",
];

fn session(id: &str) -> BuilderSession {
    BuilderSession::begin(id, 1_000, 10_000).unwrap()
}

fn custom_ids(document: &thumble_core::ConfigurationDocument) -> Vec<String> {
    document.profiles[0]["customization"]["customButtons"]
        .as_array()
        .unwrap()
        .iter()
        .map(|button| button["id"].as_str().unwrap().to_owned())
        .collect()
}

fn assert_updated_at_zero(value: &Value) {
    match value {
        Value::Array(values) => values.iter().for_each(assert_updated_at_zero),
        Value::Object(object) => {
            for (key, value) in object {
                if key == "updatedAt" {
                    assert_eq!(value.as_i64(), Some(0));
                }
                assert_updated_at_zero(value);
            }
        }
        _ => {}
    }
}

#[test]
fn catalog_is_exact_strict_and_matches_all_seventeen_revisions_and_counts() {
    validate_builder_template_fixtures().unwrap();
    let expected = [
        ("productivityStarter", 1, "Productivity Starter", "Everyday Mac navigation and shortcuts with tailored landscape and portrait layouts", 0),
        ("productivityOneHandedLeft", 1, "One-Handed Left", "Everyday Mac controls grouped in the lower-left thumb zone", 0),
        ("productivityOneHandedRight", 1, "One-Handed Right", "Everyday Mac controls grouped in the lower-right thumb zone", 0),
        ("nes", 1, "NES", "Classic console pad: D-pad, A/B, Select, Start", 0),
        ("snes", 2, "Super Nintendo", "Super Nintendo pad: D-pad, ABXY, L/R shoulders, Select, Start", 2),
        ("nintendo64", 1, "Nintendo 64", "Three-prong N64 layout with analog stick, Z trigger, and C-buttons", 8),
        ("gameCube", 1, "GameCube", "GameCube layout with oversized A, C-stick, shoulders, and Z", 5),
        ("gameBoy", 1, "Game Boy", "Classic handheld: D-pad, A/B, Select, Start", 0),
        ("gameBoyAdvance", 1, "Game Boy Advance", "GBA handheld: D-pad, A/B, L/R shoulders, Select, Start", 2),
        ("genesisSixButton", 1, "Genesis 6-Button", "Sega Genesis/Mega Drive pad with D-pad, A/B/C, X/Y/Z, Mode, Start", 2),
        ("saturn", 1, "Sega Saturn", "Sega Saturn six-button layout with D-pad, L/R, and Start", 4),
        ("dreamcast", 1, "Dreamcast", "Dreamcast layout with analog stick, D-pad, ABXY, L/R triggers, Start", 3),
        ("arcadeStick", 1, "Arcade Stick", "MAME/fight-stick layout with joystick, 8 buttons, Coin, and Start", 5),
        ("psp", 1, "PSP", "Portable emulator pad with D-pad, nub, shoulders, and face buttons", 3),
        ("playStation", 1, "PlayStation", "Dual-stick layout with PlayStation face symbols and shoulders", 6),
        ("xbox", 1, "Xbox", "Dual-stick Xbox-style layout with ABXY and triggers", 6),
        ("softWhite", 1, "Soft White Pro", "Premium soft-white neumorphic controller with layered shell, rings, plates, dual sticks, D-pad, ABXY, and shoulder controls", 15),
    ];
    assert_eq!(BuilderTemplate::ALL.len(), expected.len());
    for (template, (id, revision, display_name, description, count)) in
        BuilderTemplate::ALL.into_iter().zip(expected)
    {
        let metadata = template.metadata();
        assert_eq!(metadata.template_id, id);
        assert_eq!(metadata.revision, revision);
        assert_eq!(metadata.display_name, display_name);
        assert_eq!(metadata.description, description);
        assert_eq!(metadata.custom_element_id_count, count);
        assert_eq!(
            serde_json::from_value::<BuilderTemplate>(json!(id)).unwrap(),
            template
        );
    }
    assert!(serde_json::from_value::<BuilderTemplate>(json!("NES")).is_err());
    assert!(serde_json::from_value::<BuilderTemplate>(json!("unknown")).is_err());
}

#[test]
fn every_template_materializes_portably_and_rewrites_all_canonical_references() {
    for (index, template) in BuilderTemplate::ALL.into_iter().enumerate() {
        let operation = format!("20000000-0000-5000-8000-{index:012x}");
        let mut builder = session(SESSION);
        let summary = builder
            .install_template(&operation, 1, template, None, 1_001)
            .unwrap();
        assert_eq!(summary.template_id, template.template_id());
        assert_eq!(summary.template_revision, template.revision());
        assert_eq!(summary.base_revision, 1);
        assert_eq!(summary.result_revision, 2);
        assert!(summary.changed);
        assert_eq!(summary.profile_name, template.display_name());
        assert_eq!(
            summary.custom_element_count,
            template.custom_element_id_count()
        );
        assert_eq!(builder.document().profiles.len(), 1);
        assert_eq!(builder.document().active_profile_id, summary.profile_id);
        assert_eq!(builder.document().default_profile_id, summary.profile_id);
        assert_eq!(builder.document().profiles[0]["id"], summary.profile_id);
        assert_eq!(builder.document().profiles[0]["name"], summary.profile_name);
        assert_eq!(
            custom_ids(builder.document()).len(),
            summary.custom_element_count
        );
        assert_eq!(
            builder.document().profile_key_bindings[&summary.profile_id],
            builder.document().key_bindings
        );
        assert_eq!(
            builder.document().profile_output_bindings[&summary.profile_id],
            builder.document().output_bindings
        );
        assert!(!builder.document().key_bindings.is_empty());
        assert!(!builder.document().output_bindings.is_empty());
        assert_updated_at_zero(&builder.document().profiles[0]);

        let encoded = serde_json::to_string(builder.document()).unwrap();
        assert!(!encoded.contains(CANONICAL_PROFILE));
        for canonical in &CANONICAL_CUSTOM_IDS[..template.custom_element_id_count()] {
            assert!(!encoded.contains(canonical));
        }
        let generated_customs = custom_ids(builder.document());
        assert_eq!(
            generated_customs.iter().collect::<BTreeSet<_>>().len(),
            generated_customs.len()
        );
        for id in std::iter::once(&summary.profile_id).chain(generated_customs.iter()) {
            let parsed = Uuid::parse_str(id).unwrap();
            assert_eq!(parsed.get_version_num(), 5);
        }
        let preview = builder.preview(1_001).unwrap();
        assert_eq!(preview.profile.id, summary.profile_id);
        assert_eq!(preview.profile.name, summary.profile_name);
        let preview_ids = preview
            .elements
            .iter()
            .map(|element| element.id.as_str())
            .collect::<BTreeSet<_>>();
        assert_eq!(preview_ids.len(), preview.elements.len());
        let declared_profile_element_ids = [
            "customization",
            "landscapeCustomization",
            "portraitCustomization",
        ]
        .into_iter()
        .filter_map(|key| builder.document().profiles[0].get(key))
        .flat_map(|customization| {
            customization["elements"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|element| element["id"].as_str())
        })
        .collect::<BTreeSet<_>>();
        assert!(preview_ids.is_subset(&declared_profile_element_ids));
        assert!(builder.validate(1_001).unwrap().valid);

        let materialized = builder.document().clone();
        let emitted = builder.emit_artifact(2, 1_002).unwrap();
        assert_eq!(emitted.receipt.emitted_at, 1_002);
        assert_eq!(builder.updated_at(), 1_002);
        let artifact = ProfileArtifact::decode_json(emitted.artifact_json.as_bytes()).unwrap();
        assert_eq!(artifact.exported_at, 0);
        assert_eq!(
            artifact.active_profile_id.as_deref(),
            Some(summary.profile_id.as_str())
        );
        assert_eq!(
            artifact.default_profile_id.as_deref(),
            Some(summary.profile_id.as_str())
        );
        assert_eq!(artifact.profiles.len(), 1);
        assert_eq!(artifact.profiles[0]["id"], summary.profile_id);
        assert_eq!(artifact.profile_key_bindings.len(), 1);
        assert_eq!(artifact.profile_output_bindings.len(), 1);
        assert!(artifact
            .profile_key_bindings
            .contains_key(&summary.profile_id));
        assert!(artifact
            .profile_output_bindings
            .contains_key(&summary.profile_id));
        assert_updated_at_zero(&artifact.profiles[0]);
        let converted = artifact.to_configuration_document().unwrap();
        assert_eq!(converted, materialized);
        assert_eq!(converted.key_bindings, materialized.key_bindings);
        assert_eq!(converted.output_bindings, materialized.output_bindings);
        assert_eq!(
            converted.profile_key_bindings,
            materialized.profile_key_bindings
        );
        assert_eq!(
            converted.profile_output_bindings,
            materialized.profile_output_bindings
        );
        let preview_after_emission = builder.preview(1_002).unwrap();
        assert_eq!(
            preview_after_emission.elements.len(),
            preview.elements.len()
        );
        assert_eq!(
            preview_after_emission
                .elements
                .iter()
                .map(|element| element.id.as_str())
                .collect::<BTreeSet<_>>(),
            preview_ids
        );

        let sanitized = serde_json::to_string(&summary).unwrap();
        assert!(!sanitized.contains("customization"));
        assert!(!sanitized.contains("keyCode"));
        assert!(!sanitized.contains(CANONICAL_PROFILE));
        assert!(!emitted.artifact_json.contains(CANONICAL_PROFILE));
        for canonical in &CANONICAL_CUSTOM_IDS[..template.custom_element_id_count()] {
            assert!(!emitted.artifact_json.contains(canonical));
        }
    }
}

#[test]
fn template_ids_are_deterministic_and_separated_by_operation_and_session() {
    let mut left = session(SESSION);
    let mut right = session(SESSION);
    let left_summary = left
        .install_template(OPERATION, 1, BuilderTemplate::SoftWhite, None, 1_001)
        .unwrap();
    let right_summary = right
        .install_template(OPERATION, 1, BuilderTemplate::SoftWhite, None, 1_009)
        .unwrap();
    assert_eq!(left_summary, right_summary);
    assert_eq!(left.document(), right.document());

    let mut other_operation = session(SESSION);
    let operation_summary = other_operation
        .install_template(OTHER_OPERATION, 1, BuilderTemplate::SoftWhite, None, 1_001)
        .unwrap();
    assert_ne!(left_summary.profile_id, operation_summary.profile_id);
    assert_ne!(
        custom_ids(left.document()),
        custom_ids(other_operation.document())
    );

    let mut other_session = session(OTHER_SESSION);
    let session_summary = other_session
        .install_template(OPERATION, 1, BuilderTemplate::SoftWhite, None, 1_001)
        .unwrap();
    assert_ne!(left_summary.profile_id, session_summary.profile_id);
    assert_ne!(
        custom_ids(left.document()),
        custom_ids(other_session.document())
    );
}

#[test]
fn replay_conflicts_revision_name_validation_and_persistence_are_strict() {
    let mut builder = session(SESSION);
    let first = builder
        .install_template(
            OPERATION,
            1,
            BuilderTemplate::Snes,
            Some("  My SNES  "),
            1_001,
        )
        .unwrap();
    assert_eq!(first.profile_name, "My SNES");
    let document = builder.document().clone();
    let replay = builder
        .install_template(OPERATION, 1, BuilderTemplate::Snes, Some("My SNES"), 1_002)
        .unwrap();
    assert_eq!(first, replay);
    assert_eq!(builder.document(), &document);
    assert_eq!(builder.operations().len(), 1);

    assert_eq!(
        builder.install_template(OPERATION, 1, BuilderTemplate::Nes, Some("My SNES"), 1_003,),
        Err(BuilderError::OperationConflict)
    );
    assert_eq!(
        builder.install_template(
            OPERATION,
            1,
            BuilderTemplate::Snes,
            Some("Different"),
            1_003,
        ),
        Err(BuilderError::OperationConflict)
    );
    assert_eq!(
        builder.install_template(OTHER_OPERATION, 1, BuilderTemplate::Nes, None, 1_003,),
        Err(BuilderError::RevisionConflict {
            expected: 1,
            actual: 2
        })
    );
    for name in ["", "   ", "bad\nname"] {
        let mut invalid = session(SESSION);
        assert_eq!(
            invalid.install_template(OPERATION, 1, BuilderTemplate::Nes, Some(name), 1_001),
            Err(BuilderError::InvalidProfileName)
        );
    }
    let mut invalid = session(SESSION);
    assert_eq!(
        invalid.install_template(
            OPERATION,
            1,
            BuilderTemplate::Nes,
            Some(&"x".repeat(257)),
            1_001,
        ),
        Err(BuilderError::InvalidProfileName)
    );

    let encoded = builder.encode_json().unwrap();
    let decoded = BuilderSession::decode_json(&encoded).unwrap();
    assert_eq!(decoded, builder);
}

#[test]
fn preview_artifact_and_emission_invalidation_follow_template_revisions() {
    let mut builder = session(SESSION);
    let first = builder
        .install_template(OPERATION, 1, BuilderTemplate::Nes, None, 1_001)
        .unwrap();
    let emitted = builder.emit_artifact(2, 1_002).unwrap();
    let artifact: Value = serde_json::from_str(&emitted.artifact_json).unwrap();
    assert_eq!(artifact["profiles"].as_array().unwrap().len(), 1);
    assert_eq!(artifact["profiles"][0]["id"], first.profile_id);
    assert!(builder.emitted_artifact_receipt().is_some());

    let second = builder
        .install_template(
            OTHER_OPERATION,
            2,
            BuilderTemplate::Nintendo64,
            Some("N64 Desk"),
            1_003,
        )
        .unwrap();
    assert_eq!(second.base_revision, 2);
    assert_eq!(second.result_revision, 3);
    assert_eq!(second.profile_name, "N64 Desk");
    assert!(builder.emitted_artifact_receipt().is_none());
    assert_eq!(
        builder.preview(1_003).unwrap().profile.id,
        second.profile_id
    );
    assert_ne!(first.profile_id, second.profile_id);

    let emitted = builder.emit_artifact(3, 1_004).unwrap();
    let artifact: Value = serde_json::from_str(&emitted.artifact_json).unwrap();
    assert_eq!(artifact["profiles"][0]["id"], second.profile_id);
    assert_eq!(artifact["profiles"][0]["name"], "N64 Desk");
}
