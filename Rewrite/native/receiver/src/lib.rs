//! Native transport primitives; enabling a listener/input requires authenticated enrollment.
pub mod gamepad;
pub mod generated;
pub mod input_packet;

#[path = "generated-packet.rs"]
mod generated_packet;

pub mod packet_runtime;
pub mod runtime;

pub mod control_tls;

pub mod host_identity;
pub mod security;
#[cfg(windows)]
mod windows_security;

pub mod phone_trust;

pub mod enrollment;

pub mod pairing_host;

pub mod authenticated_control;

pub mod native_ingress;

mod input_broker;

mod input_datagram;

pub mod asset_files;

#[cfg(debug_assertions)]
#[doc(hidden)]
pub mod input_io_diagnostics;

mod authorization_clock;
mod cached_authorization;

mod trust_reservation;

pub mod export_files;

pub mod output_doctor;

pub mod clock;
#[cfg(feature = "output-bridge")]
pub mod output_bridge;

pub mod owner_wake;

#[cfg(debug_assertions)]
pub mod input_error_diagnostics;

// Captured editor lifetimes are enabled only by an explicit private parent command.
#[allow(dead_code)]
mod editor_commit_fence;

// Shared edit ownership spans native phone dispatch and policy acknowledgements.
#[allow(dead_code)]
mod editor_pending;

/// Strict bounded phone editor DTOs.
pub mod editor_codec;

mod editor_policy;
