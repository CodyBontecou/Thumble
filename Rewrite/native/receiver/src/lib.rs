//! Native transport primitives; enabling a listener/input requires authenticated enrollment.
pub mod gamepad;
pub mod generated;
pub mod input_packet;

#[path = "generated-packet.rs"]
mod generated_packet;

pub mod packet_runtime;
pub mod runtime;

pub mod control_tls;
