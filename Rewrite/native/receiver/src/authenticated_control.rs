//! Native credential admission. Authentication never grants input or exports the bearer to Bun.
use crate::{
    control_tls::{ControlChannel, FrameKind},
    phone_trust::{PhoneTrustStore, TrustedPhone},
};
#[path = "phone_catalog.rs"]
pub(crate) mod catalog;
#[path = "phone_controls.rs"]
pub(crate) mod controls;
#[path = "phone_presentation.rs"]
pub(crate) mod presentation;
pub(crate) struct ManagementBridges<'a> {
    pub catalog: &'a catalog::Bridge,
    pub controls: Option<&'a controls::Bridge>,
    pub presentation: Option<&'a presentation::Bridge>,
}
pub(crate) enum ManagementRole<'a> {
    Catalog(&'a catalog::Bridge),
    Controls(&'a controls::Bridge),
    Presentation(&'a presentation::Bridge, presentation::Protocol),
}
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
    authorization: crate::cached_authorization::CachedAuthorization,
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
        clock: &mut impl FnMut() -> Result<u64, &'static str>,
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
        let observation = store.observe_now(clock)?;
        let now = observation.now;
        let phone = store.authenticate_observed(
            &request.phone_id,
            &token(&request.credential)?,
            observation,
        )?;
        if phone.credential_epoch != request.credential_epoch {
            return Err("phone_authentication_rejected");
        }
        let expires = phone.expires_at.min(
            now.checked_add(60_000)
                .ok_or("phone_authentication_rejected")?,
        );
        let authorization = store.cached_authorization(&phone)?;
        Ok(Self {
            authorization,
            binding,
            host_pin,
            phone,
            expires,
            observed: now,
        })
    }
    #[cfg(test)]
    fn validate(
        &mut self,
        channel: &ControlChannel,
        store: &mut PhoneTrustStore,
        now: u64,
    ) -> Result<(), &'static str> {
        self.validate_now(channel, store, &mut || Ok(now))
            .map(|_| ())
    }
    /// The caller holds the epoch guard through the following native operation.
    fn validate_cached(
        &mut self,
        channel: &ControlChannel,
        now: &mut impl FnMut() -> Result<u64, &'static str>,
    ) -> Result<u64, &'static str> {
        let time = self.authorization.clock.sample(now)?;
        if channel.native_binding() != Some(self.binding)
            || channel.native_server_pin().map(|p| p.hex()).as_deref()
                != Some(self.host_pin.as_str())
            || time < self.observed
            || time >= self.expires
            || time >= self.phone.expires_at
        {
            return Err("phone_authentication_rejected");
        }
        self.observed = time;
        Ok(time)
    }
    fn validate_now(
        &mut self,
        channel: &ControlChannel,
        store: &mut PhoneTrustStore,
        now: &mut impl FnMut() -> Result<u64, &'static str>,
    ) -> Result<u64, &'static str> {
        let authorization = self.authorization.clone();
        {
            let _scope = authorization.guard()?;
        }
        let observation = store.observe_now(now)?;
        let time = observation.now;
        if channel.native_binding() != Some(self.binding)
            || channel.native_server_pin().map(|p| p.hex()).as_deref()
                != Some(self.host_pin.as_str())
            || store.host_pin() != self.host_pin
            || time < self.observed
            || time >= self.expires
        {
            return Err("phone_authentication_rejected");
        }
        store.authorize_epoch_observed(
            &self.phone.phone_id,
            &self.phone.credential_epoch,
            observation,
        )?;
        self.observed = time;
        Ok(time)
    }
    #[cfg(test)]
    fn renew(
        &mut self,
        channel: &ControlChannel,
        store: &mut PhoneTrustStore,
        now: u64,
    ) -> Result<(), &'static str> {
        self.renew_now(channel, store, &mut || Ok(now))
    }
    fn renew_now(
        &mut self,
        channel: &ControlChannel,
        store: &mut PhoneTrustStore,
        now: &mut impl FnMut() -> Result<u64, &'static str>,
    ) -> Result<(), &'static str> {
        let time = self.validate_now(channel, store, now)?;
        if self.expires.saturating_sub(time) > 30_000 {
            return Err("input_renewal_too_early");
        }
        let observation = store.observe_now(now)?;
        let time = observation.now;
        let phone = store.authorize_epoch_observed(
            &self.phone.phone_id,
            &self.phone.credential_epoch,
            observation,
        )?;
        self.expires = phone.expires_at.min(
            time.checked_add(60_000)
                .ok_or("phone_authentication_rejected")?,
        );
        self.observed = time;
        self.phone = phone;
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
    InputRenew {
        version: u8,
        connection_id: String,
        session_id: String,
        generation: String,
        revision: String,
    },
    InputRelease {
        version: u8,
        connection_id: String,
        session_id: String,
    },
    InputStatus {
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
            | Self::InputRenew {
                version,
                connection_id,
                ..
            }
            | Self::InputRelease {
                version,
                connection_id,
                ..
            }
            | Self::InputStatus {
                version,
                connection_id,
                ..
            } => (*version, connection_id),
        }
    }
}
fn input_reply(
    authorized: &AuthorizedConnection,
    command: &str,
    authority: &str,
    broker: &mut crate::input_broker::Broker<'_>,
) -> Result<Value, &'static str> {
    let mut value = authorized.reply(command, authority);
    value["inputSessionAvailable"] = json!(true);
    if broker.physical {
        let c = broker.configuration()?;
        value["outputBackend"] = json!("macos-hid");
        value["inputEnabled"] = json!(c.input_enabled);
    }
    Ok(value)
}
fn grant_lifetime(expires: u64, now: u64) -> Result<u32, &'static str> {
    expires
        .checked_sub(now)
        .filter(|left| *left >= 100)
        .map(|left| left.min(60_000) as u32)
        .ok_or("phone_authentication_rejected")
}
/// Control v3 remains metadata-only. V4 additionally uses the independent receiver's private IPC.
/// TLS waits occur outside locks. Durable grant RPCs hold the mutation fence;
/// packet/status RPCs hold only their cached epoch fence and committed clock reservation.
pub(crate) fn serve_after_hello(
    channel: &mut ControlChannel,
    authority: &str,
    store: &Mutex<PhoneTrustStore>,
    mutation: &Mutex<()>,
    input: Option<crate::input_broker::ControlInput<'_>>,
    management: Option<ManagementRole<'_>>,
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
            now,
        )?
    };
    if let Some(management) = management {
        return match management {
            ManagementRole::Presentation(presentation, protocol) => presentation::serve(
                channel,
                authority,
                &mut authorized,
                presentation,
                protocol,
                now,
            ),
            ManagementRole::Controls(controls) => {
                controls::serve(channel, authority, &mut authorized, controls, now)
            }
            ManagementRole::Catalog(catalog) => {
                catalog::serve(channel, authority, &mut authorized, catalog, now)
            }
        };
    }
    if let Some(input) = input {
        let mut broker = crate::input_broker::Broker::connect(
            input.root,
            input.registry,
            authorized.binding,
            input.datagram_port,
        )?;
        broker.renewal = input.renewal;
        if input.physical {
            broker.require_physical_output()?;
        }
        // Handshake may have waited on local IPC; recheck trust before returning admission metadata.
        {
            let _gate = mutation
                .lock()
                .map_err(|_| "phone_trust_owner_unavailable")?;
            authorized.validate_now(
                channel,
                &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                now,
            )?;
        }
        send(
            channel,
            input_reply(&authorized, "authenticated", authority, &mut broker)?,
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
            authorized.validate_now(
                channel,
                &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                now,
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
    let mut window = std::time::Instant::now();
    loop {
        let frame = channel
            .receive()
            .map_err(|_| "authenticated_control_transport_failed")?;
        if broker.renewal && window.elapsed() >= std::time::Duration::from_secs(60) {
            controls = 0;
            packets = 0;
            window = std::time::Instant::now();
        }
        if frame.kind == FrameKind::Input {
            packets += 1;
            if packets > 65_536 {
                return Err("authenticated_control_budget_exhausted");
            }
            #[cfg(debug_assertions)]
            let waiting = crate::input_io_diagnostics::Span::start(
                crate::input_io_diagnostics::Metric::InputWait,
            );
            let authorization = authorized.authorization.clone();
            let _gate = authorization.guard()?;
            #[cfg(debug_assertions)]
            drop(waiting);
            #[cfg(debug_assertions)]
            let _held = crate::input_io_diagnostics::Span::start(
                crate::input_io_diagnostics::Metric::InputHeld,
            );
            let time = authorized.validate_cached(channel, now)?;
            broker.packet(&frame.payload, time)?;
            continue;
        }
        controls += 1;
        if controls
            > if broker.datagram_port().is_some() {
                1024
            } else {
                128
            }
        {
            return Err("authenticated_control_budget_exhausted");
        }
        let request: InputRequest = serde_json::from_slice(&frame.payload)
            .map_err(|_| "authenticated_control_message_invalid")?;
        let (version, connection) = request.binding();
        if version != 1 || connection != hex(&authorized.binding) {
            return Err("authenticated_control_message_invalid");
        }
        // Only native IPC and native trust checks run while this fence is held, never TLS I/O.
        #[cfg(debug_assertions)]
        let waiting = crate::input_io_diagnostics::Span::start(
            crate::input_io_diagnostics::Metric::ControlWait,
        );
        let durable = matches!(
            request,
            InputRequest::InputGrant { .. } | InputRequest::InputRenew { .. }
        );
        let gate = if durable {
            Some(
                mutation
                    .lock()
                    .map_err(|_| "phone_trust_owner_unavailable")?,
            )
        } else {
            None
        };
        let authorization = authorized.authorization.clone();
        let scope = if durable {
            None
        } else {
            Some(authorization.guard()?)
        };
        #[cfg(debug_assertions)]
        drop(waiting);
        #[cfg(debug_assertions)]
        let held = crate::input_io_diagnostics::Span::start(
            crate::input_io_diagnostics::Metric::ControlHeld,
        );
        let time = if durable {
            authorized.validate_now(
                channel,
                &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                now,
            )?
        } else {
            authorized.validate_cached(channel, now)?
        };
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
                    broker
                        .datagram_port()
                        .map(|_| crate::input_broker::DatagramPolicy {
                            epoch: authorized.phone.credential_epoch.clone(),
                            authorization: authorized.authorization.clone(),
                            expires: authorized.expires,
                            observed: time,
                        }),
                )?;
                authorized.validate_now(
                    channel,
                    &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                    now,
                )?;
                #[cfg(debug_assertions)]
                drop(held);
                drop(scope);
                drop(gate);
                crate::input_broker::deliver(&grant, channel, broker.datagram_port())?;
                continue;
            }
            InputRequest::InputRenew {
                session_id,
                generation,
                revision,
                ..
            } => {
                if !broker.renewal {
                    return Err("authenticated_control_message_invalid");
                }
                authorized.renew_now(
                    channel,
                    &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                    now,
                )?;
                let grant = broker.rotate(
                    &session_id,
                    crate::runtime::decimal(&generation)?,
                    crate::runtime::decimal(&revision)?,
                    grant_lifetime(authorized.expires, time)?,
                    crate::input_broker::DatagramPolicy {
                        epoch: authorized.phone.credential_epoch.clone(),
                        authorization: authorized.authorization.clone(),
                        expires: authorized.expires,
                        observed: time,
                    },
                )?;
                authorized.validate_now(
                    channel,
                    &mut *store.lock().map_err(|_| "phone_trust_owner_unavailable")?,
                    now,
                )?;
                #[cfg(debug_assertions)]
                drop(held);
                drop(scope);
                drop(gate);
                grant.send_renewal_to(
                    channel,
                    broker.datagram_port(),
                    &session_id,
                    authorized.expires,
                )?;
                continue;
            }
            InputRequest::InputConfiguration { .. } => {
                let c = broker.configuration()?;
                {
                    let mut value = json!({"version":1,"command":"input-configuration","connectionId":hex(&authorized.binding),"active":c.active,"generation":c.generation.to_string(),"revision":c.revision.to_string(),"inputEnabled":false});
                    if broker.physical {
                        value["outputBackend"] = json!("macos-hid");
                        value["inputEnabled"] = json!(c.input_enabled);
                    }
                    value
                }
            }
            InputRequest::InputStatus { session_id, .. } => {
                let status = broker.datagram_status(&session_id, time)?;
                {
                    let mut value = json!({"version":1,"command":"input-status","connectionId":hex(&authorized.binding),"sessionId":session_id,"active":status.active,
                    "generation":status.generation.to_string(),"revision":status.revision.to_string(),"lastAcceptedSequence":status.last.map(|s|s.to_string()),"inputEnabled":false});
                    if broker.physical {
                        value["outputBackend"] = json!("macos-hid");
                        value["inputEnabled"] = json!(status.input_enabled);
                    }
                    value
                }
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
                {
                    let mut value = json!({"version":1,"command":"input-released","connectionId":hex(&authorized.binding),"sessionId":session_id,"inputEnabled":false});
                    if broker.physical {
                        value["outputBackend"] = json!("macos-hid");
                    }
                    value
                }
            }
            InputRequest::Disconnect { .. } => {
                broker.release()?;
                #[cfg(debug_assertions)]
                drop(held);
                drop(scope);
                drop(gate);
                return send(
                    channel,
                    input_reply(authorized, "disconnected", authority, broker)?,
                );
            }
            InputRequest::ControlStatus { .. } => {
                input_reply(authorized, "control-status", authority, broker)?
            }
        };
        #[cfg(debug_assertions)]
        drop(held);
        drop(scope);
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
            authorization: store.cached_authorization(&phone).unwrap(),
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
    include!("authenticated_catalog_tests.rs");
    include!("authenticated_controls_tests.rs");
    include!("authenticated_presentation_tests.rs");
    include!("authenticated_control_renewal_tests.rs");
    include!("authenticated_control_contention_tests.rs");
}
