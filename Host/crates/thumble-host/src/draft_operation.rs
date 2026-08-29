use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::error::Error;
use std::fmt;
pub(crate) use thumble_core::{semantic_key_code, semantic_key_name};
use thumble_core::{
    ConfigurationDocument, KeyBinding, KeyStroke, MAXIMUM_CONFIGURATION_BINDING_STROKES,
};
use thumble_protocol::GameButton;
use uuid::Uuid;

const MAXIMUM_OPERATION_ID_BYTES: usize = 128;
const MAXIMUM_ELEMENT_ID_BYTES: usize = 128;
const MAXIMUM_PROFILE_NAME_CHARACTERS: usize = 256;
const MAXIMUM_ELEMENT_LABEL_CHARACTERS: usize = 64;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case", deny_unknown_fields)]
pub enum ConfigurationOperation {
    #[serde(rename = "profile.rename")]
    ProfileRename {
        #[serde(rename = "profileID")]
        profile_id: String,
        name: String,
    },
    #[serde(rename = "element.add")]
    ElementAdd {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        /// Caller-generated UUID used in both custom-control mirrors.
        #[serde(rename = "elementID")]
        element_id: String,
        kind: ElementKind,
        #[serde(
            rename = "mappedButton",
            default,
            skip_serializing_if = "Option::is_none"
        )]
        mapped_button: Option<GameButton>,
        changes: Box<ElementChanges>,
    },
    #[serde(rename = "element.set")]
    ElementSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementID")]
        element_id: String,
        changes: Box<ElementChanges>,
    },
    #[serde(rename = "binding.set")]
    BindingSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButton,
        sequence: Vec<SemanticKeyStroke>,
    },
    #[serde(rename = "binding.clear")]
    BindingClear {
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButton,
    },
    #[serde(rename = "binding.reset")]
    BindingReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButton,
    },
    #[serde(rename = "binding.reset-all")]
    BindingResetAll {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "output.mode")]
    OutputMode {
        #[serde(rename = "profileID")]
        profile_id: String,
        mode: ConfigurationOutputMode,
    },
    #[serde(rename = "output.set")]
    OutputSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButton,
        #[serde(rename = "keyboardEdit")]
        keyboard_edit: KeyboardOutputEdit,
        #[serde(rename = "gamepadEdit")]
        gamepad_edit: GamepadOutputEdit,
    },
    #[serde(rename = "output.reset")]
    OutputReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        button: GameButton,
    },
    #[serde(rename = "output.reset-all")]
    OutputResetAll {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "profile.reset")]
    ProfileReset {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "customization.set")]
    CustomizationSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        changes: CustomizationChanges,
    },
    #[serde(rename = "customization.reset")]
    CustomizationReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
    },
    #[serde(rename = "customization.fix")]
    CustomizationFix {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        target: Box<LayoutRepairTarget>,
        canvas: Box<LayoutRepairCanvas>,
        #[serde(rename = "includeLocked")]
        include_locked: bool,
    },
    #[serde(rename = "orientation.set")]
    OrientationSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        preference: ConfigurationOrientationPreference,
    },
    #[serde(rename = "device.set")]
    DeviceSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "frameID")]
        frame_id: String,
    },
    #[serde(rename = "control-bar.set")]
    ControlBarSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        items: Vec<ConfigurationControlBarItem>,
    },
    #[serde(rename = "control-bar.add")]
    ControlBarAdd {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        item: ConfigurationControlBarItem,
    },
    #[serde(rename = "control-bar.remove")]
    ControlBarRemove {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        item: ConfigurationControlBarItem,
    },
    #[serde(rename = "control-bar.move")]
    ControlBarMove {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        item: ConfigurationControlBarItem,
        direction: ControlBarMoveDirection,
    },
    #[serde(rename = "control-bar.item.set")]
    ControlBarItemSet {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        item: ConfigurationControlBarItem,
        changes: Box<ControlBarItemChanges>,
    },
    #[serde(rename = "style.create")]
    StyleCreate {
        #[serde(rename = "profileID")]
        profile_id: String,
        #[serde(rename = "styleID")]
        style_id: String,
        name: String,
        appearance: Box<StyleAppearance>,
    },
    #[serde(rename = "style.rename")]
    StyleRename {
        #[serde(rename = "profileID")]
        profile_id: String,
        #[serde(rename = "styleID")]
        style_id: String,
        name: String,
    },
    #[serde(rename = "style.apply")]
    StyleApply {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "styleID")]
        style_id: String,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "style.detach")]
    StyleDetach {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "style.delete")]
    StyleDelete {
        #[serde(rename = "profileID")]
        profile_id: String,
        #[serde(rename = "styleID")]
        style_id: String,
    },
    #[serde(rename = "layer.move")]
    LayerMove {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementID")]
        element_id: String,
        destination: LayerMoveDestination,
    },
    #[serde(rename = "layer.forward")]
    LayerForward {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "layer.backward")]
    LayerBackward {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "layer.front")]
    LayerFront {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "layer.back")]
    LayerBack {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "group.create")]
    GroupCreate {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
        name: String,
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
    },
    #[serde(rename = "group.rename")]
    GroupRename {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
        name: String,
    },
    #[serde(rename = "group.duplicate")]
    GroupDuplicate {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
        #[serde(rename = "newGroupID")]
        new_group_id: String,
        name: Option<String>,
        #[serde(rename = "newElementIDs")]
        new_element_ids: Vec<String>,
        #[serde(rename = "offsetX")]
        offset_x: f64,
        #[serde(rename = "offsetY")]
        offset_y: f64,
    },
    #[serde(rename = "group.ungroup")]
    GroupUngroup {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.hide")]
    GroupHide {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.show")]
    GroupShow {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.lock")]
    GroupLock {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.unlock")]
    GroupUnlock {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.nudge")]
    GroupNudge {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
        #[serde(rename = "canvasFrameID", default = "default_nudge_canvas_frame_id")]
        canvas_frame_id: String,
        #[serde(rename = "deltaX")]
        delta_x: f64,
        #[serde(rename = "deltaY")]
        delta_y: f64,
    },
    #[serde(rename = "group.forward")]
    GroupForward {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.backward")]
    GroupBackward {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.front")]
    GroupFront {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "group.back")]
    GroupBack {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "groupID")]
        group_id: String,
    },
    #[serde(rename = "control-bar.reset")]
    ControlBarReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
    },
    #[serde(rename = "control-bar.item.reset")]
    ControlBarItemReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        item: ConfigurationControlBarItem,
    },
    #[serde(rename = "generation.generate")]
    GenerationGenerate {
        preset: GenerationPreset,
        #[serde(rename = "presetRevision")]
        preset_revision: u32,
        destination: GeneratedProfileDestination,
        /// Caller-generated UUIDs for every generated custom element.
        #[serde(rename = "newElementIDs")]
        new_element_ids: Vec<String>,
        select: bool,
        #[serde(rename = "makeDefault")]
        make_default: bool,
    },
    #[serde(rename = "template.install")]
    TemplateInstall {
        template: ControllerTemplate,
        #[serde(rename = "templateRevision")]
        template_revision: u32,
        destination: GeneratedProfileDestination,
        name: Option<String>,
        /// Caller-generated UUIDs for every generated custom element.
        #[serde(rename = "newElementIDs")]
        new_element_ids: Vec<String>,
        select: bool,
        #[serde(rename = "makeDefault")]
        make_default: bool,
    },
    #[serde(rename = "profile.select")]
    ProfileSelect {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "profile.default")]
    ProfileSetDefault {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
    #[serde(rename = "profile.duplicate")]
    ProfileDuplicate {
        #[serde(rename = "profileID")]
        profile_id: String,
        #[serde(rename = "newProfileID")]
        new_profile_id: String,
        name: String,
    },
    #[serde(rename = "profile.delete")]
    ProfileDelete {
        #[serde(rename = "profileID")]
        profile_id: String,
        #[serde(rename = "replacementProfileID")]
        replacement_profile_id: Option<String>,
    },
    #[serde(rename = "profile.move")]
    ProfileMove {
        #[serde(rename = "profileID")]
        profile_id: String,
        index: usize,
    },
    #[serde(rename = "profile.create")]
    ProfileCreate {
        name: String,
        #[serde(rename = "newProfileID")]
        new_profile_id: String,
        #[serde(rename = "sourceProfileID")]
        source_profile_id: Option<String>,
        select: bool,
        #[serde(rename = "makeDefault")]
        make_default: bool,
    },
    #[serde(rename = "theme.apply")]
    ThemeApply {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        preset: String,
    },
    #[serde(rename = "orientation.copy")]
    OrientationCopy {
        #[serde(rename = "profileID")]
        profile_id: String,
        source: OrientationVariant,
        destination: OrientationVariant,
        #[serde(rename = "automaticallyArrange")]
        automatically_arrange: bool,
    },
    #[serde(rename = "element.duplicate")]
    ElementDuplicate {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
        /// Caller-generated UUIDs, one per source element, for deterministic retries.
        #[serde(rename = "newElementIDs")]
        new_element_ids: Vec<String>,
        #[serde(rename = "offsetX")]
        offset_x: f64,
        #[serde(rename = "offsetY")]
        offset_y: f64,
    },
    #[serde(rename = "element.align")]
    ElementAlign {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
        alignment: ControlAlignment,
    },
    #[serde(rename = "element.distribute")]
    ElementDistribute {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
        distribution: ControlDistribution,
    },
    #[serde(rename = "element.nudge")]
    ElementNudge {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementIDs")]
        element_ids: Vec<String>,
        #[serde(rename = "deltaX")]
        delta_x: f64,
        #[serde(rename = "deltaY")]
        delta_y: f64,
    },
    #[serde(rename = "element.delete")]
    ElementDelete {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementID")]
        element_id: String,
    },
    #[serde(rename = "element.reset")]
    ElementReset {
        #[serde(rename = "profileID")]
        profile_id: String,
        variant: ConfigurationVariant,
        #[serde(rename = "elementID")]
        element_id: String,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum GenerationPreset {
    HollowKnight,
}

impl GenerationPreset {
    pub const fn revision(self) -> u32 {
        2
    }

    pub const fn custom_element_id_count(self) -> usize {
        4
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ControllerTemplate {
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

impl ControllerTemplate {
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

    pub const fn revision(self) -> u32 {
        match self {
            Self::Snes => 2,
            _ => 1,
        }
    }

    pub const fn custom_element_id_count(self) -> usize {
        match self {
            Self::ProductivityStarter
            | Self::ProductivityOneHandedLeft
            | Self::ProductivityOneHandedRight
            | Self::Nes
            | Self::GameBoy => 0,
            Self::Snes | Self::GameBoyAdvance | Self::GenesisSixButton => 2,
            Self::Dreamcast | Self::Psp => 3,
            Self::Saturn => 4,
            Self::GameCube | Self::ArcadeStick => 5,
            Self::PlayStation | Self::Xbox => 6,
            Self::Nintendo64 => 8,
            Self::SoftWhite => 15,
        }
    }

    pub const fn is_productivity(self) -> bool {
        matches!(
            self,
            Self::ProductivityStarter
                | Self::ProductivityOneHandedLeft
                | Self::ProductivityOneHandedRight
        )
    }

    pub const fn id(self) -> &'static str {
        match self {
            Self::ProductivityStarter => "productivityStarter",
            Self::ProductivityOneHandedLeft => "productivityOneHandedLeft",
            Self::ProductivityOneHandedRight => "productivityOneHandedRight",
            Self::Nes => "nes",
            Self::Snes => "snes",
            Self::Nintendo64 => "nintendo64",
            Self::GameCube => "gameCube",
            Self::GameBoy => "gameBoy",
            Self::GameBoyAdvance => "gameBoyAdvance",
            Self::GenesisSixButton => "genesisSixButton",
            Self::Saturn => "saturn",
            Self::Dreamcast => "dreamcast",
            Self::ArcadeStick => "arcadeStick",
            Self::Psp => "psp",
            Self::PlayStation => "playStation",
            Self::Xbox => "xbox",
            Self::SoftWhite => "softWhite",
        }
    }

    pub const fn display_name(self) -> &'static str {
        match self {
            Self::ProductivityStarter => "Productivity Starter",
            Self::ProductivityOneHandedLeft => "One-Handed Left",
            Self::ProductivityOneHandedRight => "One-Handed Right",
            Self::Nes => "NES",
            Self::Snes => "Super Nintendo",
            Self::Nintendo64 => "Nintendo 64",
            Self::GameCube => "GameCube",
            Self::GameBoy => "Game Boy",
            Self::GameBoyAdvance => "Game Boy Advance",
            Self::GenesisSixButton => "Genesis 6-Button",
            Self::Saturn => "Sega Saturn",
            Self::Dreamcast => "Dreamcast",
            Self::ArcadeStick => "Arcade Stick",
            Self::Psp => "PSP",
            Self::PlayStation => "PlayStation",
            Self::Xbox => "Xbox",
            Self::SoftWhite => "Soft White Pro",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum GeneratedProfileDestination {
    Create {
        #[serde(rename = "newProfileID")]
        new_profile_id: String,
    },
    Replace {
        #[serde(rename = "profileID")]
        profile_id: String,
    },
}

impl GeneratedProfileDestination {
    pub fn profile_id(&self) -> &str {
        match self {
            Self::Create { new_profile_id } => new_profile_id,
            Self::Replace { profile_id } => profile_id,
        }
    }

    pub const fn is_create(&self) -> bool {
        matches!(self, Self::Create { .. })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationVariant {
    Primary,
    Portrait,
    Landscape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum LayoutRepairKind {
    ShowDefaultControls,
    MoveInsideSafeArea,
    MinimumTouchTarget,
    ResolveOverlap,
    AutoArrange,
    SeparateExpandedHitTargets,
    ErgonomicAutoArrange,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum LayoutRepairTarget {
    All {},
    Repair { repair: LayoutRepairKind },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "source", rename_all = "lowercase", deny_unknown_fields)]
pub enum LayoutRepairCanvas {
    Stored {},
    Frame {
        #[serde(rename = "frameID")]
        frame_id: String,
    },
    Size {
        width: f64,
        height: f64,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationOutputMode {
    Keyboard,
    Controller,
    Custom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ConfigurationControlBarItem {
    Status,
    ProfileMenu,
    LaunchTarget,
    Spacer,
    EditLayout,
    Settings,
    Home,
    Connection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationOrientationPreference {
    Automatic,
    Portrait,
    Landscape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationLayoutMode {
    Standard,
    Southpaw,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationControlScale {
    Compact,
    Standard,
    Large,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationColorScheme {
    System,
    Light,
    Dark,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationAccentStyle {
    Monochrome,
    Blue,
    Green,
    Purple,
    Pink,
    Amber,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ConfigurationBackgroundScope {
    All,
    Light,
    Dark,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConfigurationRgbaColor {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
    pub alpha: f64,
}

impl ConfigurationRgbaColor {
    fn is_valid(self) -> bool {
        [self.red, self.green, self.blue, self.alpha]
            .into_iter()
            .all(|component| component.is_finite() && (0.0..=1.0).contains(&component))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum StyleMaterialPreset {
    SoftWhiteRaised,
    SoftWhiteInset,
    SoftWhitePlate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StyleIconSource {
    SfSymbol,
    Text,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StyleIcon {
    pub source: StyleIconSource,
    pub value: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StyleHapticKind {
    None,
    Light,
    Medium,
    Heavy,
    Soft,
    Rigid,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum StyleHapticPattern {
    Single,
    Double,
    Pulse,
    Buzz,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StyleHaptic {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub style: Option<StyleHapticKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pattern: Option<StyleHapticPattern>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub intensity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sharpness: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StyleShadow {
    pub color: ConfigurationRgbaColor,
    pub radius: f64,
    pub x: f64,
    pub y: f64,
    #[serde(default = "default_style_shadow_opacity")]
    pub opacity: f64,
}

const fn default_style_shadow_opacity() -> f64 {
    1.0
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StyleAppearance {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub material_preset: Option<StyleMaterialPreset>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_color: Option<ConfigurationRgbaColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub foreground_color: Option<ConfigurationRgbaColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_color: Option<ConfigurationRgbaColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stroke_width: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub glow_color: Option<ConfigurationRgbaColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub glow_radius: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inner_shadow_color: Option<ConfigurationRgbaColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inner_shadow_radius: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inner_shadow_x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub inner_shadow_y: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub highlight_color: Option<ConfigurationRgbaColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub highlight_radius: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub highlight_x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub highlight_y: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub highlight_opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bevel_highlight_color: Option<ConfigurationRgbaColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bevel_shadow_color: Option<ConfigurationRgbaColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bevel_width: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadows: Option<Vec<StyleShadow>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pressed_fill_color: Option<ConfigurationRgbaColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pressed_scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<StyleIcon>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub haptic: Option<StyleHaptic>,
}

impl StyleAppearance {
    fn is_empty(&self) -> bool {
        self == &Self::default()
    }

    fn validate(&self) -> Result<(), ConfigurationOperationError> {
        if self.is_empty() {
            return Err(ConfigurationOperationError::EmptyChanges);
        }
        let colors = [
            self.fill_color,
            self.foreground_color,
            self.stroke_color,
            self.glow_color,
            self.inner_shadow_color,
            self.highlight_color,
            self.bevel_highlight_color,
            self.bevel_shadow_color,
            self.pressed_fill_color,
        ];
        if colors.into_iter().flatten().any(|color| !color.is_valid()) {
            return Err(ConfigurationOperationError::InvalidColor);
        }
        validate_optional_style_number(self.stroke_width, 0.0, 12.0)?;
        validate_optional_style_number(self.glow_radius, 0.0, 64.0)?;
        validate_optional_style_number(self.inner_shadow_radius, 0.0, 64.0)?;
        validate_optional_style_number(self.inner_shadow_x, -64.0, 64.0)?;
        validate_optional_style_number(self.inner_shadow_y, -64.0, 64.0)?;
        validate_optional_style_number(self.highlight_radius, 0.0, 64.0)?;
        validate_optional_style_number(self.highlight_x, -64.0, 64.0)?;
        validate_optional_style_number(self.highlight_y, -64.0, 64.0)?;
        validate_optional_style_number(self.highlight_opacity, 0.0, 1.0)?;
        validate_optional_style_number(self.bevel_width, 0.0, 24.0)?;
        validate_optional_style_number(self.opacity, 0.0, 1.0)?;
        validate_optional_style_number(self.pressed_scale, 0.5, 1.5)?;
        if let Some(shadows) = &self.shadows {
            if shadows.len() > 8 {
                return Err(ConfigurationOperationError::InvalidStyle);
            }
            for shadow in shadows {
                if !shadow.color.is_valid() {
                    return Err(ConfigurationOperationError::InvalidColor);
                }
                for (value, lower, upper) in [
                    (shadow.radius, 0.0, 96.0),
                    (shadow.x, -96.0, 96.0),
                    (shadow.y, -96.0, 96.0),
                    (shadow.opacity, 0.0, 1.0),
                ] {
                    validate_style_number(value, lower, upper)?;
                }
            }
        }
        if let Some(icon) = &self.icon {
            let value = icon.value.trim();
            if value.is_empty() || value.chars().count() > 80 {
                return Err(ConfigurationOperationError::InvalidStyle);
            }
        }
        if let Some(haptic) = &self.haptic {
            if haptic.style.is_none()
                && haptic.pattern.is_none()
                && haptic.intensity.is_none()
                && haptic.sharpness.is_none()
                && haptic.duration.is_none()
            {
                return Err(ConfigurationOperationError::InvalidStyle);
            }
            validate_optional_style_number(haptic.intensity, 0.0, 1.0)?;
            validate_optional_style_number(haptic.sharpness, 0.0, 1.0)?;
            validate_optional_style_number(haptic.duration, 0.02, 0.30)?;
        }
        Ok(())
    }
}

fn validate_optional_style_number(
    value: Option<f64>,
    lower: f64,
    upper: f64,
) -> Result<(), ConfigurationOperationError> {
    if let Some(value) = value {
        validate_style_number(value, lower, upper)?;
    }
    Ok(())
}

fn validate_style_number(
    value: f64,
    lower: f64,
    upper: f64,
) -> Result<(), ConfigurationOperationError> {
    if value.is_finite() && (lower..=upper).contains(&value) {
        Ok(())
    } else {
        Err(ConfigurationOperationError::InvalidStyle)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum ConfigurationBackgroundEdit {
    Keep,
    Clear,
    Set {
        scope: ConfigurationBackgroundScope,
        color: ConfigurationRgbaColor,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CustomizationChanges {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout_mode: Option<ConfigurationLayoutMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub control_scale: Option<ConfigurationControlScale>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color_scheme: Option<ConfigurationColorScheme>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accent_style: Option<ConfigurationAccentStyle>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shows_button_labels: Option<bool>,
    pub background_edit: ConfigurationBackgroundEdit,
}

impl CustomizationChanges {
    fn is_empty(&self) -> bool {
        self.layout_mode.is_none()
            && self.control_scale.is_none()
            && self.color_scheme.is_none()
            && self.accent_style.is_none()
            && self.shows_button_labels.is_none()
            && matches!(self.background_edit, ConfigurationBackgroundEdit::Keep)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ControlBarMoveDirection {
    Up,
    Down,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum LayerMoveDestination {
    Index {
        index: i32,
    },
    Before {
        #[serde(rename = "elementID")]
        element_id: String,
    },
    After {
        #[serde(rename = "elementID")]
        element_id: String,
    },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum KeyboardOutputEdit {
    Keep,
    Clear,
    Set { sequence: Vec<SemanticKeyStroke> },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "lowercase", deny_unknown_fields)]
pub enum GamepadOutputEdit {
    Keep,
    Clear,
    Set { button: ConfigurationGamepadButton },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ConfigurationGamepadButton {
    South,
    East,
    West,
    North,
    LeftShoulder,
    RightShoulder,
    LeftTriggerButton,
    RightTriggerButton,
    Select,
    Start,
    Home,
    LeftStickPress,
    RightStickPress,
    DpadUp,
    DpadDown,
    DpadLeft,
    DpadRight,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OrientationVariant {
    Portrait,
    Landscape,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ControlAlignment {
    Left,
    HorizontalCenters,
    Right,
    Top,
    VerticalCenters,
    Bottom,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ControlDistribution {
    HorizontalCenters,
    VerticalCenters,
    HorizontalSpacing,
    VerticalSpacing,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ElementKind {
    Button,
    Joystick,
    Trigger,
    Trackpad,
    Text,
    Decoration,
}

impl ElementKind {
    pub const fn is_passive(self) -> bool {
        matches!(self, Self::Text | Self::Decoration)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ElementVisualRole {
    Movement,
    PrimaryAction,
    SecondaryAction,
    Utility,
    Menu,
    Custom,
    Joystick,
    Trigger,
    Trackpad,
    Decoration,
    System,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ElementShape {
    RoundedRectangle,
    Rectangle,
    Capsule,
    Circle,
    Ellipse,
    Polygon,
    Star,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementHitInsets {
    pub top: f64,
    pub leading: f64,
    pub bottom: f64,
    pub trailing: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementCornerRadii {
    pub top_leading: f64,
    pub top_trailing: f64,
    pub bottom_trailing: f64,
    pub bottom_leading: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ElementGradientType {
    Linear,
    Radial,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementGradientStop {
    pub offset: f64,
    pub color: ConfigurationRgbaColor,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ElementTilePattern {
    Dots,
    Grid,
    Checker,
    Diagonal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ElementTileAlignment {
    TopLeading,
    Top,
    TopTrailing,
    Leading,
    Center,
    Trailing,
    BottomLeading,
    Bottom,
    BottomTrailing,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase", deny_unknown_fields)]
pub enum ElementFill {
    Solid {
        color: ConfigurationRgbaColor,
    },
    Gradient {
        #[serde(rename = "type")]
        gradient_type: ElementGradientType,
        #[serde(rename = "angleDegrees")]
        angle_degrees: f64,
        stops: Vec<ElementGradientStop>,
    },
    Tile {
        pattern: ElementTilePattern,
        #[serde(rename = "foregroundColor")]
        foreground_color: ConfigurationRgbaColor,
        #[serde(rename = "backgroundColor")]
        background_color: ConfigurationRgbaColor,
        scale: f64,
        #[serde(rename = "spacingX")]
        spacing_x: f64,
        #[serde(rename = "spacingY")]
        spacing_y: f64,
        alignment: ElementTileAlignment,
        opacity: f64,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ElementJoystickVisualStyle {
    Pad,
    Thumbstick,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementJoystickMapping {
    pub up: GameButton,
    pub down: GameButton,
    pub left: GameButton,
    pub right: GameButton,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ElementJoystickAnalogTarget {
    None,
    LeftStick,
    RightStick,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementJoystickSettings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub analog_target: Option<ElementJoystickAnalogTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sends_digital_directions: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dead_zone: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sensitivity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invert_x: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub invert_y: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub snap_to_cardinal: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ElementTriggerTarget {
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ElementTriggerOrientation {
    Vertical,
    Horizontal,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementTriggerSettings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<ElementTriggerTarget>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub orientation: Option<ElementTriggerOrientation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dead_zone: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sensitivity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sends_digital_button: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digital_threshold: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementTrackpadSettings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sensitivity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scroll_sensitivity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tap_to_click: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub two_finger_scroll: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub natural_scrolling: Option<bool>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ElementInputPart {
    Primary,
    JoystickUp,
    JoystickDown,
    JoystickLeft,
    JoystickRight,
    TriggerDigital,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementOutputChanges {
    pub part: ElementInputPart,
    pub keyboard_edit: KeyboardOutputEdit,
    pub gamepad_edit: GamepadOutputEdit,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ElementChanges {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default)]
    pub clear_label: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<ElementKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mapped_button: Option<GameButton>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub visual_role: Option<ElementVisualRole>,
    #[serde(default)]
    pub clear_visual_role: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub center_x: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub center_y: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width_scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height_scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rotation_degrees: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<ElementShape>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_hidden: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_location_locked: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shows_integrated_label: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub z_index: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hit_insets: Option<ElementHitInsets>,
    #[serde(default)]
    pub clear_hit_insets: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub corner_radius: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub corner_radii: Option<ElementCornerRadii>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadow_strength: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill: Option<ElementFill>,
    #[serde(default)]
    pub clear_fill: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub light_fill: Option<ElementFill>,
    #[serde(default)]
    pub clear_light_fill: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dark_fill: Option<ElementFill>,
    #[serde(default)]
    pub clear_dark_fill: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub light_fill_opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dark_fill_opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumb_fill: Option<ConfigurationRgbaColor>,
    #[serde(default)]
    pub clear_thumb_fill: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub light_thumb_fill: Option<ConfigurationRgbaColor>,
    #[serde(default)]
    pub clear_light_thumb_fill: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dark_thumb_fill: Option<ConfigurationRgbaColor>,
    #[serde(default)]
    pub clear_dark_thumb_fill: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumb_opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub light_thumb_opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dark_thumb_opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub joystick_visual_style: Option<ElementJoystickVisualStyle>,
    #[serde(rename = "styleID", default, skip_serializing_if = "Option::is_none")]
    pub style_id: Option<String>,
    #[serde(default)]
    pub clear_style: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub appearance: Option<Box<StyleAppearance>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<StyleIcon>,
    #[serde(default)]
    pub clear_icon: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub haptic: Option<StyleHaptic>,
    #[serde(default)]
    pub clear_haptic: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub joystick_mapping: Option<ElementJoystickMapping>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub joystick_settings: Option<ElementJoystickSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trigger_settings: Option<ElementTriggerSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trackpad_settings: Option<ElementTrackpadSettings>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output: Option<ElementOutputChanges>,
}

impl ElementChanges {
    fn is_empty(&self) -> bool {
        self == &Self::default()
    }
}

/// Safe, rendering-effective subset of the standalone control-bar item appearance patch.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ControlBarItemChanges {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub width_scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height_scale: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_hidden: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<ElementShape>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub accent_style: Option<ConfigurationAccentStyle>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub corner_radius: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub corner_radii: Option<ElementCornerRadii>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadow_strength: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill: Option<ElementFill>,
    #[serde(default)]
    pub clear_fill: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub light_fill: Option<ElementFill>,
    #[serde(default)]
    pub clear_light_fill: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dark_fill: Option<ElementFill>,
    #[serde(default)]
    pub clear_dark_fill: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fill_opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub light_fill_opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub dark_fill_opacity: Option<f64>,
    #[serde(rename = "styleID", default, skip_serializing_if = "Option::is_none")]
    pub style_id: Option<String>,
    #[serde(default)]
    pub clear_style: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub appearance: Option<Box<StyleAppearance>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<StyleIcon>,
    #[serde(default)]
    pub clear_icon: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub haptic: Option<StyleHaptic>,
    #[serde(default)]
    pub clear_haptic: bool,
}

impl ControlBarItemChanges {
    fn is_empty(&self) -> bool {
        self == &Self::default()
    }

    fn has_spacer_forbidden_change(&self) -> bool {
        self.height_scale.is_some()
            || self.shape.is_some()
            || self.accent_style.is_some()
            || self.corner_radius.is_some()
            || self.corner_radii.is_some()
            || self.shadow_strength.is_some()
            || self.fill.is_some()
            || self.clear_fill
            || self.light_fill.is_some()
            || self.clear_light_fill
            || self.dark_fill.is_some()
            || self.clear_dark_fill
            || self.fill_opacity.is_some()
            || self.light_fill_opacity.is_some()
            || self.dark_fill_opacity.is_some()
            || self.style_id.is_some()
            || self.clear_style
            || self.appearance.is_some()
            || self.icon.is_some()
            || self.clear_icon
            || self.haptic.is_some()
            || self.clear_haptic
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SemanticKeyStroke {
    pub key: String,
    #[serde(default)]
    pub modifiers: Vec<SemanticModifier>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SemanticModifier {
    Command,
    Shift,
    Option,
    Control,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigurationOperationOutcome {
    pub changed: bool,
    pub changed_paths: Vec<String>,
}

impl ConfigurationOperation {
    pub fn validate_bridge_input(&self) -> Result<(), ConfigurationOperationError> {
        match self {
            Self::ElementAdd {
                profile_id,
                element_id,
                kind,
                changes,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_new_element_ids(std::slice::from_ref(element_id), 1, 1)?;
                validate_element_changes(changes, true)?;
                if requested_element_kind(*kind, changes).is_passive() && changes.output.is_some() {
                    return Err(ConfigurationOperationError::InvalidOutput);
                }
            }
            Self::ElementSet {
                profile_id,
                element_id,
                changes,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_element_id(element_id)?;
                if changes.is_empty() {
                    return Err(ConfigurationOperationError::EmptyChanges);
                }
                validate_element_changes(changes, false)?;
                if changes.kind.is_some_and(ElementKind::is_passive) && changes.output.is_some() {
                    return Err(ConfigurationOperationError::InvalidOutput);
                }
            }
            Self::BindingSet {
                profile_id,
                sequence,
                ..
            } => {
                validate_profile_id(profile_id)?;
                if sequence.is_empty() || sequence.len() > MAXIMUM_CONFIGURATION_BINDING_STROKES {
                    return Err(ConfigurationOperationError::InvalidBindingSequence);
                }
                for stroke in sequence {
                    resolve_stroke(stroke)?;
                }
            }
            Self::BindingClear { profile_id, .. }
            | Self::BindingReset { profile_id, .. }
            | Self::BindingResetAll { profile_id }
            | Self::OutputMode { profile_id, .. }
            | Self::OutputReset { profile_id, .. }
            | Self::OutputResetAll { profile_id } => validate_profile_id(profile_id)?,
            Self::OutputSet {
                profile_id,
                keyboard_edit,
                gamepad_edit,
                ..
            } => {
                validate_profile_id(profile_id)?;
                if matches!(keyboard_edit, KeyboardOutputEdit::Keep)
                    && matches!(gamepad_edit, GamepadOutputEdit::Keep)
                {
                    return Err(ConfigurationOperationError::EmptyChanges);
                }
                if let KeyboardOutputEdit::Set { sequence } = keyboard_edit {
                    if sequence.is_empty() || sequence.len() > MAXIMUM_CONFIGURATION_BINDING_STROKES
                    {
                        return Err(ConfigurationOperationError::InvalidBindingSequence);
                    }
                    for stroke in sequence {
                        resolve_stroke(stroke)?;
                    }
                }
            }
            Self::CustomizationSet {
                profile_id,
                changes,
                ..
            } => {
                validate_profile_id(profile_id)?;
                if changes.is_empty() {
                    return Err(ConfigurationOperationError::EmptyChanges);
                }
                if let ConfigurationBackgroundEdit::Set { color, .. } = changes.background_edit {
                    if !color.is_valid() {
                        return Err(ConfigurationOperationError::InvalidColor);
                    }
                }
            }
            Self::CustomizationFix {
                profile_id, canvas, ..
            } => {
                validate_profile_id(profile_id)?;
                match canvas.as_ref() {
                    LayoutRepairCanvas::Stored {} => {}
                    LayoutRepairCanvas::Frame { frame_id } => {
                        if !is_supported_device_frame_id(frame_id) {
                            return Err(ConfigurationOperationError::InvalidDeviceFrame);
                        }
                    }
                    LayoutRepairCanvas::Size { width, height } => {
                        if !width.is_finite()
                            || !height.is_finite()
                            || !(240.0..=1_800.0).contains(width)
                            || !(240.0..=1_800.0).contains(height)
                        {
                            return Err(ConfigurationOperationError::InvalidGeometry);
                        }
                    }
                }
            }
            Self::DeviceSet {
                profile_id,
                variant,
                frame_id,
            } => {
                validate_profile_id(profile_id)?;
                if !is_supported_device_frame_id(frame_id)
                    || matches!(variant, ConfigurationVariant::Landscape)
                        && !frame_id.ends_with("-landscape")
                    || matches!(variant, ConfigurationVariant::Portrait)
                        && !frame_id.ends_with("-portrait")
                {
                    return Err(ConfigurationOperationError::InvalidDeviceFrame);
                }
            }
            Self::ControlBarSet {
                profile_id, items, ..
            } => {
                validate_profile_id(profile_id)?;
                if items.is_empty()
                    || items.len() > 8
                    || items
                        .iter()
                        .copied()
                        .collect::<std::collections::HashSet<_>>()
                        .len()
                        != items.len()
                {
                    return Err(ConfigurationOperationError::InvalidControlBar);
                }
            }
            Self::ControlBarItemSet {
                profile_id,
                item,
                changes,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_control_bar_item_changes(changes)?;
                if *item == ConfigurationControlBarItem::Spacer
                    && changes.has_spacer_forbidden_change()
                {
                    return Err(ConfigurationOperationError::InvalidControlBar);
                }
            }
            Self::StyleCreate {
                profile_id,
                style_id,
                name,
                appearance,
            } => {
                validate_profile_id(profile_id)?;
                validate_style_id(style_id)?;
                validate_style_name(name)?;
                appearance.validate()?;
            }
            Self::StyleRename {
                profile_id,
                style_id,
                name,
            } => {
                validate_profile_id(profile_id)?;
                validate_style_id(style_id)?;
                validate_style_name(name)?;
            }
            Self::StyleApply {
                profile_id,
                style_id,
                element_id,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_style_id(style_id)?;
                validate_element_id(element_id)?;
            }
            Self::StyleDetach {
                profile_id,
                element_id,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_element_id(element_id)?;
            }
            Self::StyleDelete {
                profile_id,
                style_id,
            } => {
                validate_profile_id(profile_id)?;
                validate_style_id(style_id)?;
            }
            Self::LayerMove {
                profile_id,
                element_id,
                destination,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_element_id(element_id)?;
                match destination {
                    LayerMoveDestination::Index { index } => {
                        if !(-512..=512).contains(index) {
                            return Err(ConfigurationOperationError::InvalidLayerDestination);
                        }
                    }
                    LayerMoveDestination::Before { element_id }
                    | LayerMoveDestination::After { element_id } => {
                        validate_element_id(element_id)?;
                    }
                }
            }
            Self::GroupCreate {
                profile_id,
                group_id,
                name,
                element_ids,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_group_id(group_id)?;
                validate_group_name(name)?;
                validate_element_ids(element_ids)?;
            }
            Self::GroupRename {
                profile_id,
                group_id,
                name,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_group_id(group_id)?;
                validate_group_name(name)?;
            }
            Self::GroupDuplicate {
                profile_id,
                group_id,
                new_group_id,
                name,
                new_element_ids,
                offset_x,
                offset_y,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_group_id(group_id)?;
                validate_group_id(new_group_id)?;
                if group_id.eq_ignore_ascii_case(new_group_id) {
                    return Err(ConfigurationOperationError::InvalidGroup);
                }
                if let Some(name) = name {
                    validate_group_name(name)?;
                }
                validate_new_element_ids(new_element_ids, 1, 128)?;
                if !offset_x.is_finite()
                    || !offset_y.is_finite()
                    || !(-1.0..=1.0).contains(offset_x)
                    || !(-1.0..=1.0).contains(offset_y)
                {
                    return Err(ConfigurationOperationError::InvalidGeometry);
                }
            }
            Self::GroupNudge {
                profile_id,
                group_id,
                canvas_frame_id,
                delta_x,
                delta_y,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_group_id(group_id)?;
                if !is_supported_device_frame_id(canvas_frame_id) {
                    return Err(ConfigurationOperationError::InvalidDeviceFrame);
                }
                if !delta_x.is_finite()
                    || !delta_y.is_finite()
                    || !(-1_000.0..=1_000.0).contains(delta_x)
                    || !(-1_000.0..=1_000.0).contains(delta_y)
                    || (*delta_x == 0.0 && *delta_y == 0.0)
                {
                    return Err(ConfigurationOperationError::InvalidGeometry);
                }
            }
            Self::GroupUngroup {
                profile_id,
                group_id,
                ..
            }
            | Self::GroupHide {
                profile_id,
                group_id,
                ..
            }
            | Self::GroupShow {
                profile_id,
                group_id,
                ..
            }
            | Self::GroupLock {
                profile_id,
                group_id,
                ..
            }
            | Self::GroupUnlock {
                profile_id,
                group_id,
                ..
            }
            | Self::GroupForward {
                profile_id,
                group_id,
                ..
            }
            | Self::GroupBackward {
                profile_id,
                group_id,
                ..
            }
            | Self::GroupFront {
                profile_id,
                group_id,
                ..
            }
            | Self::GroupBack {
                profile_id,
                group_id,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_group_id(group_id)?;
            }
            Self::LayerForward {
                profile_id,
                element_id,
                ..
            }
            | Self::LayerBackward {
                profile_id,
                element_id,
                ..
            }
            | Self::LayerFront {
                profile_id,
                element_id,
                ..
            }
            | Self::LayerBack {
                profile_id,
                element_id,
                ..
            } => {
                validate_profile_id(profile_id)?;
                validate_element_id(element_id)?;
            }
            Self::OrientationSet { profile_id, .. }
            | Self::ControlBarAdd { profile_id, .. }
            | Self::ControlBarRemove { profile_id, .. }
            | Self::ControlBarMove { profile_id, .. } => validate_profile_id(profile_id)?,
            Self::GenerationGenerate {
                preset,
                preset_revision,
                destination,
                new_element_ids,
                ..
            } => {
                if *preset_revision != preset.revision() {
                    return Err(ConfigurationOperationError::RevisionMismatch);
                }
                validate_generated_operation(
                    destination,
                    new_element_ids,
                    preset.custom_element_id_count(),
                )?;
            }
            Self::TemplateInstall {
                template,
                template_revision,
                destination,
                name,
                new_element_ids,
                ..
            } => {
                if *template_revision != template.revision() {
                    return Err(ConfigurationOperationError::RevisionMismatch);
                }
                if let Some(name) = name {
                    let trimmed = name.trim();
                    if trimmed.is_empty()
                        || trimmed.chars().count() > MAXIMUM_PROFILE_NAME_CHARACTERS
                    {
                        return Err(ConfigurationOperationError::InvalidProfileName);
                    }
                }
                validate_generated_operation(
                    destination,
                    new_element_ids,
                    template.custom_element_id_count(),
                )?;
            }
            _ => {}
        }
        Ok(())
    }

    pub const fn requires_bridge(&self) -> bool {
        matches!(
            self,
            Self::ElementAdd { .. }
                | Self::ElementSet { .. }
                | Self::BindingSet { .. }
                | Self::BindingClear { .. }
                | Self::BindingReset { .. }
                | Self::BindingResetAll { .. }
                | Self::OutputMode { .. }
                | Self::OutputSet { .. }
                | Self::OutputReset { .. }
                | Self::OutputResetAll { .. }
                | Self::ProfileReset { .. }
                | Self::CustomizationSet { .. }
                | Self::CustomizationReset { .. }
                | Self::CustomizationFix { .. }
                | Self::OrientationSet { .. }
                | Self::DeviceSet { .. }
                | Self::ControlBarSet { .. }
                | Self::ControlBarAdd { .. }
                | Self::ControlBarRemove { .. }
                | Self::ControlBarMove { .. }
                | Self::ControlBarItemSet { .. }
                | Self::StyleCreate { .. }
                | Self::StyleRename { .. }
                | Self::StyleApply { .. }
                | Self::StyleDetach { .. }
                | Self::StyleDelete { .. }
                | Self::LayerMove { .. }
                | Self::LayerForward { .. }
                | Self::LayerBackward { .. }
                | Self::LayerFront { .. }
                | Self::LayerBack { .. }
                | Self::GroupCreate { .. }
                | Self::GroupRename { .. }
                | Self::GroupDuplicate { .. }
                | Self::GroupUngroup { .. }
                | Self::GroupHide { .. }
                | Self::GroupShow { .. }
                | Self::GroupLock { .. }
                | Self::GroupUnlock { .. }
                | Self::GroupNudge { .. }
                | Self::GroupForward { .. }
                | Self::GroupBackward { .. }
                | Self::GroupFront { .. }
                | Self::GroupBack { .. }
                | Self::ControlBarReset { .. }
                | Self::ControlBarItemReset { .. }
                | Self::GenerationGenerate { .. }
                | Self::TemplateInstall { .. }
                | Self::ProfileSelect { .. }
                | Self::ProfileSetDefault { .. }
                | Self::ProfileDuplicate { .. }
                | Self::ProfileDelete { .. }
                | Self::ProfileMove { .. }
                | Self::ProfileCreate { .. }
                | Self::ThemeApply { .. }
                | Self::OrientationCopy { .. }
                | Self::ElementDuplicate { .. }
                | Self::ElementAlign { .. }
                | Self::ElementDistribute { .. }
                | Self::ElementNudge { .. }
                | Self::ElementDelete { .. }
                | Self::ElementReset { .. }
        )
    }

    pub fn apply(
        &self,
        document: &mut ConfigurationDocument,
        now_millis: i64,
    ) -> Result<ConfigurationOperationOutcome, ConfigurationOperationError> {
        if self.requires_bridge() {
            return Err(ConfigurationOperationError::BridgeRequired);
        }
        let before = document.clone();
        let changed_paths = match self {
            Self::ProfileRename { profile_id, name } => {
                apply_profile_rename(document, profile_id, name, now_millis)?
            }
            Self::BindingSet {
                profile_id,
                button,
                sequence,
            } => apply_binding_set(document, profile_id, *button, sequence, now_millis)?,
            _ => return Err(ConfigurationOperationError::BridgeRequired),
        };
        let changed = before != *document;
        if changed {
            profile_object_mut(document, self.profile_id())?
                .insert("updatedAt".to_owned(), Value::from(now_millis.max(0)));
        }
        document
            .validate()
            .map_err(|error| ConfigurationOperationError::InvalidResult(error.to_string()))?;
        Ok(ConfigurationOperationOutcome {
            changed,
            changed_paths,
        })
    }

    fn profile_id(&self) -> &str {
        match self {
            Self::ProfileRename { profile_id, .. }
            | Self::ElementAdd { profile_id, .. }
            | Self::ElementSet { profile_id, .. }
            | Self::BindingSet { profile_id, .. }
            | Self::BindingClear { profile_id, .. }
            | Self::BindingReset { profile_id, .. }
            | Self::BindingResetAll { profile_id }
            | Self::OutputMode { profile_id, .. }
            | Self::OutputSet { profile_id, .. }
            | Self::OutputReset { profile_id, .. }
            | Self::OutputResetAll { profile_id }
            | Self::ProfileReset { profile_id }
            | Self::CustomizationSet { profile_id, .. }
            | Self::CustomizationReset { profile_id, .. }
            | Self::CustomizationFix { profile_id, .. }
            | Self::OrientationSet { profile_id, .. }
            | Self::DeviceSet { profile_id, .. }
            | Self::ControlBarSet { profile_id, .. }
            | Self::ControlBarAdd { profile_id, .. }
            | Self::ControlBarRemove { profile_id, .. }
            | Self::ControlBarMove { profile_id, .. }
            | Self::ControlBarItemSet { profile_id, .. }
            | Self::StyleCreate { profile_id, .. }
            | Self::StyleRename { profile_id, .. }
            | Self::StyleApply { profile_id, .. }
            | Self::StyleDetach { profile_id, .. }
            | Self::StyleDelete { profile_id, .. }
            | Self::LayerMove { profile_id, .. }
            | Self::LayerForward { profile_id, .. }
            | Self::LayerBackward { profile_id, .. }
            | Self::LayerFront { profile_id, .. }
            | Self::LayerBack { profile_id, .. }
            | Self::GroupCreate { profile_id, .. }
            | Self::GroupRename { profile_id, .. }
            | Self::GroupDuplicate { profile_id, .. }
            | Self::GroupUngroup { profile_id, .. }
            | Self::GroupHide { profile_id, .. }
            | Self::GroupShow { profile_id, .. }
            | Self::GroupLock { profile_id, .. }
            | Self::GroupUnlock { profile_id, .. }
            | Self::GroupNudge { profile_id, .. }
            | Self::GroupForward { profile_id, .. }
            | Self::GroupBackward { profile_id, .. }
            | Self::GroupFront { profile_id, .. }
            | Self::GroupBack { profile_id, .. }
            | Self::ControlBarReset { profile_id, .. }
            | Self::ControlBarItemReset { profile_id, .. }
            | Self::ProfileSelect { profile_id }
            | Self::ProfileSetDefault { profile_id }
            | Self::ProfileDuplicate { profile_id, .. }
            | Self::ProfileDelete { profile_id, .. }
            | Self::ProfileMove { profile_id, .. }
            | Self::ThemeApply { profile_id, .. }
            | Self::OrientationCopy { profile_id, .. }
            | Self::ElementDuplicate { profile_id, .. }
            | Self::ElementAlign { profile_id, .. }
            | Self::ElementDistribute { profile_id, .. }
            | Self::ElementNudge { profile_id, .. }
            | Self::ElementDelete { profile_id, .. }
            | Self::ElementReset { profile_id, .. } => profile_id,
            Self::ProfileCreate {
                source_profile_id, ..
            } => source_profile_id.as_deref().unwrap_or(""),
            Self::GenerationGenerate { destination, .. }
            | Self::TemplateInstall { destination, .. } => destination.profile_id(),
        }
    }
}

fn apply_profile_rename(
    document: &mut ConfigurationDocument,
    profile_id: &str,
    name: &str,
    _now_millis: i64,
) -> Result<Vec<String>, ConfigurationOperationError> {
    validate_profile_id(profile_id)?;
    let name = name.trim();
    if name.is_empty() || name.chars().count() > MAXIMUM_PROFILE_NAME_CHARACTERS {
        return Err(ConfigurationOperationError::InvalidProfileName);
    }
    let profile = profile_object_mut(document, profile_id)?;
    profile.insert("name".to_owned(), Value::String(name.to_owned()));
    Ok(vec![format!("profiles/{profile_id}/name")])
}

fn apply_binding_set(
    document: &mut ConfigurationDocument,
    profile_id: &str,
    button: GameButton,
    sequence: &[SemanticKeyStroke],
    _now_millis: i64,
) -> Result<Vec<String>, ConfigurationOperationError> {
    validate_profile_id(profile_id)?;
    if sequence.is_empty() || sequence.len() > MAXIMUM_CONFIGURATION_BINDING_STROKES {
        return Err(ConfigurationOperationError::InvalidBindingSequence);
    }
    let strokes = sequence
        .iter()
        .map(resolve_stroke)
        .collect::<Result<Vec<_>, _>>()?;
    let binding = KeyBinding::from_strokes(strokes)
        .ok_or(ConfigurationOperationError::InvalidBindingSequence)?;
    let canonical_profile_id = document
        .profiles
        .iter()
        .filter_map(|profile| profile.get("id").and_then(Value::as_str))
        .find(|candidate| candidate.eq_ignore_ascii_case(profile_id))
        .map(str::to_owned)
        .ok_or(ConfigurationOperationError::ProfileNotFound)?;

    document
        .profile_key_bindings
        .entry(canonical_profile_id.clone())
        .or_default()
        .insert(button, binding.clone());
    let outputs = document
        .profile_output_bindings
        .entry(canonical_profile_id.clone())
        .or_default();
    let mut output = outputs.get(&button).cloned().unwrap_or_default();
    output.keyboard = Some(binding.clone());
    outputs.insert(button, output.clone());
    if document
        .active_profile_id
        .eq_ignore_ascii_case(&canonical_profile_id)
    {
        document.key_bindings.insert(button, binding.clone());
        let mut active_output = document
            .output_bindings
            .get(&button)
            .cloned()
            .unwrap_or_default();
        active_output.keyboard = Some(binding);
        document.output_bindings.insert(button, active_output);
    }

    let output_value =
        serde_json::to_value(&output).map_err(|_| ConfigurationOperationError::EncodingFailed)?;
    let profile = profile_object_mut(document, &canonical_profile_id)?;
    for customization_key in [
        "customization",
        "landscapeCustomization",
        "portraitCustomization",
    ] {
        let Some(elements) = profile
            .get_mut(customization_key)
            .and_then(Value::as_object_mut)
            .and_then(|customization| customization.get_mut("elements"))
            .and_then(Value::as_array_mut)
        else {
            continue;
        };
        for element in elements {
            let mapped = element
                .get("legacySlot")
                .or_else(|| element.get("builtInButton"))
                .and_then(|value| serde_json::from_value::<GameButton>(value.clone()).ok());
            if mapped == Some(button) {
                if let Some(element) = element.as_object_mut() {
                    element.insert("output".to_owned(), output_value.clone());
                }
            }
        }
    }
    Ok(vec![format!(
        "profileBindings/{canonical_profile_id}/{button:?}"
    )])
}

fn profile_object_mut<'a>(
    document: &'a mut ConfigurationDocument,
    profile_id: &str,
) -> Result<&'a mut Map<String, Value>, ConfigurationOperationError> {
    document
        .profiles
        .iter_mut()
        .find(|profile| {
            profile
                .get("id")
                .and_then(Value::as_str)
                .is_some_and(|candidate| candidate.eq_ignore_ascii_case(profile_id))
        })
        .and_then(Value::as_object_mut)
        .ok_or(ConfigurationOperationError::ProfileNotFound)
}

fn validate_new_element_ids(
    ids: &[String],
    minimum: usize,
    maximum: usize,
) -> Result<(), ConfigurationOperationError> {
    if ids.len() < minimum || ids.len() > maximum {
        return Err(ConfigurationOperationError::InvalidElementId);
    }
    let mut seen = std::collections::HashSet::new();
    for id in ids {
        if id.len() > MAXIMUM_ELEMENT_ID_BYTES
            || Uuid::parse_str(id).is_err()
            || !seen.insert(id.to_ascii_lowercase())
        {
            return Err(ConfigurationOperationError::InvalidElementId);
        }
    }
    Ok(())
}

fn validate_generated_operation(
    destination: &GeneratedProfileDestination,
    new_element_ids: &[String],
    expected_count: usize,
) -> Result<(), ConfigurationOperationError> {
    validate_profile_id(destination.profile_id())?;
    if new_element_ids.len() != expected_count {
        return Err(ConfigurationOperationError::InvalidGeneratedElementIds);
    }
    let mut ids = std::collections::BTreeSet::new();
    for id in new_element_ids {
        validate_profile_id(id)
            .map_err(|_| ConfigurationOperationError::InvalidGeneratedElementIds)?;
        if !ids.insert(id.to_ascii_lowercase()) || id.eq_ignore_ascii_case(destination.profile_id())
        {
            return Err(ConfigurationOperationError::InvalidGeneratedElementIds);
        }
    }
    Ok(())
}

const SUPPORTED_DEVICE_SPEC_IDS: &[&str] = &[
    "iphone-17-pro",
    "iphone-17-pro-max",
    "iphone-17e",
    "iphone-air",
    "iphone-17",
    "iphone-16-pro",
    "iphone-16-pro-max",
    "iphone-16e",
    "iphone-16",
    "iphone-16-plus",
    "iphone-15-pro",
    "iphone-15-pro-max",
    "iphone-15",
    "iphone-15-plus",
    "iphone-14-pro",
    "iphone-14-pro-max",
    "iphone-14",
    "iphone-14-plus",
    "iphone-se-3",
    "iphone-13-pro",
    "iphone-13-pro-max",
    "iphone-13",
    "iphone-13-mini",
    "iphone-12-pro",
    "iphone-12-pro-max",
    "iphone-12",
    "iphone-12-mini",
    "iphone-se-2",
    "iphone-11-pro",
    "iphone-11-pro-max",
    "iphone-11",
    "iphone-xr",
    "iphone-xs",
    "iphone-xs-max",
];

fn default_nudge_canvas_frame_id() -> String {
    "iphone-17-pro-landscape".to_owned()
}

pub fn is_supported_device_frame_id(frame_id: &str) -> bool {
    let base = frame_id
        .strip_suffix("-landscape")
        .or_else(|| frame_id.strip_suffix("-portrait"));
    base.is_some_and(|base| SUPPORTED_DEVICE_SPEC_IDS.contains(&base))
}

fn validate_profile_id(profile_id: &str) -> Result<(), ConfigurationOperationError> {
    if profile_id.len() > MAXIMUM_OPERATION_ID_BYTES || Uuid::parse_str(profile_id).is_err() {
        return Err(ConfigurationOperationError::InvalidProfileId);
    }
    Ok(())
}

fn validate_group_id(group_id: &str) -> Result<(), ConfigurationOperationError> {
    if group_id.len() > MAXIMUM_OPERATION_ID_BYTES || Uuid::parse_str(group_id).is_err() {
        return Err(ConfigurationOperationError::InvalidGroup);
    }
    Ok(())
}

fn validate_group_name(name: &str) -> Result<(), ConfigurationOperationError> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.chars().count() > 48 {
        return Err(ConfigurationOperationError::InvalidGroup);
    }
    Ok(())
}

fn validate_style_id(style_id: &str) -> Result<(), ConfigurationOperationError> {
    if style_id.is_empty()
        || style_id.len() > 128
        || style_id.starts_with(['.', '-'])
        || style_id.ends_with(['.', '-'])
        || !style_id
            .chars()
            .all(|character| character.is_alphanumeric() || matches!(character, '-' | '_' | '.'))
    {
        return Err(ConfigurationOperationError::InvalidStyle);
    }
    Ok(())
}

fn validate_style_name(name: &str) -> Result<(), ConfigurationOperationError> {
    let trimmed = name.trim();
    if trimmed.is_empty() || trimmed.chars().count() > 48 {
        return Err(ConfigurationOperationError::InvalidStyle);
    }
    Ok(())
}

fn validate_element_ids(element_ids: &[String]) -> Result<(), ConfigurationOperationError> {
    if element_ids.is_empty() || element_ids.len() > 128 {
        return Err(ConfigurationOperationError::InvalidElementId);
    }
    let mut seen = std::collections::HashSet::new();
    for element_id in element_ids {
        validate_element_id(element_id)?;
        if !seen.insert(element_id.to_ascii_lowercase()) {
            return Err(ConfigurationOperationError::InvalidElementId);
        }
    }
    Ok(())
}

fn validate_element_id(element_id: &str) -> Result<(), ConfigurationOperationError> {
    if element_id.is_empty()
        || element_id.len() > MAXIMUM_ELEMENT_ID_BYTES
        || !element_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
    {
        return Err(ConfigurationOperationError::InvalidElementId);
    }
    Ok(())
}

fn validate_control_bar_item_changes(
    changes: &ControlBarItemChanges,
) -> Result<(), ConfigurationOperationError> {
    if changes.is_empty() {
        return Err(ConfigurationOperationError::EmptyChanges);
    }
    if changes.fill.is_some() && changes.clear_fill
        || changes.light_fill.is_some() && changes.clear_light_fill
        || changes.dark_fill.is_some() && changes.clear_dark_fill
        || changes.style_id.is_some() && changes.clear_style
        || changes.icon.is_some() && changes.clear_icon
        || changes.haptic.is_some() && changes.clear_haptic
        || changes.corner_radius.is_some() && changes.corner_radii.is_some()
        || changes
            .appearance
            .as_ref()
            .is_some_and(|appearance| appearance.icon.is_some())
            && changes.icon.is_some()
        || changes
            .appearance
            .as_ref()
            .is_some_and(|appearance| appearance.haptic.is_some())
            && changes.haptic.is_some()
    {
        return Err(ConfigurationOperationError::InvalidStyle);
    }
    for (value, minimum, maximum) in [
        (changes.width_scale, 0.001, 12.0),
        (changes.height_scale, 0.001, 12.0),
        (changes.corner_radius, 0.0, 1_024.0),
        (changes.shadow_strength, 0.0, 2.0),
        (changes.fill_opacity, 0.0, 1.0),
        (changes.light_fill_opacity, 0.0, 1.0),
        (changes.dark_fill_opacity, 0.0, 1.0),
    ] {
        if value.is_some_and(|value| !value.is_finite() || value < minimum || value > maximum) {
            return Err(ConfigurationOperationError::InvalidGeometry);
        }
    }
    if let Some(radii) = changes.corner_radii {
        if [
            radii.top_leading,
            radii.top_trailing,
            radii.bottom_trailing,
            radii.bottom_leading,
        ]
        .into_iter()
        .any(|value| !value.is_finite() || !(0.0..=1_024.0).contains(&value))
        {
            return Err(ConfigurationOperationError::InvalidGeometry);
        }
    }
    for fill in [&changes.fill, &changes.light_fill, &changes.dark_fill]
        .into_iter()
        .flatten()
    {
        validate_element_fill(fill)?;
    }
    if let Some(style_id) = &changes.style_id {
        validate_style_id(style_id)?;
    }
    if let Some(appearance) = &changes.appearance {
        appearance.validate()?;
    }
    if let Some(icon) = &changes.icon {
        let value = icon.value.trim();
        if value.is_empty() || value.chars().count() > 80 || value.chars().any(char::is_control) {
            return Err(ConfigurationOperationError::InvalidStyle);
        }
    }
    if let Some(haptic) = &changes.haptic {
        validate_element_haptic(haptic)?;
    }
    Ok(())
}

fn validate_element_changes(
    changes: &ElementChanges,
    allow_empty: bool,
) -> Result<(), ConfigurationOperationError> {
    if !allow_empty && changes.is_empty() {
        return Err(ConfigurationOperationError::EmptyChanges);
    }
    if changes.label.as_ref().is_some_and(|label| {
        label.chars().count() > MAXIMUM_ELEMENT_LABEL_CHARACTERS
            || label.chars().any(char::is_control)
    }) || changes.label.is_some() && changes.clear_label
    {
        return Err(ConfigurationOperationError::InvalidElementLabel);
    }
    if changes.visual_role.is_some() && changes.clear_visual_role
        || changes.hit_insets.is_some() && changes.clear_hit_insets
        || changes.fill.is_some() && changes.clear_fill
        || changes.light_fill.is_some() && changes.clear_light_fill
        || changes.dark_fill.is_some() && changes.clear_dark_fill
        || changes.thumb_fill.is_some() && changes.clear_thumb_fill
        || changes.light_thumb_fill.is_some() && changes.clear_light_thumb_fill
        || changes.dark_thumb_fill.is_some() && changes.clear_dark_thumb_fill
        || changes.style_id.is_some() && changes.clear_style
        || changes.icon.is_some() && changes.clear_icon
        || changes.haptic.is_some() && changes.clear_haptic
        || changes.corner_radius.is_some() && changes.corner_radii.is_some()
    {
        return Err(ConfigurationOperationError::InvalidStyle);
    }
    for (value, minimum, maximum) in [
        (changes.center_x, 0.0, 1.0),
        (changes.center_y, 0.0, 1.0),
        (changes.width_scale, 0.001, 12.0),
        (changes.height_scale, 0.001, 12.0),
        (changes.rotation_degrees, -36_000.0, 36_000.0),
        (changes.corner_radius, 0.0, 1_024.0),
        (changes.shadow_strength, 0.0, 2.0),
        (changes.fill_opacity, 0.0, 1.0),
        (changes.light_fill_opacity, 0.0, 1.0),
        (changes.dark_fill_opacity, 0.0, 1.0),
        (changes.thumb_opacity, 0.0, 1.0),
        (changes.light_thumb_opacity, 0.0, 1.0),
        (changes.dark_thumb_opacity, 0.0, 1.0),
    ] {
        if value.is_some_and(|value| !value.is_finite() || value < minimum || value > maximum) {
            return Err(ConfigurationOperationError::InvalidGeometry);
        }
    }
    if changes
        .z_index
        .is_some_and(|value| !(-100..=100).contains(&value))
    {
        return Err(ConfigurationOperationError::InvalidZIndex);
    }
    if let Some(insets) = changes.hit_insets {
        if [insets.top, insets.leading, insets.bottom, insets.trailing]
            .into_iter()
            .any(|value| !value.is_finite() || !(0.0..=96.0).contains(&value))
        {
            return Err(ConfigurationOperationError::InvalidGeometry);
        }
    }
    if let Some(radii) = changes.corner_radii {
        if [
            radii.top_leading,
            radii.top_trailing,
            radii.bottom_trailing,
            radii.bottom_leading,
        ]
        .into_iter()
        .any(|value| !value.is_finite() || !(0.0..=1_024.0).contains(&value))
        {
            return Err(ConfigurationOperationError::InvalidGeometry);
        }
    }
    for fill in [&changes.fill, &changes.light_fill, &changes.dark_fill]
        .into_iter()
        .flatten()
    {
        validate_element_fill(fill)?;
    }
    for color in [
        changes.thumb_fill,
        changes.light_thumb_fill,
        changes.dark_thumb_fill,
    ]
    .into_iter()
    .flatten()
    {
        if !color.is_valid() {
            return Err(ConfigurationOperationError::InvalidColor);
        }
    }
    if let Some(style_id) = &changes.style_id {
        validate_style_id(style_id)?;
    }
    if let Some(appearance) = &changes.appearance {
        appearance.validate()?;
    }
    if let Some(icon) = &changes.icon {
        let value = icon.value.trim();
        if value.is_empty() || value.chars().count() > 80 || value.chars().any(char::is_control) {
            return Err(ConfigurationOperationError::InvalidStyle);
        }
    }
    if let Some(haptic) = &changes.haptic {
        validate_element_haptic(haptic)?;
    }
    if let Some(settings) = &changes.joystick_settings {
        validate_optional_style_number(settings.dead_zone, 0.0, 0.85)?;
        validate_optional_style_number(settings.sensitivity, 0.2, 3.0)?;
    }
    if let Some(settings) = &changes.trigger_settings {
        validate_optional_style_number(settings.dead_zone, 0.0, 0.85)?;
        validate_optional_style_number(settings.sensitivity, 0.2, 3.0)?;
        validate_optional_style_number(settings.digital_threshold, 0.01, 1.0)?;
    }
    if let Some(settings) = &changes.trackpad_settings {
        validate_optional_style_number(settings.sensitivity, 0.2, 4.0)?;
        validate_optional_style_number(settings.scroll_sensitivity, 0.1, 4.0)?;
    }
    if let Some(output) = &changes.output {
        if matches!(output.keyboard_edit, KeyboardOutputEdit::Keep)
            && matches!(output.gamepad_edit, GamepadOutputEdit::Keep)
        {
            return Err(ConfigurationOperationError::EmptyChanges);
        }
        if let KeyboardOutputEdit::Set { sequence } = &output.keyboard_edit {
            if sequence.is_empty() || sequence.len() > MAXIMUM_CONFIGURATION_BINDING_STROKES {
                return Err(ConfigurationOperationError::InvalidBindingSequence);
            }
            for stroke in sequence {
                resolve_stroke(stroke)?;
            }
        }
    }
    Ok(())
}

fn validate_element_fill(fill: &ElementFill) -> Result<(), ConfigurationOperationError> {
    match fill {
        ElementFill::Solid { color } => {
            if !color.is_valid() {
                return Err(ConfigurationOperationError::InvalidColor);
            }
        }
        ElementFill::Gradient {
            angle_degrees,
            stops,
            ..
        } => {
            if !angle_degrees.is_finite()
                || !(-36_000.0..=36_000.0).contains(angle_degrees)
                || stops.len() < 2
                || stops.len() > 8
                || stops.iter().any(|stop| {
                    !stop.offset.is_finite()
                        || !(0.0..=1.0).contains(&stop.offset)
                        || !stop.color.is_valid()
                })
            {
                return Err(ConfigurationOperationError::InvalidStyle);
            }
        }
        ElementFill::Tile {
            foreground_color,
            background_color,
            scale,
            spacing_x,
            spacing_y,
            opacity,
            ..
        } => {
            if !foreground_color.is_valid()
                || !background_color.is_valid()
                || [
                    (*scale, 0.25, 4.0),
                    (*spacing_x, 0.0, 2.0),
                    (*spacing_y, 0.0, 2.0),
                    (*opacity, 0.0, 1.0),
                ]
                .into_iter()
                .any(|(value, minimum, maximum)| {
                    !value.is_finite() || value < minimum || value > maximum
                })
            {
                return Err(ConfigurationOperationError::InvalidStyle);
            }
        }
    }
    Ok(())
}

fn validate_element_haptic(haptic: &StyleHaptic) -> Result<(), ConfigurationOperationError> {
    if haptic.style.is_none()
        && haptic.pattern.is_none()
        && haptic.intensity.is_none()
        && haptic.sharpness.is_none()
        && haptic.duration.is_none()
    {
        return Err(ConfigurationOperationError::InvalidStyle);
    }
    validate_optional_style_number(haptic.intensity, 0.0, 1.0)?;
    validate_optional_style_number(haptic.sharpness, 0.0, 1.0)?;
    validate_optional_style_number(haptic.duration, 0.02, 0.30)
}

pub(crate) fn resolve_stroke(
    stroke: &SemanticKeyStroke,
) -> Result<KeyStroke, ConfigurationOperationError> {
    if stroke.modifiers.len() > 4 {
        return Err(ConfigurationOperationError::InvalidModifier);
    }
    let mut modifiers = 0u8;
    for modifier in &stroke.modifiers {
        let bit = match modifier {
            SemanticModifier::Command => 1,
            SemanticModifier::Shift => 2,
            SemanticModifier::Option => 4,
            SemanticModifier::Control => 8,
        };
        if modifiers & bit != 0 {
            return Err(ConfigurationOperationError::InvalidModifier);
        }
        modifiers |= bit;
    }
    let key_code = semantic_key_code(&stroke.key)
        .ok_or(ConfigurationOperationError::UnsupportedSemanticKey)?;
    Ok(KeyStroke::new(key_code, modifiers))
}

fn requested_element_kind(initial: ElementKind, changes: &ElementChanges) -> ElementKind {
    let explicit = changes.kind.unwrap_or(initial);
    if changes.joystick_mapping.is_some()
        || changes.joystick_settings.is_some()
        || changes.joystick_visual_style.is_some()
    {
        ElementKind::Joystick
    } else if changes.trigger_settings.is_some() {
        ElementKind::Trigger
    } else if changes.trackpad_settings.is_some() {
        ElementKind::Trackpad
    } else {
        explicit
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConfigurationOperationError {
    BridgeRequired,
    InvalidProfileId,
    ProfileNotFound,
    InvalidProfileName,
    InvalidElementId,
    ElementNotFound,
    VariantUnavailable,
    ElementsUnavailable,
    MalformedLayout,
    EmptyChanges,
    InvalidElementLabel,
    InvalidGeometry,
    InvalidZIndex,
    InvalidBindingSequence,
    InvalidOutput,
    InvalidModifier,
    UnsupportedSemanticKey,
    RevisionMismatch,
    InvalidGeneratedElementIds,
    InvalidColor,
    InvalidDeviceFrame,
    InvalidControlBar,
    InvalidLayerDestination,
    InvalidGroup,
    InvalidStyle,
    EncodingFailed,
    InvalidResult(String),
}

impl fmt::Display for ConfigurationOperationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BridgeRequired => {
                formatter.write_str("operation requires the constrained Swift bridge")
            }
            Self::InvalidProfileId => formatter.write_str("profile ID must be an exact UUID"),
            Self::ProfileNotFound => formatter.write_str("profile does not exist"),
            Self::InvalidProfileName => formatter.write_str("profile name is invalid"),
            Self::InvalidElementId => formatter.write_str("element ID is invalid"),
            Self::ElementNotFound => {
                formatter.write_str("element does not exist in the selected variant")
            }
            Self::VariantUnavailable => {
                formatter.write_str("selected profile variant does not exist")
            }
            Self::ElementsUnavailable => {
                formatter.write_str("selected profile variant has no element collection")
            }
            Self::MalformedLayout => formatter.write_str("element layout is malformed"),
            Self::EmptyChanges => formatter.write_str("element edit contains no changes"),
            Self::InvalidElementLabel => formatter.write_str("element label is too long"),
            Self::InvalidGeometry => {
                formatter.write_str("element geometry is outside allowed bounds")
            }
            Self::InvalidZIndex => formatter.write_str("element z-index is outside allowed bounds"),
            Self::InvalidBindingSequence => {
                formatter.write_str("binding sequence must contain 1 through 32 strokes")
            }
            Self::InvalidOutput => formatter.write_str("output is invalid for the element kind"),
            Self::InvalidModifier => {
                formatter.write_str("binding modifiers are invalid or duplicated")
            }
            Self::UnsupportedSemanticKey => {
                formatter.write_str("binding uses an unsupported semantic key name")
            }
            Self::RevisionMismatch => {
                formatter.write_str("preset or template revision does not match")
            }
            Self::InvalidGeneratedElementIds => {
                formatter.write_str("generated element IDs do not match the operation contract")
            }
            Self::InvalidColor => {
                formatter.write_str("color components must be between zero and one")
            }
            Self::InvalidDeviceFrame => {
                formatter.write_str("device frame ID is not in the built-in catalog")
            }
            Self::InvalidControlBar => formatter.write_str("control bar items are invalid"),
            Self::InvalidLayerDestination => formatter.write_str("layer destination is invalid"),
            Self::InvalidGroup => formatter.write_str("layer group is invalid"),
            Self::InvalidStyle => formatter.write_str("style definition or reference is invalid"),
            Self::EncodingFailed => {
                formatter.write_str("configuration operation could not be encoded")
            }
            Self::InvalidResult(error) => write!(
                formatter,
                "configuration operation produced an invalid result: {error}"
            ),
        }
    }
}

impl Error for ConfigurationOperationError {}

#[cfg(test)]
mod tests {
    use super::*;
    use thumble_core::{ConfigurationDocument, PersistentState};

    fn document() -> ConfigurationDocument {
        ConfigurationDocument::from_state(&PersistentState::minimal("server").unwrap()).unwrap()
    }

    #[test]
    fn rename_is_native_and_element_set_requires_the_constrained_bridge() {
        let mut document = document();
        let profile_id = document.active_profile_id.clone();
        document.profiles[0]["futureProfile"] = serde_json::json!({"kept": true});
        document.profiles[0]["customization"]["elements"][0]["futureElement"] =
            serde_json::json!([1, 2, 3]);
        let rename = ConfigurationOperation::ProfileRename {
            profile_id: profile_id.clone(),
            name: "Arcade".to_owned(),
        };
        assert!(rename.apply(&mut document, 99).unwrap().changed);
        let element_id = document.profiles[0]["customization"]["elements"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let edit = ConfigurationOperation::ElementSet {
            profile_id,
            variant: ConfigurationVariant::Primary,
            element_id,
            changes: Box::new(ElementChanges {
                label: Some("Move Up".to_owned()),
                center_x: Some(0.2),
                center_y: Some(0.8),
                width_scale: Some(1.5),
                shape: Some(ElementShape::Circle),
                ..ElementChanges::default()
            }),
        };
        assert!(edit.requires_bridge());
        assert_eq!(edit.validate_bridge_input(), Ok(()));
        assert_eq!(
            edit.apply(&mut document, 100),
            Err(ConfigurationOperationError::BridgeRequired)
        );
        assert_eq!(document.profiles[0]["futureProfile"]["kept"], true);
        assert_eq!(
            document.profiles[0]["customization"]["elements"][0]["futureElement"],
            serde_json::json!([1, 2, 3])
        );
    }

    #[test]
    fn binding_set_accepts_semantic_names_for_the_constrained_bridge() {
        let document = document();
        let profile_id = document.active_profile_id.clone();
        let operation = ConfigurationOperation::BindingSet {
            profile_id: profile_id.clone(),
            button: GameButton::Jump,
            sequence: vec![
                SemanticKeyStroke {
                    key: "B".to_owned(),
                    modifiers: vec![SemanticModifier::Control],
                },
                SemanticKeyStroke {
                    key: "H".to_owned(),
                    modifiers: vec![],
                },
            ],
        };
        assert!(operation.requires_bridge());
        assert_eq!(operation.validate_bridge_input(), Ok(()));
        let ConfigurationOperation::BindingSet { sequence, .. } = operation else {
            unreachable!()
        };
        assert_eq!(
            sequence
                .iter()
                .map(resolve_stroke)
                .collect::<Result<Vec<_>, _>>(),
            Ok(vec![KeyStroke::new(11, 8), KeyStroke::new(4, 0)])
        );
        assert_eq!(
            resolve_stroke(&SemanticKeyStroke {
                key: "←".to_owned(),
                modifiers: vec![],
            }),
            Ok(KeyStroke::new(123, 0))
        );
        assert_eq!(
            resolve_stroke(&SemanticKeyStroke {
                key: "left-arrow".to_owned(),
                modifiers: vec![],
            }),
            Err(ConfigurationOperationError::UnsupportedSemanticKey)
        );
        assert_eq!(
            resolve_stroke(&SemanticKeyStroke {
                key: "A".to_owned(),
                modifiers: vec![SemanticModifier::Command, SemanticModifier::Command],
            }),
            Err(ConfigurationOperationError::InvalidModifier)
        );
    }

    #[test]
    fn output_set_bridge_input_rejects_empty_and_raw_key_edits() {
        let profile_id = document().active_profile_id;
        let empty = ConfigurationOperation::OutputSet {
            profile_id: profile_id.clone(),
            button: GameButton::Jump,
            keyboard_edit: KeyboardOutputEdit::Keep,
            gamepad_edit: GamepadOutputEdit::Keep,
        };
        assert_eq!(
            empty.validate_bridge_input(),
            Err(ConfigurationOperationError::EmptyChanges)
        );

        let raw_key = ConfigurationOperation::OutputSet {
            profile_id,
            button: GameButton::Jump,
            keyboard_edit: KeyboardOutputEdit::Set {
                sequence: vec![SemanticKeyStroke {
                    key: "36".to_owned(),
                    modifiers: vec![],
                }],
            },
            gamepad_edit: GamepadOutputEdit::Clear,
        };
        assert_eq!(
            raw_key.validate_bridge_input(),
            Err(ConfigurationOperationError::UnsupportedSemanticKey)
        );
    }

    #[test]
    fn scalar_layout_operations_reject_empty_unsafe_and_non_catalog_values() {
        let profile_id = "00000000-0000-0000-0000-000000000001".to_owned();
        let empty = ConfigurationOperation::CustomizationSet {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            changes: CustomizationChanges {
                layout_mode: None,
                control_scale: None,
                color_scheme: None,
                accent_style: None,
                shows_button_labels: None,
                background_edit: ConfigurationBackgroundEdit::Keep,
            },
        };
        assert_eq!(
            empty.validate_bridge_input(),
            Err(ConfigurationOperationError::EmptyChanges)
        );

        let invalid_color = ConfigurationOperation::CustomizationSet {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            changes: CustomizationChanges {
                layout_mode: None,
                control_scale: None,
                color_scheme: None,
                accent_style: None,
                shows_button_labels: None,
                background_edit: ConfigurationBackgroundEdit::Set {
                    scope: ConfigurationBackgroundScope::All,
                    color: ConfigurationRgbaColor {
                        red: 1.1,
                        green: 0.0,
                        blue: 0.0,
                        alpha: 1.0,
                    },
                },
            },
        };
        assert_eq!(
            invalid_color.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidColor)
        );

        let custom_frame = ConfigurationOperation::DeviceSet {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            frame_id: "custom-844x390-landscape".to_owned(),
        };
        assert_eq!(
            custom_frame.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidDeviceFrame)
        );
        assert!(is_supported_device_frame_id("iphone-16-pro-landscape"));
        assert!(!is_supported_device_frame_id("iphone-16-pro-sideways"));

        let duplicate_items = ConfigurationOperation::ControlBarSet {
            profile_id,
            variant: ConfigurationVariant::Primary,
            items: vec![
                ConfigurationControlBarItem::Settings,
                ConfigurationControlBarItem::Settings,
            ],
        };
        assert_eq!(
            duplicate_items.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidControlBar)
        );
    }

    #[test]
    fn control_bar_item_set_is_boxed_bounded_strict_and_spacer_safe() {
        let profile_id = "00000000-0000-0000-0000-000000000001".to_owned();
        let valid = ConfigurationOperation::ControlBarItemSet {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            item: ConfigurationControlBarItem::Settings,
            changes: Box::new(ControlBarItemChanges {
                width_scale: Some(1.5),
                height_scale: Some(1.2),
                shape: Some(ElementShape::Capsule),
                accent_style: Some(ConfigurationAccentStyle::Purple),
                fill: Some(ElementFill::Solid {
                    color: ConfigurationRgbaColor {
                        red: 0.1,
                        green: 0.2,
                        blue: 0.3,
                        alpha: 0.8,
                    },
                }),
                icon: Some(StyleIcon {
                    source: StyleIconSource::SfSymbol,
                    value: "gearshape.fill".to_owned(),
                }),
                haptic: Some(StyleHaptic {
                    style: Some(StyleHapticKind::Rigid),
                    pattern: Some(StyleHapticPattern::Double),
                    intensity: Some(0.7),
                    sharpness: Some(0.8),
                    duration: Some(0.09),
                }),
                ..ControlBarItemChanges::default()
            }),
        };
        assert_eq!(valid.validate_bridge_input(), Ok(()));
        assert!(valid.requires_bridge());

        let empty = ConfigurationOperation::ControlBarItemSet {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            item: ConfigurationControlBarItem::Settings,
            changes: Box::default(),
        };
        assert_eq!(
            empty.validate_bridge_input(),
            Err(ConfigurationOperationError::EmptyChanges)
        );
        let spacer = ConfigurationOperation::ControlBarItemSet {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            item: ConfigurationControlBarItem::Spacer,
            changes: Box::new(ControlBarItemChanges {
                width_scale: Some(2.0),
                is_hidden: Some(true),
                ..ControlBarItemChanges::default()
            }),
        };
        assert_eq!(spacer.validate_bridge_input(), Ok(()));
        let invalid_spacer = ConfigurationOperation::ControlBarItemSet {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            item: ConfigurationControlBarItem::Spacer,
            changes: Box::new(ControlBarItemChanges {
                height_scale: Some(1.1),
                ..ControlBarItemChanges::default()
            }),
        };
        assert_eq!(
            invalid_spacer.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidControlBar)
        );
        let invalid_number = ConfigurationOperation::ControlBarItemSet {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            item: ConfigurationControlBarItem::Settings,
            changes: Box::new(ControlBarItemChanges {
                width_scale: Some(f64::NAN),
                ..ControlBarItemChanges::default()
            }),
        };
        assert_eq!(
            invalid_number.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidGeometry)
        );

        for field in [
            "path",
            "assetID",
            "imageBytes",
            "rawJSON",
            "centerX",
            "rotationDegrees",
            "zIndex",
            "isLocationLocked",
            "hitInsets",
            "showsIntegratedLabel",
            "launchTarget",
            "keyCode",
        ] {
            let mut changes = serde_json::Map::new();
            changes.insert(field.to_owned(), serde_json::json!("injected"));
            let value = serde_json::json!({
                "type": "control-bar.item.set",
                "profileID": profile_id,
                "variant": "primary",
                "item": "settings",
                "changes": changes,
            });
            assert!(
                serde_json::from_value::<ConfigurationOperation>(value).is_err(),
                "{field}"
            );
        }
    }

    #[test]
    fn layer_operations_require_bounded_typed_destinations() {
        let profile_id = "00000000-0000-0000-0000-000000000001".to_owned();
        let valid = ConfigurationOperation::LayerMove {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            element_id: "00000000-0000-0000-0000-000000000105".to_owned(),
            destination: LayerMoveDestination::Before {
                element_id: "builtin.attack".to_owned(),
            },
        };
        assert_eq!(valid.validate_bridge_input(), Ok(()));

        let invalid_index = ConfigurationOperation::LayerMove {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            element_id: "builtin.jump".to_owned(),
            destination: LayerMoveDestination::Index { index: 513 },
        };
        assert_eq!(
            invalid_index.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidLayerDestination)
        );

        let invalid_reference = ConfigurationOperation::LayerMove {
            profile_id,
            variant: ConfigurationVariant::Primary,
            element_id: "builtin.jump".to_owned(),
            destination: LayerMoveDestination::After {
                element_id: "not allowed/selector".to_owned(),
            },
        };
        assert_eq!(
            invalid_reference.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidElementId)
        );
    }

    #[test]
    fn group_operations_require_typed_ids_names_and_unique_children() {
        let profile_id = "00000000-0000-0000-0000-000000000001".to_owned();
        let group_id = "00000000-0000-0000-0000-000000000701".to_owned();
        let valid = ConfigurationOperation::GroupCreate {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            group_id: group_id.clone(),
            name: "Actions".to_owned(),
            element_ids: vec!["builtin.jump".to_owned(), "builtin.attack".to_owned()],
        };
        assert_eq!(valid.validate_bridge_input(), Ok(()));

        let duplicate_child = ConfigurationOperation::GroupCreate {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            group_id: group_id.clone(),
            name: "Actions".to_owned(),
            element_ids: vec!["builtin.jump".to_owned(), "builtin.jump".to_owned()],
        };
        assert_eq!(
            duplicate_child.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidElementId)
        );
        let invalid_name = ConfigurationOperation::GroupRename {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            group_id: group_id.clone(),
            name: "  ".to_owned(),
        };
        assert_eq!(
            invalid_name.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidGroup)
        );

        let valid_nudge = ConfigurationOperation::GroupNudge {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            group_id: group_id.clone(),
            canvas_frame_id: "iphone-17-pro-portrait".to_owned(),
            delta_x: 10.0,
            delta_y: 0.0,
        };
        assert_eq!(valid_nudge.validate_bridge_input(), Ok(()));
        let custom_canvas_nudge = ConfigurationOperation::GroupNudge {
            profile_id,
            variant: ConfigurationVariant::Primary,
            group_id,
            canvas_frame_id: "custom-402x874-portrait".to_owned(),
            delta_x: 10.0,
            delta_y: 0.0,
        };
        assert_eq!(
            custom_canvas_nudge.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidDeviceFrame)
        );
    }

    #[test]
    fn style_operations_require_complete_bounded_typed_appearance() {
        let profile_id = "00000000-0000-0000-0000-000000000001".to_owned();
        let valid = ConfigurationOperation::StyleCreate {
            profile_id: profile_id.clone(),
            style_id: "agent-style".to_owned(),
            name: "Agent Style".to_owned(),
            appearance: Box::new(StyleAppearance {
                material_preset: Some(StyleMaterialPreset::SoftWhiteRaised),
                stroke_width: Some(12.0),
                pressed_scale: Some(0.5),
                icon: Some(StyleIcon {
                    source: StyleIconSource::Text,
                    value: "A".to_owned(),
                }),
                haptic: Some(StyleHaptic {
                    style: Some(StyleHapticKind::Rigid),
                    pattern: Some(StyleHapticPattern::Double),
                    intensity: Some(1.0),
                    sharpness: Some(0.0),
                    duration: Some(0.30),
                }),
                ..StyleAppearance::default()
            }),
        };
        assert_eq!(valid.validate_bridge_input(), Ok(()));
        assert_eq!(
            ConfigurationOperation::StyleDelete {
                profile_id: profile_id.clone(),
                style_id: "動作-élan".to_owned(),
            }
            .validate_bridge_input(),
            Ok(())
        );

        let empty = ConfigurationOperation::StyleCreate {
            profile_id: profile_id.clone(),
            style_id: "empty".to_owned(),
            name: "Empty".to_owned(),
            appearance: Box::default(),
        };
        assert_eq!(
            empty.validate_bridge_input(),
            Err(ConfigurationOperationError::EmptyChanges)
        );
        let invalid_id = ConfigurationOperation::StyleDelete {
            profile_id: profile_id.clone(),
            style_id: "../../secret".to_owned(),
        };
        assert_eq!(
            invalid_id.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidStyle)
        );
        let invalid_number = ConfigurationOperation::StyleCreate {
            profile_id,
            style_id: "invalid".to_owned(),
            name: "Invalid".to_owned(),
            appearance: Box::new(StyleAppearance {
                stroke_width: Some(12.01),
                ..StyleAppearance::default()
            }),
        };
        assert_eq!(
            invalid_number.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidStyle)
        );
    }

    #[test]
    fn generated_operations_require_exact_revisions_counts_and_unique_ids() {
        let destination = GeneratedProfileDestination::Create {
            new_profile_id: "00000000-0000-0000-0000-000000000801".to_owned(),
        };
        let valid = ConfigurationOperation::TemplateInstall {
            template: ControllerTemplate::Snes,
            template_revision: 2,
            destination: destination.clone(),
            name: None,
            new_element_ids: vec![
                "00000000-0000-0000-0000-000000000811".to_owned(),
                "00000000-0000-0000-0000-000000000812".to_owned(),
            ],
            select: false,
            make_default: false,
        };
        assert_eq!(valid.validate_bridge_input(), Ok(()));

        let wrong_revision = ConfigurationOperation::TemplateInstall {
            template: ControllerTemplate::Snes,
            template_revision: 1,
            destination: destination.clone(),
            name: None,
            new_element_ids: vec![
                "00000000-0000-0000-0000-000000000811".to_owned(),
                "00000000-0000-0000-0000-000000000812".to_owned(),
            ],
            select: false,
            make_default: false,
        };
        assert_eq!(
            wrong_revision.validate_bridge_input(),
            Err(ConfigurationOperationError::RevisionMismatch)
        );
        let wrong_count = ConfigurationOperation::TemplateInstall {
            template: ControllerTemplate::Snes,
            template_revision: 2,
            destination: destination.clone(),
            name: None,
            new_element_ids: Vec::new(),
            select: false,
            make_default: false,
        };
        assert_eq!(
            wrong_count.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidGeneratedElementIds)
        );
        let colliding = ConfigurationOperation::GenerationGenerate {
            preset: GenerationPreset::HollowKnight,
            preset_revision: 2,
            destination,
            new_element_ids: vec![
                "00000000-0000-0000-0000-000000000801".to_owned(),
                "00000000-0000-0000-0000-000000000821".to_owned(),
                "00000000-0000-0000-0000-000000000822".to_owned(),
                "00000000-0000-0000-0000-000000000823".to_owned(),
            ],
            select: true,
            make_default: false,
        };
        assert_eq!(
            colliding.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidGeneratedElementIds)
        );
    }

    #[test]
    fn element_add_accepts_all_six_kinds_and_rejects_passive_outputs() {
        let profile_id = document().active_profile_id;
        for (index, kind) in [
            ElementKind::Button,
            ElementKind::Joystick,
            ElementKind::Trigger,
            ElementKind::Trackpad,
            ElementKind::Text,
            ElementKind::Decoration,
        ]
        .into_iter()
        .enumerate()
        {
            let operation = ConfigurationOperation::ElementAdd {
                profile_id: profile_id.clone(),
                variant: ConfigurationVariant::Primary,
                element_id: format!("00000000-0000-0000-0000-0000000009{:02}", index + 1),
                kind,
                mapped_button: None,
                changes: Box::new(ElementChanges::default()),
            };
            assert_eq!(operation.validate_bridge_input(), Ok(()));
            assert!(operation.requires_bridge());
        }
        let passive = ConfigurationOperation::ElementAdd {
            profile_id,
            variant: ConfigurationVariant::Primary,
            element_id: "00000000-0000-0000-0000-0000000009F1".to_owned(),
            kind: ElementKind::Text,
            mapped_button: None,
            changes: Box::new(ElementChanges {
                output: Some(ElementOutputChanges {
                    part: ElementInputPart::Primary,
                    keyboard_edit: KeyboardOutputEdit::Clear,
                    gamepad_edit: GamepadOutputEdit::Keep,
                }),
                ..ElementChanges::default()
            }),
        };
        assert_eq!(
            passive.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidOutput)
        );
    }

    #[test]
    fn element_operations_reject_unknown_file_asset_path_and_raw_code_fields() {
        let profile_id = document().active_profile_id;
        for (field, value) in [
            ("path", serde_json::json!("/tmp/private")),
            ("assetID", serde_json::json!("private-art")),
            ("imageBytes", serde_json::json!("AAAA")),
            ("rawJSON", serde_json::json!("{}")),
            ("keyCode", serde_json::json!(49)),
            ("modifierMask", serde_json::json!(8)),
        ] {
            let mut changes = serde_json::Map::new();
            changes.insert(field.to_owned(), value);
            let value = serde_json::json!({
                "type": "element.add",
                "profileID": profile_id,
                "variant": "primary",
                "elementID": "00000000-0000-0000-0000-0000000009F2",
                "kind": "button",
                "changes": changes,
            });
            assert!(
                serde_json::from_value::<ConfigurationOperation>(value).is_err(),
                "{field}"
            );
        }
    }

    #[test]
    fn customization_fix_accepts_only_bounded_typed_canvas_sources() {
        let profile_id = document().active_profile_id;
        for canvas in [
            LayoutRepairCanvas::Stored {},
            LayoutRepairCanvas::Frame {
                frame_id: "iphone-17-pro-portrait".to_owned(),
            },
            LayoutRepairCanvas::Size {
                width: 600.0,
                height: 300.0,
            },
        ] {
            let operation = ConfigurationOperation::CustomizationFix {
                profile_id: profile_id.clone(),
                variant: ConfigurationVariant::Primary,
                target: Box::new(LayoutRepairTarget::Repair {
                    repair: LayoutRepairKind::MoveInsideSafeArea,
                }),
                canvas: Box::new(canvas),
                include_locked: false,
            };
            assert_eq!(operation.validate_bridge_input(), Ok(()));
            assert!(operation.requires_bridge());
        }
        for canvas in [
            LayoutRepairCanvas::Frame {
                frame_id: "custom-600x300-landscape".to_owned(),
            },
            LayoutRepairCanvas::Size {
                width: 239.0,
                height: 300.0,
            },
            LayoutRepairCanvas::Size {
                width: f64::INFINITY,
                height: 300.0,
            },
        ] {
            let operation = ConfigurationOperation::CustomizationFix {
                profile_id: profile_id.clone(),
                variant: ConfigurationVariant::Landscape,
                target: Box::new(LayoutRepairTarget::All {}),
                canvas: Box::new(canvas),
                include_locked: true,
            };
            assert!(operation.validate_bridge_input().is_err());
        }
    }

    #[test]
    fn customization_fix_rejects_unknown_path_asset_and_partial_size_fields() {
        let profile_id = document().active_profile_id;
        for invalid in [
            serde_json::json!({
                "type":"customization.fix", "profileID":profile_id, "variant":"primary",
                "target":{"kind":"all"}, "canvas":{"source":"stored", "path":"/tmp/x"},
                "includeLocked":false
            }),
            serde_json::json!({
                "type":"customization.fix", "profileID":profile_id, "variant":"primary",
                "target":{"kind":"repair", "repair":"auto-arrange", "assetID":"x"},
                "canvas":{"source":"stored"}, "includeLocked":false
            }),
            serde_json::json!({
                "type":"customization.fix", "profileID":profile_id, "variant":"primary",
                "target":{"kind":"all"}, "canvas":{"source":"size", "width":600},
                "includeLocked":false
            }),
        ] {
            assert!(
                serde_json::from_value::<ConfigurationOperation>(invalid.clone()).is_err(),
                "{invalid}"
            );
        }
    }

    #[test]
    fn invalid_geometry_and_numeric_key_names_fail_closed() {
        let document = document();
        let profile_id = document.active_profile_id.clone();
        let element_id = document.profiles[0]["customization"]["elements"][0]["id"]
            .as_str()
            .unwrap()
            .to_owned();
        let invalid = ConfigurationOperation::ElementSet {
            profile_id: profile_id.clone(),
            variant: ConfigurationVariant::Primary,
            element_id,
            changes: Box::new(ElementChanges {
                center_x: Some(2.0),
                ..ElementChanges::default()
            }),
        };
        assert_eq!(
            invalid.validate_bridge_input(),
            Err(ConfigurationOperationError::InvalidGeometry)
        );
        let raw_key = ConfigurationOperation::BindingSet {
            profile_id,
            button: GameButton::Jump,
            sequence: vec![SemanticKeyStroke {
                key: "36".to_owned(),
                modifiers: vec![],
            }],
        };
        assert_eq!(
            raw_key.validate_bridge_input(),
            Err(ConfigurationOperationError::UnsupportedSemanticKey)
        );
    }
}
