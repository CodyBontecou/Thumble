use crate::state::ids_equal;
use crate::{OutputBinding, PersistentState};
use serde_json::Value;
use std::collections::BTreeMap;
use thumble_protocol::{KeypadElementID, KeypadElementInputPart};

impl PersistentState {
    /// Refresh presentation mirrors from the selected profile, never from the
    /// previously selected setup. Keep outputs unfiltered; modes gate use.
    pub(crate) fn refresh_global_binding_mirrors(&mut self) {
        let outputs = self.active_primary_binding_mirrors();
        self.key_bindings = keyboard_projection(&outputs);
        self.output_bindings = outputs;
    }

    /// An explicit customization replacement may remove controls. Reconcile
    /// only its target maps; imported/persisted orphan maps still reject.
    pub(crate) fn reconcile_active_profile_binding_maps(&mut self) {
        let outputs = self.active_primary_binding_mirrors();
        let keys = keyboard_projection(&outputs);
        replace_profile_map(
            &mut self.profile_key_bindings,
            &self.active_profile_id,
            keys.clone(),
        );
        replace_profile_map(
            &mut self.profile_output_bindings,
            &self.active_profile_id,
            outputs.clone(),
        );
        self.key_bindings = keys;
        self.output_bindings = outputs;
    }

    fn active_primary_binding_mirrors(&self) -> crate::ButtonBindings<OutputBinding> {
        self.resolved_profile_output_bindings(&self.active_profile_id)
            .unwrap_or_default()
    }

    /// An effective, unfiltered projection of one validated profile. Reads and
    /// presentation honor owned defaults/configurations and explicit clears.
    pub fn resolved_profile_output_bindings(
        &self,
        profile_id: &str,
    ) -> Option<crate::ButtonBindings<OutputBinding>> {
        let profile = self.profile(profile_id)?;
        Some(profile_primary_binding_mirrors(
            profile,
            profile_bindings(&self.profile_key_bindings, profile_id),
            profile_bindings(&self.profile_output_bindings, profile_id),
        ))
    }

    pub fn resolve_button_output(&self, id: KeypadElementID) -> Option<OutputBinding> {
        self.resolve_element_output(&id.to_string(), KeypadElementInputPart::Primary)
    }

    /// Only actual elements in the active profile can produce input. A binding
    /// never comes from another element, a slot, or the previously active setup.
    pub fn resolve_element_output(
        &self,
        element_id: &str,
        part: KeypadElementInputPart,
    ) -> Option<OutputBinding> {
        let id = KeypadElementID::parse(element_id)?;
        let profile = self.active_profile()?;
        let mut exists = false;
        for name in [
            "customization",
            "landscapeCustomization",
            "portraitCustomization",
        ] {
            let Some(elements) = profile
                .get(name)
                .and_then(|c| c.get("elements"))
                .and_then(Value::as_array)
            else {
                continue;
            };
            for element in elements {
                if element
                    .get("id")
                    .and_then(Value::as_str)
                    .is_none_or(|candidate| !ids_equal(candidate, element_id))
                {
                    continue;
                }
                exists = true;
                if let Some(binding) = direct_output(element, part) {
                    return Some(self.filter_output_mode(parse_output_binding(binding)));
                }
            }
        }
        if !exists || part != KeypadElementInputPart::Primary {
            return None;
        }
        let output = profile_bindings(&self.profile_output_bindings, &self.active_profile_id)
            .and_then(|bindings| bindings.get(&id))
            .cloned()
            .or_else(|| {
                profile_bindings(&self.profile_key_bindings, &self.active_profile_id)
                    .and_then(|bindings| bindings.get(&id))
                    .cloned()
                    .map(OutputBinding::keyboard)
            });
        output.map(|output| self.filter_output_mode(output))
    }

    pub(crate) fn filter_output_mode(&self, mut output: OutputBinding) -> OutputBinding {
        let mode = self
            .active_profile()
            .and_then(|profile| profile.get("outputMode"))
            .and_then(Value::as_str)
            .unwrap_or("keyboard");
        match mode {
            "keyboard" => output.gamepad_buttons.clear(),
            "controller" => output.keyboard = None,
            _ => {}
        }
        output
    }
}

pub(crate) fn profile_primary_binding_mirrors(
    profile: &Value,
    keys: Option<&crate::ButtonBindings<crate::KeyBinding>>,
    bindings: Option<&crate::ButtonBindings<OutputBinding>>,
) -> crate::ButtonBindings<OutputBinding> {
    let mut outputs = crate::ButtonBindings::default();
    let declared = crate::configuration::declared_element_ids(profile);
    if let Some(bindings) = bindings {
        for (id, output) in bindings.iter_ids().filter(|(id, _)| declared.contains(id)) {
            outputs.insert(id, output.clone());
        }
    }
    if let Some(keys) = keys {
        for (id, keyboard) in keys.iter_ids().filter(|(id, _)| declared.contains(id)) {
            if outputs.get(&id).is_none() {
                outputs.insert(id, OutputBinding::keyboard(keyboard.clone()));
            }
        }
    }
    for (id, output) in crate::profile_owned_outputs(profile).iter_ids() {
        outputs.insert(id, output.clone());
    }
    outputs
}

pub(crate) fn keyboard_projection(
    outputs: &crate::ButtonBindings<OutputBinding>,
) -> crate::ButtonBindings<crate::KeyBinding> {
    let mut keys = crate::ButtonBindings::default();
    for (id, output) in outputs.iter_ids() {
        if let Some(keyboard) = &output.keyboard {
            keys.insert(id, keyboard.clone());
        }
    }
    keys
}

fn replace_profile_map<T>(maps: &mut BTreeMap<String, T>, profile: &str, bindings: T) {
    let key = maps
        .keys()
        .find(|id| ids_equal(id, profile))
        .cloned()
        .unwrap_or_else(|| profile.to_owned());
    maps.insert(key, bindings);
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
        return element
            .get("output")
            .filter(|value| !value.is_null())
            .or_else(|| {
                element
                    .get("defaultOutput")
                    .filter(|value| !value.is_null())
            });
    }
    let key = element_part_name(part);
    let explicit = element
        .get("partOutputs")
        .and_then(|outputs| match outputs {
            Value::Object(map) => map.get(key).filter(|value| !value.is_null()),
            Value::Array(entries) => entries.chunks_exact(2).find_map(|entry| {
                (entry[0].as_str() == Some(key) && !entry[1].is_null()).then_some(&entry[1])
            }),
            _ => None,
        });
    if explicit.is_some() {
        return explicit;
    }
    let direction = match part {
        KeypadElementInputPart::JoystickUp => "up",
        KeypadElementInputPart::JoystickDown => "down",
        KeypadElementInputPart::JoystickLeft => "left",
        KeypadElementInputPart::JoystickRight => "right",
        _ => return None,
    };
    element
        .get("joystickMapping")
        .and_then(|mapping| mapping.get(direction))
        .filter(|value| !value.is_null())
}

fn parse_output_binding(value: &Value) -> OutputBinding {
    if value.get("keyCode").is_some() {
        return serde_json::from_value(value.clone())
            .map(OutputBinding::keyboard)
            .unwrap_or_default();
    }
    serde_json::from_value(value.clone()).unwrap_or_default()
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
