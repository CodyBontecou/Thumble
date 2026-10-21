//! Loopback-only synthetic interoperability witness; never installed with the product binaries.
use serde_json::{json, Value};
use std::{
    io::Write,
    net::{Ipv4Addr, TcpListener},
    thread,
    time::{Duration, Instant},
};
use thumble_rewrite_receiver::{
    control_tls::{ControlChannel, FrameKind, ServerIdentity},
    input_packet::PacketGrant,
    packet_runtime::PacketRuntime,
    runtime::Output,
};
struct Recording;
impl Output for Recording {
    fn submit(&mut self, _: [u8; 20], _: &'static str) -> Result<(), &'static str> {
        Ok(())
    }
}
fn bytes(value: &Value) -> Vec<u8> {
    let s = value.as_str().unwrap();
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let identity = ServerIdentity::generate().map_err(|_| "identity_failed")?;
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    listener.set_nonblocking(true)?;
    println!(
        "{}",
        json!({"version":1,"scope":"synthetic-loopback-only","inputEnabled":false,"port":listener.local_addr()?.port(),"pin":identity.pin().hex(),"certificateDER":identity.certificate_der().iter().map(|b|format!("{b:02x}")).collect::<String>()})
    );
    std::io::stdout().flush()?;
    let deadline = Instant::now() + Duration::from_secs(5);
    let socket = loop {
        match listener.accept() {
            Ok((socket, _)) => break socket,
            Err(error)
                if error.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline =>
            {
                thread::sleep(Duration::from_millis(5))
            }
            Err(_) => return Err("accept_failed".into()),
        }
    };
    let mut channel = match ControlChannel::accept_unenrolled(socket, &identity) {
        Ok(c) => c,
        Err(_) => {
            println!(
                "{}",
                json!({"version":1,"scope":"synthetic-loopback-only","handshakeRejected":true})
            );
            return Ok(());
        }
    };
    // Public deterministic packet fixture grant. No trust enrollment or OS input occurs.
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../packages/fixtures/input-packet-v1.json"
    ))?;
    let grant = PacketGrant::new(
        &bytes(&fixture["keyHex"])
            .try_into()
            .map_err(|_| "key_size")?,
        bytes(&fixture["sessionHex"])
            .try_into()
            .map_err(|_| "session_size")?,
        bytes(&fixture["noncePrefixHex"])
            .try_into()
            .map_err(|_| "prefix_size")?,
        fixture["generation"]
            .as_str()
            .ok_or("generation")?
            .parse()?,
    )
    .map_err(|_| "grant_failed")?;
    let mut runtime = PacketRuntime::default();
    let mut output = Recording;
    runtime
        .activate(grant, 1, "synthetic-tls-probe".into(), 0, &mut output)
        .map_err(|_| "activation_failed")?;
    for now in 1..=16 {
        let frame = match channel.receive() {
            Ok(f) => f,
            Err(_) => break,
        };
        match frame.kind {
            FrameKind::Control => channel
                .send(FrameKind::Control, &frame.payload)
                .map_err(|_| "echo_failed")?,
            FrameKind::Input => {
                let result = runtime.receive(&frame.payload, now, &mut output);
                let response = json!({"version":1,"scope":"synthetic-loopback-only","ok":result.is_ok(),"error":result.err(),"snapshot":runtime.snapshot()});
                channel
                    .send(FrameKind::Control, &serde_json::to_vec(&response)?)
                    .map_err(|_| "response_failed")?;
            }
        }
    }
    runtime.release(&mut output).map_err(|_| "release_failed")?;
    println!(
        "{}",
        json!({"version":1,"scope":"synthetic-loopback-only","closed":true,"reportHex":runtime.snapshot().report_hex})
    );
    Ok(())
}
