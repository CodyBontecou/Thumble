mod common;

use common::{core, no_tokens, pair, set_owned_output};
use thumble_core::{
    CoreTime, Effect, HostCore, KeyBinding, OutputBinding, PersistentState, DEFAULT_PROFILE_ID,
};
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType, ControllerPointerButton,
    ControllerPointerEventKind, KeypadElementID,
};

fn button_message(
    button: KeypadElementID,
    state: ButtonPressState,
    generation: Option<u64>,
    sequence: Option<u64>,
    press_identifier: Option<u64>,
) -> ControllerMessage {
    let mut message = ControllerMessage::new(ControllerMessageType::Button, 0);
    message.button = Some(button);
    message.state = Some(state);
    if generation.is_some() {
        message.input_protocol_version = Some(3);
    }
    message.input_generation = generation;
    message.input_sequence = sequence;
    message.press_identifier = press_identifier;
    message
}

fn pointer_message(
    event: ControllerPointerEventKind,
    generation: u64,
    sequence: u64,
) -> ControllerMessage {
    let mut message = ControllerMessage::new(ControllerMessageType::Pointer, 0);
    message.pointer_event = Some(event);
    message.input_protocol_version = Some(3);
    message.input_generation = Some(generation);
    message.input_sequence = Some(sequence);
    message
}

fn has_key_down(effects: &[Effect], key_code: u16) -> bool {
    effects
        .iter()
        .any(|effect| matches!(effect, Effect::KeyDown(binding) if binding.key_code == key_code))
}

fn has_key_up(effects: &[Effect], key_code: u16) -> bool {
    effects
        .iter()
        .any(|effect| matches!(effect, Effect::KeyUp(binding) if binding.key_code == key_code))
}

#[test]
fn legacy_v1_is_accepted_only_before_v2_establishes() {
    let mut core = core();
    pair(&mut core, 1, "token");

    let legacy_down = button_message(KeypadElementID::preset(5), ButtonPressState::Down, None, None, None);
    let effects = core
        .handle_message(1, legacy_down, 0, &mut no_tokens())
        .unwrap();
    assert!(has_key_down(&effects, 36));

    let v2_down = button_message(
        KeypadElementID::preset(6),
        ButtonPressState::Down,
        Some(10),
        Some(1),
        Some(1),
    );
    core.handle_message(1, v2_down, 1, &mut no_tokens())
        .unwrap();
    assert_eq!(core.status().active_generation, Some(10));

    let missing_generation =
        button_message(KeypadElementID::preset(10), ButtonPressState::Down, None, None, None);
    let effects = core
        .handle_message(1, missing_generation, 2, &mut no_tokens())
        .unwrap();
    assert!(!has_key_down(&effects, 53));
    assert_eq!(core.status().counters.rejected_inputs, 1);
}

#[test]
fn current_plus_one_generation_releases_then_transitions_and_retired_is_rejected() {
    let mut core = core();
    pair(&mut core, 1, "token");
    let first = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(4),
        Some(1),
        Some(1),
    );
    core.handle_message(1, first, 0, &mut no_tokens()).unwrap();

    let next = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(5),
        Some(1),
        Some(2),
    );
    let effects = core.handle_message(1, next, 1, &mut no_tokens()).unwrap();
    let up = effects
        .iter()
        .position(|effect| matches!(effect, Effect::KeyUp(_)))
        .unwrap();
    let down = effects
        .iter()
        .position(|effect| matches!(effect, Effect::KeyDown(_)))
        .unwrap();
    assert!(up < down);
    assert_eq!(core.status().active_generation, Some(5));

    let retired = button_message(
        KeypadElementID::preset(6),
        ButtonPressState::Down,
        Some(4),
        Some(2),
        Some(3),
    );
    let effects = core
        .handle_message(1, retired, 2, &mut no_tokens())
        .unwrap();
    assert!(!has_key_down(&effects, 48));
    assert_eq!(core.status().counters.stale_generations, 1);
}

#[test]
fn unexpected_generation_and_v2_missing_sequence_are_rejected() {
    let mut core = core();
    pair(&mut core, 1, "token");
    let initial = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(8),
        Some(1),
        Some(1),
    );
    core.handle_message(1, initial, 0, &mut no_tokens())
        .unwrap();

    let unexpected = button_message(
        KeypadElementID::preset(6),
        ButtonPressState::Down,
        Some(10),
        Some(2),
        Some(2),
    );
    let effects = core
        .handle_message(1, unexpected, 1, &mut no_tokens())
        .unwrap();
    assert!(!has_key_down(&effects, 48));

    let missing_sequence = button_message(
        KeypadElementID::preset(6),
        ButtonPressState::Down,
        Some(8),
        None,
        Some(2),
    );
    let effects = core
        .handle_message(1, missing_sequence, 2, &mut no_tokens())
        .unwrap();
    assert!(!has_key_down(&effects, 48));
    assert_eq!(core.status().counters.rejected_inputs, 2);
}

