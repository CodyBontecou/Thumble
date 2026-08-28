//! Shared transport and wire-protocol library for the Thumble remote relay.
//!
//! Used by both sides of the tunnel:
//!
//! - `thumble-mcp --relay` (device side, on the user's Mac)
//! - `thumble-gateway` (hosted side, terminating remote MCP sessions)
//!
//! The library contains no host logic, no profile state, and no credentials;
//! it only defines the wire protocol and WebSocket framing helpers.

pub mod protocol;
pub mod ws_rpc;

pub use protocol::{
    constant_time_eq, pkce_s256_matches, random_link_code, random_token, token_digest,
    TunnelMessage, LINK_CODE_MAX_ATTEMPTS, LINK_CODE_TTL_SECONDS, MAXIMUM_DEVICE_SESSIONS,
    MAXIMUM_FRAME_BYTES, PROTOCOL_VERSION,
};
