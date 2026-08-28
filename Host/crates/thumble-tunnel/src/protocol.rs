//! Wire protocol for the Thumble remote relay tunnel.
//!
//! The tunnel connects a device-side `thumble-mcp --relay` process to the
//! hosted gateway. One long-lived control WebSocket carries device link,
//! manifest, and session-management frames; each remote MCP session gets its
//! own on-demand WebSocket that carries exactly one newline-free JSON-RPC
//! message per WebSocket frame.

use serde::{Deserialize, Serialize};

pub const PROTOCOL_VERSION: u32 = 1;

/// Maximum in-flight remote MCP sessions one device may hold.
pub const MAXIMUM_DEVICE_SESSIONS: usize = 3;

/// Maximum encoded bytes of any single control or session frame.
pub const MAXIMUM_FRAME_BYTES: usize = 256 * 1024;

/// Six-digit link code lifetime in seconds.
pub const LINK_CODE_TTL_SECONDS: u64 = 3600;

/// Attempts allowed per link code before it is burned.
pub const LINK_CODE_MAX_ATTEMPTS: u32 = 10;

/// How long a pushed connector-approval request stays answerable on the
/// device after the connector's authorization page opens.
pub const CONNECTOR_APPROVAL_TTL_SECONDS: u64 = 300;

/// Control-channel frames exchanged on the device control WebSocket.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum TunnelMessage {
    /// Device → gateway: first frame after connect when unauthenticated.
    LinkRequest {
        #[serde(default)]
        device_name: String,
    },
    /// Gateway → device: a link code was issued.
    LinkOffer {
        code: String,
        url: String,
        expires_in: u64,
    },
    /// Gateway → device: the link was approved and this credential should be
    /// persisted atomically before OAuth is allowed to complete.
    LinkGranted {
        device_id: String,
        device_token: String,
    },
    /// Device → gateway: the granted token was durably persisted. The gateway
    /// does not finish OAuth before receiving this acknowledgment.
    LinkPersisted { device_id: String },
    /// Device → gateway: persistence failed; no secret-bearing detail crosses
    /// the tunnel and OAuth must fail closed.
    LinkPersistFailed { device_id: String },
    /// Gateway → device: the code expired, was burned, or persistence failed.
    LinkDenied { reason: String },
    /// Device → gateway: push the sanitized tool/resource manifest for
    /// offline connector validation. Bounded JSON blobs only.
    Manifest {
        tools: Vec<serde_json::Value>,
        resources: Vec<serde_json::Value>,
        #[serde(default)]
        server_instructions: Option<String>,
    },
    /// Gateway → device: open a session WebSocket for a remote MCP session.
    OpenSession {
        session_id: String,
        #[serde(default)]
        session_url: String,
    },
    /// Gateway → device: the remote session ended; drop the session socket.
    CloseSession { session_id: String },
    /// Device → gateway: session WebSocket outcome.
    SessionResult {
        session_id: String,
        ok: bool,
        #[serde(default)]
        error: Option<String>,
    },
    /// Device → gateway: revoke this device token and every binding that
    /// depends on it. Sent as a one-shot command before disconnecting.
    RevokeRequest,
    /// Gateway → device: the device token and all sessions were revoked.
    RevokeGranted {
        #[serde(default)]
        detail: Option<String>,
    },
    /// Gateway → an authenticated control connection: its credential was
    /// deliberately rotated. Close without deleting the token file; the
    /// relay's normal reconnect loop reloads the new credential.
    ReconnectRequired {
        #[serde(default)]
        detail: Option<String>,
    },
    /// Gateway → device liveness probe.
    Ping,
    /// Device → gateway liveness reply.
    Pong,
    /// Gateway → device: a connector (for example ChatGPT clicking
    /// "Connect") opened its authorization page and is waiting for this
    /// Mac to approve the link. The device answers with
    /// [`TunnelMessage::ConnectorApprovalDecision`].
    ConnectorApprovalRequest {
        request_id: String,
        #[serde(default)]
        client_name: String,
        #[serde(default)]
        scope: String,
        #[serde(default)]
        expires_in: u64,
    },
    /// Device → gateway: the user answered the pushed approval prompt on
    /// this Mac. Only valid for a request_id previously delivered to this
    /// exact connection; the first decision wins.
    ConnectorApprovalDecision { request_id: String, approved: bool },
    /// Gateway → device: outcome of a pushed approval. `granted` means the
    /// connector completed its OAuth connection bound to this Mac.
    ConnectorApprovalResult {
        request_id: String,
        granted: bool,
        #[serde(default)]
        detail: Option<String>,
    },
}

/// Generate a URL-safe opaque token with `bytes` bytes of entropy.
pub fn random_token(bytes: usize) -> String {
    use rand::RngCore;
    use std::fmt::Write as _;
    let mut raw = vec![0u8; bytes];
    rand::rng().fill_bytes(&mut raw);
    let table: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    let mut output = String::with_capacity(bytes * 2);
    for byte in &raw {
        // Two independent base62 characters per entropy byte keeps the token
        // URL-safe without padding and without base64's ambiguous characters.
        let _ = write!(
            output,
            "{}{}",
            table[(byte >> 4) as usize] as char,
            table[(*byte as usize) & 0x0f] as char
        );
    }
    output
}

