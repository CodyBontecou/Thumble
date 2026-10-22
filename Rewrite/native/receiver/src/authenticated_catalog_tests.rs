// Actual native TLS/admission plus private parent bridge, with no input receiver needed.
#[test]
fn management_is_explicit_never_input_capable_and_rechecks_revoke_after_parent_wait() {
    use crate::{
        enrollment::{self, PairingWindows},
        input_broker::{ControlInput, Registry},
    };
    use std::{sync::mpsc, time::Duration};
    for revoke in [false, true] {
        let root = Root::new();
        let identity = host_identity::load_existing(&root.0).unwrap();
        let mut trust = PhoneTrustStore::open(&root.0).unwrap();
        let issued = trust
            .enroll_after_pairing("catalog-phone", "Catalog", 100)
            .unwrap();
        let (mut delivery, mut received) = channel(&identity);
        issued.send_enrollment(&mut delivery).unwrap();
        let credential: Value = receive(&mut received).unwrap();
        delivery.close();
        received.close();
        let store = Mutex::new(trust);
        let mutation = Mutex::new(());
        let windows = Mutex::new(PairingWindows::new("authority-a", identity.pin()).unwrap());
        let registry = Registry::default();
        let bridge = catalog::Bridge::new("authority-a");
        let (output, events) = mpsc::sync_channel(1);
        bridge.attach(output).unwrap();
        let (mut server, mut client) = channel(&identity);
        thread::scope(|scope| {
            let worker = scope.spawn(|| {
                enrollment::serve(
                    &mut server,
                    &windows,
                    &store,
                    &mutation,
                    ControlInput {
                        root: &root.0,
                        registry: &registry,
                        datagram_port: Some(42424),
                        renewal: false,
                    },
                    ManagementBridges {catalog:&bridge,controls:None},
                    || Ok(100),
                )
            });
            send(&mut client,json!({"version":1,"command":"hello","controlVersion":7,"role":"management","inputVersion":1,"documentVersion":1,"capabilitiesVersion":1})).unwrap();
            assert_eq!(receive::<Value>(&mut client).unwrap()["role"], "management");
            send(&mut client,json!({"version":1,"command":"authenticate","authorityInstanceId":"authority-a","phoneId":"catalog-phone","credentialEpoch":"1","credential":credential["credential"]})).unwrap();
            let admission: Value = receive(&mut client).unwrap();
            assert_eq!(admission["role"], "management");
            assert_eq!(admission["inputSessionAvailable"], false);
            send(&mut client,json!({"version":1,"command":"configuration-list","connectionId":admission["connectionId"],"expectedRevision":null,"offset":0})).unwrap();
            let event: Value =
                serde_json::from_str(&events.recv_timeout(Duration::from_secs(1)).unwrap())
                    .unwrap();
            if revoke {
                let _mutation = mutation.lock().unwrap();
                store.lock().unwrap().revoke("catalog-phone", 101).unwrap();
            }
            bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-catalog-reply","eventId":event["eventId"],"authorityInstanceId":"authority-a","result":{"kind":"catalog","revision":"0","contentHash":null,"activeProfileId":null,"defaultProfileId":null,"nextOffset":null,"profileCount":0}})).unwrap()).unwrap();
            if revoke {
                assert!(receive::<Value>(&mut client).is_err());
                assert_eq!(worker.join().unwrap(), Err("phone_authentication_rejected"));
            } else {
                let reply: Value = receive(&mut client).unwrap();
                assert_eq!(reply["command"], "configuration-result");
                assert_eq!(reply["connectionId"], admission["connectionId"]);
                assert_eq!(reply["profileCount"], 0);
                assert_eq!(worker.join().unwrap(), Ok(()));
            }
        });
    }
}

