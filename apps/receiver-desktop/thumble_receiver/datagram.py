"""The existing phone AES-GCM datagram contract, scoped to one pinned TLS peer."""
import asyncio
import json
import secrets
import struct

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

from .clock import monotonic
from .profiles import encoded, load_json


class DatagramCipher:
    def __init__(self, key, server=True):
        if len(key) != 32:
            raise ValueError('Expected a 256-bit datagram key')
        self.aes = AESGCM(key)
        self.sending, self.receiving = (2, 1) if server else (1, 2)
        self.sent, self.received = 0, 0

    def seal(self, data):
        if len(data) > 1100 or self.sent >= 2 ** 64 - 1:
            raise ValueError('Datagram limit exceeded')
        self.sent += 1
        nonce = struct.pack('>IQ', self.sending, self.sent)
        return nonce + self.aes.encrypt(nonce, data, b'tapping-udp-v1')

    def open(self, packet):
        if not 28 <= len(packet) <= 1128:
            raise ValueError('Invalid datagram size')
        direction, sequence = struct.unpack('>IQ', packet[:12])
        if direction != self.receiving or sequence <= self.received:
            raise ValueError('Wrong direction or replayed datagram')
        data = self.aes.decrypt(packet[:12], packet[12:], b'tapping-udp-v1')
        self.received = sequence  # An unauthenticated counter must never advance replay state.
        return data


class DatagramInput(asyncio.DatagramProtocol):
    def __init__(self, session, on_failure, clock=monotonic):
        self.session, self.on_failure, self.clock = session, on_failure, clock
        self.key = secrets.token_bytes(32)
        self.cipher = DatagramCipher(self.key)
        self.transport, self.endpoint = None, None
        self.closed = False
        self.window, self.packets = clock(), 0

    @classmethod
    async def create(cls, host, session, on_failure):
        instance = cls(session, on_failure)
        transport, _ = await asyncio.get_running_loop().create_datagram_endpoint(
            lambda: instance, local_addr=(host, 0))
        instance.transport = transport
        return instance

    @property
    def port(self):
        return self.transport.get_extra_info('sockname')[1]

    def datagram_received(self, packet, address):
        if self.closed or (self.endpoint is not None and address != self.endpoint):
            return
        now = self.clock()
        if now - self.window >= 1:
            self.window, self.packets = now, 0
        self.packets += 1
        # No unauthenticated endpoint allocations; also bound crypto work per tick.
        if self.packets > (2048 if self.endpoint is not None else 64):
            return
        try:
            clear = self.cipher.open(packet)
            message = load_json(clear)
            if not isinstance(message, dict):
                return
        except (ValueError, TypeError, InvalidTag, UnicodeError, RecursionError):
            return
        if self.endpoint is None:
            if message.get('type') != 'probe':
                return
            self.endpoint = address
        if message.get('type') == 'probe':
            self.send(dict(type='udp-ready'))
        elif message.get('type') == 'input':
            try:
                for reply in self.session.handle(message, udp=True):
                    self.send(reply)
            except (ValueError, TypeError, KeyError, OSError, RuntimeError):
                self.close()
                self.on_failure()

    def send(self, value):
        if not self.closed and self.endpoint is not None:
            try:
                self.transport.sendto(self.cipher.seal(encoded(value)), self.endpoint)
            except (OSError, ValueError):
                self.close()
                self.on_failure()

    def error_received(self, error):
        self.close()
        self.on_failure()

    def close(self):
        if not self.closed:
            self.closed = True
            if self.transport:
                self.transport.close()
