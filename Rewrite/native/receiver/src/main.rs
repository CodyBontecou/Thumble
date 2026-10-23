use thumble_rewrite_receiver::{clock, gamepad, runtime, security};

use runtime::{identity, Output, Request};
use serde_json::json;
use std::{
    fs::File,
    io::{BufRead, BufReader, Write},
    path::{Path, PathBuf},
    sync::mpsc,
    time::Duration,
};
use thumble_rewrite_receiver::packet_runtime::PacketRuntime;
const FRAME_LIMIT: usize = 64 * 1024;

struct Recording {
    file: File,
}
impl Output for Recording {
    fn submit(&mut self, report: [u8; 20], reason: &'static str) -> Result<(), &'static str> {
        #[cfg(debug_assertions)]
        let _io = thumble_rewrite_receiver::input_io_diagnostics::Span::start(
            thumble_rewrite_receiver::input_io_diagnostics::Metric::NativeOutput,
        );
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
fn secure_configuration(root: &Path) -> Result<(), &'static str> {
    security::directory(root)?;
    security::file(&root.join("configuration-v1.sqlite3"), false)?;
    // A valid rollback journal can survive a crash; protect it before SQLite
    // recovery. WAL/SHM are outside this schema's supported journal mode.
    let journal = root.join("configuration-v1.sqlite3-journal");
    match std::fs::symlink_metadata(&journal) {
        Ok(_) => {
            security::file(&journal, false)?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(_) => return Err("runtime_file_open_failed"),
    }
    Ok(())
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
    run_owner(root, &mut output)
}
fn run_owner(root: &Path, output: &mut impl Output) -> Result<(), &'static str> {
    let mut runtime = PacketRuntime::default();
    runtime.release_reason(output, "startup")?;
    let wake = std::sync::Arc::new(thumble_rewrite_receiver::owner_wake::OwnerWake::default());
    let mut ingress =
        thumble_rewrite_receiver::native_ingress::Server::bind_with_wake(root, Some(wake.clone()))?;
    let (incoming, received) = mpsc::sync_channel::<Option<Vec<u8>>>(16);
    let input_wake = wake.clone();
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
                        let _ = input_wake.notify();
                        return;
                    }
                };
                if buffer.is_empty() {
                    let _ = incoming.send(None);
                    let _ = input_wake.notify();
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
            if input_wake.notify().is_err() {
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
                let _ = runtime.release_reason(output, "clock_failed");
                return Err(error);
            }
        };
        if let Err(error) = runtime.tick(now, output) {
            // Definite backend failures retire the runtime but leave the owner
            // available for a fresh activation CAS. An uncertain worker remains
            // restart-required and rejects every subsequent activation.
            if !error.starts_with("physical_output_") {
                return Err(error);
            }
        }
        if let Err(error) = ingress.drain(&mut runtime, now, output) {
            let _ = runtime.release_reason(output, "native_input_owner_failed");
            return Err(error);
        }
        let bytes = match received.try_recv() {
            Ok(Some(bytes)) => bytes,
            Ok(None) | Err(mpsc::TryRecvError::Disconnected) => {
                runtime.release_reason(output, "owner_disconnected")?;
                break;
            }
            Err(mpsc::TryRecvError::Empty) => {
                if let Err(error) = wake.wait(Duration::from_millis(10)) {
                    let _ = runtime.release_reason(output, "owner_wake_failed");
                    return Err(error);
                }
                continue;
            }
        };
        let parsed = serde_json::from_slice::<Request>(&bytes)
            .ok()
            .filter(|r| r.version == 1 && identity(&r.request_id));
        let rearm_status = parsed
            .as_ref()
            .is_some_and(|request| matches!(request.body, runtime::Command::SavedRearmStatus {}));
        let saved_binding_status = parsed
            .as_ref()
            .is_some_and(|request| matches!(request.body, runtime::Command::SavedBindingStatus {}));
        let (request_id, result) = match parsed {
            Some(request) => {
                let id = Some(request.request_id);
                (
                    id,
                    runtime.apply_owner(request.body, clock::millis()?, output),
                )
            }
            None => (None, Err("invalid_request")),
        };
        let stopping = matches!(result, Ok(false));
        let reply = match result {
            Ok(_) if rearm_status => {
                let (released, cleanup) = runtime.rearm_status();
                json!({"version":1,"requestId":request_id,"ok":true,"snapshot":runtime.snapshot(),"releasedBinding":released,"cleanupReady":cleanup,"firstTermination":runtime.first_termination()})
            }
            Ok(_) if saved_binding_status => {
                json!({"version":1,"requestId":request_id,"ok":true,"snapshot":runtime.snapshot(),"savedBinding":runtime.saved_binding()})
            }
            Ok(_) => {
                json!({"version":1,"requestId":request_id,"ok":true,"snapshot":runtime.snapshot()})
            }
            Err(error) => json!({"version":1,"requestId":request_id,"ok":false,"error":error}),
        };
        if outgoing.try_send(reply.to_string()).is_err() {
            runtime.release_reason(output, "owner_backpressure")?;
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
fn run_macos_hid(arguments: &[String]) -> Result<(), &'static str> {
    if arguments.len() != 3 || arguments[2] != "--allow-physical-output" {
        return Err("physical_output_explicit_flag_required");
    }
    #[cfg(all(target_os = "macos", feature = "output-macos"))]
    {
        use std::sync::Arc;
        use thumble_rewrite_receiver::output_bridge::{Bridge, KernelClock};
        let root = Path::new(&arguments[1]);
        security::directory(root)?;
        let lock = security::file(&root.join("receiver.lock"), false)?;
        fs2::FileExt::try_lock_exclusive(&lock).map_err(|_| "receiver_owner_exists")?;
        let mut owner = [0u8; 16];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut owner)
            .map_err(|_| "physical_output_unavailable")?;
        let mut output = Bridge::new(
            thumble_rewrite_output_core::macos::MacFactory,
            Arc::new(KernelClock),
            owner,
            "macos-hid",
        )?;
        run_owner(root, &mut output)
    }
    #[cfg(not(all(target_os = "macos", feature = "output-macos")))]
    {
        Err("physical_output_not_built")
    }
}
fn main() {
    let native_args = std::env::args().skip(1).collect::<Vec<_>>();
    let result = if native_args
        .first()
        .is_some_and(|mode| mode == "run-macos-hid")
    {
        run_macos_hid(&native_args)
    } else if native_args
        .first()
        .is_some_and(|mode| mode == "output-capabilities")
    {
        thumble_rewrite_receiver::output_doctor::run(&native_args)
    } else if native_args
        .first()
        .is_some_and(|mode| mode == "pairing-host")
    {
        if !(3..=4).contains(&native_args.len()) {
            Err("invalid_pairing_host_arguments")
        } else {
            thumble_rewrite_receiver::pairing_host::run(
                Path::new(&native_args[1]),
                &native_args[2],
                native_args.get(3).map(Path::new),
            )
        }
    } else if native_args
        .first()
        .is_some_and(|mode| mode == "configuration-export-file")
    {
        thumble_rewrite_receiver::export_files::run(&native_args)
    } else if native_args
        .first()
        .is_some_and(|mode| mode.starts_with("assets-"))
    {
        thumble_rewrite_receiver::asset_files::run(&native_args)
    } else {
        args().and_then(|(mode, root, log)| match mode.as_str() {
        "secure-directory" => security::directory(&root),
        "secure-configuration" if log.is_none() => secure_configuration(&root),
        "host-identity-initialize" | "host-identity-show" if log.is_none() => {
            let operation = if mode == "host-identity-initialize" { thumble_rewrite_receiver::host_identity::load_or_create } else { thumble_rewrite_receiver::host_identity::load_existing };
            operation(&root).map(|identity| {
                println!("{}", json!({"version":1,"certificatePin":identity.pin().hex(),"serverName":thumble_rewrite_receiver::control_tls::CONTROL_SERVER_NAME,"networkEnabled":false,"inputEnabled":false}));
            })
        }
        "run" => run(&root, log.as_deref()),
        _ => Err("unsupported_mode"),
    })
    };
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
}
