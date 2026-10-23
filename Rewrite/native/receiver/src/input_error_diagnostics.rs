//! Opt-in debug error-path evidence. No payloads, identities, paths or healthy spans.
use serde_json::{json, Value};
use std::sync::{
    atomic::{AtomicU64, Ordering},
    OnceLock,
};
const LIMIT: u64 = 16;
static ENABLED: OnceLock<bool> = OnceLock::new();
static COUNT: AtomicU64 = AtomicU64::new(0);
fn enabled() -> bool {
    *ENABLED
        .get_or_init(|| std::env::var("THUMBLE_REWRITE_INPUT_ERROR_PROBE").as_deref() == Ok("1"))
}
thread_local! { static RECEIVER_THREAD: std::cell::Cell<bool> = const { std::cell::Cell::new(false) }; }
pub fn server_thread() {
    if enabled() {
        RECEIVER_THREAD.with(|role| role.set(true));
    }
}
fn role() -> &'static str {
    RECEIVER_THREAD.with(|role| if role.get() { "receiver" } else { "broker" })
}
fn reserve(count: &AtomicU64) -> bool {
    count
        .fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| {
            (n < LIMIT).then_some(n + 1)
        })
        .is_ok()
}
fn emit(value: Value) {
    let text = value.to_string();
    if text.len() <= 256 && reserve(&COUNT) {
        eprintln!("native_input_error {text}");
    }
}
fn code(value: &'static str) -> &'static str {
    match value {
        "native_input_timeout"
        | "native_input_transport_failed"
        | "native_input_frame_invalid"
        | "native_input_rejected"
        | "native_owner_reply_timeout"
        | "native_owner_reply_closed"
        | "native_input_owner_failed"
        | "input_session_closed"
        | "input_packet_invalid" => value,
        _ => "other",
    }
}
pub fn operation(context: &'static str, op: u8, error: &'static str) {
    if !enabled() {
        return;
    }
    let context = match context {
        "native-client" | "native-server-wait" | "native-server-send" | "phone-control"
        | "sample" => context,
        _ => return,
    };
    emit(
        json!({"version":1,"role":role(),"context":context,"op":if op <= 11 { op } else { 0 },"code":code(error)}),
    );
}
pub fn io(context: &'static str, error: &std::io::Error) {
    if !enabled() {
        return;
    }
    let context = match context {
        "native-read" | "native-write" | "native-read-options" | "native-write-options" => context,
        _ => return,
    };
    let kind = match error.kind() {
        std::io::ErrorKind::WouldBlock => "would-block",
        std::io::ErrorKind::TimedOut => "timed-out",
        std::io::ErrorKind::Interrupted => "interrupted",
        std::io::ErrorKind::UnexpectedEof => "unexpected-eof",
        std::io::ErrorKind::BrokenPipe => "broken-pipe",
        std::io::ErrorKind::ConnectionReset => "connection-reset",
        std::io::ErrorKind::ConnectionAborted => "connection-aborted",
        std::io::ErrorKind::NotConnected => "not-connected",
        std::io::ErrorKind::InvalidInput => "invalid-input",
        std::io::ErrorKind::PermissionDenied => "permission-denied",
        _ => "other",
    };
    emit(
        json!({"version":1,"role":role(),"context":context,"ioKind":kind,"osCode":error.raw_os_error()}),
    );
}
pub fn end(context: &'static str) {
    if !enabled() {
        return;
    }
    let (context, exit) = match context {
        "native-read" => (context, "eof"),
        "native-write" => (context, "zero-write"),
        _ => return,
    };
    emit(json!({"version":1,"role":role(),"context":context,"exit":exit}));
}
pub fn server_exit(reason: &'static str, owned: usize) {
    if !enabled() {
        return;
    }
    let reason = match reason {
        "stopped" | "handshake" | "read-deadline" | "read-failure" | "invalid-frame"
        | "invalid-payload" | "queue-full" | "queue-closed" | "wake-failure" | "send-failure" => {
            reason
        }
        _ => return,
    };
    emit(
        json!({"version":1,"role":role(),"context":"native-server-exit","exit":reason,"owned":owned.min(2)}),
    );
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn counter_stops_at_first16_without_overflow_or_replacing_old_events() {
        let count = AtomicU64::new(0);
        assert_eq!((0..1000).filter(|_| reserve(&count)).count(), 16);
        assert_eq!(count.load(Ordering::Relaxed), 16);
    }
    #[test]
    fn arbitrary_error_text_is_never_reflected() {
        assert_eq!(code("secret=must-not-appear"), "other");
        assert_eq!(code("native_input_timeout"), "native_input_timeout");
    }
}
