use super::{BuilderError, MAXIMUM_PROFILE_NAME_CHARACTERS};
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;
use thumble_core::{
    ButtonBindings, ConfigurationDocument, KeyBinding, OutputBinding, ProfileArtifact,
};
use uuid::Uuid;

const FIXTURE_MANIFEST_SCHEMA: &str =
    "com.codybontecou.thumble.controller-template-fixture-manifest";
const FIXTURE_VERSION: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BuilderTemplate {
    ProductivityStarter,
    ProductivityOneHandedLeft,
    ProductivityOneHandedRight,
    Nes,
    Snes,
    Nintendo64,
    GameCube,
    GameBoy,
    GameBoyAdvance,
    GenesisSixButton,
    Saturn,
    Dreamcast,
    ArcadeStick,
    Psp,
    PlayStation,
    Xbox,
    SoftWhite,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuilderTemplateMetadata {
    pub template: BuilderTemplate,
    #[serde(rename = "templateID")]
    pub template_id: &'static str,
    pub revision: u32,
    pub display_name: &'static str,
    pub description: &'static str,
    pub custom_element_id_count: usize,
}

impl BuilderTemplate {
    pub const ALL: [Self; 17] = [
        Self::ProductivityStarter,
        Self::ProductivityOneHandedLeft,
        Self::ProductivityOneHandedRight,
        Self::Nes,
        Self::Snes,
        Self::Nintendo64,
        Self::GameCube,
        Self::GameBoy,
        Self::GameBoyAdvance,
        Self::GenesisSixButton,
        Self::Saturn,
        Self::Dreamcast,
        Self::ArcadeStick,
        Self::Psp,
        Self::PlayStation,
        Self::Xbox,
        Self::SoftWhite,
    ];

    pub const fn metadata(self) -> BuilderTemplateMetadata {
        match self {
            Self::ProductivityStarter => metadata(self, "productivityStarter", 1, "Productivity Starter", "Everyday Mac navigation and shortcuts with tailored landscape and portrait layouts", 0),
            Self::ProductivityOneHandedLeft => metadata(self, "productivityOneHandedLeft", 1, "One-Handed Left", "Everyday Mac controls grouped in the lower-left thumb zone", 0),
            Self::ProductivityOneHandedRight => metadata(self, "productivityOneHandedRight", 1, "One-Handed Right", "Everyday Mac controls grouped in the lower-right thumb zone", 0),
            Self::Nes => metadata(self, "nes", 1, "NES", "Classic console pad: D-pad, A/B, Select, Start", 0),
            Self::Snes => metadata(self, "snes", 2, "Super Nintendo", "Super Nintendo pad: D-pad, ABXY, L/R shoulders, Select, Start", 2),
            Self::Nintendo64 => metadata(self, "nintendo64", 1, "Nintendo 64", "Three-prong N64 layout with analog stick, Z trigger, and C-buttons", 8),
            Self::GameCube => metadata(self, "gameCube", 1, "GameCube", "GameCube layout with oversized A, C-stick, shoulders, and Z", 5),
            Self::GameBoy => metadata(self, "gameBoy", 1, "Game Boy", "Classic handheld: D-pad, A/B, Select, Start", 0),
            Self::GameBoyAdvance => metadata(self, "gameBoyAdvance", 1, "Game Boy Advance", "GBA handheld: D-pad, A/B, L/R shoulders, Select, Start", 2),
            Self::GenesisSixButton => metadata(self, "genesisSixButton", 1, "Genesis 6-Button", "Sega Genesis/Mega Drive pad with D-pad, A/B/C, X/Y/Z, Mode, Start", 2),
            Self::Saturn => metadata(self, "saturn", 1, "Sega Saturn", "Sega Saturn six-button layout with D-pad, L/R, and Start", 4),
            Self::Dreamcast => metadata(self, "dreamcast", 1, "Dreamcast", "Dreamcast layout with analog stick, D-pad, ABXY, L/R triggers, Start", 3),
            Self::ArcadeStick => metadata(self, "arcadeStick", 1, "Arcade Stick", "MAME/fight-stick layout with joystick, 8 buttons, Coin, and Start", 5),
            Self::Psp => metadata(self, "psp", 1, "PSP", "Portable emulator pad with D-pad, nub, shoulders, and face buttons", 3),
            Self::PlayStation => metadata(self, "playStation", 1, "PlayStation", "Dual-stick layout with PlayStation face symbols and shoulders", 6),
            Self::Xbox => metadata(self, "xbox", 1, "Xbox", "Dual-stick Xbox-style layout with ABXY and triggers", 6),
            Self::SoftWhite => metadata(self, "softWhite", 1, "Soft White Pro", "Premium soft-white neumorphic controller with layered shell, rings, plates, dual sticks, D-pad, ABXY, and shoulder controls", 15),
        }
    }

    pub const fn template_id(self) -> &'static str {
        self.metadata().template_id
    }

    pub const fn revision(self) -> u32 {
        self.metadata().revision
    }

    pub const fn display_name(self) -> &'static str {
        self.metadata().display_name
    }

    pub const fn custom_element_id_count(self) -> usize {
        self.metadata().custom_element_id_count
    }
}

