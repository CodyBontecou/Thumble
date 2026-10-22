//! Native-only authenticated-control handoff. Registry entries never enter service stdio.
use crate::{
    control_tls::ControlChannel,
    native_ingress::{Client, Configuration, GrantRef, NativeGrant},
};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
#[derive(Clone)]
struct Entry {
    root: PathBuf,
    phone: String,
    reference: GrantRef,
    client: Arc<Mutex<Client>>,
    datagram: Option<Arc<DatagramState>>,
}
pub(crate) struct ControlInput<'a> {
    pub root: &'a Path,
    pub registry: &'a Registry,
    pub datagram_port: Option<u16>,
}
pub(crate) struct DatagramPolicy {
    pub epoch: String,
    pub expires: u64,
    pub observed: u64,
}
struct Progress {
    last: Option<u64>,
    accepted: u32,
}
struct DatagramState {
    generation: u64,
    revision: u64,
    policy: DatagramPolicy,
    deadline: Instant,
    progress: Mutex<Progress>,
}
fn packet_scope(packet: &[u8]) -> Option<([u8; 16], u64, u64)> {
    if packet.len() != crate::input_packet::PACKET_BYTES || &packet[..8] != b"THI1\0\0\0\0" {
        return None;
    }
    let session = packet[8..24].try_into().ok()?;
    let generation = u64::from_le_bytes(packet[24..32].try_into().ok()?);
    let sequence = u64::from_le_bytes(packet[32..40].try_into().ok()?);
    (generation > 0 && sequence < crate::input_packet::PACKET_LIMIT)
        .then_some((session, generation, sequence))
}
impl DatagramState {
    /// Caller holds the trust mutation fence. Only receiver-acknowledged AEAD input advances progress.
    fn forward(
        &self,
        client: &Mutex<Client>,
        reference: GrantRef,
        packet: &[u8],
    ) -> Result<(), &'static str> {
        let (session, generation, sequence) = packet_scope(packet).ok_or("input_packet_invalid")?;
        if session != reference.session()
            || generation != self.generation
            || Instant::now() >= self.deadline
        {
            return Err("input_session_closed");
        }
        let mut progress = self
            .progress
            .lock()
            .map_err(|_| "input_broker_unavailable")?;
        // Stale snapshots have no side effects. In-flight UDP/TLS overlap cannot reset or renew input.
        if progress.last.is_some_and(|last| sequence <= last) {
            return Ok(());
        }
        if progress.accepted >= 65_536 {
            return Err("input_packet_budget_exhausted");
        }
        client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .packet(reference, packet)?;
        progress.last = Some(sequence);
        progress.accepted += 1;
        Ok(())
    }
}
pub(crate) struct DatagramStatus {
    pub active: bool,
    pub generation: u64,
    pub revision: u64,
    pub last: Option<u64>,
}
fn retire(client: &Mutex<Client>, root: &Path, reference: GrantRef) -> Result<(), &'static str> {
    let mut client = client.lock().map_err(|_| "input_broker_unavailable")?;
    if client.release(reference).is_ok() {
        return Ok(());
    }
    client.close();
    let mut replacement = Client::connect(root)?;
    replacement.release(reference)?;
    *client = replacement;
    Ok(())
}
#[derive(Default)]
pub(crate) struct Registry {
    entries: Mutex<BTreeMap<[u8; 16], Entry>>,
}
impl Registry {
    fn remember(
        &self,
        connection: [u8; 16],
        phone: &str,
        root: &Path,
        reference: GrantRef,
        client: Arc<Mutex<Client>>,
        datagram: Option<Arc<DatagramState>>,
    ) -> Result<(), &'static str> {
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| "input_broker_unavailable")?;
        if entries.len() >= 4 && !entries.contains_key(&connection) {
            return Err("input_broker_capacity");
        }
        entries.insert(
            connection,
            Entry {
                root: root.into(),
                phone: phone.into(),
                reference,
                client,
                datagram,
            },
        );
        Ok(())
    }
    fn forget(&self, connection: [u8; 16], reference: GrantRef) {
        if let Ok(mut entries) = self.entries.lock() {
            if entries
                .get(&connection)
                .is_some_and(|e| e.reference == reference)
            {
                entries.remove(&connection);
            }
        }
    }
    /// Public header is only a routing hint; decryption remains in the independent receiver.
    pub(crate) fn datagram_session(&self, packet: &[u8]) -> Option<[u8; 16]> {
        let (session, generation, _) = packet_scope(packet)?;
        self.entries
            .lock()
            .ok()?
            .values()
            .any(|e| {
                e.reference.session() == session
                    && e.datagram
                        .as_ref()
                        .is_some_and(|s| s.generation == generation)
            })
            .then_some(session)
    }
    pub(crate) fn datagram_packet(
        &self,
        packet: &[u8],
        store: &Mutex<crate::phone_trust::PhoneTrustStore>,
        mutation: &Mutex<()>,
        now: u64,
    ) -> Result<(), &'static str> {
        let (session, generation, _) = packet_scope(packet).ok_or("input_packet_invalid")?;
        // Datagram traffic drops under contention instead of blocking configuration/revocation.
        let _gate = mutation.try_lock().map_err(|_| "input_broker_busy")?;
        let entry = self
            .entries
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .values()
            .find(|e| e.reference.session() == session)
            .cloned()
            .ok_or("input_session_closed")?;
        let state = entry.datagram.as_ref().ok_or("input_session_closed")?;
        if generation != state.generation
            || now < state.policy.observed
            || now >= state.policy.expires
            || Instant::now() >= state.deadline
        {
            return Err("input_session_closed");
        }
        store
            .lock()
            .map_err(|_| "phone_trust_owner_unavailable")?
            .authorize_epoch(&entry.phone, &state.policy.epoch, now)?;
        state.forward(&entry.client, entry.reference, packet)
    }
    pub(crate) fn retire_all(&self) -> Result<(), &'static str> {
        let phones = self
            .entries
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .values()
            .map(|e| e.phone.clone())
            .collect::<std::collections::BTreeSet<_>>();
        let mut failed = false;
        for phone in phones {
            if self.retire_phone(&phone).is_err() {
                failed = true;
            }
        }
        if failed {
            Err("native_input_release_unconfirmed")
        } else {
            Ok(())
        }
    }
    /// Caller holds the shared trust mutation gate; all grants have been committed before registration.
    pub(crate) fn retire_phone(&self, phone: &str) -> Result<(), &'static str> {
        let retired = {
            let mut entries = self
                .entries
                .lock()
                .map_err(|_| "input_broker_unavailable")?;
            let keys = entries
                .iter()
                .filter(|(_, e)| e.phone == phone)
                .map(|(id, _)| *id)
                .collect::<Vec<_>>();
            keys.into_iter()
                .filter_map(|id| entries.remove(&id).map(|entry| (id, entry)))
                .collect::<Vec<_>>()
        };
        let mut failed = false;
        for (id, entry) in retired {
            if retire(&entry.client, &entry.root, entry.reference).is_err() {
                failed = true;
                if let Ok(mut entries) = self.entries.lock() {
                    entries.entry(id).or_insert(entry);
                }
            }
        }
        if failed {
            Err("native_input_release_unconfirmed")
        } else {
            Ok(())
        }
    }
}
pub(crate) struct Broker<'a> {
    root: PathBuf,
    client: Arc<Mutex<Client>>,
    registry: &'a Registry,
    connection: [u8; 16],
    reference: Option<GrantRef>,
    session: Option<String>,
    datagram_port: Option<u16>,
    datagram: Option<Arc<DatagramState>>,
}
impl<'a> Broker<'a> {
    /// Handshake outside the trust gate; revalidate authorization under that gate before any grant.
    pub(crate) fn connect(
        root: &Path,
        registry: &'a Registry,
        connection: [u8; 16],
        datagram_port: Option<u16>,
    ) -> Result<Self, &'static str> {
        Ok(Self {
            root: root.into(),
            client: Arc::new(Mutex::new(Client::connect(root)?)),
            registry,
            connection,
            reference: None,
            session: None,
            datagram_port,
            datagram: None,
        })
    }
    pub(crate) fn configuration(&mut self) -> Result<Configuration, &'static str> {
        self.client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .configuration()
    }
    pub(crate) fn grant(
        &mut self,
        phone: &str,
        generation: u64,
        revision: u64,
        lifetime: u32,
        policy: Option<DatagramPolicy>,
    ) -> Result<NativeGrant, &'static str> {
        if policy.is_some() != self.datagram_port.is_some() {
            return Err("input_protocol_invalid");
        }
        let started = Instant::now();
        let grant = self
            .client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .grant(self.connection, generation, revision, lifetime)?;
        self.datagram = policy.map(|policy| {
            Arc::new(DatagramState {
                generation,
                revision,
                policy,
                deadline: started + Duration::from_millis(u64::from(lifetime)),
                progress: Mutex::new(Progress {
                    last: None,
                    accepted: 0,
                }),
            })
        });
        self.reference = Some(grant.binding());
        self.session = Some(grant.session_id());
        self.registry.remember(
            self.connection,
            phone,
            &self.root,
            grant.binding(),
            self.client.clone(),
            self.datagram.clone(),
        )?;
        Ok(grant)
    }
    pub(crate) fn packet(&mut self, packet: &[u8]) -> Result<(), &'static str> {
        if let Some(state) = &self.datagram {
            return state.forward(
                &self.client,
                self.reference.ok_or("input_session_closed")?,
                packet,
            );
        }
        self.client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .packet(self.reference.ok_or("input_session_closed")?, packet)
    }
    pub(crate) fn datagram_port(&self) -> Option<u16> {
        self.datagram_port
    }
    pub(crate) fn datagram_status(
        &mut self,
        session: &str,
    ) -> Result<DatagramStatus, &'static str> {
        if self.session.as_deref() != Some(session) {
            return Err("input_session_closed");
        }
        let state = self
            .datagram
            .as_ref()
            .ok_or("input_protocol_invalid")?
            .clone();
        let configuration = self.configuration()?;
        let last = state
            .progress
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .last;
        Ok(DatagramStatus {
            active: configuration.active
                && configuration.generation == state.generation
                && configuration.revision == state.revision
                && Instant::now() < state.deadline,
            generation: state.generation,
            revision: state.revision,
            last,
        })
    }
    pub(crate) fn release_scope(&mut self, session: &str) -> Result<(), &'static str> {
        if self.session.as_deref() == Some(session) {
            self.release()?;
        }
        Ok(())
    }
    pub(crate) fn release(&mut self) -> Result<(), &'static str> {
        if let Some(reference) = self.reference {
            // Retain discoverability until the receiver has acknowledged neutrality.
            // Revocation racing this cleanup must wait on the same native client, never see an empty registry early.
            retire(&self.client, &self.root, reference)?;
            self.registry.forget(self.connection, reference);
            self.reference = None;
            self.session = None;
            self.datagram = None;
        }
        Ok(())
    }
}
impl Drop for Broker<'_> {
    fn drop(&mut self) {
        let _ = self.release();
    }
}
/// Secret delivery additionally requires the exact authenticated native server channel.
pub(crate) fn deliver(
    grant: &NativeGrant,
    channel: &mut ControlChannel,
    udp_port: Option<u16>,
) -> Result<(), &'static str> {
    match udp_port {
        Some(port) => grant.send_to_datagram(channel, Some(port)),
        None => grant.send_to(channel),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        native_ingress::Server,
        packet_runtime::PacketRuntime,
        runtime::{Command, Output},
        security,
    };
    use std::{
        fs,
        sync::atomic::{AtomicBool, AtomicU64, Ordering},
        thread,
        time::{Duration, Instant},
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    struct Sink;
    impl Output for Sink {
        fn submit(&mut self, _: [u8; 20], _: &'static str) -> Result<(), &'static str> {
            Ok(())
        }
    }
    struct Stop<'a>(&'a AtomicBool, &'a AtomicBool);
    impl Drop for Stop<'_> {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
            self.1.store(false, Ordering::SeqCst);
        }
    }
    #[test]
    fn disconnect_cleanup_remains_registered_until_receiver_ack_and_concurrent_revocation_waits() {
        let root = Root(std::env::temp_dir().canonicalize().unwrap().join(format!(
            "thumble-broker-retire-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )));
        security::directory(&root.0).unwrap();
        let mut server = Server::bind(&root.0).unwrap();
        let registry = Registry::default();
        let stop = AtomicBool::new(false);
        let pause = AtomicBool::new(false);
        let paused = AtomicBool::new(false);
        thread::scope(|scope| {
            let _stop = Stop(&stop, &pause);
            let owner = scope.spawn(|| {
                let start = Instant::now();
                let mut runtime = PacketRuntime::default();
                let mut sink = Sink;
                runtime
                    .apply_owner(
                        Command::Activate {
                            generation: "1".into(),
                            revision: "1".into(),
                            profile_id: "profile-a".into(),
                            session_id: "owner".into(),
                            lease_ms: 1750,
                            input_ttl_ms: 350,
                        },
                        0,
                        &mut sink,
                    )
                    .unwrap();
                while !stop.load(Ordering::SeqCst) {
                    if pause.load(Ordering::SeqCst) {
                        paused.store(true, Ordering::SeqCst);
                        while pause.load(Ordering::SeqCst) && !stop.load(Ordering::SeqCst) {
                            thread::sleep(Duration::from_millis(1));
                        }
                        paused.store(false, Ordering::SeqCst);
                    }
                    server
                        .drain(&mut runtime, start.elapsed().as_millis() as u64, &mut sink)
                        .unwrap();
                    thread::sleep(Duration::from_millis(1));
                }
            });
            let mut broker = Broker::connect(&root.0, &registry, [7; 16], None).unwrap();
            broker.grant("phone-a", 1, 1, 1000, None).unwrap();
            let client = broker.client.clone();
            pause.store(true, Ordering::SeqCst);
            let deadline = Instant::now() + Duration::from_millis(100);
            while !paused.load(Ordering::SeqCst) {
                assert!(Instant::now() < deadline);
                thread::yield_now();
            }
            let cleanup = scope.spawn(move || broker.release());
            let deadline = Instant::now() + Duration::from_millis(100);
            while client.try_lock().is_ok() {
                assert!(Instant::now() < deadline);
                thread::yield_now();
            }
            assert!(registry.entries.lock().unwrap().contains_key(&[7; 16]));
            let revocation = scope.spawn(|| registry.retire_phone("phone-a"));
            let deadline = Instant::now() + Duration::from_millis(100);
            while !registry.entries.lock().unwrap().is_empty() {
                assert!(Instant::now() < deadline);
                thread::yield_now();
            }
            pause.store(false, Ordering::SeqCst);
            cleanup.join().unwrap().unwrap();
            revocation.join().unwrap().unwrap();
            let mut observer = Client::connect(&root.0).unwrap();
            assert!(!observer.configuration().unwrap().active);
            drop(observer);
            stop.store(true, Ordering::SeqCst);
            owner.join().unwrap();
        });
    }
}
