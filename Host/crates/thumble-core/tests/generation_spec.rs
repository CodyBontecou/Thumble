use serde_json::{json, Value};
use thumble_core::{
    plan_generation_spec, GenerationSpecError, PersistentState, ProfileArtifact,
    GENERATION_UUID_NAMESPACE, MAXIMUM_GENERATION_SOURCE_CONTROLS, MAXIMUM_GENERATION_SPEC_BYTES,
    MAXIMUM_GENERATION_WARNINGS,
};
use uuid::Uuid;

const ALIASES: &[u8] = include_bytes!("../../../fixtures/generation-spec/v1/aliases-basic.json");
const MIXED: &[u8] =
    include_bytes!("../../../fixtures/generation-spec/v1/joystick-trackpad-text-decoration.json");
const EXHAUSTION: &[u8] =
    include_bytes!("../../../fixtures/generation-spec/v1/duplicate-exhaustion-reused-layout.json");
const TRIGGER: &[u8] = include_bytes!("../../../fixtures/generation-spec/v1/trigger-defaults.json");
const SPECIALIZED_CAPACITY: &[u8] =
    include_bytes!("../../../fixtures/generation-spec/v1/specialized-capacity.json");
const RICH_APPEARANCE: &[u8] =
    include_bytes!("../../../fixtures/generation-spec/v1/rich-appearance.json");
const MATERIALS: &[u8] = include_bytes!("../../../fixtures/generation-spec/v1/materials.json");
const GENERATED_ALIASES: &[u8] =
    include_bytes!("../../../fixtures/generation-spec/v1/generated/aliases-basic.json");
const GENERATED_RICH_APPEARANCE: &[u8] =
    include_bytes!("../../../fixtures/generation-spec/v1/generated/rich-appearance.json");
const GENERATED_TRIGGER_DEFAULTS: &[u8] =
    include_bytes!("../../../fixtures/generation-spec/v1/generated/trigger-defaults.json");
const GENERATED_SPECIALIZED_CAPACITY: &[u8] =
    include_bytes!("../../../fixtures/generation-spec/v1/generated/specialized-capacity.json");

fn generation_error(input: &[u8]) -> GenerationSpecError {
    match plan_generation_spec(input, None) {
        Err(error) => error,
        Ok(_) => panic!("expected generation planning to fail"),
    }
}

#[test]
fn generation_is_byte_deterministic_and_emits_valid_profile_and_artifact() {
    let first = plan_generation_spec(ALIASES, Some("Requested Override")).unwrap();
    let second = plan_generation_spec(ALIASES, Some("Requested Override")).unwrap();

    assert_eq!(
        first.generated_json.as_bytes(),
        second.generated_json.as_bytes()
    );
    assert_eq!(
        first.artifact_json.as_bytes(),
        second.artifact_json.as_bytes()
    );
    assert_eq!(first.descriptor_digest, second.descriptor_digest);
    assert_eq!(first.profile_id, second.profile_id);
    assert_eq!(first.profile["updatedAt"], 0);
    assert_eq!(first.customization["updatedAt"], 0);
    assert_eq!(first.artifact.exported_at, 0);
    assert_eq!(first.requested_game_name, "Requested Override");
    assert_eq!(first.resolved_game_name, "Alias Arcade");

    let decoded = ProfileArtifact::decode_json(first.artifact_json.as_bytes()).unwrap();
    decoded
        .to_configuration_document()
        .unwrap()
        .validate()
        .unwrap();
    assert_eq!(decoded.content_hash, first.artifact.content_hash);
    assert_eq!(
        decoded.extensions["generationMetadata"]["descriptorDigest"],
        first.descriptor_digest
    );
    assert_eq!(decoded.profiles, vec![first.profile.clone()]);

    let mut exact_profile_state = PersistentState::minimal("layout-quality-test").unwrap();
    exact_profile_state.profiles = vec![first.profile.clone()];
    exact_profile_state.active_profile_id = first.profile_id.clone();
    exact_profile_state.default_profile_id = first.profile_id.clone();
    assert!(
        exact_profile_state
            .controller_snapshot()
            .unwrap()
            .layout_quality
            == first.layout_quality
    );
}

#[test]
fn generated_json_bytes_match_checked_in_swift_decoder_fixtures() {
    for (input, fixture) in [
        (ALIASES, GENERATED_ALIASES),
        (RICH_APPEARANCE, GENERATED_RICH_APPEARANCE),
        (TRIGGER, GENERATED_TRIGGER_DEFAULTS),
        (SPECIALIZED_CAPACITY, GENERATED_SPECIALIZED_CAPACITY),
    ] {
        let plan = plan_generation_spec(input, None).unwrap();
        assert_eq!(plan.generated_json.as_bytes(), fixture);
    }
}