const fn metadata(
    template: BuilderTemplate,
    template_id: &'static str,
    revision: u32,
    display_name: &'static str,
    description: &'static str,
    custom_element_id_count: usize,
) -> BuilderTemplateMetadata {
    BuilderTemplateMetadata {
        template,
        template_id,
        revision,
        display_name,
        description,
        custom_element_id_count,
    }
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct TemplateFixture {
    fixture_version: u32,
    #[serde(rename = "templateID")]
    template_id: String,
    revision: u32,
    display_name: String,
    #[serde(rename = "canonicalProfileID")]
    canonical_profile_id: String,
    #[serde(rename = "customElementIDs")]
    custom_element_ids: Vec<String>,
    profile: Value,
    profile_key_bindings: ButtonBindings<KeyBinding>,
    profile_output_bindings: ButtonBindings<OutputBinding>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct FixtureManifest {
    schema: String,
    version: u32,
    fixtures: Vec<FixtureManifestEntry>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct FixtureManifestEntry {
    #[serde(rename = "templateID")]
    template_id: String,
    revision: u32,
    file: String,
    sha256: String,
}

macro_rules! fixture_sources {
    ($macro:ident) => {
        $macro! {
            (ProductivityStarter, "productivityStarter.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/productivityStarter.json"))),
            (ProductivityOneHandedLeft, "productivityOneHandedLeft.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/productivityOneHandedLeft.json"))),
            (ProductivityOneHandedRight, "productivityOneHandedRight.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/productivityOneHandedRight.json"))),
            (Nes, "nes.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/nes.json"))),
            (Snes, "snes.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/snes.json"))),
            (Nintendo64, "nintendo64.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/nintendo64.json"))),
            (GameCube, "gameCube.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/gameCube.json"))),
            (GameBoy, "gameBoy.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/gameBoy.json"))),
            (GameBoyAdvance, "gameBoyAdvance.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/gameBoyAdvance.json"))),
            (GenesisSixButton, "genesisSixButton.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/genesisSixButton.json"))),
            (Saturn, "saturn.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/saturn.json"))),
            (Dreamcast, "dreamcast.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/dreamcast.json"))),
            (ArcadeStick, "arcadeStick.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/arcadeStick.json"))),
            (Psp, "psp.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/psp.json"))),
            (PlayStation, "playStation.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/playStation.json"))),
            (Xbox, "xbox.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/xbox.json"))),
            (SoftWhite, "softWhite.json", include_bytes!(concat!(env!("CARGO_MANIFEST_DIR"), "/../../fixtures/controller-templates/v1/softWhite.json"))),
        }
    };
}

macro_rules! source_array {
    ($(($variant:ident, $file:expr, $bytes:expr),)*) => {
        [$( (BuilderTemplate::$variant, $file, $bytes.as_slice()), )*]
    };
}

const FIXTURE_SOURCES: [(BuilderTemplate, &str, &[u8]); 17] = fixture_sources!(source_array);
const MANIFEST_BYTES: &[u8] = include_bytes!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../fixtures/controller-templates/v1/manifest.json"
));
static FIXTURES: OnceLock<Result<BTreeMap<String, TemplateFixture>, BuilderError>> =
    OnceLock::new();

pub fn validate_builder_template_fixtures() -> Result<(), BuilderError> {
    fixtures().map(|_| ())
}

