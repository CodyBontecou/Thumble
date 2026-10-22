//! Native credential admission. Authentication never grants input or exports the bearer to Bun.
use crate::{
    control_tls::{ControlChannel, FrameKind},
    phone_trust::{PhoneTrustStore, TrustedPhone},
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Mutex;

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Authenticate {
    version: u8,
    command: String,
    authority_instance_id: String,
    phone_id: String,
    credential_epoch: String,
    credential: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct Request {
    version: u8,
    command: String,
    connection_id: String,
}
// Intentionally neither constructible outside this module nor serializable/cloneable.
struct AuthorizedConnection {
    binding: [u8; 16],
    host_pin: String,
    phone: TrustedPhone,
    expires: u64,
    observed: u64,
}
fn receive<T: serde::de::DeserializeOwned>(
    channel: &mut ControlChannel,
) -> Result<T, &'static str> {
    let frame = channel
        .receive()
        .map_err(|_| "authenticated_control_transport_failed")?;
    if frame.kind != FrameKind::Control {
        return Err("authenticated_control_required");
    }
    serde_json::from_slice(&frame.payload).map_err(|_| "authenticated_control_message_invalid")
}
fn send(channel: &mut ControlChannel, value: Value) -> Result<(), &'static str> {
    channel
        .send(
            FrameKind::Control,
            &serde_json::to_vec(&value).map_err(|_| "authenticated_control_message_invalid")?,
        )
        .map_err(|_| "authenticated_control_transport_failed")
}
fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn token(value: &str) -> Result<[u8; 32], &'static str> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err("phone_authentication_rejected");
    }
    let mut bytes = [0; 32];
    for (i, pair) in value.as_bytes().chunks_exact(2).enumerate() {
        let digit = |b: u8| if b <= b'9' { b - b'0' } else { b - b'a' + 10 };
        bytes[i] = digit(pair[0]) * 16 + digit(pair[1]);
    }
    Ok(bytes)
}
impl AuthorizedConnection {
    fn admit(
        channel: &ControlChannel,
        authority: &str,
        request: Authenticate,
        store: &mut PhoneTrustStore,
        now: u64,
    ) -> Result<Self, &'static str> {
        let binding = channel
            .native_binding()
            .ok_or("phone_authentication_rejected")?;
        let host_pin = channel
            .native_server_pin()
            .ok_or("phone_authentication_rejected")?
            .hex();
        if request.version != 1
            || request.command != "authenticate"
            || request.authority_instance_id != authority
            || store.host_pin() != host_pin
        {
            return Err("phone_authentication_rejected");
        }
        let phone = store.authenticate(&request.phone_id, &token(&request.credential)?, now)?;
        if phone.credential_epoch != request.credential_epoch {
            return Err("phone_authentication_rejected");
        }
        let expires = phone.expires_at.min(
            now.checked_add(60_000)
                .ok_or("phone_authentication_rejected")?,
        );
        Ok(Self {
            binding,
            host_pin,
            phone,
            expires,
            observed: now,
        })
    }
    fn validate(
        &mut self,
        channel: &ControlChannel,
        store: &mut PhoneTrustStore,
        now: u64,
    ) -> Result<(), &'static str> {
        if channel.native_binding() != Some(self.binding)
            || channel.native_server_pin().map(|p| p.hex()).as_deref()
                != Some(self.host_pin.as_str())
            || store.host_pin() != self.host_pin
            || now < self.observed
            || now >= self.expires
        {
            return Err("phone_authentication_rejected");
        }
        store.authorize_epoch(&self.phone.phone_id, &self.phone.credential_epoch, now)?;
        self.observed = now;
        Ok(())
    }
    fn reply(&self, command: &str, authority: &str) -> Value {
        json!({"version":1,"command":command,"authorityInstanceId":authority,"phoneId":self.phone.phone_id,"credentialEpoch":self.phone.credential_epoch,"connectionId":hex(&self.binding),"expiresAt":self.expires,"inputSessionAvailable":false,"inputEnabled":false})
    }
}
#[derive(Deserialize)]
#[serde(
    tag = "command",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum InputRequest {
    ControlStatus {
        version: u8,
        connection_id: String,
    },
    Disconnect {
        version: u8,
        connection_id: String,
    },
    InputConfiguration {
        version: u8,
        connection_id: String,
    },
    InputGrant {
        version: u8,
        connection_id: String,
        generation: String,
        revision: String,
    },
    InputRelease {
        version: u8,
        connection_id: String,
        session_id: String,
    },
}
impl InputRequest {
    fn binding(&self) -> (u8, &str) {
        match self {
            Self::ControlStatus {
                version,
                connection_id,
            }
            | Self::Disconnect {
                version,
                connection_id,
            }
            | Self::InputConfiguration {
                version,
                connection_id,
            }
            | Self::InputGrant {
                version,
                connection_id,
                ..
            }
            | Self::InputRelease {
                version,
                connection_id,
                ..
            } => (*version, connection_id),
        }
    }
}
fn input_reply(authorized: &AuthorizedConnection, command: &str, authority: &str) -> Value {
    let mut value = authorized.reply(command, authority);
    value["inputSessionAvailable"] = json!(true);
    value
}
fn grant_lifetime(expires: u64, now: u64) -> Result<u32, &'static str> {
    expires
        .checked_sub(now)
        .filter(|left| *left >= 100)
        .map(|left| left.min(60_000) as u32)
        .ok_or("phone_authentication_rejected")
}
/// Control v3 remains metadata-only. V4 additionally uses the independent receiver's private IPC.
/// TLS waits occur outside policy/storage locks; native grant/packet RPC is bounded under the trust gate.
pub(crate) fn serve_after_hello(
    channel: &mut ControlChannel,
    authority: &str,
    store: &Mutex<PhoneTrustStore>,
    mutation: &Mutex<()>,
    input: Option<(&std::path::Path, &crate::input_broker::Registry)>,
    now: &mut impl FnMut() -> Result<u64, &'static str>,
) -> Result<(), &'static str> {
    let request = receive(channel)?;
    let mut authorized = {
        let _mutation = mutation
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        AuthorizedConnection::admit(
            channel,
            authority,
            request,
            &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
            now()?,
        )?
    };
    if let Some((root, registry)) = input {
        let mut broker = crate::input_broker::Broker::connect(root, registry, authorized.binding)?;
        // Handshake may have waited on local IPC; recheck trust before returning admission metadata.
        {
            let _gate = mutation
                .lock()
                .map_err(|_| "phone_trust_owner_unavailable")?;
            authorized.validate(
                channel,
                &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                now()?,
            )?;
        }
        send(
            channel,
            input_reply(&authorized, "authenticated", authority),
        )?;
        return serve_input(
            channel,
            authority,
            &mut authorized,
            &mut broker,
            store,
            mutation,
            now,
        );
    }
    send(channel, authorized.reply("authenticated", authority))?;
    for _ in 0..128 {
        let request: Request = receive(channel)?;
        if request.version != 1
            || request.connection_id != hex(&authorized.binding)
            || !["control-status", "disconnect"].contains(&request.command.as_str())
        {
            return Err("authenticated_control_message_invalid");
        }
        {
            let _gate = mutation
                .lock()
                .map_err(|_| "phone_trust_owner_unavailable")?;
            authorized.validate(
                channel,
                &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                now()?,
            )?;
        }
        if request.command == "disconnect" {
            return send(channel, authorized.reply("disconnected", authority));
        }
        send(channel, authorized.reply("control-status", authority))?;
    }
    Err("authenticated_control_budget_exhausted")
}
fn serve_input(
    channel: &mut ControlChannel,
    authority: &str,
    authorized: &mut AuthorizedConnection,
    broker: &mut crate::input_broker::Broker<'_>,
    store: &Mutex<PhoneTrustStore>,
    mutation: &Mutex<()>,
    now: &mut impl FnMut() -> Result<u64, &'static str>,
) -> Result<(), &'static str> {
    let mut controls = 0;
    let mut packets = 0;
    loop {
        let frame = channel
            .receive()
            .map_err(|_| "authenticated_control_transport_failed")?;
        if frame.kind == FrameKind::Input {
            packets += 1;
            if packets > 65_536 {
                return Err("authenticated_control_budget_exhausted");
            }
            let _gate = mutation
                .lock()
                .map_err(|_| "phone_trust_owner_unavailable")?;
            authorized.validate(
                channel,
                &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                now()?,
            )?;
            broker.packet(&frame.payload)?;
            continue;
        }
        controls += 1;
        if controls > 128 {
            return Err("authenticated_control_budget_exhausted");
        }
        let request: InputRequest = serde_json::from_slice(&frame.payload)
            .map_err(|_| "authenticated_control_message_invalid")?;
        let (version, connection) = request.binding();
        if version != 1 || connection != hex(&authorized.binding) {
            return Err("authenticated_control_message_invalid");
        }
        // Only native IPC and native trust checks run while this fence is held, never TLS I/O.
        let gate = mutation
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        let time = now()?;
        authorized.validate(
            channel,
            &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
            time,
        )?;
        let reply = match request {
            InputRequest::InputGrant {
                generation,
                revision,
                ..
            } => {
                let grant = broker.grant(
                    &authorized.phone.phone_id,
                    crate::runtime::decimal(&generation)?,
                    crate::runtime::decimal(&revision)?,
                    grant_lifetime(authorized.expires, time)?,
                )?;
                authorized.validate(
                    channel,
                    &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                    now()?,
                )?;
                drop(gate);
                crate::input_broker::deliver(&grant, channel)?;
                continue;
            }
            InputRequest::InputConfiguration { .. } => {
                let c = broker.configuration()?;
                json!({"version":1,"command":"input-configuration","connectionId":hex(&authorized.binding),"active":c.active,"generation":c.generation.to_string(),"revision":c.revision.to_string(),"inputEnabled":false})
            }
            InputRequest::InputRelease { session_id, .. } => {
                if session_id.len() != 32
                    || !session_id
                        .bytes()
                        .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                {
                    return Err("authenticated_control_message_invalid");
                }
                broker.release_scope(&session_id)?;
                json!({"version":1,"command":"input-released","connectionId":hex(&authorized.binding),"sessionId":session_id,"inputEnabled":false})
            }
            InputRequest::Disconnect { .. } => {
                broker.release()?;
                drop(gate);
                return send(channel, input_reply(authorized, "disconnected", authority));
            }
            InputRequest::ControlStatus { .. } => {
                input_reply(authorized, "control-status", authority)
            }
        };
        drop(gate);
        send(channel, reply)?;
    }
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
                "thumble-auth-{}-{}",
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
    fn channel(identity: &ServerIdentity) -> (ControlChannel, ControlChannel) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let pin = identity.pin();
        let client = thread::spawn(move || ControlChannel::connect_pinned(address, pin).unwrap());
        let server =
            ControlChannel::accept_unenrolled(listener.accept().unwrap().0, identity).unwrap();
        (server, client.join().unwrap())
    }
    #[test]
    fn native_capability_cannot_move_to_another_socket_or_survive_close_expiry_rollback_or_epoch_change(
    ) {
        let root = Root::new();
        let identity = host_identity::load_existing(&root.0).unwrap();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        let phone = store
            .enroll_after_pairing("phone-a", "Native", 100)
            .unwrap()
            .phone()
            .clone();
        let (mut server, client) = channel(&identity);
        let (other, _other_client) = channel(&identity);
        let mut capability = AuthorizedConnection {
            binding: server.native_binding().unwrap(),
            host_pin: identity.pin().hex(),
            phone,
            expires: 60_100,
            observed: 100,
        };
        assert!(capability.validate(&client, &mut store, 101).is_err());
        assert!(capability.validate(&other, &mut store, 101).is_err());
        assert!(capability.validate(&server, &mut store, 101).is_ok());
        assert!(capability.validate(&server, &mut store, 100).is_err());
        assert!(capability.validate(&server, &mut store, 60_100).is_err());
        store
            .enroll_after_pairing("phone-a", "Native", 102)
            .unwrap();
        assert!(capability.validate(&server, &mut store, 103).is_err());
        server.close();
        assert!(capability.validate(&server, &mut store, 103).is_err());
    }
    #[test]
    fn input_grants_require_a_canonical_exact_receipt_and_at_least_100ms_of_auth_lifetime() {
        assert_eq!(grant_lifetime(200, 100), Ok(100));
        assert!(grant_lifetime(199, 100).is_err());
        assert!(grant_lifetime(99, 100).is_err());
        assert_eq!(grant_lifetime(u64::MAX, 0), Ok(60_000));
        for raw in [
            r#"{"command":"input-grant","version":1,"connectionId":"a","generation":"1","revision":"1","key":"injected"}"#,
            r#"{"command":"input-grant","version":1,"connectionId":"a","generation":1,"revision":"1"}"#,
            r#"{"command":"input-grant","version":1,"connectionId":"a","generation":"1","revision":"1","revision":"2"}"#,
        ] {
            assert!(serde_json::from_str::<InputRequest>(raw).is_err());
        }
    }
    #[test]
    fn authentication_frames_are_strict_and_no_public_connection_id_substitutes_for_a_credential() {
        let valid = r#"{"version":1,"command":"authenticate","authorityInstanceId":"authority-a","phoneId":"phone-a","credentialEpoch":"1","credential":"0000000000000000000000000000000000000000000000000000000000000000"}"#;
        assert!(serde_json::from_str::<Authenticate>(valid).is_ok());
        for bad in [
            valid.replace("\"version\":1", "\"version\":1,\"version\":1"),
            valid.replace("\"version\":1", "\"version\":1,\"inputEnabled\":true"),
            valid.replace("\"version\":1", "\"version\":1.0"),
        ] {
            assert!(serde_json::from_str::<Authenticate>(&bad).is_err());
        }
        for bad in [
            "00".repeat(16),
            "AA".repeat(32),
            "gg".repeat(32),
            "0".repeat(65),
        ] {
            assert!(token(&bad).is_err());
        }
    }
}
