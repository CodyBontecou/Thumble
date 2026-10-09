use thumble_core::{KeyBinding, OutputBinding};
use thumble_host::draft_operation::ElementJoystickMapping;

#[test]
fn joystick_directions_serialize_shared_modifier_spelling_without_input_routing() {
    let binding = OutputBinding::keyboard(KeyBinding::new(40, 3));
    let mapping = ElementJoystickMapping {
        up: binding.clone(), down: binding.clone(), left: binding.clone(), right: binding,
    };
    let value = serde_json::to_value(&mapping).unwrap();
    for direction in ["up", "down", "left", "right"] {
        assert_eq!(value[direction]["keyboard"]["modifiersRawValue"], 3);
        assert!(value[direction]["keyboard"].get("modifiers").is_none());
        assert!(value[direction].get("inputID").is_none());
    }
    assert_eq!(serde_json::from_value::<ElementJoystickMapping>(value).unwrap(), mapping);
    assert!(serde_json::from_value::<ElementJoystickMapping>(serde_json::json!({
        "up": "jump", "down": "attack", "left": "dash", "right": "focus"
    })).is_err());
}
