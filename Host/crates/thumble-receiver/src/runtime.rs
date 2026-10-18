use crate::{input::Input, store::Store};
use futures_util::{SinkExt, StreamExt};
use mdns_sd::{ServiceDaemon, ServiceInfo};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{HashMap, VecDeque},
    net::{Ipv4Addr, SocketAddr},
    sync::Arc,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use thumble_core::{ConnectionId, CoreTime, Effect, HostCore, TokenSource};
use thumble_protocol::{ControllerMessage, ControllerWireCodec};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{TcpListener, TcpStream},
    sync::{mpsc, oneshot, watch, OwnedSemaphorePermit, Semaphore},
    task::JoinSet,
};
use tokio_tungstenite::{
    accept_async_with_config,
    tungstenite::{protocol::WebSocketConfig, Message},
};

const HOLD_AGE: i64 = 1750;
const FRAME_LIMIT: usize = 8 * 1024 * 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(5);

struct Tokens;
impl TokenSource for Tokens {
    fn next_pairing_code(&mut self) -> String {
        format!("{:06}", rand::rng().random_range(0..1_000_000u32))
    }
    fn next_auth_token(&mut self) -> String {
        format!(
            "{}{}",
            uuid::Uuid::new_v4().simple(),
            uuid::Uuid::new_v4().simple()
        )
    }
}

#[derive(Serialize, Deserialize)]
struct ControlEndpoint {
    port: u16,
    token: String,
}
#[derive(Deserialize, Serialize)]
struct ControlRequest {
    token: String,
    command: String,
}

enum Command {
    Connect(ConnectionId, mpsc::Sender<Message>),
    Message(ConnectionId, Box<ControllerMessage>, OwnedSemaphorePermit),
    Disconnect(ConnectionId),
    Control(String, oneshot::Sender<Value>),
    Tick,
    Shutdown,
}

struct Receiver {
    core: HostCore,
    input: Input,
    store: Store,
    peers: HashMap<ConnectionId, mpsc::Sender<Message>>,
    clock: Clock,
    last_poll: i64,
    neutralizing: bool,
    input_enabled: bool,
    port: u16,
    shutdown: watch::Sender<bool>,
    last_error: Option<String>,
}

