"""Durable, prepaid demo time and the existing Ed25519 entitlement contract."""
import base64
import json
import os
from pathlib import Path
import time
import uuid

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

from .state import number
from .clock import monotonic

PUBLIC_KEY = 'iZ110UZOAtUhFZirDAp6EiuA11GEixRYzkmeXRJ88sM='


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
    def __init__(self, directory, public_key=PUBLIC_KEY, clock=monotonic, wall=time.time):
        self.directory = Path(directory)
        self.public_key, self.clock, self.wall = public_key, clock, wall
        self.receiver_id, self.nonce = str(uuid.uuid4()), str(uuid.uuid4())
        self.phone_id = ''
        self.used = self.deadline = self.grant_expires = self.grant_issued = 0
        self.pro = self.running = False
        self.error = ''
        self.cached = None
        try:
            self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            ledger = self.directory / 'demo.json'
            if ledger.exists():
                value = json.loads(ledger.read_text(encoding='utf-8'))
                self.receiver_id = str(uuid.UUID(value['receiverId']))
                if not number(value['used']) or not 0 <= value['used'] <= 1800:
                    raise ValueError('Invalid demo ledger')
                self.used = value['used']
            else:
                self.persist()
            grant = self.directory / 'pro-grant.json'
            if grant.exists():
                self.cached = json.loads(grant.read_text(encoding='utf-8'))
        except (OSError, ValueError, KeyError, TypeError):
            self.used = 1800
            self.error = 'Demo record could not be loaded. Restore Pro or contact support.'

    def persist(self):
        atomic_json(self.directory / 'demo.json',
                    dict(version=1, receiverId=self.receiver_id, used=self.used))

    def save(self):
        try:
            self.persist()
            return True
        except OSError:
            self.used, self.deadline, self.running = 1800, 0, False
            self.error = 'Demo time could not be saved. Restore Pro or contact support.'
            return False

    def pause(self):
        if self.running and not self.pro:
            self.used = max(0, self.used - max(0, self.deadline - self.clock()))
            self.save()
        self.running, self.deadline = False, 0

    def pair(self, phone_id, mirrored):
        self.pause()
        self.phone_id, self.nonce, self.pro = phone_id, str(uuid.uuid4()), False
        if self.cached:
            try:
                self.accept(self.cached, require_nonce=False)
            except Exception:
                pass
        self.used = max(self.used, mirrored if number(mirrored) and 0 <= mirrored <= 1800 else 0)
        self.save()

    def start(self):
        if self.running:
            return
        if self.pro:
            self.running = True
            return
        reserve = min(5, 1800 - self.used)
        if reserve > 0:
            self.used += reserve
            if self.save():
                self.running, self.deadline = True, self.clock() + reserve

    def tick(self):
        if self.pro and self.wall() >= self.grant_expires:
            self.pause()
            self.pro = False
        if self.running and not self.pro:
            if self.clock() >= self.deadline:
                self.running = False
            elif self.deadline - self.clock() <= 1 and self.used < 1800:
                reserve = min(5, 1800 - self.used)
                self.used += reserve
                if self.save():
                    self.deadline += reserve

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
        self.pause()
        self.grant_issued, self.grant_expires, self.pro = issued, expires, payload['pro']

    def submit(self, grant):
        try:
            self.accept(grant)
            atomic_json(self.directory / 'pro-grant.json', grant)
            self.cached, self.error = grant, ''
        except Exception:
            self.pause()
            self.pro = False
            self.error = 'Pro could not be verified on this computer. Retry Restore Purchases.'

    def snapshot(self, enabled):
        remaining = max(0, 1800 - self.used + (max(0, self.deadline - self.clock())
                                             if self.running and not self.pro else 0))
        return dict(type='access', v=1, pro=self.pro, remaining=remaining,
                    debitedUsed=self.used, running=self.running, receiverId=self.receiver_id,
                    nonce=self.nonce, error=self.error, grantExpires=self.grant_expires, enabled=enabled)
