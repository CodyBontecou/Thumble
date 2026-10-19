//! Windows/Linux LAN receiver. Shares the released iOS wire protocol and host
//! state machine with the Mac host; owns no Swift helper or Mac IPC dependency.
pub mod input;
pub mod runtime;
pub mod store;