impl Receiver {
    fn retire(&mut self) {
        let ids = self.peers.keys().copied().collect::<Vec<_>>();
        for id in ids {
            self.peers.remove(&id);
            let effects = self.core.disconnect(id);
            // Retire transport first. Attempt every output release even if one
            // backend event fails; pending physical releases remain tracked.
            for effect in effects {
                let _ = self.input.execute(&effect);
            }
        }
        let effects = self.core.release_all_locally();
        for effect in effects {
            let _ = self.input.execute(&effect);
        }
        self.neutralizing = self.input.release_all().is_err();
    }
    fn safety_tick(&mut self) -> Result<(), String> {
        let now = self.clock.millis();
        if now.saturating_sub(self.last_poll) > HOLD_AGE {
            self.retire();
        }
        self.last_poll = now;
        if self.neutralizing {
            self.neutralizing = self.input.release_all().is_err();
        }
        let effects = self.core.expire_holds(now, HOLD_AGE);
        self.effects(effects)
    }
    fn effects(&mut self, effects: Vec<Effect>) -> Result<(), String> {
        let mut effects = VecDeque::from(effects);
        while let Some(effect) = effects.pop_front() {
            match effect {
                Effect::PersistState => {
                    if let Err(error) = self.store.save(self.core.persistent_state()) {
                        let _ = self.shutdown.send(true);
                        return Err(error);
                    }
                }
                Effect::SendMessage {
                    connection_id,
                    mut message,
                } => {
                    message.virtual_gamepad_status = Some(Box::new(gamepad_status()));
                    let bytes = ControllerWireCodec::encode(&message).map_err(|e| e.to_string())?;
                    if self
                        .peers
                        .get(&connection_id)
                        .is_some_and(|peer| peer.try_send(Message::Binary(bytes.into())).is_err())
                    {
                        self.peers.remove(&connection_id);
                        effects.extend(self.core.disconnect(connection_id));
                    }
                }
                Effect::CloseConnection { connection_id, .. } => {
                    self.peers.remove(&connection_id);
                    effects.extend(self.core.disconnect(connection_id));
                }
                // Diagnostics can contain remote-provided names. Never write
                // protocol payloads, auth tokens, or raw decode errors to logs.
                Effect::Diagnostic { .. } | Effect::StatusChanged(_) => (),
                effect => self.input.execute(&effect)?,
            }
        }
        Ok(())
    }
    fn command(&mut self, command: Command) -> Result<bool, String> {
        if matches!(command, Command::Shutdown) {
            return Ok(false);
        }
        self.safety_tick()?;
        match command {
            Command::Connect(id, peer) => {
                self.peers.insert(id, peer);
            }
            Command::Message(id, message, _budget) => {
                if self.peers.contains_key(&id) && !self.neutralizing {
                    let effects = self
                        .core
                        .handle_message_at(
                            id,
                            *message,
                            CoreTime::new(unix_millis(), self.clock.millis()),
                            &mut Tokens,
                        )
                        .map_err(|_| "Controller message rejected".to_owned())?;
                    self.effects(effects)?;
                }
            }
            Command::Disconnect(id) => {
                self.peers.remove(&id);
                let effects = self.core.disconnect(id);
                self.effects(effects)?;
            }
            Command::Control(name, reply) => {
                let response = match name.as_str() {
                    "status" => {
                        json!({"ok":true,"platform":std::env::consts::OS,"port":self.port,"urls":urls(self.port),"inputEnabled":self.input_enabled,"neutralizing":self.neutralizing,"lastError":self.last_error,"core":self.core.status(),"virtualGamepadStatus":gamepad_status()})
                    }
                    "pairing-code" => json!({"ok":true,"pairingCode":self.core.pairing_code()}),
                    "release-all" => {
                        self.retire();
                        json!({"ok":!self.neutralizing})
                    }
                    "stop" => json!({"ok":true}),
                    _ => json!({"ok":false,"error":"Unknown local command"}),
                };
                let _ = reply.send(response);
            }
            Command::Tick | Command::Shutdown => (),
        }
        Ok(true)
    }
    fn work(
        mut self,
        mut commands: mpsc::Receiver<Command>,
        mut priority: mpsc::Receiver<Command>,
    ) {
        // Local release/stop must not wait behind an entire phone macro queue.
        // Their sender also posts a normal Tick to wake blocking_recv when idle.
        while let Some(command) = priority
            .try_recv()
            .ok()
            .or_else(|| commands.blocking_recv())
        {
            if *self.shutdown.borrow() {
                break;
            }
            match self.command(command) {
                Ok(true) => (),
                Ok(false) => break,
                Err(error) => {
                    // Fail closed on any delivery/persistence failure. Retire
                    // queued input generations and retry physical releases.
                    self.last_error = Some(error);
                    self.retire();
                }
            }
        }
        self.retire();
        let _ = self.shutdown.send(true);
    }
}

fn gamepad_status() -> Value {
    // Keep the actual payload in a shared fixture decoded by Swift interop tests.
    // New enum cases would make existing iOS clients reject the whole message.
    serde_json::from_str(include_str!("../fixtures/gamepad-status.json"))
        .expect("Valid gamepad status fixture")
}

/// The live descriptor is private and contains only a short-lived local CLI
/// credential. It is never sent to a phone or included in status output.
struct RuntimeFile(Store);
impl Drop for RuntimeFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.0.directory.join("runtime.json"));
    }
}
struct Discovery(ServiceDaemon, String);
impl Drop for Discovery {
    fn drop(&mut self) {
        if let Ok(done) = self.0.unregister(&self.1) {
            let _ = done.recv_timeout(Duration::from_secs(1));
        }
        if let Ok(done) = self.0.shutdown() {
            let _ = done.recv_timeout(Duration::from_secs(1));
        }
    }
}

