//! Capability-authenticated loopback IPC between native owners. Never part of Bun/React contracts.
use crate::{
    input_packet::{PacketGrant, PacketSender, PACKET_BYTES, PACKET_LIMIT},
    packet_runtime::PacketRuntime,
    runtime::{decimal, Output},
    security,
};
use ring::{
    hmac,
    rand::{SecureRandom, SystemRandom},
};
use std::{
    collections::BTreeMap,
    fs,
    io::{Read, Write},
    net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc, Arc, Mutex,
    },
    thread,
    time::{Duration, Instant},
};
use subtle::ConstantTimeEq;
const MAGIC: &[u8; 8] = b"THNI1\0\0\0";
const LIMIT: usize = 192;
const FRAME_WAIT: Duration = Duration::from_secs(2);
const OP_WAIT: Duration = Duration::from_millis(250);
const STATUS: u8 = 1;
const GRANT: u8 = 2;
const PACKET: u8 = 3;
const RELEASE: u8 = 4;
const ROTATE: u8 = 5;
const SAVED_STATUS: u8 = 6;
const OUTPUT_STATUS: u8 = 7;
const PHYSICAL_GRANT: u8 = 8;
const PHYSICAL_PACKET: u8 = 9;
const PHYSICAL_RELEASE: u8 = 10;
const PHYSICAL_ROTATE: u8 = 11;
fn canonical_op(op: u8) -> u8 {
    match op {
        PHYSICAL_GRANT => GRANT,
        PHYSICAL_PACKET => PACKET,
        PHYSICAL_RELEASE => RELEASE,
        PHYSICAL_ROTATE => ROTATE,
        _ => op,
    }
}
fn physical_op(op: u8) -> u8 {
    match op {
        GRANT => PHYSICAL_GRANT,
        PACKET => PHYSICAL_PACKET,
        RELEASE => PHYSICAL_RELEASE,
        ROTATE => PHYSICAL_ROTATE,
        _ => op,
    }
}

