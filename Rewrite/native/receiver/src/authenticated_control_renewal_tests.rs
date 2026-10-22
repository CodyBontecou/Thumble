// Included in authenticated_control::tests so these tests exercise the private native seam.
#[test]
fn renewal_is_bounded_by_live_socket_epoch_clock_and_credential_expiry() {
    let root = Root::new();
    let identity = host_identity::load_existing(&root.0).unwrap();
    let mut store = PhoneTrustStore::open(&root.0).unwrap();
    let phone = store
        .enroll_after_pairing("renew-phone", "Native", 100)
        .unwrap()
        .phone()
        .clone();
    let (server, _client) = channel(&identity);
    let (other, _other_client) = channel(&identity);
    let mut auth = AuthorizedConnection {
        binding: server.native_binding().unwrap(),
        host_pin: identity.pin().hex(),
        authorization: store.cached_authorization(&phone).unwrap(),
        phone,
        expires: 60_100,
        observed: 100,
    };
    assert_eq!(
        auth.renew(&server, &mut store, 30_099),
        Err("input_renewal_too_early")
    );
    assert_eq!(auth.expires, 60_100);
    assert!(auth.renew(&other, &mut store, 30_100).is_err());
    auth.renew(&server, &mut store, 30_100).unwrap();
    assert_eq!(auth.expires, 90_100);
    assert!(auth.renew(&server, &mut store, 30_099).is_err());
    auth.renew(&server, &mut store, 61_100).unwrap();
    assert_eq!(auth.expires, 121_100);
    // The persistent credential remains the upper bound, even near its final minute.
    auth.expires = auth.phone.expires_at;
    let end = auth.phone.expires_at;
    auth.renew(&server, &mut store, end - 20_000).unwrap();
    assert_eq!(auth.expires, end);
    assert!(auth.renew(&server, &mut store, end).is_err());
}

#[test]
fn renewal_cannot_restore_a_revoked_or_replaced_phone_epoch() {
    for replace in [false, true] {
        let root = Root::new();
        let identity = host_identity::load_existing(&root.0).unwrap();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        let phone = store
            .enroll_after_pairing("renew-phone", "Native", 100)
            .unwrap()
            .phone()
            .clone();
        let (server, _client) = channel(&identity);
        let mut auth = AuthorizedConnection {
            binding: server.native_binding().unwrap(),
            host_pin: identity.pin().hex(),
            authorization: store.cached_authorization(&phone).unwrap(),
            phone,
            expires: 60_100,
            observed: 100,
        };
        if replace {
            store
                .enroll_after_pairing("renew-phone", "Replacement", 30_100)
                .unwrap();
        } else {
            store.revoke("renew-phone", 30_100).unwrap();
        }
        assert!(auth.renew(&server, &mut store, 31_100).is_err());
        assert_eq!(auth.expires, 60_100);
    }
}

fn renewal_sender(reply: &Value) -> crate::input_packet::PacketSender {
    fn bytes<const N: usize>(value: &Value) -> [u8; N] {
        let value = value.as_str().unwrap();
        assert_eq!(value.len(), N * 2);
        std::array::from_fn(|i| u8::from_str_radix(&value[i * 2..i * 2 + 2], 16).unwrap())
    }
    crate::input_packet::PacketSender::new(
        crate::input_packet::PacketGrant::new(
            &bytes(&reply["key"]),
            bytes(&reply["sessionId"]),
            bytes(&reply["noncePrefix"]),
            1,
        )
        .unwrap(),
        crate::input_packet::PACKET_LIMIT,
    )
    .unwrap()
}

#[test]
fn tls_renewals_cross_initial_wall_expiry_preserve_holds_and_retire_old_udp_routes() {
    exercise_tls_renewal(RenewalScenario::Disconnect);
}

#[test]
fn revocation_retires_current_and_prepared_keys_before_renewal_commit() {
    exercise_tls_renewal(RenewalScenario::RevokePrepared);
}

#[test]
fn revocation_retires_the_committed_successor_after_renewal_commit() {
    exercise_tls_renewal(RenewalScenario::RevokeCommitted);
}

#[test]
fn legacy_control_cannot_renew_and_invalid_renewals_release_held_input() {
    for scenario in [
        RenewalScenario::LegacyRejected,
        RenewalScenario::TooEarly,
        RenewalScenario::Expired,
    ] {
        exercise_tls_renewal(scenario);
    }
}

#[derive(Clone, Copy)]
enum RenewalScenario {
    Disconnect,
    RevokePrepared,
    RevokeCommitted,
    LegacyRejected,
    TooEarly,
    Expired,
}