pub async fn run(
    store: Store,
    port: u16,
    discover: bool,
    input_enabled: bool,
) -> Result<(), String> {
    let _lock = store.lock()?;
    let state = store.load()?;
    let core = HostCore::new_with_tokens(state, &mut Tokens).map_err(|e| e.to_string())?;
    let input = Input::open(input_enabled)?;
    let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, port))
        .await
        .map_err(|e| format!("Bind LAN listener: {e}"))?;
    let port = listener.local_addr().map_err(|e| e.to_string())?.port();
    let cli_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .map_err(|e| e.to_string())?;
    let local_token = Tokens.next_auth_token();
    store.write(
        "runtime.json",
        &ControlEndpoint {
            port: cli_listener.local_addr().map_err(|e| e.to_string())?.port(),
            token: local_token.clone(),
        },
    )?;
    let _runtime_file = RuntimeFile(store.clone());
    let _discovery = if discover {
        let daemon = ServiceDaemon::new().map_err(|e| format!("Start mDNS: {e}"))?;
        daemon
            .disable_interface(mdns_sd::IfKind::IPv6)
            .map_err(|e| e.to_string())?;
        let id = &core.persistent_state().server_id;
        let name = format!(
            "Thumble on {} {}",
            std::env::consts::OS,
            id.chars().take(8).collect::<String>()
        );
        let properties = [("id", id.as_str()), ("name", name.as_str())];
        let info = ServiceInfo::new(
            "_pocketpad._tcp.local.",
            &name,
            &format!("thumble-{id}.local."),
            "",
            port,
            &properties[..],
        )
        .map_err(|e| e.to_string())?
        .enable_addr_auto();
        let fullname = info.get_fullname().to_owned();
        daemon
            .register(info)
            .map_err(|e| format!("Register mDNS: {e}"))?;
        Some(Discovery(daemon, fullname))
    } else {
        None
    };
    println!("Thumble receiver listening: {}", urls(port).join(", "));
    println!("Pairing code: {}", core.pairing_code());
    println!(
        "Virtual gamepad output: unsupported. Keyboard/mouse input: {}",
        if input_enabled { "enabled" } else { "disabled" }
    );
    let (shutdown, mut shutdown_rx) = watch::channel(false);
    let (commands, rx) = mpsc::channel(32);
    let (priority, priority_rx) = mpsc::channel(16);
    let worker = Receiver {
        core,
        input,
        store,
        peers: HashMap::new(),
        clock: Clock::new(),
        last_poll: 0,
        neutralizing: false,
        input_enabled,
        port,
        shutdown: shutdown.clone(),
        last_error: None,
    };
    let thread = std::thread::Builder::new()
        .name("thumble-receiver".into())
        .spawn(move || worker.work(rx, priority_rx))
        .map_err(|e| e.to_string())?;
    let mut tick = tokio::time::interval(Duration::from_millis(250));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let phones = Arc::new(Semaphore::new(32));
    let frame_budget = Arc::new(Semaphore::new(2 * FRAME_LIMIT));
    let clients = Arc::new(Semaphore::new(16));
    let mut tasks = JoinSet::new();
    let mut next_id = 0u64;
    let signal = shutdown_signal();
    tokio::pin!(signal);
    let mut run_error = None;
    loop {
        tokio::select! {
            _ = &mut signal => break,
            _ = shutdown_rx.changed() => break,
            _ = tick.tick() => { if commands.try_send(Command::Tick).is_err() && commands.is_closed() { break; } }
            Some(_) = tasks.join_next(), if !tasks.is_empty() => (),
            accepted = listener.accept() => {
                let (stream,_) = match accepted {
                    Ok(connection) => connection,
                    Err(error) => { run_error = Some(error.to_string()); break; }
                };
                if let Ok(permit) = phones.clone().try_acquire_owned() {
                    next_id += 1;
                    let commands = commands.clone();
                    let budget = frame_budget.clone();
                    tasks.spawn(async move { let _permit = permit; phone(stream,next_id,commands,budget).await; });
                }
            }
            accepted = cli_listener.accept() => {
                let (stream,_) = match accepted {
                    Ok(connection) => connection,
                    Err(error) => { run_error = Some(error.to_string()); break; }
                };
                if let Ok(permit) = clients.clone().try_acquire_owned() {
                    let commands = commands.clone();
                    let token = local_token.clone();
                    let priority = priority.clone();
                    tasks.spawn(async move { let _permit = permit; let _ = tokio::time::timeout(IO_TIMEOUT,local_client(stream,&token,commands,priority)).await; });
                }
            }
        }
    }
    // Closing the command receiver drains no more phone input. Worker retirement
    // neutralizes all output before the lock and runtime descriptor are dropped.
    let _ = shutdown.send(true);
    tasks.abort_all();
    drop(commands);
    while tasks.join_next().await.is_some() {}
    tokio::task::spawn_blocking(move || thread.join())
        .await
        .map_err(|e| e.to_string())?
        .map_err(|_| "Receiver thread panicked".to_owned())?;
    run_error.map_or(Ok(()), Err)
}

