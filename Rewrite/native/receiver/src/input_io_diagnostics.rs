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
}
const NAMES: [&str; 8] = [
    "trustAuthorize",
    "trustAuthenticate",
    "inputWait",
    "inputHeld",
    "controlWait",
    "controlHeld",
    "sampleCycle",
    "sampleGap",
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
static COUNTERS: [Counter; 8] = [const { Counter::new() }; 8];
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
