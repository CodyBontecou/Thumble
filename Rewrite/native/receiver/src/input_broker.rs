//! Native-only authenticated-control handoff. Registry entries never enter service stdio.
use crate::{
    control_tls::ControlChannel,
    native_ingress::{Client, Configuration, GrantRef, NativeGrant},
};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};
struct Entry {
    root: PathBuf,
    phone: String,
    reference: GrantRef,
    client: Arc<Mutex<Client>>,
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
}
impl<'a> Broker<'a> {
    /// Handshake outside the trust gate; revalidate authorization under that gate before any grant.
    pub(crate) fn connect(
        root: &Path,
        registry: &'a Registry,
        connection: [u8; 16],
    ) -> Result<Self, &'static str> {
        Ok(Self {
            root: root.into(),
            client: Arc::new(Mutex::new(Client::connect(root)?)),
            registry,
            connection,
            reference: None,
            session: None,
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
    ) -> Result<NativeGrant, &'static str> {
        let grant = self
            .client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .grant(self.connection, generation, revision, lifetime)?;
        self.reference = Some(grant.binding());
        self.session = Some(grant.session_id());
        self.registry.remember(
            self.connection,
            phone,
            &self.root,
            grant.binding(),
            self.client.clone(),
        )?;
        Ok(grant)
    }
    pub(crate) fn packet(&mut self, packet: &[u8]) -> Result<(), &'static str> {
        self.client
            .lock()
            .map_err(|_| "input_broker_unavailable")?
            .packet(self.reference.ok_or("input_session_closed")?, packet)
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
) -> Result<(), &'static str> {
    grant.send_to(channel)
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
            let mut broker = Broker::connect(&root.0, &registry, [7; 16]).unwrap();
            broker.grant("phone-a", 1, 1, 1000).unwrap();
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