#[test]
fn aliases_precedence_bindings_and_uuid_rules_match_the_basic_contract() {
    let plan = plan_generation_spec(ALIASES, None).unwrap();
    assert_eq!(plan.assigned_controls.len(), 2);
    assert_eq!(
        plan.assigned_controls[0].element_id,
        "00000000-0000-0000-0000-000000000101"
    );
    assert_eq!(
        plan.assigned_controls[1].element_id,
        "00000000-0000-0000-0000-000000000105"
    );
    assert_eq!(plan.elements[1]["layout"]["centerX"], 0.82);
    assert_eq!(plan.elements[1]["layout"]["centerY"], 0.84);
    assert_eq!(plan.semantic_bindings[0].button, "up");
    assert_eq!(plan.semantic_bindings[0].key_code, 126);
    assert_eq!(plan.semantic_bindings[1].button, "jump");
    assert_eq!(plan.semantic_bindings[1].key_code, 49);
    assert_eq!(plan.semantic_bindings[1].modifier_mask, 2);

    let alternating = plan.generated_profile["keyBindings"].as_array().unwrap();
    assert_eq!(alternating.len(), 4);
    assert_eq!(alternating[0], "up");
    assert_eq!(alternating[2], "jump");
    assert!(plan.profile_key_bindings.get_raw("left").is_some());
    assert!(plan.profile_key_bindings.get_raw("pause").is_some());
    assert!(plan.profile_output_bindings.get_raw("jump").is_some());

    let expected_profile = Uuid::new_v5(
        &GENERATION_UUID_NAMESPACE,
        format!("profile:{}", plan.descriptor_digest).as_bytes(),
    );
    assert_eq!(plan.profile_id, expected_profile.hyphenated().to_string());
}

#[test]
fn joystick_trackpad_text_and_decoration_defaults_are_explicit_and_safe() {
    let plan = plan_generation_spec(MIXED, None).unwrap();
    assert_eq!(plan.assigned_controls.len(), 4);
    let joystick = &plan.elements[0];
    assert_eq!(joystick["kind"], "joystick");
    assert_eq!(joystick["layout"]["joystickVisualStyle"], "thumbstick");
    assert_eq!(joystick["joystickMapping"]["right"], "custom4");
    assert_eq!(joystick["layout"]["widthScale"], 0.58);
    let trackpad = &plan.elements[1];
    assert_eq!(trackpad["kind"], "trackpad");
    assert_eq!(trackpad["trackpadSettings"]["sensitivity"], 1.5);
    assert_eq!(trackpad["trackpadSettings"]["twoFingerScroll"], false);
    assert_eq!(trackpad["layout"]["cornerRadius"], 18.0);
    assert_eq!(plan.elements[2]["layout"]["showsIntegratedLabel"], false);
    assert_eq!(plan.elements[2]["layout"]["shadowStrength"], 0.0);
    assert_eq!(plan.elements[3]["layout"]["shadowStrength"], 1.0);
    assert_eq!(
        plan.semantic_bindings.len(),
        1,
        "text and decoration have no binding"
    );
    assert!(!plan.assigned_controls[0].element_id.starts_with("00000000"));
    assert_eq!(
        Uuid::parse_str(&plan.assigned_controls[0].element_id)
            .unwrap()
            .get_version_num(),
        5
    );
    assert!(plan.layout_quality.issue_count >= plan.layout_quality.warning_count);
}

#[test]
fn trigger_defaults_labels_and_kind_specific_shape_normalization_match_swift() {
    let trigger_plan = plan_generation_spec(TRIGGER, None).unwrap();
    let trigger = &trigger_plan.elements[0];
    assert_eq!(trigger["label"], "Right Trigge");
    assert_eq!(trigger["layout"]["shape"], "ellipse");
    assert_eq!(
        trigger["triggerSettings"],
        json!({
            "target": "right",
            "orientation": "vertical",
            "sensitivity": 1.0,
            "deadZone": 0.03,
            "sendsDigitalButton": false,
            "digitalThreshold": 0.5
        })
    );
    assert_eq!(
        trigger_plan.customization["customButtons"][0]["triggerSettings"],
        trigger["triggerSettings"]
    );

    let input = serde_json::to_vec(&json!({
        "controls": [
            {"button":"jump","label":"   ","key":"A"},
            {"kind":"text","label":"  操作設定あいうえおかきくけこさし  "},
            {"kind":"joystick","label":"Stick","shape":"star"},
            {"kind":"decoration","label":"Panel","shadowStrength":1.6}
        ]
    }))
    .unwrap();
    let plan = plan_generation_spec(&input, None).unwrap();
    assert_eq!(plan.elements[0]["label"], "Jump");
    assert_eq!(plan.elements[1]["label"], "操作設定あいうえおかきく");
    assert_eq!(plan.elements[2]["layout"]["shape"], "circle");
    assert_eq!(plan.elements[3]["layout"]["shadowStrength"], 1.6);

    let grapheme_input = serde_json::to_vec(&json!({
        "controls": [
            {"kind":"text","label":"abcdefghijk👨‍👩‍👧‍👦tail"},
            {"kind":"text","label":"abcdefghijke\u{301}tail"}
        ]
    }))
    .unwrap();
    let grapheme_plan = plan_generation_spec(&grapheme_input, None).unwrap();
    assert_eq!(grapheme_plan.elements[0]["label"], "abcdefghijk👨‍👩‍👧‍👦");
    assert_eq!(grapheme_plan.elements[1]["label"], "abcdefghijke\u{301}");
}