pub(super) fn materialize_template_document(
    session_id: &str,
    operation_id: &str,
    template: BuilderTemplate,
    name: Option<&str>,
) -> Result<(ConfigurationDocument, String, String, usize), BuilderError> {
    let fixture = fixtures()?
        .get(template.template_id())
        .ok_or(BuilderError::InvalidTemplateFixtures)?;
    let profile_name = validate_profile_name(name.unwrap_or(template.display_name()))?;
    let namespace = Uuid::parse_str(session_id).map_err(|_| BuilderError::InvalidSessionId)?;
    let profile_id = derived_id(namespace, operation_id, template, "profile", 0);
    let custom_ids = (0..fixture.custom_element_ids.len())
        .map(|ordinal| derived_id(namespace, operation_id, template, "custom", ordinal))
        .collect::<Vec<_>>();

    let mut replacements = BTreeMap::new();
    replacements.insert(fixture.canonical_profile_id.clone(), profile_id.clone());
    for (canonical, replacement) in fixture.custom_element_ids.iter().zip(&custom_ids) {
        replacements.insert(canonical.clone(), replacement.clone());
    }
    let mut profile = fixture.profile.clone();
    rewrite_exact_strings(&mut profile, &replacements)?;
    zero_updated_at(&mut profile);
    profile
        .as_object_mut()
        .ok_or(BuilderError::InvalidTemplateFixtures)?
        .insert("name".to_owned(), Value::String(profile_name.clone()));

    let profile_key_bindings = rewrite_serializable(&fixture.profile_key_bindings, &replacements)?;
    let profile_output_bindings =
        rewrite_serializable(&fixture.profile_output_bindings, &replacements)?;
    let document = ConfigurationDocument {
        profiles: vec![profile],
        active_profile_id: profile_id.clone(),
        default_profile_id: profile_id.clone(),
        key_bindings: profile_key_bindings.clone(),
        output_bindings: profile_output_bindings.clone(),
        profile_key_bindings: BTreeMap::from([(profile_id.clone(), profile_key_bindings)]),
        profile_output_bindings: BTreeMap::from([(profile_id.clone(), profile_output_bindings)]),
    };
    document
        .validate()
        .map_err(|_| BuilderError::InvalidTemplateFixtures)?;
    ProfileArtifact::validate_configuration_portability(&document)
        .map_err(|_| BuilderError::InvalidTemplateFixtures)?;
    Ok((document, profile_id, profile_name, custom_ids.len()))
}

fn fixtures() -> Result<&'static BTreeMap<String, TemplateFixture>, BuilderError> {
    FIXTURES
        .get_or_init(|| validate_fixture_set(MANIFEST_BYTES, &FIXTURE_SOURCES))
        .as_ref()
        .map_err(Clone::clone)
}