fn random<const N: usize>() -> Result<[u8; N], &'static str> {
    let mut bytes = [0; N];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| "native_input_entropy_failed")?;
    Ok(bytes)
}
// A socket deadline may surface as WouldBlock (including macOS EAGAIN) or
// TimedOut. Keep its failure category consistent with an elapsed frame deadline.
// This does not retry, extend the deadline, or change transport cleanup.
fn io_failure(error: &std::io::Error) -> &'static str {
    match error.kind() {
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => "native_input_timeout",
        _ => "native_input_transport_failed",
    }
}
fn read_exact(
    stream: &mut TcpStream,
    bytes: &mut [u8],
    deadline: Instant,
) -> Result<(), &'static str> {
    let mut at = 0;
    while at < bytes.len() {
        let left = deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or("native_input_timeout")?;
        stream.set_read_timeout(Some(left)).map_err(|error| {
            #[cfg(debug_assertions)]
            crate::input_error_diagnostics::io("native-read-options", &error);
            #[cfg(not(debug_assertions))]
            let _ = error;
            "native_input_transport_failed"
        })?;
        let n = stream.read(&mut bytes[at..]).map_err(|error| {
            #[cfg(debug_assertions)]
            crate::input_io_diagnostics::terminal_io("native-read", &error);
            io_failure(&error)
        })?;
        if n == 0 {
            #[cfg(debug_assertions)]
            crate::input_error_diagnostics::end("native-read");
            return Err("native_input_transport_failed");
        }
        at += n;
    }
    Ok(())
}
fn receive(stream: &mut TcpStream, wait: Duration) -> Result<Vec<u8>, &'static str> {
    let deadline = Instant::now() + wait;
    let mut size = [0; 2];
    read_exact(stream, &mut size, deadline)?;
    let n = usize::from(u16::from_be_bytes(size));
    if !(1..=LIMIT).contains(&n) {
        return Err("native_input_frame_invalid");
    }
    let mut bytes = vec![0; n];
    read_exact(stream, &mut bytes, deadline)?;
    Ok(bytes)
}
fn send(stream: &mut TcpStream, bytes: &[u8], wait: Duration) -> Result<(), &'static str> {
    if bytes.is_empty() || bytes.len() > LIMIT {
        return Err("native_input_frame_invalid");
    }
    let mut frame = Vec::with_capacity(bytes.len() + 2);
    frame.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
    frame.extend_from_slice(bytes);
    let deadline = Instant::now() + wait;
    let mut at = 0;
    while at < frame.len() {
        let left = deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or("native_input_timeout")?;
        stream.set_write_timeout(Some(left)).map_err(|error| {
            #[cfg(debug_assertions)]
            crate::input_error_diagnostics::io("native-write-options", &error);
            #[cfg(not(debug_assertions))]
            let _ = error;
            "native_input_transport_failed"
        })?;
        let n = stream.write(&frame[at..]).map_err(|error| {
            #[cfg(debug_assertions)]
            crate::input_error_diagnostics::io("native-write", &error);
            io_failure(&error)
        })?;
        if n == 0 {
            #[cfg(debug_assertions)]
            crate::input_error_diagnostics::end("native-write");
            return Err("native_input_transport_failed");
        }
        at += n;
    }
    Ok(())
}
fn server_proof(token: &[u8; 32], challenge: &[u8]) -> Vec<u8> {
    let mut message = b"thumble-rewrite/native-input-server/v1\0".to_vec();
    message.extend_from_slice(challenge);
    hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, token), &message)
        .as_ref()
        .to_vec()
}
fn number(bytes: &[u8], at: usize) -> u64 {
    u64::from_le_bytes(
        bytes[at..at + 8]
            .try_into()
            .expect("validated fixed native frame"),
    )
}
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct GrantRef {
    connection: [u8; 16],
    session: [u8; 16],
}
impl GrantRef {
    pub(crate) fn session(&self) -> [u8; 16] {
        self.session
    }
}
/// Opaque native-only secret. Deliberately no Debug, Clone, Serialize or raw key getter.
pub struct NativeGrant {
    key: [u8; 32],
    session: [u8; 16],
    prefix: [u8; 4],
    generation: u64,
    revision: u64,
    lifetime_ms: u32,
    binding: GrantRef,
    physical: bool,
}
impl NativeGrant {
    pub fn binding(&self) -> GrantRef {
        self.binding
    }
    pub fn generation(&self) -> u64 {
        self.generation
    }
    pub fn revision(&self) -> u64 {
        self.revision
    }
    pub fn lifetime_ms(&self) -> u32 {
        self.lifetime_ms
    }
    pub(crate) fn send_to(
        &self,
        channel: &mut crate::control_tls::ControlChannel,
    ) -> Result<(), &'static str> {
        self.send_to_datagram(channel, None)
    }
    pub(crate) fn send_to_datagram(
        &self,
        channel: &mut crate::control_tls::ControlChannel,
        udp_port: Option<u16>,
    ) -> Result<(), &'static str> {
        self.send_frame(channel, udp_port, None)
    }
    pub(crate) fn send_renewal_to(
        &self,
        channel: &mut crate::control_tls::ControlChannel,
        udp_port: Option<u16>,
        previous: &str,
        authorization_expires: u64,
    ) -> Result<(), &'static str> {
        self.send_frame(channel, udp_port, Some((previous, authorization_expires)))
    }
    fn send_frame(
        &self,
        channel: &mut crate::control_tls::ControlChannel,
        udp_port: Option<u16>,
        renewal: Option<(&str, u64)>,
    ) -> Result<(), &'static str> {
        if channel.native_binding() != Some(self.binding.connection) {
            return Err("native_grant_delivery_unconfirmed");
        }
        let value = self.control_reply(udp_port, renewal)?;
        channel
            .send(
                crate::control_tls::FrameKind::Control,
                &serde_json::to_vec(&value).map_err(|_| "native_grant_delivery_unconfirmed")?,
            )
            .map_err(|_| "native_grant_delivery_unconfirmed")
    }
    fn control_reply(
        &self,
        udp_port: Option<u16>,
        renewal: Option<(&str, u64)>,
    ) -> Result<serde_json::Value, &'static str> {
        let mut value = serde_json::json!({"version":1,"command":"input-granted","connectionId":crate::gamepad::hex(&self.binding.connection),"generation":self.generation.to_string(),"revision":self.revision.to_string(),"sessionId":crate::gamepad::hex(&self.session),"key":crate::gamepad::hex(&self.key),"noncePrefix":crate::gamepad::hex(&self.prefix),"lifetimeMs":self.lifetime_ms,"packetVersion":1,"packetBytes":PACKET_BYTES,"packetLimit":PACKET_LIMIT.to_string(),"transport":"tls","inputEnabled":false});
        if self.physical {
            value["inputEnabled"] = serde_json::json!(true);
            value["outputBackend"] = serde_json::json!("macos-hid");
        }
        if let Some(port) = udp_port {
            if port == 0 {
                return Err("native_grant_delivery_unconfirmed");
            }
            value["transport"] = serde_json::json!("udp+tls");
            value["udpPort"] = serde_json::json!(port);
        }
        if let Some((previous, expires)) = renewal {
            if previous.len() != 32
                || !previous
                    .bytes()
                    .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            {
                return Err("native_grant_delivery_unconfirmed");
            }
            value["command"] = serde_json::json!("input-renewed");
            value["replacesSessionId"] = serde_json::json!(previous);
            value["authorizationExpiresAt"] = serde_json::json!(expires);
        }
        Ok(value)
    }
    /// Native fixture/delivery owner only. Consumes the material so callers cannot reset its sender.
    pub fn into_sender(self) -> Result<PacketSender, &'static str> {
        PacketSender::new(
            PacketGrant::new(&self.key, self.session, self.prefix, self.generation)
                .map_err(|_| "native_input_grant_invalid")?,
            PACKET_LIMIT,
        )
        .map_err(|_| "native_input_grant_invalid")
    }
}
#[derive(Clone, Copy)]
pub struct Configuration {
    pub active: bool,
    pub generation: u64,
    pub revision: u64,
    pub backend: &'static str,
    pub input_enabled: bool,
}
/// One serialized native worker connection. Never put this blocking API on the safety/input/UI loop.
pub struct Client {
    stream: TcpStream,
    token: [u8; 32],
    physical: bool,
}
impl Client {
    pub fn connect(root: &Path) -> Result<Self, &'static str> {
        security::directory(root)?;
        let path = root.join("native-input.endpoint");
        if !path.exists() {
            return Err("native_input_unavailable");
        }
        let mut bytes = Vec::new();
        security::file(&path, false)?
            .take(43)
            .read_to_end(&mut bytes)
            .map_err(|_| "native_input_unavailable")?;
        if bytes.len() != 42 || &bytes[..8] != MAGIC {
            return Err("native_input_endpoint_invalid");
        }
        let port = u16::from_le_bytes(bytes[8..10].try_into().unwrap());
        if port == 0 {
            return Err("native_input_endpoint_invalid");
        }
        let mut stream =
            TcpStream::connect_timeout(&SocketAddr::from((Ipv4Addr::LOCALHOST, port)), OP_WAIT)
                .map_err(|_| "native_input_unavailable")?;
        stream
            .set_nodelay(true)
            .map_err(|_| "native_input_unavailable")?;
        let token = bytes[10..].try_into().unwrap();
        let challenge = random::<16>()?;
        let mut hello = vec![0];
        hello.extend_from_slice(&challenge);
        send(&mut stream, &hello, OP_WAIT)?;
        let proof = receive(&mut stream, OP_WAIT)?;
        if proof.len() != 33
            || proof[0] != 0
            || !bool::from(proof[1..].ct_eq(&server_proof(&token, &challenge)))
        {
            return Err("native_input_server_rejected");
        }
        Ok(Self {
            stream,
            token,
            physical: false,
        })
    }
    pub(crate) fn physical_output(&self) -> bool {
        self.physical
    }
    pub(crate) fn close(&mut self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
    fn request(&mut self, op: u8, payload: &[u8]) -> Result<Vec<u8>, &'static str> {
        let op = if self.physical { physical_op(op) } else { op };
        let mut bytes = vec![1];
        bytes.extend_from_slice(&self.token);
        bytes.push(op);
        bytes.extend_from_slice(payload);
        let result = (|| {
            {
                #[cfg(debug_assertions)]
                let _io = crate::input_io_diagnostics::Span::start(
                    crate::input_io_diagnostics::Metric::NativeClientSend,
                );
                send(&mut self.stream, &bytes, OP_WAIT)?;
            }
            let reply = {
                #[cfg(debug_assertions)]
                let _io = crate::input_io_diagnostics::Span::start(
                    crate::input_io_diagnostics::Metric::NativeClientReceive,
                );
                receive(&mut self.stream, OP_WAIT)?
            };
            if reply.len() < 2
                || reply[0] > 1
                || reply[1] != op
                || (reply[0] == 1 && reply.len() != 2)
            {
                return Err("native_input_frame_invalid");
            }
            Ok(reply)
        })();
        if let Err(error) = &result {
            #[cfg(debug_assertions)]
            crate::input_io_diagnostics::terminal("native-client", op, error);
            #[cfg(not(debug_assertions))]
            let _ = error;
            let _ = self.stream.shutdown(Shutdown::Both);
        }
        let reply = result?;
        if reply[0] == 1 {
            #[cfg(debug_assertions)]
            crate::input_io_diagnostics::terminal("native-client", op, "native_input_rejected");
            return Err("native_input_rejected");
        }
        Ok(reply[2..].to_vec())
    }
    pub fn configuration(&mut self) -> Result<Configuration, &'static str> {
        if self.physical {
            return Ok(self.output_configuration()?.0);
        }
        let b = self.request(STATUS, &[])?;
        if b.len() != 17 || b[0] > 1 {
            return Err("native_input_frame_invalid");
        }
        Ok(Configuration {
            active: b[0] == 1,
            generation: number(&b, 1),
            revision: number(&b, 9),
            backend: "recording",
            input_enabled: false,
        })
    }
    /// Read-only saved source pin. No grant, input packet, or owner renewal.
    pub fn saved_configuration(
        &mut self,
    ) -> Result<(Configuration, Option<crate::packet_runtime::SavedBinding>), &'static str> {
        let bytes = self.request(SAVED_STATUS, &[])?;
        Self::decode_saved_configuration(&bytes)
    }
    fn decode_saved_configuration(
        bytes: &[u8],
    ) -> Result<(Configuration, Option<crate::packet_runtime::SavedBinding>), &'static str> {
        if bytes.len() < 18 || bytes[0] > 1 || bytes[17] > 1 {
            return Err("native_input_frame_invalid");
        }
        let configuration = Configuration {
            active: bytes[0] == 1,
            generation: number(bytes, 1),
            revision: number(bytes, 9),
            backend: "recording",
            input_enabled: false,
        };
        let pin = if bytes[17] == 0 {
            if bytes.len() != 18 {
                return Err("native_input_frame_invalid");
            }
            None
        } else {
            if bytes.len() != 126
                || !configuration.active
                || configuration.generation == 0
                || number(bytes, 18) == 0
            {
                return Err("native_input_frame_invalid");
            }
            let source_hash =
                std::str::from_utf8(&bytes[26..90]).map_err(|_| "native_input_frame_invalid")?;
            let profile_id =
                std::str::from_utf8(&bytes[90..126]).map_err(|_| "native_input_frame_invalid")?;
            if !source_hash
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
                || !crate::packet_runtime::saved_profile(profile_id)
            {
                return Err("native_input_frame_invalid");
            }
            Some(crate::packet_runtime::SavedBinding {
                configuration_revision: number(bytes, 18).to_string(),
                source_hash: source_hash.into(),
                profile_id: profile_id.into(),
                generation: configuration.generation.to_string(),
                revision: configuration.revision.to_string(),
            })
        };
        Ok((configuration, pin))
    }
    /// Output-aware read-only status, separate from the unchanged recording-only opcodes.
    pub fn output_configuration(
        &mut self,
    ) -> Result<(Configuration, Option<crate::packet_runtime::SavedBinding>), &'static str> {
        let bytes = self.request(OUTPUT_STATUS, &[])?;
        if !matches!(bytes.len(), 20 | 128) {
            return Err("native_input_frame_invalid");
        }
        let at = bytes.len() - 2;
        let (mut configuration, pin) = Self::decode_saved_configuration(&bytes[..at])?;
        configuration.backend = match bytes[at] {
            0 => "recording",
            1 => "macos-hid",
            _ => return Err("native_input_frame_invalid"),
        };
        if bytes[at + 1] > 1
            || (bytes[at] == 0 && bytes[at + 1] != 0)
            || (!configuration.active && bytes[at + 1] != 0)
        {
            return Err("native_input_frame_invalid");
        }
        configuration.input_enabled = bytes[at + 1] == 1;
        if self.physical && configuration.backend != "macos-hid" {
            return Err("native_input_backend_not_supported");
        }
        Ok((configuration, pin))
    }
    pub(crate) fn require_physical_output(&mut self) -> Result<Configuration, &'static str> {
        let c = self.output_configuration()?.0;
        if c.backend != "macos-hid" {
            return Err("native_input_backend_not_supported");
        }
        self.physical = true;
        Ok(c)
    }
    /// Caller must hold a current authenticated connection capability and trust mutation fence.
    pub fn grant(
        &mut self,
        connection: [u8; 16],
        generation: u64,
        revision: u64,
        lifetime_ms: u32,
    ) -> Result<NativeGrant, &'static str> {
        if connection == [0; 16] {
            return Err("native_input_grant_invalid");
        }
        let mut b = connection.to_vec();
        b.extend_from_slice(&generation.to_le_bytes());
        b.extend_from_slice(&revision.to_le_bytes());
        b.extend_from_slice(&lifetime_ms.to_le_bytes());
        let b = self.request(GRANT, &b)?;
        if b.len() != 72
            || number(&b, 52) != generation
            || number(&b, 60) != revision
            || u32::from_le_bytes(b[68..72].try_into().unwrap()) != lifetime_ms
        {
            return Err("native_input_grant_invalid");
        }
        let session = b[32..48].try_into().unwrap();
        Ok(NativeGrant {
            physical: self.physical,
            key: b[..32].try_into().unwrap(),
            session,
            prefix: b[48..52].try_into().unwrap(),
            generation,
            revision,
            lifetime_ms,
            binding: GrantRef {
                connection,
                session,
            },
        })
    }
    /// Stage fresh material for this exact still-live source. No receiver state changes until packet zero.
    pub fn rotate(
        &mut self,
        previous: GrantRef,
        generation: u64,
        revision: u64,
        lifetime_ms: u32,
    ) -> Result<NativeGrant, &'static str> {
        let mut b = previous.connection.to_vec();
        b.extend_from_slice(&previous.session);
        b.extend_from_slice(&generation.to_le_bytes());
        b.extend_from_slice(&revision.to_le_bytes());
        b.extend_from_slice(&lifetime_ms.to_le_bytes());
        let b = self.request(ROTATE, &b)?;
        if b.len() != 72
            || number(&b, 52) != generation
            || number(&b, 60) != revision
            || u32::from_le_bytes(b[68..72].try_into().unwrap()) != lifetime_ms
        {
            return Err("native_input_grant_invalid");
        }
        let session = b[32..48].try_into().unwrap();
        if session == previous.session {
            return Err("native_input_grant_invalid");
        }
        Ok(NativeGrant {
            physical: self.physical,
            key: b[..32].try_into().unwrap(),
            session,
            prefix: b[48..52].try_into().unwrap(),
            generation,
            revision,
            lifetime_ms,
            binding: GrantRef {
                connection: previous.connection,
                session,
            },
        })
    }
    pub fn packet(&mut self, binding: GrantRef, packet: &[u8]) -> Result<(), &'static str> {
        if packet.len() != PACKET_BYTES {
            return Err("native_input_packet_invalid");
        }
        let mut b = binding.connection.to_vec();
        b.extend_from_slice(&binding.session);
        b.extend_from_slice(packet);
        if !self.request(PACKET, &b)?.is_empty() {
            return Err("native_input_frame_invalid");
        }
        Ok(())
    }
    pub fn release(&mut self, binding: GrantRef) -> Result<(), &'static str> {
        let mut b = binding.connection.to_vec();
        b.extend_from_slice(&binding.session);
        if !self.request(RELEASE, &b)?.is_empty() {
            return Err("native_input_frame_invalid");
        }
        Ok(())
    }
}
impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
}
struct Pending {
    #[cfg(debug_assertions)]
    queue_span: Option<crate::input_io_diagnostics::Span>,
    op: u8,
    payload: Vec<u8>,
    deadline: Instant,
    response: mpsc::SyncSender<Result<Vec<u8>, &'static str>>,
}
struct Binding {
    reference: GrantRef,
    generation: u64,
}
type Peers = Arc<Mutex<BTreeMap<u64, TcpStream>>>;
/// Four bounded socket workers enqueue work; only drain() on the native safety thread mutates output.
pub struct Server {
    _lease: std::fs::File,
    pending: mpsc::Receiver<Pending>,
    jobs: Option<mpsc::SyncSender<(u64, TcpStream)>>,
    stop: Arc<AtomicBool>,
    peers: Peers,
    accept: Option<thread::JoinHandle<()>>,
    workers: Vec<thread::JoinHandle<()>>,
    path: PathBuf,
    binding: Option<Binding>,
    staged: Option<Binding>,
    wake: Option<Arc<crate::owner_wake::OwnerWake>>,
}
impl Server {
    pub fn bind(root: &Path) -> Result<Self, &'static str> {
        Self::bind_with_wake(root, None)
    }
    pub fn bind_with_wake(
        root: &Path,
        wake: Option<Arc<crate::owner_wake::OwnerWake>>,
    ) -> Result<Self, &'static str> {
        security::directory(root)?;
        let lease = security::file(&root.join("native-input.lock"), false)?;
        fs2::FileExt::try_lock_exclusive(&lease).map_err(|_| "native_input_owner_exists")?;
        let listener =
            TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).map_err(|_| "native_input_bind_failed")?;
        listener
            .set_nonblocking(true)
            .map_err(|_| "native_input_bind_failed")?;
        let port = listener
            .local_addr()
            .map_err(|_| "native_input_bind_failed")?
            .port();
        let token = random::<32>()?;
        let path = root.join("native-input.endpoint");
        // Runtime capability rotates on every owner restart, including recovery from a partial publication.
        if path.exists() {
            drop(security::file(&path, false)?);
        }
        let staged = root.join("native-input.pending");
        let mut file = security::file(&staged, false)?;
        file.set_len(0)
            .map_err(|_| "native_input_endpoint_failed")?;
        file.write_all(MAGIC)
            .and_then(|_| file.write_all(&port.to_le_bytes()))
            .and_then(|_| file.write_all(&token))
            .and_then(|_| file.sync_all())
            .map_err(|_| "native_input_endpoint_failed")?;
        drop(file);
        fs::rename(&staged, &path).map_err(|_| "native_input_endpoint_failed")?;
        let (incoming, pending) = mpsc::sync_channel::<Pending>(16);
        let (jobs, work) = mpsc::sync_channel::<(u64, TcpStream)>(4);
        let work = Arc::new(Mutex::new(work));
        let stop = Arc::new(AtomicBool::new(false));
        let peers: Peers = Arc::new(Mutex::new(BTreeMap::new()));
        let mut workers = Vec::new();
        for _ in 0..4 {
            let work = work.clone();
            let stop = stop.clone();
            let peers = peers.clone();
            let incoming = incoming.clone();
            let wake = wake.clone();
            workers.push(thread::spawn(move || loop {
                #[cfg(debug_assertions)]
                crate::input_error_diagnostics::server_thread();
                let (id, mut stream) = match work.lock() {
                    Ok(work) => match work.recv() {
                        Ok(job) => job,
                        Err(_) => break,
                    },
                    Err(_) => break,
                };
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_nodelay(true);
                let mut owned: Vec<GrantRef> = Vec::with_capacity(2);
                let authenticated_server = (|| {
                    let hello = receive(&mut stream, FRAME_WAIT)?;
                    if hello.len() != 17 || hello[0] != 0 {
                        return Err("native_input_frame_invalid");
                    }
                    let mut proof = vec![0];
                    proof.extend_from_slice(&server_proof(&token, &hello[1..]));
                    send(&mut stream, &proof, OP_WAIT)
                })()
                .is_ok();
                let mut owned_physical = false;
                #[cfg(debug_assertions)]
                let mut exit_reason = if authenticated_server {
                    "stopped"
                } else {
                    "handshake"
                };
                while authenticated_server && !stop.load(Ordering::SeqCst) {
                    let b = match receive(&mut stream, FRAME_WAIT) {
                        Ok(b) => b,
                        Err(error) => {
                            #[cfg(debug_assertions)]
                            {
                                exit_reason = if error == "native_input_timeout" {
                                    "read-deadline"
                                } else {
                                    "read-failure"
                                };
                            }
                            #[cfg(not(debug_assertions))]
                            let _ = error;
                            break;
                        }
                    };
                    if b.len() < 34 || b[0] != 1 || !bool::from(b[1..33].ct_eq(&token)) {
                        #[cfg(debug_assertions)]
                        {
                            exit_reason = "invalid-frame";
                        }
                        break;
                    }
                    let op = b[33];
                    let canonical = canonical_op(op);
                    let payload = b[34..].to_vec();
                    if !matches!(
                        (canonical, payload.len()),
                        (STATUS | SAVED_STATUS | OUTPUT_STATUS, 0)
                            | (GRANT, 36)
                            | (PACKET, 140)
                            | (RELEASE, 32)
                            | (ROTATE, 52)
                    ) {
                        #[cfg(debug_assertions)]
                        {
                            exit_reason = "invalid-payload";
                        }
                        break;
                    }
                    let old_reference = if matches!(canonical, ROTATE | PACKET | RELEASE) {
                        Some(GrantRef {
                            connection: payload[..16].try_into().unwrap(),
                            session: payload[16..32].try_into().unwrap(),
                        })
                    } else {
                        None
                    };
                    let grant_connection = if matches!(canonical, GRANT | ROTATE) {
                        Some(<[u8; 16]>::try_from(&payload[..16]).unwrap())
                    } else {
                        None
                    };
                    let (response, result) = mpsc::sync_channel(1);
                    let deadline = Instant::now() + OP_WAIT;
                    if let Err(error) = incoming.try_send(Pending {
                        #[cfg(debug_assertions)]
                        queue_span: crate::input_io_diagnostics::Span::start(
                            crate::input_io_diagnostics::Metric::NativeServerQueue,
                        ),
                        op,
                        payload,
                        deadline,
                        response,
                    }) {
                        #[cfg(debug_assertions)]
                        {
                            exit_reason = match error {
                                mpsc::TrySendError::Full(_) => "queue-full",
                                mpsc::TrySendError::Disconnected(_) => "queue-closed",
                            };
                        }
                        #[cfg(not(debug_assertions))]
                        let _ = error;
                        break;
                    }
                    if wake.as_ref().is_some_and(|wake| wake.notify().is_err()) {
                        #[cfg(debug_assertions)]
                        {
                            exit_reason = "wake-failure";
                        }
                        break;
                    }
                    let reply = match result.recv_timeout(OP_WAIT) {
                        Ok(Ok(payload)) => {
                            if let Some(connection) = grant_connection {
                                owned_physical = op == PHYSICAL_GRANT || op == PHYSICAL_ROTATE;
                                if canonical == GRANT {
                                    owned.clear();
                                } else {
                                    owned.retain(|r| Some(*r) == old_reference);
                                }
                                owned.push(GrantRef {
                                    connection,
                                    session: payload[32..48].try_into().unwrap(),
                                });
                            } else if canonical == RELEASE {
                                owned.retain(|r| Some(*r) != old_reference);
                            } else if canonical == PACKET
                                && owned.last().copied() == old_reference
                                && owned.len() == 2
                            {
                                owned.remove(0);
                            }
                            let mut r = vec![0, op];
                            r.extend_from_slice(&payload);
                            r
                        }
                        failure => {
                            #[cfg(debug_assertions)]
                            crate::input_io_diagnostics::terminal(
                                "native-server-wait",
                                op,
                                match &failure {
                                    Ok(Err(error)) => error,
                                    Err(mpsc::RecvTimeoutError::Timeout) => {
                                        "native_owner_reply_timeout"
                                    }
                                    _ => "native_owner_reply_closed",
                                },
                            );
                            #[cfg(not(debug_assertions))]
                            let _ = failure;
                            vec![1, op]
                        }
                    };
                    let sent = {
                        #[cfg(debug_assertions)]
                        let _io = crate::input_io_diagnostics::Span::start(
                            crate::input_io_diagnostics::Metric::NativeServerReply,
                        );
                        send(&mut stream, &reply, OP_WAIT)
                    };
                    if let Err(error) = sent {
                        #[cfg(debug_assertions)]
                        crate::input_io_diagnostics::terminal("native-server-send", op, error);
                        #[cfg(not(debug_assertions))]
                        let _ = error;
                        #[cfg(debug_assertions)]
                        {
                            exit_reason = "send-failure";
                        }
                        break;
                    }
                }
                #[cfg(debug_assertions)]
                crate::input_error_diagnostics::server_exit(exit_reason, owned.len());
                for binding in owned {
                    let (response, _) = mpsc::sync_channel(1);
                    let mut payload = binding.connection.to_vec();
                    payload.extend_from_slice(&binding.session);
                    let queued = incoming
                        .try_send(Pending {
                            #[cfg(debug_assertions)]
                            queue_span: crate::input_io_diagnostics::Span::start(
                                crate::input_io_diagnostics::Metric::NativeServerQueue,
                            ),
                            op: if owned_physical {
                                PHYSICAL_RELEASE
                            } else {
                                RELEASE
                            },
                            payload,
                            deadline: Instant::now() + OP_WAIT,
                            response,
                        })
                        .is_ok();
                    if queued {
                        if let Some(wake) = &wake {
                            let _ = wake.notify();
                        }
                    }
                }
                let _ = stream.shutdown(Shutdown::Both);
                if let Ok(mut peers) = peers.lock() {
                    peers.remove(&id);
                }
            }));
        }
        drop(incoming);
        let owner_stop = stop.clone();
        let owner_peers = peers.clone();
        let owner_jobs = jobs.clone();
        let next = AtomicU64::new(1);
        let accept = thread::spawn(move || {
            while !owner_stop.load(Ordering::SeqCst) {
                for _ in 0..8 {
                    let (stream, _) = match listener.accept() {
                        Ok(pair) => pair,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(_) => {
                            owner_stop.store(true, Ordering::SeqCst);
                            break;
                        }
                    };
                    let id = next.fetch_add(1, Ordering::Relaxed);
                    let mut peers = match owner_peers.lock() {
                        Ok(p) => p,
                        Err(_) => return,
                    };
                    if peers.len() >= 8 {
                        let _ = stream.shutdown(Shutdown::Both);
                        continue;
                    }
                    if let Ok(copy) = stream.try_clone() {
                        peers.insert(id, copy);
                    } else {
                        continue;
                    }
                    if let Err(
                        mpsc::TrySendError::Full((_, stream))
                        | mpsc::TrySendError::Disconnected((_, stream)),
                    ) = owner_jobs.try_send((id, stream))
                    {
                        peers.remove(&id);
                        let _ = stream.shutdown(Shutdown::Both);
                    }
                }
                thread::sleep(Duration::from_millis(5));
            }
        });
        Ok(Self {
            _lease: lease,
            pending,
            jobs: Some(jobs),
            stop,
            peers,
            accept: Some(accept),
            workers,
            path,
            binding: None,
            staged: None,
            wake,
        })
    }
    pub fn drain(
        &mut self,
        runtime: &mut PacketRuntime,
        now: u64,
        output: &mut impl Output,
    ) -> Result<(), &'static str> {
        if self.stop.load(Ordering::SeqCst) {
            return Err("native_input_owner_failed");
        }
        // Bounded work preserves owner-pipe progress and the independent 10ms safety tick.
        let mut drained = 0;
        for _ in 0..4 {
            let request = match self.pending.try_recv() {
                Ok(r) => r,
                Err(mpsc::TryRecvError::Empty) => break,
                Err(_) => return Err("native_input_owner_failed"),
            };
            drained += 1;
            #[cfg(debug_assertions)]
            drop(request.queue_span);
            let result = {
                #[cfg(debug_assertions)]
                let _io = crate::input_io_diagnostics::Span::start(
                    crate::input_io_diagnostics::Metric::NativeServerApply,
                );
                if Instant::now() >= request.deadline {
                    Err("native_input_timeout")
                } else {
                    self.apply(request.op, &request.payload, runtime, now, output)
                }
            };
            let issued = matches!(canonical_op(request.op), GRANT | ROTATE) && result.is_ok();
            if request.response.try_send(result).is_err() && issued {
                self.binding = None;
                self.staged = None;
                runtime.release_reason(output, "native_grant_delivery_failed")?;
            }
        }
        // A coalesced notification may cover more than one bounded batch.
        // Revisit after checking stdin and the authoritative safety clock.
        if drained == 4 {
            if let Some(wake) = &self.wake {
                wake.notify()?;
            }
        }
        Ok(())
    }
    fn apply(
        &mut self,
        op: u8,
        b: &[u8],
        runtime: &mut PacketRuntime,
        now: u64,
        output: &mut impl Output,
    ) -> Result<Vec<u8>, &'static str> {
        let snapshot = runtime.snapshot();
        let physical = matches!(
            op,
            PHYSICAL_GRANT | PHYSICAL_PACKET | PHYSICAL_RELEASE | PHYSICAL_ROTATE
        );
        let canonical = canonical_op(op);
        if op != OUTPUT_STATUS {
            if physical {
                if snapshot.backend != "macos-hid" {
                    return Err("native_input_backend_not_supported");
                }
                if canonical != RELEASE && !snapshot.input_enabled {
                    return Err("native_physical_output_not_admitted");
                }
            } else if snapshot.backend != "recording" {
                return Err("native_input_backend_not_supported");
            }
        }
        let op = canonical;
        if self
            .binding
            .as_ref()
            .is_some_and(|a| !snapshot.active || a.generation.to_string() != snapshot.generation)
        {
            self.binding = None;
            self.staged = None;
        }
        if self
            .staged
            .as_ref()
            .is_some_and(|s| runtime.rotation_session() != Some(s.reference.session))
        {
            self.staged = None;
        }
        match op {
            SAVED_STATUS | OUTPUT_STATUS => {
                let mut reply = vec![u8::from(snapshot.active)];
                reply.extend_from_slice(&decimal(&snapshot.generation)?.to_le_bytes());
                reply.extend_from_slice(&decimal(&snapshot.revision)?.to_le_bytes());
                if let Some(pin) = runtime.saved_binding() {
                    reply.push(1);
                    reply.extend_from_slice(&decimal(&pin.configuration_revision)?.to_le_bytes());
                    reply.extend_from_slice(pin.source_hash.as_bytes());
                    reply.extend_from_slice(pin.profile_id.as_bytes());
                } else {
                    reply.push(0);
                }
                if op == OUTPUT_STATUS {
                    reply.push(match snapshot.backend {
                        "recording" => 0,
                        "macos-hid" => 1,
                        _ => return Err("native_input_backend_not_supported"),
                    });
                    reply.push(u8::from(snapshot.input_enabled));
                }
                Ok(reply)
            }
            STATUS => {
                let mut r = vec![u8::from(snapshot.active)];
                r.extend_from_slice(&decimal(&snapshot.generation)?.to_le_bytes());
                r.extend_from_slice(&decimal(&snapshot.revision)?.to_le_bytes());
                Ok(r)
            }
            GRANT => {
                let connection: [u8; 16] = b[..16].try_into().unwrap();
                if connection == [0; 16] {
                    return Err("native_input_grant_invalid");
                }
                let generation = number(b, 16);
                let revision = number(b, 24);
                let lifetime = u32::from_le_bytes(b[32..36].try_into().unwrap());
                let key = random::<32>()?;
                let session = random::<16>()?;
                let prefix = random::<4>()?;
                runtime.attach(
                    PacketGrant::new(&key, session, prefix, generation)
                        .map_err(|_| "native_input_grant_invalid")?,
                    revision,
                    u64::from(lifetime),
                    now,
                    output,
                )?;
                self.staged = None;
                self.binding = Some(Binding {
                    reference: GrantRef {
                        connection,
                        session,
                    },
                    generation,
                });
                let mut r = key.to_vec();
                r.extend_from_slice(&session);
                r.extend_from_slice(&prefix);
                r.extend_from_slice(&generation.to_le_bytes());
                r.extend_from_slice(&revision.to_le_bytes());
                r.extend_from_slice(&lifetime.to_le_bytes());
                Ok(r)
            }
            ROTATE => {
                let previous = GrantRef {
                    connection: b[..16].try_into().unwrap(),
                    session: b[16..32].try_into().unwrap(),
                };
                if !self
                    .binding
                    .as_ref()
                    .is_some_and(|a| a.reference == previous)
                {
                    return Err("native_input_session_closed");
                }
                let generation = number(b, 32);
                let revision = number(b, 40);
                let lifetime = u32::from_le_bytes(b[48..52].try_into().unwrap());
                let key = random::<32>()?;
                let session = random::<16>()?;
                let prefix = random::<4>()?;
                runtime.stage_rotation(
                    previous.session,
                    PacketGrant::new(&key, session, prefix, generation)
                        .map_err(|_| "native_input_grant_invalid")?,
                    revision,
                    u64::from(lifetime),
                    now,
                    output,
                )?;
                self.staged = Some(Binding {
                    reference: GrantRef {
                        connection: previous.connection,
                        session,
                    },
                    generation,
                });
                let mut r = key.to_vec();
                r.extend_from_slice(&session);
                r.extend_from_slice(&prefix);
                r.extend_from_slice(&generation.to_le_bytes());
                r.extend_from_slice(&revision.to_le_bytes());
                r.extend_from_slice(&lifetime.to_le_bytes());
                Ok(r)
            }
            PACKET | RELEASE => {
                let reference = GrantRef {
                    connection: b[..16].try_into().unwrap(),
                    session: b[16..32].try_into().unwrap(),
                };
                let current = self
                    .binding
                    .as_ref()
                    .is_some_and(|a| a.reference == reference);
                let staged = self
                    .staged
                    .as_ref()
                    .is_some_and(|a| a.reference == reference);
                if !current && !staged {
                    return if op == RELEASE {
                        Ok(Vec::new())
                    } else {
                        Err("native_input_session_closed")
                    };
                }
                if op == PACKET {
                    runtime.receive(&b[32..], now, output)?;
                    if staged {
                        self.binding = self.staged.take();
                    }
                } else if current {
                    self.binding = None;
                    self.staged = None;
                    runtime.release_reason(output, "native_input_released")?;
                } else {
                    runtime.cancel_rotation(reference.session);
                    self.staged = None;
                }
                Ok(Vec::new())
            }
            _ => Err("native_input_frame_invalid"),
        }
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Ok(peers) = self.peers.lock() {
            for peer in peers.values() {
                let _ = peer.shutdown(Shutdown::Both);
            }
        }
        if let Some(accept) = self.accept.take() {
            let _ = accept.join();
        }
        self.jobs = None;
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
        let _ = fs::remove_file(&self.path);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{gamepad::NEUTRAL, generated::GamepadState, runtime::Command};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let root = Self(std::env::temp_dir().canonicalize().unwrap().join(format!(
                "thumble-native-ingress-unit-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            )));
            security::directory(&root.0).unwrap();
            root
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    struct Sink([u8; 20]);
    impl Output for Sink {
        fn submit(&mut self, r: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            self.0 = r;
            Ok(())
        }
    }
    fn runtime() -> (PacketRuntime, Sink) {
        let mut runtime = PacketRuntime::default();
        let mut sink = Sink(NEUTRAL);
        runtime
            .apply_owner(
                Command::Activate {
                    generation: "1".into(),
                    revision: "1".into(),
                    profile_id: "profile-a".into(),
                    session_id: "owner".into(),
                    lease_ms: 750,
                    input_ttl_ms: 350,
                },
                0,
                &mut sink,
            )
            .unwrap();
        let state:GamepadState=serde_json::from_value(serde_json::json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":1,"rightTrigger":1})).unwrap();
        runtime
            .apply_owner(
                Command::Sample {
                    generation: "1".into(),
                    session_id: "owner".into(),
                    sequence: "10".into(),
                    state,
                },
                1,
                &mut sink,
            )
            .unwrap();
        (runtime, sink)
    }
    fn grant_payload() -> Vec<u8> {
        let mut b = vec![8; 16];
        b.extend_from_slice(&1u64.to_le_bytes());
        b.extend_from_slice(&1u64.to_le_bytes());
        b.extend_from_slice(&1000u32.to_le_bytes());
        b
    }
    #[test]
    fn recording_only_phone_wire_cannot_issue_a_physical_output_grant() {
        struct PhysicalStatus;
        impl crate::runtime::OutputStatus for PhysicalStatus {
            fn backend(&self) -> &'static str {
                "macos-hid"
            }
            fn enabled(&self, _: u64) -> bool {
                true
            }
        }
        struct PhysicalSink;
        impl Output for PhysicalSink {
            fn submit(&mut self, _: [u8; 20], _: &'static str) -> Result<(), &'static str> {
                Ok(())
            }
            fn status(&self) -> Option<Arc<dyn crate::runtime::OutputStatus>> {
                Some(Arc::new(PhysicalStatus))
            }
        }
        let root = Root::new();
        let mut server = Server::bind(&root.0).unwrap();
        let mut runtime = PacketRuntime::default();
        let mut sink = PhysicalSink;
        runtime
            .apply_owner(
                Command::Activate {
                    generation: "1".into(),
                    revision: "1".into(),
                    profile_id: "profile-a".into(),
                    session_id: "owner".into(),
                    lease_ms: 750,
                    input_ttl_ms: 350,
                },
                0,
                &mut sink,
            )
            .unwrap();
        assert_eq!(runtime.snapshot().backend, "macos-hid");
        assert!(runtime.snapshot().input_enabled);
        assert_eq!(
            server.apply(GRANT, &grant_payload(), &mut runtime, 1, &mut sink),
            Err("native_input_backend_not_supported")
        );
        assert_eq!(
            server.apply(STATUS, &[], &mut runtime, 1, &mut sink),
            Err("native_input_backend_not_supported")
        );
        assert!(server.binding.is_none());
        assert!(runtime.snapshot().active);
        assert_eq!(runtime.snapshot().generation, "1");
        assert_eq!(runtime.snapshot().report_hex, crate::gamepad::hex(&NEUTRAL));
    }
    #[test]
    fn endpoint_has_one_native_owner_rotates_capability_and_never_exposes_material_through_a_codec()
    {
        let root = Root::new();
        let server = Server::bind(&root.0).unwrap();
        let old = fs::read(&server.path).unwrap();
        assert_eq!(old.len(), 42);
        assert!(matches!(
            Server::bind(&root.0),
            Err("native_input_owner_exists")
        ));
        drop(server);
        assert!(!root.0.join("native-input.endpoint").exists());
        let server = Server::bind(&root.0).unwrap();
        let new = fs::read(&server.path).unwrap();
        assert_ne!(&old[10..], &new[10..]);
        fs::write(&server.path, b"invalid").unwrap();
        assert!(Client::connect(&root.0).is_err());
    }
    #[test]
    fn invalid_capabilities_lengths_and_shapes_never_enter_the_output_queue() {
        let root = Root::new();
        let mut server = Server::bind(&root.0).unwrap();
        let endpoint = fs::read(&server.path).unwrap();
        let port = u16::from_le_bytes(endpoint[8..10].try_into().unwrap());
        let (mut runtime, mut sink) = runtime();
        let before = sink.0;
        let mut wrong = vec![1];
        wrong.extend_from_slice(&[0; 32]);
        wrong.push(STATUS);
        let mut shape = vec![1];
        shape.extend_from_slice(&endpoint[10..]);
        shape.push(GRANT);
        let mut short_rotation = vec![1];
        short_rotation.extend_from_slice(&endpoint[10..]);
        short_rotation.push(ROTATE);
        short_rotation.extend_from_slice(&[0; 51]);
        let mut long_rotation = short_rotation.clone();
        long_rotation.extend_from_slice(&[0; 2]);
        for payload in [wrong, shape, short_rotation, long_rotation] {
            let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            send(&mut stream, &[0; 17], OP_WAIT).unwrap();
            assert_eq!(receive(&mut stream, OP_WAIT).unwrap().len(), 33);
            send(&mut stream, &payload, OP_WAIT).unwrap();
            assert!(receive(&mut stream, OP_WAIT).is_err());
        }
        let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
        stream
            .write_all(&((LIMIT + 1) as u16).to_be_bytes())
            .unwrap();
        assert!(receive(&mut stream, OP_WAIT).is_err());
        server.drain(&mut runtime, 2, &mut sink).unwrap();
        assert_eq!(sink.0, before);
        assert!(server.binding.is_none());
    }
    #[test]
    fn stale_endpoint_port_reuse_cannot_extract_the_client_capability_before_server_proof() {
        let root = Root::new();
        let server = Server::bind(&root.0).unwrap();
        let mut endpoint = fs::read(&server.path).unwrap();
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        endpoint[8..10].copy_from_slice(&listener.local_addr().unwrap().port().to_le_bytes());
        fs::write(&server.path, endpoint).unwrap();
        let fake = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let hello = receive(&mut stream, OP_WAIT).unwrap();
            assert_eq!(hello.len(), 17);
            assert_eq!(hello[0], 0);
            send(&mut stream, &[0; 33], OP_WAIT).unwrap();
            assert!(receive(&mut stream, OP_WAIT).is_err());
        });
        assert!(matches!(
            Client::connect(&root.0),
            Err("native_input_server_rejected")
        ));
        fake.join().unwrap();
    }
    #[test]
    fn expired_queue_work_never_installs_and_abandoned_grant_delivery_is_neutral() {
        let root = Root::new();
        let mut server = Server::bind(&root.0).unwrap();
        let (sender, pending) = mpsc::sync_channel(8);
        server.pending = pending;
        let (mut runtime, mut sink) = runtime();
        let before = sink.0;
        let (response, result) = mpsc::sync_channel(1);
        sender
            .send(Pending {
                #[cfg(debug_assertions)]
                queue_span: crate::input_io_diagnostics::Span::start(
                    crate::input_io_diagnostics::Metric::NativeServerQueue,
                ),
                op: GRANT,
                payload: grant_payload(),
                deadline: Instant::now() - Duration::from_secs(1),
                response,
            })
            .unwrap();
        server.drain(&mut runtime, 2, &mut sink).unwrap();
        assert!(result.recv().unwrap().is_err());
        assert_eq!(sink.0, before);
        assert!(server.binding.is_none());
        let (response, result) = mpsc::sync_channel(1);
        drop(result);
        sender
            .send(Pending {
                #[cfg(debug_assertions)]
                queue_span: crate::input_io_diagnostics::Span::start(
                    crate::input_io_diagnostics::Metric::NativeServerQueue,
                ),
                op: GRANT,
                payload: grant_payload(),
                deadline: Instant::now() + OP_WAIT,
                response,
            })
            .unwrap();
        server.drain(&mut runtime, 3, &mut sink).unwrap();
        assert_eq!(sink.0, NEUTRAL);
        assert!(!runtime.snapshot().active);
        assert!(server.binding.is_none());
        assert_eq!(
            runtime.snapshot().last_release_reason,
            "native_grant_delivery_failed"
        );
    }
    #[test]
    fn abandoned_rotation_delivery_retires_the_held_source_and_staged_material() {
        let root = Root::new();
        let mut server = Server::bind(&root.0).unwrap();
        let (mut runtime, mut sink) = runtime();
        let grant = server
            .apply(GRANT, &grant_payload(), &mut runtime, 2, &mut sink)
            .unwrap();
        let key: [u8; 32] = grant[..32].try_into().unwrap();
        let session: [u8; 16] = grant[32..48].try_into().unwrap();
        let prefix: [u8; 4] = grant[48..52].try_into().unwrap();
        let mut sender = PacketSender::new(
            PacketGrant::new(&key, session, prefix, 1).unwrap(),
            PACKET_LIMIT,
        )
        .unwrap();
        let held: GamepadState = serde_json::from_value(serde_json::json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":1,"rightTrigger":1})).unwrap();
        let mut packet = vec![8; 16];
        packet.extend_from_slice(&session);
        packet.extend_from_slice(&sender.seal(&held).unwrap());
        server
            .apply(PACKET, &packet, &mut runtime, 3, &mut sink)
            .unwrap();
        assert_ne!(sink.0, NEUTRAL);
        let mut payload = vec![8; 16];
        payload.extend_from_slice(&session);
        payload.extend_from_slice(&1u64.to_le_bytes());
        payload.extend_from_slice(&1u64.to_le_bytes());
        payload.extend_from_slice(&1000u32.to_le_bytes());
        let (incoming, pending) = mpsc::sync_channel(1);
        server.pending = pending;
        let (response, receipt) = mpsc::sync_channel(1);
        drop(receipt);
        incoming
            .send(Pending {
                #[cfg(debug_assertions)]
                queue_span: crate::input_io_diagnostics::Span::start(
                    crate::input_io_diagnostics::Metric::NativeServerQueue,
                ),
                op: ROTATE,
                payload,
                deadline: Instant::now() + OP_WAIT,
                response,
            })
            .unwrap();
        server.drain(&mut runtime, 4, &mut sink).unwrap();
        assert_eq!(sink.0, NEUTRAL);
        assert!(!runtime.snapshot().active);
        assert_eq!(
            runtime.snapshot().last_release_reason,
            "native_grant_delivery_failed"
        );
        assert!(server.binding.is_none() && server.staged.is_none());
        assert!(runtime.rotation_session().is_none());
    }
    #[test]
    fn actual_native_status_wakes_parked_owner_without_renewing_lease() {
        let root = Root::new();
        let wake = Arc::new(crate::owner_wake::OwnerWake::default());
        let mut server = Server::bind_with_wake(&root.0, Some(wake.clone())).unwrap();
        let (mut runtime, mut sink) = runtime();
        let (started, ready) = mpsc::sync_channel(1);
        thread::scope(|scope| {
            let request = scope.spawn(|| {
                let mut client = Client::connect(&root.0).unwrap();
                started.send(()).unwrap();
                // configuration uses the unchanged 250ms operation budget.
                assert!(client.configuration().unwrap().active);
            });
            ready.recv().unwrap();
            // TEST-only long park proves native enqueue wakes us, rather than
            // depending on the production 10ms fallback polling interval.
            wake.wait(Duration::from_secs(1)).unwrap();
            server.drain(&mut runtime, 2, &mut sink).unwrap();
            request.join().unwrap();
        });
        runtime.tick(751, &mut sink).unwrap();
        assert!(!runtime.snapshot().active);
        assert_eq!(sink.0, NEUTRAL);
        assert_eq!(runtime.snapshot().last_release_reason, "lease_expired");
    }
    #[test]
    fn draining_native_requests_is_bounded_for_owner_progress() {
        let root = Root::new();
        let wake = Arc::new(crate::owner_wake::OwnerWake::default());
        let mut server = Server::bind_with_wake(&root.0, Some(wake.clone())).unwrap();
        let (sender, pending) = mpsc::sync_channel(8);
        server.pending = pending;
        let (mut runtime, mut sink) = runtime();
        let mut results = Vec::new();
        for _ in 0..8 {
            let (response, result) = mpsc::sync_channel(1);
            sender
                .send(Pending {
                    #[cfg(debug_assertions)]
                    queue_span: crate::input_io_diagnostics::Span::start(
                        crate::input_io_diagnostics::Metric::NativeServerQueue,
                    ),
                    op: STATUS,
                    payload: vec![],
                    deadline: Instant::now() + OP_WAIT,
                    response,
                })
                .unwrap();
            results.push(result);
        }
        server.drain(&mut runtime, 2, &mut sink).unwrap();
        assert_eq!(results.iter().filter(|r| r.try_recv().is_ok()).count(), 4);
        wake.wait(Duration::from_secs(1)).unwrap();
        server.drain(&mut runtime, 3, &mut sink).unwrap();
        assert_eq!(results.iter().filter(|r| r.try_recv().is_ok()).count(), 4);
    }
    #[test]
    fn socket_deadline_categories_do_not_hide_other_io_failures() {
        use std::io::ErrorKind;
        for kind in [ErrorKind::WouldBlock, ErrorKind::TimedOut] {
            assert_eq!(
                io_failure(&std::io::Error::from(kind)),
                "native_input_timeout"
            );
        }
        for kind in [
            ErrorKind::Interrupted,
            ErrorKind::UnexpectedEof,
            ErrorKind::BrokenPipe,
            ErrorKind::ConnectionReset,
            ErrorKind::InvalidInput,
            ErrorKind::Other,
        ] {
            assert_eq!(
                io_failure(&std::io::Error::from(kind)),
                "native_input_transport_failed"
            );
        }
        #[cfg(unix)]
        assert_eq!(
            io_failure(&std::io::Error::from_raw_os_error(libc::EAGAIN)),
            "native_input_timeout"
        );
    }
    #[test]
    fn response_deadline_closes_the_transport_without_replaying_a_request() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let peer = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let frame = receive(&mut stream, Duration::from_secs(2)).unwrap();
            let mut expected = vec![1];
            expected.extend_from_slice(&[8; 32]);
            expected.push(STATUS);
            assert_eq!(frame, expected);
            // Never send a response. The client's unchanged OP_WAIT must cause
            // socket shutdown; a retry would instead appear as another frame.
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut unexpected = [0];
            assert_eq!(stream.read(&mut unexpected).unwrap(), 0);
        });
        let mut client = Client {
            stream: TcpStream::connect(address).unwrap(),
            token: [8; 32],
            physical: false,
        };
        assert!(matches!(
            client.configuration(),
            Err("native_input_timeout")
        ));
        assert!(client.configuration().is_err());
        peer.join().unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn endpoint_publication_and_read_refuse_symlink_retargeting() {
        use std::os::unix::fs::symlink;
        let root = Root::new();
        let target = root.0.join("retained");
        fs::write(&target, b"preserve").unwrap();
        symlink(&target, root.0.join("native-input.endpoint")).unwrap();
        assert!(Server::bind(&root.0).is_err());
        assert!(Client::connect(&root.0).is_err());
        assert_eq!(fs::read(&target).unwrap(), b"preserve");
    }
}

#[cfg(test)]
#[path = "physical_input_tests.rs"]
mod physical_tests;
