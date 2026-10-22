//! Synthetic native host witness. Never installed as a product executable.
use std::{
    io::{Read, Write},
    path::PathBuf,
    sync::mpsc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use thumble_rewrite_receiver::{
    host_identity,
    pairing_host::{Command, Host},
};
struct Root(PathBuf);
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = Root(std::env::temp_dir().canonicalize()?.join(format!(
        "thumble-phone-control-probe-{}-{}",
        std::process::id(),
        SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos()
    )));
    std::fs::create_dir(&root.0)?;
    let identity = root.0.join("identity");
    host_identity::load_or_create(&identity)?;
    let mut host = Host::new(
        &root.0.join("runtime"),
        "synthetic-control",
        Some(&identity),
    )?;
    let opened = host.execute(Command::PairingListen {
        bind_address: "127.0.0.1:0".into(),
        advertise_host: "127.0.0.1".into(),
    })?;
    println!(
        "{}",
        serde_json::json!({"scope":"synthetic-loopback-only","port":opened["transport"]["port"],"pin":opened["transport"]["certificatePin"],"authorityInstanceId":"synthetic-control","windowId":opened["offer"]["windowId"],"secret":opened["offer"]["secret"],"expiresAt":opened["offer"]["expiresAt"]})
    );
    std::io::stdout().flush()?;
    let (sender, receiver) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut byte = [0];
        let _ = sender.send(std::io::stdin().read_exact(&mut byte).is_ok() && byte[0] == b'f');
    });
    if !receiver
        .recv_timeout(Duration::from_secs(30))
        .unwrap_or(false)
    {
        return Err("probe_finish_failed".into());
    }
    let inventory = host.execute(Command::PairingList {})?;
    if inventory["phones"][0]["active"] != true {
        return Err("probe_trust_missing".into());
    }
    println!(
        "{}",
        serde_json::json!({"completed":true,"inputEnabled":false})
    );
    drop(host);
    Ok(())
}
