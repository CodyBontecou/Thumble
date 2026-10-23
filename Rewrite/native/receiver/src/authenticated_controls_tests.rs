#[test]
fn controls_v8_is_management_only_and_fences_revocation_and_native_replacement_after_parent_wait() {
    use crate::{
        enrollment::{self, PairingWindows},
        input_broker::{ControlInput, Registry},
        native_ingress::Server,
        packet_runtime::PacketRuntime,
        runtime::{Command, Output},
    };
    use std::{
        sync::{atomic::AtomicBool, mpsc, Arc},
        time::{Duration, Instant},
    };
    struct Sink {
        held_allowed: bool,
    }
    impl Output for Sink {
        fn submit(&mut self, report: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            if !self.held_allowed {
                assert_eq!(report, crate::gamepad::NEUTRAL);
            }
            Ok(())
        }
    }
    struct Stop(Arc<AtomicBool>);
    impl Drop for Stop {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }
    fn activation(generation: &str, revision: &str) -> Command {
        serde_json::from_value(json!({"command":"activateSaved","generation":generation,"revision":revision,"profileId":"aaaaaaaa-0000-0000-0000-000000000001","sessionId":"owner","leaseMs":750,"inputTtlMs":350,"configurationRevision":"3","sourceHash":"a".repeat(64)})).unwrap()
    }
    fn wall_time() -> u64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64
    }
    for outcome in [
        "success",
        "replace",
        "revoke",
        "input",
        "missing-role",
        "timeout",
    ] {
        let root = Root::new();
        let identity = host_identity::load_existing(&root.0).unwrap();
        let mut trust = PhoneTrustStore::open(&root.0).unwrap();
        let issued = trust
            .enroll_after_pairing("controls-phone", "Controls", wall_time())
            .unwrap();
        let (mut delivery, mut received) = channel(&identity);
        issued.send_enrollment(&mut delivery).unwrap();
        let credential: Value = receive(&mut received).unwrap();
        delivery.close();
        received.close();
        let store = Arc::new(Mutex::new(trust));
        let _reservation = crate::trust_reservation::Owner::start(store.clone()).unwrap();
        let mutation = Mutex::new(());
        let windows = Mutex::new(PairingWindows::new("authority-a", identity.pin()).unwrap());
        let registry = Registry::default();
        let receiver_root = root.0.join("receiver");
        crate::security::directory(&receiver_root).unwrap();
        let mut ingress = Server::bind(&receiver_root).unwrap();
        let catalog = catalog::Bridge::new("authority-a");
        let bridge = controls::Bridge::new("authority-a", &receiver_root);
        let (output, events) = mpsc::sync_channel(1);
        bridge.attach(output).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let (replace, replace_receiver) = mpsc::sync_channel(1);
        let (replaced, replace_ack) = mpsc::sync_channel(1);
        let (ready, ready_receiver) = mpsc::sync_channel(1);
        let observed = Arc::new(Mutex::new(None));
        let owner_observed = observed.clone();
        let (mut server, mut client) = channel(&identity);
        thread::scope(|scope| {
            let _stop = Stop(stop);
            let owner = scope.spawn(move || {
                let mut runtime = PacketRuntime::default();
                let mut output = Sink {
                    held_allowed: outcome == "timeout",
                };
                let started = Instant::now();
                runtime
                    .apply_owner(activation("7", "2"), 0, &mut output)
                    .unwrap();
                let mut generation = "7";
                ready.send(()).unwrap();
                while !stopped.load(Ordering::SeqCst) {
                    let now = started.elapsed().as_millis() as u64;
                    if replace_receiver.try_recv().is_ok() {
                        runtime
                            .apply_owner(activation("8", "3"), now, &mut output)
                            .unwrap();
                        generation = "8";
                        replaced.send(()).unwrap();
                    }
                    runtime
                        .apply_owner(
                            Command::Renew {
                                generation: generation.into(),
                                session_id: "owner".into(),
                            },
                            now,
                            &mut output,
                        )
                        .unwrap();
                    ingress.drain(&mut runtime, now, &mut output).unwrap();
                    *owner_observed.lock().unwrap() =
                        Some((runtime.snapshot(), runtime.saved_binding().cloned()));
                    thread::sleep(Duration::from_millis(1));
                }
            });
            ready_receiver.recv_timeout(Duration::from_secs(1)).unwrap();
            let worker = scope.spawn(|| {
                enrollment::serve(
                    &mut server,
                    &windows,
                    &store,
                    &mutation,
                    ControlInput {
                        root: &receiver_root,
                        registry: &registry,
                        datagram_port: Some(42424),
                        renewal: false,
                        physical: false,
                    },
                    ManagementBridges {
                        catalog: &catalog,
                        controls: Some(&bridge),
                        presentation: None,
                    },
                    || Ok(wall_time()),
                )
            });
            let mut hello = json!({"version":1,"command":"hello","controlVersion":8,"role":"management","inputVersion":1,"documentVersion":1,"capabilitiesVersion":1});
            if outcome == "missing-role" {
                hello.as_object_mut().unwrap().remove("role");
            }
            send(&mut client, hello).unwrap();
            if outcome == "missing-role" {
                assert!(receive::<Value>(&mut client).is_err());
                assert_eq!(
                    worker.join().unwrap(),
                    Err("enrollment_version_unsupported")
                );
                return;
            }
            let hello: Value = receive(&mut client).unwrap();
            assert_eq!(hello["controlVersion"], 8);
            assert_eq!(hello["role"], "management");
            assert_eq!(hello["inputEnabled"], false);
            send(&mut client,json!({"version":1,"command":"authenticate","authorityInstanceId":"authority-a","phoneId":"controls-phone","credentialEpoch":"1","credential":credential["credential"]})).unwrap();
            let admission: Value = receive(&mut client).unwrap();
            assert_eq!(admission["role"], "management");
            assert_eq!(admission["inputSessionAvailable"], false);
            if outcome == "input" {
                client
                    .send(FrameKind::Input, &[0; crate::input_packet::PACKET_BYTES])
                    .unwrap();
                assert!(receive::<Value>(&mut client).is_err());
                assert_eq!(worker.join().unwrap(), Err("saved_map_request_invalid"));
                return;
            }
            let input_stop = Arc::new(AtomicBool::new(false));
            let stopped_input = input_stop.clone();
            let input_stop_guard = Stop(input_stop);
            let input = if outcome == "timeout" {
                let mut input = crate::native_ingress::Client::connect(&receiver_root).unwrap();
                let grant = input.grant([0x44; 16], 7, 2, 60_000).unwrap();
                let binding = grant.binding();
                let mut sender = grant.into_sender().unwrap();
                let (first, first_packet) = mpsc::sync_channel(1);
                let input=scope.spawn(move ||{let state:crate::generated::GamepadState=serde_json::from_value(json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":1,"rightTrigger":0})).unwrap();let mut first=Some(first);
                    while !stopped_input.load(Ordering::SeqCst){input.packet(binding,&sender.seal(&state).unwrap()).unwrap();if let Some(first)=first.take(){first.send(()).unwrap();}thread::sleep(Duration::from_millis(20));}
                });
                first_packet.recv_timeout(Duration::from_secs(1)).unwrap();
                Some(input)
            } else {
                None
            };
            let fixture: Value = serde_json::from_str(include_str!(
                "../../../packages/fixtures/saved-controller-control-v8.json"
            ))
            .unwrap();
            let mut request = fixture["request"].clone();
            request["connectionId"] = admission["connectionId"].clone();
            send(&mut client, request.clone()).unwrap();
            let event: Value =
                serde_json::from_str(&events.recv_timeout(Duration::from_secs(1)).unwrap())
                    .unwrap();
            assert_eq!(event["event"], "phone-controls");
            assert_eq!(event["authorityInstanceId"], "authority-a");
            assert!(event.get("connectionId").is_none());
            assert!(event.get("credential").is_none());
            if outcome == "replace" {
                replace.send(()).unwrap();
                replace_ack.recv_timeout(Duration::from_secs(1)).unwrap();
            }
            if outcome == "revoke" {
                let _mutation = mutation.lock().unwrap();
                store
                    .lock()
                    .unwrap()
                    .revoke("controls-phone", wall_time())
                    .unwrap();
            }
            let mut result = fixture["reply"].clone();
            for key in ["version", "command", "connectionId"] {
                result.as_object_mut().unwrap().remove(key);
            }
            result["authorityInstanceId"] = json!("authority-a");
            if outcome == "timeout" {
                thread::sleep(Duration::from_millis(2200));
                let reply: Value = receive(&mut client).unwrap();
                assert_eq!(reply["kind"], "error");
                assert_eq!(reply["error"], "saved_map_timeout");
                assert_eq!(worker.join().unwrap(), Ok(()));
                let (snapshot, pin) = observed.lock().unwrap().clone().unwrap();
                assert!(snapshot.active);
                assert_eq!(snapshot.generation, "7");
                assert_ne!(
                    snapshot.report_hex,
                    crate::gamepad::hex(&crate::gamepad::NEUTRAL)
                );
                assert!(pin.is_some());
                bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-controls-reply","eventId":event["eventId"],"authorityInstanceId":"authority-a","result":result})).unwrap()).unwrap();
                drop(input_stop_guard);
                input.unwrap().join().unwrap();
                drop(_stop);
                owner.join().unwrap();
                return;
            }
            bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-controls-reply","eventId":event["eventId"],"authorityInstanceId":"authority-a","result":result})).unwrap()).unwrap();
            if outcome == "revoke" {
                assert!(receive::<Value>(&mut client).is_err());
                assert_eq!(worker.join().unwrap(), Err("phone_authentication_rejected"));
            } else {
                let reply: Value = receive(&mut client).unwrap();
                assert_eq!(reply["command"], "configuration-controls-result");
                assert_eq!(reply["connectionId"], admission["connectionId"]);
                if outcome == "replace" {
                    assert_eq!(reply["kind"], "error");
                    assert_eq!(reply["error"], "saved_map_reactivation_required");
                } else {
                    assert_eq!(reply["kind"], "controls");
                    assert_eq!(reply["controlCount"], 2);
                    assert_eq!(reply["control0HapticStyle"], "light");
                    assert_eq!(reply["generation"], "7");
                    assert_eq!(reply["sourceHash"], "a".repeat(64));
                    assert!(reply.get("inputEnabled").is_none());
                }
                assert_eq!(worker.join().unwrap(), Ok(()));
            }
            drop(_stop);
            owner.join().unwrap();
        });
    }
}