fn validate_fixture_set(
    manifest_bytes: &[u8],
    sources: &[(BuilderTemplate, &str, &[u8])],
) -> Result<BTreeMap<String, TemplateFixture>, BuilderError> {
    let manifest: FixtureManifest = serde_json::from_slice(manifest_bytes)
        .map_err(|_| BuilderError::InvalidTemplateFixtures)?;
    if manifest.schema != FIXTURE_MANIFEST_SCHEMA
        || manifest.version != FIXTURE_VERSION
        || manifest.fixtures.len() != BuilderTemplate::ALL.len()
        || sources.len() != BuilderTemplate::ALL.len()
    {
        return Err(BuilderError::InvalidTemplateFixtures);
    }
    let manifest_by_id = manifest
        .fixtures
        .iter()
        .map(|entry| (entry.template_id.as_str(), entry))
        .collect::<BTreeMap<_, _>>();
    if manifest_by_id.len() != BuilderTemplate::ALL.len()
        || manifest
            .fixtures
            .iter()
            .map(|entry| entry.template_id.as_str())
            .ne(BuilderTemplate::ALL
                .iter()
                .map(|template| template.template_id()))
        || sources
            .iter()
            .map(|(template, _, _)| template)
            .ne(BuilderTemplate::ALL.iter())
    {
        return Err(BuilderError::InvalidTemplateFixtures);
    }

    let mut result = BTreeMap::new();
    for (template, file, bytes) in sources {
        let metadata = template.metadata();
        let entry = manifest_by_id
            .get(metadata.template_id)
            .ok_or(BuilderError::InvalidTemplateFixtures)?;
        if entry.revision != metadata.revision
            || entry.file != *file
            || entry.sha256 != format!("{:x}", Sha256::digest(bytes))
        {
            return Err(BuilderError::InvalidTemplateFixtures);
        }
        let fixture: TemplateFixture =
            serde_json::from_slice(bytes).map_err(|_| BuilderError::InvalidTemplateFixtures)?;
        if fixture.fixture_version != FIXTURE_VERSION
            || fixture.template_id != metadata.template_id
            || fixture.revision != metadata.revision
            || fixture.display_name != metadata.display_name
            || fixture.custom_element_ids.len() != metadata.custom_element_id_count
            || fixture
                .custom_element_ids
                .iter()
                .collect::<BTreeSet<_>>()
                .len()
                != metadata.custom_element_id_count
            || fixture.profile.get("id").and_then(Value::as_str)
                != Some(fixture.canonical_profile_id.as_str())
            || fixture.profile.get("name").and_then(Value::as_str) != Some(metadata.display_name)
            || contains_nonzero_updated_at(&fixture.profile)
        {
            return Err(BuilderError::InvalidTemplateFixtures);
        }
        Uuid::parse_str(&fixture.canonical_profile_id)
            .map_err(|_| BuilderError::InvalidTemplateFixtures)?;
        let mut all_ids = BTreeSet::from([fixture.canonical_profile_id.as_str()]);
        for custom_id in &fixture.custom_element_ids {
            Uuid::parse_str(custom_id).map_err(|_| BuilderError::InvalidTemplateFixtures)?;
            if !all_ids.insert(custom_id.as_str()) {
                return Err(BuilderError::InvalidTemplateFixtures);
            }
        }
        validate_declared_custom_element_ids(&fixture.profile, &fixture.custom_element_ids)?;
        let document = ConfigurationDocument {
            profiles: vec![fixture.profile.clone()],
            active_profile_id: fixture.canonical_profile_id.clone(),
            default_profile_id: fixture.canonical_profile_id.clone(),
            key_bindings: fixture.profile_key_bindings.clone(),
            output_bindings: fixture.profile_output_bindings.clone(),
            profile_key_bindings: BTreeMap::from([(
                fixture.canonical_profile_id.clone(),
                fixture.profile_key_bindings.clone(),
            )]),
            profile_output_bindings: BTreeMap::from([(
                fixture.canonical_profile_id.clone(),
                fixture.profile_output_bindings.clone(),
            )]),
        };
        document
            .validate()
            .map_err(|_| BuilderError::InvalidTemplateFixtures)?;
        ProfileArtifact::validate_configuration_portability(&document)
            .map_err(|_| BuilderError::InvalidTemplateFixtures)?;
        if result
            .insert(fixture.template_id.clone(), fixture)
            .is_some()
        {
            return Err(BuilderError::InvalidTemplateFixtures);
        }
    }
    let expected = BuilderTemplate::ALL
        .iter()
        .map(|template| template.template_id())
        .collect::<BTreeSet<_>>();
    if result.keys().map(String::as_str).collect::<BTreeSet<_>>() != expected {
        return Err(BuilderError::InvalidTemplateFixtures);
    }
    Ok(result)
}

fn validate_profile_name(value: &str) -> Result<String, BuilderError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed.chars().count() > MAXIMUM_PROFILE_NAME_CHARACTERS
        || trimmed.chars().any(char::is_control)
    {
        return Err(BuilderError::InvalidProfileName);
    }
    Ok(trimmed.to_owned())
}

fn derived_id(
    namespace: Uuid,
    operation_id: &str,
    template: BuilderTemplate,
    kind: &str,
    ordinal: usize,
) -> String {
    Uuid::new_v5(
        &namespace,
        format!(
            "builder-template:{}:{}:{}:{}:{}",
            operation_id,
            template.template_id(),
            template.revision(),
            kind,
            ordinal
        )
        .as_bytes(),
    )
    .hyphenated()
    .to_string()
}

