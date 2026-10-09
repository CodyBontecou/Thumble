mod common;

use common::{core, error_text, no_tokens, pair, sent_message, ScriptedTokens};
use thumble_core::{CoreTime, Effect, HostCore, KeyBinding, PersistentState, TrustedClient};
use thumble_protocol::{ButtonPressState, ControllerMessage, ControllerMessageType, KeypadElementID};

#[test]
fn explicit_pairing_code_rotation_is_validated_and_preserves_state() {
    let mut core = core();
    let before = core.persistent_state().clone();
    let mut tokens = ScriptedTokens::new(&["234567"], &[]);

    core.rotate_pairing_code(&mut tokens).unwrap();

    assert_eq!(core.pairing_code(), "234567");
    assert_eq!(core.persistent_state(), &before);

    let mut invalid = ScriptedTokens::new(&["secret"], &[]);
    assert!(core.rotate_pairing_code(&mut invalid).is_err());
    assert_eq!(core.pairing_code(), "234567");
}

#[test]
fn pairing_request_rotates_code_and_pairing_acceptance_is_websocket_only() {
    let mut core = core();
    let mut request = ControllerMessage::new(ControllerMessageType::PairingRequest, 5);
    request.client_name = Some("Cody's iPhone".to_owned());
    let mut tokens = ScriptedTokens::new(&["654321"], &["opaque-auth-token"]);

    let request_effects = core.handle_message(10, request, 100, &mut tokens).unwrap();
    assert_eq!(core.pairing_code(), "654321");
    assert!(core.status().pairing_pending);
    assert_eq!(core.status().client_name.as_deref(), Some("Cody's iPhone"));
    let challenge = sent_message(&request_effects, ControllerMessageType::PairingChallenge);
    assert_eq!(challenge.pairing_code, None);

    let mut hello = ControllerMessage::new(ControllerMessageType::Hello, 6);
    hello.pairing_code = Some("654321".to_owned());
    hello.client_name = Some("Cody's iPhone".to_owned());
    let accepted_effects = core.handle_message(10, hello, 200, &mut tokens).unwrap();
    assert!(matches!(
        accepted_effects.first(),
        Some(Effect::PersistState)
    ));
    let accepted = sent_message(&accepted_effects, ControllerMessageType::PairingAccepted);
    assert_eq!(accepted.auth_token.as_deref(), Some("opaque-auth-token"));
    assert_eq!(accepted.server_id.as_deref(), Some("server-1"));
    assert_eq!(accepted.realtime_token, None);
    assert_eq!(accepted.binding_presentations, Some(Vec::new()));
    assert_eq!(accepted.capabilities, Some(Vec::new()));
    assert_eq!(accepted.input_protocol_version, Some(3));
    assert_eq!(accepted.gamepad_profiles.as_ref().unwrap().len(), 1);
    assert_eq!(
        accepted.gamepad_profile_id.as_deref(),
        Some(core.persistent_state().active_profile_id.as_str())
    );
    assert!(core.status().paired);

    let trusted = &core.persistent_state().trusted_clients["opaque-auth-token"];
    assert_eq!(trusted.name, "Cody's iPhone");
    assert_eq!(trusted.created_at, 200);
    assert_eq!(trusted.last_seen_at, 200);
}

#[test]
fn pending_pairing_is_not_rotated_or_superseded_by_other_connections() {
    let mut core = core();
    let request = ControllerMessage::new(ControllerMessageType::PairingRequest, 0);
    let mut tokens = ScriptedTokens::new(&["654321"], &[]);
    core.handle_message(10, request.clone(), 0, &mut tokens)
        .unwrap();

    let repeated = core
        .handle_message(10, request.clone(), 1, &mut no_tokens())
        .unwrap();
    assert_eq!(core.pairing_code(), "654321");
    let _ = sent_message(&repeated, ControllerMessageType::PairingChallenge);

    let rejected = core
        .handle_message(11, request, 2, &mut no_tokens())
        .unwrap();
    assert_eq!(
        error_text(&rejected),
        "Another pairing request is already pending"
    );
    assert!(rejected.iter().any(|effect| matches!(
        effect,
        Effect::CloseConnection {
            connection_id: 11,
            ..
        }
    )));
    assert_eq!(core.pairing_code(), "654321");
}

