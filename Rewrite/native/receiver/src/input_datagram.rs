//! One bounded native UDP ingress per explicitly configured control listener. Never replies to UDP.
use crate::{input_broker::Registry, phone_trust::PhoneTrustStore};
use std::{
    collections::BTreeMap,
    net::{IpAddr, SocketAddr, UdpSocket},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
const READ_BUDGET: usize = 64;
const DELIVERY_BUDGET: usize = 240;
pub(crate) struct Listener {
    address: SocketAddr,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Listener {
    pub(crate) fn bind(
        ip: IpAddr,
        registry: Arc<Registry>,
        store: Arc<Mutex<PhoneTrustStore>>,
        mutation: Arc<Mutex<()>>,
    ) -> Result<Self, &'static str> {
        if ip.is_multicast() {
            return Err("input_datagram_address_invalid");
        }
        let socket =
            UdpSocket::bind(SocketAddr::new(ip, 0)).map_err(|_| "input_datagram_bind_failed")?;
        socket
            .set_nonblocking(true)
            .map_err(|_| "input_datagram_bind_failed")?;
        let address = socket
            .local_addr()
            .map_err(|_| "input_datagram_bind_failed")?;
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let worker = thread::spawn(move || {
            let mut window = Instant::now();
            let mut delivered = 0;
            while !stopped.load(Ordering::SeqCst) {
                let mut latest: BTreeMap<[u8; 16], ([u8; 108], u64)> = BTreeMap::new();
                for _ in 0..READ_BUDGET {
                    // An oversized datagram is rejected even when the OS truncates it to this buffer.
                    let mut buffer = [0; 109];
                    let size = match socket.recv_from(&mut buffer) {
                        Ok((size, _)) => size,
                        Err(_) => break,
                    };
                    if size != 108 {
                        continue;
                    }
                    let Some(session) = registry.datagram_session(&buffer[..108]) else {
                        continue;
                    };
                    let sequence =
                        u64::from_le_bytes(buffer[32..40].try_into().expect("fixed header"));
                    if latest.len() < 4 || latest.contains_key(&session) {
                        let slot = latest.entry(session).or_insert(([0; 108], 0));
                        if slot.0 == [0; 108] || sequence > slot.1 {
                            slot.0.copy_from_slice(&buffer[..108]);
                            slot.1 = sequence;
                        }
                    }
                }
                if window.elapsed() >= Duration::from_secs(1) {
                    window = Instant::now();
                    delivered = 0;
                }
                for (packet, _) in latest.into_values() {
                    if stopped.load(Ordering::SeqCst) || delivered >= DELIVERY_BUDGET {
                        break;
                    }
                    delivered += 1;
                    let time = SystemTime::now()
                        .duration_since(UNIX_EPOCH)
                        .ok()
                        .and_then(|d| u64::try_from(d.as_millis()).ok());
                    if let Some(time) = time {
                        let _ = registry.datagram_packet(&packet, &store, &mutation, time);
                    }
                    // Yield between bounded RPCs so configuration/revocation can acquire the fence.
                    thread::sleep(Duration::from_millis(2));
                }
                thread::sleep(Duration::from_millis(3));
            }
        });
        Ok(Self {
            address,
            stop,
            thread: Some(worker),
        })
    }
    pub(crate) fn port(&self) -> u16 {
        self.address.port()
    }
}
impl Drop for Listener {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(worker) = self.thread.take() {
            let _ = worker.join();
        }
    }
}
