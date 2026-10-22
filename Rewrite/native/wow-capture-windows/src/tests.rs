use super::*;
use std::collections::VecDeque;
use std::io::Cursor;
use thumble_rewrite_windows_optical::Panel;
fn request(source: u32, generation: u64, receipt: u64) -> wire::Request {
    wire::Request::decode(format!(r#"{{"version":1,"command":"wow-capture","source":{source},"generation":"{generation}","receipt":"{receipt}"}}"#).as_bytes()).unwrap()
}
fn identity() -> Identity {
    Identity {
        process: WindowIdentity {
            handle: 0x100000001,
            process_id: 25,
            process_started: 44,
            executable_file_id: 99,
        },
        executable: r"C:\Games\_classic_era_\WowClassic.exe".into(),
        volume: 1,
        file_size: 500,
        modified: 77,
        window_rect: [0, 0, 900, 700],
        client_rect: [0, 0, 884, 662],
        frame_rect: [8, 0, 892, 692],
        dpi: 144,
    }
}
struct Fake {
    snapshots: VecDeque<Result<Vec<Identity>, Status>>,
    selected: Identity,
    captures: usize,
    size: (u32, u32),
    panel: bool,
}
impl Default for Fake {
    fn default() -> Self {
        Self {
            snapshots: VecDeque::new(),
            selected: identity(),
            captures: 0,
            size: (884, 692),
            panel: false,
        }
    }
}
impl Provider for Fake {
    fn inventory(&mut self) -> Result<Vec<Identity>, Status> {
        self.snapshots
            .pop_front()
            .unwrap_or_else(|| Ok(vec![self.selected.clone()]))
    }
    fn capture(&mut self, expected: &Identity) -> Result<Capture, Status> {
        assert_eq!(expected, &self.selected);
        self.captures += 1;
        Ok(Capture {
            panel: self.panel.then(|| Panel {
                frame: [0; 512],
                atlas_rgba: vec![0; 262144],
            }),
            width: self.size.0,
            height: self.size.1,
        })
    }
}
#[test]
fn strict_request_codec_bounds_types_duplicates_and_canonical_receipts() {
    let good=br#"{"version":1,"command":"wow-capture","source":4294967295,"generation":"18446744073709551615","receipt":"1"}"#;
    assert!(wire::Request::decode(good).is_ok());
    for text in [
        r#"{"version":1,"command":"wow-capture","source":1,"generation":"01","receipt":"1"}"#,
        r#"{"version":1,"command":"wow-capture","source":1,"generation":"1","receipt":"0"}"#,
        r#"{"version":1,"command":"wow-capture","source":1,"generation":"1","receipt":"18446744073709551616"}"#,
        r#"{"version":1,"command":"wow-capture","source":1,"generation":"1","receipt":"1","source":2}"#,
        r#"{"version":1,"command":"wow-capture","source":1.0,"generation":"1","receipt":"1"}"#,
        r#"{"version":1,"command":"wow-capture","source":1,"generation":"1","receipt":"1","hwnd":1}"#,
    ] {
        assert!(wire::Request::decode(text.as_bytes()).is_err());
    }
    assert!(wire::Request::decode(&[b' '; 257]).is_err());
    assert!(wire::Request::decode(&[255]).is_err());
}
#[test]
fn framed_reader_rejects_oversize_before_body_allocation_and_truncation() {
    for bytes in [
        vec![0xff; 4],
        vec![0, 0, 1, 1],
        vec![0, 0, 0, 0],
        vec![0, 0],
        vec![0, 0, 0, 2, 123],
    ] {
        assert!(wire::read_frame(&mut Cursor::new(bytes)).is_err());
    }
    assert_eq!(wire::read_frame(&mut Cursor::new([])).unwrap(), None);
    let mut frames = vec![];
    wire::write_frame(&mut frames, b"first").unwrap();
    wire::write_frame(&mut frames, b"second").unwrap();
    let mut cursor = Cursor::new(frames);
    assert_eq!(wire::read_frame(&mut cursor).unwrap().unwrap(), b"first");
    assert_eq!(wire::read_frame(&mut cursor).unwrap().unwrap(), b"second");
    assert!(wire::read_frame(&mut cursor).unwrap().is_none());
}
#[test]
fn duplicate_or_new_context_invalidates_child_without_any_new_capture() {
    for changed in [request(1, 1, 1), request(2, 1, 2), request(1, 2, 2)] {
        let (mut session, mut fake) = (Session::default(), Fake::default());
        assert!(matches!(
            session.perform(&request(1, 1, 1), &mut fake),
            Err(Status::PanelNotVisible)
        ));
        assert!(matches!(
            session.perform(&changed, &mut fake),
            Err(Status::Unavailable)
        ));
        assert!(matches!(
            session.perform(&request(1, 1, 3), &mut fake),
            Err(Status::Unavailable)
        ));
        assert_eq!(fake.captures, 1);
    }
}
#[test]
fn preselection_ambiguity_never_requests_pixels_and_window_loss_cannot_retarget() {
    let (mut session, mut fake) = (Session::default(), Fake::default());
    fake.snapshots.push_back(Ok(vec![identity(), identity()]));
    assert!(matches!(
        session.perform(&request(1, 1, 1), &mut fake),
        Err(Status::MultipleGameWindows)
    ));
    assert_eq!(fake.captures, 0);
    assert!(matches!(
        session.perform(&request(1, 1, 2), &mut fake),
        Err(Status::PanelNotVisible)
    ));
    fake.snapshots.push_back(Ok(vec![]));
    assert!(matches!(
        session.perform(&request(1, 1, 3), &mut fake),
        Err(Status::GameNotVisible)
    ));
    assert!(matches!(
        session.perform(&request(1, 1, 4), &mut fake),
        Err(Status::Unavailable)
    ));
    assert_eq!(fake.captures, 1);
}
#[test]
fn each_private_binding_change_during_acquisition_invalidates_all_future_receipts() {
    let mut changed = vec![];
    for field in 0..13 {
        let mut value = identity();
        match field {
            0 => value.process.handle += 1,
            1 => value.process.process_id += 1,
            2 => value.process.process_started += 1,
            3 => value.process.executable_file_id += 1,
            4 => value.volume += 1,
            5 => value.file_size += 1,
            6 => value.modified += 1,
            7 => value.executable.push('x'),
            8 => value.window_rect[0] += 1,
            9 => value.client_rect[2] += 1,
            10 => value.frame_rect[2] += 1,
            11 => value.dpi += 1,
            _ => value.process.handle = 1,
        };
        changed.push(value);
    }
    for value in changed {
        let (mut session, mut fake) = (Session::default(), Fake::default());
        fake.snapshots
            .extend([Ok(vec![identity()]), Ok(vec![value])]);
        assert!(matches!(
            session.perform(&request(1, 1, 1), &mut fake),
            Err(Status::Unavailable)
        ));
        assert!(matches!(
            session.perform(&request(1, 1, 2), &mut fake),
            Err(Status::Unavailable)
        ));
        assert_eq!(fake.captures, 1);
    }
}
#[test]
fn resized_gpu_content_is_terminal_and_same_context_can_never_adopt_new_size() {
    let (mut session, mut fake) = (Session::default(), Fake::default());
    let _ = session.perform(&request(1, 1, 1), &mut fake);
    fake.size.0 += 1;
    assert!(matches!(
        session.perform(&request(1, 1, 2), &mut fake),
        Err(Status::Unavailable)
    ));
    fake.size.0 -= 1;
    assert!(matches!(
        session.perform(&request(1, 1, 3), &mut fake),
        Err(Status::Unavailable)
    ));
}
#[test]
fn eligibility_is_exact_retained_client_root_metadata_policy_not_basename_only() {
    assert!(eligible_path(
        r"C:\Games\_classic_era_\WowClassic.exe",
        "World of Warcraft",
        "WowClassic.exe"
    ));
    assert!(eligible_path(
        r"C:\Games\_forever_\Wow.exe",
        "World of Warcraft",
        "WoW.exe"
    ));
    for path in [
        r"C:\Games\_retail_\Wow.exe",
        r"C:\Games\_forever_copy\Wow.exe",
        r"C:\Other\Wow.exe",
        r"relative\_forever_\Wow.exe",
        r"C:\Games\_forever_\..\Other\Wow.exe",
    ] {
        assert!(!eligible_path(path, "World of Warcraft", "Wow.exe"));
    }
    assert!(!eligible_path(
        r"C:\Games\_forever_\Wow.exe",
        "Other app",
        "Wow.exe"
    ));
    assert!(!eligible_path(
        r"C:\Games\_forever_\not-wow.exe",
        "World of Warcraft",
        "Wow.exe"
    ));
}
#[test]
fn framed_reply_contains_only_receipt_frame_and_png_not_native_identity() {
    let request = request(1, 1, 1);
    let panel = Panel {
        frame: [23; 512],
        atlas_rgba: vec![255; 262144],
    };
    let bytes = wire::reply(&request, Ok(panel)).unwrap();
    assert!(bytes.len() < wire::REPLY_LIMIT);
    let value: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value.as_object().unwrap().len(), 8);
    assert_eq!(value["source"], 1);
    assert_eq!(value["receipt"], "1");
    assert_eq!(value["kind"], "frame");
    assert!(value["atlasPNGBase64"].is_string());
    assert!(value.get("atlasPngBase64").is_none());
    assert_eq!(value["frameBase64"].as_str().unwrap().len(), 684);
    let text = String::from_utf8(bytes).unwrap();
    assert!(!text.contains("executable"));
    assert!(!text.contains("handle"));
    assert!(!text.contains("process"));
}
#[test]
fn png_is_bounded_fixed_rgba_and_rejects_wrong_input_lengths() {
    for length in [0, 262143, 262145] {
        assert!(png::encode(&vec![0; length]).is_err());
    }
    let bytes = png::encode(&vec![0; 262144]).unwrap();
    assert_eq!(&bytes[..8], b"\x89PNG\r\n\x1a\n");
    assert!(bytes.len() < 2 * 1024 * 1024);
    assert_eq!(&bytes[12..16], b"IHDR");
    assert_eq!(u32::from_be_bytes(bytes[16..20].try_into().unwrap()), 256);
    assert_eq!(bytes[25], 6);
}
