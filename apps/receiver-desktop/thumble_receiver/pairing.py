"""Process-local TLS identity and private-IPv4 pairing invitations."""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import ipaddress
import json
import secrets
import socket
import ssl
from pathlib import Path
import tempfile
import time

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID


def private_ipv4(value):
    address = ipaddress.IPv4Address(value)
    if not any(address in ipaddress.IPv4Network(network)
               for network in ('10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16')):
        raise ValueError('Choose an RFC1918 IPv4 address on the phone Wi-Fi network')
    return str(address)


def detect_address():
    # UDP connect selects the default interface without transmitting a packet.
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect(('192.0.2.1', 9))
        return private_ipv4(probe.getsockname()[0])


def identity():
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Thumble Receiver')])
    now = datetime.now(timezone.utc)
    certificate = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
                   .public_key(key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(now - timedelta(minutes=5)).not_valid_after(now + timedelta(days=2))
                   .sign(key, hashes.SHA256()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    # Close handles before loading/removing files so this works on Windows too.
    with tempfile.TemporaryDirectory(prefix='thumble-tls-') as temporary:
        cert_path, key_path = Path(temporary) / 'cert.pem', Path(temporary) / 'key.pem'
        cert_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
        key_path.touch(mode=0o600)
        key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM,
                                              serialization.PrivateFormat.PKCS8,
                                              serialization.NoEncryption()))
        context.load_cert_chain(cert_path, key_path)
    fingerprint = hashlib.sha256(certificate.public_bytes(serialization.Encoding.DER)).hexdigest()
    return context, fingerprint


class Invitation:
    def __init__(self, address, port, fingerprint, wall=time.time):
        self.address, self.port, self.fingerprint, self.wall = address, port, fingerprint, wall
        self.token, self.expires = '', 0

    def renew(self):
        self.token, self.expires = secrets.token_hex(32), int(self.wall() + 120)
        payload = dict(v=1, url=f'wss://{self.address}:{self.port}/controller',
                       pin=self.fingerprint, token=self.token, expires=self.expires)
        encoded = base64.urlsafe_b64encode(json.dumps(payload, separators=(',', ':')).encode()).decode().rstrip('=')
        return 'thumble://pair?data=' + encoded

    def redeem(self, token):
        if (not self.token or not isinstance(token, str) or not token.isascii()
                or self.wall() > self.expires or not secrets.compare_digest(token, self.token)):
            return False
        self.token = ''
        return True
