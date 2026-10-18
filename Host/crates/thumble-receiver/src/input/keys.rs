/// Physical key identity, using Linux input codes and Windows Set-1 scan codes.
/// Bit 8 marks an E0-prefixed Windows scan code. Layout interpretation remains
/// with the destination OS. Command maps to Super/Windows, Option to Alt.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct NativeKey {
    pub linux: u16,
    pub scan: u16,
    pub modifier: bool,
}

pub fn key(mac: u16) -> Option<NativeKey> {
    let (linux, scan) = match mac {
        0 => (30, 0x1e),
        1 => (31, 0x1f),
        2 => (32, 0x20),
        3 => (33, 0x21),
        4 => (35, 0x23),
        5 => (34, 0x22),
        6 => (44, 0x2c),
        7 => (45, 0x2d),
        8 => (46, 0x2e),
        9 => (47, 0x2f),
        11 => (48, 0x30),
        12 => (16, 0x10),
        13 => (17, 0x11),
        14 => (18, 0x12),
        15 => (19, 0x13),
        16 => (21, 0x15),
        17 => (20, 0x14),
        18 => (2, 2),
        19 => (3, 3),
        20 => (4, 4),
        21 => (5, 5),
        22 => (7, 7),
        23 => (6, 6),
        24 => (13, 13),
        25 => (10, 10),
        26 => (8, 8),
        27 => (12, 12),
        28 => (9, 9),
        29 => (11, 11),
        30 => (27, 27),
        31 => (24, 24),
        32 => (22, 22),
        33 => (26, 26),
        34 => (23, 23),
        35 => (25, 25),
        36 => (28, 28),
        37 => (38, 38),
        38 => (36, 36),
        39 => (40, 40),
        40 => (37, 37),
        41 => (39, 39),
        42 => (43, 43),
        43 => (51, 51),
        44 => (53, 53),
        45 => (49, 49),
        46 => (50, 50),
        47 => (52, 52),
        48 => (15, 15),
        49 => (57, 57),
        50 => (41, 41),
        51 => (14, 14),
        53 => (1, 1),
        54 => (126, 0x15c),
        55 => (125, 0x15b),
        56 => (42, 42),
        57 => (58, 58),
        58 => (56, 56),
        59 => (29, 29),
        60 => (54, 54),
        61 => (100, 0x138),
        62 => (97, 0x11d),
        // Fn has no portable injectable Set-1 equivalent; reject it explicitly.
        64 => (187, 0x68),
        65 => (83, 83),
        67 => (55, 55),
        69 => (78, 78),
        71 => (69, 0x145),
        75 => (98, 0x135),
        76 => (96, 0x11c),
        78 => (74, 74),
        81 => (117, 0x59),
        82 => (82, 82),
        83 => (79, 79),
        84 => (80, 80),
        85 => (81, 81),
        86 => (75, 75),
        87 => (76, 76),
        88 => (77, 77),
        89 => (71, 71),
        91 => (72, 72),
        92 => (73, 73),
        96 => (63, 63),
        97 => (64, 64),
        98 => (65, 65),
        99 => (61, 61),
        100 => (66, 66),
        101 => (67, 67),
        103 => (87, 87),
        105 => (183, 0x64),
        106 => (186, 0x67),
        107 => (184, 0x65),
        109 => (68, 68),
        111 => (88, 88),
        113 => (185, 0x66),
        114 => (110, 0x152),
        115 => (102, 0x147),
        116 => (104, 0x149),
        117 => (111, 0x153),
        118 => (62, 62),
        119 => (107, 0x14f),
        120 => (60, 60),
        121 => (109, 0x151),
        122 => (59, 59),
        123 => (105, 0x14b),
        124 => (106, 0x14d),
        125 => (108, 0x150),
        126 => (103, 0x148),
        _ => return None,
    };
    Some(NativeKey {
        linux,
        scan,
        modifier: matches!(mac,54..=56 | 58..=62),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn translates_physical_codes_and_extended_keys() {
        assert_eq!(key(0).unwrap().linux, 30);
        assert_eq!(key(0).unwrap().scan, 0x1e);
        assert_eq!(key(123).unwrap().scan, 0x14b);
        assert_ne!(key(36), key(76));
        for code in [10, 52, 63, 65535] {
            assert!(key(code).is_none());
        }
    }
    #[test]
    fn all_supported_semantic_keys_have_a_mapping_except_fn() {
        for code in 0..=126 {
            if thumble_core::semantic_key_name(code).is_some() && code != 63 {
                assert!(key(code).is_some(), "{code}");
            }
        }
    }
}
