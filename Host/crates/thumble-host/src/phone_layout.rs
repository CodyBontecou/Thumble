//! Native phone layout transactions. Only customization comes from the phone;
//! profile metadata, binding reconciliation, revision and persistence are local.
use crate::bridge::ConfigurationBridge;
use crate::skins::SkinReference;
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::Deserialize;
use serde_json::{json, Value};
use thumble_core::{ButtonBindings, ConfigurationDocument, PersistentState};
use thumble_protocol::ControllerMessage;
use uuid::Uuid;

const MAXIMUM_REQUEST: usize = 24 * 1024 * 1024;

pub(crate) struct PhoneLayoutBridge(ConfigurationBridge);
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Response {
    schema_version: u32,
    #[serde(rename = "invocationID")]
    invocation_id: Uuid,
    profile: Option<Value>,
    changed: bool,
    recovered: bool,
}
impl PhoneLayoutBridge {
    pub(crate) fn discover() -> Result<Self, &'static str> {
        let bridge =
            Self(ConfigurationBridge::discover().map_err(|_| "phone_layout_bridge_unavailable")?);
        let nonce = Uuid::new_v4();
        let response = bridge.invoke(json!({"schemaVersion":1,"invocationID":nonce,"phoneLayoutCommand":"capabilities","nowMillis":0}), nonce)?;
        if response.profile.is_some() || response.changed || response.recovered {
            return Err("invalid_phone_layout_response");
        }
        Ok(bridge)
    }
    fn invoke(&self, request: Value, nonce: Uuid) -> Result<Response, &'static str> {
        let mut input = serde_json::to_vec(&request).map_err(|_| "invalid_phone_layout_request")?;
        if input.len() > MAXIMUM_REQUEST {
            return Err("phone_layout_request_too_large");
        }
        input.push(b'\n');
        let output = self
            .0
            .execute_bounded(input, MAXIMUM_REQUEST)
            .map_err(|_| "phone_layout_bridge_failed")?;
        let response: Response = thumble_protocol::decode_unique_json(&output)
            .map_err(|_| "invalid_phone_layout_response")?;
        if response.schema_version != 1 || response.invocation_id != nonce {
            return Err("invalid_phone_layout_response");
        }
        Ok(response)
    }
}