#[test]
fn specialized_capacities_drop_before_assignment_and_leave_no_profile_or_artifact_trace() {
    let plan = plan_generation_spec(SPECIALIZED_CAPACITY, None).unwrap();
    assert_eq!(
        plan.assigned_controls
            .iter()
            .map(|control| control.source_ordinal)
            .collect::<Vec<_>>(),
        vec![0, 1, 3, 4, 6]
    );
    assert_eq!(
        plan.dropped_controls
            .iter()
            .map(|control| (control.source_ordinal, control.reason.as_str()))
            .collect::<Vec<_>>(),
        vec![
            (2, "specialized-capacity-exceeded:joystick"),
            (5, "specialized-capacity-exceeded:trigger"),
            (7, "specialized-capacity-exceeded:trackpad"),
        ]
    );
    for (ordinal, kind) in [(2, "joystick"), (5, "trigger"), (7, "trackpad")] {
        assert!(plan.warnings.iter().any(|warning| {
            warning.code == "specialized-capacity-exceeded"
                && warning.source_ordinal == ordinal
                && warning.message.contains(kind)
        }));
    }
    assert_eq!(plan.elements.len(), 5);
    for dropped_label in ["Joystick Dr", "Trigger Drop", "Trackpad Dro"] {
        assert!(!plan
            .elements
            .iter()
            .any(|element| element["label"] == dropped_label));
    }
    assert_eq!(plan.semantic_bindings.len(), 5);
    for button in ["custom3", "custom6", "custom8"] {
        assert!(plan.profile_key_bindings.get_raw(button).is_none());
        assert!(plan.profile_output_bindings.get_raw(button).is_none());
    }

    assert_eq!(plan.artifact.profiles, vec![plan.profile.clone()]);
    let artifact_document = plan.artifact.to_configuration_document().unwrap();
    for button in ["custom3", "custom6", "custom8"] {
        assert!(artifact_document
            .profile_key_bindings
            .get(&plan.profile_id)
            .unwrap()
            .get_raw(button)
            .is_none());
        assert!(artifact_document
            .profile_output_bindings
            .get(&plan.profile_id)
            .unwrap()
            .get_raw(button)
            .is_none());
    }

    let mut exact_profile_state = PersistentState::minimal("capacity-layout-quality").unwrap();
    exact_profile_state.profiles = vec![plan.profile.clone()];
    exact_profile_state.active_profile_id = plan.profile_id.clone();
    exact_profile_state.default_profile_id = plan.profile_id.clone();
    assert!(
        exact_profile_state
            .controller_snapshot()
            .unwrap()
            .layout_quality
            == plan.layout_quality
    );
}

