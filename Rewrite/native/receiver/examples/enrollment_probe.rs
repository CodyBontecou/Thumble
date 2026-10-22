//! Synthetic loopback enrollment witness. Never installed as a product listener.
use std::{
    io::Write,
    net::{Ipv4Addr, TcpListener},
    path::PathBuf,
    sync::Mutex,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use thumble_rewrite_receiver::{
    control_tls::ControlChannel,
    enrollment::{self, PairingWindows},
    host_identity,
    phone_trust::PhoneTrustStore,
};
struct Root(PathBuf);
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn now() -> Result<u64, &'static str> {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "clock_failed")?
            .as_millis(),
    )
    .map_err(|_| "clock_failed")
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = Root(std::env::temp_dir().canonicalize()?.join(format!(
        "thumble-enrollment-probe-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
    )));
    let identity = host_identity::load_or_create(&root.0)?;
    let store = Mutex::new(PhoneTrustStore::open(&root.0)?);
    let mut windows = PairingWindows::new("synthetic-enrollment", identity.pin())?;
    let offer = windows.open(now()?)?;
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))?;
    listener.set_nonblocking(true)?;
    println!(
        "{}",
        serde_json::json!({"scope":"synthetic-loopback-only","port":listener.local_addr()?.port(),"pin":identity.pin().hex(),"certificateDER":identity.certificate_der().iter().map(|b|format!("{b:02x}")).collect::<String>(),"authorityInstanceId":"synthetic-enrollment","windowId":offer.window_id,"secret":offer.secret,"expiresAt":offer.expires_at})
    );
    std::io::stdout().flush()?;
    let deadline = Instant::now() + Duration::from_secs(5);
    let stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                thread::sleep(Duration::from_millis(5))
            }
            Err(_) => return Err("accept_failed".into()),
        }
    };
    let mut channel =
        ControlChannel::accept_unenrolled(stream, &identity).map_err(|_| "tls_failed")?;
    let result = enrollment::enroll(
        &mut channel,
        &Mutex::new(windows),
        &store,
        &Mutex::new(()),
        now,
    );
    match result {
        Ok(phone) => println!(
            "{}",
            serde_json::json!({"completed":true,"phoneId":phone.phone_id,"credentialEpoch":phone.credential_epoch,"inputEnabled":false})
        ),
        Err(code) => println!(
            "{}",
            serde_json::json!({"completed":false,"error":code,"inputEnabled":false})
        ),
    }
    drop(store);
    Ok(())
}
