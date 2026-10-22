//! Temporary aggregate-only native IO probe. Compiled out of release builds.
use std::{
    sync::{
        atomic::{AtomicU64, Ordering},
        OnceLock,
    },
    time::{Duration, Instant},
};
#[derive(Clone, Copy)]
pub enum Metric {
    TrustAuthorize,
    TrustAuthenticate,
    InputWait,
    InputHeld,
    ControlWait,
    ControlHeld,
    SampleCycle,
    SampleGap,
    NativeClientSend,
    NativeClientReceive,
    NativeServerQueue,
    NativeServerApply,
    NativeServerReply,
    NativeOutput,
}
const NAMES: [&str; 14] = [
    "trustAuthorize",
    "trustAuthenticate",
    "inputWait",
    "inputHeld",
    "controlWait",
    "controlHeld",
    "sampleCycle",
    "sampleGap",
    "nativeClientSend",
    "nativeClientReceive",
    "nativeServerQueue",
    "nativeServerApply",
    "nativeServerReply",
    "nativeOutput",
];
static ENABLED: OnceLock<bool> = OnceLock::new();
static ORIGIN: OnceLock<Instant> = OnceLock::new();
fn timestamp() -> u64 {
    ORIGIN
        .get_or_init(Instant::now)
        .elapsed()
        .as_micros()
        .min(u128::from(u64::MAX - 1)) as u64
        + 1
}
struct Counter {
    count: AtomicU64,
    total: AtomicU64,
    maximum: AtomicU64,
    active: [AtomicU64; 16],
}
impl Counter {
    const fn new() -> Self {
        Self {
            count: AtomicU64::new(0),
            total: AtomicU64::new(0),
            maximum: AtomicU64::new(0),
            active: [const { AtomicU64::new(0) }; 16],
        }
    }
}
static COUNTERS: [Counter; 14] = [const { Counter::new() }; 14];
fn enabled() -> bool {
    *ENABLED.get_or_init(|| std::env::var("THUMBLE_REWRITE_INPUT_IO_PROBE").as_deref() == Ok("1"))
}
pub fn record(metric: Metric, elapsed: Duration) {
    if !enabled() {
        return;
    }
    let value = elapsed.as_micros().min(u128::from(u64::MAX)) as u64;
    let counter = &COUNTERS[metric as usize];
    counter.count.fetch_add(1, Ordering::Relaxed);
    counter.total.fetch_add(value, Ordering::Relaxed);
    counter.maximum.fetch_max(value, Ordering::Relaxed);
}
pub struct Span {
    metric: Metric,
    started: Instant,
    slot: Option<usize>,
}
impl Span {
    pub fn start(metric: Metric) -> Option<Self> {
        enabled().then(|| {
            let started = Instant::now();
            let time = timestamp();
            let slot = COUNTERS[metric as usize].active.iter().position(|slot| {
                slot.compare_exchange(0, time, Ordering::Relaxed, Ordering::Relaxed)
                    .is_ok()
            });
            Self {
                metric,
                started,
                slot,
            }
        })
    }
}
impl Drop for Span {
    fn drop(&mut self) {
        record(self.metric, self.started.elapsed());
        if let Some(slot) = self.slot {
            COUNTERS[self.metric as usize].active[slot].store(0, Ordering::Relaxed);
        }
    }
}
/// Fixed names and numeric aggregates only. No peer/source/credential/packet fields.
pub fn snapshot() -> serde_json::Value {
    let now = timestamp();
    serde_json::Value::Array(COUNTERS.iter().zip(NAMES).map(|(c, name)| {
        let active: Vec<_> = c.active.iter().map(|slot| slot.load(Ordering::Relaxed)).filter(|start| *start != 0).collect();
        serde_json::json!({"metric":name,"count":c.count.load(Ordering::Relaxed),"totalUs":c.total.load(Ordering::Relaxed),"maximumUs":c.maximum.load(Ordering::Relaxed),"activeCount":active.len(),"oldestActiveUs":active.into_iter().min().map(|start| now.saturating_sub(start)).unwrap_or(0)})
    }).collect())
}

/// Debug-only terminal evidence: callers supply fixed operation/error names,
/// never frame payloads, identities, credentials, paths or arbitrary IO text.
pub fn terminal(context: &'static str, operation: u8, error: &'static str) {
    if enabled() {
        let context = match context {
            "native-client" | "native-server-wait" | "native-server-send" | "phone-control"
            | "sample" => context,
            _ => "unclassified",
        };
        let error =
            if error.len() <= 96 && error.bytes().all(|b| b.is_ascii_lowercase() || b == b'_') {
                error
            } else {
                "unclassified"
            };
        let operation = if operation <= 5 { operation } else { 0 };
        eprintln!(
            "[DEBUG-native-io-terminal] context={context} op={operation} error={error} metrics={}",
            snapshot()
        );
    }
}
pub fn terminal_io(context: &'static str, error: &std::io::Error) {
    if enabled() {
        let context = if context == "native-read" {
            context
        } else {
            "unclassified"
        };
        eprintln!(
            "[DEBUG-native-io-terminal] context={context} ioKind={:?} osCode={:?} metrics={}",
            error.kind(),
            error.raw_os_error(),
            snapshot()
        );
    }
}
