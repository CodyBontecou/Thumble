use crate::state::ids_equal;
use crate::{OutputBinding, PersistentState};
use serde_json::Value;
use std::collections::BTreeMap;
use thumble_protocol::{GameButton, KeypadElementInputPart};

impl PersistentState {
    /// Resolve the active profile's output map, overlaying profile-specific maps
    /// on the portable global fallback maps.
    pub fn resolve_button_output(&self, button: GameButton) -> Option<OutputBinding> {
        resolve_legacy_button(self, button).map(|output| self.filter_output_mode(output))
    }

    /// Resolve an element from any of the active profile's primary, landscape,
    /// or portrait customizations. A direct `output`/`partOutputs` entry wins
    /// over every legacy mapping, including a legacy mapping found earlier.
    pub fn resolve_element_output(
        &self,
        element_id: &str,
        part: KeypadElementInputPart,
    ) -> Option<OutputBinding> {
        let profile = self.active_profile()?;
        let mut legacy_button = None;

        for customization_name in [
            "customization",
            "landscapeCustomization",
            "portraitCustomization",
        ] {
            let Some(customization) = profile.get(customization_name) else {
                continue;
            };
            let Some(elements) = customization.get("elements").and_then(Value::as_array) else {
                continue;
            };

            for element in elements {
                let Some(candidate_id) = element.get("id").and_then(Value::as_str) else {
                    continue;
                };
                if !ids_equal(candidate_id, element_id) {
                    continue;
                }

                if let Some(direct) = direct_output(element, part) {
                    return Some(self.filter_output_mode(parse_output_binding(direct)));
                }
                if legacy_button.is_none() {
                    legacy_button = legacy_button_for_part(element, part);
                }
            }
        }

        legacy_button.and_then(|button| self.resolve_button_output(button))
    }

    pub(crate) fn filter_output_mode(&self, mut output: OutputBinding) -> OutputBinding {
        if self.gamepad_output_disabled() {
            output.gamepad_buttons.clear();
        }
        output
    }
}

fn resolve_legacy_button(state: &PersistentState, button: GameButton) -> Option<OutputBinding> {
    if let Some(binding) =
        profile_bindings(&state.profile_output_bindings, &state.active_profile_id)
            .and_then(|bindings| bindings.get(&button))
    {
        return Some(binding.clone());
    }
    if let Some(binding) = profile_bindings(&state.profile_key_bindings, &state.active_profile_id)
        .and_then(|bindings| bindings.get(&button))
    {
        return Some(OutputBinding::keyboard(binding.clone()));
    }
    if let Some(binding) = state.output_bindings.get(&button) {
        return Some(binding.clone());
    }
    state
        .key_bindings
        .get(&button)
        .cloned()
        .map(OutputBinding::keyboard)
}

fn profile_bindings<'a, T>(profiles: &'a BTreeMap<String, T>, profile_id: &str) -> Option<&'a T> {
    profiles.get(profile_id).or_else(|| {
        profiles
            .iter()
            .find_map(|(candidate, bindings)| ids_equal(candidate, profile_id).then_some(bindings))
    })
}

fn direct_output(element: &Value, part: KeypadElementInputPart) -> Option<&Value> {
    if part == KeypadElementInputPart::Primary {
        return element.get("output").filter(|value| !value.is_null());
    }

    let outputs = element.get("partOutputs")?;
    let key = element_part_name(part);
    match outputs {
        Value::Object(map) => map.get(key).filter(|value| !value.is_null()),
        Value::Array(entries) => entries.chunks_exact(2).find_map(|entry| {
            (entry[0].as_str() == Some(key) && !entry[1].is_null()).then_some(&entry[1])
        }),
        _ => None,
    }
}

fn parse_output_binding(value: &Value) -> OutputBinding {
    if value.get("keyCode").is_some() {
        return serde_json::from_value(value.clone())
            .map(OutputBinding::keyboard)
            .unwrap_or_default();
    }
    serde_json::from_value(value.clone()).unwrap_or_default()
}

fn legacy_button_for_part(element: &Value, part: KeypadElementInputPart) -> Option<GameButton> {
    let raw = match part {
        KeypadElementInputPart::Primary | KeypadElementInputPart::TriggerDigital => {
            element.get("legacySlot")
        }
        KeypadElementInputPart::JoystickUp => element.get("joystickMapping")?.get("up"),
        KeypadElementInputPart::JoystickDown => element.get("joystickMapping")?.get("down"),
        KeypadElementInputPart::JoystickLeft => element.get("joystickMapping")?.get("left"),
        KeypadElementInputPart::JoystickRight => element.get("joystickMapping")?.get("right"),
    }?;
    serde_json::from_value(raw.clone()).ok()
}

pub(crate) const fn element_part_name(part: KeypadElementInputPart) -> &'static str {
    match part {
        KeypadElementInputPart::Primary => "primary",
        KeypadElementInputPart::JoystickUp => "joystick_up",
        KeypadElementInputPart::JoystickDown => "joystick_down",
        KeypadElementInputPart::JoystickLeft => "joystick_left",
        KeypadElementInputPart::JoystickRight => "joystick_right",
        KeypadElementInputPart::TriggerDigital => "trigger_digital",
    }
}
