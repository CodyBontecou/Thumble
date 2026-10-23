use super::*;
const NEUTRAL: [u8; 20] = [0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
fn bytes(hex: &str) -> Vec<u8> {
    hex.as_bytes()
        .chunks_exact(2)
        .map(|pair| u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap())
        .collect()
}
fn near(actual: f32, expected: f64) {
    assert!(
        (f64::from(actual) - expected).abs() < 3e-8,
        "{actual} != {expected}"
    );
}
#[test]
fn every_retained_v2_vector_has_explicit_candidate_semantics() {
    // Read only the fixture's literal name/hex fields, without adding a JSON
    // dependency or copying the vectors. Every retained vector must be covered.
    let fixture = include_str!("../../../../Host/fixtures/gamepad/v2.json");
    let mut name = "";
    let mut count = 0;
    for line in fixture.lines().map(str::trim) {
        if let Some(value) = line.strip_prefix("\"name\": \"") {
            name = value.strip_suffix("\",").unwrap();
        }
        if let Some(value) = line.strip_prefix("\"hex\": \"") {
            let report = bytes(value.trim_end_matches(',').strip_suffix('"').unwrap());
            let mapped = map_report(&report).unwrap();
            assert_eq!(
                mapped.axes().map(|a| a.axis),
                [Axis::X, Axis::Y, Axis::Rx, Axis::Ry, Axis::Vx, Axis::Vy]
            );
            match name {
                "south" => assert_eq!(mapped.buttons.api_mask(), 1),
                "east" => assert_eq!(mapped.buttons.api_mask(), 2),
                "west" => assert_eq!(mapped.buttons.api_mask(), 4),
                "north" => assert_eq!(mapped.buttons.api_mask(), 8),
                "left shoulder" => assert_eq!(mapped.buttons.api_mask(), 16),
                "right shoulder" => assert_eq!(mapped.buttons.api_mask(), 32),
                "select" => assert_eq!(mapped.buttons.api_mask(), 64),
                "start" => assert_eq!(mapped.buttons.api_mask(), 128),
                "left stick press" => assert_eq!(mapped.buttons.api_mask(), 256),
                "right stick press" => assert_eq!(mapped.buttons.api_mask(), 512),
                "home" => assert_eq!(mapped.buttons.api_mask(), 1024),
                "up" => assert_eq!(mapped.hat, Hat::North),
                "up right" => assert_eq!(mapped.hat, Hat::NorthEast),
                "right" => assert_eq!(mapped.hat, Hat::East),
                "down right" => assert_eq!(mapped.hat, Hat::SouthEast),
                "down" => assert_eq!(mapped.hat, Hat::South),
                "down left" => assert_eq!(mapped.hat, Hat::SouthWest),
                "left" => assert_eq!(mapped.hat, Hat::West),
                "up left" => assert_eq!(mapped.hat, Hat::NorthWest),
                "neutral" | "opposed vertical" | "opposed horizontal" | "all dpad directions" => {
                    assert_eq!(mapped, map_report(&NEUTRAL).unwrap())
                }
                "sticks full scale" | "sticks clamp" => {
                    assert_eq!(mapped.axis(Axis::X), 0.0);
                    assert_eq!(mapped.axis(Axis::Y), 1.0);
                    assert_eq!(mapped.axis(Axis::Rx), 1.0);
                    assert_eq!(mapped.axis(Axis::Ry), 0.0);
                }
                "sticks half scale" => {
                    assert_eq!(mapped.axis(Axis::X), 0.25);
                    assert_eq!(mapped.axis(Axis::Y), 0.75);
                    near(mapped.axis(Axis::Rx), 0.750007629627369);
                    near(mapped.axis(Axis::Ry), 0.249992370372631);
                }
                "left trigger independent" | "digital left trigger also actuates axis" => {
                    assert_eq!(mapped.axis(Axis::Vx), 1.0);
                    assert_eq!(mapped.axis(Axis::Vy), 0.0);
                }
                "right trigger independent"
                | "digital right trigger also actuates axis"
                | "triggers clamp" => {
                    assert_eq!(mapped.axis(Axis::Vx), 0.0);
                    assert_eq!(mapped.axis(Axis::Vy), 1.0);
                }
                "triggers together" => {
                    assert_eq!(mapped.axis(Axis::Vx), 1.0);
                    assert_eq!(mapped.axis(Axis::Vy), 1.0);
                }
                "trigger midpoint rounds away from zero" => {
                    near(mapped.axis(Axis::Vx), 128.0 / 255.0);
                    near(mapped.axis(Axis::Vy), 128.0 / 255.0);
                }
                "mixed state" => {
                    assert_eq!(mapped.buttons.api_mask(), 129);
                    assert_eq!(mapped.hat, Hat::NorthEast);
                    assert_eq!(mapped.axis(Axis::X), 0.0);
                    assert_eq!(mapped.axis(Axis::Y), 0.75);
                    assert_eq!(mapped.axis(Axis::Rx), 1.0);
                    near(mapped.axis(Axis::Ry), 0.249992370372631);
                    near(mapped.axis(Axis::Vx), 64.0 / 255.0);
                    near(mapped.axis(Axis::Vy), 191.0 / 255.0);
                }
                _ => panic!("new retained vector needs semantic coverage: {name}"),
            }
            count += 1;
        }
    }
    assert_eq!(count, 34);
}
#[test]
fn all_signed_axis_values_are_finite_strictly_monotone_and_have_no_deadzone() {
    let mut previous = [-1.0; 4];
    for value in i16::MIN..=i16::MAX {
        let mut report = NEUTRAL;
        for offset in [6, 8, 10, 12] {
            report[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
        }
        let mapped = map_report(&report).unwrap();
        for (index, axis) in [Axis::X, Axis::Y, Axis::Rx, Axis::Ry].iter().enumerate() {
            let raw = mapped.axis(*axis);
            assert!(raw.is_finite() && (0.0..=1.0).contains(&raw));
            let ascending = if index % 2 == 1 { 1.0 - raw } else { raw };
            assert!(ascending > previous[index]);
            previous[index] = ascending;
            if value == 0 {
                assert_eq!(raw, 0.5);
            }
        }
    }
}
#[test]
fn all_trigger_byte_pairs_stay_independent_without_deadzone() {
    for left in 0..=255u8 {
        for right in 0..=255u8 {
            let mut report = NEUTRAL;
            report[4] = left;
            report[5] = right;
            let mapped = map_report(&report).unwrap();
            near(mapped.axis(Axis::Vx), f64::from(left) / 255.0);
            near(mapped.axis(Axis::Vy), f64::from(right) / 255.0);
        }
    }
}
#[test]
fn malformed_reports_and_unrepresentable_hat_never_get_repaired() {
    for len in [0, 1, 19, 21, 64] {
        assert_eq!(map_report(&vec![0; len]), Err(MappingError::InvalidLength));
    }
    for (offset, value) in [(0, 1), (1, 19)] {
        let mut r = NEUTRAL;
        r[offset] = value;
        assert_eq!(map_report(&r), Err(MappingError::InvalidHeader));
    }
    let mut reserved = NEUTRAL;
    reserved[3] = 0x08;
    assert_eq!(map_report(&reserved), Err(MappingError::ReservedButtonBit));
    for offset in 14..20 {
        let mut r = NEUTRAL;
        r[offset] = 1;
        assert_eq!(map_report(&r), Err(MappingError::ReservedBytes));
    }
    for mask in [3, 7, 11, 12, 13, 14, 15] {
        let mut r = NEUTRAL;
        r[2] = mask;
        assert_eq!(map_report(&r), Err(MappingError::UnsupportedDpad));
    }
}
#[test]
fn static_doctor_cannot_claim_a_driver_or_gamepad() {
    let info = capability();
    assert!(!info.sdk_linked && !info.backend_available && !info.gameplay_verified);
    assert_eq!(info.driver, DriverVerification::NotInspected);
    assert_eq!(info.reason, "mapping_only_no_sdk_or_driver_probe");
    assert_eq!(info.profile_id, "xbox-360-wired");
}

#[test]
fn every_supported_button_can_be_held_together_without_reusing_hat_bits() {
    let mut report = NEUTRAL;
    report[2..4].copy_from_slice(&0xf7f9u16.to_le_bytes());
    let mapped = map_report(&report).unwrap();
    assert_eq!(mapped.buttons.api_mask(), 0x7ff);
    assert_eq!(mapped.hat, Hat::NorthEast);
    for button in [
        Button::A,
        Button::B,
        Button::X,
        Button::Y,
        Button::LeftBumper,
        Button::RightBumper,
        Button::Back,
        Button::Start,
        Button::LeftStick,
        Button::RightStick,
        Button::Guide,
    ] {
        assert!(mapped.buttons.contains(button));
    }
}
