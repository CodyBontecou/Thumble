//! Synthetic phone -> pinned TLS -> native IPC -> independent receiver witness. Never shipped.
use serde_json::{json, Value};
use std::{
    fs,
    io::{BufRead, BufReader, Read, Seek, SeekFrom, Write},
    path::PathBuf,
    process::{Child, ChildStdin, Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use thumble_rewrite_receiver::{
    gamepad::{hex, NEUTRAL},
    generated::GamepadState,
    host_identity,
    pairing_host::{Command as HostCommand, Host},
};
struct Receiver {
    child: Child,
    input: ChildStdin,
    replies: mpsc::Receiver<Value>,
    serial: u64,
    generation: u64,
    recording: PathBuf,
    recording_start: u64,
}
impl Receiver {
    fn start(root: &std::path::Path) -> Result<Self, Box<dyn std::error::Error>> {
        let executable = std::env::current_exe()?;
        let binary = executable
            .parent()
            .and_then(|p| p.parent())
            .ok_or("probe_path")?
            .join(format!(
                "thumble-rewrite-receiver{}",
                std::env::consts::EXE_SUFFIX
            ));
        let mut child = Command::new(binary)
            .arg("run")
            .arg(root)
            .arg(root.join("recording.jsonl"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()?;
        let input = child.stdin.take().ok_or("probe_stdin")?;
        let output = child.stdout.take().ok_or("probe_stdout")?;
        let (sender, replies) = mpsc::sync_channel(16);
        thread::spawn(move || {
            for line in BufReader::new(output).lines() {
                let Ok(line) = line else { break };
                let Ok(value) = serde_json::from_str(&line) else {
                    break;
                };
                if sender.send(value).is_err() {
                    break;
                }
            }
        });
        let mut receiver = Self {
            child,
            input,
            replies,
            serial: 0,
            generation: 0,
            recording: root.join("recording.jsonl"),
            recording_start: 0,
        };
        if receiver.replies.recv_timeout(Duration::from_secs(5))?["ready"] != true {
            receiver.child.kill()?;
            return Err("probe_receiver_not_ready".into());
        }
        Ok(receiver)
    }
    fn command(&mut self, body: Value) -> Result<Value, Box<dyn std::error::Error>> {
        self.serial += 1;
        writeln!(
            self.input,
            "{}",
            json!({"version":1,"requestId":format!("probe-{}",self.serial),"body":body})
        )?;
        self.input.flush()?;
        let reply = self.replies.recv_timeout(Duration::from_secs(2))?;
        if reply["ok"] != true {
            return Err("probe_receiver_rejected".into());
        }
        Ok(reply["snapshot"].clone())
    }
    fn activate(&mut self) -> Result<Value, Box<dyn std::error::Error>> {
        self.generation += 1;
        let reply = self.command(json!({"command":"activate","generation":self.generation.to_string(),"revision":self.generation.to_string(),"profileId":"phone-input-test","sessionId":"probe-owner","leaseMs":1750,"inputTtlMs":1500}))?;
        self.recording_start = fs::metadata(&self.recording)?.len();
        Ok(reply)
    }
    fn first_source_sample_neutral(&self) -> Result<bool, Box<dyn std::error::Error>> {
        let mut file = fs::File::open(&self.recording)?;
        file.seek(SeekFrom::Start(self.recording_start))?;
        let mut text = String::new();
        file.take(65_536).read_to_string(&mut text)?;
        // Only complete output records count; the receiver may currently be appending one.
        let Some(last) = text.rfind('\n') else {
            return Ok(false);
        };
        for line in text[..last].lines() {
            let value: Value = serde_json::from_str(line)?;
            if value["reason"] == "sample" {
                if value["reportHex"] != hex(&NEUTRAL) {
                    return Err("probe_first_app_sample_was_not_neutral".into());
                }
                return Ok(true);
            }
        }
        Ok(false)
    }
    fn renew(&mut self) {
        if self.generation > 0 {
            let _ = self.command(json!({"command":"renew","generation":self.generation.to_string(),"sessionId":"probe-owner"}));
        }
    }
    fn wait_report(&mut self, held: bool) -> Result<Value, Box<dyn std::error::Error>> {
        let state: GamepadState = serde_json::from_value(
            json!({"buttons":["south"],"leftStickX":0,"leftStickY":0,"rightStickX":0,"rightStickY":0,"leftTrigger":0,"rightTrigger":0}),
        )?;
        let expected = if held {
            hex(&state.report())
        } else {
            hex(&NEUTRAL)
        };
        let deadline = Instant::now() + Duration::from_secs(1);
        loop {
            self.renew();
            let snapshot = self.command(json!({"command":"status"}))?;
            if snapshot["reportHex"] == expected && snapshot["active"] == held {
                if !held && snapshot["lastReleaseReason"] != "native_input_released" {
                    return Err("probe_release_was_not_native_acknowledged".into());
                }
                return Ok(snapshot);
            }
            if Instant::now() >= deadline {
                return Err("probe_report_timeout".into());
            }
            thread::sleep(Duration::from_millis(5));
        }
    }
}
impl Drop for Receiver {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
struct Root(PathBuf);
impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn emit(value: Value) -> Result<(), Box<dyn std::error::Error>> {
    println!("{value}");
    std::io::stdout().flush()?;
    Ok(())
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = Root(std::env::temp_dir().canonicalize()?.join(format!(
        "thumble-phone-input-probe-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
    )));
    fs::create_dir(&root.0)?;
    let runtime = root.0.join("runtime");
    let mut receiver = Receiver::start(&runtime)?;
    let identity = root.0.join("identity");
    host_identity::load_or_create(&identity)?;
    let mut host = Host::new(&runtime, "synthetic-input", Some(&identity))?;
    let opened = host.execute(HostCommand::PairingListen {
        bind_address: "127.0.0.1:0".into(),
        advertise_host: "127.0.0.1".into(),
    })?;
    emit(
        json!({"scope":"synthetic-loopback-recording-only","port":opened["transport"]["port"],"pin":opened["transport"]["certificatePin"],"authorityInstanceId":"synthetic-input","windowId":opened["offer"]["windowId"],"secret":opened["offer"]["secret"],"expiresAt":opened["offer"]["expiresAt"]}),
    )?;
    let (sender, commands) = mpsc::sync_channel(4);
    thread::spawn(move || {
        let mut byte = [0];
        while std::io::stdin().read_exact(&mut byte).is_ok() {
            if sender.send(byte[0]).is_err() {
                break;
            }
        }
    });
    let expiry = Instant::now() + Duration::from_secs(30);
    loop {
        if Instant::now() >= expiry {
            return Err("probe_deadline".into());
        }
        receiver.renew();
        match commands.recv_timeout(Duration::from_millis(100)) {
            Ok(b'a') => {
                let value = receiver.activate()?;
                emit(
                    json!({"active":true,"generation":value["generation"],"revision":value["revision"]}),
                )?;
            }
            Ok(b'c') => {
                let expiry = Instant::now() + Duration::from_secs(1);
                loop {
                    receiver.renew();
                    let value = receiver.command(json!({"command":"status"}))?;
                    if value["active"] == true
                        && value["reportHex"] == hex(&NEUTRAL)
                        && receiver.first_source_sample_neutral()?
                    {
                        break;
                    }
                    if Instant::now() >= expiry {
                        return Err("probe_app_source_not_neutral".into());
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                emit(json!({"freshNeutral":true,"firstSampleNeutral":true}))?;
            }
            Ok(b'z') => {
                let expiry = Instant::now() + Duration::from_secs(1);
                loop {
                    receiver.renew();
                    let value = receiver.command(json!({"command":"status"}))?;
                    if value["active"] == true
                        && value["reportHex"] == hex(&NEUTRAL)
                        && value["sequence"] == "0"
                    {
                        break;
                    }
                    if Instant::now() >= expiry {
                        return Err("probe_fresh_source_not_neutral".into());
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                emit(json!({"freshNeutral":true}))?;
            }
            Ok(b'h') => {
                let value = receiver.wait_report(true)?;
                emit(json!({"held":true,"reportHex":value["reportHex"],"inputEnabled":false}))?;
            }
            Ok(b'n') => {
                let value = receiver.wait_report(false)?;
                emit(
                    json!({"neutral":true,"reason":value["lastReleaseReason"],"inputEnabled":false}),
                )?;
            }
            Ok(b'f') => {
                emit(json!({"completed":true,"inputEnabled":false}))?;
                break;
            }
            Ok(_) => return Err("probe_command".into()),
            Err(mpsc::RecvTimeoutError::Timeout) => (),
            Err(_) => return Err("probe_closed".into()),
        }
    }
    drop(host);
    drop(receiver);
    Ok(())
}
