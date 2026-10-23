use crate::Error;
pub const REPORT_ID: u8 = 0;
pub const REPORT_LENGTH: usize = 20;
// Apple Xbox userspace-driver descriptor, pinned from steam-controller-bridge.
// Copyright (c) 2026 Lynxware; MIT, see ThirdParty/SteamControllerBridge-LICENSE.txt.
pub const REPORT_DESCRIPTOR: &[u8] = &[
    0x05, 0x01, 0x09, 0x05, 0xa1, 0x01, 0x05, 0x01, 0x09, 0x3a, 0xa1, 0x02, 0x75, 0x08, 0x95, 0x02,
    0x05, 0x01, 0x09, 0x3f, 0x09, 0x3b, 0x81, 0x01, 0x75, 0x01, 0x15, 0x00, 0x25, 0x01, 0x35, 0x00,
    0x45, 0x01, 0x95, 0x04, 0x05, 0x09, 0x19, 0x0c, 0x29, 0x0f, 0x81, 0x02, 0x75, 0x01, 0x15, 0x00,
    0x25, 0x01, 0x35, 0x00, 0x45, 0x01, 0x95, 0x04, 0x05, 0x09, 0x09, 0x09, 0x09, 0x0a, 0x09, 0x07,
    0x09, 0x08, 0x81, 0x02, 0x75, 0x01, 0x15, 0x00, 0x25, 0x01, 0x35, 0x00, 0x45, 0x01, 0x95, 0x03,
    0x05, 0x09, 0x09, 0x05, 0x09, 0x06, 0x09, 0x0b, 0x81, 0x02, 0x75, 0x01, 0x95, 0x01, 0x81, 0x01,
    0x75, 0x01, 0x15, 0x00, 0x25, 0x01, 0x35, 0x00, 0x45, 0x01, 0x95, 0x04, 0x05, 0x09, 0x19, 0x01,
    0x29, 0x04, 0x81, 0x02, 0x75, 0x08, 0x15, 0x00, 0x26, 0xff, 0x00, 0x35, 0x00, 0x46, 0xff, 0x00,
    0x95, 0x02, 0x05, 0x01, 0x09, 0x32, 0x09, 0x35, 0x81, 0x02, 0x75, 0x10, 0x16, 0x00, 0x80, 0x26,
    0xff, 0x7f, 0x36, 0x00, 0x80, 0x46, 0xff, 0x7f, 0x05, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x95, 0x02,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x81, 0x02, 0xc0, 0x05, 0x01, 0x09, 0x01, 0xa1, 0x00, 0x95,
    0x02, 0x05, 0x01, 0x09, 0x33, 0x09, 0x34, 0x81, 0x02, 0xc0, 0x75, 0x08, 0x95, 0x06, 0x81, 0x01,
    0x06, 0x00, 0xff, 0x15, 0x00, 0x26, 0xff, 0x00, 0x85, 0x31, 0x09, 0x01, 0x75, 0x08, 0x95, 0x4d,
    0x91, 0x02, 0xc0, 0xc0,
];
/// Validated existing wire bytes. No semantic encoder is implemented here.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Report([u8; REPORT_LENGTH]);
impl Report {
    pub const NEUTRAL: Self = Self([0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
    pub fn bytes(self) -> [u8; REPORT_LENGTH] {
        self.0
    }
}
impl TryFrom<[u8; REPORT_LENGTH]> for Report {
    type Error = Error;
    fn try_from(bytes: [u8; REPORT_LENGTH]) -> Result<Self, Error> {
        let mask = u16::from_le_bytes([bytes[2], bytes[3]]);
        if bytes[..2] != [0, 20]
            || bytes[14..].iter().any(|b| *b != 0)
            || mask & 0x0800 != 0
            || mask & 3 == 3
            || mask & 12 == 12
        {
            return Err(Error::InvalidReport);
        }
        Ok(Self(bytes))
    }
}
#[cfg(any(test, all(target_os = "macos", feature = "macos-hid")))]
pub(crate) const BAD_ARGUMENT: u32 = 0xe00002c2;
#[cfg(any(test, all(target_os = "macos", feature = "macos-hid")))]
pub(crate) const NO_SPACE: u32 = 0xe00002db;
#[cfg(any(test, all(target_os = "macos", feature = "macos-hid")))]
pub(crate) const UNSUPPORTED: u32 = 0xe00002c7;
#[cfg(any(test, all(target_os = "macos", feature = "macos-hid")))]
pub(crate) fn get_report(
    cached: Report,
    kind: u32,
    id: u32,
    buffer: &mut [u8],
) -> Result<usize, u32> {
    if kind != 0 || id != u32::from(REPORT_ID) {
        return Err(UNSUPPORTED);
    }
    if buffer.len() < REPORT_LENGTH {
        return Err(NO_SPACE);
    }
    buffer[..REPORT_LENGTH].copy_from_slice(&cached.bytes());
    Ok(REPORT_LENGTH)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn bytes(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }
    #[test]
    fn existing_v2_vectors_pass_through_without_a_new_semantic_encoder() {
        let fixture: serde_json::Value =
            serde_json::from_str(include_str!("../../../../Host/fixtures/gamepad/v2.json"))
                .unwrap();
        assert_eq!(fixture["reportID"], REPORT_ID);
        assert_eq!(fixture["reportLength"], REPORT_LENGTH);
        assert_eq!(
            bytes(fixture["descriptorHex"].as_str().unwrap()),
            REPORT_DESCRIPTOR
        );
        for vector in fixture["vectors"].as_array().unwrap() {
            let raw: [u8; REPORT_LENGTH] =
                bytes(vector["hex"].as_str().unwrap()).try_into().unwrap();
            assert_eq!(Report::try_from(raw).unwrap().bytes(), raw);
        }
    }
    #[test]
    fn invalid_reports_and_get_report_capacity_type_and_id_fail_without_writes() {
        for index in [0, 1, 14, 19] {
            let mut raw = Report::NEUTRAL.bytes();
            raw[index] ^= 1;
            assert_eq!(Report::try_from(raw), Err(Error::InvalidReport));
        }
        for mask in [0x0800u16, 3, 12] {
            let mut raw = Report::NEUTRAL.bytes();
            raw[2..4].copy_from_slice(&mask.to_le_bytes());
            assert_eq!(Report::try_from(raw), Err(Error::InvalidReport));
        }
        let mut short = [99; REPORT_LENGTH - 1];
        assert_eq!(get_report(Report::NEUTRAL, 0, 0, &mut short), Err(NO_SPACE));
        assert_eq!(short, [99; REPORT_LENGTH - 1]);
        let mut full = [99; REPORT_LENGTH];
        for (kind, id) in [(1, 0), (0, 1), (2, 0)] {
            assert_eq!(
                get_report(Report::NEUTRAL, kind, id, &mut full),
                Err(UNSUPPORTED)
            );
            assert_eq!(full, [99; REPORT_LENGTH]);
        }
        assert_eq!(
            get_report(Report::NEUTRAL, 0, 0, &mut full),
            Ok(REPORT_LENGTH)
        );
        assert_eq!(full, Report::NEUTRAL.bytes());
        assert_eq!(BAD_ARGUMENT, 0xe00002c2);
    }
}
