//! Persistent gateway state (SQLite, single-writer).
//!
//! Every secret is stored as a SHA-256 digest, never in the clear:
//! device tokens, OAuth authorization codes, access tokens, and refresh
//! tokens. Rotation ancestry for refresh tokens enables reuse detection.

use std::path::Path;
use std::sync::Mutex;

use hmac::{Hmac, Mac as _};
use rusqlite::Connection;
use sha2::Sha256;
use thumble_tunnel::token_digest;

const SCHEMA: &str = r#"
CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    token_digest TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    last_seen_at INTEGER NOT NULL,
    revoked INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS oauth_clients (
    client_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    redirect_uris TEXT NOT NULL,
    created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS authorization_requests (
    request_digest TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    redirect_uri TEXT NOT NULL,
    state TEXT NOT NULL,
    scope TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    used INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS auth_codes (
    code_digest TEXT PRIMARY KEY,
    client_id TEXT NOT NULL,
    redirect_uri TEXT NOT NULL,
    scope TEXT NOT NULL,
    code_challenge TEXT NOT NULL,
    device_id TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    used INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS access_tokens (
    token_digest TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    scope TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    revoked INTEGER NOT NULL DEFAULT 0,
    family_id TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS refresh_tokens (
    token_digest TEXT PRIMARY KEY,
    device_id TEXT NOT NULL,
    client_id TEXT NOT NULL,
    scope TEXT NOT NULL,
    expires_at INTEGER NOT NULL,
    rotated_from TEXT,
    revoked INTEGER NOT NULL DEFAULT 0,
    rotated_at INTEGER NOT NULL DEFAULT 0,
    family_id TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS link_codes (
    code_digest TEXT PRIMARY KEY,
    pending_key TEXT NOT NULL,
    device_name TEXT NOT NULL,
    created_at INTEGER NOT NULL,
    expires_at INTEGER NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    used INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS manifests (
    device_id TEXT PRIMARY KEY,
    tools TEXT NOT NULL,
    resources TEXT NOT NULL,
    instructions TEXT,
    updated_at INTEGER NOT NULL
);
"#;

#[derive(Debug)]
pub struct DeviceRecord {
    pub id: String,
    pub name: String,
}

#[derive(Debug)]
pub struct ClientRecord {
    pub client_id: String,
    pub name: String,
    pub redirect_uris: Vec<String>,
}

#[derive(Debug)]
pub struct AuthorizationRequestRecord {
    pub client_id: String,
    pub redirect_uri: String,
    pub state: String,
    pub scope: String,
    pub code_challenge: String,
}

#[derive(Debug)]
pub struct AuthCodeRecord {
    pub client_id: String,
    pub redirect_uri: String,
    pub scope: String,
    pub code_challenge: String,
    pub device_id: String,
}

#[derive(Debug)]
pub struct AuthorizationTokenGrant {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub scope: String,
    pub device_id: String,
}

#[derive(Debug)]
pub struct AccessTokenRecord {
    pub device_id: String,
    pub scope: String,
}

#[derive(Debug)]
pub struct RefreshTokenRecord {
    pub device_id: String,
    pub client_id: String,
    pub scope: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct ManifestRecord {
    pub tools: Vec<serde_json::Value>,
    pub resources: Vec<serde_json::Value>,
    pub instructions: Option<String>,
}

pub struct Store {
    connection: Mutex<Connection>,
    link_secret: Vec<u8>,
    /// How long after a rotation the previous refresh token may be exchanged
    /// again by a concurrent legitimate client. Multi-window clients such as
    /// the ChatGPT desktop app share one token cache across chat runtimes;
    /// without this window, two simultaneous refreshes read as token theft
    /// and revoke the whole session family. Replays after the window (or
    /// beyond the successor budget) still revoke everything.
    refresh_grace_seconds: i64,
}

/// Default concurrent-refresh grace window in seconds.
const DEFAULT_REFRESH_GRACE_SECONDS: i64 = 60;
/// Maximum live successors one rotated refresh token may mint inside the
/// grace window (original exchange plus this many concurrent peers).
const MAXIMUM_GRACE_SUCCESSORS: i64 = 4;

fn prune_expired_oauth(connection: &Connection, now: i64) -> Result<(), String> {
    connection
        .execute(
            "DELETE FROM authorization_requests WHERE used = 1 OR expires_at < ?1",
            rusqlite::params![now],
        )
        .map_err(|error| format!("prune authorization requests: {error}"))?;
    connection
        .execute(
            "DELETE FROM auth_codes WHERE used = 1 OR expires_at < ?1",
            rusqlite::params![now],
        )
        .map_err(|error| format!("prune authorization codes: {error}"))?;
    connection
        .execute(
            "DELETE FROM access_tokens WHERE revoked = 1 OR expires_at < ?1",
            rusqlite::params![now],
        )
        .map_err(|error| format!("prune access tokens: {error}"))?;
    connection
        .execute(
            "DELETE FROM refresh_tokens WHERE expires_at < ?1",
            rusqlite::params![now],
        )
        .map_err(|error| format!("prune refresh tokens: {error}"))?;
    connection
        .execute(
            "DELETE FROM oauth_clients \
             WHERE created_at < ?1 \
               AND client_id NOT IN (SELECT client_id FROM refresh_tokens) \
               AND client_id NOT IN (SELECT client_id FROM auth_codes)",
            rusqlite::params![now - 180 * 24 * 60 * 60],
        )
        .map_err(|error| format!("prune inactive OAuth clients: {error}"))?;
    Ok(())
}

fn require_active_device(connection: &Connection, device_id: &str) -> Result<(), String> {
    match connection.query_row(
        "SELECT revoked FROM devices WHERE id = ?1",
        rusqlite::params![device_id],
        |row| row.get::<_, i64>(0),
    ) {
        Ok(0) => Ok(()),
        Ok(_) => Err("device is revoked".to_owned()),
        Err(rusqlite::Error::QueryReturnedNoRows) => Err("unknown device".to_owned()),
        Err(error) => Err(format!("inspect device state: {error}")),
    }
}

fn validate_link_secret(secret: &str) -> Result<(), String> {
    if secret.len() < 32 {
        Err("THUMBLE_GATEWAY_TOKEN_SECRET must contain at least 32 characters".to_owned())
    } else {
        Ok(())
    }
}

fn validate_redirect_uri(uri: &str) -> Result<(), String> {
    if uri.len() > 2048 {
        return Err("redirect_uri exceeds 2048 characters".to_owned());
    }
    let parsed = url::Url::parse(uri).map_err(|_| "redirect_uri is not an absolute URI")?;
    if parsed.fragment().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.host_str().is_none()
    {
        return Err("redirect_uri must not contain credentials or a fragment".to_owned());
    }
    match parsed.scheme() {
        "https" => Ok(()),
        "http" if matches!(parsed.host_str(), Some("localhost" | "127.0.0.1" | "::1")) => Ok(()),
        _ => Err("redirect_uri must use https (or exact loopback http for development)".to_owned()),
    }
}

impl Store {
    pub fn open(path: &Path, link_secret: &str) -> Result<Self, String> {
        validate_link_secret(link_secret)?;
        let connection = Connection::open(path)
            .map_err(|error| format!("open gateway database {}: {error}", path.display()))?;
        Self::with_connection(connection, link_secret)
    }

    pub fn open_in_memory() -> Result<Self, String> {
        let connection =
            Connection::open_in_memory().map_err(|e| format!("open memory db: {e}"))?;
        Self::with_connection(connection, "gateway-test-link-secret-32-bytes-minimum")
    }

    fn with_connection(connection: Connection, link_secret: &str) -> Result<Self, String> {
        connection
            .execute_batch(SCHEMA)
            .map_err(|error| format!("initialize gateway database: {error}"))?;
        // Additive migrations keep live volume-backed deployments compatible.
        // Legacy tokens share an empty family; newly authorized grants always
        // receive an isolated random family below.
        for statement in [
            "ALTER TABLE refresh_tokens ADD COLUMN rotated_at INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE refresh_tokens ADD COLUMN family_id TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE access_tokens ADD COLUMN family_id TEXT NOT NULL DEFAULT ''",
        ] {
            if let Err(error) = connection.execute(statement, []) {
                if !error.to_string().contains("duplicate column") {
                    return Err(format!("migrate gateway database: {error}"));
                }
            }
        }
        Ok(Self {
            connection: Mutex::new(connection),
            link_secret: link_secret.as_bytes().to_vec(),
            refresh_grace_seconds: DEFAULT_REFRESH_GRACE_SECONDS,
        })
    }

    /// Override the concurrent-refresh grace window (0 disables it and keeps
    /// strict replay-revocation semantics).
    pub fn with_refresh_grace(mut self, seconds: i64) -> Self {
        self.refresh_grace_seconds = seconds.clamp(0, 3600);
        self
    }

    fn link_code_digest(&self, code: &str) -> String {
        let mut mac = Hmac::<Sha256>::new_from_slice(&self.link_secret)
            .expect("HMAC accepts keys of any length");
        mac.update(code.as_bytes());
        mac.finalize()
            .into_bytes()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect()
    }

    fn new_token_family_id() -> String {
        token_digest(&thumble_tunnel::random_token(24))
    }

    fn now() -> i64 {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_secs() as i64)
            .unwrap_or(0)
    }

    pub fn create_device(&self, name: &str) -> Result<(String, String), String> {
        let device_id = format!("dev_{}", thumble_tunnel::random_token(12));
        let token = thumble_tunnel::random_token(32);
        let now = Self::now();
        self.connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO devices (id, token_digest, name, created_at, last_seen_at, revoked) \
                 VALUES (?1, ?2, ?3, ?4, ?4, 0)",
                rusqlite::params![device_id, token_digest(&token), name, now],
            )
            .map_err(|e| format!("create device: {e}"))?;
        Ok((device_id, token))
    }

    /// Look up a device by bearer token. Returns None for unknown or revoked.
    pub fn device_for_token(&self, token: &str) -> Result<Option<DeviceRecord>, String> {
        let digest = token_digest(token);
        self.connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT id, name FROM devices WHERE token_digest = ?1 AND revoked = 0",
                rusqlite::params![digest],
                |row| {
                    Ok(DeviceRecord {
                        id: row.get(0)?,
                        name: row.get(1)?,
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("lookup device: {other}")),
            })
    }

    /// Look up an active device by id (name and liveness bookkeeping).
    pub fn device(&self, device_id: &str) -> Result<Option<DeviceRecord>, String> {
        self.connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT id, name FROM devices WHERE id = ?1 AND revoked = 0",
                rusqlite::params![device_id],
                |row| {
                    Ok(DeviceRecord {
                        id: row.get(0)?,
                        name: row.get(1)?,
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("lookup device by id: {other}")),
            })
    }

    pub fn touch_device(&self, device_id: &str) -> Result<(), String> {
        self.connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE devices SET last_seen_at = ?2 WHERE id = ?1",
                rusqlite::params![device_id, Self::now()],
            )
            .map_err(|e| format!("touch device: {e}"))?;
        Ok(())
    }

    /// Replace the credential of an existing (non-revoked) device in place.
    ///
    /// Rotation keeps the same device identity and OAuth bindings while the
    /// old bearer token stops working the moment the digest row is replaced.
    /// There is never a window in which both the old and the new token are
    /// valid, and a failed rotation leaves the previous token untouched.
    pub fn rotate_device_token(&self, device_id: &str, name: &str) -> Result<String, String> {
        let token = thumble_tunnel::random_token(32);
        let updated = self
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE devices SET token_digest = ?2, name = ?3, last_seen_at = ?4 \
                 WHERE id = ?1 AND revoked = 0",
                rusqlite::params![device_id, token_digest(&token), name, Self::now()],
            )
            .map_err(|e| format!("rotate device token: {e}"))?;
        if updated != 1 {
            return Err("device is revoked or unknown; link it again".to_owned());
        }
        Ok(token)
    }

    /// Revoke a device and every token family bound to it.
    pub fn revoke_device(&self, device_id: &str) -> Result<(), String> {
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin device revocation: {error}"))?;
        transaction
            .execute(
                "UPDATE devices SET revoked = 1 WHERE id = ?1",
                rusqlite::params![device_id],
            )
            .map_err(|e| format!("revoke device: {e}"))?;
        transaction
            .execute(
                "UPDATE access_tokens SET revoked = 1 WHERE device_id = ?1",
                rusqlite::params![device_id],
            )
            .map_err(|e| format!("revoke device access tokens: {e}"))?;
        transaction
            .execute(
                "UPDATE refresh_tokens SET revoked = 1 WHERE device_id = ?1",
                rusqlite::params![device_id],
            )
            .map_err(|e| format!("revoke device refresh tokens: {e}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit device revocation: {error}"))?;
        Ok(())
    }

    pub fn register_client(
        &self,
        name: &str,
        redirect_uris: Vec<String>,
    ) -> Result<String, String> {
        if name.is_empty() || name.len() > 128 {
            return Err("client_name must be 1-128 characters".to_owned());
        }
        if redirect_uris.is_empty() || redirect_uris.len() > 8 {
            return Err("redirect_uris must contain 1-8 exact URIs".to_owned());
        }
        let mut unique = std::collections::HashSet::new();
        for uri in &redirect_uris {
            if !unique.insert(uri) {
                return Err("redirect_uris must not contain duplicates".to_owned());
            }
            validate_redirect_uri(uri)?;
        }
        let client_id = format!("cc_{}", thumble_tunnel::random_token(16));
        let now = Self::now();
        let connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        let client_count: i64 = connection
            .query_row("SELECT COUNT(*) FROM oauth_clients", [], |row| row.get(0))
            .map_err(|error| format!("count OAuth clients: {error}"))?;
        if client_count >= 10_000 {
            return Err("dynamic client registration capacity reached".to_owned());
        }
        connection
            .execute(
                "INSERT INTO oauth_clients (client_id, name, redirect_uris, created_at) \
                 VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![
                    client_id,
                    name,
                    serde_json::to_string(&redirect_uris).unwrap(),
                    now
                ],
            )
            .map_err(|e| format!("register client: {e}"))?;
        Ok(client_id)
    }

    pub fn client(&self, client_id: &str) -> Result<Option<ClientRecord>, String> {
        self.connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT client_id, name, redirect_uris FROM oauth_clients WHERE client_id = ?1",
                rusqlite::params![client_id],
                |row| {
                    Ok(ClientRecord {
                        client_id: row.get(0)?,
                        name: row.get(1)?,
                        redirect_uris: serde_json::from_str(&row.get::<_, String>(2)?)
                            .unwrap_or_default(),
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("lookup client: {other}")),
            })
    }

    pub fn create_link_code(
        &self,
        pending_key: &str,
        device_name: &str,
        ttl_seconds: i64,
        max_existing: usize,
    ) -> Result<String, String> {
        let connection = self.connection.lock().unwrap();
        let now = Self::now();
        connection
            .execute(
                "DELETE FROM link_codes WHERE expires_at < ?1 OR used = 1",
                rusqlite::params![now],
            )
            .map_err(|e| format!("prune link codes: {e}"))?;
        let live: i64 = connection
            .query_row("SELECT COUNT(*) FROM link_codes", [], |row| row.get(0))
            .map_err(|e| format!("count link codes: {e}"))?;
        if live as usize >= max_existing {
            return Err("too many pending link codes; try again shortly".to_owned());
        }
        let code = thumble_tunnel::random_link_code();
        let code_digest = self.link_code_digest(&code);
        connection
            .execute(
                "INSERT INTO link_codes (code_digest, pending_key, device_name, created_at, expires_at, attempts, used) \
                 VALUES (?1, ?2, ?3, ?4, ?5, 0, 0)",
                rusqlite::params![code_digest, pending_key, device_name, now, now + ttl_seconds],
            )
            .map_err(|e| format!("create link code: {e}"))?;
        Ok(code)
    }

    /// Verify a link code entered by a user. Burns one attempt; on success
    /// marks it used and returns the pending key that identifies the
    /// anonymous device control connection waiting for the grant.
    pub fn consume_link_code(&self, code: &str) -> Result<Result<String, String>, String> {
        let connection = self.connection.lock().unwrap();
        let code_digest = self.link_code_digest(code);
        let row = connection.query_row(
            "SELECT pending_key, expires_at, attempts, used FROM link_codes WHERE code_digest = ?1",
            rusqlite::params![code_digest],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            },
        );
        let (pending_key, expires_at, attempts, used) = match row {
            Ok(value) => value,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown link code".to_owned()));
            }
            Err(other) => return Err(format!("lookup link code: {other}")),
        };
        if used == 1 {
            return Ok(Err("link code already used".to_owned()));
        }
        if Self::now() > expires_at {
            return Ok(Err("link code expired".to_owned()));
        }
        if attempts >= i64::from(thumble_tunnel::LINK_CODE_MAX_ATTEMPTS) {
            return Ok(Err("link code locked after too many attempts".to_owned()));
        }
        connection
            .execute(
                "UPDATE link_codes SET attempts = attempts + 1 WHERE code_digest = ?1",
                rusqlite::params![code_digest],
            )
            .map_err(|e| format!("burn link attempt: {e}"))?;
        connection
            .execute(
                "UPDATE link_codes SET used = 1 WHERE code_digest = ?1",
                rusqlite::params![code_digest],
            )
            .map_err(|e| format!("use link code: {e}"))?;
        Ok(Ok(pending_key))
    }

    pub fn create_authorization_request(
        &self,
        client_id: &str,
        redirect_uri: &str,
        state: &str,
        scope: &str,
        code_challenge: &str,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        if state.len() > 2048 {
            return Err("OAuth state exceeds 2048 characters".to_owned());
        }
        let request_id = thumble_tunnel::random_token(24);
        let now = Self::now();
        let connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        let live: i64 = connection
            .query_row("SELECT COUNT(*) FROM authorization_requests", [], |row| {
                row.get(0)
            })
            .map_err(|error| format!("count authorization requests: {error}"))?;
        if live >= 1_000 {
            return Err("authorization request capacity reached; retry later".to_owned());
        }
        connection
            .execute(
                "INSERT INTO authorization_requests (request_digest, client_id, redirect_uri, state, scope, code_challenge, expires_at, attempts, used) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0, 0)",
                rusqlite::params![
                    token_digest(&request_id),
                    client_id,
                    redirect_uri,
                    state,
                    scope,
                    code_challenge,
                    now + ttl_seconds
                ],
            )
            .map_err(|error| format!("create authorization request: {error}"))?;
        Ok(request_id)
    }

    pub fn authorization_request(
        &self,
        request_id: &str,
    ) -> Result<Result<AuthorizationRequestRecord, String>, String> {
        let record = self.connection.lock().unwrap().query_row(
            "SELECT client_id, redirect_uri, state, scope, code_challenge, expires_at, used \
             FROM authorization_requests WHERE request_digest = ?1",
            rusqlite::params![token_digest(request_id)],
            |row| {
                Ok((
                    AuthorizationRequestRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        state: row.get(2)?,
                        scope: row.get(3)?,
                        code_challenge: row.get(4)?,
                    },
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            },
        );
        match record {
            Ok((_record, _, 1)) => Ok(Err("authorization request already used".to_owned())),
            Ok((_record, expires_at, _)) if Self::now() > expires_at => {
                Ok(Err("authorization request expired".to_owned()))
            }
            Ok((record, _, _)) => Ok(Ok(record)),
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                Ok(Err("unknown authorization request".to_owned()))
            }
            Err(error) => Err(format!("lookup authorization request: {error}")),
        }
    }

    pub fn record_authorization_attempt(&self, request_id: &str) -> Result<(), String> {
        let changed = self
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE authorization_requests SET attempts = attempts + 1 \
                 WHERE request_digest = ?1 AND used = 0 AND expires_at >= ?2 AND attempts < 10",
                rusqlite::params![token_digest(request_id), Self::now()],
            )
            .map_err(|error| format!("record authorization attempt: {error}"))?;
        if changed == 1 {
            Ok(())
        } else {
            Err("authorization request is expired, used, or locked after ten attempts".to_owned())
        }
    }

    pub fn consume_authorization_request(&self, request_id: &str) -> Result<(), String> {
        let changed = self
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE authorization_requests SET used = 1 \
                 WHERE request_digest = ?1 AND used = 0 AND expires_at >= ?2",
                rusqlite::params![token_digest(request_id), Self::now()],
            )
            .map_err(|error| format!("consume authorization request: {error}"))?;
        if changed == 1 {
            Ok(())
        } else {
            Err("authorization request is expired or already used".to_owned())
        }
    }

    /// Atomically claim a live authorization request and its valid fallback
    /// link code. Denial/approval races cannot burn the code without winning
    /// the request, and no code can override a request already consumed by a
    /// pushed decision or timeout.
    pub fn consume_authorization_with_link_code(
        &self,
        request_id: &str,
        code: &str,
    ) -> Result<Result<(AuthorizationRequestRecord, String), String>, String> {
        let request_digest = token_digest(request_id);
        let code_digest = self.link_code_digest(code);
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin authorization/link claim: {error}"))?;

        let authorization = transaction.query_row(
            "SELECT client_id, redirect_uri, state, scope, code_challenge, expires_at, used \
             FROM authorization_requests WHERE request_digest = ?1",
            rusqlite::params![request_digest],
            |row| {
                Ok((
                    AuthorizationRequestRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        state: row.get(2)?,
                        scope: row.get(3)?,
                        code_challenge: row.get(4)?,
                    },
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            },
        );
        let (authorization, authorization_expires, authorization_used) = match authorization {
            Ok(value) => value,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown authorization request".to_owned()))
            }
            Err(error) => return Err(format!("lookup authorization request for link: {error}")),
        };
        if authorization_used == 1 {
            return Ok(Err("authorization request already used".to_owned()));
        }
        if now > authorization_expires {
            return Ok(Err("authorization request expired".to_owned()));
        }

        let link = transaction.query_row(
            "SELECT pending_key, expires_at, attempts, used FROM link_codes WHERE code_digest = ?1",
            rusqlite::params![code_digest],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    row.get::<_, i64>(2)?,
                    row.get::<_, i64>(3)?,
                ))
            },
        );
        let (pending_key, link_expires, link_attempts, link_used) = match link {
            Ok(value) => value,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown link code".to_owned()))
            }
            Err(error) => return Err(format!("lookup link code for authorization: {error}")),
        };
        if link_used == 1 {
            return Ok(Err("link code already used".to_owned()));
        }
        if now > link_expires {
            return Ok(Err("link code expired".to_owned()));
        }
        if link_attempts >= i64::from(thumble_tunnel::LINK_CODE_MAX_ATTEMPTS) {
            return Ok(Err("link code locked after too many attempts".to_owned()));
        }

        transaction
            .execute(
                "UPDATE authorization_requests SET used = 1 WHERE request_digest = ?1",
                rusqlite::params![request_digest],
            )
            .map_err(|error| format!("claim authorization request: {error}"))?;
        transaction
            .execute(
                "UPDATE link_codes SET attempts = attempts + 1, used = 1 WHERE code_digest = ?1",
                rusqlite::params![code_digest],
            )
            .map_err(|error| format!("claim link code: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit authorization/link claim: {error}"))?;
        Ok(Ok((authorization, pending_key)))
    }

    pub fn create_auth_code(
        &self,
        client_id: &str,
        redirect_uri: &str,
        scope: &str,
        code_challenge: &str,
        device_id: &str,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        let code = thumble_tunnel::random_token(24);
        let now = Self::now();
        let connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        connection
            .execute(
                "INSERT INTO auth_codes (code_digest, client_id, redirect_uri, scope, code_challenge, device_id, expires_at, used) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 0)",
                rusqlite::params![
                    token_digest(&code),
                    client_id,
                    redirect_uri,
                    scope,
                    code_challenge,
                    device_id,
                    now + ttl_seconds
                ],
            )
            .map_err(|e| format!("create auth code: {e}"))?;
        Ok(code)
    }

    /// Verify every authorization-code binding, including PKCE, before
    /// marking the code used. A guessed/intercepted code with the wrong
    /// verifier cannot deny service to the legitimate client.
    pub fn consume_auth_code(
        &self,
        code: &str,
        client_id: &str,
        redirect_uri: &str,
        code_verifier: &str,
    ) -> Result<Result<AuthCodeRecord, String>, String> {
        let digest = token_digest(code);
        let connection = self.connection.lock().unwrap();
        let record = connection.query_row(
            "SELECT client_id, redirect_uri, scope, code_challenge, device_id, expires_at, used \
             FROM auth_codes WHERE code_digest = ?1",
            rusqlite::params![digest],
            |row| {
                Ok((
                    AuthCodeRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        scope: row.get(2)?,
                        code_challenge: row.get(3)?,
                        device_id: row.get(4)?,
                    },
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            },
        );
        match record {
            Ok((record, expires_at, used)) => {
                if used == 1 {
                    return Ok(Err("authorization code already used".to_owned()));
                }
                if Self::now() > expires_at {
                    return Ok(Err("authorization code expired".to_owned()));
                }
                if record.client_id != client_id || record.redirect_uri != redirect_uri {
                    return Ok(Err(
                        "authorization code does not match the client".to_owned()
                    ));
                }
                if !thumble_tunnel::pkce_s256_matches(code_verifier, &record.code_challenge) {
                    return Ok(Err("PKCE verification failed".to_owned()));
                }
                connection
                    .execute(
                        "UPDATE auth_codes SET used = 1 WHERE code_digest = ?1",
                        rusqlite::params![digest],
                    )
                    .map_err(|e| format!("use auth code: {e}"))?;
                Ok(Ok(record))
            }
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                Ok(Err("unknown authorization code".to_owned()))
            }
            Err(other) => Err(format!("lookup auth code: {other}")),
        }
    }

    /// Verify and consume an authorization code while issuing its isolated
    /// access/optional-refresh token family in the same transaction. Any
    /// storage or active-device failure rolls the code consumption back.
    #[allow(clippy::too_many_arguments)]
    pub fn exchange_auth_code(
        &self,
        code: &str,
        client_id: &str,
        redirect_uri: &str,
        code_verifier: &str,
        access_ttl_seconds: i64,
        refresh_ttl_seconds: i64,
    ) -> Result<Result<AuthorizationTokenGrant, String>, String> {
        let code_digest = token_digest(code);
        let access_token = thumble_tunnel::random_token(32);
        let refresh_token = thumble_tunnel::random_token(32);
        let family_id = Self::new_token_family_id();
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin authorization-code exchange: {error}"))?;
        let record = transaction.query_row(
            "SELECT client_id, redirect_uri, scope, code_challenge, device_id, expires_at, used \
             FROM auth_codes WHERE code_digest = ?1",
            rusqlite::params![code_digest],
            |row| {
                Ok((
                    AuthCodeRecord {
                        client_id: row.get(0)?,
                        redirect_uri: row.get(1)?,
                        scope: row.get(2)?,
                        code_challenge: row.get(3)?,
                        device_id: row.get(4)?,
                    },
                    row.get::<_, i64>(5)?,
                    row.get::<_, i64>(6)?,
                ))
            },
        );
        let (record, expires_at, used) = match record {
            Ok(record) => record,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown authorization code".to_owned()));
            }
            Err(error) => return Err(format!("lookup authorization code: {error}")),
        };
        if used == 1 {
            return Ok(Err("authorization code already used".to_owned()));
        }
        if now > expires_at {
            return Ok(Err("authorization code expired".to_owned()));
        }
        if record.client_id != client_id || record.redirect_uri != redirect_uri {
            return Ok(Err(
                "authorization code does not match the client".to_owned()
            ));
        }
        if !thumble_tunnel::pkce_s256_matches(code_verifier, &record.code_challenge) {
            return Ok(Err("PKCE verification failed".to_owned()));
        }
        require_active_device(&transaction, &record.device_id)?;
        transaction
            .execute(
                "INSERT INTO access_tokens (token_digest, device_id, scope, expires_at, revoked, family_id) \
                 VALUES (?1, ?2, ?3, ?4, 0, ?5)",
                rusqlite::params![
                    token_digest(&access_token),
                    record.device_id,
                    record.scope,
                    now + access_ttl_seconds,
                    family_id
                ],
            )
            .map_err(|error| format!("issue authorization access token: {error}"))?;
        let include_refresh = record
            .scope
            .split_whitespace()
            .any(|scope| scope == "offline_access");
        if include_refresh {
            transaction
                .execute(
                    "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at, family_id) \
                     VALUES (?1, ?2, ?3, ?4, ?5, NULL, 0, 0, ?6)",
                    rusqlite::params![
                        token_digest(&refresh_token),
                        record.device_id,
                        client_id,
                        record.scope,
                        now + refresh_ttl_seconds,
                        family_id
                    ],
                )
                .map_err(|error| format!("issue authorization refresh token: {error}"))?;
        }
        transaction
            .execute(
                "UPDATE auth_codes SET used = 1 WHERE code_digest = ?1 AND used = 0",
                rusqlite::params![code_digest],
            )
            .map_err(|error| format!("consume authorization code: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit authorization-code exchange: {error}"))?;
        Ok(Ok(AuthorizationTokenGrant {
            access_token,
            refresh_token: include_refresh.then_some(refresh_token),
            scope: record.scope,
            device_id: record.device_id,
        }))
    }

    pub fn issue_access_token(
        &self,
        device_id: &str,
        scope: &str,
        ttl_seconds: i64,
    ) -> Result<String, String> {
        let token = thumble_tunnel::random_token(32);
        let family_id = Self::new_token_family_id();
        let mut connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, Self::now())?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin access-token issuance: {error}"))?;
        require_active_device(&transaction, device_id)?;
        transaction
            .execute(
                "INSERT INTO access_tokens (token_digest, device_id, scope, expires_at, revoked, family_id) \
                 VALUES (?1, ?2, ?3, ?4, 0, ?5)",
                rusqlite::params![
                    token_digest(&token),
                    device_id,
                    scope,
                    Self::now() + ttl_seconds,
                    family_id
                ],
            )
            .map_err(|e| format!("issue access token: {e}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit access-token issuance: {error}"))?;
        Ok(token)
    }

    /// Issue the authorization-code access/refresh credential pair in one
    /// isolated family and one transaction. Reuse of an older independent
    /// grant can revoke only its own family, never this newly approved one.
    pub fn issue_authorization_tokens(
        &self,
        device_id: &str,
        client_id: &str,
        scope: &str,
        access_ttl_seconds: i64,
        refresh_ttl_seconds: i64,
        include_refresh: bool,
    ) -> Result<(String, Option<String>), String> {
        let access = thumble_tunnel::random_token(32);
        let refresh = include_refresh.then(|| thumble_tunnel::random_token(32));
        let family_id = Self::new_token_family_id();
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin authorization-token issuance: {error}"))?;
        require_active_device(&transaction, device_id)?;
        transaction
            .execute(
                "INSERT INTO access_tokens (token_digest, device_id, scope, expires_at, revoked, family_id) \
                 VALUES (?1, ?2, ?3, ?4, 0, ?5)",
                rusqlite::params![
                    token_digest(&access),
                    device_id,
                    scope,
                    now + access_ttl_seconds,
                    family_id
                ],
            )
            .map_err(|error| format!("issue authorization access token: {error}"))?;
        if let Some(refresh) = refresh.as_deref() {
            transaction
                .execute(
                    "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at, family_id) \
                     VALUES (?1, ?2, ?3, ?4, ?5, NULL, 0, 0, ?6)",
                    rusqlite::params![
                        token_digest(refresh),
                        device_id,
                        client_id,
                        scope,
                        now + refresh_ttl_seconds,
                        family_id
                    ],
                )
                .map_err(|error| format!("issue authorization refresh token: {error}"))?;
        }
        transaction
            .commit()
            .map_err(|error| format!("commit authorization-token issuance: {error}"))?;
        Ok((access, refresh))
    }

    pub fn access_token(&self, token: &str) -> Result<Option<AccessTokenRecord>, String> {
        self.connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT a.device_id, a.scope, a.expires_at, a.revoked \
                 FROM access_tokens a JOIN devices d ON d.id = a.device_id \
                 WHERE a.token_digest = ?1 AND d.revoked = 0",
                rusqlite::params![token_digest(token)],
                |row| {
                    Ok((
                        AccessTokenRecord {
                            device_id: row.get(0)?,
                            scope: row.get(1)?,
                        },
                        row.get::<_, i64>(2)?,
                        row.get::<_, i64>(3)?,
                    ))
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("lookup access token: {other}")),
            })
            .map(|option| match option {
                Some((record, expires_at, revoked))
                    if revoked == 0 && Self::now() <= expires_at =>
                {
                    Some(record)
                }
                Some(_) => None,
                None => None,
            })
    }

    pub fn issue_refresh_token(
        &self,
        device_id: &str,
        client_id: &str,
        scope: &str,
        ttl_seconds: i64,
        rotated_from: Option<&str>,
    ) -> Result<String, String> {
        let token = thumble_tunnel::random_token(32);
        let rotated_from_digest = rotated_from.map(token_digest);
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin refresh-token issuance: {error}"))?;
        require_active_device(&transaction, device_id)?;
        let family_id = if let Some(parent) = rotated_from_digest.as_deref() {
            transaction
                .query_row(
                    "SELECT family_id FROM refresh_tokens \
                     WHERE token_digest = ?1 AND device_id = ?2 AND client_id = ?3",
                    rusqlite::params![parent, device_id, client_id],
                    |row| row.get::<_, String>(0),
                )
                .map_err(|error| format!("lookup parent refresh-token family: {error}"))?
        } else {
            Self::new_token_family_id()
        };
        transaction
            .execute(
                "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at, family_id) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, 0, ?7)",
                rusqlite::params![
                    token_digest(&token),
                    device_id,
                    client_id,
                    scope,
                    now + ttl_seconds,
                    rotated_from_digest,
                    family_id
                ],
            )
            .map_err(|e| format!("issue refresh token: {e}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit refresh-token issuance: {error}"))?;
        Ok(token)
    }

    /// Rotate a refresh token. Validation, reuse-family revocation, device
    /// state checking, old-token revocation, and replacement insertion are a
    /// single SQLite transaction, so concurrent replay/revoke cannot mint a
    /// token after the family has been invalidated.
    ///
    /// Presenting an already-rotated token is either a concurrent refresh by
    /// another window of the same desktop client (they share one token
    /// cache) or a replayed stolen token. Recent rotations (inside the grace
    /// window, within the successor budget, on an active device) mint one
    /// additional successor per caller; anything later revokes the family.
    #[allow(clippy::type_complexity)]
    pub fn rotate_refresh_token(
        &self,
        token: &str,
        client_id: &str,
        ttl_seconds: i64,
    ) -> Result<Result<(String, String, String), String>, String> {
        let digest = token_digest(token);
        let new_refresh = thumble_tunnel::random_token(32);
        let new_access = thumble_tunnel::random_token(32);
        let now = Self::now();
        let mut connection = self.connection.lock().unwrap();
        prune_expired_oauth(&connection, now)?;
        let transaction = connection
            .transaction()
            .map_err(|error| format!("begin refresh rotation: {error}"))?;
        let record = transaction.query_row(
            "SELECT device_id, client_id, scope, expires_at, revoked, family_id \
             FROM refresh_tokens WHERE token_digest = ?1",
            rusqlite::params![digest],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, i64>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, String>(5)?,
                ))
            },
        );
        let (device_id, stored_client, scope, expires_at, revoked, family_id) = match record {
            Ok(value) => value,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                return Ok(Err("unknown refresh token".to_owned()));
            }
            Err(other) => return Err(format!("lookup refresh token: {other}")),
        };
        if stored_client != client_id {
            return Ok(Err(
                "refresh token was issued to a different client".to_owned()
            ));
        }
        if revoked == 1 {
            let rotated_at: i64 = transaction
                .query_row(
                    "SELECT rotated_at FROM refresh_tokens WHERE token_digest = ?1",
                    rusqlite::params![digest],
                    |row| row.get(0),
                )
                .unwrap_or(0);
            let within_grace = rotated_at > 0
                && now - rotated_at <= self.refresh_grace_seconds
                && self.refresh_grace_seconds > 0;
            let successors: i64 = if within_grace {
                transaction
                    .query_row(
                        "SELECT COUNT(*) FROM refresh_tokens \
                         WHERE rotated_from = ?1 AND revoked = 0",
                        rusqlite::params![digest],
                        |row| row.get(0),
                    )
                    .unwrap_or(i64::MAX)
            } else {
                i64::MAX
            };
            if within_grace
                && successors < MAXIMUM_GRACE_SUCCESSORS
                && now <= expires_at
                && stored_client == client_id
            {
                // Concurrent-refresh race: this caller shares the credential
                // with the window that just rotated it. Give it its own
                // successor so neither session dies, bounded by the grace
                // window and the successor budget.
                if let Err(reason) = require_active_device(&transaction, &device_id) {
                    return Ok(Err(reason));
                }
                transaction
                    .execute(
                        "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at, family_id) \
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, 0, ?7)",
                        rusqlite::params![token_digest(&new_refresh), device_id, client_id, scope, now + ttl_seconds, digest, family_id],
                    )
                    .map_err(|error| format!("insert grace refresh token: {error}"))?;
                transaction
                    .execute(
                        "INSERT INTO access_tokens (token_digest, device_id, scope, expires_at, revoked, family_id) \
                         VALUES (?1, ?2, ?3, ?4, 0, ?5)",
                        rusqlite::params![token_digest(&new_access), device_id, scope, now + 900, family_id],
                    )
                    .map_err(|error| format!("insert grace access token: {error}"))?;
                transaction
                    .commit()
                    .map_err(|error| format!("commit grace refresh rotation: {error}"))?;
                return Ok(Ok((new_access, new_refresh, scope)));
            }
            transaction
                .execute(
                    "UPDATE access_tokens SET revoked = 1 \
                     WHERE device_id = ?1 AND family_id = ?2",
                    rusqlite::params![device_id, family_id],
                )
                .map_err(|error| format!("revoke family access tokens: {error}"))?;
            transaction
                .execute(
                    "UPDATE refresh_tokens SET revoked = 1 \
                     WHERE device_id = ?1 AND client_id = ?2 AND family_id = ?3",
                    rusqlite::params![device_id, stored_client, family_id],
                )
                .map_err(|error| format!("revoke family refresh tokens: {error}"))?;
            transaction
                .commit()
                .map_err(|error| format!("commit refresh reuse revocation: {error}"))?;
            return Ok(Err(
                "refresh token reuse detected; token family revoked".to_owned()
            ));
        }
        if now > expires_at {
            return Ok(Err("refresh token expired".to_owned()));
        }
        require_active_device(&transaction, &device_id)?;
        transaction
            .execute(
                "UPDATE refresh_tokens SET revoked = 1, rotated_at = ?2 WHERE token_digest = ?1",
                rusqlite::params![digest, now],
            )
            .map_err(|error| format!("rotate refresh token: {error}"))?;
        transaction
            .execute(
                "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at, family_id) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0, 0, ?7)",
                rusqlite::params![
                    token_digest(&new_refresh),
                    device_id,
                    client_id,
                    scope,
                    now + ttl_seconds,
                    digest,
                    family_id
                ],
            )
            .map_err(|error| format!("insert rotated refresh token: {error}"))?;
        transaction
            .execute(
                "INSERT INTO access_tokens (token_digest, device_id, scope, expires_at, revoked, family_id) \
                 VALUES (?1, ?2, ?3, ?4, 0, ?5)",
                rusqlite::params![token_digest(&new_access), device_id, scope, now + 900, family_id],
            )
            .map_err(|error| format!("insert rotated access token: {error}"))?;
        transaction
            .commit()
            .map_err(|error| format!("commit refresh rotation: {error}"))?;
        Ok(Ok((new_access, new_refresh, scope)))
    }

    pub fn store_manifest(&self, device_id: &str, manifest: &ManifestRecord) -> Result<(), String> {
        self.connection
            .lock()
            .unwrap()
            .execute(
                "INSERT INTO manifests (device_id, tools, resources, instructions, updated_at) \
                 VALUES (?1, ?2, ?3, ?4, ?5) \
                 ON CONFLICT(device_id) DO UPDATE SET tools = ?2, resources = ?3, instructions = ?4, updated_at = ?5",
                rusqlite::params![
                    device_id,
                    serde_json::to_string(&manifest.tools).unwrap(),
                    serde_json::to_string(&manifest.resources).unwrap(),
                    manifest.instructions,
                    Self::now()
                ],
            )
            .map_err(|e| format!("store manifest: {e}"))?;
        Ok(())
    }

    pub fn manifest(&self, device_id: &str) -> Result<Option<ManifestRecord>, String> {
        self.connection
            .lock()
            .unwrap()
            .query_row(
                "SELECT tools, resources, instructions FROM manifests WHERE device_id = ?1",
                rusqlite::params![device_id],
                |row| {
                    Ok(ManifestRecord {
                        tools: serde_json::from_str(&row.get::<_, String>(0)?).unwrap_or_default(),
                        resources: serde_json::from_str(&row.get::<_, String>(1)?)
                            .unwrap_or_default(),
                        instructions: row.get(2)?,
                    })
                },
            )
            .map(Some)
            .or_else(|error| match error {
                rusqlite::Error::QueryReturnedNoRows => Ok(None),
                other => Err(format!("lookup manifest: {other}")),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> Store {
        Store::open_in_memory().unwrap()
    }

    fn pkce_pair() -> (String, String) {
        use base64::Engine as _;
        use sha2::Digest as _;
        let verifier = "store-verifier-store-verifier-store-verifier-123".to_owned();
        let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .encode(sha2::Sha256::digest(verifier.as_bytes()));
        (verifier, challenge)
    }

    #[test]
    fn devices_round_trip_and_revoke_fail_closed() {
        let store = store();
        let (id, token) = store.create_device("Cody's Mac").unwrap();
        let device = store.device_for_token(&token).unwrap().unwrap();
        assert_eq!(device.id, id);
        assert_eq!(device.name, "Cody's Mac");
        store.revoke_device(&id).unwrap();
        assert!(store.device_for_token(&token).unwrap().is_none());
    }

    #[test]
    fn rotating_a_device_token_replaces_the_credential_in_place() {
        let store = store();
        let (id, token) = store.create_device("Mac").unwrap();
        let rotated = store.rotate_device_token(&id, "MacBook").unwrap();
        assert_ne!(rotated, token);
        // The old credential stops working immediately; no dual-valid window.
        assert!(store.device_for_token(&token).unwrap().is_none());
        let device = store.device_for_token(&rotated).unwrap().unwrap();
        assert_eq!(device.id, id, "rotation must keep the device identity");
        assert_eq!(device.name, "MacBook");
        // Revoked (or unknown) devices cannot rotate back in.
        store.revoke_device(&id).unwrap();
        assert!(store.rotate_device_token(&id, "Mac").is_err());
        assert!(store.rotate_device_token("dev_missing", "Mac").is_err());
    }

    #[test]
    fn unknown_tokens_are_rejected() {
        let store = store();
        assert!(store.device_for_token("nope").unwrap().is_none());
    }

    #[test]
    fn link_codes_are_keyed_at_rest_burn_attempts_and_expire() {
        let store = store();
        let code = store.create_link_code("pending-1", "Mac", 60, 16).unwrap();
        let digest: String = store
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT code_digest FROM link_codes", [], |row| row.get(0))
            .unwrap();
        assert_ne!(digest, code);
        assert_eq!(digest.len(), 64);
        let second = store.consume_link_code(&code).unwrap().unwrap();
        assert_eq!(second, "pending-1");
        assert!(store.consume_link_code(&code).unwrap().is_err());
        let other = store.create_link_code("pending-2", "Mac", -1, 16).unwrap();
        assert!(store.consume_link_code(&other).unwrap().is_err());
    }

    #[test]
    fn client_registration_requires_https_redirects() {
        let store = store();
        for invalid in [
            "http://evil.example/cb",
            "http://localhost.evil/cb",
            "https://user@example.com/cb",
            "https://example.com/cb#fragment",
        ] {
            assert!(store
                .register_client("ChatGPT", vec![invalid.to_owned()])
                .is_err());
        }
        assert!(store
            .register_client(
                "ChatGPT",
                vec![
                    "https://chatgpt.com/cb".to_owned(),
                    "https://chatgpt.com/cb".to_owned()
                ]
            )
            .is_err());
        let client_id = store
            .register_client(
                "ChatGPT",
                vec!["https://chatgpt.com/connector/oauth/callback".to_owned()],
            )
            .unwrap();
        assert!(client(&store, &client_id).is_some());
    }

    fn client(store: &Store, id: &str) -> Option<ClientRecord> {
        store.client(id).unwrap()
    }

    #[test]
    fn inactive_clients_and_expired_authorization_requests_are_pruned() {
        let store = store();
        let old_client = store
            .register_client("Old", vec!["https://example.com/cb".to_owned()])
            .unwrap();
        store
            .connection
            .lock()
            .unwrap()
            .execute(
                "UPDATE oauth_clients SET created_at = 0 WHERE client_id = ?1",
                rusqlite::params![old_client],
            )
            .unwrap();
        store
            .create_authorization_request(
                "old",
                "https://example.com/cb",
                "state",
                "thumble.read",
                "challenge",
                -1,
            )
            .unwrap();
        store
            .register_client("New", vec!["https://example.com/new".to_owned()])
            .unwrap();
        assert!(store.client(&old_client).unwrap().is_none());
        let request_count: i64 = store
            .connection
            .lock()
            .unwrap()
            .query_row("SELECT COUNT(*) FROM authorization_requests", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(request_count, 0);
    }

    #[test]
    fn authorization_requests_are_server_bound_and_lock_after_ten_attempts() {
        let store = store();
        let request = store
            .create_authorization_request(
                "cc_1",
                "https://chatgpt.com/cb",
                "state",
                "thumble.read",
                "challenge",
                60,
            )
            .unwrap();
        let loaded = store.authorization_request(&request).unwrap().unwrap();
        assert_eq!(loaded.client_id, "cc_1");
        for _ in 0..10 {
            store.record_authorization_attempt(&request).unwrap();
        }
        assert!(store.record_authorization_attempt(&request).is_err());
        store.consume_authorization_request(&request).unwrap();
        assert!(store.authorization_request(&request).unwrap().is_err());
    }

    #[test]
    fn fallback_code_and_authorization_are_claimed_atomically() {
        let store = store();
        let denied_request = store
            .create_authorization_request(
                "cc_1",
                "https://chatgpt.com/cb",
                "state",
                "thumble.read",
                "challenge",
                60,
            )
            .unwrap();
        let preserved_code = store
            .create_link_code("pending-denied", "Mac", 60, 16)
            .unwrap();
        store
            .consume_authorization_request(&denied_request)
            .unwrap();
        assert!(store
            .consume_authorization_with_link_code(&denied_request, &preserved_code)
            .unwrap()
            .is_err());
        assert_eq!(
            store.consume_link_code(&preserved_code).unwrap().unwrap(),
            "pending-denied",
            "losing the authorization race must not burn the fallback code"
        );

        let live_request = store
            .create_authorization_request(
                "cc_1",
                "https://chatgpt.com/cb",
                "state-2",
                "thumble.read",
                "challenge",
                60,
            )
            .unwrap();
        let live_code = store
            .create_link_code("pending-live", "Mac", 60, 16)
            .unwrap();
        let (claimed, pending_key) = store
            .consume_authorization_with_link_code(&live_request, &live_code)
            .unwrap()
            .unwrap();
        assert_eq!(claimed.state, "state-2");
        assert_eq!(pending_key, "pending-live");
        assert!(store.authorization_request(&live_request).unwrap().is_err());
        assert!(store.consume_link_code(&live_code).unwrap().is_err());
    }

    #[test]
    fn pre_family_schema_migrates_with_rollback_compatible_defaults() {
        let connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE access_tokens (
                    token_digest TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    revoked INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE refresh_tokens (
                    token_digest TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL,
                    client_id TEXT NOT NULL,
                    scope TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    rotated_from TEXT,
                    revoked INTEGER NOT NULL DEFAULT 0,
                    rotated_at INTEGER NOT NULL DEFAULT 0
                );",
            )
            .unwrap();
        let store = Store::with_connection(connection, "gateway-test-link-secret-32-bytes-minimum")
            .unwrap();
        let (device, _) = store.create_device("Mac").unwrap();
        let connection = store.connection.lock().unwrap();
        // Old binaries omit family_id. The migration default keeps those
        // inserts valid if the deployment must roll back after migration.
        connection
            .execute(
                "INSERT INTO access_tokens (token_digest, device_id, scope, expires_at, revoked) \
                 VALUES ('legacy-access', ?1, 'thumble.read', ?2, 0)",
                rusqlite::params![device, Store::now() + 60],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO refresh_tokens (token_digest, device_id, client_id, scope, expires_at, rotated_from, revoked, rotated_at) \
                 VALUES ('legacy-refresh', ?1, 'cc_1', 'thumble.read', ?2, NULL, 0, 0)",
                rusqlite::params![device, Store::now() + 60],
            )
            .unwrap();
        let families: (String, String) = connection
            .query_row(
                "SELECT
                    (SELECT family_id FROM access_tokens WHERE token_digest = 'legacy-access'),
                    (SELECT family_id FROM refresh_tokens WHERE token_digest = 'legacy-refresh')",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(families, (String::new(), String::new()));
    }

    #[test]
    fn auth_codes_verify_pkce_before_single_use_consumption() {
        let store = store();
        let (_device, _token) = store.create_device("Mac").unwrap();
        let (verifier, challenge) = pkce_pair();
        let code = store
            .create_auth_code(
                "cc_1",
                "https://chatgpt.com/cb",
                "thumble.read",
                &challenge,
                "dev_x",
                60,
            )
            .unwrap();
        assert!(store
            .consume_auth_code(
                &code,
                "cc_1",
                "https://chatgpt.com/cb",
                "wrong-verifier-wrong-verifier-wrong-verifier-123",
            )
            .unwrap()
            .is_err());
        let first = store
            .consume_auth_code(&code, "cc_1", "https://chatgpt.com/cb", &verifier)
            .unwrap()
            .unwrap();
        assert_eq!(first.device_id, "dev_x");
        assert_eq!(first.code_challenge, challenge);
        assert!(store
            .consume_auth_code(&code, "cc_1", "https://chatgpt.com/cb", &verifier)
            .unwrap()
            .is_err());
        assert!(store
            .consume_auth_code(&code, "cc_1", "https://other.example/cb", &verifier,)
            .unwrap()
            .is_err());
        assert!(store
            .consume_auth_code("unknown", "cc_1", "https://chatgpt.com/cb", &verifier,)
            .unwrap()
            .is_err());
    }

    #[test]
    fn failed_authorization_token_issuance_does_not_consume_the_code() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let (verifier, challenge) = pkce_pair();
        let code = store
            .create_auth_code(
                "cc_1",
                "https://chatgpt.com/cb",
                "thumble.read offline_access",
                &challenge,
                &device,
                60,
            )
            .unwrap();
        store.revoke_device(&device).unwrap();

        assert!(store
            .exchange_auth_code(
                &code,
                "cc_1",
                "https://chatgpt.com/cb",
                &verifier,
                900,
                3600,
            )
            .is_err());
        // The transaction rolled back before marking the code used.
        assert!(store
            .consume_auth_code(&code, "cc_1", "https://chatgpt.com/cb", &verifier)
            .unwrap()
            .is_ok());
    }

    #[test]
    fn access_tokens_expire_and_revoke() {
        let store = store();
        let (device, _token) = store.create_device("Mac").unwrap();
        let access = store
            .issue_access_token(&device, "thumble.read", -1)
            .unwrap();
        assert!(store.access_token(&access).unwrap().is_none());
    }

    #[test]
    fn refresh_rotation_detects_reuse_after_the_grace_window() {
        let store = store().with_refresh_grace(0);
        let (device, _token) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let (access, new_refresh, scope) = store
            .rotate_refresh_token(&refresh, "cc_1", 3600)
            .unwrap()
            .unwrap();
        assert_eq!(scope, "thumble.read");
        assert!(store.access_token(&access).unwrap().is_some());
        // Replaying the old token after the grace window revokes the family.
        let replay = store.rotate_refresh_token(&refresh, "cc_1", 3600).unwrap();
        assert!(replay.is_err());
        assert!(store.access_token(&access).unwrap().is_none());
        assert!(store
            .rotate_refresh_token(&new_refresh, "cc_1", 3600)
            .unwrap()
            .is_err());
    }

    #[test]
    fn stale_refresh_replay_cannot_revoke_a_new_authorization_family() {
        let store = store().with_refresh_grace(0);
        let (device, _) = store.create_device("Mac").unwrap();
        let (_, old_refresh) = store
            .issue_authorization_tokens(
                &device,
                "cc_1",
                "thumble.read offline_access",
                900,
                3600,
                true,
            )
            .unwrap();
        let old_refresh = old_refresh.unwrap();
        let (old_access, old_successor, _) = store
            .rotate_refresh_token(&old_refresh, "cc_1", 3600)
            .unwrap()
            .unwrap();
        // Simulate rows migrated from the pre-family production schema. All
        // legacy grants intentionally share the empty compatibility family.
        {
            let connection = store.connection.lock().unwrap();
            connection
                .execute("UPDATE refresh_tokens SET family_id = ''", [])
                .unwrap();
            connection
                .execute("UPDATE access_tokens SET family_id = ''", [])
                .unwrap();
        }

        // A user explicitly authorizes the same device/client again while a
        // stale desktop window still holds a refresh token from the old grant.
        let (new_access, new_refresh) = store
            .issue_authorization_tokens(
                &device,
                "cc_1",
                "thumble.read offline_access",
                900,
                3600,
                true,
            )
            .unwrap();
        let replay = store
            .rotate_refresh_token(&old_refresh, "cc_1", 3600)
            .unwrap();
        assert!(replay.is_err());
        assert!(store.access_token(&old_access).unwrap().is_none());
        assert!(store
            .rotate_refresh_token(&old_successor, "cc_1", 3600)
            .unwrap()
            .is_err());

        // Reuse revokes only the compromised old family. The independently
        // approved replacement remains valid and refreshable.
        assert!(store.access_token(&new_access).unwrap().is_some());
        assert!(store
            .rotate_refresh_token(&new_refresh.unwrap(), "cc_1", 3600)
            .unwrap()
            .is_ok());
    }

    #[test]
    fn concurrent_refreshes_within_grace_each_keep_their_session() {
        // Multi-window desktop clients share one token cache: two chat
        // runtimes refresh the same token at the same moment. Both must walk
        // away with a working credential pair, and the family must survive.
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let first = store
            .rotate_refresh_token(&refresh, "cc_1", 3600)
            .unwrap()
            .unwrap();
        let second = store
            .rotate_refresh_token(&refresh, "cc_1", 3600)
            .unwrap()
            .unwrap();
        assert_ne!(first.1, second.1, "each caller gets its own successor");
        assert!(store.access_token(&first.0).unwrap().is_some());
        assert!(store.access_token(&second.0).unwrap().is_some());
        // Both successors remain usable; the family is alive.
        assert!(store
            .rotate_refresh_token(&first.1, "cc_1", 3600)
            .unwrap()
            .is_ok());
        assert!(store
            .rotate_refresh_token(&second.1, "cc_1", 3600)
            .unwrap()
            .is_ok());
    }

    #[test]
    fn grace_replay_is_bounded_by_the_successor_budget() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        // The original exchange plus (MAXIMUM_GRACE_SUCCESSORS - 1) peers
        // succeed, for MAXIMUM_GRACE_SUCCESSORS live successors total;
        // grinding past the budget revokes everything.
        let mut last_access = None;
        for _ in 0..MAXIMUM_GRACE_SUCCESSORS {
            let (access, _, _) = store
                .rotate_refresh_token(&refresh, "cc_1", 3600)
                .unwrap()
                .unwrap();
            last_access = Some(access);
        }
        let grinding = store.rotate_refresh_token(&refresh, "cc_1", 3600).unwrap();
        assert!(grinding.is_err());
        assert!(
            store.access_token(&last_access.unwrap()).unwrap().is_none(),
            "the whole family must die once the budget is exceeded"
        );
    }

    #[test]
    fn device_revocation_blocks_grace_exchanges() {
        let store = store();
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let (access, _new_refresh, _) = store
            .rotate_refresh_token(&refresh, "cc_1", 3600)
            .unwrap()
            .unwrap();
        store.revoke_device(&device).unwrap();
        // A grace replay must not resurrect a revoked device's session.
        let replay = store.rotate_refresh_token(&refresh, "cc_1", 3600).unwrap();
        assert!(replay.is_err());
        assert!(store.access_token(&access).unwrap().is_none());
    }

    #[test]
    fn concurrent_refresh_replay_cannot_leave_valid_replacements() {
        use std::sync::{Arc, Barrier};

        // With the grace window disabled, exactly one racer wins and the
        // replay still revokes the family — the strict theft policy.
        let store = Arc::new(store().with_refresh_grace(0));
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let barrier = Arc::new(Barrier::new(3));
        let mut handles = Vec::new();
        for _ in 0..2 {
            let store = store.clone();
            let refresh = refresh.clone();
            let barrier = barrier.clone();
            handles.push(std::thread::spawn(move || {
                barrier.wait();
                store.rotate_refresh_token(&refresh, "cc_1", 3600).unwrap()
            }));
        }
        barrier.wait();
        let outcomes = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(outcomes.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(outcomes.iter().filter(|result| result.is_err()).count(), 1);
        let access = outcomes.into_iter().find_map(Result::ok).unwrap().0;
        assert!(store.access_token(&access).unwrap().is_none());
    }

    #[test]
    fn revoke_racing_rotation_cannot_mint_after_revocation() {
        use std::sync::{Arc, Barrier};

        let store = Arc::new(store());
        let (device, _) = store.create_device("Mac").unwrap();
        let refresh = store
            .issue_refresh_token(&device, "cc_1", "thumble.read", 3600, None)
            .unwrap();
        let barrier = Arc::new(Barrier::new(3));
        let rotation = {
            let store = store.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                store.rotate_refresh_token(&refresh, "cc_1", 3600)
            })
        };
        let revocation = {
            let store = store.clone();
            let device = device.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                store.revoke_device(&device)
            })
        };
        barrier.wait();
        let rotation = rotation.join().unwrap().unwrap();
        revocation.join().unwrap().unwrap();
        if let Ok((access, _, _)) = rotation {
            assert!(store.access_token(&access).unwrap().is_none());
        }
        assert!(store
            .issue_access_token(&device, "thumble.read", 60)
            .is_err());
    }

    #[test]
    fn manifests_upsert() {
        let store = store();
        let manifest = ManifestRecord {
            tools: vec![serde_json::json!({"name": "host_status"})],
            resources: vec![],
            instructions: Some("hi".to_owned()),
        };
        store.store_manifest("dev_1", &manifest).unwrap();
        let loaded = store.manifest("dev_1").unwrap().unwrap();
        assert_eq!(loaded.tools.len(), 1);
        assert!(store.manifest("dev_missing").unwrap().is_none());
    }
}
