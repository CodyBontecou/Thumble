#[test]
fn presentation_v10_is_read_only_and_fences_revocation_replacement_timeout_and_reuse() {
    presentation_management_witness(presentation::Protocol::BaseV1, "base");
}
#[test]
fn presentation_v11_banks_preserve_management_fences_bounds_and_legacy_isolation() {
    for bank in ["base", "left-trigger", "right-trigger", "both-triggers"] {
        presentation_management_witness(presentation::Protocol::BanksV2, bank);
    }
}
fn presentation_management_witness(protocol: presentation::Protocol, bank: &str) {
    let control_version = if protocol == presentation::Protocol::BanksV2 {11} else {10};
    let wire_version = if protocol == presentation::Protocol::BanksV2 {2} else {1};
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
    // Shared lifecycle/fence/65-command coverage runs once per negotiated protocol;
    // every bank still crosses actual TLS metadata and icon request/reply boundaries.
    let full = protocol == presentation::Protocol::BaseV1 || bank == "both-triggers";
    let mut outcomes = if full {vec![
        "success",
        "replace",
        "revoke",
        "input",
        "grant",
        "wrong-role",
        "missing-role",
        "timeout",
    ]} else {vec!["success"]};
    if protocol == presentation::Protocol::BanksV2 {
        outcomes.extend(["wrong-wire", "missing-bank", "invalid-bank"]);
    }
    for outcome in outcomes {
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
        let controls = controls::Bridge::new("authority-a", &receiver_root);
        let bridge = presentation::Bridge::new("authority-a", &receiver_root, controls.operation_gate());
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
                        controls: Some(&controls),
                        presentation: Some(&bridge),
                    },
                    || Ok(wall_time()),
                )
            });
            let mut hello = json!({"version":1,"command":"hello","controlVersion":control_version,"role":"management","inputVersion":1,"documentVersion":1,"capabilitiesVersion":1});
            if outcome == "wrong-role" { hello["role"]=json!("physical-input"); hello["requiredOutputBackend"]=json!("macos-hid"); }
            if outcome == "missing-role" {
                hello.as_object_mut().unwrap().remove("role");
            }
            send(&mut client, hello).unwrap();
            if matches!(outcome,"missing-role"|"wrong-role") {
                assert!(receive::<Value>(&mut client).is_err());
                assert_eq!(
                    worker.join().unwrap(),
                    Err("enrollment_version_unsupported")
                );
                return;
            }
            let hello: Value = receive(&mut client).unwrap();
            assert_eq!(hello["controlVersion"], control_version);
            assert_eq!(hello["role"], "management");
            assert_eq!(hello["inputEnabled"], false);
            send(&mut client,json!({"version":1,"command":"authenticate","authorityInstanceId":"authority-a","phoneId":"controls-phone","credentialEpoch":"1","credential":credential["credential"]})).unwrap();
            let admission: Value = receive(&mut client).unwrap();
            assert_eq!(admission["role"], "management");
            assert_eq!(admission["inputSessionAvailable"], false);
            if outcome == "grant" {
                send(&mut client,json!({"version":1,"command":"input-grant","connectionId":admission["connectionId"],"generation":"7","revision":"2"})).unwrap();
                assert!(receive::<Value>(&mut client).is_err());
                assert_eq!(worker.join().unwrap(),Err("presentation_request_invalid"));
                return;
            }
            if outcome == "input" {
                client
                    .send(FrameKind::Input, &[0; crate::input_packet::PACKET_BYTES])
                    .unwrap();
                assert!(receive::<Value>(&mut client).is_err());
                assert_eq!(worker.join().unwrap(), Err("presentation_request_invalid"));
                return;
            }
            if outcome == "success" {
                let (mut other_server, mut other_client) = channel(&identity);
                thread::scope(|other_scope| {
                let other = other_scope.spawn(|| enrollment::serve(
                    &mut other_server, &windows, &store, &mutation,
                    ControlInput { root: &receiver_root, registry: &registry, datagram_port:Some(42424),renewal:false,physical:false },
                    ManagementBridges { catalog:&catalog, controls:Some(&controls), presentation:Some(&bridge) },
                    || Ok(wall_time()),
                ));
                send(&mut other_client,json!({"version":1,"command":"hello","controlVersion":10,"role":"management","inputVersion":1,"documentVersion":1,"capabilitiesVersion":1})).unwrap();
                let _:Value=receive(&mut other_client).unwrap();
                send(&mut other_client,json!({"version":1,"command":"authenticate","authorityInstanceId":"authority-a","phoneId":"controls-phone","credentialEpoch":"1","credential":credential["credential"]})).unwrap();
                assert!(receive::<Value>(&mut other_client).is_err());
                assert_eq!(other.join().unwrap(),Err("presentation_busy"));
                });
                // The first peer still owns its batch; rejected peers cannot steal it.
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
                "../../../packages/fixtures/saved-controller-presentation-control-v10.json"
            ))
            .unwrap();
            let mut request = fixture["request"].clone();
            request["connectionId"] = admission["connectionId"].clone();
            request["version"] = json!(wire_version);
            if protocol == presentation::Protocol::BanksV2 {request["bank"] = json!(bank);}
            if matches!(outcome,"wrong-wire"|"missing-bank"|"invalid-bank") {
                if outcome=="wrong-wire" {request["version"]=json!(1);}
                if outcome=="missing-bank" {request.as_object_mut().unwrap().remove("bank");}
                if outcome=="invalid-bank" {request["bank"]=json!("shift");}
                send(&mut client,request).unwrap();
                assert!(receive::<Value>(&mut client).is_err());
                assert_eq!(worker.join().unwrap(),Err("presentation_request_invalid"));
                assert!(events.try_recv().is_err());
                return;
            }
            send(&mut client, request.clone()).unwrap();
            let event: Value =
                serde_json::from_str(&events.recv_timeout(Duration::from_secs(1)).unwrap())
                    .unwrap();
            assert_eq!(event["event"], "phone-presentation");
            assert_eq!(event["version"], wire_version);
            if protocol == presentation::Protocol::BanksV2 {assert_eq!(event["bank"],bank);} else {assert!(event.get("bank").is_none());}
            assert!(event.get("presentationProtocol").is_none());
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
            result["bank"] = json!(bank);
            if outcome=="success" {
                let mut wrong=result.clone();wrong["bank"]=json!(if bank=="base" {"left-trigger"}else{"base"});
                assert_eq!(bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-presentation-reply","eventId":event["eventId"],"authorityInstanceId":"authority-a","result":wrong})).unwrap()),Err("presentation_parent_invalid"));
                // A rejected wrong-bank result cannot consume the pending correct request.
            }
            if outcome == "timeout" {
                thread::sleep(Duration::from_millis(2200));
                let reply: Value = receive(&mut client).unwrap();
                assert_eq!(reply["kind"], "error");
                assert_eq!(reply["error"], "presentation_timeout");
                assert_eq!(reply["version"], wire_version);
                client.close();
                assert_eq!(worker.join().unwrap(), Ok(()));
                let (snapshot, pin) = observed.lock().unwrap().clone().unwrap();
                assert!(snapshot.active);
                assert_eq!(snapshot.generation, "7");
                assert_ne!(
                    snapshot.report_hex,
                    crate::gamepad::hex(&crate::gamepad::NEUTRAL)
                );
                assert!(pin.is_some());
                bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-presentation-reply","eventId":event["eventId"],"authorityInstanceId":"authority-a","result":result})).unwrap()).unwrap();
                drop(input_stop_guard);
                input.unwrap().join().unwrap();
                drop(_stop);
                owner.join().unwrap();
                return;
            }
            bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-presentation-reply","eventId":event["eventId"],"authorityInstanceId":"authority-a","result":result})).unwrap()).unwrap();
            if outcome == "revoke" {
                assert!(receive::<Value>(&mut client).is_err());
                assert_eq!(worker.join().unwrap(), Err("phone_authentication_rejected"));
            } else {
                let reply: Value = receive(&mut client).unwrap();
                assert_eq!(reply["command"], "configuration-presentation-result");
                assert_eq!(reply["version"], wire_version);
                assert_eq!(reply["connectionId"], admission["connectionId"]);
                if outcome == "replace" {
                    assert_eq!(reply["kind"], "error");
                    assert_eq!(reply["error"], "presentation_reactivation_required");
                } else {
                    assert_eq!(reply["kind"], "presentation");
                    assert_eq!(reply["bank"], bank);
                    assert_eq!(reply["controlCount"], 2);
                    assert_eq!(reply["control0IconName"], "Synthetic spell");
                    assert_eq!(reply["generation"], "7");
                    assert_eq!(reply["expectedSourceHash"], "a".repeat(64));
                    assert!(reply.get("inputEnabled").is_none());
                }
                if outcome == "success" {
                  let icon_reads = if full {64} else {1};
                  for _ in 0..icon_reads {
                    let mut icon = fixture["iconRequest"].clone();
                    icon["connectionId"] = admission["connectionId"].clone();
                    icon["version"] = json!(wire_version);
                    if protocol == presentation::Protocol::BanksV2 {icon["bank"] = json!(bank);}
                    send(&mut client, icon).unwrap();
                    let event:Value = serde_json::from_str(&events.recv_timeout(Duration::from_secs(1)).unwrap()).unwrap();
                    assert_eq!(event["kind"], "icon");
                    assert_eq!(event["version"], wire_version);
                    if protocol == presentation::Protocol::BanksV2 {assert_eq!(event["bank"],bank);} else {assert!(event.get("bank").is_none());}
                    let mut icon = fixture["iconReply"].clone();
                    for key in ["version", "command", "connectionId"] { icon.as_object_mut().unwrap().remove(key); }
                    icon["authorityInstanceId"] = json!("authority-a");
                    if protocol == presentation::Protocol::BanksV2 {icon["bank"] = json!(bank);}
                    if protocol == presentation::Protocol::BanksV2 {
                        let mut wrong=icon.clone();wrong["bank"]=json!(if bank=="base" {"left-trigger"}else{"base"});
                        assert_eq!(bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-presentation-reply","eventId":event["eventId"],"authorityInstanceId":"authority-a","result":wrong})).unwrap()),Err("presentation_parent_invalid"));
                    }
                    bridge.deliver(&serde_json::to_vec(&json!({"version":1,"event":"phone-presentation-reply","eventId":event["eventId"],"authorityInstanceId":"authority-a","result":icon})).unwrap()).unwrap();
                    let reply:Value=receive(&mut client).unwrap();
                    assert_eq!(reply["kind"], "icon");
                    assert_eq!(reply["version"], wire_version);
                    if protocol == presentation::Protocol::BanksV2 {assert_eq!(reply["bank"],bank);} else {assert!(reply.get("bank").is_none());}
                    assert_eq!(reply["command"], "configuration-presentation-icon-result");
                    assert_eq!(reply["byteCount"], fixture["iconReply"]["byteCount"]);
                    assert!(reply.get("controlCount").is_none());
                  }
                  if full {
                    // One metadata plus64iconreads exhausts this management connection.
                    assert!(receive::<Value>(&mut client).is_err());
                  }
                }
                client.close();
                assert_eq!(worker.join().unwrap(), Ok(()));
            }
            drop(_stop);
            owner.join().unwrap();
        });
    }
}
