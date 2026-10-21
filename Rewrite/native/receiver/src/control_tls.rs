//! Pinned host-authenticated TLS only. Phone enrollment/trust and input admission are separate.
use ring::digest;
use rustls::{
    client::{
        danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
        Resumption, WebPkiServerVerifier,
    },
    crypto::{ring::default_provider, CryptoProvider},
    pki_types::{CertificateDer, PrivateKeyDer, ServerName, UnixTime},
    ClientConfig, ClientConnection, DigitallySignedStruct, Error, RootCertStore, ServerConfig,
    ServerConnection, SignatureScheme, StreamOwned,
};
use std::{
    io::{self, Read, Write},
    net::{Shutdown, SocketAddr, TcpStream},
    sync::Arc,
    time::{Duration, Instant},
};

pub const CONTROL_ALPN: &[u8] = b"thumble-rewrite-control/1";
pub const CONTROL_SERVER_NAME: &str = "thumble-rewrite.local";
pub const MAX_CONTROL_BYTES: usize = 65_536;
const MAX_CERT_BYTES: usize = 16_384;
const HANDSHAKE_BYTES: usize = 131_072;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(3);
const FRAME_TIMEOUT: Duration = Duration::from_secs(2);
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TransportRejected;
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CertificatePin([u8; 32]);
impl CertificatePin {
    pub fn from_der(bytes: &[u8]) -> Result<Self, TransportRejected> {
        if bytes.is_empty() || bytes.len() > MAX_CERT_BYTES {
            return Err(TransportRejected);
        }
        Ok(Self(
            digest::digest(&digest::SHA256, bytes)
                .as_ref()
                .try_into()
                .map_err(|_| TransportRejected)?,
        ))
    }
    pub fn from_hex(text: &str) -> Result<Self, TransportRejected> {
        if text.len() != 64
            || !text
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        {
            return Err(TransportRejected);
        }
        let mut value = [0; 32];
        for (i, v) in value.iter_mut().enumerate() {
            *v = u8::from_str_radix(&text[i * 2..i * 2 + 2], 16).map_err(|_| TransportRejected)?;
        }
        Ok(Self(value))
    }
    pub fn hex(&self) -> String {
        self.0.iter().map(|b| format!("{b:02x}")).collect()
    }
}
#[derive(Debug)]
struct PinVerifier {
    pin: CertificatePin,
    provider: Arc<CryptoProvider>,
}
impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        intermediates: &[CertificateDer<'_>],
        server_name: &ServerName<'_>,
        ocsp: &[u8],
        now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        if CertificatePin::from_der(end_entity.as_ref()).ok() != Some(self.pin)
            || !intermediates.is_empty()
        {
            return Err(Error::General("host_pin_mismatch".into()));
        }
        // Pinning selects exactly one trust anchor; it never bypasses normal name/time validation.
        let mut roots = RootCertStore::empty();
        roots.add(end_entity.clone())?;
        let verifier =
            WebPkiServerVerifier::builder_with_provider(Arc::new(roots), self.provider.clone())
                .build()
                .map_err(|_| Error::General("invalid_pinned_certificate".into()))?;
        verifier.verify_server_cert(end_entity, intermediates, server_name, ocsp, now)
    }
    fn verify_tls12_signature(
        &self,
        _: &[u8],
        _: &CertificateDer<'_>,
        _: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        Err(Error::General("tls12_disabled".into()))
    }
    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        signature: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            signature,
            &self.provider.signature_verification_algorithms,
        )
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}
fn client_config(pin: CertificatePin) -> Result<Arc<ClientConfig>, TransportRejected> {
    let provider = Arc::new(default_provider());
    let mut config = ClientConfig::builder_with_provider(provider.clone())
        .with_protocol_versions(&[&rustls::version::TLS13])
        .map_err(|_| TransportRejected)?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(PinVerifier { pin, provider }))
        .with_no_client_auth();
    config.alpn_protocols = vec![CONTROL_ALPN.to_vec()];
    config.enable_early_data = false;
    config.resumption = Resumption::disabled();
    Ok(Arc::new(config))
}
/// Ephemeral identity for isolated engineering. Persistent identity storage is a later owner operation.
pub struct ServerIdentity {
    certificate: CertificateDer<'static>,
    config: Arc<ServerConfig>,
    pin: CertificatePin,
}
impl ServerIdentity {
    pub fn generate() -> Result<Self, TransportRejected> {
        let (certificate, key) = Self::generate_material()?;
        Self::from_der(certificate, key)
    }
    pub(crate) fn generate_material() -> Result<(Vec<u8>, Vec<u8>), TransportRejected> {
        let mut params = rcgen::CertificateParams::new(vec![CONTROL_SERVER_NAME.to_string()])
            .map_err(|_| TransportRejected)?;
        let now = time::OffsetDateTime::now_utc();
        params.not_before = now - time::Duration::minutes(5);
        params.not_after = now + time::Duration::days(30);
        params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ServerAuth];
        let key = rcgen::KeyPair::generate().map_err(|_| TransportRejected)?;
        let cert = params.self_signed(&key).map_err(|_| TransportRejected)?;
        Ok((cert.der().to_vec(), key.serialize_der()))
    }
    /// Call only with key bytes loaded by the user-private native identity owner.
    pub fn from_der(certificate: Vec<u8>, key: Vec<u8>) -> Result<Self, TransportRejected> {
        if key.is_empty() || key.len() > MAX_CERT_BYTES {
            return Err(TransportRejected);
        }
        let pin = CertificatePin::from_der(&certificate)?;
        let certificate = CertificateDer::from(certificate);
        let key = PrivateKeyDer::try_from(key).map_err(|_| TransportRejected)?;
        let mut config = ServerConfig::builder_with_provider(Arc::new(default_provider()))
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(|_| TransportRejected)?
            .with_no_client_auth()
            .with_single_cert(vec![certificate.clone()], key)
            .map_err(|_| TransportRejected)?;
        config.alpn_protocols = vec![CONTROL_ALPN.to_vec()];
        config.max_early_data_size = 0;
        config.send_tls13_tickets = 0;
        config.session_storage = Arc::new(rustls::server::NoServerSessionStorage {});
        Ok(Self {
            certificate,
            config: Arc::new(config),
            pin,
        })
    }
    pub(crate) fn validate_current(&self) -> Result<(), TransportRejected> {
        PinVerifier {
            pin: self.pin,
            provider: Arc::new(default_provider()),
        }
        .verify_server_cert(
            &self.certificate,
            &[],
            &ServerName::try_from(CONTROL_SERVER_NAME).map_err(|_| TransportRejected)?,
            &[],
            UnixTime::now(),
        )
        .map(|_| ())
        .map_err(|_| TransportRejected)
    }
    pub fn certificate_der(&self) -> &[u8] {
        self.certificate.as_ref()
    }
    pub fn pin(&self) -> CertificatePin {
        self.pin
    }
}
/// Absolute per-operation deadline, including trickled reads/writes inside rustls complete_io.
struct BudgetSocket {
    socket: TcpStream,
    deadline: Instant,
    read_remaining: usize,
}
impl BudgetSocket {
    fn new(socket: TcpStream, timeout: Duration) -> io::Result<Self> {
        socket.set_nonblocking(false)?;
        socket.set_nodelay(true)?;
        Ok(Self {
            socket,
            deadline: Instant::now() + timeout,
            read_remaining: HANDSHAKE_BYTES,
        })
    }
    fn reset(&mut self, timeout: Duration) {
        self.deadline = Instant::now() + timeout;
        self.read_remaining = HANDSHAKE_BYTES;
    }
    fn remaining(&self) -> io::Result<Duration> {
        self.deadline
            .checked_duration_since(Instant::now())
            .filter(|d| !d.is_zero())
            .ok_or_else(|| io::Error::new(io::ErrorKind::TimedOut, "transport_deadline"))
    }
}
impl Read for BudgetSocket {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        if self.read_remaining == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "transport_read_limit",
            ));
        }
        self.socket.set_read_timeout(Some(self.remaining()?))?;
        let length = bytes.len().min(self.read_remaining);
        let count = self.socket.read(&mut bytes[..length])?;
        self.read_remaining -= count;
        Ok(count)
    }
}
impl Write for BudgetSocket {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        self.socket.set_write_timeout(Some(self.remaining()?))?;
        self.socket.write(bytes)
    }
    fn flush(&mut self) -> io::Result<()> {
        self.remaining()?;
        self.socket.flush()
    }
}
impl Drop for BudgetSocket {
    fn drop(&mut self) {
        let _ = self.socket.shutdown(Shutdown::Both);
    }
}
enum Stream {
    Client(StreamOwned<ClientConnection, BudgetSocket>),
    Server(StreamOwned<ServerConnection, BudgetSocket>),
}
impl Stream {
    fn reset(&mut self) {
        match self {
            Self::Client(s) => s.sock.reset(FRAME_TIMEOUT),
            Self::Server(s) => s.sock.reset(FRAME_TIMEOUT),
        }
    }
    fn read_exact(&mut self, bytes: &mut [u8]) -> io::Result<()> {
        match self {
            Self::Client(s) => s.read_exact(bytes),
            Self::Server(s) => s.read_exact(bytes),
        }
    }
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        match self {
            Self::Client(s) => s.write_all(bytes),
            Self::Server(s) => s.write_all(bytes),
        }
    }
    fn flush(&mut self) -> io::Result<()> {
        match self {
            Self::Client(s) => s.flush(),
            Self::Server(s) => s.flush(),
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameKind {
    Control,
    Input,
}
impl FrameKind {
    fn byte(self) -> u8 {
        match self {
            Self::Control => 1,
            Self::Input => 2,
        }
    }
    fn valid(self, length: usize) -> bool {
        match self {
            Self::Control => (1..=MAX_CONTROL_BYTES).contains(&length),
            Self::Input => length == crate::input_packet::PACKET_BYTES,
        }
    }
}
pub struct ControlFrame {
    pub kind: FrameKind,
    pub payload: Vec<u8>,
}
/// Host-authenticated transport, not an enrolled phone or an input authorization.
/// Blocking IO belongs on a bounded network worker, never the native safety tick owner.
pub struct ControlChannel {
    stream: Option<Stream>,
    server_pin: Option<CertificatePin>,
}
impl ControlChannel {
    pub fn connect_pinned(
        address: SocketAddr,
        pin: CertificatePin,
    ) -> Result<Self, TransportRejected> {
        let socket = TcpStream::connect_timeout(&address, HANDSHAKE_TIMEOUT)
            .map_err(|_| TransportRejected)?;
        Self::connect_socket(socket, pin)
    }
    fn connect_socket(socket: TcpStream, pin: CertificatePin) -> Result<Self, TransportRejected> {
        let mut socket =
            BudgetSocket::new(socket, HANDSHAKE_TIMEOUT).map_err(|_| TransportRejected)?;
        let mut conn = ClientConnection::new(
            client_config(pin)?,
            ServerName::try_from(CONTROL_SERVER_NAME).map_err(|_| TransportRejected)?,
        )
        .map_err(|_| TransportRejected)?;
        conn.set_buffer_limit(Some(MAX_CONTROL_BYTES + 4096));
        while conn.is_handshaking() {
            conn.complete_io(&mut socket)
                .map_err(|_| TransportRejected)?;
        }
        if conn.protocol_version() != Some(rustls::ProtocolVersion::TLSv1_3)
            || conn.alpn_protocol() != Some(CONTROL_ALPN)
        {
            return Err(TransportRejected);
        }
        Ok(Self {
            stream: Some(Stream::Client(StreamOwned::new(conn, socket))),
            server_pin: None,
        })
    }
    pub fn accept_unenrolled(
        socket: TcpStream,
        identity: &ServerIdentity,
    ) -> Result<Self, TransportRejected> {
        let mut socket =
            BudgetSocket::new(socket, HANDSHAKE_TIMEOUT).map_err(|_| TransportRejected)?;
        let mut conn =
            ServerConnection::new(identity.config.clone()).map_err(|_| TransportRejected)?;
        conn.set_buffer_limit(Some(MAX_CONTROL_BYTES + 4096));
        while conn.is_handshaking() {
            conn.complete_io(&mut socket)
                .map_err(|_| TransportRejected)?;
        }
        if conn.protocol_version() != Some(rustls::ProtocolVersion::TLSv1_3)
            || conn.alpn_protocol() != Some(CONTROL_ALPN)
        {
            return Err(TransportRejected);
        }
        Ok(Self {
            stream: Some(Stream::Server(StreamOwned::new(conn, socket))),
            server_pin: Some(identity.pin()),
        })
    }
    pub(crate) fn native_server_pin(&self) -> Option<CertificatePin> {
        if self.stream.is_some() {
            self.server_pin
        } else {
            None
        }
    }
    pub fn close(&mut self) {
        self.stream = None;
    }
    pub fn send(&mut self, kind: FrameKind, payload: &[u8]) -> Result<(), TransportRejected> {
        if !kind.valid(payload.len()) {
            self.close();
            return Err(TransportRejected);
        }
        let result = (|| {
            let s = self.stream.as_mut().ok_or(TransportRejected)?;
            s.reset();
            s.write_all(&((payload.len() + 1) as u32).to_be_bytes())
                .map_err(|_| TransportRejected)?;
            s.write_all(&[kind.byte()]).map_err(|_| TransportRejected)?;
            s.write_all(payload).map_err(|_| TransportRejected)?;
            s.flush().map_err(|_| TransportRejected)
        })();
        if result.is_err() {
            self.close();
        }
        result
    }
    pub fn receive(&mut self) -> Result<ControlFrame, TransportRejected> {
        let result = (|| {
            let s = self.stream.as_mut().ok_or(TransportRejected)?;
            s.reset();
            let mut header = [0; 5];
            s.read_exact(&mut header[..4])
                .map_err(|_| TransportRejected)?;
            let total =
                u32::from_be_bytes(header[..4].try_into().map_err(|_| TransportRejected)?) as usize;
            if !(2..=MAX_CONTROL_BYTES + 1).contains(&total) {
                return Err(TransportRejected);
            }
            s.read_exact(&mut header[4..])
                .map_err(|_| TransportRejected)?;
            let length = total.checked_sub(1).ok_or(TransportRejected)?;
            let kind = match header[4] {
                1 => FrameKind::Control,
                2 => FrameKind::Input,
                _ => return Err(TransportRejected),
            };
            if !kind.valid(length) {
                return Err(TransportRejected);
            }
            let mut payload = vec![0; length];
            s.read_exact(&mut payload).map_err(|_| TransportRejected)?;
            Ok(ControlFrame { kind, payload })
        })();
        if result.is_err() {
            self.close();
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{net::TcpListener, thread};
    fn bind_listener() -> TcpListener {
        TcpListener::bind("127.0.0.1:0").unwrap()
    }
    fn certificate(params: rcgen::CertificateParams) -> ServerIdentity {
        let key = rcgen::KeyPair::generate().unwrap();
        let cert = params.self_signed(&key).unwrap();
        ServerIdentity::from_der(cert.der().to_vec(), key.serialize_der()).unwrap()
    }
    fn raw_connect(
        address: SocketAddr,
        config: Arc<ClientConfig>,
    ) -> Result<StreamOwned<ClientConnection, BudgetSocket>, TransportRejected> {
        let mut socket =
            BudgetSocket::new(TcpStream::connect(address).unwrap(), HANDSHAKE_TIMEOUT).unwrap();
        let mut conn =
            ClientConnection::new(config, ServerName::try_from(CONTROL_SERVER_NAME).unwrap())
                .unwrap();
        while conn.is_handshaking() {
            conn.complete_io(&mut socket)
                .map_err(|_| TransportRejected)?;
        }
        Ok(StreamOwned::new(conn, socket))
    }
    #[test]
    fn pinned_tls13_round_trip_control_and_exact_input_frames() {
        let identity = ServerIdentity::generate().unwrap();
        let pin = identity.pin();
        let listener = bind_listener();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_nodelay(true).unwrap();
            let mut channel = ControlChannel::accept_unenrolled(stream, &identity).unwrap();
            let control = channel.receive().unwrap();
            assert_eq!(control.kind, FrameKind::Control);
            assert_eq!(control.payload, b"configuration-v1");
            let input = channel.receive().unwrap();
            assert_eq!(input.kind, FrameKind::Input);
            assert_eq!(input.payload, vec![7; 108]);
            channel.send(FrameKind::Control, b"receipt-v1").unwrap();
            channel.close();
            assert!(channel.send(FrameKind::Control, b"retired").is_err());
            assert!(channel.receive().is_err());
        });
        let mut client = ControlChannel::connect_pinned(address, pin).unwrap();
        client
            .send(FrameKind::Control, b"configuration-v1")
            .unwrap();
        client.send(FrameKind::Input, &[7; 108]).unwrap();
        assert_eq!(client.receive().unwrap().payload, b"receipt-v1");
        server.join().unwrap();
    }
    #[test]
    fn certificate_pin_is_canonical_and_identity_is_fresh() {
        let a = ServerIdentity::generate().unwrap();
        let b = ServerIdentity::generate().unwrap();
        assert_ne!(a.pin(), b.pin());
        assert_eq!(
            a.pin(),
            CertificatePin::from_der(a.certificate_der()).unwrap()
        );
        assert_eq!(a.pin(), CertificatePin::from_hex(&a.pin().hex()).unwrap());
        for invalid in [
            "",
            "abcd",
            &"0".repeat(63),
            &"A".repeat(64),
            &"g".repeat(64),
            &"é".repeat(32),
        ] {
            assert!(CertificatePin::from_hex(invalid).is_err());
        }
        assert!(CertificatePin::from_der(&[]).is_err());
        assert!(CertificatePin::from_der(&vec![0; MAX_CERT_BYTES + 1]).is_err());
        assert!(ServerIdentity::from_der(vec![0; 16], vec![0; 16]).is_err());
    }
    #[test]
    fn wrong_pin_refuses_handshake_before_any_application_frame() {
        let identity = ServerIdentity::generate().unwrap();
        let wrong = ServerIdentity::generate().unwrap().pin();
        let listener = bind_listener();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            ControlChannel::accept_unenrolled(listener.accept().unwrap().0, &identity).is_err()
        });
        assert!(ControlChannel::connect_pinned(address, wrong).is_err());
        assert!(server.join().unwrap());
    }
    #[test]
    fn pin_does_not_bypass_expiry_future_dates_hostname_or_server_usage() {
        for mode in 0..4 {
            let mut params = rcgen::CertificateParams::new(vec![if mode == 2 {
                "wrong.local"
            } else {
                CONTROL_SERVER_NAME
            }
            .to_string()])
            .unwrap();
            if mode == 0 {
                params.not_before = rcgen::date_time_ymd(2000, 1, 1);
                params.not_after = rcgen::date_time_ymd(2001, 1, 1);
            }
            if mode == 1 {
                params.not_before = rcgen::date_time_ymd(3000, 1, 1);
                params.not_after = rcgen::date_time_ymd(3001, 1, 1);
            }
            if mode == 3 {
                params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ClientAuth];
            }
            let identity = certificate(params);
            let pin = identity.pin();
            let listener = bind_listener();
            let address = listener.local_addr().unwrap();
            let server = thread::spawn(move || {
                ControlChannel::accept_unenrolled(listener.accept().unwrap().0, &identity).is_err()
            });
            assert!(
                ControlChannel::connect_pinned(address, pin).is_err(),
                "mode {mode}"
            );
            assert!(server.join().unwrap());
        }
    }
    #[test]
    fn unsupported_alpn_and_tls12_are_rejected() {
        for mode in 0..3 {
            let identity = ServerIdentity::generate().unwrap();
            let pin = identity.pin();
            let listener = bind_listener();
            let address = listener.local_addr().unwrap();
            let server = thread::spawn(move || {
                ControlChannel::accept_unenrolled(listener.accept().unwrap().0, &identity).is_err()
            });
            let mut config = (*client_config(pin).unwrap()).clone();
            if mode == 0 {
                config.alpn_protocols = vec![b"legacy/1".to_vec()];
            } else if mode == 1 {
                config.alpn_protocols = vec![];
            } else {
                let provider = Arc::new(default_provider());
                config = ClientConfig::builder_with_provider(provider.clone())
                    .with_protocol_versions(&[&rustls::version::TLS12])
                    .unwrap()
                    .dangerous()
                    .with_custom_certificate_verifier(Arc::new(PinVerifier { pin, provider }))
                    .with_no_client_auth();
                config.alpn_protocols = vec![CONTROL_ALPN.to_vec()];
            }
            let _ = raw_connect(address, Arc::new(config));
            assert!(server.join().unwrap());
        }
    }
    #[test]
    fn framing_accepts_maximum_control_and_rejects_local_invalid_frames_terminally() {
        let identity = ServerIdentity::generate().unwrap();
        let pin = identity.pin();
        let listener = bind_listener();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let mut c =
                ControlChannel::accept_unenrolled(listener.accept().unwrap().0, &identity).unwrap();
            let p = c.receive().unwrap();
            assert_eq!(p.payload, vec![13; MAX_CONTROL_BYTES]);
        });
        let mut client = ControlChannel::connect_pinned(address, pin).unwrap();
        client
            .send(FrameKind::Control, &vec![13; MAX_CONTROL_BYTES])
            .unwrap();
        server.join().unwrap();
        for (kind, length) in [
            (FrameKind::Control, 0),
            (FrameKind::Control, MAX_CONTROL_BYTES + 1),
            (FrameKind::Input, 107),
            (FrameKind::Input, 109),
        ] {
            let identity = ServerIdentity::generate().unwrap();
            let pin = identity.pin();
            let listener = bind_listener();
            let address = listener.local_addr().unwrap();
            let server = thread::spawn(move || {
                let mut c =
                    ControlChannel::accept_unenrolled(listener.accept().unwrap().0, &identity)
                        .unwrap();
                assert!(c.receive().is_err());
            });
            let mut client = ControlChannel::connect_pinned(address, pin).unwrap();
            assert!(client.send(kind, &vec![1; length]).is_err());
            assert!(client.send(FrameKind::Control, b"after-error").is_err());
            server.join().unwrap();
        }
    }
    #[test]
    fn malformed_remote_lengths_kinds_and_truncation_retire_connection() {
        for (length, kind, body) in [
            (0u32, 1u8, 0usize),
            (1, 1, 0),
            (u32::MAX, 1, 0),
            (2, 9, 1),
            (108, 2, 107),
            (110, 2, 109),
            (10, 1, 3),
        ] {
            let identity = ServerIdentity::generate().unwrap();
            let pin = identity.pin();
            let listener = bind_listener();
            let address = listener.local_addr().unwrap();
            let server = thread::spawn(move || {
                let mut c =
                    ControlChannel::accept_unenrolled(listener.accept().unwrap().0, &identity)
                        .unwrap();
                assert!(c.receive().is_err());
                assert!(c.receive().is_err());
            });
            let mut client = raw_connect(address, client_config(pin).unwrap()).unwrap();
            let mut frame = length.to_be_bytes().to_vec();
            frame.push(kind);
            frame.extend(vec![0; body]);
            let _ = client.write_all(&frame);
            let _ = client.flush();
            drop(client);
            server.join().unwrap();
        }
    }
    #[test]
    fn absolute_io_budget_cannot_be_extended_by_trickled_reads() {
        let listener = bind_listener();
        let address = listener.local_addr().unwrap();
        let sender = thread::spawn(move || {
            let mut socket = TcpStream::connect(address).unwrap();
            for _ in 0..100 {
                if socket.write_all(&[1]).is_err() {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
        });
        let socket = listener.accept().unwrap().0;
        let mut budget = BudgetSocket::new(socket, Duration::from_millis(75)).unwrap();
        let mut bytes = [0; 100];
        assert!(budget.read_exact(&mut bytes).is_err());
        drop(budget);
        sender.join().unwrap();
    }
    #[test]
    fn read_byte_budget_and_unresponsive_peer_fail_closed() {
        let listener = bind_listener();
        let address = listener.local_addr().unwrap();
        let sender = thread::spawn(move || {
            let mut socket = TcpStream::connect(address).unwrap();
            let _ = socket.write_all(&[1; 32]);
        });
        let socket = listener.accept().unwrap().0;
        let mut budget = BudgetSocket::new(socket, Duration::from_secs(1)).unwrap();
        budget.read_remaining = 8;
        assert!(budget.read_exact(&mut [0; 9]).is_err());
        drop(budget);
        sender.join().unwrap();
        let listener = bind_listener();
        let address = listener.local_addr().unwrap();
        let peer = thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            thread::sleep(Duration::from_millis(100));
            drop(socket);
        });
        let socket = TcpStream::connect(address).unwrap();
        let mut budget = BudgetSocket::new(socket, Duration::from_millis(20)).unwrap();
        assert!(budget.read_exact(&mut [0; 1]).is_err());
        peer.join().unwrap();
    }
}

#[cfg(test)]
mod socket_mode_tests {
    use super::*;
    use std::{net::TcpListener, thread};
    #[test]
    fn accepted_and_client_nonblocking_sockets_are_normalized_before_tls() {
        let identity = ServerIdentity::generate().unwrap();
        let pin = identity.pin();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (socket, _) = listener.accept().unwrap();
            socket.set_nonblocking(true).unwrap();
            let mut channel = ControlChannel::accept_unenrolled(socket, &identity).unwrap();
            assert_eq!(channel.receive().unwrap().payload, b"mode-normalized");
            channel.send(FrameKind::Control, b"accepted").unwrap();
        });
        let socket = TcpStream::connect(address).unwrap();
        socket.set_nonblocking(true).unwrap();
        let mut client = ControlChannel::connect_socket(socket, pin).unwrap();
        client.send(FrameKind::Control, b"mode-normalized").unwrap();
        assert_eq!(client.receive().unwrap().payload, b"accepted");
        server.join().unwrap();
    }
}
