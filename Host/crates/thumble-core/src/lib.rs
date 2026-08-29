//! Deterministic, platform-neutral Thumble host state and input handling.
//!
//! This crate owns no sockets, files, clocks, randomness, or OS input APIs.
//! Adapters feed decoded [`thumble_protocol::ControllerMessage`] values into
//! [`HostCore`] and execute the returned typed [`Effect`] values.

mod binding;
mod configuration;
mod controller_snapshot;
mod core;
mod generation_spec;
mod profile_artifact;
mod resolver;
mod semantic_key;
mod state;

pub use binding::{ButtonBindings, KeyBinding, KeyStroke, OutputBinding};
pub use configuration::{
    ConfigurationDocument, ConfigurationDocumentError, MAXIMUM_CONFIGURATION_BINDING_STROKES,
    MAXIMUM_CONFIGURATION_DOCUMENT_BYTES, MAXIMUM_CONFIGURATION_PROFILES,
};
pub use controller_snapshot::{
    ControllerCanvasSnapshot, ControllerControlBarItemSnapshot, ControllerElementOutputSnapshot,
    ControllerElementSnapshot, ControllerFrameSnapshot, ControllerGroupSnapshot,
    ControllerLayerSnapshot, ControllerLayoutQualityIssueSnapshot, ControllerLayoutQualitySnapshot,
    ControllerOrientation, ControllerProfileSnapshot, ControllerSemanticKeyStrokeSnapshot,
    ControllerSnapshot, ControllerSnapshotError, ControllerStyleAppearanceSnapshot,
    ControllerStyleColorSnapshot, ControllerStyleHapticSnapshot, ControllerStyleIconSnapshot,
    ControllerStyleShadowSnapshot, ControllerStyleSnapshot, ControllerStyleStateSnapshot,
    MAXIMUM_CONTROLLER_SNAPSHOT_ELEMENTS, MAXIMUM_CONTROLLER_SNAPSHOT_LAYERS,
    MAXIMUM_CONTROLLER_SNAPSHOT_LAYOUT_ISSUES, MAXIMUM_CONTROLLER_SNAPSHOT_STYLES,
};
pub use core::{
    ConnectionId, CoreError, CoreTime, Effect, HostCore, LocalControlError, StatusCounters,
    StatusSnapshot, TokenSource,
};
pub use generation_spec::{
    plan_generation_spec, GeneratedSemanticBinding, GenerationAssignedControl,
    GenerationDroppedControl, GenerationSpecError, GenerationSpecPlan, GenerationSpecWarning,
    GENERATION_SPEC_CATALOG_REVISION, GENERATION_SPEC_PLANNER_REVISION,
    GENERATION_SPEC_SCHEMA_VERSION, GENERATION_UUID_NAMESPACE, MAXIMUM_GENERATION_OUTPUT_BYTES,
    MAXIMUM_GENERATION_SOURCE_CONTROLS, MAXIMUM_GENERATION_SPEC_BYTES, MAXIMUM_GENERATION_WARNINGS,
};
pub use profile_artifact::{
    ProfileArtifact, ProfileArtifactBindingMaps, ProfileArtifactCatalogRevision,
    ProfileArtifactContentHash, ProfileArtifactError, ProfileArtifactSelection,
    MAXIMUM_PROFILE_ARTIFACT_BYTES, PROFILE_ARTIFACT_CANONICALIZATION,
    PROFILE_ARTIFACT_HASH_ALGORITHM, PROFILE_ARTIFACT_SCHEMA, PROFILE_ARTIFACT_SCHEMA_VERSION,
    PROFILE_ARTIFACT_VERSION,
};
pub use semantic_key::{
    generated_modifier_mask, generated_semantic_key_code, semantic_key_code, semantic_key_name,
};
pub use state::{
    canonical_default_profile_key_bindings, minimal_default_customization, minimal_default_profile,
    ConfigurationCommitRecord, PersistentState, StateError, TrustedClient, CURRENT_SCHEMA_VERSION,
    DEFAULT_PROFILE_ID, INITIAL_CONFIGURATION_REVISION, MAXIMUM_RECENT_CONFIGURATION_COMMITS,
};
