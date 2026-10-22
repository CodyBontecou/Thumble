//! Native enrollment policy. Only trusted local setup may open windows; no input is granted here.
use crate::{
    control_tls::{CertificatePin, ControlChannel, FrameKind},
    phone_trust::{PhoneTrustStore, TrustedPhone},
    runtime,
};
use ring::{
    digest,
    rand::{SecureRandom, SystemRandom},
};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use subtle::ConstantTimeEq;

const WINDOW_MS: u64 = 120_000;
const ATTEMPTS: u8 = 5;
const MAX_TIME: u64 = 9_007_199_254_740_991 - WINDOW_MS;
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn secret(text: &str) -> bool {
    text.len() == 64
        && text
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn verifier(authority: &str, id: &str, proof: &str) -> [u8; 32] {
    let text = format!("thumble-rewrite/pairing/v1\0{authority}\0{id}\0{proof}");
    digest::digest(&digest::SHA256, text.as_bytes())
        .as_ref()
        .try_into()
        .expect("SHA-256 length")
}
/// Secret-bearing offer for authenticated same-user setup only. Never embed it in status or logs.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PairingOffer {
    pub window_id: String,
    pub secret: String,
    pub expires_at: u64,
}
#[derive(Serialize, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PairingStatus {
    pub state: &'static str,
    pub network_enabled: bool,
    pub window_id: Option<String>,
    pub expires_at: Option<u64>,
    pub attempts_remaining: u8,
}
struct Pending {
    id: String,
    verifier: [u8; 32],
    expires: u64,
    attempts: u8,
}
pub struct PairingWindows {
    authority: String,
    pin: CertificatePin,
    pending: Option<Pending>,
    last: Option<u64>,
}
impl PairingWindows {
    pub fn new(authority: &str, pin: CertificatePin) -> Result<Self, &'static str> {
        if !runtime::identity(authority) {
            return Err("pairing_authority_invalid");
        }
        Ok(Self {
            authority: authority.into(),
            pin,
            pending: None,
            last: None,
        })
    }
    fn observe(&mut self, now: u64) -> Result<(), &'static str> {
        if now > MAX_TIME || self.last.is_some_and(|last| now < last) {
            self.pending = None;
            return Err("pairing_clock_invalid");
        }
        self.last = Some(now);
        if self.pending.as_ref().is_some_and(|p| now >= p.expires) {
            self.pending = None;
        }
        Ok(())
    }
    pub fn open(&mut self, now: u64) -> Result<PairingOffer, &'static str> {
        self.pending = None;
        self.observe(now)?;
        let mut entropy = [0; 48];
        SystemRandom::new()
            .fill(&mut entropy)
            .map_err(|_| "pairing_entropy_failed")?;
        self.install(now, hex(&entropy[..16]), hex(&entropy[16..]))
    }
    fn install(
        &mut self,
        now: u64,
        id: String,
        proof: String,
    ) -> Result<PairingOffer, &'static str> {
        let expires = now + WINDOW_MS;
        self.pending = Some(Pending {
            id: id.clone(),
            verifier: verifier(&self.authority, &id, &proof),
            expires,
            attempts: ATTEMPTS,
        });
        Ok(PairingOffer {
            window_id: id,
            secret: proof,
            expires_at: expires,
        })
    }
    pub fn cancel(&mut self) {
        self.pending = None;
    }
    pub fn status(&mut self, now: u64) -> Result<PairingStatus, &'static str> {
        self.observe(now)?;
        Ok(PairingStatus {
            state: if self.pending.is_some() {
                "open"
            } else {
                "closed"
            },
            network_enabled: false,
            window_id: self.pending.as_ref().map(|p| p.id.clone()),
            expires_at: self.pending.as_ref().map(|p| p.expires),
            attempts_remaining: self.pending.as_ref().map_or(0, |p| p.attempts),
        })
    }
    fn consume(
        &mut self,
        authority: &str,
        id: &str,
        proof: &str,
        now: u64,
    ) -> Result<(), &'static str> {
        self.observe(now)?;
        let p = self.pending.as_mut().ok_or("pairing_closed")?;
        p.attempts -= 1;
        // Fixed-size comparison even when the public identifiers do not match.
        let candidate = if secret(proof) {
            verifier(authority, id, proof)
        } else {
            [0; 32]
        };
        let accepted = bool::from(candidate.ct_eq(&p.verifier))
            && authority == self.authority
            && id == p.id
            && secret(proof);
        if accepted || p.attempts == 0 {
            self.pending = None;
        }
        if accepted {
            Ok(())
        } else {
            Err("pairing_proof_rejected")
        }
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Hello {
    version: u8,
    command: String,
    control_version: u8,
    input_version: u8,
    document_version: u8,
    capabilities_version: u8,
    #[serde(default, deserialize_with = "non_null_role")]
    role: Option<String>,
}
fn non_null_role<'de, D: serde::Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    String::deserialize(d).map(Some)
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Enroll {
    version: u8,
    command: String,
    authority_instance_id: String,
    window_id: String,
    proof: String,
    phone_id: String,
    label: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Acknowledgment {
    version: u8,
    command: String,
    phone_id: String,
    credential_epoch: String,
}
fn receive<T: serde::de::DeserializeOwned>(
    channel: &mut ControlChannel,
) -> Result<T, &'static str> {
    let frame = channel
        .receive()
        .map_err(|_| "enrollment_transport_failed")?;
    if frame.kind != FrameKind::Control {
        return Err("enrollment_control_required");
    }
    serde_json::from_slice(&frame.payload).map_err(|_| "enrollment_message_invalid")
}
/// Blocking native worker operation. Never call from the input/safety/UI thread.
/// The clock callback must read trusted native wall time, not peer timestamps.
/// On every failure the TLS channel is closed; a consumed invitation is never restored.
pub fn enroll(
    channel: &mut ControlChannel,
    windows: &Mutex<PairingWindows>,
    store: &Mutex<PhoneTrustStore>,
    policy_mutation: &Mutex<()>,
    mut now: impl FnMut() -> Result<u64, &'static str>,
) -> Result<TrustedPhone, &'static str> {
    let result = (|| {
        begin(channel, windows, store, 2)?;
        complete(channel, windows, store, policy_mutation, None, &mut now)
    })();
    if result.is_err() {
        channel.close();
    }
    result
}
pub(crate) fn serve(
    channel: &mut ControlChannel,
    windows: &Mutex<PairingWindows>,
    store: &Mutex<PhoneTrustStore>,
    policy_mutation: &Mutex<()>,
    input: crate::input_broker::ControlInput<'_>,
    management: crate::authenticated_control::ManagementBridges<'_>,
    mut now: impl FnMut() -> Result<u64, &'static str>,
) -> Result<(), &'static str> {
    let crate::authenticated_control::ManagementBridges { catalog, controls } = management;
    let result = (|| match begin(
        channel,
        windows,
        store,
        if controls.is_some_and(|bridge| bridge.enabled()) {
            8
        } else if catalog.enabled() {
            7
        } else if input.datagram_port.is_some() {
            6
        } else {
            4
        },
    )? {
        2 => complete(
            channel,
            windows,
            store,
            policy_mutation,
            Some(input.registry),
            &mut now,
        )
        .map(|_| ()),
        5 | 6 if input.datagram_port.is_none() => Err("enrollment_version_unsupported"),
        7 if !catalog.enabled() => Err("enrollment_version_unsupported"),
        8 if !controls.is_some_and(|bridge| bridge.enabled()) => {
            Err("enrollment_version_unsupported")
        }
        version @ 3..=8 => {
            let authority = windows
                .lock()
                .map_err(|_| "pairing_owner_unavailable")?
                .authority
                .clone();
            crate::authenticated_control::serve_after_hello(
                channel,
                &authority,
                store,
                policy_mutation,
                if (4..=6).contains(&version) {
                    Some(crate::input_broker::ControlInput {
                        root: input.root,
                        registry: input.registry,
                        renewal: version == 6,
                        datagram_port: if version >= 5 {
                            input.datagram_port
                        } else {
                            None
                        },
                    })
                } else {
                    None
                },
                match version {
                    7 => Some(crate::authenticated_control::ManagementRole::Catalog(
                        catalog,
                    )),
                    8 => controls.map(crate::authenticated_control::ManagementRole::Controls),
                    _ => None,
                },
                &mut now,
            )
        }
        _ => Err("enrollment_version_unsupported"),
    })();
    channel.close();
    #[cfg(debug_assertions)]
    if let Err(error) = &result {
        crate::input_io_diagnostics::terminal("phone-control", 0, error);
    }
    result
}
fn begin(
    channel: &mut ControlChannel,
    windows: &Mutex<PairingWindows>,
    store: &Mutex<PhoneTrustStore>,
    max_version: u8,
) -> Result<u8, &'static str> {
    let (authority, pin) = {
        let policy = windows.lock().map_err(|_| "pairing_owner_unavailable")?;
        (policy.authority.clone(), policy.pin)
    };
    if channel.native_server_pin() != Some(pin)
        || store
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?
            .host_pin()
            != pin.hex()
    {
        return Err("enrollment_host_mismatch");
    }
    let hello: Hello = receive(channel)?;
    if hello.version != 1
        || hello.command != "hello"
        || !(2..=max_version).contains(&hello.control_version)
        || (if matches!(hello.control_version, 7 | 8) {
            hello.role.as_deref() != Some("management")
        } else {
            hello.role.is_some()
        })
        || hello.input_version != 1
        || hello.document_version != 1
        || hello.capabilities_version != 1
    {
        return Err("enrollment_version_unsupported");
    }
    let mut reply = serde_json::json!({"version":1,"command":"hello","authorityInstanceId":authority,"controlVersion":hello.control_version,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1,"inputEnabled":false});
    if matches!(hello.control_version, 7 | 8) {
        reply["role"] = serde_json::json!("management");
    }
    channel
        .send(
            FrameKind::Control,
            &serde_json::to_vec(&reply).map_err(|_| "enrollment_message_invalid")?,
        )
        .map_err(|_| "enrollment_transport_failed")?;
    Ok(hello.control_version)
}
fn complete(
    channel: &mut ControlChannel,
    windows: &Mutex<PairingWindows>,
    store: &Mutex<PhoneTrustStore>,
    policy_mutation: &Mutex<()>,
    input_grants: Option<&crate::input_broker::Registry>,
    now: &mut impl FnMut() -> Result<u64, &'static str>,
) -> Result<TrustedPhone, &'static str> {
    let request: Enroll = receive(channel)?;
    if request.version != 1 || request.command != "enroll" {
        return Err("enrollment_message_invalid");
    }
    crate::phone_trust::validate_phone(&request.phone_id, &request.label)?;
    let (issued, retired) = {
        let _mutation = policy_mutation
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        let proof_time = match now() {
            Ok(time) => time,
            Err(error) => {
                windows
                    .lock()
                    .map_err(|_| "pairing_owner_unavailable")?
                    .cancel();
                return Err(error);
            }
        };
        windows
            .lock()
            .map_err(|_| "pairing_owner_unavailable")?
            .consume(
                &request.authority_instance_id,
                &request.window_id,
                &request.proof,
                proof_time,
            )?;
        let mut store = store.lock().map_err(|_| "phone_trust_owner_unavailable")?;
        let retired = store.detach_scope(&request.phone_id)?;
        let result = (|| {
            if let Some(grants) = input_grants {
                grants.retire_phone(&request.phone_id)?;
            }
            store.enroll_now(&request.phone_id, &request.label, now)
        })();
        (result, retired)
    };
    // No global store/policy lock covers a backpressured old management send.
    if let Some(retired) = retired {
        retired.wait_management_delivery()?;
    }
    let issued = issued?;
    issued.send_enrollment(channel)?;
    let ack: Acknowledgment =
        receive(channel).map_err(|_| "phone_credential_delivery_unconfirmed")?;
    if ack.version != 1
        || ack.command != "enrollment-stored"
        || ack.phone_id != issued.phone().phone_id
        || ack.credential_epoch != issued.phone().credential_epoch
    {
        return Err("phone_credential_delivery_unconfirmed");
    }
    let completed = serde_json::json!({"version":1,"command":"enrollment-complete","phoneId":issued.phone().phone_id,"credentialEpoch":issued.phone().credential_epoch,"inputEnabled":false});
    channel
        .send(
            FrameKind::Control,
            &serde_json::to_vec(&completed).map_err(|_| "phone_credential_delivery_unconfirmed")?,
        )
        .map_err(|_| "phone_credential_delivery_unconfirmed")?;
    Ok(issued.phone().clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{control_tls::ServerIdentity, host_identity};
    use std::{
        fs,
        net::TcpListener,
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
        thread,
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let root = Self(std::env::temp_dir().canonicalize().unwrap().join(format!(
                "thumble-enrollment-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            )));
            host_identity::load_or_create(&root.0).unwrap();
            root
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn send(channel: &mut ControlChannel, value: serde_json::Value) {
        channel
            .send(FrameKind::Control, &serde_json::to_vec(&value).unwrap())
            .unwrap();
    }
    fn hello() -> serde_json::Value {
        serde_json::json!({"version":1,"command":"hello","controlVersion":2,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1})
    }
    fn request(offer: &PairingOffer) -> serde_json::Value {
        serde_json::json!({"version":1,"command":"enroll","authorityInstanceId":"authority-a","windowId":offer.window_id,"proof":offer.secret,"phoneId":"phone-a","label":"Controller"})
    }
    fn token(value: &serde_json::Value) -> Vec<u8> {
        value["credential"]
            .as_str()
            .unwrap()
            .as_bytes()
            .chunks_exact(2)
            .map(|v| u8::from_str_radix(std::str::from_utf8(v).unwrap(), 16).unwrap())
            .collect()
    }
    fn exercise(
        client: impl FnOnce(&mut ControlChannel, &PairingOffer),
    ) -> (Root, Result<TrustedPhone, &'static str>, PairingStatus) {
        exercise_policy(|channel, offer, _| client(channel, offer))
    }
    fn exercise_policy(
        client: impl FnOnce(&mut ControlChannel, &PairingOffer, &Mutex<PairingWindows>),
    ) -> (Root, Result<TrustedPhone, &'static str>, PairingStatus) {
        exercise_clock(client, || Ok(101))
    }
    fn exercise_clock(
        client: impl FnOnce(&mut ControlChannel, &PairingOffer, &Mutex<PairingWindows>),
        clock: impl FnMut() -> Result<u64, &'static str> + Send + 'static,
    ) -> (Root, Result<TrustedPhone, &'static str>, PairingStatus) {
        let root = Root::new();
        let identity = host_identity::load_existing(&root.0).unwrap();
        let pin = identity.pin();
        let mut windows = PairingWindows::new("authority-a", pin).unwrap();
        let offer = windows.open(100).unwrap();
        let windows = std::sync::Arc::new(Mutex::new(windows));
        let owner = windows.clone();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let path = root.0.clone();
        let worker = thread::spawn(move || {
            let store = Mutex::new(PhoneTrustStore::open(&path).unwrap());
            let (stream, _) = listener.accept().unwrap();
            let mut channel = ControlChannel::accept_unenrolled(stream, &identity).unwrap();
            let result = enroll(&mut channel, &windows, &store, &Mutex::new(()), clock);
            (result, windows.lock().unwrap().status(102).unwrap())
        });
        let mut channel = ControlChannel::connect_pinned(address, pin).unwrap();
        client(&mut channel, &offer, &owner);
        channel.close();
        let (result, status) = worker.join().unwrap();
        (root, result, status)
    }
    #[test]
    fn native_windows_are_one_use_bounded_and_secret_free_in_status() {
        let pin = ServerIdentity::generate().unwrap().pin();
        assert!(PairingWindows::new("bad id", pin).is_err());
        let mut windows = PairingWindows::new("authority-a", pin).unwrap();
        let first = windows.open(10).unwrap();
        let status = serde_json::to_string(&windows.status(10).unwrap()).unwrap();
        assert!(!status.contains(&first.secret));
        assert_eq!(first.expires_at, 120_010);
        for i in 0..5 {
            assert_eq!(
                windows
                    .consume("authority-a", &first.window_id, "wrong", 10)
                    .err(),
                Some("pairing_proof_rejected")
            );
            assert_eq!(windows.status(10).unwrap().attempts_remaining, 4 - i);
        }
        assert_eq!(
            windows
                .consume("authority-a", &first.window_id, &first.secret, 10)
                .err(),
            Some("pairing_closed")
        );
        let fresh = windows.open(11).unwrap();
        windows
            .consume("authority-a", &fresh.window_id, &fresh.secret, 11)
            .unwrap();
        assert_eq!(
            windows
                .consume("authority-a", &fresh.window_id, &fresh.secret, 11)
                .err(),
            Some("pairing_closed")
        );
        let old = windows.open(12).unwrap();
        let replacement = windows.open(12).unwrap();
        assert_ne!(old.window_id, replacement.window_id);
        assert_ne!(old.secret, replacement.secret);
        assert!(windows
            .consume("authority-a", &old.window_id, &old.secret, 12)
            .is_err());
        windows.cancel();
        assert_eq!(windows.status(12).unwrap().attempts_remaining, 0);
        let last = windows.open(13).unwrap();
        assert_eq!(
            windows
                .consume(
                    "authority-a",
                    &last.window_id,
                    &last.secret,
                    last.expires_at
                )
                .err(),
            Some("pairing_closed")
        );
    }
    #[test]
    fn window_clock_and_authority_failures_do_not_retain_admission() {
        let pin = ServerIdentity::generate().unwrap().pin();
        let mut w = PairingWindows::new("authority-a", pin).unwrap();
        let p = w.open(100).unwrap();
        assert_eq!(
            w.consume("other", &p.window_id, &p.secret, 100).err(),
            Some("pairing_proof_rejected")
        );
        assert_eq!(w.status(100).unwrap().attempts_remaining, 4);
        assert_eq!(w.status(99).err(), Some("pairing_clock_invalid"));
        assert!(w.pending.is_none());
        assert!(w.open(u64::MAX).is_err());
        assert!(w.pending.is_none());
        assert_eq!(
            PairingWindows::new("authority-a", pin)
                .unwrap()
                .status(100)
                .unwrap()
                .attempts_remaining,
            0
        );
    }
    #[test]
    fn real_tls_negotiates_versions_commits_then_requires_matching_storage_ack() {
        let mut credential = Vec::new();
        let (root, result, status) = exercise(|channel, offer| {
            send(channel, hello());
            let greeting: serde_json::Value = receive(channel).unwrap();
            assert_eq!(greeting["authorityInstanceId"], "authority-a");
            assert_eq!(greeting["inputEnabled"], false);
            send(channel, request(offer));
            let reply: serde_json::Value = receive(channel).unwrap();
            assert_eq!(reply["command"], "enrolled");
            credential = token(&reply);
            send(
                channel,
                serde_json::json!({"version":1,"command":"enrollment-stored","phoneId":"phone-a","credentialEpoch":reply["credentialEpoch"]}),
            );
            let completed: serde_json::Value = receive(channel).unwrap();
            assert_eq!(completed["command"], "enrollment-complete");
            assert_eq!(completed["inputEnabled"], false);
        });
        assert_eq!(result.unwrap().credential_epoch, "1");
        assert_eq!(status.attempts_remaining, 0);
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        assert!(store.authenticate("phone-a", &credential, 1101).is_ok());
        store.revoke("phone-a", 1102).unwrap();
        assert!(store.authenticate("phone-a", &credential, 1103).is_err());
    }
    #[test]
    fn unsupported_versions_and_wrong_phase_frames_never_consume_invitation() {
        for field in [
            "version",
            "controlVersion",
            "inputVersion",
            "documentVersion",
            "capabilitiesVersion",
        ] {
            let (root, result, status) = exercise(|channel, _| {
                let mut value = hello();
                value[field] = serde_json::json!(if field == "controlVersion" { 3 } else { 2 });
                send(channel, value);
                assert!(channel.receive().is_err());
            });
            assert_eq!(result.err(), Some("enrollment_version_unsupported"));
            assert_eq!(status.attempts_remaining, 5);
            assert!(PhoneTrustStore::open(&root.0)
                .unwrap()
                .list()
                .unwrap()
                .is_empty());
        }
        let (root, result, status) = exercise(|channel, offer| {
            send(channel, request(offer));
            assert!(channel.receive().is_err());
        });
        assert_eq!(result.err(), Some("enrollment_message_invalid"));
        assert_eq!(status.attempts_remaining, 5);
        assert!(PhoneTrustStore::open(&root.0)
            .unwrap()
            .list()
            .unwrap()
            .is_empty());
        let (_, result, status) = exercise(|channel, _| {
            channel.send(FrameKind::Input, &[0; 108]).unwrap();
            assert!(channel.receive().is_err());
        });
        assert_eq!(result.err(), Some("enrollment_control_required"));
        assert_eq!(status.attempts_remaining, 5);
    }
    #[test]
    fn wrong_proof_spends_attempt_without_committing_trust() {
        let (root, result, status) = exercise(|channel, offer| {
            send(channel, hello());
            let _: serde_json::Value = receive(channel).unwrap();
            let mut value = request(offer);
            value["proof"] = serde_json::json!("00".repeat(32));
            send(channel, value);
            assert!(channel.receive().is_err());
        });
        assert_eq!(result.err(), Some("pairing_proof_rejected"));
        assert_eq!(status.attempts_remaining, 4);
        assert!(PhoneTrustStore::open(&root.0)
            .unwrap()
            .list()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn lost_or_mismatched_ack_preserves_committed_trust_and_consumed_window() {
        for ack in [false, true] {
            let mut credential = Vec::new();
            let (root, result, status) = exercise(|channel, offer| {
                send(channel, hello());
                let _: serde_json::Value = receive(channel).unwrap();
                send(channel, request(offer));
                let reply: serde_json::Value = receive(channel).unwrap();
                credential = token(&reply);
                if ack {
                    send(
                        channel,
                        serde_json::json!({"version":1,"command":"enrollment-stored","phoneId":"phone-a","credentialEpoch":"2"}),
                    );
                    assert!(channel.receive().is_err());
                }
            });
            assert_eq!(result.err(), Some("phone_credential_delivery_unconfirmed"));
            assert_eq!(status.attempts_remaining, 0);
            assert!(PhoneTrustStore::open(&root.0)
                .unwrap()
                .authenticate("phone-a", &credential, 1101)
                .is_ok());
        }
    }
    #[test]
    fn duplicate_or_unknown_json_fields_fail_before_proof_admission() {
        for raw in [br#"{"version":1,"version":1,"command":"hello","controlVersion":2,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1}"#.as_slice(),br#"{"version":1,"command":"hello","controlVersion":2,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1,"extra":true}"#] {
            let (_,result,status)=exercise(|channel,_|{channel.send(FrameKind::Control,raw).unwrap();assert!(channel.receive().is_err());});
            assert_eq!(result.err(),Some("enrollment_message_invalid"));assert_eq!(status.attempts_remaining,5);
        }
    }
    #[test]
    fn client_role_cannot_consume_native_enrollment_window() {
        let root = Root::new();
        let identity = host_identity::load_existing(&root.0).unwrap();
        let pin = identity.pin();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut channel = ControlChannel::accept_unenrolled(stream, &identity).unwrap();
            assert!(channel.receive().is_err());
        });
        let mut client = ControlChannel::connect_pinned(address, pin).unwrap();
        let store = Mutex::new(PhoneTrustStore::open(&root.0).unwrap());
        let mut w = PairingWindows::new("authority-a", pin).unwrap();
        w.open(100).unwrap();
        let w = Mutex::new(w);
        assert_eq!(
            enroll(&mut client, &w, &store, &Mutex::new(()), || Ok(101)).err(),
            Some("enrollment_host_mismatch")
        );
        assert_eq!(w.lock().unwrap().status(102).unwrap().attempts_remaining, 5);
        assert!(store.lock().unwrap().list().unwrap().is_empty());
        server.join().unwrap();
    }
    #[test]
    fn local_cancel_or_replacement_during_tls_wait_prevents_enrollment() {
        for replace in [false, true] {
            let (root, result, status) = exercise_policy(|channel, offer, windows| {
                send(channel, hello());
                let _: serde_json::Value = receive(channel).unwrap();
                // This local policy lock must be available while the worker waits for its next frame.
                let mut policy = windows
                    .try_lock()
                    .expect("TLS read must not retain policy lock");
                if replace {
                    policy.open(101).unwrap();
                } else {
                    policy.cancel();
                }
                drop(policy);
                send(channel, request(offer));
                assert!(channel.receive().is_err());
            });
            assert_eq!(
                result.err(),
                Some(if replace {
                    "pairing_proof_rejected"
                } else {
                    "pairing_closed"
                })
            );
            assert_eq!(status.attempts_remaining, if replace { 4 } else { 0 });
            assert!(PhoneTrustStore::open(&root.0)
                .unwrap()
                .list()
                .unwrap()
                .is_empty());
        }
    }
    #[test]
    fn shared_typescript_fixture_matches_native_verifier_and_control_shapes() {
        let fixture: serde_json::Value = serde_json::from_slice(include_bytes!(
            "../../../packages/fixtures/enrollment-v1.json"
        ))
        .unwrap();
        let a = fixture["authorityInstanceId"].as_str().unwrap();
        let id = fixture["offer"]["windowId"].as_str().unwrap();
        let proof = fixture["offer"]["secret"].as_str().unwrap();
        assert_eq!(hex(&verifier(a, id, proof)), fixture["windowVerifier"]);
        let _: Hello = serde_json::from_value(fixture["hello"].clone()).unwrap();
        let _: Enroll = serde_json::from_value(fixture["enroll"].clone()).unwrap();
        let _: Acknowledgment = serde_json::from_value(fixture["acknowledgment"].clone()).unwrap();
        let pin = ServerIdentity::generate().unwrap().pin();
        let mut policy = PairingWindows::new(a, pin).unwrap();
        let now = fixture["openedAt"].as_u64().unwrap();
        let offer = policy.install(now, id.into(), proof.into()).unwrap();
        assert_eq!(serde_json::to_value(offer).unwrap(), fixture["offer"]);
        policy.consume(a, id, proof, now).unwrap();
        assert!(policy.pending.is_none());
    }
    #[test]
    fn native_clock_failure_closes_window_before_any_credential_is_issued() {
        let (root, result, status) = exercise_clock(
            |channel, offer, _| {
                send(channel, hello());
                let _: serde_json::Value = receive(channel).unwrap();
                send(channel, request(offer));
                assert!(channel.receive().is_err());
            },
            || Err("native_clock_failed"),
        );
        assert_eq!(result.err(), Some("native_clock_failed"));
        assert_eq!(status.attempts_remaining, 0);
        assert!(PhoneTrustStore::open(&root.0)
            .unwrap()
            .list()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn trust_clock_failure_after_consumption_does_not_restore_window() {
        let mut calls = 0;
        let (root, result, status) = exercise_clock(
            |channel, offer, _| {
                send(channel, hello());
                let _: serde_json::Value = receive(channel).unwrap();
                send(channel, request(offer));
                assert!(channel.receive().is_err());
            },
            move || {
                calls += 1;
                if calls == 1 {
                    Ok(101)
                } else {
                    Err("native_clock_failed")
                }
            },
        );
        assert_eq!(result.err(), Some("native_clock_failed"));
        assert_eq!(status.attempts_remaining, 0);
        assert!(PhoneTrustStore::open(&root.0)
            .unwrap()
            .list()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn earlier_control_version_is_rejected_before_invitation_consumption() {
        let (root, result, status) = exercise(|channel, _| {
            let mut value = hello();
            value["controlVersion"] = serde_json::json!(1);
            send(channel, value);
            assert!(channel.receive().is_err());
        });
        assert_eq!(result.err(), Some("enrollment_version_unsupported"));
        assert_eq!(status.attempts_remaining, 5);
        assert!(PhoneTrustStore::open(&root.0)
            .unwrap()
            .list()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn renewal_revision_is_explicit_and_requires_a_datagram_capable_host() {
        for (version, maximum, accepted) in [
            (4, 6, true),
            (5, 6, true),
            (6, 6, true),
            (6, 4, false),
            (7, 6, false),
        ] {
            let root = Root::new();
            let identity = host_identity::load_existing(&root.0).unwrap();
            let pin = identity.pin();
            let windows = Mutex::new(PairingWindows::new("authority-a", pin).unwrap());
            let store = Mutex::new(PhoneTrustStore::open(&root.0).unwrap());
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap();
            thread::scope(|scope| {
                let worker = scope.spawn(|| {
                    let mut channel =
                        ControlChannel::accept_unenrolled(listener.accept().unwrap().0, &identity)
                            .unwrap();
                    begin(&mut channel, &windows, &store, maximum)
                });
                let mut channel = ControlChannel::connect_pinned(address, pin).unwrap();
                let mut value = hello();
                value["controlVersion"] = serde_json::json!(version);
                send(&mut channel, value);
                if accepted {
                    let reply: serde_json::Value = receive(&mut channel).unwrap();
                    assert_eq!(reply["controlVersion"], version);
                    assert_eq!(worker.join().unwrap(), Ok(version));
                } else {
                    assert!(channel.receive().is_err());
                    assert_eq!(
                        worker.join().unwrap(),
                        Err("enrollment_version_unsupported")
                    );
                }
            });
            assert!(store.lock().unwrap().list().unwrap().is_empty());
        }
    }
    #[test]
    fn management_role_cannot_downgrade_into_any_legacy_input_version() {
        for version in 2..=7 {
            for role in [
                None,
                Some(serde_json::json!(null)),
                Some(serde_json::json!("input")),
                Some(serde_json::json!("management")),
            ] {
                let root = Root::new();
                let identity = host_identity::load_existing(&root.0).unwrap();
                let windows =
                    Mutex::new(PairingWindows::new("authority-a", identity.pin()).unwrap());
                let store = Mutex::new(PhoneTrustStore::open(&root.0).unwrap());
                let listener = TcpListener::bind("127.0.0.1:0").unwrap();
                let address = listener.local_addr().unwrap();
                let accepted = (version == 7 && role == Some(serde_json::json!("management")))
                    || (version < 7 && role.is_none());
                thread::scope(|scope| {
                    let worker = scope.spawn(|| {
                        let mut channel = ControlChannel::accept_unenrolled(
                            listener.accept().unwrap().0,
                            &identity,
                        )
                        .unwrap();
                        begin(&mut channel, &windows, &store, 7)
                    });
                    let mut channel =
                        ControlChannel::connect_pinned(address, identity.pin()).unwrap();
                    let mut value = hello();
                    value["controlVersion"] = serde_json::json!(version);
                    if let Some(role) = role {
                        value["role"] = role;
                    }
                    send(&mut channel, value);
                    if accepted {
                        let reply: serde_json::Value = receive(&mut channel).unwrap();
                        assert_eq!(
                            reply.get("role"),
                            (version == 7).then_some(&serde_json::json!("management"))
                        );
                        assert_eq!(worker.join().unwrap(), Ok(version));
                    } else {
                        assert!(channel.receive().is_err());
                        assert!(worker.join().unwrap().is_err());
                    }
                });
            }
        }
    }
}
