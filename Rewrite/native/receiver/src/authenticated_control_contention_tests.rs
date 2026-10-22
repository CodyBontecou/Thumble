// Native in-process fault injection at the real trust mutation seam. No production hook.
// This characterizes a remaining responsiveness limitation, not a continuous-input
// fix: contended durable trust work can stop a queued reliable frame from reaching
// the receiver. Native expiry must still run and queued input must not revive it.
#[test]
fn contended_trust_mutation_keeps_native_expiry_independent_and_cannot_resurrect_queued_input() {
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
        assert_eq!(reports.lock().unwrap().last().copied(), Some(held.report()));
        // Model another control operation suspended in storage while it owns both
        // locks. The runtime safety owner is separate and keeps renewing normally.
        let renewal_count = renewals.load(Ordering::SeqCst);
        let gate = mutation.lock().unwrap();
        let storage = store.lock().unwrap();
        let (sent, queued) = mpsc::sync_channel(1);
        let input = scope.spawn(move || {
            client
                .send(FrameKind::Input, &sender.seal(&held).unwrap())
                .unwrap();
            sent.send(()).unwrap();
            send(
                &mut client,
                json!({"version":1,"command":"control-status","connectionId":connection}),
            )
            .unwrap();
            receive::<Value>(&mut client)
        });
        queued.recv_timeout(Duration::from_secs(1)).unwrap();
        let started = Instant::now();
        while snapshot
            .lock()
            .unwrap()
            .as_ref()
            .is_none_or(|state| state.last_release_reason != "input_expired")
            && started.elapsed() < Duration::from_secs(1)
        {
            thread::sleep(Duration::from_millis(1));
        }
        let state = snapshot.lock().unwrap().clone().unwrap();
        assert!(!state.active);
        assert_eq!(state.last_release_reason, "input_expired");
        assert_eq!(
            state.report_hex,
            crate::gamepad::hex(&crate::gamepad::NEUTRAL)
        );
        assert!(
            renewals.load(Ordering::SeqCst) > renewal_count,
            "independent healthy owner did not renew during injected contention"
        );
        drop(storage);
        drop(gate);
        assert!(input.join().unwrap().is_err());
        assert_eq!(control.join().unwrap(), Err("native_input_rejected"));
        assert_eq!(
            reports.lock().unwrap().last().copied(),
            Some(crate::gamepad::NEUTRAL)
        );
        stop.store(true, Ordering::SeqCst);
        owner.join().unwrap();
    });
}
