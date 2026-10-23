//! Dormant native output owner. This crate is not connected to the rewrite receiver.
//! Factory values cross threads; devices never do. No factory opens a device at spawn.
mod clock;
mod owner;
mod report;
pub use clock::{ClockDomain, ClockFault};
pub use owner::*;
pub use report::{Report, REPORT_DESCRIPTOR, REPORT_ID, REPORT_LENGTH};
#[cfg(all(target_os = "macos", feature = "macos-hid"))]
pub mod macos;