#[test]
fn pending_pairing_expires_even_if_socket_remains_open() {
    let mut core = core();
    let request = ControllerMessage::new(ControllerMessageType::PairingRequest, 0);
    let mut tokens = ScriptedTokens::new(&["654321"], &[]);
    core.handle_message(10, request, 0, &mut tokens).unwrap();

    let effects = core.expire_holds(120_000, 1_750);
    assert_eq!(
        error_text(&effects),
        "Pairing request expired. Request pairing again."
    );
    assert!(effects.iter().any(|effect| matches!(
        effect,
        Effect::CloseConnection {
            connection_id: 10,
            ..
        }
    )));
    assert!(!core.status().pairing_pending);
}

#[test]
fn wrong_pairing_codes_apply_a_short_global_backoff() {
    let mut core = core();
    let mut wrong = ControllerMessage::new(ControllerMessageType::Hello, 0);
    wrong.pairing_code = Some("999999".to_owned());
    let effects = core
        .handle_message_at(1, wrong, CoreTime::new(0, 100), &mut no_tokens())
        .unwrap();
    assert_eq!(error_text(&effects), "Wrong pairing code");

    let mut correct = ControllerMessage::new(ControllerMessageType::Hello, 0);
    correct.pairing_code = Some("111111".to_owned());
    let effects = core
        .handle_message_at(2, correct.clone(), CoreTime::new(1, 200), &mut no_tokens())
        .unwrap();
    assert_eq!(
        error_text(&effects),
        "Pairing is temporarily rate limited. Try again shortly."
    );

    let mut tokens = ScriptedTokens::new(&[], &["accepted-after-backoff"]);
    let effects = core
        .handle_message_at(3, correct, CoreTime::new(2, 350), &mut tokens)
        .unwrap();
    assert_eq!(
        sent_message(&effects, ControllerMessageType::PairingAccepted)
            .auth_token
            .as_deref(),
        Some("accepted-after-backoff")
    );
}

#[test]
fn wrong_code_server_and_token_have_clear_secret_free_errors() {
    let mut wrong_code_core = core();
    let mut hello = ControllerMessage::new(ControllerMessageType::Hello, 0);
    hello.pairing_code = Some("999999".to_owned());
    let effects = wrong_code_core
        .handle_message(1, hello, 0, &mut no_tokens())
        .unwrap();
    assert_eq!(error_text(&effects), "Wrong pairing code");
    assert!(effects.iter().any(|effect| matches!(
        effect,
        Effect::CloseConnection {
            connection_id: 1,
            ..
        }
    )));

    let mut state = PersistentState::minimal("server-1").unwrap();
    state.trusted_clients.insert(
        "trusted-secret".to_owned(),
        TrustedClient {
            name: "Phone".to_owned(),
            created_at: 1,
            last_seen_at: 1,
        },
    );
    let mut wrong_server_core = HostCore::new(state.clone(), "111111").unwrap();
    let mut reconnect = ControllerMessage::new(ControllerMessageType::Hello, 0);
    reconnect.auth_token = Some("trusted-secret".to_owned());
    reconnect.server_id = Some("other-server".to_owned());
    let effects = wrong_server_core
        .handle_message(1, reconnect, 2, &mut no_tokens())
        .unwrap();
    assert_eq!(error_text(&effects), "Wrong server ID");

    let mut wrong_token_core = HostCore::new(state, "111111").unwrap();
    let mut reconnect = ControllerMessage::new(ControllerMessageType::Hello, 0);
    reconnect.auth_token = Some("unknown-secret".to_owned());
    reconnect.server_id = Some("server-1".to_owned());
    let effects = wrong_token_core
        .handle_message(1, reconnect, 2, &mut no_tokens())
        .unwrap();
    assert_eq!(
        error_text(&effects),
        "Trusted pairing expired. Request pairing again from Thumble Host."
    );
    assert!(!error_text(&effects).contains("unknown-secret"));
}

