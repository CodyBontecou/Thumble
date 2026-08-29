/// Canonical macOS virtual-key codes and the semantic names used by the host protocol.
const SEMANTIC_KEYS: &[(u16, &str)] = &[
    (0, "A"),
    (1, "S"),
    (2, "D"),
    (3, "F"),
    (4, "H"),
    (5, "G"),
    (6, "Z"),
    (7, "X"),
    (8, "C"),
    (9, "V"),
    (11, "B"),
    (12, "Q"),
    (13, "W"),
    (14, "E"),
    (15, "R"),
    (16, "Y"),
    (17, "T"),
    (18, "1"),
    (19, "2"),
    (20, "3"),
    (21, "4"),
    (22, "6"),
    (23, "5"),
    (24, "="),
    (25, "9"),
    (26, "7"),
    (27, "-"),
    (28, "8"),
    (29, "0"),
    (30, "]"),
    (31, "O"),
    (32, "U"),
    (33, "["),
    (34, "I"),
    (35, "P"),
    (36, "Return"),
    (37, "L"),
    (38, "J"),
    (39, "'"),
    (40, "K"),
    (41, ";"),
    (42, "\\"),
    (43, ","),
    (44, "/"),
    (45, "N"),
    (46, "M"),
    (47, "."),
    (48, "Tab"),
    (49, "Space"),
    (50, "`"),
    (51, "Delete"),
    (53, "Esc"),
    (54, "Right Command"),
    (55, "Command"),
    (56, "Shift"),
    (57, "Caps Lock"),
    (58, "Option"),
    (59, "Control"),
    (60, "Right Shift"),
    (61, "Right Option"),
    (62, "Right Control"),
    (63, "Fn"),
    (64, "F17"),
    (65, "Keypad ."),
    (67, "Keypad *"),
    (69, "Keypad +"),
    (71, "Clear"),
    (75, "Keypad /"),
    (76, "Keypad Enter"),
    (78, "Keypad -"),
    (81, "Keypad ="),
    (82, "Keypad 0"),
    (83, "Keypad 1"),
    (84, "Keypad 2"),
    (85, "Keypad 3"),
    (86, "Keypad 4"),
    (87, "Keypad 5"),
    (88, "Keypad 6"),
    (89, "Keypad 7"),
    (91, "Keypad 8"),
    (92, "Keypad 9"),
    (96, "F5"),
    (97, "F6"),
    (98, "F7"),
    (99, "F3"),
    (100, "F8"),
    (101, "F9"),
    (103, "F11"),
    (105, "F13"),
    (106, "F16"),
    (107, "F14"),
    (109, "F10"),
    (111, "F12"),
    (113, "F15"),
    (114, "Help"),
    (115, "Home"),
    (116, "PageUp"),
    (117, "ForwardDelete"),
    (118, "F4"),
    (119, "End"),
    (120, "F2"),
    (121, "PageDown"),
    (122, "F1"),
    (123, "LeftArrow"),
    (124, "RightArrow"),
    (125, "DownArrow"),
    (126, "UpArrow"),
];

/// Resolves the strict, case-sensitive semantic key vocabulary accepted by typed
/// configuration operations.
pub fn semantic_key_code(key: &str) -> Option<u16> {
    let key = key.trim();
    let alias = match key {
        "←" => Some(123),
        "→" => Some(124),
        "↓" => Some(125),
        "↑" => Some(126),
        "Escape" => Some(53),
        "Backspace" => Some(51),
        "Forward Delete" => Some(117),
        "Page Up" => Some(116),
        "Page Down" => Some(121),
        _ => None,
    };
    alias.or_else(|| {
        SEMANTIC_KEYS
            .iter()
            .find_map(|(code, name)| (*name == key).then_some(*code))
    })
}

/// Returns the canonical semantic name for a known macOS virtual-key code.
pub fn semantic_key_name(code: u16) -> Option<&'static str> {
    SEMANTIC_KEYS
        .iter()
        .find_map(|(known_code, name)| (*known_code == code).then_some(*name))
}

/// Resolves generated key names using the permissive aliases supported by the
/// Swift generation path. Numeric input is accepted only for a known code.
pub fn generated_semantic_key_code(name: &str) -> Option<u16> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return None;
    }

    if let Some(code) = SEMANTIC_KEYS
        .iter()
        .find_map(|(code, name)| name.eq_ignore_ascii_case(trimmed).then_some(*code))
    {
        return Some(code);
    }

    let symbolic_alias = match trimmed {
        "←" => Some(123),
        "→" => Some(124),
        "↓" => Some(125),
        "↑" => Some(126),
        _ => None,
    };
    if symbolic_alias.is_some() {
        return symbolic_alias;
    }

    let normalized = normalized_name(trimmed);
    let alias = match normalized.as_str() {
        "left" | "leftarrow" | "arrowleft" => Some(123),
        "right" | "rightarrow" | "arrowright" => Some(124),
        "up" | "uparrow" | "arrowup" => Some(126),
        "down" | "downarrow" | "arrowdown" => Some(125),
        "esc" | "escape" => Some(53),
        "return" | "enter" => Some(36),
        "space" | "spacebar" => Some(49),
        "delete" | "backspace" => Some(51),
        "forwarddelete" => Some(117),
        _ => None,
    };
    if alias.is_some() {
        return alias;
    }

    if let Some(code) = SEMANTIC_KEYS.iter().find_map(|(code, name)| {
        (normalized_name(name) == normalized && !normalized.is_empty()).then_some(*code)
    }) {
        return Some(code);
    }

    let code = trimmed.parse::<u16>().ok()?;
    semantic_key_name(code).map(|_| code)
}