#[test]
fn reliable_sequences_are_monotonic_and_deduplicated() {
    let mut core = core();
    pair(&mut core, 1, "token");
    let first = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(1),
        Some(10),
        Some(1),
    );
    assert!(has_key_down(
        &core.handle_message(1, first, 0, &mut no_tokens()).unwrap(),
        36
    ));

    for sequence in [10, 9] {
        let duplicate = button_message(
            KeypadElementID::preset(5),
            ButtonPressState::Up,
            Some(1),
            Some(sequence),
            Some(1),
        );
        let effects = core
            .handle_message(1, duplicate, 1, &mut no_tokens())
            .unwrap();
        assert!(!has_key_up(&effects, 36));
    }
    assert_eq!(core.status().counters.duplicate_sequences, 2);
    assert_eq!(core.status().pressed_buttons, vec![KeypadElementID::preset(5)]);
}

#[test]
fn heartbeat_refresh_dedupes_while_overlapping_press_ids_emit_distinct_pulse() {
    let mut core = core();
    pair(&mut core, 1, "token");

    let down_one = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(2),
        Some(1),
        Some(100),
    );
    let effects = core
        .handle_message(1, down_one, 0, &mut no_tokens())
        .unwrap();
    assert!(has_key_down(&effects, 36));

    let refresh = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(2),
        Some(2),
        Some(100),
    );
    let effects = core
        .handle_message(1, refresh, 50, &mut no_tokens())
        .unwrap();
    assert!(!has_key_down(&effects, 36));

    let overlap = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(2),
        Some(3),
        Some(200),
    );
    let effects = core
        .handle_message(1, overlap, 60, &mut no_tokens())
        .unwrap();
    assert!(effects
        .iter()
        .any(|effect| matches!(effect, Effect::PulseKey(binding) if binding.key_code == 36)));

    let up_one = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Up,
        Some(2),
        Some(4),
        Some(100),
    );
    let effects = core
        .handle_message(1, up_one, 70, &mut no_tokens())
        .unwrap();
    assert!(!has_key_up(&effects, 36));

    let up_two = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Up,
        Some(2),
        Some(5),
        Some(200),
    );
    let effects = core
        .handle_message(1, up_two, 80, &mut no_tokens())
        .unwrap();
    assert!(has_key_up(&effects, 36));
    assert!(core.status().pressed_buttons.is_empty());
}

#[test]
fn identical_bindings_are_reference_counted_across_inputs() {
    let mut state = PersistentState::minimal("server-1").unwrap();
    set_owned_output(&mut state, DEFAULT_PROFILE_ID, KeypadElementID::preset(6), OutputBinding::keyboard(KeyBinding::new(36, 0)));
    let mut core = HostCore::new(state, "111111").unwrap();
    pair(&mut core, 1, "token");

    let jump_down = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(3),
        Some(1),
        Some(1),
    );
    assert!(has_key_down(
        &core
            .handle_message(1, jump_down, 0, &mut no_tokens())
            .unwrap(),
        36
    ));
    let attack_down = button_message(
        KeypadElementID::preset(6),
        ButtonPressState::Down,
        Some(3),
        Some(2),
        Some(2),
    );
    assert!(!has_key_down(
        &core
            .handle_message(1, attack_down, 1, &mut no_tokens())
            .unwrap(),
        36
    ));

    let jump_up = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Up,
        Some(3),
        Some(3),
        Some(1),
    );
    assert!(!has_key_up(
        &core
            .handle_message(1, jump_up, 2, &mut no_tokens())
            .unwrap(),
        36
    ));
    let attack_up = button_message(
        KeypadElementID::preset(6),
        ButtonPressState::Up,
        Some(3),
        Some(4),
        Some(2),
    );
    assert!(has_key_up(
        &core
            .handle_message(1, attack_up, 3, &mut no_tokens())
            .unwrap(),
        36
    ));
}

#[test]
fn pointer_move_scroll_button_dedupe_and_explicit_release_are_typed() {
    let mut core = core();
    pair(&mut core, 1, "token");

    let mut movement = pointer_message(ControllerPointerEventKind::Move, 4, 1);
    movement.delta_x = Some(1.25);
    movement.delta_y = Some(-2.5);
    let effects = core
        .handle_message(1, movement, 0, &mut no_tokens())
        .unwrap();
    assert!(effects.iter().any(|effect| matches!(effect,
        Effect::PointerMove { delta_x, delta_y } if *delta_x == 1.25 && *delta_y == -2.5
    )));

    let mut scroll = pointer_message(ControllerPointerEventKind::Scroll, 4, 2);
    scroll.delta_x = Some(3.0);
    scroll.delta_y = Some(4.0);
    let effects = core.handle_message(1, scroll, 1, &mut no_tokens()).unwrap();
    assert!(effects.iter().any(|effect| matches!(effect,
        Effect::PointerScroll { delta_x, delta_y } if *delta_x == 3.0 && *delta_y == 4.0
    )));

    let mut down = pointer_message(ControllerPointerEventKind::Button, 4, 3);
    down.pointer_button = Some(ControllerPointerButton::Left);
    down.state = Some(ButtonPressState::Down);
    let effects = core
        .handle_message(1, down.clone(), 2, &mut no_tokens())
        .unwrap();
    assert!(effects.iter().any(|effect| matches!(
        effect,
        Effect::PointerButton {
            button: ControllerPointerButton::Left,
            pressed: true
        }
    )));

    let duplicate = core.handle_message(1, down, 3, &mut no_tokens()).unwrap();
    assert!(!duplicate
        .iter()
        .any(|effect| matches!(effect, Effect::PointerButton { .. })));

    let mut release = ControllerMessage::new(ControllerMessageType::ReleaseAll, 0);
    release.input_protocol_version = Some(3);
    release.input_generation = Some(4);
    let effects = core
        .handle_message(1, release, 4, &mut no_tokens())
        .unwrap();
    assert!(effects.iter().any(|effect| matches!(
        effect,
        Effect::PointerButton {
            button: ControllerPointerButton::Left,
            pressed: false
        }
    )));
    assert!(core.status().active_pointer_buttons.is_empty());
}

