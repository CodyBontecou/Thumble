// Actual pinned TLS and private native IPC. A controlled stalled cleanup owner
// must not obscure the earlier malformed-control serving error.
#[cfg(debug_assertions)]
#[test]
fn original_tls_serving_failure_is_observed_before_delayed_native_release_cleanup() {
    use crate::{
        input_broker::{ControlInput, Registry},
        native_ingress::Server,
        packet_runtime::PacketRuntime,
        runtime::{Command, Output},
    };
    use std::{
        sync::{
            atomic::{AtomicBool, Ordering},
            mpsc, Arc,
        },
        time::Duration,
    };
    struct Recording;
    impl Output for Recording {
        fn submit(&mut self, _: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            Ok(())
        }
    }
    let root = Root::new();
    let identity = host_identity::load_existing(&root.0).unwrap();
    let mut trust = PhoneTrustStore::open(&root.0).unwrap();
    let issued = trust
        .enroll_after_pairing("diagnostic-phone", "Synthetic", 100)
        .unwrap();
    let (mut delivery, mut enrollment_client) = channel(&identity);
    issued.send_enrollment(&mut delivery).unwrap();
    let credential: Value = receive(&mut enrollment_client).unwrap();
    delivery.close();
    enrollment_client.close();
    let store = Mutex::new(trust);
    let mutation = Mutex::new(());
    let registry = Registry::default();
    let receiver_root = root.0.join("receiver");
    crate::security::directory(&receiver_root).unwrap();
    let mut ingress = Server::bind(&receiver_root).unwrap();
    let (pause, pause_rx) = mpsc::sync_channel(1);
    let (paused, paused_rx) = mpsc::sync_channel(1);
    let (resume, resume_rx) = mpsc::sync_channel(1);
    let stopping = Arc::new(AtomicBool::new(false));
    let (observed, observation) = mpsc::sync_channel(1);
    let (mut server, mut client) = channel(&identity);
    thread::scope(|scope| {
        struct Stop(Arc<AtomicBool>);
        impl Drop for Stop {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }
        let _stop = Stop(stopping.clone());
        let owner_stopping = stopping.clone();
        let owner = scope.spawn(move || {
            let mut runtime = PacketRuntime::default();
            let mut output = Recording;
            runtime
                .apply_owner(
                    Command::Activate {
                        generation: "1".into(),
                        revision: "1".into(),
                        profile_id: "diagnostic-profile".into(),
                        session_id: "owner".into(),
                        lease_ms: 750,
                        input_ttl_ms: 350,
                    },
                    100,
                    &mut output,
                )
                .unwrap();
            loop {
                if owner_stopping.load(Ordering::SeqCst) {
                    break;
                }
                if pause_rx.try_recv().is_ok() {
                    paused.send(()).unwrap();
                    if resume_rx.recv_timeout(Duration::from_secs(3)).is_err() {
                        break;
                    }
                }
                ingress.drain(&mut runtime, 100, &mut output).unwrap();
                thread::sleep(Duration::from_millis(1));
            }
        });
        let worker = scope.spawn(|| {
            crate::input_error_diagnostics::capture_control_before_cleanup_for_test(observed);
            serve_after_hello(
                &mut server,
                "authority-a",
                &store,
                &mutation,
                Some(ControlInput {
                    root: &receiver_root,
                    registry: &registry,
                    datagram_port: None,
                    renewal: false,
                    physical: false,
                }),
                None,
                &mut || Ok(100),
            )
        });
        send(&mut client,json!({"version":1,"command":"authenticate","authorityInstanceId":"authority-a","phoneId":"diagnostic-phone","credentialEpoch":"1","credential":credential["credential"]})).unwrap();
        let admission: Value = receive(&mut client).unwrap();
        send(&mut client,json!({"version":1,"command":"input-grant","connectionId":admission["connectionId"],"generation":"1","revision":"1"})).unwrap();
        let grant: Value = receive(&mut client).unwrap();
        assert_eq!(grant["command"], "input-granted");
        pause.send(()).unwrap();
        paused_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        send(&mut client,json!({"version":0,"command":"input-status","connectionId":admission["connectionId"],"sessionId":grant["sessionId"]})).unwrap();
        let first = observation.recv_timeout(Duration::from_secs(1)).unwrap();
        assert_eq!(
            first,
            json!({"version":1,"role":"broker","context":"phone-control-before-cleanup","stage":"decode-control","code":"authenticated_control_message_invalid"})
        );
        // Deliberately keep cleanup from receiving an ACK for longer than its
        // existing 250 ms budget. This is a fault, not an expanded product budget.
        thread::sleep(Duration::from_millis(300));
        resume.send(()).unwrap();
        assert_eq!(
            worker.join().unwrap(),
            Err("authenticated_control_message_invalid")
        );
        assert!(observation.try_recv().is_err());
        stopping.store(true, Ordering::SeqCst);
        owner.join().unwrap();
    });
}
