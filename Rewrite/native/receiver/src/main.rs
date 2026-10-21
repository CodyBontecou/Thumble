use thumble_rewrite_receiver::{gamepad, runtime};
mod clock;
mod security;
#[cfg(windows)]
mod windows_security;

use runtime::{identity, Output, Request, Runtime};
use serde_json::json;
use std::{
    fs::File,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    sync::mpsc,
    time::Duration,
};
const FRAME_LIMIT: usize = 64 * 1024;

struct Recording {
    file: File,
}
impl Output for Recording {
    fn submit(&mut self, report: [u8; 20], reason: &'static str) -> Result<(), &'static str> {
        writeln!(
            self.file,
            "{}",
            json!({"reportHex":gamepad::hex(&report),"reason":reason})
        )
        .and_then(|_| self.file.flush())
        .map_err(|_| "recording_output_failed")
    }
}
impl Drop for Recording {
    fn drop(&mut self) {
        let _ = self.submit(gamepad::NEUTRAL, "process_exit");
    }
}
fn args() -> Result<(String, PathBuf, Option<PathBuf>), &'static str> {
    let mut args = std::env::args().skip(1);
    let mode = args.next().ok_or("missing_mode")?;
    let root = PathBuf::from(args.next().ok_or("missing_runtime_directory")?);
    let log = args.next().map(PathBuf::from);
    if args.next().is_some() {
        return Err("unexpected_argument");
    }
    Ok((mode, root, log))
}
fn run(root: &Path, log: Option<&Path>) -> Result<(), &'static str> {
    security::directory(root)?;
    let lock = security::file(&root.join("receiver.lock"), false)?;
    fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "receiver_owner_exists")?;
    let log = log.ok_or("missing_recording_log")?;
    if log.parent() != Some(root) {
        return Err("recording_log_outside_runtime");
    }
    let mut output = Recording {
        file: security::file(log, true)?,
    };
    let mut runtime = Runtime::default();
    runtime.release(&mut output, "startup")?;
    let (incoming, received) = mpsc::sync_channel::<Option<Vec<u8>>>(16);
    std::thread::spawn(move || {
        let mut input = BufReader::new(std::io::stdin());
        loop {
            let mut bytes = Vec::new();
            let mut overflow = false;
            loop {
                let buffer = match input.fill_buf() {
                    Ok(b) => b,
                    Err(_) => {
                        let _ = incoming.send(None);
                        return;
                    }
                };
                if buffer.is_empty() {
                    let _ = incoming.send(None);
                    return;
                }
                let newline = buffer.iter().position(|b| *b == b'\n');
                let count = newline.map_or(buffer.len(), |n| n + 1);
                if bytes.len().saturating_add(count) > FRAME_LIMIT {
                    overflow = true;
                } else if !overflow {
                    bytes.extend_from_slice(&buffer[..count]);
                }
                input.consume(count);
                if newline.is_some() {
                    break;
                }
            }
            if overflow {
                bytes.clear();
            }
            if incoming.send(Some(bytes)).is_err() {
                return;
            }
        }
    });
    // Never let a stalled stdout reader block the native safety clock.
    let (outgoing, responses) = mpsc::sync_channel::<String>(16);
    let (flushed, finished) = mpsc::channel();
    std::thread::spawn(move || {
        let mut stdout = std::io::stdout().lock();
        for line in responses {
            if writeln!(stdout, "{line}")
                .and_then(|_| stdout.flush())
                .is_err()
            {
                break;
            }
        }
        let _ = flushed.send(());
    });
    outgoing.try_send(json!({"version":1,"ready":true,"pid":std::process::id(),"snapshot":runtime.snapshot()}).to_string()).map_err(|_|"owner_output_unavailable")?;
    loop {
        let now = match clock::millis() {
            Ok(n) => n,
            Err(error) => {
                let _ = runtime.release(&mut output, "clock_failed");
                return Err(error);
            }
        };
        runtime.tick(now, &mut output)?;
        let bytes = match received.recv_timeout(Duration::from_millis(10)) {
            Ok(Some(bytes)) => bytes,
            Ok(None) | Err(mpsc::RecvTimeoutError::Disconnected) => {
                runtime.release(&mut output, "owner_disconnected")?;
                break;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
        };
        let parsed = serde_json::from_slice::<Request>(&bytes)
            .ok()
            .filter(|r| r.version == 1 && identity(&r.request_id));
        let (request_id, result) = match parsed {
            Some(request) => {
                let id = Some(request.request_id);
                (
                    id,
                    runtime.apply(request.body, clock::millis()?, &mut output),
                )
            }
            None => (None, Err("invalid_request")),
        };
        let stopping = matches!(result, Ok(false));
        let reply = match result {
            Ok(_) => {
                json!({"version":1,"requestId":request_id,"ok":true,"snapshot":runtime.snapshot()})
            }
            Err(error) => json!({"version":1,"requestId":request_id,"ok":false,"error":error}),
        };
        if outgoing.try_send(reply.to_string()).is_err() {
            runtime.release(&mut output, "owner_backpressure")?;
            return Err("owner_output_unavailable");
        }
        if stopping {
            break;
        }
    }
    // A shutdown response needs to leave the bounded queue before main exits.
    drop(outgoing);
    let _ = finished.recv_timeout(Duration::from_millis(100));
    Ok(())
}
fn main() {
    let result = args().and_then(|(mode, root, log)| match mode.as_str() {
        "secure-directory" => security::directory(&root),
        "run" => run(&root, log.as_deref()),
        _ => Err("unsupported_mode"),
    });
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
