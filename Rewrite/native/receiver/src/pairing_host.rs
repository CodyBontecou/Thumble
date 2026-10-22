//! Agent-facing native pairing owner. Enrollment sockets never share the receiver safety loop.
use crate::{
    control_tls::{ControlChannel, ServerIdentity, CONTROL_SERVER_NAME},
    enrollment::{self, PairingOffer, PairingWindows},
    host_identity,
    input_broker::Registry,
    phone_trust::PhoneTrustStore,
    runtime, security,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    fs::File,
    io::{BufRead, BufReader, Write},
    net::{Shutdown, SocketAddr, TcpListener, TcpStream},
    path::Path,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc, Arc, Mutex,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
const FRAME_BYTES: usize = 65_536;
type Peers = Arc<Mutex<BTreeMap<u64, TcpStream>>>;
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    version: u8,
    request_id: String,
    body: Command,
}
#[derive(Deserialize)]
#[serde(
    tag = "command",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum Command {
    PairingOpen {},
    PairingStatus {},
    PairingList {},
    PairingRevoke {
        phone_id: String,
    },
    PairingCancel {},
    PairingListen {
        bind_address: String,
        advertise_host: String,
    },
    PairingStopListening {},
}
fn now() -> Result<u64, &'static str> {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "pairing_clock_invalid")?
            .as_millis(),
    )
    .map_err(|_| "pairing_clock_invalid")
}
fn host(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 253
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b':'))
        && !matches!(value, "0.0.0.0" | "::")
}
struct Job {
    stream: TcpStream,
    stop: Arc<AtomicBool>,
    peers: Peers,
    id: u64,
    datagram_port: u16,
}
struct Listener {
    stop: Arc<AtomicBool>,
    peers: Peers,
    thread: Option<thread::JoinHandle<()>>,
    address: SocketAddr,
    host: String,
    _datagrams: crate::input_datagram::Listener,
}
impl Drop for Listener {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Ok(peers) = self.peers.lock() {
            for stream in peers.values() {
                let _ = stream.shutdown(Shutdown::Both);
            }
        }
        if let Some(handle) = self.thread.take() {
            let _ = handle.join();
        }
    }
}
pub struct Host {
    authority: String,
    identity: Arc<ServerIdentity>,
    windows: Arc<Mutex<PairingWindows>>,
    store: Option<Arc<Mutex<PhoneTrustStore>>>,
    listener: Option<Listener>,
    policy_mutation: Arc<Mutex<()>>,
    input_grants: Arc<Registry>,
    jobs: Option<mpsc::SyncSender<Job>>,
    workers: Vec<thread::JoinHandle<()>>,
    reservation_owner: Option<crate::trust_reservation::Owner>,
    _lease: File,
}
impl Host {
    pub fn new(
        root: &Path,
        authority: &str,
        identity_directory: Option<&Path>,
    ) -> Result<Self, &'static str> {
        if !runtime::identity(authority) {
            return Err("pairing_authority_invalid");
        }
        security::directory(root)?;
        let lease = security::file(&root.join("pairing-host.lock"), false)?;
        fs2::FileExt::try_lock_exclusive(&lease).map_err(|_| "pairing_host_owner_exists")?;
        let identity = Arc::new(match identity_directory {
            Some(path) => host_identity::load_existing(path)?,
            None => ServerIdentity::generate().map_err(|_| "pairing_identity_unavailable")?,
        });
        let store = identity_directory
            .map(PhoneTrustStore::open)
            .transpose()?
            .map(|store| Arc::new(Mutex::new(store)));
        let reservation_owner = store
            .as_ref()
            .map(|store| crate::trust_reservation::Owner::start(store.clone()))
            .transpose()?;
        let windows = Arc::new(Mutex::new(PairingWindows::new(authority, identity.pin())?));
        let policy_mutation = Arc::new(Mutex::new(()));
        let input_grants = Arc::new(Registry::default());
        let (jobs, incoming) = mpsc::sync_channel::<Job>(4);
        let incoming = Arc::new(Mutex::new(incoming));
        let mut workers = Vec::new();
        if let Some(store) = &store {
            for _ in 0..4 {
                let incoming = incoming.clone();
                let identity = identity.clone();
                let windows = windows.clone();
                let store = store.clone();
                let policy_mutation = policy_mutation.clone();
                let input_grants = input_grants.clone();
                let runtime_directory = root.to_path_buf();
                workers.push(thread::spawn(move || loop {
                    let job = match incoming.lock() {
                        Ok(receiver) => match receiver.recv() {
                            Ok(job) => job,
                            Err(_) => break,
                        },
                        Err(_) => break,
                    };
                    if !job.stop.load(Ordering::SeqCst) {
                        if let Ok(mut channel) =
                            ControlChannel::accept_unenrolled(job.stream, &identity)
                        {
                            if !job.stop.load(Ordering::SeqCst) {
                                let _ = enrollment::serve(
                                    &mut channel,
                                    &windows,
                                    &store,
                                    &policy_mutation,
                                    crate::input_broker::ControlInput {
                                        registry: &input_grants,
                                        renewal: false,
                                        root: &runtime_directory,
                                        datagram_port: Some(job.datagram_port),
                                    },
                                    || {
                                        if job.stop.load(Ordering::SeqCst) {
                                            Err("pairing_closed")
                                        } else {
                                            now()
                                        }
                                    },
                                );
                            }
                            channel.close();
                        }
                    }
                    if let Ok(mut peers) = job.peers.lock() {
                        peers.remove(&job.id);
                    };
                }));
            }
        }
        Ok(Self {
            authority: authority.into(),
            identity,
            windows,
            store,
            listener: None,
            policy_mutation,
            input_grants,
            jobs: Some(jobs),
            workers,
            reservation_owner,
            _lease: lease,
        })
    }
    fn transport(&self) -> Value {
        json!({"listening":self.listener.is_some(),"bindAddress":self.listener.as_ref().map(|l|l.address.to_string()),"advertiseHost":self.listener.as_ref().map(|l|l.host.clone()),"port":self.listener.as_ref().map(|l|l.address.port()),"certificatePin":self.identity.pin().hex(),"certificateDER":self.identity.certificate_der().iter().map(|b|format!("{b:02x}")).collect::<String>(),"persistentIdentity":self.store.is_some(),"serverName":CONTROL_SERVER_NAME,"controlVersion":2,"inputEnabled":false})
    }
    fn reply(&self, offer: Option<PairingOffer>) -> Result<Value, &'static str> {
        let mut status = self
            .windows
            .lock()
            .map_err(|_| "pairing_owner_unavailable")?
            .status(now()?)?;
        status.network_enabled = self.listener.is_some();
        if offer.as_ref().is_some_and(|offer| {
            status.state != "open"
                || status.window_id.as_deref() != Some(offer.window_id.as_str())
                || status.expires_at != Some(offer.expires_at)
        }) {
            return Err("pairing_closed");
        }

        let offer = offer.map(|offer| {
            let mut value =
                serde_json::to_value(offer).expect("primitive pairing offer serializes");
            if let Some(listener) = &self.listener {
                value["host"] = json!(listener.host);
                value["port"] = json!(listener.address.port());
                value["certificatePin"] = json!(self.identity.pin().hex());
                value["authorityInstanceId"] = json!(self.authority);
            }
            value
        });
        let phones = match &self.store {
            Some(store) => store
                .lock()
                .map_err(|_| "phone_trust_owner_unavailable")?
                .list()?,
            None => Vec::new(),
        };
        Ok(
            json!({"authorityInstanceId":self.authority,"pairing":status,"offer":offer,"transport":self.transport(),"phones":phones}),
        )
    }
    fn close_peers(&self) {
        if let Some(listener) = &self.listener {
            if let Ok(peers) = listener.peers.lock() {
                for peer in peers.values() {
                    let _ = peer.shutdown(Shutdown::Both);
                }
            }
        }
    }
    fn stop(&mut self) -> Result<(), &'static str> {
        if let Ok(mut windows) = self.windows.lock() {
            windows.cancel();
        }
        self.listener = None;
        let _gate = self
            .policy_mutation
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?;
        self.input_grants.retire_all()
    }
    fn listen(&mut self, bind: &str, advertise: &str) -> Result<(), &'static str> {
        if self.store.is_none() {
            return Err("pairing_persistent_identity_required");
        }
        if bind.len() > 96 || !host(advertise) {
            return Err("pairing_address_invalid");
        }
        let address: SocketAddr = bind.parse().map_err(|_| "pairing_address_invalid")?;
        if address.ip().is_multicast() {
            return Err("pairing_address_invalid");
        }
        // Replace explicitly: failure leaves no old window/listener silently active.
        self.stop()?;
        let listener = TcpListener::bind(address).map_err(|_| "pairing_bind_failed")?;
        listener
            .set_nonblocking(true)
            .map_err(|_| "pairing_bind_failed")?;
        let address = listener.local_addr().map_err(|_| "pairing_bind_failed")?;
        self.store
            .as_ref()
            .ok_or("pairing_persistent_identity_required")?;
        let datagrams =
            crate::input_datagram::Listener::bind(address.ip(), self.input_grants.clone())?;
        let datagram_port = datagrams.port();
        let stop = Arc::new(AtomicBool::new(false));
        let peers: Peers = Arc::new(Mutex::new(BTreeMap::new()));
        let stop_thread = stop.clone();
        let peers_thread = peers.clone();
        let jobs = self.jobs.as_ref().ok_or("pairing_closed")?.clone();
        let accept = thread::spawn(move || {
            let serial = AtomicU64::new(0);
            while !stop_thread.load(Ordering::SeqCst) {
                for _ in 0..8 {
                    let stream = match listener.accept() {
                        Ok((stream, _)) => stream,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(_) => {
                            stop_thread.store(true, Ordering::SeqCst);
                            break;
                        }
                    };
                    let id = serial.fetch_add(1, Ordering::Relaxed);
                    let copy = match stream.try_clone() {
                        Ok(copy) => copy,
                        Err(_) => continue,
                    };
                    let mut peers = match peers_thread.lock() {
                        Ok(peers) => peers,
                        Err(_) => return,
                    };
                    if peers.len() >= 8 {
                        continue;
                    }
                    peers.insert(id, copy);
                    drop(peers);
                    let job = Job {
                        stream,
                        stop: stop_thread.clone(),
                        peers: peers_thread.clone(),
                        id,
                        datagram_port,
                    };
                    if jobs.try_send(job).is_err() {
                        if let Ok(mut peers) = peers_thread.lock() {
                            peers.remove(&id);
                        }
                    }
                }
                thread::sleep(Duration::from_millis(10));
            }
        });
        self.listener = Some(Listener {
            stop,
            peers,
            thread: Some(accept),
            address,
            host: advertise.into(),
            _datagrams: datagrams,
        });
        Ok(())
    }
    pub fn execute(&mut self, command: Command) -> Result<Value, &'static str> {
        if self
            .listener
            .as_ref()
            .is_some_and(|listener| listener.stop.load(Ordering::SeqCst))
        {
            self.stop()?;
        }
        let offer = match command {
            Command::PairingOpen {} => Some(
                self.windows
                    .lock()
                    .map_err(|_| "pairing_owner_unavailable")?
                    .open(now()?)?,
            ),
            Command::PairingStatus {} | Command::PairingList {} => None,
            Command::PairingRevoke { phone_id } => {
                if !runtime::identity(&phone_id) {
                    return Err("phone_identity_invalid");
                }
                self.windows
                    .lock()
                    .map_err(|_| "pairing_owner_unavailable")?
                    .cancel();
                self.close_peers();
                let result = (|| {
                    let _mutation = self
                        .policy_mutation
                        .lock()
                        .map_err(|_| "phone_trust_owner_unavailable")?;
                    let mut store = self
                        .store
                        .as_ref()
                        .ok_or("pairing_persistent_identity_required")?
                        .lock()
                        .map_err(|_| "phone_trust_owner_unavailable")?;
                    store.invalidate_scope(&phone_id)?;
                    self.input_grants.retire_phone(&phone_id)?;
                    store.revoke_now(&phone_id, &mut now)
                })();
                self.close_peers();
                result?;
                None
            }
            Command::PairingCancel {} => {
                self.windows
                    .lock()
                    .map_err(|_| "pairing_owner_unavailable")?
                    .cancel();
                None
            }
            Command::PairingListen {
                bind_address,
                advertise_host,
            } => {
                self.listen(&bind_address, &advertise_host)?;
                Some(
                    self.windows
                        .lock()
                        .map_err(|_| "pairing_owner_unavailable")?
                        .open(now()?)?,
                )
            }
            Command::PairingStopListening {} => {
                self.stop()?;
                None
            }
        };
        self.reply(offer)
    }
}
impl Drop for Host {
    fn drop(&mut self) {
        let _ = self.stop();
        // Listener stop closes peer sockets. Closing the queue wakes idle workers;
        // join before releasing host/trust leases so an immediate restart is safe.
        self.jobs.take();
        for worker in self.workers.drain(..) {
            let _ = worker.join();
        }
        self.reservation_owner.take();
    }
}
/// Private inherited stdio only; parent EOF/backpressure tears down the enrollment listener.
pub fn run(
    root: &Path,
    authority: &str,
    identity_directory: Option<&Path>,
) -> Result<(), &'static str> {
    let mut host = Host::new(root, authority, identity_directory)?;
    let (incoming, received) = mpsc::sync_channel::<Option<Vec<u8>>>(16);
    thread::spawn(move || {
        let mut reader = BufReader::new(std::io::stdin());
        loop {
            let mut bytes = Vec::new();
            let mut oversized = false;
            loop {
                let buffer = match reader.fill_buf() {
                    Ok(buffer) if !buffer.is_empty() => buffer,
                    _ => {
                        let _ = incoming.send(None);
                        return;
                    }
                };
                let newline = buffer.iter().position(|b| *b == 10);
                let count = newline.map_or(buffer.len(), |i| i + 1);
                if bytes.len().saturating_add(count) > FRAME_BYTES {
                    oversized = true;
                } else if !oversized {
                    bytes.extend_from_slice(&buffer[..count]);
                }
                reader.consume(count);
                if newline.is_some() {
                    break;
                }
            }
            if oversized {
                bytes.clear();
            }
            if incoming.send(Some(bytes)).is_err() {
                return;
            }
        }
    });
    let (outgoing, responses) = mpsc::sync_channel::<String>(16);
    thread::spawn(move || {
        let mut stdout = std::io::stdout().lock();
        for line in responses {
            if writeln!(stdout, "{line}")
                .and_then(|_| stdout.flush())
                .is_err()
            {
                break;
            }
        }
    });
    outgoing.try_send(json!({"version":1,"ready":true,"pid":std::process::id(),"authorityInstanceId":authority}).to_string()).map_err(|_|"pairing_owner_output_unavailable")?;
    loop {
        let bytes = match received.recv_timeout(Duration::from_millis(10)) {
            Ok(Some(bytes)) => bytes,
            Ok(None) | Err(mpsc::RecvTimeoutError::Disconnected) => break,
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
        };
        let parsed = serde_json::from_slice::<Request>(&bytes)
            .ok()
            .filter(|request| request.version == 1 && runtime::identity(&request.request_id));
        let (id, result) = match parsed {
            Some(request) => (Some(request.request_id), host.execute(request.body)),
            None => (None, Err("invalid_request")),
        };
        let reply = match result {
            Ok(result) => json!({"version":1,"requestId":id,"ok":true,"result":result}),
            Err(code) => json!({"version":1,"requestId":id,"ok":false,"error":code}),
        };
        outgoing
            .try_send(reply.to_string())
            .map_err(|_| "pairing_owner_output_unavailable")?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::control_tls::{CertificatePin, FrameKind};
    use std::{fs, path::PathBuf, sync::atomic::AtomicU64, time::Instant};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Root(PathBuf);
    impl Root {
        fn new() -> Self {
            let root = Self(std::env::temp_dir().canonicalize().unwrap().join(format!(
                "thumble-pairing-owner-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            )));
            fs::create_dir(&root.0).unwrap();
            host_identity::load_or_create(&root.0.join("identity")).unwrap();
            root
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            for _ in 0..100 {
                if fs::remove_dir_all(&self.0).is_ok() {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
        }
    }
    fn listen(host: &mut Host) -> Value {
        host.execute(Command::PairingListen {
            bind_address: "127.0.0.1:0".into(),
            advertise_host: "127.0.0.1".into(),
        })
        .unwrap()
    }
    fn connect(value: &Value) -> ControlChannel {
        ControlChannel::connect_pinned(
            format!("127.0.0.1:{}", value["transport"]["port"])
                .parse()
                .unwrap(),
            CertificatePin::from_hex(value["transport"]["certificatePin"].as_str().unwrap())
                .unwrap(),
        )
        .unwrap()
    }
    fn send(channel: &mut ControlChannel, value: Value) {
        channel
            .send(FrameKind::Control, &serde_json::to_vec(&value).unwrap())
            .unwrap();
    }
    fn receive(channel: &mut ControlChannel) -> Value {
        let frame = channel.receive().unwrap();
        assert_eq!(frame.kind, FrameKind::Control);
        serde_json::from_slice(&frame.payload).unwrap()
    }
    fn hello(channel: &mut ControlChannel) {
        send(
            channel,
            json!({"version":1,"command":"hello","controlVersion":2,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1}),
        );
        assert_eq!(receive(channel)["authorityInstanceId"], "authority-a");
    }
    fn proof(value: &Value) -> Value {
        json!({"version":1,"command":"enroll","authorityInstanceId":"authority-a","windowId":value["offer"]["windowId"],"proof":value["offer"]["secret"],"phoneId":"phone-a","label":"Native controller"})
    }
    #[test]
    fn local_only_owner_preserves_bootstrap_shape_and_requires_explicit_persistent_identity() {
        let root = Root::new();
        let mut host = Host::new(&root.0.join("runtime"), "authority-a", None).unwrap();
        let offer = host.execute(Command::PairingOpen {}).unwrap();
        assert_eq!(offer["offer"].as_object().unwrap().len(), 3);
        assert_eq!(offer["pairing"]["networkEnabled"], false);
        assert_eq!(offer["transport"]["persistentIdentity"], false);
        assert_eq!(
            host.execute(Command::PairingListen {
                bind_address: "127.0.0.1:0".into(),
                advertise_host: "127.0.0.1".into()
            })
            .err(),
            Some("pairing_persistent_identity_required")
        );
        assert!(host.execute(Command::PairingStatus {}).unwrap()["offer"].is_null());
        assert_eq!(
            Host::new(&root.0.join("runtime"), "authority-a", None).err(),
            Some("pairing_host_owner_exists")
        );
    }
    #[test]
    fn stalled_tls_never_holds_policy_or_store_lock_and_local_cancel_fences_proof() {
        let root = Root::new();
        let mut host = Host::new(
            &root.0.join("runtime"),
            "authority-a",
            Some(&root.0.join("identity")),
        )
        .unwrap();
        let value = listen(&mut host);
        let mut channel = connect(&value);
        hello(&mut channel);
        assert!(host.store.as_ref().unwrap().try_lock().is_ok());
        let status = host.execute(Command::PairingStatus {}).unwrap();
        assert!(status["offer"].is_null());
        assert_eq!(status["pairing"]["state"], "open");
        let canceled = host.execute(Command::PairingCancel {}).unwrap();
        assert_eq!(canceled["pairing"]["state"], "closed");
        assert_eq!(canceled["transport"]["listening"], true);
        send(&mut channel, proof(&value));
        assert!(channel.receive().is_err());
        assert!(host
            .store
            .as_ref()
            .unwrap()
            .lock()
            .unwrap()
            .list()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn native_listener_commits_trust_before_reply_and_requires_storage_ack_for_completion() {
        let root = Root::new();
        let mut host = Host::new(
            &root.0.join("runtime"),
            "authority-a",
            Some(&root.0.join("identity")),
        )
        .unwrap();
        let value = listen(&mut host);
        let mut channel = connect(&value);
        hello(&mut channel);
        send(&mut channel, proof(&value));
        let reply = receive(&mut channel);
        assert_eq!(reply["command"], "enrolled");
        assert_eq!(
            host.store
                .as_ref()
                .unwrap()
                .lock()
                .unwrap()
                .list()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            host.execute(Command::PairingStatus {}).unwrap()["pairing"]["state"],
            "closed"
        );
        send(
            &mut channel,
            json!({"version":1,"command":"enrollment-stored","phoneId":"phone-a","credentialEpoch":reply["credentialEpoch"]}),
        );
        let complete = receive(&mut channel);
        assert_eq!(complete["command"], "enrollment-complete");
        assert_eq!(complete["inputEnabled"], false);
        let stop = host.execute(Command::PairingStopListening {}).unwrap();
        assert_eq!(stop["pairing"]["networkEnabled"], false);
        assert!(stop["transport"]["port"].is_null());
        assert!(channel.receive().is_err());
    }
    #[test]
    fn dropping_host_releases_worker_owned_trust_lease_before_restart() {
        let root = Root::new();
        let runtime = root.0.join("runtime");
        let identity = root.0.join("identity");
        for _ in 0..32 {
            let host = Host::new(&runtime, "authority-a", Some(&identity)).unwrap();
            let store = Arc::downgrade(host.store.as_ref().unwrap());
            drop(host);
            assert!(store.upgrade().is_none(), "host workers outlived shutdown");
        }
    }
    #[test]
    fn revocation_fences_an_enrollment_already_waiting_to_commit_and_survives_restart() {
        let root = Root::new();
        let runtime = root.0.join("runtime");
        let identity = root.0.join("identity");
        let mut host = Host::new(&runtime, "authority-a", Some(&identity)).unwrap();
        let value = listen(&mut host);
        let mut channel = connect(&value);
        hello(&mut channel);
        let store = host.store.as_ref().unwrap().clone();
        let guard = store.lock().unwrap();
        send(&mut channel, proof(&value));
        let deadline = Instant::now() + Duration::from_secs(1);
        while host
            .windows
            .lock()
            .unwrap()
            .status(now().unwrap())
            .unwrap()
            .state
            != "closed"
        {
            assert!(Instant::now() < deadline);
            thread::sleep(Duration::from_millis(1));
        }
        assert!(host.policy_mutation.try_lock().is_err());
        let revoker = thread::spawn(move || {
            let reply = host
                .execute(Command::PairingRevoke {
                    phone_id: "phone-a".into(),
                })
                .unwrap();
            assert_eq!(reply["phones"][0]["active"], false);
            assert_eq!(reply["pairing"]["state"], "closed");
            assert_eq!(reply["transport"]["listening"], true);
            host
        });
        // Revocation closes native TLS peers before waiting for the database transaction.
        assert!(channel.receive().is_err());
        drop(guard);
        let mut host = revoker.join().unwrap();
        assert_eq!(
            host.execute(Command::PairingList {}).unwrap()["phones"][0]["active"],
            false
        );
        drop(host);
        drop(store);
        let mut restarted = Host::new(&runtime, "authority-b", Some(&identity)).unwrap();
        let inventory = restarted.execute(Command::PairingList {}).unwrap();
        assert_eq!(inventory["phones"][0]["phoneId"], "phone-a");
        assert_eq!(inventory["phones"][0]["active"], false);
        assert!(!inventory.to_string().contains("credential\""));
    }
    fn enrolled(host: &mut Host) -> (Value, Value) {
        let value = listen(host);
        let mut channel = connect(&value);
        hello(&mut channel);
        send(&mut channel, proof(&value));
        let credential = receive(&mut channel);
        send(
            &mut channel,
            json!({"version":1,"command":"enrollment-stored","phoneId":"phone-a","credentialEpoch":credential["credentialEpoch"]}),
        );
        assert_eq!(receive(&mut channel)["command"], "enrollment-complete");
        (value, credential)
    }
    fn authentication(channel: &mut ControlChannel, credential: &Value) {
        send(
            channel,
            json!({"version":1,"command":"hello","controlVersion":3,"inputVersion":1,"documentVersion":1,"capabilitiesVersion":1}),
        );
        assert_eq!(receive(channel)["controlVersion"], 3);
        send(
            channel,
            json!({"version":1,"command":"authenticate","authorityInstanceId":"authority-a","phoneId":"phone-a","credentialEpoch":credential["credentialEpoch"],"credential":credential["credential"]}),
        );
    }
    #[test]
    fn authenticated_native_control_rechecks_trust_and_never_enables_input() {
        let root = Root::new();
        let mut host = Host::new(
            &root.0.join("runtime"),
            "authority-a",
            Some(&root.0.join("identity")),
        )
        .unwrap();
        let (value, credential) = enrolled(&mut host);
        let mut channel = connect(&value);
        authentication(&mut channel, &credential);
        let receipt = receive(&mut channel);
        assert_eq!(receipt["command"], "authenticated");
        assert_eq!(receipt["inputEnabled"], false);
        assert_eq!(receipt["inputSessionAvailable"], false);
        assert!(!receipt
            .to_string()
            .contains(credential["credential"].as_str().unwrap()));
        assert_eq!(receipt["connectionId"].as_str().unwrap().len(), 32);
        assert!(receipt["expiresAt"].as_u64().unwrap() <= now().unwrap() + 60_000);
        assert!(host.policy_mutation.try_lock().is_ok());
        assert!(host.store.as_ref().unwrap().try_lock().is_ok());
        send(
            &mut channel,
            json!({"version":1,"command":"control-status","connectionId":receipt["connectionId"]}),
        );
        assert_eq!(receive(&mut channel)["command"], "control-status");
        host.execute(Command::PairingRevoke {
            phone_id: "phone-a".into(),
        })
        .unwrap();
        assert!(channel.receive().is_err());
        let mut rejected = connect(&value);
        authentication(&mut rejected, &credential);
        assert!(rejected.receive().is_err());
    }
    #[test]
    fn connection_identifiers_do_not_transfer_authority_and_reenrollment_retires_old_epoch() {
        let root = Root::new();
        let mut host = Host::new(
            &root.0.join("runtime"),
            "authority-a",
            Some(&root.0.join("identity")),
        )
        .unwrap();
        let (value, old) = enrolled(&mut host);
        let mut one = connect(&value);
        authentication(&mut one, &old);
        let receipt = receive(&mut one);
        let mut two = connect(&value);
        authentication(&mut two, &old);
        let second = receive(&mut two);
        assert_ne!(receipt["connectionId"], second["connectionId"]);
        send(
            &mut two,
            json!({"version":1,"command":"control-status","connectionId":receipt["connectionId"]}),
        );
        assert!(two.receive().is_err());
        send(
            &mut one,
            json!({"version":1,"command":"disconnect","connectionId":receipt["connectionId"]}),
        );
        assert_eq!(receive(&mut one)["command"], "disconnected");
        assert!(one.receive().is_err());
        let (new_value, fresh) = enrolled(&mut host);
        assert_ne!(old["credentialEpoch"], fresh["credentialEpoch"]);
        for credential in [
            old.clone(),
            json!({"credential":fresh["credential"],"credentialEpoch":old["credentialEpoch"]}),
        ] {
            let mut rejected = connect(&new_value);
            authentication(&mut rejected, &credential);
            assert!(rejected.receive().is_err());
        }
        let mut valid = connect(&new_value);
        authentication(&mut valid, &fresh);
        let valid_receipt = receive(&mut valid);
        assert_eq!(valid_receipt["command"], "authenticated");
        // Direct native policy changes are still rechecked on every authorized operation.
        host.store
            .as_ref()
            .unwrap()
            .lock()
            .unwrap()
            .revoke("phone-a", now().unwrap())
            .unwrap();
        send(
            &mut valid,
            json!({"version":1,"command":"control-status","connectionId":valid_receipt["connectionId"]}),
        );
        assert!(valid.receive().is_err());
    }
    #[test]
    fn authenticated_connections_bound_work_and_reject_unimplemented_input_grants() {
        let root = Root::new();
        let mut host = Host::new(
            &root.0.join("runtime"),
            "authority-a",
            Some(&root.0.join("identity")),
        )
        .unwrap();
        let (value, credential) = enrolled(&mut host);
        let mut channel = connect(&value);
        authentication(&mut channel, &credential);
        let receipt = receive(&mut channel);
        for _ in 0..128 {
            send(
                &mut channel,
                json!({"version":1,"command":"control-status","connectionId":receipt["connectionId"]}),
            );
            assert_eq!(receive(&mut channel)["command"], "control-status");
        }
        assert!(channel.receive().is_err());
        let mut denied = connect(&value);
        authentication(&mut denied, &credential);
        let receipt = receive(&mut denied);
        send(
            &mut denied,
            json!({"version":1,"command":"input-grant","connectionId":receipt["connectionId"]}),
        );
        assert!(denied.receive().is_err());
    }
    #[test]
    fn bounded_acceptance_and_stop_close_all_stalled_sockets_without_more_workers() {
        let root = Root::new();
        let mut host = Host::new(
            &root.0.join("runtime"),
            "authority-a",
            Some(&root.0.join("identity")),
        )
        .unwrap();
        let value = listen(&mut host);
        let address = format!("127.0.0.1:{}", value["transport"]["port"]);
        let sockets = (0..20)
            .filter_map(|_| TcpStream::connect(&address).ok())
            .collect::<Vec<_>>();
        thread::sleep(Duration::from_millis(50));
        assert!(host.listener.as_ref().unwrap().peers.lock().unwrap().len() <= 8);
        host.execute(Command::PairingStopListening {}).unwrap();
        assert!(TcpStream::connect(&address).is_err());
        for mut socket in sockets {
            // Some platforms reject socket-option changes after peer reset. Observe closure itself.
            let (closed, result) = mpsc::sync_channel(1);
            thread::spawn(move || {
                let _ = closed.send(std::io::Read::read(&mut socket, &mut [0]));
            });
            match result
                .recv_timeout(Duration::from_millis(500))
                .expect("stopped listener must close every peer")
            {
                Ok(0) => {}
                Err(error)
                    if !matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                _ => panic!("stopped listener left a live peer socket"),
            };
        }
    }
    #[test]
    fn retired_window_cannot_be_serialized_as_a_fresh_offer() {
        let root = Root::new();
        let host = Host::new(&root.0.join("runtime"), "authority-a", None).unwrap();
        let offer = host.windows.lock().unwrap().open(now().unwrap()).unwrap();
        host.windows.lock().unwrap().cancel();
        assert_eq!(host.reply(Some(offer)).err(), Some("pairing_closed"));
        assert!(host.reply(None).unwrap()["offer"].is_null());
    }
}