fn validate_declared_custom_element_ids(
    profile: &Value,
    declared: &[String],
) -> Result<(), BuilderError> {
    let profile = profile
        .as_object()
        .ok_or(BuilderError::InvalidTemplateFixtures)?;
    let mut found_primary = false;
    for field in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let Some(customization) = profile.get(field) else {
            continue;
        };
        found_primary |= field == "customization";
        let customization = customization
            .as_object()
            .ok_or(BuilderError::InvalidTemplateFixtures)?;
        let controls = customization
            .get("customButtons")
            .and_then(Value::as_array)
            .ok_or(BuilderError::InvalidTemplateFixtures)?;
        let control_ids = controls
            .iter()
            .map(|control| {
                control
                    .get("id")
                    .and_then(Value::as_str)
                    .ok_or(BuilderError::InvalidTemplateFixtures)
            })
            .collect::<Result<Vec<_>, _>>()?;
        if control_ids != declared.iter().map(String::as_str).collect::<Vec<_>>()
            || control_ids.iter().collect::<BTreeSet<_>>().len() != declared.len()
        {
            return Err(BuilderError::InvalidTemplateFixtures);
        }

        let elements = customization
            .get("elements")
            .and_then(Value::as_array)
            .ok_or(BuilderError::InvalidTemplateFixtures)?;
        for declared_id in declared {
            if elements
                .iter()
                .filter(|element| element.get("id").and_then(Value::as_str) == Some(declared_id))
                .count()
                != 1
            {
                return Err(BuilderError::InvalidTemplateFixtures);
            }
        }
    }
    if !found_primary {
        return Err(BuilderError::InvalidTemplateFixtures);
    }
    Ok(())
}

fn rewrite_serializable<T: Serialize + DeserializeOwned>(
    value: &T,
    replacements: &BTreeMap<String, String>,
) -> Result<T, BuilderError> {
    let mut json =
        serde_json::to_value(value).map_err(|_| BuilderError::InvalidTemplateFixtures)?;
    rewrite_exact_strings(&mut json, replacements)?;
    serde_json::from_value(json).map_err(|_| BuilderError::InvalidTemplateFixtures)
}

fn rewrite_exact_strings(
    value: &mut Value,
    replacements: &BTreeMap<String, String>,
) -> Result<(), BuilderError> {
    match value {
        Value::String(string) => {
            if let Some(replacement) = replacements.get(string) {
                *string = replacement.clone();
            }
        }
        Value::Array(values) => {
            for value in values {
                rewrite_exact_strings(value, replacements)?;
            }
        }
        Value::Object(object) => {
            let original = std::mem::take(object);
            for (key, mut child) in original {
                rewrite_exact_strings(&mut child, replacements)?;
                let rewritten_key = replacements.get(&key).cloned().unwrap_or(key);
                if object.insert(rewritten_key, child).is_some() {
                    return Err(BuilderError::InvalidTemplateFixtures);
                }
            }
        }
        _ => {}
    }
    Ok(())
}

fn zero_updated_at(value: &mut Value) {
    match value {
        Value::Array(values) => values.iter_mut().for_each(zero_updated_at),
        Value::Object(object) => {
            for (key, value) in object {
                if key == "updatedAt" {
                    *value = Value::from(0);
                } else {
                    zero_updated_at(value);
                }
            }
        }
        _ => {}
    }
}

