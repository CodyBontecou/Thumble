// Fault injection at the real trust/mutation seam. The historical failing
// characterization is preserved in commit 4aa2e98 and its evidence log. This
// regression requires live packets and status to proceed during stalled storage,
// then proves an exhausted reservation cannot resurrect expired held state.
#[test]
fn reserved_input_and_status_bypass_stalled_storage_then_fail_closed_without_resurrection() {
    use crate::{
        generated::{GamepadButton, GamepadState},
        input_broker::{Broker, Registry},
        native_ingress::Server,
        packet_runtime::PacketRuntime,
        runtime::{Command, Output},
    };
    use std::{
        sync::{atomic::AtomicBool, mpsc, Arc},
        time::{Duration, Instant},
    };
    struct Recording(Arc<Mutex<Vec<[u8; 20]>>>);
    impl Output for Recording {
        fn submit(&mut self, report: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            self.0.lock().unwrap().push(report);
            Ok(())
        }
    }
    struct Stop(Arc<AtomicBool>);
    impl Drop for Stop {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }
    let root = Root::new();
    let identity = host_identity::load_existing(&root.0).unwrap();
    let mut trust = PhoneTrustStore::open(&root.0).unwrap();
    let phone = trust
        .enroll_after_pairing("contention-phone", "Native", 100)
        .unwrap()
        .phone()
        .clone();
    let store = Mutex::new(trust);
    let mutation = Mutex::new(());
    let registry = Registry::default();
    let receiver_root = root.0.join("receiver");
    crate::security::directory(&receiver_root).unwrap();
    let mut ingress = Server::bind(&receiver_root).unwrap();
    let reports = Arc::new(Mutex::new(Vec::new()));
    let snapshot = Arc::new(Mutex::new(None));
    let stop = Arc::new(AtomicBool::new(false));
    let renewals = Arc::new(AtomicU64::new(0));
    let (mut server, mut client) = channel(&identity);
    let connection = hex(&server.native_binding().unwrap());
    let mut auth = AuthorizedConnection {
        binding: server.native_binding().unwrap(),
        host_pin: identity.pin().hex(),
        authorization: store.lock().unwrap().cached_authorization(&phone).unwrap(),
        phone,
        expires: 60_100,
        observed: 100,
    };
    let neutral: GamepadState = serde_json::from_value(json!({"buttons":[],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":0,"rightTrigger":0})).unwrap();
    let mut held = neutral.clone();
    held.buttons.push(GamepadButton::South);
    held.left_trigger = 1.;
    thread::scope(|scope| {
        let _stop = Stop(stop.clone());
        let stop_owner = stop.clone();
        let reports_owner = reports.clone();
        let snapshot_owner = snapshot.clone();
        let renewals_owner = renewals.clone();
        let owner = scope.spawn(move || {
            let started = Instant::now();
            let mut runtime = PacketRuntime::default();
            let mut output = Recording(reports_owner);
            runtime
                .apply_owner(
                    Command::Activate {
                        generation: "1".into(),
                        revision: "1".into(),
                        profile_id: "contention-profile".into(),
                        session_id: "owner".into(),
                        lease_ms: 750,
                        input_ttl_ms: 350,
                    },
                    0,
                    &mut output,
                )
                .unwrap();
            let mut renewed = Instant::now();
            while !stop_owner.load(Ordering::SeqCst) {
                let now = started.elapsed().as_millis() as u64;
                if renewed.elapsed() >= Duration::from_millis(30) {
                    if runtime
                        .apply_owner(
                            Command::Renew {
                                generation: "1".into(),
                                session_id: "owner".into(),
                            },
                            now,
                            &mut output,
                        )
                        .is_ok()
                    {
                        renewals_owner.fetch_add(1, Ordering::SeqCst);
                    }
                    renewed = Instant::now();
                }
                ingress.drain(&mut runtime, now, &mut output).unwrap();
                *snapshot_owner.lock().unwrap() = Some(runtime.snapshot());
                thread::sleep(Duration::from_millis(1));
            }
        });
        let control = scope.spawn(|| {
            let mut broker =
                Broker::connect(&receiver_root, &registry, auth.binding, Some(42424)).unwrap();
            serve_input(
                &mut server,
                "authority-a",
                &mut auth,
                &mut broker,
                &store,
                &mutation,
                &mut || Ok(100),
            )
        });
        send(&mut client, json!({"version":1,"command":"input-grant","connectionId":connection,"generation":"1","revision":"1"})).unwrap();
        let grant: Value = receive(&mut client).unwrap();
        let mut sender = renewal_sender(&grant);
        client
            .send(FrameKind::Input, &sender.seal(&neutral).unwrap())
            .unwrap();
        send(
            &mut client,
            json!({"version":1,"command":"control-status","connectionId":connection}),
        )
        .unwrap();
        assert_eq!(
            receive::<Value>(&mut client).unwrap()["command"],
            "control-status"
        );
        assert_eq!(
            reports.lock().unwrap().last().copied(),
            Some(neutral.report())
        );
        // Model another control operation suspended in storage while it owns both
        // locks. The runtime safety owner is separate and keeps renewing normally.
        let renewal_count = renewals.load(Ordering::SeqCst);
        let gate = mutation.lock().unwrap();
        let storage = store.lock().unwrap();
        let (sent, queued) = mpsc::sync_channel(1);
        let (resume, resumed) = mpsc::sync_channel(1);
        let sent_held = held.clone();
        let input = scope.spawn(move || {
            let held = sent_held;
            // The first held packet arrives while the other operation owns the
            // durable store: neutral admission does not defer it behind fsync.
            for _ in 0..20 {
                client
                    .send(FrameKind::Input, &sender.seal(&held).unwrap())
                    .unwrap();
                send(
                    &mut client,
                    json!({"version":1,"command":"control-status","connectionId":connection}),
                )
                .unwrap();
                assert_eq!(
                    receive::<Value>(&mut client).unwrap()["command"],
                    "control-status"
                );
                thread::sleep(Duration::from_millis(20));
            }
            sent.send(()).unwrap();
            resumed.recv_timeout(Duration::from_secs(2)).unwrap();
            client
                .send(FrameKind::Input, &sender.seal(&held).unwrap())
                .unwrap();
            receive::<Value>(&mut client)
        });
        queued.recv_timeout(Duration::from_secs(2)).unwrap();
        let state = snapshot.lock().unwrap().clone().unwrap();
        assert!(
            state.active,
            "continuous input expired behind unrelated storage"
        );
        assert_eq!(state.report_hex, crate::gamepad::hex(&held.report()));
        assert!(renewals.load(Ordering::SeqCst) > renewal_count);
        // No durable renewal can finish while storage is held. After the existing
        // reservation and 350ms input freshness both run out, late held input is
        // rejected. Neither the healthy 750ms owner nor a stale queued frame may
        // extend the reservation or reanimate the released source.
        thread::sleep(Duration::from_millis(750));
        let state = snapshot.lock().unwrap().clone().unwrap();
        assert!(!state.active);
        assert_eq!(state.last_release_reason, "input_expired");
        assert_eq!(
            state.report_hex,
            crate::gamepad::hex(&crate::gamepad::NEUTRAL)
        );
        resume.send(()).unwrap();
        assert!(input.join().unwrap().is_err());
        assert_eq!(
            control.join().unwrap(),
            Err("phone_trust_reservation_expired")
        );
        drop(storage);
        drop(gate);
        assert_eq!(
            reports.lock().unwrap().last().copied(),
            Some(crate::gamepad::NEUTRAL)
        );
        stop.store(true, Ordering::SeqCst);
        owner.join().unwrap();
    });
}
