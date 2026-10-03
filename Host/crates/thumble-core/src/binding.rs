use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use thumble_protocol::GameButton;

/// One platform-neutral macOS virtual-key stroke.
///
/// `modifiers` is the spelling used by the existing `MacKeyStroke` JSON. The
/// alias accepts the direct shared-profile spelling, `modifiersRawValue`.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyStroke {
    pub key_code: u16,
    #[serde(rename = "modifiers", alias = "modifiersRawValue", default)]
    pub modifiers: u8,
}

impl KeyStroke {
    pub const fn new(key_code: u16, modifiers: u8) -> Self {
        Self {
            key_code,
            modifiers,
        }
    }
}

/// A held key chord or a sequence of key taps.
///
/// Both the legacy Mac binding shape and the shared profile output shape
/// deserialize into this type without changing their key-code or modifier bits.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyBinding {
    pub key_code: u16,
    #[serde(rename = "modifiers", alias = "modifiersRawValue", default)]
    pub modifiers: u8,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sequence: Option<Vec<KeyStroke>>,
}

impl KeyBinding {
    pub const fn new(key_code: u16, modifiers: u8) -> Self {
        Self {
            key_code,
            modifiers,
            sequence: None,
        }
    }

    pub fn from_strokes(strokes: Vec<KeyStroke>) -> Option<Self> {
        let first = strokes.first()?.clone();
        Some(Self {
            key_code: first.key_code,
            modifiers: first.modifiers,
            sequence: (strokes.len() > 1).then_some(strokes),
        })
    }

    pub fn strokes(&self) -> Vec<KeyStroke> {
        match self
            .sequence
            .as_ref()
            .filter(|sequence| !sequence.is_empty())
        {
            Some(sequence) => sequence.clone(),
            None => vec![KeyStroke::new(self.key_code, self.modifiers)],
        }
    }

    pub fn is_sequence(&self) -> bool {
        self.sequence
            .as_ref()
            .is_some_and(|sequence| sequence.len() > 1)
    }

    pub(crate) fn canonical_held_binding(&self) -> Self {
        let stroke = self
            .sequence
            .as_ref()
            .and_then(|sequence| sequence.first())
            .cloned()
            .unwrap_or_else(|| KeyStroke::new(self.key_code, self.modifiers));
        Self::new(stroke.key_code, stroke.modifiers)
    }
}

/// The lossless portable subset of `MacControlOutputBinding` and
/// `KeypadElementOutputBinding`.
///
/// Gamepad button names remain lossless strings for forward compatibility.
/// Execution uses only supported typed buttons.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct OutputBinding {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keyboard: Option<KeyBinding>,
    #[serde(default)]
    pub gamepad_buttons: BTreeSet<String>,
}

impl OutputBinding {
    pub fn supported_gamepad_buttons(
        &self,
    ) -> impl Iterator<Item = crate::VirtualGamepadButton> + '_ {
        self.gamepad_buttons
            .iter()
            .filter_map(|name| crate::VirtualGamepadButton::from_name(name))
    }

    pub fn keyboard(binding: KeyBinding) -> Self {
        Self {
            keyboard: Some(binding),
            gamepad_buttons: BTreeSet::new(),
        }
    }
}

/// A deterministically serialized map whose public operations use the protocol
/// `GameButton` enum while retaining unknown future string keys on round trips.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct ButtonBindings<T>(BTreeMap<String, T>);

impl<T> Default for ButtonBindings<T> {
    fn default() -> Self {
        Self(BTreeMap::new())
    }
}

impl<T> ButtonBindings<T> {
    pub fn insert(&mut self, button: GameButton, value: T) -> Option<T> {
        self.0.insert(button_name(button).to_owned(), value)
    }

    pub fn insert_raw(&mut self, button: impl Into<String>, value: T) -> Option<T> {
        self.0.insert(button.into(), value)
    }

    pub fn get(&self, button: &GameButton) -> Option<&T> {
        self.0.get(button_name(*button))
    }

    pub fn remove(&mut self, button: GameButton) -> Option<T> {
        self.0.remove(button_name(button))
    }

    pub fn get_raw(&self, button: &str) -> Option<&T> {
        self.0.get(button)
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &T)> {
        self.0.iter().map(|(key, value)| (key.as_str(), value))
    }
}

pub(crate) const fn button_name(button: GameButton) -> &'static str {
    match button {
        GameButton::Up => "up",
        GameButton::Down => "down",
        GameButton::Left => "left",
        GameButton::Right => "right",
        GameButton::Jump => "jump",
        GameButton::Attack => "attack",
        GameButton::Dash => "dash",
        GameButton::Focus => "focus",
        GameButton::Map => "map",
        GameButton::Pause => "pause",
        GameButton::Custom1 => "custom1",
        GameButton::Custom2 => "custom2",
        GameButton::Custom3 => "custom3",
        GameButton::Custom4 => "custom4",
        GameButton::Custom5 => "custom5",
        GameButton::Custom6 => "custom6",
        GameButton::Custom7 => "custom7",
        GameButton::Custom8 => "custom8",
    }
}
