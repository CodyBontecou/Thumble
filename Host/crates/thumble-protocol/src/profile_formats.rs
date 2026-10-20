//! Version negotiation for profile data, separate from real-time input v3.
use serde_json::Value;
use std::collections::BTreeSet;

pub const LEGACY_PROFILE_FORMAT: i64 = 4;
pub const OWNED_APPEARANCE_PROFILE_FORMAT: i64 = 5;
// Do not advertise v5 until codecs, complete transport bounds and migration ship.
pub const SUPPORTED_PROFILE_FORMATS: &[i64] = &[4];
pub const PROFILE_UPDATE_MESSAGE: &str = "Update Thumble on both devices to use this keypad format. Your saved setups and edits have been kept.";
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProfileFormatError {
    InvalidOffer,
    UpdateRequired,
}
pub fn negotiate_profile_format(
    required: i64,
    offered: Option<&[i64]>,
) -> Result<i64, ProfileFormatError> {
    let offered = offered.unwrap_or(&[LEGACY_PROFILE_FORMAT]);
    if offered.len() > 8
        || offered.iter().any(|v| !(1..=65_535).contains(v))
        || offered.iter().collect::<BTreeSet<_>>().len() != offered.len()
    {
        return Err(ProfileFormatError::InvalidOffer);
    }
    if ![LEGACY_PROFILE_FORMAT, OWNED_APPEARANCE_PROFILE_FORMAT].contains(&required)
        || !offered.contains(&required)
    {
        return Err(ProfileFormatError::UpdateRequired);
    }
    Ok(required)
}
pub fn required_profile_format(profiles: &[Value]) -> i64 {
    profiles
        .iter()
        .fold(LEGACY_PROFILE_FORMAT, |required, profile| {
            let explicit = profile
                .get("profileFormatVersion")
                .filter(|v| !v.is_null())
                .map_or(LEGACY_PROFILE_FORMAT, |v| v.as_i64().unwrap_or(i64::MAX));
            if ![LEGACY_PROFILE_FORMAT, OWNED_APPEARANCE_PROFILE_FORMAT].contains(&explicit) {
                return i64::MAX;
            }
            let owned = profile.get("appearanceBank").is_some_and(|v| !v.is_null())
                || profile.get("appearanceResources").is_some()
                || profile.get("appearanceResourceVersion").is_some();
            required.max(explicit).max(if owned {
                OWNED_APPEARANCE_PROFILE_FORMAT
            } else {
                LEGACY_PROFILE_FORMAT
            })
        })
}

/// Guard for receiving profile data with the currently shipped client codecs.
pub fn validate_incoming_profile_format(
    message: &crate::ControllerMessage,
) -> Result<(), ProfileFormatError> {
    if message.gamepad_profiles.is_none() && message.gamepad_customization.is_none() {
        return Ok(());
    }
    let declared = message
        .profile_format_version
        .unwrap_or(LEGACY_PROFILE_FORMAT);
    if ![LEGACY_PROFILE_FORMAT, OWNED_APPEARANCE_PROFILE_FORMAT].contains(&declared) {
        return Err(ProfileFormatError::UpdateRequired);
    }
    let required = declared.max(required_profile_format(
        message.gamepad_profiles.as_deref().unwrap_or(&[]),
    ));
    negotiate_profile_format(required, Some(SUPPORTED_PROFILE_FORMATS)).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{ControllerMessage, ControllerMessageType, ControllerWireCodec};
    #[test]
    fn shared_negotiations_and_incoming_frames_match_the_native_clients() {
        let fixture: Value =
            serde_json::from_str(include_str!("../../../fixtures/profile-formats/v1.json"))
                .unwrap();
        for row in fixture["negotiations"].as_array().unwrap() {
            let offered = row["offered"]
                .as_array()
                .map(|a| a.iter().map(|v| v.as_i64().unwrap()).collect::<Vec<_>>());
            assert_eq!(
                negotiate_profile_format(row["required"].as_i64().unwrap(), offered.as_deref())
                    .is_ok(),
                row["allowed"].as_bool().unwrap(),
                "{}",
                row["name"]
            );
        }
        for row in fixture["frames"].as_array().unwrap() {
            let message: ControllerMessage =
                serde_json::from_value(row["message"].clone()).unwrap();
            assert_eq!(
                validate_incoming_profile_format(&message).is_ok(),
                row["allowed"].as_bool().unwrap(),
                "{}",
                row["name"]
            );
        }
        assert_eq!(SUPPORTED_PROFILE_FORMATS, &[4]);
    }
    #[test]
    fn format_metadata_uses_json_instead_of_disappearing_into_compact_frames() {
        let mut message = ControllerMessage::new(ControllerMessageType::Ping, 17);
        assert_eq!(ControllerWireCodec::encode(&message).unwrap().len(), 14);
        message.supported_profile_formats = Some(vec![4]);
        message.profile_format_version = Some(4);
        let bytes = ControllerWireCodec::encode(&message).unwrap();
        assert_eq!(bytes[0], b'{');
        assert_eq!(ControllerWireCodec::decode(&bytes).unwrap(), message);
    }
}
