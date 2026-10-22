use super::*;
fn frame() -> [u8; 512] {
    let fixture = include_str!("../../../packages/fixtures/wow-live-v1.json");
    let after = &fixture[fixture.find("\"frames\"").unwrap()..];
    let array = &after[after.find('[').unwrap() + 1..];
    let text = &array[array.find('"').unwrap() + 1..];
    let text = &text[..text.find('"').unwrap()];
    let mut out = [0; 512];
    assert_eq!(text.len(), 1024);
    for (i, pair) in text.as_bytes().chunks_exact(2).enumerate() {
        out[i] = u8::from_str_radix(std::str::from_utf8(pair).unwrap(), 16).unwrap();
    }
    out
}
fn image(frame: &[u8; 512], scale: f64) -> Vec<u8> {
    let mut bytes = vec![0; 1024 * 1100 * 4];
    let mut rect = |x: f64, y: f64, w: f64, h: f64, p: [u8; 4]| {
        for row in 23 + (y * scale).floor() as usize..23 + ((y + h) * scale).floor() as usize {
            for col in 17 + (x * scale).floor() as usize..17 + ((x + w) * scale).floor() as usize {
                bytes[(row * 1024 + col) * 4..][..4].copy_from_slice(&p);
            }
        }
    };
    for i in 0..4 {
        let p = if i % 2 == 0 {
            [0, 255, 255, 255]
        } else {
            [255, 0, 255, 255]
        };
        rect((i * 6) as f64, 0.0, 6.0, 6.0, p);
        rect((240 + i * 4) as f64, 0.0, 4.0, 6.0, p);
    }
    for i in 0..16 {
        let n = i * 17;
        rect((24 + i as usize * 6) as f64, 0.0, 6.0, 6.0, [n, n, n, 255]);
    }
    for i in 0..1024 {
        let n = if i % 2 == 0 {
            frame[i / 2] >> 4
        } else {
            frame[i / 2] & 15
        } * 17;
        rect(
            (i % 64 * 3) as f64,
            (8 + i / 64 * 3) as f64,
            3.0,
            3.0,
            [n, n, n, 255],
        );
    }
    for i in 0..64 {
        rect(
            (i % 8 * 32) as f64,
            (64 + i / 8 * 32) as f64,
            32.0,
            32.0,
            [i as u8, 120, 240, 255],
        );
    }
    bytes
}
fn raster(bytes: &[u8]) -> Raster<'_> {
    Raster {
        width: 1024,
        height: 1100,
        stride: 4096,
        channels: ChannelOrder::Rgba,
        orientation: Orientation::TopLeft,
        bytes,
    }
}
#[test]
fn retained_ten_scales_decode_same_frame_and_atlas_corners() {
    let expected = frame();
    for scale in [0.75, 0.853, 1.0, 1.1, 1.28, 1.5, 1.6, 2.0, 2.557, 3.0] {
        let pixels = image(&expected, scale);
        let panel = decode_panel(raster(&pixels)).unwrap().unwrap();
        assert_eq!(panel.frame, expected, "{scale}");
        assert_eq!(panel.atlas_rgba.len(), 262144);
        for (x, y, index) in [(0, 0, 0), (255, 0, 7), (0, 255, 56), (255, 255, 63)] {
            assert_eq!(
                &panel.atlas_rgba[(y * 256 + x) * 4..][..4],
                &[index, 120, 240, 255],
                "{scale} {x},{y}"
            );
        }
    }
}
#[test]
fn bgra_bottom_up_padding_matches_rgba_without_aliasing_input() {
    let expected = frame();
    let mut pixels = image(&expected, 1.28);
    let reference = decode_panel(raster(&pixels)).unwrap().unwrap();
    let stride = 4096 + 16;
    let mut padded = vec![17; stride * 1100];
    for y in 0..1100 {
        for x in 0..1024 {
            let a = (y * 1024 + x) * 4;
            let b = (1099 - y) * stride + x * 4;
            padded[b..b + 4].copy_from_slice(&[
                pixels[a + 2],
                pixels[a + 1],
                pixels[a],
                pixels[a + 3],
            ]);
        }
    }
    let panel = decode_panel(Raster {
        stride,
        bytes: &padded,
        channels: ChannelOrder::Bgra,
        orientation: Orientation::BottomLeft,
        ..raster(&pixels)
    })
    .unwrap()
    .unwrap();
    assert_eq!(panel.frame, reference.frame);
    assert_eq!(panel.atlas_rgba, reference.atlas_rgba);
    pixels.fill(0);
    padded.fill(0);
    assert_eq!(panel.atlas_rgba[0], 0);
    assert_eq!(panel.atlas_rgba[1], 120);
}
#[test]
fn corrupt_clipped_hidden_and_invalid_shapes_fail_without_partial_panel() {
    let mut corrupt = frame();
    corrupt[100] ^= 1;
    let bytes = image(&corrupt, 1.0);
    assert!(decode_panel(raster(&bytes)).unwrap().is_none());
    let valid = image(&frame(), 1.0);
    let clipped = &valid[..4096 * 200];
    assert!(decode_panel(Raster {
        height: 200,
        bytes: clipped,
        ..raster(clipped)
    })
    .unwrap()
    .is_none());
    assert!(matches!(
        decode_panel(Raster {
            width: 0,
            ..raster(&[])
        }),
        Err(Error::InvalidRaster)
    ));
    assert!(matches!(
        decode_panel(Raster {
            width: 8193,
            ..raster(&[])
        }),
        Err(Error::InvalidRaster)
    ));
    assert!(matches!(
        decode_panel(Raster {
            stride: usize::MAX,
            ..raster(&[])
        }),
        Err(Error::InvalidRaster)
    ));
    assert!(matches!(
        decode_panel(raster(&valid[..valid.len() - 1])),
        Err(Error::InvalidRaster)
    ));
    let black = vec![0; 4096 * 1100];
    assert!(decode_panel(raster(&black)).unwrap().is_none());
}
fn candidate() -> WindowCandidate {
    WindowCandidate {
        identity: WindowIdentity {
            handle: 1u64 << 40,
            process_id: 42,
            process_started: 7,
            executable_file_id: 9,
        },
        eligible_client: true,
        visible: true,
        minimized: false,
        top_level: true,
        width: 1024,
        height: 1100,
    }
}
#[test]
fn strict_inventory_and_private_pointer_width_identity_never_truncate_to_source() {
    let c = candidate();
    assert_eq!(select_window(&[c]).unwrap(), c.identity);
    assert_eq!(select_window(&[c, c]), Err(Error::MultipleGameWindows));
    assert_eq!(select_window(&[c; 129]), Err(Error::InvalidInventory));
    for c in [
        WindowCandidate {
            eligible_client: false,
            ..c
        },
        WindowCandidate {
            visible: false,
            ..c
        },
        WindowCandidate {
            minimized: true,
            ..c
        },
        WindowCandidate {
            top_level: false,
            ..c
        },
        WindowCandidate { width: 319, ..c },
    ] {
        assert_eq!(select_window(&[c]), Err(Error::GameNotVisible));
    }
    assert_eq!(
        select_window(&[WindowCandidate { width: 8193, ..c }]),
        Err(Error::InvalidInventory)
    );
    assert_eq!(
        select_window(&[WindowCandidate {
            identity: WindowIdentity {
                process_id: 0,
                ..c.identity
            },
            ..c
        }]),
        Err(Error::InvalidInventory)
    );
    let r = Receipt {
        source: 13,
        generation: 3,
        receipt: 8,
    };
    let binding = CaptureBinding::new(r, c.identity).unwrap();
    let pixels = image(&frame(), 1.0);
    let decoded = binding
        .decode(c.identity, raster(&pixels))
        .unwrap()
        .unwrap();
    assert_eq!(decoded.receipt, r);
    for identity in [
        WindowIdentity {
            handle: c.identity.handle + 1,
            ..c.identity
        },
        WindowIdentity {
            process_id: 43,
            ..c.identity
        },
        WindowIdentity {
            process_started: 8,
            ..c.identity
        },
        WindowIdentity {
            executable_file_id: 10,
            ..c.identity
        },
    ] {
        assert!(matches!(
            binding.decode(identity, raster(&pixels)),
            Err(Error::SourceChanged)
        ));
    }
    for bad in [
        Receipt { source: 0, ..r },
        Receipt { generation: 0, ..r },
        Receipt { receipt: 0, ..r },
    ] {
        assert!(matches!(
            CaptureBinding::new(bad, c.identity),
            Err(Error::InvalidReceipt)
        ));
    }
}
#[test]
fn adversarial_discovery_hits_same_fixed_sample_budget() {
    let (w, h) = (8192, 64);
    let mut b = vec![0; w * h * 4];
    for y in (0..h).step_by(2) {
        for marker in 0..4 {
            let color = if marker % 2 == 0 {
                [0, 255, 255, 255]
            } else {
                [255, 0, 255, 255]
            };
            for x in 17 + marker * 6..17 + (marker + 1) * 6 {
                b[(y * w + x) * 4..][..4].copy_from_slice(&color);
            }
        }
        for x in 200..w {
            b[(y * w + x) * 4..][..4].copy_from_slice(&[0, 255, 255, 255]);
        }
    }
    let result = decode_panel(Raster {
        width: w as u32,
        height: h as u32,
        stride: w * 4,
        channels: ChannelOrder::Rgba,
        orientation: Orientation::TopLeft,
        bytes: &b,
    });
    assert!(matches!(result, Err(Error::ScanLimit)));
}
