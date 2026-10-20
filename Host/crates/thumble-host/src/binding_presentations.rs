//! Display-only vocabulary mirrors Sources/Shared/KeypadBindingPresentation.swift.
//! Resolution is shared with CLI binding display; these strings never route input.
use crate::cli_profile::{
    orientation_customization, profile_output_mode, raw_binding_display_entries,
};
use crate::draft_operation::OrientationVariant;
use serde_json::{json, Value};
use thumble_core::{OutputBinding, PersistentState};

pub(crate) fn snapshot(state: &PersistentState) -> Vec<Value> {
    let mut groups = Vec::new();
    for profile in &state.profiles {
        let Some(id) = profile.get("id").and_then(Value::as_str) else {
            continue;
        };
        let Some(outputs) = state.resolved_profile_output_bindings(id) else {
            continue;
        };
        let Ok(mode) = profile_output_mode(profile) else {
            continue;
        };
        let mut variants = Vec::new();
        for orientation in [OrientationVariant::Landscape, OrientationVariant::Portrait] {
            let entries=orientation_customization(profile,orientation)
                .and_then(|customization| raw_binding_display_entries(customization,&outputs,mode))
                .map(|entries| entries.into_iter().filter_map(|entry| {
                    let (compact,accessible)=format_output(&entry.output)?;
                    Some(json!({"input":{"elementID":entry.element_id,"part":entry.part},"compactText":compact,"accessibilityText":accessible}))
                }).collect::<Vec<_>>()).unwrap_or_default();
            variants.push(entries);
        }
        if variants[0] == variants[1] {
            groups.push(json!({"profileID":id,"entries":variants[0]}));
        } else {
            groups.push(json!({"profileID":id,"orientation":"landscape","entries":variants[0]}));
            groups.push(json!({"profileID":id,"orientation":"portrait","entries":variants[1]}));
        }
    }
    groups
}

