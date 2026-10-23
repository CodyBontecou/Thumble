//! Explicit authority-clock port. Implementations must use the same absolute,
//! sleep-inclusive millisecond domain as the receiver's lease timestamps.
//! `std::time::Instant`/awake elapsed clocks are not substitutes for this contract.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClockFault {
    Unavailable,
    Regressed,
}
/// Reads must not wait on the output owner or device IO. The receiver supplies
/// its existing platform clock function directly, without elapsed-time conversion.
pub trait ClockDomain: Send + Sync + 'static {
    fn now_ms(&self) -> Result<u64, ClockFault>;
}
impl<F: Fn() -> Result<u64, ClockFault> + Send + Sync + 'static> ClockDomain for F {
    fn now_ms(&self) -> Result<u64, ClockFault> {
        self()
    }
}
