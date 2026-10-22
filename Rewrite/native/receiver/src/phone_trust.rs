//! Native credential ledger. Pairing admission and input-session ownership are separate ports.
use crate::{
    control_tls::{ControlChannel, FrameKind},
    host_identity, runtime, security,
};
use ring::{
    digest,
    rand::{SecureRandom, SystemRandom},
};
use rusqlite::{params, Connection, OptionalExtension, Transaction, TransactionBehavior};
use serde::Serialize;
use std::{fs::File, path::Path, time::Duration};
use subtle::ConstantTimeEq;
const APP_ID: i64 = 0x54485431;
const LIFETIME_MS: u64 = 30 * 24 * 60 * 60 * 1000;
const MAX_PHONES: i64 = 32;
const SCHEMA: &str = "
CREATE TABLE trust_meta(id INTEGER PRIMARY KEY CHECK(id=1),host_pin TEXT NOT NULL CHECK(length(host_pin)=64),last_time INTEGER NOT NULL CHECK(last_time>=0)) STRICT;
CREATE TABLE phones(phone_id TEXT PRIMARY KEY NOT NULL CHECK(length(phone_id) BETWEEN 1 AND 64),label TEXT NOT NULL CHECK(length(label) BETWEEN 1 AND 128),epoch INTEGER NOT NULL CHECK(epoch>0),active INTEGER NOT NULL CHECK(active IN (0,1)),verifier BLOB,expires_at INTEGER NOT NULL CHECK(expires_at>0),updated_at INTEGER NOT NULL CHECK(updated_at>=0),CHECK((active=0 AND verifier IS NULL) OR (active=1 AND length(verifier)=32))) STRICT;";
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TrustedPhone {
    pub phone_id: String,
    pub label: String,
    pub credential_epoch: String,
    pub active: bool,
    pub expires_at: u64,
}
/// The secret has no Serialize/Debug/export getter. Only a native TLS channel may carry its reply.
pub struct IssuedCredential {
    phone: TrustedPhone,
    token: [u8; 32],
    host_pin: String,
}
impl IssuedCredential {
    pub fn phone(&self) -> &TrustedPhone {
        &self.phone
    }
    /// Trust has already committed. Failure means delivery is unconfirmed, never rolled back.
    pub fn send_enrollment(&self, channel: &mut ControlChannel) -> Result<(), &'static str> {
        if channel.native_server_pin().map(|p| p.hex()).as_deref() != Some(self.host_pin.as_str()) {
            return Err("phone_credential_delivery_unconfirmed");
        }
        let token = self
            .token
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        let reply = serde_json::json!({"version":1,"command":"enrolled","phoneId":self.phone.phone_id,"credentialEpoch":self.phone.credential_epoch,"expiresAt":self.phone.expires_at,"credential":token});
        channel
            .send(
                FrameKind::Control,
                &serde_json::to_vec(&reply).map_err(|_| "phone_credential_delivery_unconfirmed")?,
            )
            .map_err(|_| "phone_credential_delivery_unconfirmed")
    }
}
pub struct PhoneTrustStore {
    connection: Connection,
    _lease: File,
    host_pin: String,
}
fn error(_: rusqlite::Error) -> &'static str {
    "phone_trust_storage_invalid"
}
pub(crate) fn validate_phone(id: &str, label: &str) -> Result<(), &'static str> {
    if !runtime::identity(id)
        || label.is_empty()
        || label.len() > 128
        || label.chars().any(char::is_control)
    {
        return Err("phone_identity_invalid");
    }
    Ok(())
}
fn verifier(pin: &str, id: &str, token: &[u8]) -> [u8; 32] {
    let mut hash = digest::Context::new(&digest::SHA256);
    hash.update(b"thumble-rewrite/phone-credential/v1\0");
    hash.update(pin.as_bytes());
    hash.update(&[0]);
    hash.update(id.as_bytes());
    hash.update(&[0]);
    hash.update(token);
    hash.finish()
        .as_ref()
        .try_into()
        .expect("SHA-256 is 32 bytes")
}
fn observe(tx: &Transaction<'_>, now: u64, revoking: bool) -> Result<i64, &'static str> {
    let now = i64::try_from(now).map_err(|_| "phone_trust_clock_invalid")?;
    let last: i64 = tx
        .query_row("SELECT last_time FROM trust_meta WHERE id=1", [], |r| {
            r.get(0)
        })
        .map_err(error)?;
    if last < 0 {
        return Err("phone_trust_storage_invalid");
    }
    if now < last && !revoking {
        return Err("phone_trust_clock_rollback");
    }
    let accepted = now.max(last);
    tx.execute("UPDATE trust_meta SET last_time=?1 WHERE id=1", [accepted])
        .map_err(error)?;
    Ok(accepted)
}
fn metadata(row: &rusqlite::Row<'_>) -> rusqlite::Result<TrustedPhone> {
    let epoch: i64 = row.get(2)?;
    let expires: i64 = row.get(4)?;
    let active: i64 = row.get(3)?;
    if epoch <= 0 || expires <= 0 || !(0..=1).contains(&active) {
        return Err(rusqlite::Error::InvalidQuery);
    }
    Ok(TrustedPhone {
        phone_id: row.get(0)?,
        label: row.get(1)?,
        credential_epoch: epoch.to_string(),
        active: active == 1,
        expires_at: expires as u64,
    })
}
impl PhoneTrustStore {
    pub(crate) fn host_pin(&self) -> &str {
        &self.host_pin
    }
    pub fn open(identity_directory: &Path) -> Result<Self, &'static str> {
        let identity = host_identity::load_existing(identity_directory)?;
        let lease = security::file(&identity_directory.join("phone-trust.lock"), false)?;
        fs2::FileExt::try_lock_exclusive(&lease).map_err(|_| "phone_trust_owner_exists")?;
        for name in [
            "phone-trust.sqlite3",
            "phone-trust.sqlite3-journal",
            "phone-trust.sqlite3-wal",
            "phone-trust.sqlite3-shm",
        ] {
            let path = identity_directory.join(name);
            if name == "phone-trust.sqlite3" || std::fs::symlink_metadata(&path).is_ok() {
                let file = security::file(&path, false)?;
                let metadata = file.metadata().map_err(|_| "phone_trust_storage_invalid")?;
                if metadata.len() > 1_048_576 {
                    return Err("phone_trust_storage_invalid");
                }
                #[cfg(unix)]
                {
                    use std::os::unix::fs::MetadataExt;
                    if metadata.nlink() != 1 {
                        return Err("phone_trust_link_rejected");
                    }
                }
            }
        }
        let mut connection =
            Connection::open(identity_directory.join("phone-trust.sqlite3")).map_err(error)?;
        connection.busy_timeout(Duration::ZERO).map_err(error)?;
        connection
            .execute_batch("PRAGMA trusted_schema=OFF; PRAGMA synchronous=EXTRA;")
            .map_err(error)?;
        let app: i64 = connection
            .pragma_query_value(None, "application_id", |r| r.get(0))
            .map_err(error)?;
        let version: i64 = connection
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(error)?;
        if app == 0 && version == 0 {
            let tables: i64 = connection
                .query_row(
                    "SELECT count(*) FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%'",
                    [],
                    |r| r.get(0),
                )
                .map_err(error)?;
            if tables != 0 {
                return Err("phone_trust_foreign_database");
            }
            let tx = connection
                .transaction_with_behavior(TransactionBehavior::Immediate)
                .map_err(error)?;
            tx.execute_batch(SCHEMA).map_err(error)?;
            tx.pragma_update(None, "application_id", APP_ID)
                .map_err(error)?;
            tx.pragma_update(None, "user_version", 1).map_err(error)?;
            tx.execute(
                "INSERT INTO trust_meta VALUES(1,?1,0)",
                [identity.pin().hex()],
            )
            .map_err(error)?;
            tx.commit().map_err(error)?;
        } else if app != APP_ID || version != 1 {
            return Err("phone_trust_version_unsupported");
        }
        connection.execute_batch("PRAGMA journal_mode=DELETE; PRAGMA synchronous=EXTRA; PRAGMA max_page_count=256; PRAGMA foreign_keys=ON;").map_err(error)?;
        let check: String = connection
            .query_row("PRAGMA quick_check", [], |r| r.get(0))
            .map_err(error)?;
        if check != "ok" {
            return Err("phone_trust_storage_invalid");
        }
        let pin: String = connection
            .query_row("SELECT host_pin FROM trust_meta WHERE id=1", [], |r| {
                r.get(0)
            })
            .map_err(error)?;
        if pin != identity.pin().hex() {
            return Err("phone_trust_host_identity_mismatch");
        }
        let count: i64 = connection
            .query_row("SELECT count(*) FROM phones", [], |r| r.get(0))
            .map_err(error)?;
        if count > MAX_PHONES {
            return Err("phone_trust_storage_invalid");
        }
        Ok(Self {
            connection,
            _lease: lease,
            host_pin: pin,
        })
    }
    pub fn list(&self) -> Result<Vec<TrustedPhone>, &'static str> {
        let mut query = self
            .connection
            .prepare("SELECT phone_id,label,epoch,active,expires_at FROM phones ORDER BY phone_id")
            .map_err(error)?;
        let phones = query
            .query_map([], metadata)
            .map_err(error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(error)?;
        for phone in &phones {
            validate_phone(&phone.phone_id, &phone.label)?;
        }
        Ok(phones)
    }
    /// Trusted native operation only: a pinned TLS enrollment coordinator must consume a pairing window first.
    /// `now` is native wall-clock milliseconds, never a timestamp supplied by a peer.
    pub(crate) fn enroll_after_pairing(
        &mut self,
        id: &str,
        label: &str,
        now: u64,
    ) -> Result<IssuedCredential, &'static str> {
        validate_phone(id, label)?;
        let expires = now
            .checked_add(LIFETIME_MS)
            .and_then(|v| i64::try_from(v).ok())
            .ok_or("phone_trust_clock_invalid")?;
        let mut token = [0; 32];
        SystemRandom::new()
            .fill(&mut token)
            .map_err(|_| "phone_credential_entropy_failed")?;
        let hash = verifier(&self.host_pin, id, &token);
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(error)?;
        let now = observe(&tx, now, false)?;
        let old: Option<i64> = tx
            .query_row("SELECT epoch FROM phones WHERE phone_id=?1", [id], |r| {
                r.get(0)
            })
            .optional()
            .map_err(error)?;
        if old.is_none() {
            let count: i64 = tx
                .query_row("SELECT count(*) FROM phones", [], |r| r.get(0))
                .map_err(error)?;
            if count >= MAX_PHONES {
                return Err("phone_trust_capacity_exhausted");
            }
        }
        let epoch = old
            .unwrap_or(0)
            .checked_add(1)
            .ok_or("phone_credential_epoch_exhausted")?;
        tx.execute("INSERT INTO phones VALUES(?1,?2,?3,1,?4,?5,?6) ON CONFLICT(phone_id) DO UPDATE SET label=excluded.label,epoch=excluded.epoch,active=1,verifier=excluded.verifier,expires_at=excluded.expires_at,updated_at=excluded.updated_at",params![id,label,epoch,hash.as_slice(),expires,now]).map_err(error)?;
        tx.commit().map_err(error)?;
        Ok(IssuedCredential {
            host_pin: self.host_pin.clone(),
            phone: TrustedPhone {
                phone_id: id.into(),
                label: label.into(),
                credential_epoch: epoch.to_string(),
                active: true,
                expires_at: expires as u64,
            },
            token,
        })
    }
    pub fn authenticate(
        &mut self,
        id: &str,
        token: &[u8],
        now: u64,
    ) -> Result<TrustedPhone, &'static str> {
        if !runtime::identity(id) || token.len() != 32 {
            return Err("phone_authentication_rejected");
        }
        let candidate = verifier(&self.host_pin, id, token);
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(error)?;
        let now = observe(&tx, now, false)?;
        let row:Option<(TrustedPhone,Option<Vec<u8>>)>=tx.query_row("SELECT phone_id,label,epoch,active,expires_at,verifier FROM phones WHERE phone_id=?1",[id],|r|Ok((metadata(r)?,r.get(5)?))).optional().map_err(error)?;
        let stored = row
            .as_ref()
            .and_then(|(_, v)| v.as_deref())
            .and_then(|v| <&[u8; 32]>::try_from(v).ok())
            .copied();
        let expected = stored.unwrap_or([0; 32]);
        let valid = bool::from(candidate.ct_eq(&expected)) && stored.is_some();
        let phone = row
            .map(|(p, _)| p)
            .filter(|p| valid && p.active && (now as u64) < p.expires_at)
            .ok_or("phone_authentication_rejected")?;
        tx.commit().map_err(error)?;
        Ok(phone)
    }
    /// Recheck native connection authorization without retaining its bearer credential.
    pub(crate) fn authorize_epoch(
        &mut self,
        id: &str,
        epoch: &str,
        now: u64,
    ) -> Result<TrustedPhone, &'static str> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(error)?;
        let now = observe(&tx, now, false)?;
        let phone = tx
            .query_row(
                "SELECT phone_id,label,epoch,active,expires_at FROM phones WHERE phone_id=?1",
                [id],
                metadata,
            )
            .optional()
            .map_err(error)?
            .filter(|p| p.active && p.credential_epoch == epoch && (now as u64) < p.expires_at)
            .ok_or("phone_authentication_rejected")?;
        tx.commit().map_err(error)?;
        Ok(phone)
    }
    /// Persist revocation even if wall time moved backward. Runtime release is the native session owner's job.
    pub fn revoke(&mut self, id: &str, now: u64) -> Result<(), &'static str> {
        if !runtime::identity(id) {
            return Err("phone_identity_invalid");
        }
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(error)?;
        let now = observe(&tx, now, true)?;
        if tx
            .execute(
                "UPDATE phones SET active=0,verifier=NULL,updated_at=?2 WHERE phone_id=?1",
                params![id, now],
            )
            .map_err(error)?
            != 1
        {
            return Err("phone_not_found");
        }
        tx.commit().map_err(error)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        net::TcpListener,
        sync::atomic::{AtomicU64, Ordering},
        thread,
    };
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Root(std::path::PathBuf);
    impl Root {
        fn new() -> Self {
            let root = Self(std::env::temp_dir().canonicalize().unwrap().join(format!(
                "thumble-trust-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            )));
            host_identity::load_or_create(&root.0).unwrap();
            root
        }
    }
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn sqlite_uses_pinned_native_engine_and_durable_bounded_private_storage() {
        let root = Root::new();
        let store = PhoneTrustStore::open(&root.0).unwrap();
        assert_eq!(rusqlite::version(), "3.53.2");
        for (name, expected) in [
            ("synchronous", 3i64),
            ("trusted_schema", 0),
            ("foreign_keys", 1),
            ("max_page_count", 256),
        ] {
            let actual: i64 = store
                .connection
                .pragma_query_value(None, name, |r| r.get(0))
                .unwrap();
            assert_eq!(actual, expected);
        }
        let mode: String = store
            .connection
            .pragma_query_value(None, "journal_mode", |r| r.get(0))
            .unwrap();
        assert_eq!(mode, "delete");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(root.0.join("phone-trust.sqlite3"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o600
            );
        }
    }
    #[test]
    fn credential_commits_reloads_and_never_persists_plaintext_or_exports_it_as_metadata() {
        let root = Root::new();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        let credential = store
            .enroll_after_pairing("phone-a", "Controller", 100)
            .unwrap();
        assert_eq!(credential.phone().credential_epoch, "1");
        assert_eq!(
            store
                .authenticate("phone-a", &credential.token, 101)
                .unwrap()
                .phone_id,
            "phone-a"
        );
        let metadata = serde_json::to_string(&store.list().unwrap()).unwrap();
        assert!(!metadata.contains("verifier") && !metadata.contains("credential\""));
        drop(store);
        let bytes = fs::read(root.0.join("phone-trust.sqlite3")).unwrap();
        assert!(!bytes.windows(32).any(|v| v == credential.token));
        let hex = credential
            .token
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>();
        assert!(!bytes.windows(hex.len()).any(|v| v == hex.as_bytes()));
        assert!(!metadata.contains(&hex));
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        assert!(store
            .authenticate("phone-a", &credential.token, 102)
            .is_ok());
        assert!(store
            .authenticate("phone-b", &credential.token, 102)
            .is_err());
        assert!(store.authenticate("phone-a", &[0; 32], 102).is_err());
    }
    #[test]
    fn reenrollment_rotates_old_credentials_and_revocation_survives_restart_and_clock_rollback() {
        let root = Root::new();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        let old = store.enroll_after_pairing("phone-a", "Old", 10).unwrap();
        let fresh = store.enroll_after_pairing("phone-a", "New", 20).unwrap();
        assert!(old.token != fresh.token);
        assert_eq!(fresh.phone().credential_epoch, "2");
        assert!(store.authenticate("phone-a", &old.token, 21).is_err());
        assert!(store.authenticate("phone-a", &fresh.token, 22).is_ok());
        assert_eq!(
            store.authenticate("phone-a", &fresh.token, 21).err(),
            Some("phone_trust_clock_rollback")
        );
        store.revoke("phone-a", 1).unwrap();
        drop(store);
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        assert!(!store.list().unwrap()[0].active);
        assert!(store.authenticate("phone-a", &fresh.token, 23).is_err());
        let restored = store
            .enroll_after_pairing("phone-a", "Restored", 24)
            .unwrap();
        assert_eq!(restored.phone().credential_epoch, "3");
        assert!(store.authenticate("phone-a", &fresh.token, 25).is_err());
        assert!(store.authenticate("phone-a", &restored.token, 25).is_ok());
    }
    #[test]
    fn expiry_and_native_clock_limits_fail_without_partial_mutations() {
        let root = Root::new();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        let credential = store.enroll_after_pairing("phone-a", "A", 100).unwrap();
        assert!(store
            .authenticate("phone-a", &credential.token, 100 + LIFETIME_MS - 1)
            .is_ok());
        assert!(store
            .authenticate("phone-a", &credential.token, 100 + LIFETIME_MS)
            .is_err());
        assert!(store
            .enroll_after_pairing("phone-b", "B", u64::MAX)
            .is_err());
        assert!(store.enroll_after_pairing("phone-b", "B", 1).is_err());
        assert_eq!(store.list().unwrap().len(), 1);
    }
    #[test]
    fn capacity_and_malformed_identities_are_bounded() {
        let root = Root::new();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        for (id, label) in [
            ("", "A"),
            ("bad/id", "A"),
            ("phone-a", ""),
            ("phone-a", "line\nfeed"),
        ] {
            assert!(store.enroll_after_pairing(id, label, 0).is_err());
        }
        assert!(store
            .enroll_after_pairing("phone-a", &"x".repeat(129), 0)
            .is_err());
        for i in 0..MAX_PHONES {
            store
                .enroll_after_pairing(&format!("phone-{i}"), "Phone", 0)
                .unwrap();
        }
        assert_eq!(
            store.enroll_after_pairing("extra", "Phone", 0).err(),
            Some("phone_trust_capacity_exhausted")
        );
        store.enroll_after_pairing("phone-0", "Rotated", 1).unwrap();
        assert_eq!(store.list().unwrap().len(), MAX_PHONES as usize);
        assert_eq!(store.revoke("missing", 1).err(), Some("phone_not_found"));
    }
    #[test]
    fn failed_commit_rolls_back_verifier_epoch_and_observed_clock() {
        let root = Root::new();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        let credential = store.enroll_after_pairing("phone-a", "A", 10).unwrap();
        store.connection.execute_batch("CREATE TRIGGER reject_fixture BEFORE INSERT ON phones BEGIN SELECT RAISE(ABORT,'fixture'); END;").unwrap();
        assert!(store
            .enroll_after_pairing("phone-a", "Replacement", 1000)
            .is_err());
        store
            .connection
            .execute_batch("DROP TRIGGER reject_fixture;")
            .unwrap();
        assert!(store.authenticate("phone-a", &credential.token, 11).is_ok());
        assert_eq!(store.list().unwrap()[0].credential_epoch, "1");
    }
    #[test]
    fn exclusive_owner_and_host_identity_binding_are_enforced() {
        let a = Root::new();
        let b = Root::new();
        let mut store = PhoneTrustStore::open(&a.0).unwrap();
        store.enroll_after_pairing("phone-a", "A", 0).unwrap();
        assert_eq!(
            PhoneTrustStore::open(&a.0).err(),
            Some("phone_trust_owner_exists")
        );
        drop(store);
        fs::copy(
            a.0.join("phone-trust.sqlite3"),
            b.0.join("phone-trust.sqlite3"),
        )
        .unwrap();
        assert_eq!(
            PhoneTrustStore::open(&b.0).err(),
            Some("phone_trust_host_identity_mismatch")
        );
    }
    #[test]
    fn foreign_schemas_and_corruption_are_rejected_without_replacing_data() {
        let root = Root::new();
        let path = root.0.join("phone-trust.sqlite3");
        let connection = Connection::open(&path).unwrap();
        connection.execute_batch("CREATE TABLE foreign_data(value TEXT);INSERT INTO foreign_data VALUES('preserved');").unwrap();
        drop(connection);
        assert_eq!(
            PhoneTrustStore::open(&root.0).err(),
            Some("phone_trust_foreign_database")
        );
        let connection = Connection::open(&path).unwrap();
        assert_eq!(
            connection
                .query_row("SELECT value FROM foreign_data", [], |r| r
                    .get::<_, String>(0))
                .unwrap(),
            "preserved"
        );
        drop(connection);
        fs::write(&path, b"corrupt-owned-db").unwrap();
        assert!(PhoneTrustStore::open(&root.0).is_err());
        assert_eq!(fs::read(path).unwrap(), b"corrupt-owned-db");
    }
    #[test]
    fn actual_tls_receives_only_after_native_commit_and_wrong_channel_cannot_export_secret() {
        let root = Root::new();
        let identity = host_identity::load_existing(&root.0).unwrap();
        let pin = identity.pin();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let path = root.0.clone();
        let server = thread::spawn(move || {
            let mut channel =
                ControlChannel::accept_unenrolled(listener.accept().unwrap().0, &identity).unwrap();
            let mut store = PhoneTrustStore::open(&path).unwrap();
            let credential = store.enroll_after_pairing("phone-a", "A", 10).unwrap();
            assert!(store.authenticate("phone-a", &credential.token, 11).is_ok());
            credential.send_enrollment(&mut channel).unwrap();
        });
        let mut client = ControlChannel::connect_pinned(address, pin).unwrap();
        let frame = client.receive().unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&frame.payload).unwrap();
        assert_eq!(reply["command"], "enrolled");
        let hex = reply["credential"].as_str().unwrap();
        let token = hex
            .as_bytes()
            .chunks_exact(2)
            .map(|v| u8::from_str_radix(std::str::from_utf8(v).unwrap(), 16).unwrap())
            .collect::<Vec<_>>();
        server.join().unwrap();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        assert!(store.authenticate("phone-a", &token, 12).is_ok());
        let credential = store.enroll_after_pairing("phone-b", "B", 13).unwrap();
        assert_eq!(
            credential.send_enrollment(&mut client).err(),
            Some("phone_credential_delivery_unconfirmed")
        );
        assert!(store.authenticate("phone-b", &credential.token, 14).is_ok());
    }
    #[cfg(unix)]
    #[test]
    fn credential_database_symlinks_and_aliases_do_not_cross_native_storage() {
        let root = Root::new();
        let path = root.0.join("phone-trust.sqlite3");
        std::os::unix::fs::symlink(root.0.join("identity.bin"), &path).unwrap();
        assert!(PhoneTrustStore::open(&root.0).is_err());
        fs::remove_file(&path).unwrap();
        fs::hard_link(root.0.join("identity.bin"), &path).unwrap();
        assert_eq!(
            PhoneTrustStore::open(&root.0).err(),
            Some("host_identity_link_rejected")
        );
        host_identity::load_existing(&root.0).err().unwrap();
    }
}
