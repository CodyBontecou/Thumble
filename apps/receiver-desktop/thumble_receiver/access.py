"""Plan grants under the existing Ed25519 entitlement contract, and the receiver record."""
import base64
import contextlib
import json
import os
from pathlib import Path
import time
import uuid

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from .state import number

PUBLIC_KEY = 'iZ110UZOAtUhFZirDAp6EiuA11GEixRYzkmeXRJ88sM='
LOAD_ERROR = 'Receiver record could not be loaded. Restore your plan in Thumble on your phone, or contact support.'
SAVE_ERROR = 'Receiver record could not be saved. Restore your plan in Thumble on your phone, or contact support.'
GRANT_ERROR = 'Your plan could not be verified on this computer. Tap Restore in Thumble on your phone.'


def atomic_json(path, value):
    temporary = path.with_name(path.name + '.tmp')
    try:
        with open(temporary, 'w', encoding='utf-8') as stream:
            os.chmod(temporary, 0o600)
            json.dump(value, stream, allow_nan=False, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


class Access:
    """Controller output requires a valid plan grant; there is no free time."""

    def __init__(self, directory, public_key=PUBLIC_KEY, wall=time.time):
        self.directory = Path(directory)
        self.public_key, self.wall = public_key, wall
        self.receiver_id, self.nonce = str(uuid.uuid4()), str(uuid.uuid4())
        self.phone_id = ''
        self.grant_expires = self.grant_issued = 0
        self.pro = self.running = False
        self.error = ''
        self.cached = None
        # demo.json is the receiver record. It once also metered the retired free demo;
        # it stays because plan grants are bound to its receiverId, which must never
        # rotate for existing installs. New records keep a spent `used` value so the
        # file stays readable by older receivers; this receiver ignores it.
        record = self.directory / 'demo.json'
        try:
            self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            if record.exists():
                self.receiver_id = str(uuid.UUID(json.loads(record.read_text(encoding='utf-8'))['receiverId']))
            else:
                try:
                    atomic_json(record, dict(version=1, receiverId=self.receiver_id, used=1800))
                except OSError:
                    self.error = SAVE_ERROR
                    return
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            # Never replace an unreadable record: that would rotate the receiver ID.
            self.error = LOAD_ERROR
            return
        with contextlib.suppress(OSError, ValueError):
            self.cached = json.loads((self.directory / 'pro-grant.json').read_text(encoding='utf-8'))

    def pause(self):
        self.running = False

    def pair(self, phone_id):
        self.running = False
        self.phone_id, self.nonce, self.pro = phone_id, str(uuid.uuid4()), False
        if self.cached:
            try:
                self.accept(self.cached, require_nonce=False)
            except Exception:
                pass

    def start(self):
        if self.pro:
            self.running = True

    def tick(self):
        if self.pro and self.wall() >= self.grant_expires:
            self.running = self.pro = False

    def accept(self, grant, require_nonce=True):
        data = base64.b64decode(grant['payload'], validate=True)
        signature = base64.b64decode(grant['signature'], validate=True)
        Ed25519PublicKey.from_public_bytes(base64.b64decode(self.public_key, validate=True)).verify(signature, data)
        payload = json.loads(data)
        issued, expires = payload['issuedAt'], payload['expiresAt']
        if not (type(payload['v']) is int and payload['v'] == 1
                and payload['receiverId'] == self.receiver_id and payload['phoneId'] == self.phone_id
                and payload['productId'] == 'thumble_pro_lifetime' and type(payload['pro']) is bool
                and number(issued) and number(expires) and issued >= self.grant_issued
                and issued <= self.wall() + 60 and expires > self.wall()
                and 0 < expires - issued <= 7 * 86400
                and (not require_nonce or payload['nonce'] == self.nonce)):
            raise ValueError('Invalid entitlement')
        # Ownership changes always require an explicit Resume from neutral input.
        self.running = False
        self.grant_issued, self.grant_expires, self.pro = issued, expires, payload['pro']

    def submit(self, grant):
        try:
            self.accept(grant)
            atomic_json(self.directory / 'pro-grant.json', grant)
            self.cached, self.error = grant, ''
        except Exception:
            self.running = self.pro = False
            self.error = GRANT_ERROR

    def snapshot(self, enabled):
        # remaining and debitedUsed stay on the wire for older phone builds.
        return dict(type='access', v=1, pro=self.pro, remaining=0,
                    debitedUsed=1800, running=self.running, receiverId=self.receiver_id,
                    nonce=self.nonce, error=self.error, grantExpires=self.grant_expires, enabled=enabled)