fn exercise_tls_renewal(scenario: RenewalScenario) {
    use crate::{
        generated::GamepadState,
        input_broker::{Broker, Registry},
        native_ingress::Server,
        packet_runtime::PacketRuntime,
        runtime::{Command, Output},
    };
    use std::sync::{atomic::AtomicBool, Arc};
    use std::time::{Duration, Instant};
    struct Recording(Arc<Mutex<Vec<[u8; 20]>>>);
    impl Output for Recording {
        fn submit(&mut self, bytes: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            self.0.lock().unwrap().push(bytes);
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
        .enroll_after_pairing("renew-phone", "Native", 100)
        .unwrap()
        .phone()
        .clone();
    let store = Mutex::new(trust);
    let mutation = Mutex::new(());
    let registry = Registry::default();
    let clock = AtomicU64::new(100);
    let reports = Arc::new(Mutex::new(Vec::new()));
    let stop = Arc::new(AtomicBool::new(false));
    let receiver_root = root.0.join("receiver");
    crate::security::directory(&receiver_root).unwrap();
    let mut ingress = Server::bind(&receiver_root).unwrap();
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
    let neutral: GamepadState = serde_json::from_value(json!({
        "buttons":[],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,
        "leftTrigger":0,"rightTrigger":0,
    }))
    .unwrap();
    let mut held = neutral.clone();
    held.buttons.push(crate::generated::GamepadButton::South);
    held.left_trigger = 1.0;
    thread::scope(|scope| {
        let _stop = Stop(stop.clone());
        let reports_owner = reports.clone();
        let stop_owner = stop.clone();
        let owner = scope.spawn(move || {
            let start = Instant::now();
            let mut runtime = PacketRuntime::default();
            let mut output = Recording(reports_owner);
            runtime
                .apply_owner(
                    Command::Activate {
                        generation: "1".into(),
                        revision: "1".into(),
                        profile_id: "renew-profile".into(),
                        session_id: "owner".into(),
                        lease_ms: 1750,
                        input_ttl_ms: 350,
                    },
                    0,
                    &mut output,
                )
                .unwrap();
            while !stop_owner.load(Ordering::SeqCst) {
                ingress
                    .drain(
                        &mut runtime,
                        start.elapsed().as_millis() as u64,
                        &mut output,
                    )
                    .unwrap();
                thread::sleep(Duration::from_millis(1));
            }
        });
        let control = scope.spawn(|| {
            let mut broker =
                Broker::connect(&receiver_root, &registry, auth.binding, Some(42424)).unwrap();
            broker.renewal = !matches!(scenario, RenewalScenario::LegacyRejected);
            serve_input(
                &mut server,
                "authority-a",
                &mut auth,
                &mut broker,
                &store,
                &mutation,
                &mut || Ok(clock.load(Ordering::SeqCst)),
            )
        });
        let request = |client: &mut ControlChannel, mut value: Value| -> Value {
            value["version"] = json!(1);
            value["connectionId"] = json!(connection);
            send(client, value).unwrap();
            receive(client).unwrap()
        };
        let status = |client: &mut ControlChannel, session: &str| {
            request(
                client,
                json!({"command":"input-status","sessionId":session}),
            )
        };
        let grant = request(
            &mut client,
            json!({"command":"input-grant","generation":"1","revision":"1"}),
        );
        assert_eq!(grant["command"], "input-granted");
        let mut session = grant["sessionId"].as_str().unwrap().to_owned();
        let mut sender = renewal_sender(&grant);
        client
            .send(FrameKind::Input, &sender.seal(&neutral).unwrap())
            .unwrap();
        client
            .send(FrameKind::Input, &sender.seal(&held).unwrap())
            .unwrap();
        assert_eq!(status(&mut client, &session)["lastAcceptedSequence"], "1");
        let held_begin = reports.lock().unwrap().len() - 1;
        if matches!(
            scenario,
            RenewalScenario::LegacyRejected | RenewalScenario::TooEarly | RenewalScenario::Expired
        ) {
            clock.store(
                match scenario {
                    RenewalScenario::TooEarly => 1_000,
                    RenewalScenario::Expired => 60_100,
                    _ => 31_100,
                },
                Ordering::SeqCst,
            );
            send(&mut client, json!({"version":1,"command":"input-renew","connectionId":connection,"sessionId":session,"generation":"1","revision":"1"})).unwrap();
            let error = control.join().unwrap().unwrap_err();
            assert_eq!(
                error,
                match scenario {
                    RenewalScenario::TooEarly => "input_renewal_too_early",
                    RenewalScenario::Expired => "phone_authentication_rejected",
                    _ => "authenticated_control_message_invalid",
                }
            );
            assert_eq!(
                reports.lock().unwrap().last().copied(),
                Some(crate::gamepad::NEUTRAL)
            );
            assert!(registry
                .datagram_session(&sender.seal(&held).unwrap())
                .is_none());
            stop.store(true, Ordering::SeqCst);
            owner.join().unwrap();
            return;
        }
        for now in [31_100, 62_100] {
            clock.store(now, Ordering::SeqCst);
            let renewed = request(
                &mut client,
                json!({"command":"input-renew","sessionId":session,"generation":"1","revision":"1"}),
            );
            assert_eq!(renewed["command"], "input-renewed");
            assert_eq!(renewed["replacesSessionId"], session);
            assert_eq!(renewed["authorizationExpiresAt"], now + 60_000);
            assert_ne!(renewed["sessionId"], session);
            assert_ne!(renewed["key"], grant["key"]);
            let next_session = renewed["sessionId"].as_str().unwrap().to_owned();
            let mut next = renewal_sender(&renewed);
            let first = next.seal(&held).unwrap();
            // The prepared key is unavailable to UDP until reliable packet zero commits it.
            assert!(registry.datagram_session(&first).is_none());
            assert!(registry.datagram_packet(&first, &mut || Ok(now)).is_err());
            let old_packet = sender.seal(&held).unwrap();
            client.send(FrameKind::Input, &old_packet).unwrap();
            assert!(status(&mut client, &session)["active"].as_bool().unwrap());
            client.send(FrameKind::Input, &first).unwrap();
            assert_eq!(
                status(&mut client, &next_session)["lastAcceptedSequence"],
                "0"
            );
            assert!(registry.datagram_session(&first).is_some());
            assert!(registry.datagram_session(&old_packet).is_none());
            assert!(registry
                .datagram_packet(&old_packet, &mut || Ok(now))
                .is_err());
            let udp = next.seal(&held).unwrap();
            registry.datagram_packet(&udp, &mut || Ok(now)).unwrap();
            assert_eq!(
                status(&mut client, &next_session)["lastAcceptedSequence"],
                "1"
            );
            assert!(reports.lock().unwrap()[held_begin..]
                .iter()
                .all(|r| *r == held.report()));
            sender = next;
            session = next_session;
        }
        if matches!(
            scenario,
            RenewalScenario::RevokePrepared | RenewalScenario::RevokeCommitted
        ) {
            let commit = matches!(scenario, RenewalScenario::RevokeCommitted);
            clock.store(93_100, Ordering::SeqCst);
            let renewed = request(
                &mut client,
                json!({"command":"input-renew","sessionId":session,"generation":"1","revision":"1"}),
            );
            let mut prepared = renewal_sender(&renewed);
            let first = prepared.seal(&held).unwrap();
            if commit {
                client.send(FrameKind::Input, &first).unwrap();
                assert_eq!(
                    status(&mut client, renewed["sessionId"].as_str().unwrap())
                        ["lastAcceptedSequence"],
                    "0"
                );
            }
            {
                let _gate = mutation.lock().unwrap();
                store.lock().unwrap().revoke("renew-phone", 93_100).unwrap();
                registry.retire_phone("renew-phone").unwrap();
            }
            assert!(registry.datagram_session(&first).is_none());
            assert!(registry
                .datagram_packet(&first, &mut || Ok(93_100))
                .is_err());
            assert!(registry
                .datagram_packet(&sender.seal(&held).unwrap(), &mut || Ok(93_100))
                .is_err());
            send(
                &mut client,
                json!({"version":1,"command":"control-status","connectionId":connection}),
            )
            .unwrap();
            assert!(control.join().unwrap().is_err());
        } else {
            let disconnected = request(&mut client, json!({"command":"disconnect"}));
            assert_eq!(disconnected["command"], "disconnected");
            control.join().unwrap().unwrap();
        }
        assert_eq!(
            reports.lock().unwrap().last().copied(),
            Some(crate::gamepad::NEUTRAL)
        );
        assert!(registry
            .datagram_session(&sender.seal(&held).unwrap())
            .is_none());
        stop.store(true, Ordering::SeqCst);
        owner.join().unwrap();
    });
}

#[test]
fn renewal_frames_require_exact_unambiguous_native_receipts() {
    let valid = r#"{"command":"input-renew","version":1,"connectionId":"socket","sessionId":"session","generation":"1","revision":"1"}"#;
    assert!(serde_json::from_str::<InputRequest>(valid).is_ok());
    for bad in [
        valid.replace("\"generation\":\"1\"", "\"generation\":1"),
        valid.replace(
            "\"revision\":\"1\"",
            "\"revision\":\"1\",\"revision\":\"2\"",
        ),
        valid.replace("\"version\":1", "\"version\":1,\"key\":\"injected\""),
        valid.replace("\"sessionId\":\"session\"", "\"sessionId\":null"),
    ] {
        assert!(serde_json::from_str::<InputRequest>(&bad).is_err());
    }
}

#[test]
fn cached_packet_authorization_enforces_exact_connection_and_credential_expiry() {
    let root = Root::new();
    let identity = host_identity::load_existing(&root.0).unwrap();
    let mut store = PhoneTrustStore::open(&root.0).unwrap();
    let phone = store
        .enroll_after_pairing("expiry-phone", "Native", 100)
        .unwrap()
        .phone()
        .clone();
    let (server, _client) = channel(&identity);
    let mut auth = AuthorizedConnection {
        binding: server.native_binding().unwrap(),
        host_pin: identity.pin().hex(),
        authorization: store.cached_authorization(&phone).unwrap(),
        phone,
        expires: 201,
        observed: 100,
    };
    assert_eq!(auth.validate_cached(&server, &mut || Ok(200)), Ok(200));
    assert_eq!(
        auth.validate_cached(&server, &mut || Ok(201)),
        Err("phone_authentication_rejected")
    );
    auth.expires = 1000;
    auth.phone.expires_at = 202;
    assert_eq!(
        auth.validate_cached(&server, &mut || Ok(202)),
        Err("phone_authentication_rejected")
    );
}