#[test]
fn duplicate_exhaustion_and_reused_layout_warnings_are_source_ordinal() {
    let duplicate = serde_json::to_vec(&json!({
        "gameName": "Duplicate fallback",
        "controls": [
            {"button":"jump","label":"Jump","key":"Space"},
            {"button":"jump","label":"Second Jump","key":"A"}
        ]
    }))
    .unwrap();
    let duplicate_plan = plan_generation_spec(&duplicate, None).unwrap();
    assert_eq!(duplicate_plan.assigned_controls[0].button, "jump");
    assert_eq!(duplicate_plan.assigned_controls[1].button, "custom1");
    assert!(duplicate_plan.warnings.iter().any(|warning| {
        warning.code == "duplicate-explicit-button-fallback" && warning.source_ordinal == 1
    }));

    let reused_specialized = serde_json::to_vec(&json!({
        "controls": [
            {"kind":"joystick","label":"Stick 1"},
            {"kind":"joystick","label":"Stick 2"},
            {"kind":"joystick","label":"Stick 3"},
            {"kind":"trackpad","label":"Pad 1"},
            {"kind":"trackpad","label":"Pad 2"}
        ]
    }))
    .unwrap();
    let specialized_plan = plan_generation_spec(&reused_specialized, None).unwrap();
    assert!(specialized_plan.warnings.iter().any(|warning| {
        warning.code == "reused-joystick-layout-default" && warning.source_ordinal == 1
    }));
    assert!(specialized_plan.warnings.iter().any(|warning| {
        warning.code == "specialized-capacity-exceeded" && warning.source_ordinal == 2
    }));
    assert!(specialized_plan.warnings.iter().any(|warning| {
        warning.code == "specialized-capacity-exceeded" && warning.source_ordinal == 4
    }));
    assert!(!specialized_plan
        .warnings
        .iter()
        .any(|warning| warning.code == "reused-trackpad-layout-default"));

    let plan = plan_generation_spec(EXHAUSTION, None).unwrap();
    assert_eq!(plan.assigned_controls.len(), 18);
    assert_eq!(plan.dropped_controls.len(), 2);
    assert_eq!(plan.dropped_controls[0].source_ordinal, 18);
    assert_eq!(plan.dropped_controls[1].source_ordinal, 19);
    assert!(plan
        .warnings
        .iter()
        .any(|warning| warning.code == "slot-exhaustion" && warning.source_ordinal == 18));
    assert!(plan
        .warnings
        .iter()
        .any(|warning| warning.code == "reused-role-layout-default"));
}

#[test]
fn strict_safety_revision_bounds_and_unknown_field_failures_are_precise() {
    let unsafe_input = include_bytes!("../../../fixtures/generation-spec/v1/failures/unsafe.json");
    assert_eq!(
        generation_error(unsafe_input),
        GenerationSpecError::UnsafeField {
            path: "$".to_owned(),
            field: "asset".to_owned(),
        }
    );
    let bounds = include_bytes!("../../../fixtures/generation-spec/v1/failures/bounds.json");
    assert!(
        matches!(plan_generation_spec(bounds, None), Err(GenerationSpecError::NumberOutOfBounds { path }) if path.ends_with("centerX"))
    );
    let revision = include_bytes!("../../../fixtures/generation-spec/v1/failures/revision.json");
    assert!(matches!(
        plan_generation_spec(revision, None),
        Err(GenerationSpecError::InvalidRevision {
            field: "plannerRevision",
            value: 2
        })
    ));
    let unknown = include_bytes!("../../../fixtures/generation-spec/v1/failures/unknown.json");
    assert_eq!(
        generation_error(unknown),
        GenerationSpecError::UnknownField {
            path: "$.controls[0]".to_owned(),
            field: "mystery".to_owned(),
        }
    );
}