/// Generate a uniformly random six-digit decimal code (`000000`..=`999999`).
pub fn random_link_code() -> String {
    use rand::Rng;
    let value: u32 = rand::rng().random_range(0..1_000_000);
    format!("{value:06}")
}

/// Deterministic at-rest digest for tokens. Tokens are never stored in the
/// clear; the digest is a plain SHA-256 because tokens carry 256 bits of
/// entropy already.
pub fn token_digest(token: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    let digest = hasher.finalize();
    let mut output = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(output, "{byte:02x}");
    }
    output
}

/// S256 PKCE code-challenge verification per RFC 7636 §4.6.
pub fn pkce_s256_matches(verifier: &str, challenge: &str) -> bool {
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use base64::Engine as _;
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(verifier.as_bytes());
    let computed = URL_SAFE_NO_PAD.encode(digest);
    constant_time_eq(computed.as_bytes(), challenge.as_bytes())
}

/// Constant-time byte comparison for secrets.
pub fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0u8;
    for (a, b) in left.iter().zip(right.iter()) {
        difference |= a ^ b;
    }
    difference == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_frames_round_trip() {
        let messages = [
            TunnelMessage::LinkRequest {
                device_name: "Cody's Mac".to_owned(),
            },
            TunnelMessage::LinkOffer {
                code: "123456".to_owned(),
                url: "https://mcp.thumble.app/link?code=123456".to_owned(),
                expires_in: LINK_CODE_TTL_SECONDS,
            },
            TunnelMessage::LinkGranted {
                device_id: "dev_x".to_owned(),
                device_token: random_token(32),
            },
            TunnelMessage::LinkPersisted {
                device_id: "dev_x".to_owned(),
            },
            TunnelMessage::LinkPersistFailed {
                device_id: "dev_x".to_owned(),
            },
            TunnelMessage::LinkDenied {
                reason: "expired".to_owned(),
            },
            TunnelMessage::Manifest {
                tools: vec![serde_json::json!({"name":"host_status"})],
                resources: Vec::new(),
                server_instructions: Some("instructions".to_owned()),
            },
            TunnelMessage::OpenSession {
                session_id: "sess_1".to_owned(),
                session_url: "wss://mcp.thumble.app/tunnel/session/sess_1".to_owned(),
            },
            TunnelMessage::CloseSession {
                session_id: "sess_1".to_owned(),
            },
            TunnelMessage::SessionResult {
                session_id: "sess_1".to_owned(),
                ok: true,
                error: None,
            },
            TunnelMessage::Ping,
            TunnelMessage::Pong,
            TunnelMessage::RevokeRequest,
            TunnelMessage::RevokeGranted {
                detail: Some("device unlinked".to_owned()),
            },
            TunnelMessage::ReconnectRequired {
                detail: Some("device token rotated".to_owned()),
            },
            TunnelMessage::ConnectorApprovalRequest {
                request_id: "req_1".to_owned(),
                client_name: "ChatGPT".to_owned(),
                scope: "thumble.read thumble.draft".to_owned(),
                expires_in: CONNECTOR_APPROVAL_TTL_SECONDS,
            },
            TunnelMessage::ConnectorApprovalDecision {
                request_id: "req_1".to_owned(),
                approved: true,
            },
            TunnelMessage::ConnectorApprovalResult {
                request_id: "req_1".to_owned(),
                granted: true,
                detail: Some("ChatGPT connected".to_owned()),
            },
        ];
        for message in &messages {
            let encoded = serde_json::to_vec(message).unwrap();
            assert!(encoded.len() <= MAXIMUM_FRAME_BYTES);
            let decoded: TunnelMessage = serde_json::from_slice(&encoded).unwrap();
            assert_eq!(&decoded, message);
        }
    }

    #[test]
    fn unknown_frame_types_are_rejected() {
        let encoded = br#"{"type":"run_shell_command"}"#;
        assert!(serde_json::from_slice::<TunnelMessage>(encoded).is_err());
    }

    #[test]
    fn random_tokens_have_expected_shape_and_entropy() {
        let token = random_token(32);
        assert_eq!(token.len(), 64);
        assert!(token.bytes().all(|b| b.is_ascii_alphanumeric()));
        assert_ne!(token, random_token(32));
    }

    #[test]
    fn link_codes_are_six_digits() {
        for _ in 0..10 {
            let code = random_link_code();
            assert_eq!(code.len(), 6);
            assert!(code.bytes().all(|b| b.is_ascii_digit()));
        }
    }

    #[test]
    fn token_digest_is_stable_and_lengthy() {
        let a = token_digest("secret");
        let b = token_digest("secret");
        let c = token_digest("secreu");
        assert_eq!(a, b);
        assert_ne!(a, c);
        assert_eq!(a.len(), 64);
    }

    #[test]
    fn pkce_s256_verification_accepts_only_matching_verifiers() {
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        use base64::Engine as _;
        use sha2::{Digest, Sha256};
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        let challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        assert!(pkce_s256_matches(verifier, &challenge));
        assert!(!pkce_s256_matches("wrong-verifier", &challenge));
        assert!(!pkce_s256_matches(verifier, "not-the-challenge"));
    }

    #[test]
    fn constant_time_compares_lengths_and_bytes() {
        assert!(constant_time_eq(b"abc", b"abc"));
        assert!(!constant_time_eq(b"abc", b"abd"));
        assert!(!constant_time_eq(b"abc", b"abcd"));
    }
}