async fn phone(
    stream: TcpStream,
    id: u64,
    commands: mpsc::Sender<Command>,
    budget: Arc<Semaphore>,
) {
    let _ = stream.set_nodelay(true);
    let config = WebSocketConfig::default()
        .max_message_size(Some(FRAME_LIMIT))
        .max_frame_size(Some(FRAME_LIMIT));
    let Ok(Ok(socket)) =
        tokio::time::timeout(IO_TIMEOUT, accept_async_with_config(stream, Some(config))).await
    else {
        return;
    };
    let (mut sink, mut source) = socket.split();
    let (outbound, mut incoming) = mpsc::channel(4);
    if commands.send(Command::Connect(id, outbound)).await.is_err() {
        return;
    }
    let idle = tokio::time::sleep(Duration::from_secs(60));
    tokio::pin!(idle);
    loop {
        tokio::select! {
            _ = &mut idle => break,
            message = incoming.recv() => {
                let Some(message) = message else { break; };
                if !matches!(tokio::time::timeout(IO_TIMEOUT,sink.send(message)).await,Ok(Ok(()))) { break; }
            }
            message = source.next() => {
                idle.as_mut().reset(tokio::time::Instant::now()+Duration::from_secs(60));
                let bytes = match message {
                    Some(Ok(Message::Binary(bytes))) => bytes.to_vec(),
                    Some(Ok(Message::Text(text))) => text.as_bytes().to_vec(),
                    Some(Ok(Message::Ping(data))) => { if !matches!(tokio::time::timeout(IO_TIMEOUT,sink.send(Message::Pong(data))).await,Ok(Ok(()))) { break; } continue; }
                    Some(Ok(Message::Pong(_))) => continue,
                    _ => break,
                };
                let Ok(Ok(permit)) = tokio::time::timeout(IO_TIMEOUT,budget.clone().acquire_many_owned(bytes.len().max(1) as u32)).await else { break; };
                let Ok(message) = ControllerWireCodec::decode(&bytes) else { break; };
                if commands.send(Command::Message(id,Box::new(message),permit)).await.is_err() { break; }
            }
        }
    }
    let _ = commands.send(Command::Disconnect(id)).await;
}

async fn line<R: tokio::io::AsyncRead + Unpin>(read: R) -> Result<Vec<u8>, String> {
    let mut reader = BufReader::new(read).take(65537);
    let mut data = Vec::new();
    // AsyncBufReadExt::take is an AsyncRead adapter; use a bounded second reader.
    let count = BufReader::new(&mut reader)
        .read_until(b'\n', &mut data)
        .await
        .map_err(|e| e.to_string())?;
    if count > 65536 || data.last() != Some(&b'\n') {
        return Err("Invalid bounded local frame".into());
    }
    Ok(data)
}
async fn local_client(
    mut stream: TcpStream,
    token: &str,
    commands: mpsc::Sender<Command>,
    priority: mpsc::Sender<Command>,
) -> Result<(), String> {
    let request: ControlRequest = thumble_protocol::decode_unique_json(&line(&mut stream).await?)
        .map_err(|_| "Invalid control request".to_owned())?;
    if request.token != token {
        return Err("Unauthorized local request".into());
    }
    let stopping = request.command == "stop";
    let (reply, response) = oneshot::channel();
    priority
        .send(Command::Control(request.command, reply))
        .await
        .map_err(|_| "Receiver stopped".to_owned())?;
    let _ = commands.try_send(Command::Tick);
    let response = response.await.map_err(|_| "Receiver stopped".to_owned())?;
    let mut bytes = serde_json::to_vec(&response).map_err(|e| e.to_string())?;
    bytes.push(b'\n');
    let result = stream.write_all(&bytes).await.map_err(|e| e.to_string());
    if stopping {
        let _ = priority.send(Command::Shutdown).await;
        let _ = commands.try_send(Command::Tick);
    }
    result
}

