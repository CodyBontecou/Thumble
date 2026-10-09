//! Regenerate current-generation positive goldens, not a migration/import adapter.
//! cargo run -p thumble-core --example refresh_generation_fixtures
use serde_json::{json, Map, Value};
use std::{fs, path::Path};
use thumble_core::plan_generation_spec;

fn main() {
    let directory = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/generation-spec/v1");
    for name in ["aliases-basic", "duplicate-exhaustion-reused-layout", "joystick-trackpad-text-decoration", "materials", "rich-appearance", "specialized-capacity", "trigger-defaults"] {
        let plan = plan_generation_spec(&fs::read(directory.join(format!("{name}.json"))).unwrap(), None).unwrap();
        fs::write(directory.join(format!("generated/{name}.json")), plan.generated_json).unwrap();
        println!("generated/{name}.json");
    }
    let mut vectors = Map::new();
    for (name, source, requested) in [
        ("aliasesBasic", "aliases-basic", Some("Requested Override")),
        ("mixedControls", "joystick-trackpad-text-decoration", None),
    ] {
        let plan = plan_generation_spec(&fs::read(directory.join(format!("{source}.json"))).unwrap(), requested).unwrap();
        vectors.insert(name.to_owned(), json!({
            "descriptorDigest": plan.descriptor_digest,
            "profileID": plan.profile_id,
            "artifactContentHash": plan.artifact.content_hash.value,
            "assignedButtons": plan.assigned_controls.iter().map(|control| &control.button).collect::<Vec<_>>(),
            "generatedSemantic": {
                "requestedGameName": plan.requested_game_name,
                "resolvedGameName": plan.resolved_game_name,
                "keyBindingButtons": plan.generated_profile["keyBindings"].as_array().unwrap().iter().step_by(2).collect::<Vec<_>>()
            },
            "artifactSemantic": {
                "schemaVersion": plan.artifact.version,
                "artifactVersion": plan.artifact.artifact_version,
                "exportedAt": plan.artifact.exported_at,
                "profileCount": plan.artifact.profiles.len()
            }
        }));
    }
    fs::write(directory.join("expected-semantic-vectors.json"), format!("{}\n", serde_json::to_string_pretty(&Value::Object(vectors)).unwrap())).unwrap();
    let rich = plan_generation_spec(&fs::read(directory.join("rich-appearance.json")).unwrap(), None).unwrap();
    let materials = plan_generation_spec(&fs::read(directory.join("materials.json")).unwrap(), None).unwrap();
    let rich_vectors = json!({
        "richAppearance": {
            "descriptorDigest": rich.descriptor_digest, "profileID": rich.profile_id,
            "artifactContentHash": rich.artifact.content_hash.value,
            "visualStyle": rich.elements[0]["layout"]["visualStyle"],
            "icon": rich.elements[0]["layout"]["icon"],
            "hapticStyle": rich.elements[0]["layout"]["hapticStyle"],
            "hapticFeedback": rich.elements[0]["layout"]["hapticFeedback"]
        },
        "materials": {
            "descriptorDigest": materials.descriptor_digest, "profileID": materials.profile_id,
            "artifactContentHash": materials.artifact.content_hash.value,
            "visualStyles": materials.elements.iter().map(|element| &element["layout"]["visualStyle"]).collect::<Vec<_>>()
        }
    });
    fs::write(directory.join("expected-rich-semantic-vectors.json"), format!("{}\n", serde_json::to_string_pretty(&rich_vectors).unwrap())).unwrap();
}
