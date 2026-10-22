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
fn random<const N: usize>() -> Result<[u8; N], &'static str> {
    let mut bytes = [0; N];
    SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| "native_input_entropy_failed")?;
    Ok(bytes)
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
        stream
            .set_read_timeout(Some(left))
            .map_err(|_| "native_input_transport_failed")?;
        let n = stream
            .read(&mut bytes[at..])
            .map_err(|_| "native_input_transport_failed")?;
        if n == 0 {
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
        stream
            .set_write_timeout(Some(left))
            .map_err(|_| "native_input_transport_failed")?;
        let n = stream
            .write(&frame[at..])
            .map_err(|_| "native_input_transport_failed")?;
        if n == 0 {
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
/// Opaque native-only secret. Deliberately no Debug, Clone, Serialize or raw key getter.
pub struct NativeGrant {
    key: [u8; 32],
    session: [u8; 16],
    prefix: [u8; 4],
    generation: u64,
    revision: u64,
    lifetime_ms: u32,
    binding: GrantRef,
}
impl NativeGrant {
    pub(crate) fn session_id(&self) -> String {
        crate::gamepad::hex(&self.session)
    }
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
        if channel.native_binding() != Some(self.binding.connection) {
            return Err("native_grant_delivery_unconfirmed");
        }
        let value = serde_json::json!({"version":1,"command":"input-granted","connectionId":crate::gamepad::hex(&self.binding.connection),"generation":self.generation.to_string(),"revision":self.revision.to_string(),"sessionId":crate::gamepad::hex(&self.session),"key":crate::gamepad::hex(&self.key),"noncePrefix":crate::gamepad::hex(&self.prefix),"lifetimeMs":self.lifetime_ms,"packetVersion":1,"packetBytes":PACKET_BYTES,"packetLimit":PACKET_LIMIT.to_string(),"transport":"tls","inputEnabled":false});
        channel
            .send(
                crate::control_tls::FrameKind::Control,
                &serde_json::to_vec(&value).map_err(|_| "native_grant_delivery_unconfirmed")?,
            )
            .map_err(|_| "native_grant_delivery_unconfirmed")
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
}
/// One serialized native worker connection. Never put this blocking API on the safety/input/UI loop.
pub struct Client {
    stream: TcpStream,
    token: [u8; 32],
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
        Ok(Self { stream, token })
    }
    pub(crate) fn close(&mut self) {
        let _ = self.stream.shutdown(Shutdown::Both);
    }
    fn request(&mut self, op: u8, payload: &[u8]) -> Result<Vec<u8>, &'static str> {
        let mut bytes = vec![1];
        bytes.extend_from_slice(&self.token);
        bytes.push(op);
        bytes.extend_from_slice(payload);
        let result = (|| {
            send(&mut self.stream, &bytes, OP_WAIT)?;
            let reply = receive(&mut self.stream, OP_WAIT)?;
            if reply.len() < 2
                || reply[0] > 1
                || reply[1] != op
                || (reply[0] == 1 && reply.len() != 2)
            {
                return Err("native_input_frame_invalid");
            }
            Ok(reply)
        })();
        if result.is_err() {
            let _ = self.stream.shutdown(Shutdown::Both);
        }
        let reply = result?;
        if reply[0] == 1 {
            return Err("native_input_rejected");
        }
        Ok(reply[2..].to_vec())
    }
    pub fn configuration(&mut self) -> Result<Configuration, &'static str> {
        let b = self.request(STATUS, &[])?;
        if b.len() != 17 || b[0] > 1 {
            return Err("native_input_frame_invalid");
        }
        Ok(Configuration {
            active: b[0] == 1,
            generation: number(&b, 1),
            revision: number(&b, 9),
        })
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
}
impl Server {
    pub fn bind(root: &Path) -> Result<Self, &'static str> {
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
            workers.push(thread::spawn(move || loop {
                let (id, mut stream) = match work.lock() {
                    Ok(work) => match work.recv() {
                        Ok(job) => job,
                        Err(_) => break,
                    },
                    Err(_) => break,
                };
                let _ = stream.set_nonblocking(false);
                let _ = stream.set_nodelay(true);
                let mut owned: Option<GrantRef> = None;
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
                while authenticated_server && !stop.load(Ordering::SeqCst) {
                    let b = match receive(&mut stream, FRAME_WAIT) {
                        Ok(b) => b,
                        Err(_) => break,
                    };
                    if b.len() < 34 || b[0] != 1 || !bool::from(b[1..33].ct_eq(&token)) {
                        break;
                    }
                    let op = b[33];
                    let payload = b[34..].to_vec();
                    if !matches!(
                        (op, payload.len()),
                        (STATUS, 0) | (GRANT, 36) | (PACKET, 140) | (RELEASE, 32)
                    ) {
                        break;
                    }
                    let grant_connection = if op == GRANT {
                        Some(<[u8; 16]>::try_from(&payload[..16]).unwrap())
                    } else {
                        None
                    };
                    let (response, result) = mpsc::sync_channel(1);
                    let deadline = Instant::now() + OP_WAIT;
                    if incoming
                        .try_send(Pending {
                            op,
                            payload,
                            deadline,
                            response,
                        })
                        .is_err()
                    {
                        break;
                    }
                    let reply = match result.recv_timeout(OP_WAIT) {
                        Ok(Ok(payload)) => {
                            if let Some(connection) = grant_connection {
                                owned = Some(GrantRef {
                                    connection,
                                    session: payload[32..48].try_into().unwrap(),
                                });
                            } else if op == RELEASE {
                                owned = None;
                            }
                            let mut r = vec![0, op];
                            r.extend_from_slice(&payload);
                            r
                        }
                        _ => vec![1, op],
                    };
                    if send(&mut stream, &reply, OP_WAIT).is_err() {
                        break;
                    }
                }
                if let Some(binding) = owned {
                    let (response, _) = mpsc::sync_channel(1);
                    let mut payload = binding.connection.to_vec();
                    payload.extend_from_slice(&binding.session);
                    let _ = incoming.try_send(Pending {
                        op: RELEASE,
                        payload,
                        deadline: Instant::now() + OP_WAIT,
                        response,
                    });
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
        for _ in 0..4 {
            let request = match self.pending.try_recv() {
                Ok(r) => r,
                Err(mpsc::TryRecvError::Empty) => break,
                Err(_) => return Err("native_input_owner_failed"),
            };
            let result = if Instant::now() >= request.deadline {
                Err("native_input_timeout")
            } else {
                self.apply(request.op, &request.payload, runtime, now, output)
            };
            let issued = request.op == GRANT && result.is_ok();
            if request.response.try_send(result).is_err() && issued {
                self.binding = None;
                runtime.release_reason(output, "native_grant_delivery_failed")?;
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
        if self
            .binding
            .as_ref()
            .is_some_and(|a| !snapshot.active || a.generation.to_string() != snapshot.generation)
        {
            self.binding = None;
        }
        match op {
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
            PACKET | RELEASE => {
                let reference = GrantRef {
                    connection: b[..16].try_into().unwrap(),
                    session: b[16..32].try_into().unwrap(),
                };
                if !self
                    .binding
                    .as_ref()
                    .is_some_and(|a| a.reference == reference)
                {
                    return if op == RELEASE {
                        Ok(Vec::new())
                    } else {
                        Err("native_input_session_closed")
                    };
                }
                if op == PACKET {
                    runtime.receive(&b[32..], now, output)?;
                } else {
                    self.binding = None;
                    runtime.release_reason(output, "native_input_released")?;
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
        for payload in [wrong, shape] {
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
    fn draining_native_requests_is_bounded_for_owner_progress() {
        let root = Root::new();
        let mut server = Server::bind(&root.0).unwrap();
        let (sender, pending) = mpsc::sync_channel(8);
        server.pending = pending;
        let (mut runtime, mut sink) = runtime();
        let mut results = Vec::new();
        for _ in 0..8 {
            let (response, result) = mpsc::sync_channel(1);
            sender
                .send(Pending {
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
        server.drain(&mut runtime, 3, &mut sink).unwrap();
        assert_eq!(results.iter().filter(|r| r.try_recv().is_ok()).count(), 4);
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
