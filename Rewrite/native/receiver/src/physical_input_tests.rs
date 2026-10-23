//! Synthetic output status and encrypted packet tests; never creates an OS device.
use super::*;
use crate::{
    gamepad::NEUTRAL,
    generated::GamepadState,
    runtime::{Command, OutputStatus},
};
use std::sync::atomic::AtomicUsize;
struct Root(std::path::PathBuf);
impl Root {
    fn new() -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = Self(std::env::temp_dir().canonicalize().unwrap().join(format!(
            "thumble-physical-input-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::SeqCst)
        )));
        security::directory(&root.0).unwrap();
        root
    }
}
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
struct Admission(Arc<AtomicBool>);
impl OutputStatus for Admission {
    fn backend(&self) -> &'static str {
        "macos-hid"
    }
    fn enabled(&self, generation: u64) -> bool {
        generation == 1 && self.0.load(Ordering::SeqCst)
    }
}
struct FakeOutput {
    admitted: Arc<AtomicBool>,
    report: [u8; 20],
}
impl Output for FakeOutput {
    fn submit(&mut self, report: [u8; 20], _: &'static str) -> Result<(), &'static str> {
        self.report = report;
        Ok(())
    }
    fn status(&self) -> Option<Arc<dyn OutputStatus>> {
        Some(Arc::new(Admission(self.admitted.clone())))
    }
}
fn active() -> (PacketRuntime, FakeOutput) {
    let mut runtime = PacketRuntime::default();
    let mut sink = FakeOutput {
        admitted: Arc::new(AtomicBool::new(true)),
        report: NEUTRAL,
    };
    runtime
        .apply_owner(
            Command::Activate {
                generation: "1".into(),
                revision: "1".into(),
                profile_id: "profile-a".into(),
                session_id: "owner".into(),
                lease_ms: 750,
                input_ttl_ms: 350,
            },
            0,
            &mut sink,
        )
        .unwrap();
    (runtime, sink)
}
fn grant_payload() -> Vec<u8> {
    let mut bytes = vec![0xab; 16];
    bytes.extend_from_slice(&1u64.to_le_bytes());
    bytes.extend_from_slice(&1u64.to_le_bytes());
    bytes.extend_from_slice(&1000u32.to_le_bytes());
    bytes
}
fn sender(bytes: &[u8]) -> PacketSender {
    PacketSender::new(
        PacketGrant::new(
            bytes[..32].try_into().unwrap(),
            bytes[32..48].try_into().unwrap(),
            bytes[48..52].try_into().unwrap(),
            1,
        )
        .unwrap(),
        PACKET_LIMIT,
    )
    .unwrap()
}
fn packet(bytes: &[u8], sender: &mut PacketSender, state: &GamepadState) -> Vec<u8> {
    let mut packet = vec![0xab; 16];
    packet.extend_from_slice(&bytes[32..48]);
    packet.extend_from_slice(&sender.seal(state).unwrap());
    packet
}
#[test]
fn old_operations_stay_recording_only_and_physical_operations_require_actual_admission() {
    let root = Root::new();
    let mut server = Server::bind(&root.0).unwrap();
    let (mut runtime, mut output) = active();
    for op in [STATUS, SAVED_STATUS, GRANT, PACKET, RELEASE, ROTATE] {
        assert_eq!(
            server.apply(op, &[], &mut runtime, 1, &mut output),
            Err("native_input_backend_not_supported")
        );
    }
    let status = server
        .apply(OUTPUT_STATUS, &[], &mut runtime, 1, &mut output)
        .unwrap();
    assert_eq!(status.len(), 20);
    assert_eq!(&status[18..], &[1, 1]);
    let grant = server
        .apply(
            PHYSICAL_GRANT,
            &grant_payload(),
            &mut runtime,
            1,
            &mut output,
        )
        .unwrap();
    let mut sender = sender(&grant);
    let held:GamepadState=serde_json::from_value(serde_json::json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":0,"rightTrigger":0})).unwrap();
    let bytes = packet(&grant, &mut sender, &held);
    server
        .apply(PHYSICAL_PACKET, &bytes, &mut runtime, 2, &mut output)
        .unwrap();
    assert_eq!(output.report, held.report());
    output.admitted.store(false, Ordering::SeqCst);
    assert_eq!(
        server.apply(PHYSICAL_PACKET, &bytes, &mut runtime, 3, &mut output),
        Err("native_physical_output_not_admitted")
    );
    server
        .apply(PHYSICAL_RELEASE, &bytes[..32], &mut runtime, 3, &mut output)
        .unwrap();
    assert_eq!(output.report, NEUTRAL);
    assert!(!runtime.snapshot().active);
}
#[test]
fn physical_grant_and_rotation_cannot_fallback_to_recording() {
    struct Recording;
    impl Output for Recording {
        fn submit(&mut self, _: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            Ok(())
        }
    }
    let root = Root::new();
    let mut server = Server::bind(&root.0).unwrap();
    let mut runtime = PacketRuntime::default();
    let mut sink = Recording;
    for op in [
        PHYSICAL_GRANT,
        PHYSICAL_PACKET,
        PHYSICAL_RELEASE,
        PHYSICAL_ROTATE,
    ] {
        assert_eq!(
            server.apply(op, &[], &mut runtime, 0, &mut sink),
            Err("native_input_backend_not_supported")
        );
    }
}
#[test]
fn v9_grant_matches_shared_sdk_fixture_and_old_grant_shape_is_unchanged() {
    let fixture: serde_json::Value = serde_json::from_str(include_str!(
        "../../../packages/fixtures/physical-input-control-v9.json"
    ))
    .unwrap();
    let mut grant = NativeGrant {
        key: [0x44; 32],
        session: [0x33; 16],
        prefix: [0x55; 4],
        generation: 1,
        revision: 1,
        lifetime_ms: 1000,
        binding: GrantRef {
            connection: [0xab; 16],
            session: [0x33; 16],
        },
        physical: true,
    };
    assert_eq!(
        grant.control_reply(Some(43210), None).unwrap(),
        fixture["grant"]
    );
    grant.physical = false;
    let legacy: serde_json::Value = serde_json::from_str(include_str!(
        "../../../packages/fixtures/native-input-control-v5.json"
    ))
    .unwrap();
    assert_eq!(
        grant.control_reply(Some(43210), None).unwrap(),
        legacy["grant"]
    );
    grant.physical = true;
    grant.session = [0x66; 16];
    grant.key = [0x77; 32];
    grant.prefix = [0x88; 4];
    grant.binding.session = grant.session;
    assert_eq!(
        grant
            .control_reply(Some(43210), Some((&"33".repeat(16), 100000)))
            .unwrap(),
        fixture["renewal"]
    );
}
#[test]
fn physical_rotation_preserves_epochs_and_rejects_previous_source_after_commit() {
    let root = Root::new();
    let mut server = Server::bind(&root.0).unwrap();
    let (mut runtime, mut output) = active();
    let grant = server
        .apply(
            PHYSICAL_GRANT,
            &grant_payload(),
            &mut runtime,
            1,
            &mut output,
        )
        .unwrap();
    let mut first = sender(&grant);
    let held:GamepadState=serde_json::from_value(serde_json::json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":0,"rightTrigger":0})).unwrap();
    let bytes = packet(&grant, &mut first, &held);
    server
        .apply(PHYSICAL_PACKET, &bytes, &mut runtime, 2, &mut output)
        .unwrap();
    let mut rotate = bytes[..32].to_vec();
    rotate.extend_from_slice(&grant_payload()[16..]);
    let next = server
        .apply(PHYSICAL_ROTATE, &rotate, &mut runtime, 3, &mut output)
        .unwrap();
    assert_ne!(&grant[32..48], &next[32..48]);
    let mut successor = sender(&next);
    let next_packet = packet(&next, &mut successor, &held);
    server
        .apply(PHYSICAL_PACKET, &next_packet, &mut runtime, 4, &mut output)
        .unwrap();
    assert_eq!(output.report, held.report());
    assert_eq!(runtime.snapshot().generation, "1");
    assert!(server
        .apply(
            PHYSICAL_PACKET,
            &packet(&grant, &mut first, &held),
            &mut runtime,
            5,
            &mut output
        )
        .is_err());
}
#[test]
fn real_native_ipc_physical_disconnect_retires_only_its_owned_source() {
    let root = Root::new();
    let mut server = Server::bind(&root.0).unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let (released, done) = mpsc::sync_channel(1);
    struct Stop(Arc<AtomicBool>);
    impl Drop for Stop {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }
    std::thread::scope(|scope| {
        let stopped = stop.clone();
        let worker = scope.spawn(move || {
            let (mut runtime, mut sink) = active();
            while !stopped.load(Ordering::SeqCst) {
                server.drain(&mut runtime, 1, &mut sink).unwrap();
                if !runtime.snapshot().active
                    && runtime.snapshot().last_release_reason == "native_input_released"
                {
                    let _ = released.try_send(());
                }
                std::thread::yield_now();
            }
            sink.report
        });
        let _stop = Stop(stop.clone());
        let mut client = Client::connect(&root.0).unwrap();
        assert!(client.require_physical_output().unwrap().input_enabled);
        let grant = client.grant([0xab; 16], 1, 1, 1000).unwrap();
        assert!(grant.physical);
        let binding = grant.binding();
        let mut sender = grant.into_sender().unwrap();
        let held:GamepadState=serde_json::from_value(serde_json::json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":0,"rightTrigger":0})).unwrap();
        client
            .packet(binding, &sender.seal(&held).unwrap())
            .unwrap();
        drop(client);
        done.recv_timeout(Duration::from_secs(2)).unwrap();
        stop.store(true, Ordering::SeqCst);
        assert_eq!(worker.join().unwrap(), NEUTRAL);
    });
}
#[test]
fn physical_epoch_cas_is_not_bypassed_by_output_negotiation() {
    let root = Root::new();
    let mut server = Server::bind(&root.0).unwrap();
    let (mut runtime, mut output) = active();
    for offset in [16, 24] {
        let mut bytes = grant_payload();
        bytes[offset..offset + 8].copy_from_slice(&2u64.to_le_bytes());
        assert!(server
            .apply(PHYSICAL_GRANT, &bytes, &mut runtime, 1, &mut output)
            .is_err());
        assert!(server.binding.is_none());
        assert!(runtime.snapshot().active);
        assert_eq!(runtime.snapshot().generation, "1");
    }
}