#[test]
fn trusted_same_token_replaces_connection_and_releases_held_output() {
    let mut core = core();
    pair(&mut core, 1, "same-secret");

    let mut down = ControllerMessage::new(ControllerMessageType::Button, 0);
    down.button = Some(KeypadElementID::preset(5));
    down.state = Some(ButtonPressState::Down);
    down.input_protocol_version = Some(3);
    down.input_generation = Some(7);
    down.input_sequence = Some(1);
    down.press_identifier = Some(9);
    let down_effects = core.handle_message(1, down, 10, &mut no_tokens()).unwrap();
    assert!(down_effects
        .iter()
        .any(|effect| matches!(effect, Effect::KeyDown(KeyBinding { key_code: 36, .. }))));

    let mut reconnect = ControllerMessage::new(ControllerMessageType::Hello, 0);
    reconnect.auth_token = Some("same-secret".to_owned());
    reconnect.server_id = Some("server-1".to_owned());
    reconnect.client_name = Some("Replacement iPhone".to_owned());
    let effects = core
        .handle_message(2, reconnect, 20, &mut no_tokens())
        .unwrap();

    let key_up_index = effects
        .iter()
        .position(|effect| matches!(effect, Effect::KeyUp(KeyBinding { key_code: 36, .. })))
        .unwrap();
    let close_index = effects
        .iter()
        .position(|effect| {
            matches!(
                effect,
                Effect::CloseConnection {
                    connection_id: 1,
                    ..
                }
            )
        })
        .unwrap();
    assert!(key_up_index < close_index);
    assert_eq!(
        sent_message(&effects, ControllerMessageType::PairingAccepted)
            .auth_token
            .as_deref(),
        Some("same-secret")
    );
    assert_eq!(
        core.status().client_name.as_deref(),
        Some("Replacement iPhone")
    );

    // A late disconnect from the replaced socket cannot clear the new session.
    core.disconnect(1);
    assert!(core.status().paired);
}

#[test]
fn different_active_token_is_rejected_without_disrupting_active_client() {
    let mut core = core();
    pair(&mut core, 1, "active-secret");
    core.persistent_state();

    // Add a second trusted token through a serialized-state reconstruction.
    let mut state = core.persistent_state().clone();
    state.trusted_clients.insert(
        "other-secret".to_owned(),
        TrustedClient {
            name: "Other".to_owned(),
            created_at: 0,
            last_seen_at: 0,
        },
    );
    let mut replacement_core = HostCore::new(state, "111111").unwrap();
    let mut first = ControllerMessage::new(ControllerMessageType::Hello, 0);
    first.auth_token = Some("active-secret".to_owned());
    first.server_id = Some("server-1".to_owned());
    replacement_core
        .handle_message(1, first, 10, &mut no_tokens())
        .unwrap();

    let mut other = ControllerMessage::new(ControllerMessageType::Hello, 0);
    other.auth_token = Some("other-secret".to_owned());
    other.server_id = Some("server-1".to_owned());
    let effects = replacement_core
        .handle_message(2, other, 11, &mut no_tokens())
        .unwrap();
    assert_eq!(error_text(&effects), "Another client is already active");
    assert!(replacement_core.status().paired);
    assert_eq!(
        replacement_core.status().client_name.as_deref(),
        Some("Test iPhone")
    );
}

#[test]
fn debug_and_status_never_render_authentication_tokens() {
    let mut core = core();
    let effects = pair(&mut core, 1, "never-print-this-token");
    let core_debug = format!("{core:?}");
    let effects_debug = format!("{effects:?}");
    let state_debug = format!("{:?}", core.persistent_state());
    let status_json = serde_json::to_string(&core.status()).unwrap();

    for rendered in [core_debug, effects_debug, state_debug, status_json] {
        assert!(!rendered.contains("never-print-this-token"));
    }
}