#[test]
fn control_characters_are_rejected_in_all_generation_strings_before_planning() {
    let name =
        include_bytes!("../../../fixtures/generation-spec/v1/failures/control-character.json");
    assert_eq!(
        generation_error(name),
        GenerationSpecError::ControlCharacter {
            path: "$.gameName".to_owned(),
        }
    );

    let cases = [
        (json!({"source":"unsafe\nsource","controls":[]}), "$.source"),
        (
            json!({"notes":["unsafe\nnote"],"controls":[]}),
            "$.notes[0]",
        ),
        (
            json!({"controls":[{"label":"unsafe\u{1b}label"}]}),
            "$.controls[0].label",
        ),
        (
            json!({"controls":[{"label":"Rich icon","visualStyle":{"normal":{},"icon":{"source":"text","value":"unsafe\u{85}icon"}}}]}),
            "$.controls[0].visualStyle.icon.value",
        ),
        (
            json!({"controls":[{"id":"unsafe\u{9b}id"}]}),
            "$.controls[0].id",
        ),
        (
            json!({"controls":[{"styleID":"unsafe\u{1b}style"}]}),
            "$.controls[0].styleID",
        ),
        (json!({"controls":[{"key":"A\u{1b}"}]}), "$.controls[0].key"),
        (
            json!({"controls":[{"key":"A","modifiers":["shift\n"]}]}),
            "$.controls[0].modifiers[0]",
        ),
    ];
    for (value, expected_path) in cases {
        let input = serde_json::to_vec(&value).unwrap();
        assert_eq!(
            generation_error(&input),
            GenerationSpecError::ControlCharacter {
                path: expected_path.to_owned(),
            }
        );
    }

    assert!(matches!(
        plan_generation_spec(br#"{"controls":[]}"#, Some("requested\u{1b}name")),
        Err(GenerationSpecError::ControlCharacter { path })
            if path == "requestedGameName"
    ));
}

#[test]
fn control_character_error_paths_and_messages_are_bounded_and_safe() {
    let long_field = "field".repeat(80);
    let input = serde_json::to_vec(&json!({(long_field):"unsafe\nvalue"})).unwrap();
    let error = generation_error(&input);
    let GenerationSpecError::ControlCharacter { path } = &error else {
        panic!("unexpected error: {error}");
    };
    assert!(path.len() <= 256);
    assert!(!path.chars().any(char::is_control));
    assert!(!error.to_string().chars().any(char::is_control));
}

#[test]
fn rich_appearance_and_material_presets_match_exact_semantic_vectors() {
    let vectors: Value = serde_json::from_slice(include_bytes!(
        "../../../fixtures/generation-spec/v1/expected-rich-semantic-vectors.json"
    ))
    .unwrap();
    let rich = plan_generation_spec(RICH_APPEARANCE, None).unwrap();
    assert_eq!(
        vectors["richAppearance"],
        json!({
            "descriptorDigest": rich.descriptor_digest,
            "profileID": rich.profile_id,
            "artifactContentHash": rich.artifact.content_hash.value,
            "visualStyle": rich.elements[0]["layout"]["visualStyle"],
            "icon": rich.elements[0]["layout"]["icon"],
            "hapticStyle": rich.elements[0]["layout"]["hapticStyle"],
            "hapticFeedback": rich.elements[0]["layout"]["hapticFeedback"]
        })
    );
    assert_eq!(
        rich.elements[0]["layout"]["fillColor"],
        json!({
            "red": 17.0 / 255.0, "green": 24.0 / 255.0, "blue": 39.0 / 255.0, "alpha": 1.0
        })
    );

    let materials = plan_generation_spec(MATERIALS, None).unwrap();
    assert_eq!(
        vectors["materials"],
        json!({
            "descriptorDigest": materials.descriptor_digest,
            "profileID": materials.profile_id,
            "artifactContentHash": materials.artifact.content_hash.value,
            "visualStyles": materials.elements.iter().map(|element| element["layout"]["visualStyle"].clone()).collect::<Vec<_>>()
        })
    );
    assert_eq!(materials.elements.len(), 3);
    assert!(materials.elements[0]["layout"]["visualStyle"]
        .get("hapticFeedback")
        .is_some());
    assert!(materials.elements[2]["layout"]["visualStyle"]
        .get("hapticFeedback")
        .is_none());
}

#[test]
fn material_and_scalar_aliases_merge_with_swift_precedence() {
    let input = serde_json::to_vec(&json!({
        "controls":[{
            "button":"jump","label":"Merge",
            "material":"raised","materialPreset":"plate",
            "stroke":"#010203","strokeColor":"#FFFFFF","strokeWidth":3,
            "foreground":"#040506","pressedColor":"#070809","opacity":0.75
        }]
    }))
    .unwrap();
    let plan = plan_generation_spec(&input, None).unwrap();
    let style = &plan.elements[0]["layout"]["visualStyle"];
    assert_eq!(
        style["normal"]["fillStyle"]["color"],
        json!({
            "red":247.0/255.0,"green":244.0/255.0,"blue":248.0/255.0,"alpha":1.0
        })
    );
    assert_eq!(
        style["normal"]["strokeColor"],
        json!({
            "red":1.0/255.0,"green":2.0/255.0,"blue":3.0/255.0,"alpha":1.0
        })
    );
    assert_eq!(
        style["normal"]["foregroundColor"],
        json!({
            "red":4.0/255.0,"green":5.0/255.0,"blue":6.0/255.0,"alpha":1.0
        })
    );
    assert_eq!(style["normal"]["strokeWidth"], 3.0);
    assert_eq!(style["normal"]["opacity"], 0.75);
    assert_eq!(
        style["pressed"]["fillStyle"]["color"],
        json!({
            "red":7.0/255.0,"green":8.0/255.0,"blue":9.0/255.0,"alpha":1.0
        })
    );
    assert_eq!(style["pressed"]["scale"], 0.975);
    assert_eq!(style["hapticFeedback"]["style"], "soft");
}

#[test]
fn explicit_visual_style_wins_and_safe_states_and_gradients_normalize() {
    let input = serde_json::to_vec(&json!({
        "controls": [{
            "button": "focus",
            "label": "Explicit",
            "visualStyle": {
                "normal": {
                    "fillStyle": {"kind":"gradient","gradient":{
                        "type":"radial","angleDegrees":450,
                        "stops":[
                            {"offset":1,"color":"#FFFFFF"},
                            {"offset":0,"color":{"red":0.1,"green":0.2,"blue":0.3,"alpha":0.4}}
                        ]
                    }},
                    "shadowColor":"#112233","shadowRadius":4,"shadowX":-2,"shadowY":3,
                    "strokeColor":"#ABCDEF","strokeWidth":2,"opacity":0.8
                },
                "pressed":{"fillStyle":{"kind":"solid","color":"#102030"},"scale":0.9},
                "active":{"glowColor":"#405060","glowRadius":8},
                "disabled":{"fillStyle":{"kind":"none"},"opacity":0.4}
            },
            "material": {"ignored":true},
            "strokeWidth": "ignored",
            "pressedFill": ["ignored"]
        }]
    }))
    .unwrap();
    let plan = plan_generation_spec(&input, None).unwrap();
    let style = &plan.elements[0]["layout"]["visualStyle"];
    assert_eq!(style["normal"]["fillStyle"]["gradient"]["type"], "radial");
    assert_eq!(
        style["normal"]["fillStyle"]["gradient"]["angleDegrees"],
        90.0
    );
    assert_eq!(
        style["normal"]["fillStyle"]["gradient"]["stops"][0]["offset"],
        0.0
    );
    assert_eq!(style["pressed"]["scale"], 0.9);
    assert_eq!(style["active"]["glowRadius"], 8.0);
    assert_eq!(style["disabled"], json!({"opacity":0.4}));
    assert_eq!(style["normal"]["strokeWidth"], 2.0);
}

#[test]
fn icon_haptic_alias_precedence_normalization_and_clamping_are_exact() {
    let long_icon = format!("  {}  ", "x".repeat(100));
    let input = serde_json::to_vec(&json!({
        "controls": [{
            "button":"jump", "label":"Clamp",
            "styleID":"  raised style/@1.0  ",
            "icon":{"source":"text","value":long_icon,"placement":"top","scale":99,"renderingMode":"original"},
            "sfSymbol":"ignored",
            "hapticStyle":"heavy",
            "hapticFeedback":{"style":"light","pattern":"buzz","intensity":4,"sharpness":-2,"duration":9},
            "hapticPattern":"ignored"
        }, {
            "button":"attack", "label":"Aliases",
            "iconName":"text: GO ",
            "hapticStrength":0.4,"hapticDurationMS":1
        }]
    })).unwrap();
    let plan = plan_generation_spec(&input, None).unwrap();
    let first = &plan.elements[0]["layout"];
    assert_eq!(first["styleID"], "raised-style--1.0");
    assert_eq!(first["icon"]["value"].as_str().unwrap().chars().count(), 80);
    assert_eq!(first["icon"]["scale"], 3.0);
    assert_eq!(first["hapticStyle"], "heavy");
    assert_eq!(
        first["hapticFeedback"],
        json!({
            "style":"heavy","pattern":"buzz","intensity":1.0,"sharpness":0.0,"duration":0.30
        })
    );
    let second = &plan.elements[1]["layout"];
    assert_eq!(
        second["icon"],
        json!({
            "source":"text","value":"GO","placement":"center","scale":1.0,"renderingMode":"template"
        })
    );
    assert_eq!(second["hapticStyle"], "light");
    assert_eq!(
        second["hapticFeedback"],
        json!({
            "style":"light","pattern":"single","intensity":0.4,"sharpness":0.48,"duration":0.02
        })
    );
}

#[test]
fn default_outer_haptic_feedback_is_omitted_without_affecting_material_feedback() {
    let input = serde_json::to_vec(&json!({
        "controls": [{
            "button":"jump",
            "label":"Default",
            "hapticFeedback": {
                "style":"light", "pattern":"single", "intensity":0.45,
                "sharpness":0.48, "duration":0.06
            }
        }, {
            "button":"attack",
            "label":"Within tolerance",
            "hapticStyle":"light",
            "hapticIntensity":0.4509,
            "hapticSharpness":0.4791,
            "hapticDuration":0.0609
        }, {
            "button":"dash",
            "label":"Near nondefault",
            "hapticIntensity":0.451
        }, {
            "button":"focus",
            "label":"Material feedback",
            "visualStyle": {
                "normal": {},
                "hapticFeedback": {
                    "style":"light", "pattern":"single", "intensity":0.45,
                    "sharpness":0.48, "duration":0.06
                }
            }
        }]
    }))
    .unwrap();
    let plan = plan_generation_spec(&input, None).unwrap();

    for index in [0, 1] {
        assert_eq!(plan.elements[index]["layout"]["hapticStyle"], "light");
        assert!(plan.elements[index]["layout"]
            .get("hapticFeedback")
            .is_none());
    }
    assert_eq!(plan.elements[2]["layout"]["hapticStyle"], "light");
    assert_eq!(
        plan.elements[2]["layout"]["hapticFeedback"]["intensity"],
        0.451
    );
    assert!(plan.elements[3]["layout"]["visualStyle"]
        .get("hapticFeedback")
        .is_some());
}

#[test]
fn normalized_rich_fields_participate_in_deterministic_identity_and_hashes() {
    fn plan(control: Value) -> thumble_core::GenerationSpecPlan {
        let input = serde_json::to_vec(&json!({"controls":[control]})).unwrap();
        plan_generation_spec(&input, None).unwrap()
    }

    for (name, baseline, mutation) in [
        (
            "material",
            json!({"button":"jump","label":"Identity","material":"raised"}),
            json!({"button":"jump","label":"Identity","material":"inset"}),
        ),
        (
            "style",
            json!({"button":"jump","label":"Identity","styleID":"style-one"}),
            json!({"button":"jump","label":"Identity","styleID":"style-two"}),
        ),
        (
            "state",
            json!({"button":"jump","label":"Identity","visualStyle":{"normal":{"strokeWidth":1}}}),
            json!({"button":"jump","label":"Identity","visualStyle":{"normal":{"strokeWidth":2}}}),
        ),
        (
            "haptic",
            json!({"button":"jump","label":"Identity","hapticStyle":"heavy","hapticIntensity":0.7}),
            json!({"button":"jump","label":"Identity","hapticStyle":"heavy","hapticIntensity":0.8}),
        ),
    ] {
        let first = plan(baseline.clone());
        let repeat = plan(baseline);
        let changed = plan(mutation);
        assert_eq!(first.descriptor_digest, repeat.descriptor_digest, "{name}");
        assert_eq!(first.profile_id, repeat.profile_id, "{name}");
        assert_eq!(
            first.artifact.content_hash, repeat.artifact.content_hash,
            "{name}"
        );
        assert_ne!(first.descriptor_digest, changed.descriptor_digest, "{name}");
        assert_ne!(first.profile_id, changed.profile_id, "{name}");
        assert_ne!(
            first.artifact.content_hash, changed.artifact.content_hash,
            "{name}"
        );
    }
}

#[test]
fn unsafe_or_excess_rich_appearance_errors_have_exact_variants_and_paths() {
    let asset_icon =
        include_bytes!("../../../fixtures/generation-spec/v1/failures/asset-icon.json");
    assert_eq!(
        generation_error(asset_icon),
        GenerationSpecError::InvalidEnum {
            path: "$.controls[0].icon.source".to_owned(),
            value: "asset".to_owned(),
        }
    );

    for (fixture, field) in [
        (
            include_bytes!("../../../fixtures/generation-spec/v1/failures/image-fill.json")
                .as_slice(),
            "image",
        ),
        (
            include_bytes!("../../../fixtures/generation-spec/v1/failures/tile-fill.json")
                .as_slice(),
            "tile",
        ),
    ] {
        assert_eq!(
            generation_error(fixture),
            GenerationSpecError::UnsafeField {
                path: "$.controls[0].visualStyle.normal.fillStyle".to_owned(),
                field: field.to_owned(),
            }
        );
    }

    for (control, path, field) in [
        (
            json!({"label":"URL","icon":{"source":"text","value":"x","sourceURL":"https://example.invalid"}}),
            "$.controls[0].icon",
            "sourceURL",
        ),
        (
            json!({"label":"Path","filePath":"/tmp/unsafe"}),
            "$.controls[0]",
            "filePath",
        ),
    ] {
        let input = serde_json::to_vec(&json!({"controls":[control]})).unwrap();
        assert_eq!(
            generation_error(&input),
            GenerationSpecError::UnsafeField {
                path: path.to_owned(),
                field: field.to_owned(),
            }
        );
    }

    let nested = include_bytes!("../../../fixtures/generation-spec/v1/failures/nested-excess.json");
    assert_eq!(
        generation_error(nested),
        GenerationSpecError::UnknownField {
            path: "$.controls[0].visualStyle.normal".to_owned(),
            field: "mystery".to_owned(),
        }
    );
    let shadow =
        include_bytes!("../../../fixtures/generation-spec/v1/failures/shadow-overflow.json");
    assert_eq!(
        generation_error(shadow),
        GenerationSpecError::NumberOutOfBounds {
            path: "$.controls[0].shadows".to_owned(),
        }
    );

    for control in [
        json!({"label":"Range","visualStyle":{"normal":{"strokeWidth":13}}}),
        json!({"label":"Color","foreground":{"red":2,"green":0,"blue":0}}),
        json!({"label":"Shadow","shadows":[{"color":"#000000","radius":97}]}),
    ] {
        let input = serde_json::to_vec(&json!({"controls":[control]})).unwrap();
        assert!(plan_generation_spec(&input, None).is_err());
    }
}

#[test]
fn key_modifier_type_count_and_size_errors_are_rejected() {
    for (control, expected) in [
        (json!({"label":"Bad key","key":"not-a-key"}), "key"),
        (
            json!({"label":"Bad modifier","key":"A","modifiers":["hyper"]}),
            "modifier",
        ),
    ] {
        let input = serde_json::to_vec(&json!({"controls":[control]})).unwrap();
        match (expected, plan_generation_spec(&input, None)) {
            ("key", Err(GenerationSpecError::InvalidKey { .. }))
            | ("modifier", Err(GenerationSpecError::InvalidModifier { .. })) => {}
            (_, result) => panic!("unexpected result: {}", result.err().unwrap()),
        }
    }

    let controls = vec![json!({"label":"x"}); MAXIMUM_GENERATION_SOURCE_CONTROLS + 1];
    let too_many = serde_json::to_vec(&json!({"controls":controls})).unwrap();
    assert!(matches!(
        plan_generation_spec(&too_many, None),
        Err(GenerationSpecError::TooManyControls(_))
    ));
    assert!(matches!(
        plan_generation_spec(&vec![b' '; MAXIMUM_GENERATION_SPEC_BYTES + 1], None),
        Err(GenerationSpecError::TooLarge(_))
    ));
    assert!(matches!(
        plan_generation_spec(br#"{"controls":{}}"#, None),
        Err(GenerationSpecError::InvalidType { .. })
    ));
}

#[test]
fn warning_output_is_bounded_and_reports_deterministic_omissions() {
    let controls = (0..MAXIMUM_GENERATION_SOURCE_CONTROLS)
        .map(|ordinal| json!({"button":"jump","label":format!("Warning {ordinal}"),"key":"A"}))
        .collect::<Vec<_>>();
    let input = serde_json::to_vec(&json!({"controls":controls})).unwrap();
    let first = plan_generation_spec(&input, None).unwrap();
    let second = plan_generation_spec(&input, None).unwrap();
    assert_eq!(first.warnings.len(), MAXIMUM_GENERATION_WARNINGS);
    assert_eq!(first.warnings, second.warnings);
    assert_eq!(first.omitted_warning_count, 2);
    assert_eq!(first.omitted_warning_count, second.omitted_warning_count);

    let serialized = serde_json::to_value(&first).unwrap();
    assert_eq!(serialized["omittedWarningCount"], 2);
    assert!(serialized["generatedJSON"].is_string());
    assert!(serialized["artifactJSON"].is_string());
    assert!(serialized.get("generatedJson").is_none());
    assert!(serialized.get("artifactJson").is_none());
}

#[test]
fn expected_semantic_vector_matches_fixture() {
    let vectors: Value = serde_json::from_slice(include_bytes!(
        "../../../fixtures/generation-spec/v1/expected-semantic-vectors.json"
    ))
    .unwrap();
    for (name, input, requested) in [
        ("aliasesBasic", ALIASES, Some("Requested Override")),
        ("mixedControls", MIXED, None),
    ] {
        let plan = plan_generation_spec(input, requested).unwrap();
        assert_eq!(vectors[name]["descriptorDigest"], plan.descriptor_digest);
        assert_eq!(vectors[name]["profileID"], plan.profile_id);
        assert_eq!(
            vectors[name]["artifactContentHash"],
            plan.artifact.content_hash.value
        );
        assert_eq!(
            vectors[name]["assignedButtons"],
            json!(plan
                .assigned_controls
                .iter()
                .map(|control| control.button.as_str())
                .collect::<Vec<_>>())
        );
        let binding_buttons = plan.generated_profile["keyBindings"]
            .as_array()
            .unwrap()
            .iter()
            .step_by(2)
            .cloned()
            .collect::<Vec<_>>();
        assert_eq!(
            vectors[name]["generatedSemantic"],
            json!({
                "requestedGameName": plan.requested_game_name,
                "resolvedGameName": plan.resolved_game_name,
                "keyBindingButtons": binding_buttons
            })
        );
        assert_eq!(
            vectors[name]["artifactSemantic"],
            json!({
                "schemaVersion": plan.artifact.version,
                "artifactVersion": plan.artifact.artifact_version,
                "exportedAt": plan.artifact.exported_at,
                "profileCount": plan.artifact.profiles.len()
            })
        );
    }
}
