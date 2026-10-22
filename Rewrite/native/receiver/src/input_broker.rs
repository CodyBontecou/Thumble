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
    authorization: Option<crate::cached_authorization::CachedAuthorization>,
    root: PathBuf,
    phone: String,
    client: Arc<Mutex<Client>>,
    sources: Arc<Mutex<Sources>>,
}
pub(crate) struct ControlInput<'a> {
    pub root: &'a Path,
    pub registry: &'a Registry,
    pub datagram_port: Option<u16>,
    pub renewal: bool,
    pub physical: bool,
}
pub(crate) struct DatagramPolicy {
    pub epoch: String,
    pub authorization: crate::cached_authorization::CachedAuthorization,
    pub expires: u64,
    pub observed: u64,
}
struct Progress {
    last: Option<u64>,
    accepted: u32,
}
struct Source {
    reference: GrantRef,
    generation: u64,
    revision: u64,
    policy: Option<DatagramPolicy>,
    deadline: Instant,
    progress: Progress,
}
struct Staged {
    source: Source,
    commit_deadline: Instant,
}
struct Sources {
    current: Source,
    staged: Option<Staged>,
    closed: bool,
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
impl Source {
    fn new(grant: &NativeGrant, started: Instant, policy: Option<DatagramPolicy>) -> Self {
        Self {
            reference: grant.binding(),
            generation: grant.generation(),
            revision: grant.revision(),
            policy,
            deadline: started + Duration::from_millis(u64::from(grant.lifetime_ms())),
            progress: Progress {
                last: None,
                accepted: 0,
            },
        }
    }
    fn live(&self, now: u64) -> bool {
        Instant::now() < self.deadline
            && self
                .policy
                .as_ref()
                .is_none_or(|p| now >= p.observed && now < p.expires)
    }
    fn forward(
        &mut self,
        client: &Mutex<Client>,
        packet: &[u8],
        now: u64,
    ) -> Result<(), &'static str> {
        let (session, generation, sequence) = packet_scope(packet).ok_or("input_packet_invalid")?;
        if session != self.reference.session() || generation != self.generation || !self.live(now) {
            return Err("input_session_closed");
        }
        if self.policy.is_some() && self.progress.last.is_some_and(|last| sequence <= last) {
            return Ok(());
        }
        if self.progress.accepted >= 65_536 {
            return Err("input_packet_budget_exhausted");
        }
        client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .packet(self.reference, packet)?;
        self.progress.last = Some(sequence);
        self.progress.accepted += 1;
        Ok(())
    }
}
impl Sources {
    fn forward(
        &mut self,
        client: &Mutex<Client>,
        packet: &[u8],
        reliable: bool,
        now: u64,
    ) -> Result<(), &'static str> {
        if self.closed {
            return Err("input_session_closed");
        }
        let (session, _, sequence) = packet_scope(packet).ok_or("input_packet_invalid")?;
        if self
            .staged
            .as_ref()
            .is_some_and(|s| s.source.reference.session() == session)
        {
            if !self.current.live(now) {
                return Err("input_session_closed");
            }
            let staged = self.staged.as_mut().ok_or("input_session_closed")?;
            if !reliable || sequence != 0 || Instant::now() >= staged.commit_deadline {
                return Err("input_session_closed");
            }
            staged.source.forward(client, packet, now)?;
            self.current = self.staged.take().ok_or("input_session_closed")?.source;
            return Ok(());
        }
        self.current.forward(client, packet, now)
    }
}
pub(crate) struct DatagramStatus {
    pub active: bool,
    pub generation: u64,
    pub revision: u64,
    pub last: Option<u64>,
    pub input_enabled: bool,
}
fn retire(client: &Mutex<Client>, root: &Path, reference: GrantRef) -> Result<(), &'static str> {
    let mut client = client.lock().map_err(|_| "input_broker_unavailable")?;
    if client.release(reference).is_ok() {
        return Ok(());
    }
    let physical = client.physical_output();
    client.close();
    let mut replacement = Client::connect(root)?;
    if physical {
        replacement.require_physical_output()?;
    }
    replacement.release(reference)?;
    *client = replacement;
    Ok(())
}
fn retire_sources(entry: &Entry) -> Result<(), &'static str> {
    let mut sources = entry
        .sources
        .lock()
        .map_err(|_| "input_broker_unavailable")?;
    if sources.closed {
        return Ok(());
    }
    // A lost packet ACK may leave the receiver on either key. Retire both references.
    let references = [
        Some(sources.current.reference),
        sources.staged.as_ref().map(|s| s.source.reference),
    ];
    let mut failed = false;
    for reference in references.into_iter().flatten() {
        if retire(&entry.client, &entry.root, reference).is_err() {
            failed = true;
        }
    }
    if failed {
        return Err("native_input_release_unconfirmed");
    }
    sources.closed = true;
    sources.staged = None;
    Ok(())
}
#[derive(Default)]
pub(crate) struct Registry {
    entries: Mutex<BTreeMap<[u8; 16], Entry>>,
}
impl Registry {
    fn remember(&self, connection: [u8; 16], entry: Entry) -> Result<(), &'static str> {
        let mut entries = self
            .entries
            .lock()
            .map_err(|_| "input_broker_unavailable")?;
        if entries.len() >= 4 && !entries.contains_key(&connection) {
            return Err("input_broker_capacity");
        }
        entries.insert(connection, entry);
        Ok(())
    }
    fn forget(&self, connection: [u8; 16], sources: &Arc<Mutex<Sources>>) {
        if let Ok(mut entries) = self.entries.lock() {
            if entries
                .get(&connection)
                .is_some_and(|e| Arc::ptr_eq(&e.sources, sources))
            {
                entries.remove(&connection);
            }
        }
    }
    pub(crate) fn datagram_session(&self, packet: &[u8]) -> Option<[u8; 16]> {
        let (session, generation, _) = packet_scope(packet)?;
        self.entries
            .lock()
            .ok()?
            .values()
            .any(|e| {
                e.sources.try_lock().ok().is_some_and(|s| {
                    !s.closed
                        && s.current.reference.session() == session
                        && s.current.generation == generation
                        && s.current.policy.is_some()
                })
            })
            .then_some(session)
    }
    pub(crate) fn datagram_packet(
        &self,
        packet: &[u8],
        now: &mut impl FnMut() -> Result<u64, &'static str>,
    ) -> Result<(), &'static str> {
        let (session, generation, _) = packet_scope(packet).ok_or("input_packet_invalid")?;
        let entries = self
            .entries
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .values()
            .cloned()
            .collect::<Vec<_>>();
        for entry in entries {
            let Some(authorization) = entry.authorization.as_ref() else {
                continue;
            };
            let _scope = authorization.guard()?;
            let time = authorization.clock.sample(now)?;
            let mut sources = entry.sources.try_lock().map_err(|_| "input_broker_busy")?;
            if sources.closed || sources.current.reference.session() != session {
                continue;
            }
            let source = &sources.current;
            let policy = source.policy.as_ref().ok_or("input_session_closed")?;
            if generation != source.generation
                || time < policy.observed
                || time >= policy.expires
                || Instant::now() >= source.deadline
            {
                return Err("input_session_closed");
            }
            return sources.forward(&entry.client, packet, false, time);
        }
        Err("input_session_closed")
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
    /// Caller holds the trust mutation gate. One entry continuously covers both sides of a handoff.
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
                .filter_map(|id| entries.remove(&id).map(|e| (id, e)))
                .collect::<Vec<_>>()
        };
        let mut failed = false;
        for (id, entry) in retired {
            if retire_sources(&entry).is_err() {
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
    entry: Option<Entry>,
    datagram_port: Option<u16>,
    pub(crate) renewal: bool,
    pub(crate) physical: bool,
}
impl<'a> Broker<'a> {
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
            entry: None,
            datagram_port,
            renewal: false,
            physical: false,
        })
    }
    pub(crate) fn require_physical_output(&mut self) -> Result<(), &'static str> {
        self.client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .require_physical_output()?;
        self.physical = true;
        Ok(())
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
        let entry = Entry {
            authorization: policy.as_ref().map(|p| p.authorization.clone()),
            root: self.root.clone(),
            phone: phone.into(),
            client: self.client.clone(),
            sources: Arc::new(Mutex::new(Sources {
                current: Source::new(&grant, started, policy),
                staged: None,
                closed: false,
            })),
        };
        self.entry = Some(entry.clone());
        self.registry.remember(self.connection, entry)?;
        Ok(grant)
    }
    pub(crate) fn rotate(
        &mut self,
        session: &str,
        generation: u64,
        revision: u64,
        lifetime: u32,
        policy: DatagramPolicy,
    ) -> Result<NativeGrant, &'static str> {
        if self.datagram_port.is_none() {
            return Err("input_protocol_invalid");
        }
        let entry = self.entry.as_ref().ok_or("input_session_closed")?;
        let mut sources = entry
            .sources
            .lock()
            .map_err(|_| "input_broker_unavailable")?;
        if sources.closed
            || sources.staged.is_some()
            || crate::gamepad::hex(&sources.current.reference.session()) != session
            || sources.current.generation != generation
            || sources.current.revision != revision
            || sources.current.progress.last.is_none()
            || Instant::now() >= sources.current.deadline
        {
            return Err("input_session_closed");
        }
        let old_policy = sources
            .current
            .policy
            .as_ref()
            .ok_or("input_protocol_invalid")?;
        if old_policy.epoch != policy.epoch
            || policy.observed < old_policy.observed
            || policy.observed >= old_policy.expires
            || policy.expires < old_policy.expires
        {
            return Err("input_session_closed");
        }
        let started = Instant::now();
        let grant = self
            .client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .rotate(sources.current.reference, generation, revision, lifetime)?;
        sources.staged = Some(Staged {
            source: Source::new(&grant, started, Some(policy)),
            commit_deadline: started + Duration::from_millis(u64::from(lifetime).min(2000)),
        });
        Ok(grant)
    }
    pub(crate) fn packet(&mut self, packet: &[u8], now: u64) -> Result<(), &'static str> {
        let entry = self.entry.as_ref().ok_or("input_session_closed")?;
        entry
            .sources
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .forward(&self.client, packet, true, now)
    }
    pub(crate) fn datagram_port(&self) -> Option<u16> {
        self.datagram_port
    }
    pub(crate) fn datagram_status(
        &mut self,
        session: &str,
        now: u64,
    ) -> Result<DatagramStatus, &'static str> {
        let entry = self.entry.as_ref().ok_or("input_session_closed")?;
        let sources = entry
            .sources
            .lock()
            .map_err(|_| "input_broker_unavailable")?;
        if sources.closed {
            return Err("input_session_closed");
        }
        let (source, commit_live) =
            if crate::gamepad::hex(&sources.current.reference.session()) == session {
                (&sources.current, true)
            } else if let Some(staged) = sources
                .staged
                .as_ref()
                .filter(|s| crate::gamepad::hex(&s.source.reference.session()) == session)
            {
                (&staged.source, Instant::now() < staged.commit_deadline)
            } else {
                return Err("input_session_closed");
            };
        if source.policy.is_none() {
            return Err("input_protocol_invalid");
        }
        let configuration = self
            .client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .configuration()?;
        Ok(DatagramStatus {
            active: commit_live
                && configuration.active
                && configuration.generation == source.generation
                && configuration.revision == source.revision
                && source.live(now),
            generation: source.generation,
            revision: source.revision,
            last: source.progress.last,
            input_enabled: configuration.input_enabled
                && commit_live
                && configuration.active
                && configuration.generation == source.generation
                && configuration.revision == source.revision
                && source.live(now),
        })
    }
    pub(crate) fn release_scope(&mut self, session: &str) -> Result<(), &'static str> {
        let Some(entry) = self.entry.as_ref() else {
            return Ok(());
        };
        let mut sources = entry
            .sources
            .lock()
            .map_err(|_| "input_broker_unavailable")?;
        if crate::gamepad::hex(&sources.current.reference.session()) == session {
            drop(sources);
            return self.release();
        }
        if sources
            .staged
            .as_ref()
            .is_some_and(|s| crate::gamepad::hex(&s.source.reference.session()) == session)
        {
            let reference = sources
                .staged
                .as_ref()
                .ok_or("input_session_closed")?
                .source
                .reference;
            retire(&self.client, &self.root, reference)?;
            sources.staged = None;
        }
        Ok(())
    }
    pub(crate) fn release(&mut self) -> Result<(), &'static str> {
        if let Some(entry) = self.entry.as_ref() {
            retire_sources(entry)?;
            self.registry.forget(self.connection, &entry.sources);
            self.entry = None;
        }
        Ok(())
    }
}
impl Drop for Broker<'_> {
    fn drop(&mut self) {
        let _ = self.release();
    }
}
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