#[test]
fn disconnect_releases_every_key_and_pointer_button() {
    let mut core = core();
    pair(&mut core, 1, "token");
    let down = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(5),
        Some(1),
        Some(1),
    );
    core.handle_message(1, down, 0, &mut no_tokens()).unwrap();
    let mut pointer = pointer_message(ControllerPointerEventKind::Button, 5, 1);
    pointer.pointer_button = Some(ControllerPointerButton::Right);
    pointer.state = Some(ButtonPressState::Down);
    core.handle_message(1, pointer, 0, &mut no_tokens())
        .unwrap();

    let effects = core.disconnect(1);
    assert!(has_key_up(&effects, 36));
    assert!(effects.iter().any(|effect| matches!(
        effect,
        Effect::PointerButton {
            button: ControllerPointerButton::Right,
            pressed: false
        }
    )));
    assert!(!core.status().paired);
    assert!(core.status().pressed_buttons.is_empty());
}

#[test]
fn separate_wall_and_monotonic_timestamps_drive_persistence_and_expiry() {
    let mut core = core();
    let mut hello = ControllerMessage::new(ControllerMessageType::Hello, 0);
    hello.pairing_code = Some("111111".to_owned());
    let mut tokens = common::ScriptedTokens::new(&[], &["clock-token"]);
    core.handle_message_at(1, hello, CoreTime::new(1_700_000_000_000, 10), &mut tokens)
        .unwrap();
    assert_eq!(
        core.persistent_state().trusted_clients["clock-token"].created_at,
        1_700_000_000_000
    );

    let down = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(6),
        Some(1),
        Some(1),
    );
    core.handle_message_at(
        1,
        down,
        CoreTime::new(1_700_000_100_000, 100),
        &mut no_tokens(),
    )
    .unwrap();
    assert!(!has_key_up(&core.expire_holds(199, 100), 36));
    assert!(has_key_up(&core.expire_holds(200, 100), 36));
}

#[test]
fn expiry_removes_individual_press_references_and_only_releases_last() {
    let mut core = core();
    pair(&mut core, 1, "token");
    let first = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(6),
        Some(1),
        Some(1),
    );
    core.handle_message(1, first, 0, &mut no_tokens()).unwrap();
    let second = button_message(
        KeypadElementID::preset(5),
        ButtonPressState::Down,
        Some(6),
        Some(2),
        Some(2),
    );
    core.handle_message(1, second, 100, &mut no_tokens())
        .unwrap();

    let mut pointer = pointer_message(ControllerPointerEventKind::Button, 6, 1);
    pointer.pointer_button = Some(ControllerPointerButton::Middle);
    pointer.state = Some(ButtonPressState::Down);
    core.handle_message(1, pointer, 100, &mut no_tokens())
        .unwrap();

    let effects = core.expire_holds(100, 100);
    assert!(!has_key_up(&effects, 36));
    assert_eq!(core.status().pressed_buttons, vec![KeypadElementID::preset(5)]);

    let mut heartbeat = ControllerMessage::new(ControllerMessageType::Heartbeat, 0);
    heartbeat.input_protocol_version = Some(3);
    heartbeat.input_generation = Some(6);
    core.handle_message(1, heartbeat, 150, &mut no_tokens())
        .unwrap();

    let effects = core.expire_holds(200, 100);
    assert!(has_key_up(&effects, 36));
    assert!(!effects.iter().any(|effect| matches!(
        effect,
        Effect::PointerButton {
            button: ControllerPointerButton::Middle,
            pressed: false
        }
    )));
    assert!(core.status().pressed_buttons.is_empty());

    let effects = core.expire_holds(250, 100);
    assert!(effects.iter().any(|effect| matches!(
        effect,
        Effect::PointerButton {
            button: ControllerPointerButton::Middle,
            pressed: false
        }
    )));
    assert_eq!(core.status().counters.expired_holds, 3);
}
