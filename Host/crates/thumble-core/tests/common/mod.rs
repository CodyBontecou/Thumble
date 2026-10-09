#![allow(dead_code)]

use std::collections::VecDeque;
use thumble_core::{Effect, HostCore, OutputBinding, PersistentState, TokenSource};
use thumble_protocol::{ControllerMessage, ControllerMessageType, KeypadElementID};

/// Edit the installed control, not a routing/sidecar map. Tests deliberately
/// keep sidecars unchanged so input execution must honor the owned output.
pub fn set_owned_output(state: &mut PersistentState, profile_id: &str, id: KeypadElementID, output: OutputBinding) {
    let profile = state.profile_mut(profile_id).expect("installed profile");
    let mut found = false;
    for customization in ["customization", "landscapeCustomization", "portraitCustomization"] {
        let Some(elements) = profile.get_mut(customization).and_then(|c| c.get_mut("elements")).and_then(serde_json::Value::as_array_mut) else { continue; };
        for element in elements {
            if element.get("id").and_then(serde_json::Value::as_str).and_then(KeypadElementID::parse) == Some(id) {
                element["output"] = output.element_value();
                found = true;
            }
        }
    }
    assert!(found, "output edits require an installed control UUID");
}

pub struct ScriptedTokens {
    codes: VecDeque<String>,
    tokens: VecDeque<String>,
}

impl ScriptedTokens {
    pub fn new(codes: &[&str], tokens: &[&str]) -> Self {
        Self {
            codes: codes.iter().map(|value| (*value).to_owned()).collect(),
            tokens: tokens.iter().map(|value| (*value).to_owned()).collect(),
        }
    }
}

impl TokenSource for ScriptedTokens {
    fn next_pairing_code(&mut self) -> String {
        self.codes.pop_front().expect("scripted pairing code")
    }

    fn next_auth_token(&mut self) -> String {
        self.tokens.pop_front().expect("scripted auth token")
    }
}

pub fn core() -> HostCore {
    HostCore::new(PersistentState::minimal("server-1").unwrap(), "111111").unwrap()
}

pub fn pair(core: &mut HostCore, connection_id: u64, token: &str) -> Vec<Effect> {
    let mut hello = ControllerMessage::new(ControllerMessageType::Hello, 0);
    hello.pairing_code = Some(core.pairing_code().to_owned());
    hello.client_name = Some("Test iPhone".to_owned());
    let mut tokens = ScriptedTokens::new(&[], &[token]);
    core.handle_message(connection_id, hello, 1_000, &mut tokens)
        .unwrap()
}

pub fn sent_message(effects: &[Effect], kind: ControllerMessageType) -> &ControllerMessage {
    effects
        .iter()
        .find_map(|effect| match effect {
            Effect::SendMessage { message, .. } if message.message_type == kind => Some(message),
            _ => None,
        })
        .expect("expected outbound message")
}

pub fn diagnostic_text(effects: &[Effect]) -> &str {
    effects
        .iter()
        .find_map(|effect| match effect {
            Effect::Diagnostic { message, .. } => Some(message.as_str()),
            _ => None,
        })
        .expect("expected diagnostic effect")
}

pub fn error_text(effects: &[Effect]) -> &str {
    sent_message(effects, ControllerMessageType::Error)
        .message
        .as_deref()
        .expect("error text")
}

pub fn no_tokens() -> ScriptedTokens {
    ScriptedTokens::new(&[], &[])
}
