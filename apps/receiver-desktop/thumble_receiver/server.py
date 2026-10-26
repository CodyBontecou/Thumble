"""Bounded WSS transport and the v3 phone protocol; no gameplay cloud relay."""
import asyncio
import contextlib
import json
import time
import uuid

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

from .state import NEUTRAL, State, integer
from .clock import monotonic


class ProtocolError(ValueError):
    pass


def decode(text):
    def invalid(_):
        raise ProtocolError('Non-finite JSON number')

    if not isinstance(text, str) or len(text.encode('utf-8')) > 4096:
        raise ProtocolError('Expected a small JSON text frame')
    value = json.loads(text, parse_constant=invalid)
    if not isinstance(value, dict):
        raise ProtocolError('Expected object')
    return value


class Session:
    def __init__(self, output, access, clock=monotonic):
        self.output, self.access, self.clock = output, access, clock
        self.sequence, self.last_input, self.last_pause = -1, clock(), 0
        self.leases = {}
        self.paused, self.enabled = True, False
        self.generation = output.generation

    def pause(self):
        self.output.release()
        self.generation = self.output.generation
        self.leases.clear()
        self.paused = True
        self.access.pause()

    def ack(self, kind):
        now = self.clock()
        self.leases = {key: deadline for key, deadline in self.leases.items() if deadline > now}
        if len(self.leases) >= 256:
            raise ProtocolError('Input rate exceeded')
        lease = str(uuid.uuid4())
        self.leases[lease] = now + 0.5
        value = dict(type=kind, seq=self.sequence, lease=lease)
        if kind == 'ready':
            value['access'] = 1
        return value

    def handle(self, message):
        kind = message.get('type')
        if kind == 'bye':
            raise ProtocolError('Phone disconnected')
        if kind == 'access-pause':
            self.enabled = False
            self.pause()
            return [self.access.snapshot(False), self.ack('paused')]
        if kind == 'access-resume':
            self.pause()
            self.enabled = self.access.pro or self.access.used < 1800
            return [self.access.snapshot(self.enabled), self.ack('paused')]
        if kind == 'access-grant':
            self.pause()
            self.enabled = False
            self.access.submit(message.get('grant'))
            return [self.access.snapshot(False), self.ack('paused')]
        if kind in ('profiles-list', 'profile-select', 'profile-adopt', 'chat'):
            # Do not advertise unfinished features, or leave older clients waiting.
            request = message.get('id')
            if isinstance(request, str) and 0 < len(request.encode()) <= 80:
                return [dict(type='chat-result' if kind == 'chat' else 'profiles-result',
                             id=request, error='This feature is not available in the desktop preview.')]
            return []
        if kind == 'latency':
            return []
        if kind != 'input':
            raise ProtocolError('Unknown message')
        # This receiver uses the phone's built-in layout (revision zero).
        if type(message.get('revision')) is not int or message['revision'] != 0:
            return []
        sequence = message.get('seq')
        if not integer(sequence) or sequence <= self.sequence:
            raise ProtocolError('Invalid or stale sequence')
        state = State.parse(message.get('state'))
        lease = message.get('lease')
        if not isinstance(lease, str) or self.clock() > self.leases.get(lease, float('-inf')):
            return []
        # Independent watchdog may already have released while the event loop stalled.
        if (self.generation != self.output.generation
                or (not self.paused and self.clock() - self.last_input >= 0.3)):
            self.pause()
            return [self.ack('paused')]
        if self.paused and state != NEUTRAL:
            return []
        self.paused = False
        self.sequence, self.last_input = sequence, self.clock()
        if self.enabled:
            self.access.start()
        allowed = self.enabled and self.access.running
        deadline = self.last_input + 0.3
        if allowed and not self.access.pro:
            deadline = min(deadline, self.access.deadline)
        if not self.output.apply(state if allowed else NEUTRAL, deadline, self.generation):
            self.pause()
            return [self.ack('paused')]
        return [self.ack('ack')]

    def tick(self):
        now = self.clock()
        if now - self.last_input > 2:
            raise ProtocolError('Input timed out')
        self.access.tick()
        replies = []
        if self.enabled and not self.access.pro and self.access.used >= 1800 and not self.access.running:
            self.enabled = False
            self.pause()
        if self.generation != self.output.generation or now - self.last_input >= 0.3:
            if not self.paused or self.generation != self.output.generation:
                self.pause()
            if now - self.last_pause >= 0.08:
                replies.append(self.ack('paused'))
                self.last_pause = now
        return replies


class ReceiverServer:
    def __init__(self, output, access, invitation, on_invitation=lambda _: None):
        self.output, self.access, self.invitation = output, access, invitation
        self.on_invitation = on_invitation
        self.peer = None
        self.clients = 0

    def renew(self):
        self.on_invitation(self.invitation.renew())

    async def send(self, socket, values):
        for value in values:
            # A stalled client must not retain a session indefinitely.
            await asyncio.wait_for(socket.send(json.dumps(value, allow_nan=False)), timeout=0.2)

    async def handler(self, socket):
        if self.clients >= 4 or socket.request.path != '/controller':
            await socket.close(code=1008)
            return
        self.clients += 1
        ticker = None
        session = None
        try:
            hello = decode(await asyncio.wait_for(socket.recv(), timeout=5))
            phone_id = hello.get('phoneId')
            if not isinstance(phone_id, str) or len(phone_id) != 36:
                raise ProtocolError('Invalid phone identity')
            uuid.UUID(phone_id)
            if (self.peer is not None or hello.get('type') != 'hello'
                    or type(hello.get('v')) is not int or hello['v'] != 3
                    or not self.invitation.redeem(hello.get('token'))):
                raise ProtocolError('Pairing unavailable')
            self.peer = socket
            self.output.release()
            self.access.pair(phone_id, hello.get('demoUsed', 0))
            session = Session(self.output, self.access)
            await self.send(socket, [session.ack('ready'), self.access.snapshot(False)])

            async def tick():
                last_access = 0
                try:
                    while True:
                        await asyncio.sleep(0.02)
                        replies = session.tick()
                        if time.monotonic() - last_access >= 0.25:
                            replies.append(self.access.snapshot(session.enabled))
                            last_access = time.monotonic()
                        await self.send(socket, replies)
                except (ProtocolError, OSError, RuntimeError, TimeoutError):
                    session.pause()
                    await socket.close(code=1008)

            ticker = asyncio.create_task(tick())
            async for text in socket:
                await self.send(socket, session.handle(decode(text)))
        except (ValueError, TypeError, KeyError, OSError, RuntimeError, TimeoutError, ConnectionClosed):
            if session:
                session.pause()
            await socket.close(code=1008)
        finally:
            if ticker:
                ticker.cancel()
                with contextlib.suppress(asyncio.CancelledError, ConnectionClosed):
                    await ticker
            if self.peer is socket:
                try:
                    if session:
                        session.pause()
                    else:
                        self.output.release()
                finally:
                    self.peer = None
                    self.renew()
            self.clients -= 1

    async def run(self, host, port, context, stop):
        async with serve(self.handler, host, port, ssl=context, max_size=4096,
                         max_queue=4, compression=None, open_timeout=5,
                         close_timeout=1, ping_interval=20, ping_timeout=5) as server:
            self.invitation.port = server.sockets[0].getsockname()[1]
            self.renew()

            async def refresh():
                while True:
                    await asyncio.sleep(1)
                    if self.peer is None and time.time() > self.invitation.expires:
                        self.renew()

            refresh_task = asyncio.create_task(refresh())
            try:
                await stop.wait()
            finally:
                refresh_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await refresh_task