pub async fn control(store: &Store, command: &str) -> Result<Value, String> {
    let endpoint: ControlEndpoint = store
        .read("runtime.json")
        .map_err(|_| "Receiver is not running or its runtime record is inaccessible".to_owned())?;
    tokio::time::timeout(IO_TIMEOUT, async {
        let mut stream = TcpStream::connect(SocketAddr::from((Ipv4Addr::LOCALHOST, endpoint.port)))
            .await
            .map_err(|e| e.to_string())?;
        let mut request = serde_json::to_vec(&ControlRequest {
            token: endpoint.token,
            command: command.into(),
        })
        .map_err(|e| e.to_string())?;
        request.push(b'\n');
        stream
            .write_all(&request)
            .await
            .map_err(|e| e.to_string())?;
        serde_json::from_slice(&line(stream).await?)
            .map_err(|_| "Invalid local response".to_owned())
    })
    .await
    .map_err(|_| "Local command timed out".to_owned())?
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis().min(i64::MAX as u128) as i64)
        .unwrap_or(0)
}
fn urls(port: u16) -> Vec<String> {
    if_addrs::get_if_addrs()
        .unwrap_or_default()
        .into_iter()
        .filter(|i| !i.is_loopback())
        .filter_map(|i| match i.ip() {
            std::net::IpAddr::V4(ip) => Some(format!("ws://{ip}:{port}")),
            _ => None,
        })
        .collect::<std::collections::BTreeSet<_>>()
        .into_iter()
        .collect()
}
async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("Install SIGTERM handler");
        tokio::select! { _ = tokio::signal::ctrl_c() => (), _ = terminate.recv() => () }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

struct Clock {
    fallback: Instant,
    origin: Option<u64>,
}
impl Clock {
    fn new() -> Self {
        Self {
            fallback: Instant::now(),
            origin: continuous_millis(),
        }
    }
    fn millis(&self) -> i64 {
        let millis = self
            .origin
            .zip(continuous_millis())
            .map(|(start, now)| now.saturating_sub(start))
            .unwrap_or_else(|| self.fallback.elapsed().as_millis().min(u64::MAX as u128) as u64);
        millis.min(i64::MAX as u64) as i64
    }
}
fn continuous_millis() -> Option<u64> {
    #[cfg(target_os = "linux")]
    {
        let mut time = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        // CLOCK_BOOTTIME includes suspension, unlike CLOCK_MONOTONIC.
        if unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut time) } == 0 {
            return Some(time.tv_sec as u64 * 1000 + time.tv_nsec as u64 / 1_000_000);
        }
    }
    #[cfg(windows)]
    {
        Some(unsafe { windows_sys::Win32::System::SystemInformation::GetTickCount64() })
    }
    #[cfg(not(windows))]
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::{Event, Sink};
    use std::sync::Mutex;
    use thumble_core::KeyBinding;
    struct Record(Arc<Mutex<Vec<Event>>>);
    impl Sink for Record {
        fn emit(&mut self, e: Event) -> Result<(), String> {
            self.0.lock().unwrap().push(e);
            Ok(())
        }
    }
    #[test]
    fn scheduling_gap_retires_sessions_and_releases_physical_outputs() {
        let temp = tempfile::tempdir().unwrap();
        let store = Store::open(Some(temp.path().join("state"))).unwrap();
        let core = HostCore::new_with_tokens(store.load().unwrap(), &mut Tokens).unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let mut input = Input::with_sink(Box::new(Record(events.clone())));
        input
            .execute(&Effect::KeyDown(KeyBinding::new(0, 8)))
            .unwrap();
        input
            .execute(&Effect::PointerButton {
                button: thumble_protocol::ControllerPointerButton::Left,
                pressed: true,
            })
            .unwrap();
        let (shutdown, _) = watch::channel(false);
        let (peer, _) = mpsc::channel(4);
        let mut receiver = Receiver {
            core,
            input,
            store,
            peers: HashMap::from([(1, peer)]),
            clock: Clock::new(),
            last_poll: -HOLD_AGE - 1,
            neutralizing: false,
            input_enabled: true,
            port: 0,
            shutdown,
            last_error: None,
        };
        receiver.safety_tick().unwrap();
        assert!(receiver.peers.is_empty());
        let events = events.lock().unwrap();
        assert!(events.contains(&Event::Key(crate::input::key(0).unwrap(), false)));
        assert!(events.contains(&Event::Button(272, false)));
    }
}