// Never serialize or log this object: the captured state contains private trust.
pub(crate) struct PhoneLayoutRequest {
    state: PersistentState,
    profile_id: Uuid,
    customization: Value,
}
pub(crate) struct PreparedPhoneLayout {
    revision: u64,
    before: ConfigurationDocument,
    profile_id: Uuid,
    after: Value,
    changed: bool,
    now_millis: i64,
}
impl PhoneLayoutRequest {
    pub(crate) fn rebase(mut self, current: PersistentState) -> Result<Self, &'static str> {
        if current.profile(&self.profile_id.to_string()).is_none() && current.profiles.len() >= 256
        {
            return Err("phone_layout_profile_limit");
        }
        // Full layout payloads are explicit phone intent, as in the native Mac.
        // Queueing independent edits must not give every job the same stale base.
        // Receiver-owned metadata is taken at preparation; candidate() still
        // rejects any configuration change made while native processing runs.
        self.state = current;
        Ok(self)
    }
    pub(crate) fn capture(
        state: &PersistentState,
        message: &ControllerMessage,
    ) -> Result<Self, &'static str> {
        let raw = message
            .gamepad_profile_id
            .as_deref()
            .unwrap_or(&state.active_profile_id);
        let profile_id = Uuid::parse_str(raw).map_err(|_| "invalid_phone_layout_profile_id")?;
        if !profile_id.to_string().eq_ignore_ascii_case(raw) {
            return Err("invalid_phone_layout_profile_id");
        }
        let customization = message
            .gamepad_customization
            .as_ref()
            .filter(|v| v.is_object())
            .ok_or("invalid_phone_layout_customization")?;
        if state.profile(raw).is_none() && state.profiles.len() >= 256 {
            return Err("phone_layout_profile_limit");
        }
        Ok(Self {
            state: state.clone(),
            profile_id,
            customization: customization.clone(),
        })
    }
    pub(crate) fn skin_reference(&self) -> Result<Option<SkinReference>, &'static str> {
        self.state
            .profile(&self.profile_id.to_string())
            .and_then(|p| p.get("skinReference"))
            .filter(|v| !v.is_null())
            .map(|v| {
                serde_json::from_value(v.clone()).map_err(|_| "invalid_phone_layout_skin_reference")
            })
            .transpose()
    }
    pub(crate) fn prepare(
        self,
        bridge: &PhoneLayoutBridge,
        archive: Option<&[u8]>,
        now_millis: i64,
    ) -> Result<PreparedPhoneLayout, &'static str> {
        let before = ConfigurationDocument::from_state(&self.state)
            .map_err(|_| "invalid_phone_layout_configuration")?;
        let old = before
            .profiles
            .iter()
            .find(|p| profile_uuid(p) == Some(self.profile_id));
        let raw = serde_json::to_vec(&self.customization)
            .map_err(|_| "invalid_phone_layout_customization")?;
        if raw.len() > 8 * 1024 * 1024
            || self.state.trusted_clients.keys().any(|token| {
                !token.is_empty() && raw.windows(token.len()).any(|v| v == token.as_bytes())
            })
        {
            return Err("invalid_phone_layout_customization");
        }
        if !thumble_core::validate_element_identities(
            &json!({"id":self.profile_id,"customization":self.customization}),
        ) {
            return Err("invalid_phone_layout_elements");
        }
        let nonce = Uuid::new_v4();
        let mut request = json!({"schemaVersion":1,"invocationID":nonce,"phoneLayoutCommand":"replace",
            "profileID":self.profile_id,"customization":self.customization,"nowMillis":now_millis});
        if let Some(profile) = old {
            request["profile"] = profile.clone();
        }
        if let Some(archive) = archive {
            request["packageData"] = json!(STANDARD.encode(archive));
        }
        let response = bridge.invoke(request, nonce)?;
        let after = response.profile.ok_or("invalid_phone_layout_response")?;
        validate_profile_delta(
            old,
            &after,
            self.profile_id,
            response.changed,
            response.recovered,
            now_millis,
        )?;
        Ok(PreparedPhoneLayout {
            revision: self.state.configuration_revision,
            before,
            profile_id: self.profile_id,
            after,
            changed: response.changed,
            now_millis,
        })
    }
}
impl PreparedPhoneLayout {
    pub(crate) fn candidate(
        &self,
        current: &PersistentState,
    ) -> Result<Option<PersistentState>, &'static str> {
        if current.configuration_revision != self.revision
            || ConfigurationDocument::from_state(current)
                .map_err(|_| "invalid_phone_layout_configuration")?
                != self.before
        {
            return Err("phone_layout_revision_conflict");
        }
        if !self.changed {
            return Ok(None);
        }
        let mut candidate = current.clone();
        let id = self.profile_id.to_string();
        if let Some(profile) = candidate.profile_mut(&id) {
            *profile = self.after.clone();
        } else {
            candidate.profiles.push(self.after.clone());
        }
        // Rebuild only this profile's effective maps, pruning removed controls,
        // retaining explicit clears and installing declared outputs for new ones.
        let outputs = candidate
            .resolved_profile_output_bindings(&id)
            .ok_or("invalid_phone_layout_profile")?;
        let mut keys = ButtonBindings::default();
        for (element, output) in outputs.iter_ids() {
            if let Some(keyboard) = &output.keyboard {
                keys.insert(element, keyboard.clone());
            }
        }
        let canonical = self.after["id"]
            .as_str()
            .ok_or("invalid_phone_layout_profile")?
            .to_owned();
        candidate
            .profile_key_bindings
            .retain(|key, _| !key.eq_ignore_ascii_case(&id));
        candidate
            .profile_output_bindings
            .retain(|key, _| !key.eq_ignore_ascii_case(&id));
        candidate
            .profile_key_bindings
            .insert(canonical.clone(), keys.clone());
        candidate
            .profile_output_bindings
            .insert(canonical, outputs.clone());
        if candidate.active_profile_id.eq_ignore_ascii_case(&id) {
            candidate.key_bindings = keys;
            candidate.output_bindings = outputs;
        }
        ConfigurationDocument::from_state(&candidate)
            .map_err(|_| "invalid_phone_layout_configuration")?;
        candidate
            .bump_configuration_revision()
            .map_err(|_| "phone_layout_revision_exhausted")?;
        candidate.configuration_updated_at = self.now_millis;
        Ok(Some(candidate))
    }
}
fn profile_uuid(profile: &Value) -> Option<Uuid> {
    Uuid::parse_str(profile.get("id")?.as_str()?).ok()
}
fn validate_profile_delta(
    old: Option<&Value>,
    after: &Value,
    id: Uuid,
    changed: bool,
    recovered: bool,
    now: i64,
) -> Result<(), &'static str> {
    let object = after.as_object().ok_or("invalid_phone_layout_response")?;
    if profile_uuid(after) != Some(id)
        || recovered != old.is_none()
        || !thumble_core::validate_element_identities(after)
    {
        return Err("invalid_phone_layout_response");
    }
    if let Some(old) = old {
        let mut before = old
            .as_object()
            .ok_or("invalid_phone_layout_response")?
            .clone();
        let mut next = object.clone();
        for key in [
            "customization",
            "portraitCustomization",
            "landscapeCustomization",
            "updatedAt",
        ] {
            before.remove(key);
            next.remove(key);
        }
        if before != next || changed != (old != after) {
            return Err("invalid_phone_layout_response");
        }
    } else if !changed
        || object.keys().any(|key| {
            ![
                "id",
                "name",
                "customization",
                "portraitCustomization",
                "landscapeCustomization",
                "updatedAt",
                "orientationPreference",
                "outputMode",
            ]
            .contains(&key.as_str())
        })
        || after["name"] != "Recovered Phone Layout"
        || after
            .get("outputMode")
            .and_then(Value::as_str)
            .unwrap_or("keyboard")
            != "keyboard"
        || after
            .get("orientationPreference")
            .and_then(Value::as_str)
            .unwrap_or("automatic")
            != "automatic"
    {
        return Err("invalid_phone_layout_response");
    }
    if changed && after.get("updatedAt").and_then(Value::as_i64) != Some(now) {
        return Err("invalid_phone_layout_response");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn native_delta_cannot_change_profile_identity_metadata_or_recovery_claim() {
        let state = PersistentState::minimal("phone-layout").unwrap();
        let before = &state.profiles[0];
        let id = profile_uuid(before).unwrap();
        let mut after = before.clone();
        after["customization"]["colorSchemePreference"] = json!("dark");
        after["updatedAt"] = json!(42);
        assert!(validate_profile_delta(Some(before), &after, id, true, false, 42).is_ok());
        assert!(validate_profile_delta(Some(before), &after, id, false, false, 42).is_err());
        assert!(validate_profile_delta(Some(before), &after, id, true, true, 42).is_err());
        after["name"] = json!("Changed metadata");
        assert!(validate_profile_delta(Some(before), &after, id, true, false, 42).is_err());
        after = before.clone();
        after["launchTarget"] = json!({"path":"/tmp/unrequested-app"});
        assert!(validate_profile_delta(Some(before), &after, id, true, false, 42).is_err());
    }
    #[test]
    fn prepared_recovery_preserves_selection_and_new_trust_and_rejects_stale_authority() {
        let state = PersistentState::minimal("phone-layout").unwrap();
        let mut after = state.profiles[0].clone();
        let id = Uuid::new_v4();
        after["id"] = json!(id);
        after["name"] = json!("Recovered Phone Layout");
        after["updatedAt"] = json!(42);
        let prepared = PreparedPhoneLayout {
            revision: state.configuration_revision,
            before: ConfigurationDocument::from_state(&state).unwrap(),
            profile_id: id,
            after,
            changed: true,
            now_millis: 42,
        };
        let mut current = state.clone();
        current.trusted_clients.insert(
            "new-private-token".into(),
            thumble_core::TrustedClient {
                name: "Phone".into(),
                created_at: 1,
                last_seen_at: 2,
            },
        );
        let candidate = prepared.candidate(&current).unwrap().unwrap();
        assert_eq!(candidate.trusted_clients, current.trusted_clients);
        assert_eq!(candidate.active_profile_id, current.active_profile_id);
        assert_eq!(candidate.default_profile_id, current.default_profile_id);
        assert_eq!(candidate.profiles.len(), 2);
        assert_eq!(
            candidate.configuration_revision,
            current.configuration_revision + 1
        );
        assert!(candidate
            .profile_output_bindings
            .contains_key(&id.to_string()));
        current.profiles[0]["name"] = json!("New Mac edit");
        assert!(prepared.candidate(&current).is_err());
        current = state;
        current.bump_configuration_revision().unwrap();
        assert!(prepared.candidate(&current).is_err());
    }
    #[test]
    fn recovery_response_cannot_introduce_launch_metadata() {
        let state = PersistentState::minimal("phone-layout").unwrap();
        let mut recovered = state.profiles[0].clone();
        let id = profile_uuid(&recovered).unwrap();
        recovered["name"] = json!("Recovered Phone Layout");
        recovered["updatedAt"] = json!(42);
        assert!(validate_profile_delta(None, &recovered, id, true, true, 42).is_ok());
        recovered["launchTarget"] = json!({"path":"/tmp/not-part-of-layout"});
        assert!(validate_profile_delta(None, &recovered, id, true, true, 42).is_err());
    }
    #[test]
    fn removed_controls_are_pruned_from_only_the_target_binding_maps() {
        let mut state = PersistentState::minimal("phone-layout").unwrap();
        let id = profile_uuid(&state.profiles[0]).unwrap();
        let outputs = state
            .resolved_profile_output_bindings(&id.to_string())
            .unwrap();
        state
            .profile_output_bindings
            .insert(state.active_profile_id.clone(), outputs);
        let removed = thumble_protocol::KeypadElementID::preset(1);
        let mut after = state.profiles[0].clone();
        after["customization"]["elements"]
            .as_array_mut()
            .unwrap()
            .retain(|e| {
                e["id"]
                    .as_str()
                    .is_none_or(|v| !v.eq_ignore_ascii_case(&removed.to_string()))
            });
        after["updatedAt"] = json!(42);
        let prepared = PreparedPhoneLayout {
            revision: state.configuration_revision,
            before: ConfigurationDocument::from_state(&state).unwrap(),
            profile_id: id,
            after,
            changed: true,
            now_millis: 42,
        };
        let candidate = prepared.candidate(&state).unwrap().unwrap();
        assert!(candidate.output_bindings.get(&removed).is_none());
        assert!(candidate.key_bindings.get(&removed).is_none());
        assert!(candidate
            .resolved_profile_output_bindings(&id.to_string())
            .unwrap()
            .get(&removed)
            .is_none());
        assert!(candidate
            .output_bindings
            .get(&thumble_protocol::KeypadElementID::preset(2))
            .is_some());
    }
    #[test]
    fn credentials_inside_customization_never_reach_the_native_child() {
        use std::os::unix::fs::PermissionsExt;
        let folder = tempfile::tempdir().unwrap();
        let helper = folder.path().join("bridge");
        std::fs::write(&helper, "#!/bin/sh\nexit 1\n").unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o700)).unwrap();
        let bridge = PhoneLayoutBridge(ConfigurationBridge::at_path(helper).unwrap());
        let mut state = PersistentState::minimal("phone-layout").unwrap();
        state.trusted_clients.insert(
            "fixture-private-authentication".into(),
            thumble_core::TrustedClient {
                name: "Phone".into(),
                created_at: 1,
                last_seen_at: 2,
            },
        );
        let mut message = ControllerMessage::new(
            thumble_protocol::ControllerMessageType::GamepadCustomization,
            0,
        );
        let mut customization = state.profiles[0]["customization"].clone();
        customization["futureSecret"] = json!("fixture-private-authentication");
        message.gamepad_customization = Some(customization);
        let request = PhoneLayoutRequest::capture(&state, &message).unwrap();
        assert!(matches!(
            request.prepare(&bridge, None, 42),
            Err("invalid_phone_layout_customization")
        ));
    }
}