fn format_output(output: &OutputBinding) -> Option<(String, String)> {
    let mut compact = Vec::new();
    let mut accessible = Vec::new();
    if let Some(keyboard) = &output.keyboard {
        let mut compact_strokes = Vec::new();
        let mut accessible_strokes = Vec::new();
        for stroke in keyboard.strokes() {
            let (key, spoken) = key_name(stroke.key_code);
            let mut symbols = String::new();
            let mut words = Vec::new();
            for (bit, symbol, name) in [
                (8, "⌃", "Control"),
                (4, "⌥", "Option"),
                (2, "⇧", "Shift"),
                (1, "⌘", "Command"),
            ] {
                if stroke.modifiers & bit != 0 {
                    symbols.push_str(symbol);
                    words.push(name.to_owned());
                }
            }
            symbols.push_str(&key);
            words.push(spoken);
            compact_strokes.push(symbols);
            accessible_strokes.push(words.join(" "));
        }
        compact.push(compact_strokes.join(" › "));
        accessible.push(accessible_strokes.join(", then "));
    }
    // Declaration order matches VirtualGamepadButton.allCases in the shared model.
    for (name, short, spoken) in GAMEPAD_NAMES {
        if output.gamepad_buttons.contains(*name) {
            compact.push((*short).to_owned());
            accessible.push((*spoken).to_owned());
        }
    }
    (!compact.is_empty()).then(|| (compact.join(" + "), accessible.join(" plus ")))
}
const GAMEPAD_NAMES: &[(&str, &str, &str)] = &[
    ("south", "A", "South / A / Cross"),
    ("east", "B", "East / B / Circle"),
    ("west", "X", "West / X / Square"),
    ("north", "Y", "North / Y / Triangle"),
    ("leftShoulder", "L1", "Left Shoulder / L1"),
    ("rightShoulder", "R1", "Right Shoulder / R1"),
    ("leftTriggerButton", "L2", "Left Trigger Button / L2"),
    ("rightTriggerButton", "R2", "Right Trigger Button / R2"),
    ("select", "Select", "Select / Back"),
    ("start", "Start", "Start / Menu"),
    ("home", "Home", "Home / Guide"),
    ("leftStickPress", "L3", "Left Stick Press"),
    ("rightStickPress", "R3", "Right Stick Press"),
    ("dpadUp", "D↑", "D-pad Up"),
    ("dpadDown", "D↓", "D-pad Down"),
    ("dpadLeft", "D←", "D-pad Left"),
    ("dpadRight", "D→", "D-pad Right"),
];
fn key_name(code: u16) -> (String, String) {
    let (compact, accessible) = match code {
        36 => ("Return", "Return"),
        48 => ("Tab", "Tab"),
        49 => ("Space", "Space"),
        51 => ("Delete", "Delete"),
        53 => ("Esc", "Escape"),
        54 => ("⌘", "Right Command"),
        55 => ("⌘", "Command"),
        56 => ("⇧", "Shift"),
        57 => ("Caps", "Caps Lock"),
        58 => ("⌥", "Option"),
        59 => ("⌃", "Control"),
        60 => ("⇧", "Right Shift"),
        61 => ("⌥", "Right Option"),
        62 => ("⌃", "Right Control"),
        63 => ("Fn", "Function"),
        71 => ("Clear", "Clear"),
        76 => ("⌤", "Keypad Enter"),
        114 => ("Help", "Help"),
        115 => ("Home", "Home"),
        116 => ("PgUp", "Page Up"),
        117 => ("⌦", "Forward Delete"),
        119 => ("End", "End"),
        121 => ("PgDn", "Page Down"),
        123 => ("←", "Left Arrow"),
        124 => ("→", "Right Arrow"),
        125 => ("↓", "Down Arrow"),
        126 => ("↑", "Up Arrow"),
        0 => ("A", "A"),
        1 => ("S", "S"),
        2 => ("D", "D"),
        3 => ("F", "F"),
        4 => ("H", "H"),
        5 => ("G", "G"),
        6 => ("Z", "Z"),
        7 => ("X", "X"),
        8 => ("C", "C"),
        9 => ("V", "V"),
        11 => ("B", "B"),
        12 => ("Q", "Q"),
        13 => ("W", "W"),
        14 => ("E", "E"),
        15 => ("R", "R"),
        16 => ("Y", "Y"),
        17 => ("T", "T"),
        18 => ("1", "1"),
        19 => ("2", "2"),
        20 => ("3", "3"),
        21 => ("4", "4"),
        22 => ("6", "6"),
        23 => ("5", "5"),
        24 => ("=", "="),
        25 => ("9", "9"),
        26 => ("7", "7"),
        27 => ("-", "-"),
        28 => ("8", "8"),
        29 => ("0", "0"),
        30 => ("]", "]"),
        31 => ("O", "O"),
        32 => ("U", "U"),
        33 => ("[", "["),
        34 => ("I", "I"),
        35 => ("P", "P"),
        37 => ("L", "L"),
        38 => ("J", "J"),
        39 => ("'", "'"),
        40 => ("K", "K"),
        41 => (";", ";"),
        42 => ("\\", "\\"),
        43 => (",", ","),
        44 => ("/", "/"),
        45 => ("N", "N"),
        46 => ("M", "M"),
        47 => (".", "."),
        50 => ("`", "`"),
        64 => ("F17", "F17"),
        65 => ("Keypad .", "Keypad ."),
        67 => ("Keypad *", "Keypad *"),
        69 => ("Keypad +", "Keypad +"),
        75 => ("Keypad /", "Keypad /"),
        78 => ("Keypad -", "Keypad -"),
        81 => ("Keypad =", "Keypad ="),
        82 => ("Keypad 0", "Keypad 0"),
        83 => ("Keypad 1", "Keypad 1"),
        84 => ("Keypad 2", "Keypad 2"),
        85 => ("Keypad 3", "Keypad 3"),
        86 => ("Keypad 4", "Keypad 4"),
        87 => ("Keypad 5", "Keypad 5"),
        88 => ("Keypad 6", "Keypad 6"),
        89 => ("Keypad 7", "Keypad 7"),
        91 => ("Keypad 8", "Keypad 8"),
        92 => ("Keypad 9", "Keypad 9"),
        96 => ("F5", "F5"),
        97 => ("F6", "F6"),
        98 => ("F7", "F7"),
        99 => ("F3", "F3"),
        100 => ("F8", "F8"),
        101 => ("F9", "F9"),
        103 => ("F11", "F11"),
        105 => ("F13", "F13"),
        106 => ("F16", "F16"),
        107 => ("F14", "F14"),
        109 => ("F10", "F10"),
        111 => ("F12", "F12"),
        113 => ("F15", "F15"),
        118 => ("F4", "F4"),
        120 => ("F2", "F2"),
        122 => ("F1", "F1"),
        _ => return (format!("Key {code}"), format!("Key {code}")),
    };
    (compact.to_owned(), accessible.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use thumble_core::{KeyBinding, KeyStroke};
    #[test]
    fn native_vocabulary_preserves_modifier_sequence_gamepad_order_and_unknown_keys() {
        let output = OutputBinding {
            keyboard: KeyBinding::from_strokes(vec![
                KeyStroke::new(36, 15),
                KeyStroke::new(65535, 0),
            ]),
            gamepad_buttons: ["dpadUp", "south", "rightShoulder"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
        };
        assert_eq!(format_output(&output),Some(("⌃⌥⇧⌘Return › Key 65535 + A + R1 + D↑".into(),
            "Control Option Shift Command Return, then Key 65535 plus South / A / Cross plus Right Shoulder / R1 plus D-pad Up".into())));
        assert_eq!(format_output(&OutputBinding::default()), None);
    }
    fn state() -> PersistentState {
        let mut state = PersistentState::minimal("binding-test").unwrap();
        state.profiles = vec![
            json!({"id":"00000000-0000-0000-0000-000000000201","name":"Bindings","outputMode":"custom",
            "customization":{"elements":[
                {"id":"417A9EB2-0D3E-4F64-86EE-34A761075061","kind":"button","label":"Unrelated label"},
                {"id":"417A9EB2-0D3E-4F64-86EE-34A761075062","kind":"joystick","joystickMapping":{"up":{"keyboard":{"keyCode":13,"modifiersRawValue":0}}},
                    "partOutputs":["joystick_up",{},"joystick_right",{"keyboard":{"keyCode":2,"modifiersRawValue":0}}]},
                {"id":"417A9EB2-0D3E-4F64-86EE-34A761075063","kind":"trigger","partOutputs":["trigger_digital",{"gamepadButtons":["south"]}]},
                {"id":"417A9EB2-0D3E-4F64-86EE-34A761075064","kind":"text","output":{"keyboard":{"keyCode":49}}}
            ]}}),
        ];
        state.profile_output_bindings.clear();
        state.profile_key_bindings.clear();
        state.profile_output_bindings.insert("00000000-0000-0000-0000-000000000201".into(),serde_json::from_value(json!({"417A9EB2-0D3E-4F64-86EE-34A761075061":{"keyboard":{"keyCode":48,"modifiers":1}}})).unwrap());
        state
    }
    #[test]
    fn profile_snapshot_resolves_authoritative_outputs_parts_empty_overrides_and_modes() {
        let mut state = state();
        let before = state.clone();
        let groups = snapshot(&state);
        assert_eq!(groups.len(), 1);
        let entries = groups[0]["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 3);
        assert_eq!(entries[0]["compactText"], "⌘Tab");
        assert_eq!(entries[1]["input"]["part"], "joystick_right");
        assert_eq!(entries[1]["compactText"], "D");
        assert_eq!(entries[2]["compactText"], "A");
        assert_eq!(
            serde_json::to_value(&state).unwrap(),
            serde_json::to_value(&before).unwrap()
        );
        state.profiles[0]["outputMode"] = json!("controller");
        assert_eq!(snapshot(&state)[0]["entries"].as_array().unwrap().len(), 1);
        state.profiles[0]["outputMode"] = json!("keyboard");
        assert_eq!(snapshot(&state)[0]["entries"].as_array().unwrap().len(), 2);
    }
    #[test]
    fn orientation_groups_keep_explicit_empty_variant_and_raw_unknown_numeric_keys() {
        let mut state = state();
        state.profiles[0]["portraitCustomization"] = json!({"elements":[]});
        state.profiles[0]["customization"]["elements"][0]["output"] =
            json!({"keyboard":{"keyCode":65535,"modifiersRawValue":0}});
        let groups = snapshot(&state);
        assert_eq!(groups.len(), 2);
        assert_eq!(groups[0]["orientation"], "landscape");
        assert_eq!(groups[0]["entries"][0]["compactText"], "Key 65535");
        assert_eq!(groups[1]["orientation"], "portrait");
        assert_eq!(groups[1]["entries"], json!([]));
    }
    #[test]
    fn legacy_joystick_mapping_only_fills_missing_parts() {
        let mut state = state();
        state.profiles[0]["customization"]["elements"][1]["partOutputs"] = json!([]);
        let groups = snapshot(&state);
        assert!(groups[0]["entries"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["input"]["part"] == "joystick_up" && entry["compactText"] == "W"));
    }
}
