use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use thumble_protocol::KeypadElementID;

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
/// Execution uses only supported typed buttons. Portable artifacts retain
/// unknown metadata in their raw maps; the execution projection ignores it.
/// Identity/routing validation is performed independently by the element schema.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct OutputBinding {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub keyboard: Option<KeyBinding>,
    #[serde(default)]
    pub gamepad_buttons: BTreeSet<String>,
}

impl OutputBinding {
    /// Shared-profile spelling used by Swift's element-owned bindings.
    pub fn element_value(&self) -> serde_json::Value {
        let mut output = serde_json::json!({"gamepadButtons": self.gamepad_buttons});
        if let Some(binding) = &self.keyboard {
            let mut keyboard = serde_json::json!({"keyCode": binding.key_code, "modifiersRawValue": binding.modifiers});
            if let Some(strokes) = &binding.sequence {
                keyboard["sequence"] = serde_json::Value::Array(strokes.iter().map(|stroke|
                    serde_json::json!({"keyCode": stroke.key_code, "modifiersRawValue": stroke.modifiers})
                ).collect());
            }
            output["keyboard"] = keyboard;
        }
        output
    }

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

/// Deterministically serialized bindings keyed by actual element UUIDs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(transparent)]
pub struct ButtonBindings<T>(BTreeMap<String, T>);

impl<'de, T: Deserialize<'de>> Deserialize<'de> for ButtonBindings<T> {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = BTreeMap::<String, T>::deserialize(deserializer)?;
        let mut bindings = BTreeMap::new();
        for (key, value) in raw {
            let id = KeypadElementID::parse(&key).ok_or_else(|| serde::de::Error::custom("binding keys must be element UUIDs; named slots are no longer supported"))?;
            if bindings.insert(id.to_string(), value).is_some() {
                return Err(serde::de::Error::custom("duplicate element UUID in binding map"));
            }
        }
        Ok(Self(bindings))
    }
}

impl<T> Default for ButtonBindings<T> {
    fn default() -> Self {
        Self(BTreeMap::new())
    }
}

impl<T> ButtonBindings<T> {
    pub fn insert(&mut self, button: KeypadElementID, value: T) -> Option<T> {
        self.0.insert(button.to_string(), value)
    }

    pub fn get(&self, button: &KeypadElementID) -> Option<&T> {
        self.0.get(&button.to_string())
    }

    pub fn remove(&mut self, button: KeypadElementID) -> Option<T> {
        self.0.remove(&button.to_string())
    }

    pub fn get_raw(&self, button: &str) -> Option<&T> {
        self.0.get(&KeypadElementID::parse(button)?.to_string())
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

    pub fn iter_ids(&self) -> impl Iterator<Item = (KeypadElementID, &T)> {
        self.0.iter().map(|(key, value)| {
            (KeypadElementID::parse(key).expect("binding keys are validated UUIDs"), value)
        })
    }
}

pub(crate) fn button_name(button: KeypadElementID) -> String { button.to_string() }
