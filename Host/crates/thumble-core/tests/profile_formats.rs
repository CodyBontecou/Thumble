mod common;
use common::*;
use serde_json::json;
use thumble_core::{ConfigurationDocument, ConfigurationDocumentError, Effect};
use thumble_protocol::{
    ButtonPressState, ControllerMessage, ControllerMessageType as Kind, KeypadElementID,
};

#[test]
fn explicit_and_legacy_v4_pairing_preserve_profiles_and_input_protocol() {
    for offered in [None, Some(vec![4]), Some(vec![4, 5]), Some(vec![4, 99])] {
        let mut core = core();
        let profiles = core.persistent_state().profiles.clone();
        let mut hello = ControllerMessage::new(Kind::Hello, 0);
        hello.pairing_code = Some("111111".into());
        hello.supported_profile_formats = offered;
        let effects = core
            .handle_message(1, hello, 1000, &mut ScriptedTokens::new(&[], &["token"]))
            .unwrap();
        let accepted = sent_message(&effects, Kind::PairingAccepted);
        assert_eq!(accepted.profile_format_version, Some(4));
        assert_eq!(accepted.input_protocol_version, Some(3));
        assert_eq!(accepted.gamepad_profiles.as_ref().unwrap(), &profiles);
        assert_eq!(core.persistent_state().profiles, profiles);
    }
}
#[test]
fn incompatible_offer_does_not_persist_trust_or_send_a_profile_snapshot() {
    let mut core = core();
    let before = core.persistent_state().clone();
    let mut hello = ControllerMessage::new(Kind::Hello, 0);
    hello.pairing_code = Some("111111".into());
    hello.supported_profile_formats = Some(vec![5]);
    let effects = core
        .handle_message(
            1,
            hello,
            1000,
            &mut ScriptedTokens::new(&[], &["not-persisted"]),
        )
        .unwrap();
    let error = sent_message(&effects, Kind::Error);
    assert_eq!(error.profile_format_version, Some(4));
    assert!(error.message.as_ref().unwrap().contains("Update Thumble"));
    assert!(effects.iter().all(|e| !matches!(e, Effect::PersistState)));
    assert_eq!(core.persistent_state(), &before);
    assert!(!core.is_authenticated(1));
    assert!(effects.iter().all(|e| match e {
        Effect::SendMessage { message, .. } =>
            message.gamepad_profiles.is_none()
                && message.gamepad_customization.is_none()
                && message.auth_token.is_none(),
        _ => true,
    }));
}
#[test]
fn installed_future_contract_releases_and_retires_old_peer_before_any_new_snapshot_or_input() {
    let mut core = core();
    pair(&mut core, 1, "token");
    let mut down = ControllerMessage::new(Kind::Button, 0);
    down.button = Some(KeypadElementID::preset(1));
    down.state = Some(ButtonPressState::Down);
    core.handle_message(1, down.clone(), 1001, &mut no_tokens())
        .unwrap();
    assert!(!core.status().pressed_buttons.is_empty());
    let mut future = core.persistent_state().clone();
    future.profiles[0]["profileFormatVersion"] = json!(5);
    // Exercise the post-validation install seam without opening the v4 authority gate.
    assert_eq!(
        ConfigurationDocument::from_state(&future).unwrap_err(),
        ConfigurationDocumentError::UnsupportedProfileFormat
    );
    let effects = core.install_validated_persisted_state(future);
    assert!(!core.is_authenticated(1));
    assert!(core.status().pressed_buttons.is_empty());
    let error = sent_message(&effects, Kind::Error);
    assert_eq!(error.profile_format_version, Some(5));
    assert!(effects.iter().any(|e| matches!(
        e,
        Effect::CloseConnection {
            connection_id: 1,
            ..
        }
    )));
    assert!(effects.iter().all(|e| match e {
        Effect::SendMessage { message, .. } =>
            message.gamepad_profiles.is_none() && message.gamepad_customization.is_none(),
        _ => true,
    }));
    let rejected = core
        .handle_message(1, down, 1002, &mut no_tokens())
        .unwrap();
    assert!(rejected
        .iter()
        .all(|e| !matches!(e, Effect::KeyDown { .. })));
    assert!(core.status().pressed_buttons.is_empty());
}
#[test]
fn future_ready_offer_can_receive_a_new_contract_but_authority_acceptance_stays_closed() {
    let mut core = core();
    let mut hello = ControllerMessage::new(Kind::Hello, 0);
    hello.pairing_code = Some("111111".into());
    hello.supported_profile_formats = Some(vec![4, 5]);
    core.handle_message(1, hello, 1000, &mut ScriptedTokens::new(&[], &["token"]))
        .unwrap();
    let mut future = core.persistent_state().clone();
    future.profiles[0]["profileFormatVersion"] = json!(5);
    let effects = core.install_validated_persisted_state(future);
    assert!(core.is_authenticated(1));
    let snapshot = sent_message(&effects, Kind::GamepadProfiles);
    assert_eq!(snapshot.profile_format_version, Some(5));
    assert_eq!(
        ConfigurationDocument::from_state(core.persistent_state()).unwrap_err(),
        ConfigurationDocumentError::UnsupportedProfileFormat
    );
}