/// Parses generated modifier aliases into the key-stroke modifier mask.
/// Empty values are ignored, aliases and duplicates collapse, and an unknown
/// value rejects the complete list.
pub fn generated_modifier_mask<S: AsRef<str>>(names: &[S]) -> Option<u8> {
    let mut modifiers = 0;
    for name in names {
        let normalized = normalized_name(name.as_ref());
        let bit = match normalized.as_str() {
            "cmd" | "command" | "meta" => 1,
            "shift" => 2,
            "opt" | "option" | "alt" => 4,
            "ctrl" | "control" => 8,
            "" => continue,
            _ => return None,
        };
        modifiers |= bit;
    }
    Some(modifiers)
}

fn normalized_name(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .filter(|character| character.is_alphanumeric())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_known_code_and_name_round_trips() {
        for &(code, name) in SEMANTIC_KEYS {
            assert_eq!(semantic_key_name(code), Some(name));
            assert_eq!(semantic_key_code(name), Some(code));
            assert_eq!(generated_semantic_key_code(name), Some(code));
            assert_eq!(
                generated_semantic_key_code(&name.to_ascii_lowercase()),
                Some(code)
            );
        }
        assert_eq!(semantic_key_name(10), None);
        assert_eq!(semantic_key_name(u16::MAX), None);
    }

    #[test]
    fn strict_lookup_preserves_configuration_operation_vocabulary() {
        for (name, code) in [
            ("LeftArrow", 123),
            ("←", 123),
            ("Escape", 53),
            ("Esc", 53),
            ("Delete", 51),
            ("Backspace", 51),
            ("ForwardDelete", 117),
            ("Forward Delete", 117),
            ("PageUp", 116),
            ("Page Up", 116),
        ] {
            assert_eq!(semantic_key_code(name), Some(code), "{name}");
        }
        for unsupported in ["a", "left", "Enter", "Spacebar", "36", "Keypad-Enter"] {
            assert_eq!(semantic_key_code(unsupported), None, "{unsupported}");
        }
    }

    #[test]
    fn generated_lookup_accepts_case_and_punctuation_insensitive_aliases() {
        for (name, code) in [
            ("LEFT", 123),
            ("left-arrow", 123),
            ("arrow left", 123),
            ("right", 124),
            ("RIGHT_ARROW", 124),
            ("arrow.right", 124),
            ("up", 126),
            ("up arrow", 126),
            ("arrow_up", 126),
            ("down", 125),
            ("down-arrow", 125),
            ("arrow down", 125),
            ("esc", 53),
            ("ESCAPE", 53),
            ("return", 36),
            ("enter", 36),
            ("space", 49),
            ("space-bar", 49),
            ("delete", 51),
            ("back_space", 51),
            ("forward-delete", 117),
            ("page-up", 116),
            ("right.command", 54),
            ("keypad enter", 76),
            ("←", 123),
            ("→", 124),
            ("↓", 125),
            ("↑", 126),
        ] {
            assert_eq!(generated_semantic_key_code(name), Some(code), "{name}");
        }
        assert_eq!(generated_semantic_key_code(""), None);
        assert_eq!(generated_semantic_key_code("not-a-key"), None);
    }

    #[test]
    fn generated_lookup_accepts_only_known_numeric_codes() {
        assert_eq!(generated_semantic_key_code("122"), Some(122));
        assert_eq!(generated_semantic_key_code("10"), None);
        assert_eq!(generated_semantic_key_code("999"), None);
        assert_eq!(generated_semantic_key_code("65535"), None);
        // Canonical numeric key names win before numeric-code parsing.
        assert_eq!(generated_semantic_key_code("1"), Some(18));
    }

    #[test]
    fn generated_modifier_aliases_collapse_duplicates_and_reject_unknowns() {
        assert_eq!(
            generated_modifier_mask(&[
                "cmd", "COMMAND", "meta", "shift", "opt", "option", "alt", "ctrl", "control",
                "---",
            ]),
            Some(15)
        );
        assert_eq!(generated_modifier_mask(&["", "  "]), Some(0));
        assert_eq!(generated_modifier_mask(&["com.mand", "con!trol"]), Some(9));
        assert_eq!(generated_modifier_mask(&["command", "hyper"]), None);
    }
}