fn contains_nonzero_updated_at(value: &Value) -> bool {
    match value {
        Value::Array(values) => values.iter().any(contains_nonzero_updated_at),
        Value::Object(object) => object.iter().any(|(key, value)| {
            (key == "updatedAt" && value.as_i64() != Some(0)) || contains_nonzero_updated_at(value)
        }),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    type TestFixtureSource = (BuilderTemplate, &'static str, &'static [u8]);
    type TamperedFixtureSet = (Vec<u8>, Vec<TestFixtureSource>);

    #[test]
    fn embedded_fixture_catalog_is_strict_and_safe() {
        let fixtures = validate_fixture_set(MANIFEST_BYTES, &FIXTURE_SOURCES).unwrap();
        assert_eq!(fixtures.len(), 17);
        for template in BuilderTemplate::ALL {
            let fixture = &fixtures[template.template_id()];
            assert_eq!(fixture.revision, template.revision());
            assert_eq!(
                fixture.custom_element_ids.len(),
                template.custom_element_id_count()
            );
        }
    }

    fn manifest_for_sources(sources: &[(BuilderTemplate, &str, &[u8])]) -> Vec<u8> {
        let mut manifest: Value = serde_json::from_slice(MANIFEST_BYTES).unwrap();
        for entry in manifest["fixtures"].as_array_mut().unwrap() {
            let file = entry["file"].as_str().unwrap();
            let bytes = sources
                .iter()
                .find(|(_, source_file, _)| *source_file == file)
                .unwrap()
                .2;
            entry["sha256"] = Value::String(format!("{:x}", Sha256::digest(bytes)));
        }
        serde_json::to_vec(&manifest).unwrap()
    }

    fn tampered_source(
        template: BuilderTemplate,
        mutate: impl FnOnce(&mut Value),
    ) -> TamperedFixtureSet {
        let mut sources = FIXTURE_SOURCES.to_vec();
        let source = sources
            .iter_mut()
            .find(|(candidate, _, _)| *candidate == template)
            .unwrap();
        let mut fixture: Value = serde_json::from_slice(source.2).unwrap();
        mutate(&mut fixture);
        source.2 = Box::leak(serde_json::to_vec(&fixture).unwrap().into_boxed_slice());
        let manifest = manifest_for_sources(&sources);
        (manifest, sources)
    }

    #[test]
    fn fixture_hash_and_content_tampering_are_rejected() {
        let mut manifest: Value = serde_json::from_slice(MANIFEST_BYTES).unwrap();
        manifest["fixtures"][0]["sha256"] = Value::String("0".repeat(64));
        assert!(matches!(
            validate_fixture_set(&serde_json::to_vec(&manifest).unwrap(), &FIXTURE_SOURCES),
            Err(BuilderError::InvalidTemplateFixtures)
        ));

        let mut tampered = FIXTURE_SOURCES.to_vec();
        let mut bytes = tampered[0].2.to_vec();
        let index = bytes.iter().position(|byte| *byte == b'{').unwrap();
        bytes[index] = b'[';
        tampered[0].2 = Box::leak(bytes.into_boxed_slice());
        assert!(matches!(
            validate_fixture_set(MANIFEST_BYTES, &tampered),
            Err(BuilderError::InvalidTemplateFixtures)
        ));
    }

    #[test]
    fn declared_custom_ids_must_exactly_match_supported_controls_and_elements() {
        let replacement = "ffffffff-ffff-5fff-8fff-ffffffffffff";
        let (manifest, sources) = tampered_source(BuilderTemplate::Snes, |fixture| {
            fixture["customElementIDs"][0] = Value::String(replacement.to_owned());
        });
        assert!(matches!(
            validate_fixture_set(&manifest, &sources),
            Err(BuilderError::InvalidTemplateFixtures)
        ));

        let (manifest, sources) = tampered_source(BuilderTemplate::Snes, |fixture| {
            fixture["profile"]["customization"]["customButtons"]
                .as_array_mut()
                .unwrap()
                .pop();
        });
        assert!(matches!(
            validate_fixture_set(&manifest, &sources),
            Err(BuilderError::InvalidTemplateFixtures)
        ));
    }

    #[test]
    fn exact_uuid_rewriting_includes_object_keys_and_rejects_collisions() {
        let canonical = "aaaaaaaa-aaaa-5aaa-8aaa-aaaaaaaaaaaa";
        let replacement = "bbbbbbbb-bbbb-5bbb-8bbb-bbbbbbbbbbbb";
        let replacements = BTreeMap::from([(canonical.to_owned(), replacement.to_owned())]);
        let mut keyed = serde_json::json!({
            (canonical): canonical,
            "nested": { (canonical): canonical }
        });
        rewrite_exact_strings(&mut keyed, &replacements).unwrap();
        let encoded = serde_json::to_string(&keyed).unwrap();
        assert!(!encoded.contains(canonical));
        assert!(keyed.get(replacement).is_some());
        assert!(keyed["nested"].get(replacement).is_some());

        let mut collision = serde_json::json!({(canonical): 1, (replacement): 2});
        assert_eq!(
            rewrite_exact_strings(&mut collision, &replacements),
            Err(BuilderError::InvalidTemplateFixtures)
        );
    }

    #[test]
    fn fixture_with_uuid_object_key_materializes_without_canonical_ids() {
        let canonical = "C5EC51F7-C610-572F-9171-A8699D614ED6";
        let (manifest, sources) = tampered_source(BuilderTemplate::Snes, |fixture| {
            fixture["profile"]["futurePortableMap"] = serde_json::json!({(canonical): canonical});
        });
        let fixtures = validate_fixture_set(&manifest, &sources).unwrap();
        let fixture = &fixtures[BuilderTemplate::Snes.template_id()];
        let mut profile = fixture.profile.clone();
        let replacement = "bbbbbbbb-bbbb-5bbb-8bbb-bbbbbbbbbbbb";
        rewrite_exact_strings(
            &mut profile,
            &BTreeMap::from([(canonical.to_owned(), replacement.to_owned())]),
        )
        .unwrap();
        let encoded = serde_json::to_string(&profile).unwrap();
        assert!(!encoded.contains(canonical));
        assert!(profile["futurePortableMap"].get(replacement).is_some());
    }
}