// Real receiver safety owner, reservation worker and two independent pinned TLS sockets.
#[test]
fn management_timeout_preserves_held_input_and_native_owner_lease() {
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
    fn wall_time() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64
    }
    let root = Root::new();
    let identity = host_identity::load_existing(&root.0).unwrap();
    let mut trust = PhoneTrustStore::open(&root.0).unwrap();
    let phone = trust
        .enroll_after_pairing("contention-phone", "Native", wall_time())
        .unwrap()
        .phone()
        .clone();
    let blocked_phone = trust
        .enroll_after_pairing("blocked-management-phone", "Backpressure", wall_time())
        .unwrap()
        .phone()
        .clone();
    let blocked_authorization = trust.cached_authorization(&blocked_phone).unwrap();
    let control_result = Mutex::new(None);
    let store = Arc::new(Mutex::new(trust));
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
        expires: wall_time() + 60_000,
        observed: wall_time(),
    };
    let neutral: GamepadState = serde_json::from_value(json!({"buttons":[],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":0,"rightTrigger":0})).unwrap();
    let mut held = neutral.clone();
    held.buttons.push(GamepadButton::South);
    held.left_trigger = 1.;
    let _reservation = crate::trust_reservation::Owner::start(store.clone()).unwrap();
    let bridge = catalog::Bridge::new("authority-a");
    let (output, events) = mpsc::sync_channel(1);
    bridge.attach(output).unwrap();
    let (mut management_server, mut management_client) = channel(&identity);
    let mut management_auth = AuthorizedConnection {
        binding: management_server.native_binding().unwrap(),
        host_pin: identity.pin().hex(),
        authorization: auth.authorization.clone(),
        phone: auth.phone.clone(),
        expires: wall_time() + 60_000,
        observed: wall_time(),
    };
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
            let result = serve_input(
                &mut server,
                "authority-a",
                &mut auth,
                &mut broker,
                &store,
                &mutation,
                &mut || Ok(wall_time()),
            );
            *control_result.lock().unwrap() = Some(result);
            // Match the real host worker: an authorization failure closes TLS
            // immediately instead of making the client wait for a read timeout.
            server.close();
            result
        });
        send(&mut client, json!({"version":1,"command":"input-grant","connectionId":connection,"generation":"1","revision":"1"})).unwrap();
        let grant: Value = receive(&mut client).unwrap();
        let mut sender = renewal_sender(&grant);
        client
            .send(FrameKind::Input, &sender.seal(&neutral).unwrap())
            .unwrap();
        let management = scope.spawn(|| {
            let result = catalog::serve(
                &mut management_server,
                "authority-a",
                &mut management_auth,
                &bridge,
                &mut || Ok(wall_time()),
            );
            management_server.close();
            result
        });
        let admission: Value = receive(&mut management_client).unwrap();
        assert_eq!(admission["role"], "management");
        assert_eq!(admission["inputSessionAvailable"], false);
        send(&mut management_client, json!({"version":1,"command":"configuration-list","connectionId":admission["connectionId"],"expectedRevision":null,"offset":0})).unwrap();
        let event: Value =
            serde_json::from_str(&events.recv_timeout(Duration::from_secs(1)).unwrap()).unwrap();
        let started = Instant::now();
        let initial_renewals = renewals.load(Ordering::SeqCst);
        let mut samples = 0;
        while started.elapsed() < Duration::from_millis(2200) {
            client
                .send(FrameKind::Input, &sender.seal(&held).unwrap())
                .unwrap();
            send(
                &mut client,
                json!({"version":1,"command":"control-status","connectionId":connection}),
            )
            .unwrap();
            let response = receive::<Value>(&mut client);
            #[cfg(debug_assertions)]
            if response.is_err() {
                let state = snapshot.lock().ok().and_then(|v| v.clone());
                let control = control_result.lock().ok().and_then(|v| *v);
                eprintln!(
                    "[DEBUG-catalog-held-status] samples={samples} elapsedMs={} controlResult={control:?} stateActive={:?} stateReason={:?} metrics={}",
                    started.elapsed().as_millis(),
                    state.as_ref().map(|v| v.active),
                    state.as_ref().map(|v| v.last_release_reason),
                    crate::input_io_diagnostics::snapshot(),
                );
            }
            assert_eq!(response.unwrap()["command"], "control-status");
            let state = snapshot.lock().unwrap().clone().unwrap();
            assert!(
                state.active,
                "catalog wait retired healthy held input: {state:?}"
            );
            assert_eq!(state.report_hex, crate::gamepad::hex(&held.report()));
            samples += 1;
            thread::sleep(Duration::from_millis(20));
        }
        assert!(samples >= 10);
        assert!(renewals.load(Ordering::SeqCst) > initial_renewals + 10);
        let timeout: Value = receive(&mut management_client).unwrap();
        assert_eq!(timeout["kind"], "error");
        assert_eq!(timeout["error"], "phone_catalog_timeout");
        assert_eq!(management.join().unwrap(), Ok(()));
        // A late service completion cannot produce another delivery or touch input.
        bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-catalog-reply","eventId":event["eventId"],"authorityInstanceId":"authority-a","error":"phone_catalog_busy"})).unwrap()).unwrap();
        let state = snapshot.lock().unwrap().clone().unwrap();
        assert!(state.active);
        assert_eq!(state.report_hex, crate::gamepad::hex(&held.report()));
        management_client.close();
        // Deterministic backpressure model: hold exactly the management delivery
        // fence that a non-reading TLS peer could retain during its bounded send.
        // This is not a platform-specific TCP receive-window reproduction.
        let delivery = blocked_authorization.management_guard().unwrap();
        let windows = Mutex::new(
            crate::enrollment::PairingWindows::new("authority-a", identity.pin()).unwrap(),
        );
        let offer = windows.lock().unwrap().open(wall_time()).unwrap();
        let (mut enrollment_server, mut enrollment_client) = channel(&identity);
        let enrollment_store = store.clone();
        let enrollment_mutation = &mutation;
        let reenroll = scope.spawn(move || {
            crate::enrollment::enroll(
                &mut enrollment_server,
                &windows,
                &enrollment_store,
                enrollment_mutation,
                || Ok(wall_time()),
            )
        });
        send(&mut enrollment_client, json!({"version":1,"command":"hello","controlVersion":2,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1})).unwrap();
        assert_eq!(
            receive::<Value>(&mut enrollment_client).unwrap()["command"],
            "hello"
        );
        send(&mut enrollment_client, json!({"version":1,"command":"enroll","authorityInstanceId":"authority-a","windowId":offer.window_id,"proof":offer.secret,"phoneId":"blocked-management-phone","label":"Replacement"})).unwrap();
        let blocked_started = Instant::now();
        let initial_renewals = renewals.load(Ordering::SeqCst);
        let mut committed = false;
        while blocked_started.elapsed() < Duration::from_millis(1200) {
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
            let state = snapshot.lock().unwrap().clone().unwrap();
            assert!(
                state.active,
                "unrelated input expired behind management delivery: {state:?}"
            );
            assert_eq!(state.report_hex, crate::gamepad::hex(&held.report()));
            if let Ok(store) = store.try_lock() {
                committed |=
                    store.list().unwrap().iter().any(|p| {
                        p.phone_id == "blocked-management-phone" && p.credential_epoch == "2"
                    });
            }
            thread::sleep(Duration::from_millis(20));
        }
        assert!(
            committed,
            "re-enrollment retained store lock while waiting for old management delivery"
        );
        assert!(
            mutation.try_lock().is_ok(),
            "policy lock retained during delivery drain"
        );
        assert!(
            !reenroll.is_finished(),
            "credential acknowledgement escaped the delivery fence"
        );
        assert!(matches!(
            blocked_authorization.guard(),
            Err("phone_authentication_rejected")
        ));
        assert!(renewals.load(Ordering::SeqCst) > initial_renewals + 10);
        drop(delivery);
        let enrolled: Value = receive(&mut enrollment_client).unwrap();
        assert_eq!(enrolled["command"], "enrolled");
        assert_eq!(enrolled["credentialEpoch"], "2");
        send(&mut enrollment_client, json!({"version":1,"command":"enrollment-stored","phoneId":"blocked-management-phone","credentialEpoch":"2"})).unwrap();
        assert_eq!(
            receive::<Value>(&mut enrollment_client).unwrap()["command"],
            "enrollment-complete"
        );
        assert_eq!(reenroll.join().unwrap().unwrap().credential_epoch, "2");
        assert!(matches!(
            blocked_authorization.guard(),
            Err("phone_authentication_rejected")
        ));
        client.close();
        assert!(control.join().unwrap().is_err());
        assert_eq!(
            reports.lock().unwrap().last().copied(),
            Some(crate::gamepad::NEUTRAL)
        );
        stop.store(true, Ordering::SeqCst);
        owner.join().unwrap();
    });
}
