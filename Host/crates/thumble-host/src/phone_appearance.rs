//! Captures scalar appearance intent before queued native work. The original
//! revision prevents a delayed full-customization message replacing newer layout.
use crate::bridge::ConfigurationBridge;
use crate::draft_operation::{
    ConfigurationBackgroundEdit, ConfigurationOperation, ConfigurationVariant, CustomizationChanges,
};
use thumble_core::{ConfigurationDocument, PersistentState};
use thumble_protocol::{ControllerMessage, ControllerMessageType};

pub(crate) struct PhoneAppearanceRequest {
    revision: u64,
    document: ConfigurationDocument,
    operation: ConfigurationOperation,
}

pub(crate) struct PreparedPhoneAppearance {
    revision: u64,
    before: ConfigurationDocument,
    after: ConfigurationDocument,
    now_millis: i64,
}

impl PhoneAppearanceRequest {
    pub(crate) fn capture(state: &PersistentState, message: &ControllerMessage) -> Option<Self> {
        if message.message_type != ControllerMessageType::GamepadCustomization {
            return None;
        }
        let incoming = message.gamepad_customization.as_ref()?.as_object()?;
        let profile_id = message
            .gamepad_profile_id
            .as_deref()
            .unwrap_or(&state.active_profile_id);
        let profile = state.profile(profile_id)?;
        let mut previous = profile.get("customization")?.as_object()?.clone();
        let mut incoming = incoming.clone();
        let color = incoming.remove("colorSchemePreference")?;
        let color_scheme = serde_json::from_value(color).ok()?;
        previous.remove("colorSchemePreference");
        previous.remove("updatedAt");
        incoming.remove("updatedAt");
        // Generic layout replacements retain their existing handler. Never
        // mistake a binding, canvas, asset or element edit for scalar intent.
        if incoming != previous {
            return None;
        }
        Some(Self {
            revision: state.configuration_revision,
            document: ConfigurationDocument::from_state(state).ok()?,
            operation: ConfigurationOperation::CustomizationSet {
                profile_id: profile.get("id")?.as_str()?.to_owned(),
                variant: ConfigurationVariant::Primary,
                changes: CustomizationChanges {
                    layout_mode: None,
                    control_scale: None,
                    color_scheme: Some(color_scheme),
                    accent_style: None,
                    shows_button_labels: None,
                    background_edit: ConfigurationBackgroundEdit::Keep,
                },
            },
        })
    }

    pub(crate) fn prepare(
        self,
        bridge: &ConfigurationBridge,
        now_millis: i64,
    ) -> Result<PreparedPhoneAppearance, &'static str> {
        let (after, _) = bridge
            .apply(&self.document, &self.operation, now_millis)
            .map_err(|_| "appearance_native_transform_failed")?;
        Ok(PreparedPhoneAppearance {
            revision: self.revision,
            before: self.document,
            after,
            now_millis,
        })
    }
}

impl PreparedPhoneAppearance {
    pub(crate) fn candidate(
        &self,
        current: &PersistentState,
    ) -> Result<Option<PersistentState>, &'static str> {
        if current.configuration_revision != self.revision
            || ConfigurationDocument::from_state(current)
                .map_err(|_| "appearance_invalid_configuration")?
                != self.before
        {
            return Err("appearance_revision_conflict");
        }
        if self.after == self.before {
            return Ok(None);
        }
        // Pairing credentials can change while native work runs. Keep the live
        // authority; the child process receives only the credential-free document.
        let mut candidate = current.clone();
        self.after
            .install_into(&mut candidate)
            .map_err(|_| "appearance_invalid_configuration")?;
        candidate
            .bump_configuration_revision()
            .map_err(|_| "appearance_revision_exhausted")?;
        candidate.configuration_updated_at = self.now_millis;
        Ok(Some(candidate))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn request(state: &PersistentState) -> ControllerMessage {
        let mut message = ControllerMessage::new(ControllerMessageType::GamepadCustomization, 100);
        message.gamepad_profile_id = Some(state.active_profile_id.to_uppercase());
        let mut customization = state.profiles[0]["customization"].clone();
        customization["colorSchemePreference"] = json!("dark");
        customization["updatedAt"] = json!(100);
        message.gamepad_customization = Some(customization);
        message
    }

    #[test]
    fn captures_only_known_appearance_intent_and_never_generic_layout_edits() {
        let state = PersistentState::minimal("appearance").unwrap();
        let message = request(&state);
        assert!(PhoneAppearanceRequest::capture(&state, &message).is_some());
        let mut layout = message.clone();
        layout.gamepad_customization.as_mut().unwrap()["futureLayout"] = json!("changed");
        assert!(PhoneAppearanceRequest::capture(&state, &layout).is_none());
        let mut invalid = message.clone();
        invalid.gamepad_customization.as_mut().unwrap()["colorSchemePreference"] = json!("unknown");
        assert!(PhoneAppearanceRequest::capture(&state, &invalid).is_none());
        invalid = message;
        invalid.gamepad_profile_id = Some(uuid::Uuid::new_v4().to_string());
        assert!(PhoneAppearanceRequest::capture(&state, &invalid).is_none());
    }

    #[test]
    fn candidate_preserves_live_trust_and_rejects_revision_or_document_changes() {
        let state = PersistentState::minimal("appearance").unwrap();
        let before = ConfigurationDocument::from_state(&state).unwrap();
        let mut after = before.clone();
        after.profiles[0]["customization"]["colorSchemePreference"] = json!("dark");
        let prepared = PreparedPhoneAppearance {
            revision: state.configuration_revision,
            before,
            after,
            now_millis: 123,
        };
        let mut current = state.clone();
        current.trusted_clients.insert(
            "new-private-token".into(),
            thumble_core::TrustedClient {
                name: "Phone".into(),
                created_at: 100,
                last_seen_at: 122,
            },
        );
        let candidate = prepared.candidate(&current).unwrap().unwrap();
        assert_eq!(candidate.trusted_clients, current.trusted_clients);
        assert_eq!(candidate.server_id, current.server_id);
        assert_eq!(candidate.active_profile_id, current.active_profile_id);
        assert_eq!(candidate.default_profile_id, current.default_profile_id);
        assert_eq!(
            candidate.configuration_revision,
            current.configuration_revision + 1
        );
        assert_eq!(candidate.configuration_updated_at, 123);
        current.profiles[0]["name"] = json!("New Mac metadata");
        assert!(prepared.candidate(&current).is_err());
        current = state;
        current.bump_configuration_revision().unwrap();
        assert!(prepared.candidate(&current).is_err());
    }

    #[test]
    fn unchanged_native_document_never_creates_a_revision() {
        let state = PersistentState::minimal("appearance").unwrap();
        let document = ConfigurationDocument::from_state(&state).unwrap();
        let prepared = PreparedPhoneAppearance {
            revision: state.configuration_revision,
            before: document.clone(),
            after: document,
            now_millis: 123,
        };
        assert!(prepared.candidate(&state).unwrap().is_none());
    }
}
