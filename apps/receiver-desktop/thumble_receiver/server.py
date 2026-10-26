"""Bounded WSS transport and the v3 phone protocol; no gameplay cloud relay."""
import asyncio
import base64
import contextlib
from concurrent.futures import ThreadPoolExecutor
import json
import time
import threading
import uuid

from websockets.asyncio.server import serve
from websockets.exceptions import ConnectionClosed

from .state import NEUTRAL, State, integer
from .clock import monotonic
from .consoleport import ConsolePortSync
from .profiles import ProfileStore, ProfileError, load_json
from .chat import ChatError, validate as validate_chat
from .datagram import DatagramInput
from .pairing_image import PairingImage


class ProtocolError(ValueError):
    pass


def decode(text, adoption=False):
    if not isinstance(text, str) or len(text.encode('utf-8')) > (65536 if adoption else 4096):
        raise ProtocolError('Expected a small JSON text frame')
    value = load_json(text)
    if not isinstance(value, dict):
        raise ProtocolError('Expected object')
    if len(text.encode('utf-8')) > 4096 and value.get('type') != 'profile-adopt':
        raise ProtocolError('Only authenticated profile adoption accepts large messages')
    return value


class Session:
    def __init__(self, output, access, clock=monotonic, chat_available=False):
        self.output, self.access, self.clock = output, access, clock
        self.sequence, self.last_input, self.last_pause = -1, clock(), 0
        self.leases = {}
        self.paused, self.enabled = True, False
        self.generation = output.generation
        self.revision, self.profile, self.layout_pending, self.layout_deadline = 0, None, False, 0
        self.profile_busy = False
        self.chat_available, self.chat_busy, self.chat_cancel = chat_available, False, None
        self.chat_results = {}

    def activate(self, active):
        if not active or active['revision'] <= self.revision:
            return []
        self.pause()
        self.enabled = False
        self.revision, self.profile = active['revision'], active['profile']
        self.layout_pending, self.layout_deadline = True, self.clock() + 5
        return [self.access.snapshot(False), dict(type='layout', revision=self.revision, profile=self.profile)]

    def status(self):
        return dict(updatedAt=time.time() * 1000, connected=True,
                    ready=not self.layout_pending and not self.paused,
                    revision=self.revision, pro=self.access.pro, receiverId=self.access.receiver_id)

    def pause(self, revoke=True):
        if self.chat_cancel:
            self.chat_cancel.set()
        self.output.release()
        self.generation = self.output.generation
        if revoke:
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
            value.update(access=1, profiles=1, cloudAdoption=1)
            if self.chat_available:
                value['chat'] = 1
        return value

    def handle(self, message, udp=False):
        kind = message.get('type')
        if kind == 'bye':
            raise ProtocolError('Phone disconnected')
        if kind == 'access-pause':
            self.enabled = False
            # The phone sends access-pause immediately before profile-adopt,
            # using its current lease for the adoption. Keep that lease valid
            # until its original deadline; paused held input still cannot rearm.
            self.pause(revoke=False)
            return [self.access.snapshot(False)] + ([] if self.layout_pending else [self.ack('paused')])
        if kind == 'access-resume':
            if self.layout_pending:
                return [self.access.snapshot(False)]
            self.pause()
            self.enabled = self.access.pro or self.access.used < 1800
            return [self.access.snapshot(self.enabled), self.ack('paused')]
        if kind == 'access-grant':
            self.pause()
            self.enabled = False
            self.access.submit(message.get('grant'))
            return [self.access.snapshot(False)] + ([] if self.layout_pending else [self.ack('paused')])
        if kind == 'layout-ready':
            value = message.get('revision')
            if not integer(value) or value > self.revision:
                raise ProtocolError('Invalid layout acknowledgement')
            if value != self.revision or not self.layout_pending:
                return []
            self.layout_pending = False
            self.pause()
            self.last_input = self.clock()
            return [self.ack('paused')]
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
        if self.layout_pending or type(message.get('revision')) is not int or message['revision'] != self.revision:
            return []
        sequence = message.get('seq')
        if udp and integer(sequence) and sequence <= self.sequence:
            return []  # Datagram reordering is normal; TCP replay is a protocol error.
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
        allowed = self.enabled and self.access.running and not self.chat_busy
        deadline = self.last_input + 0.3
        if allowed and not self.access.pro:
            deadline = min(deadline, self.access.deadline)
        if not self.output.apply(state if allowed else NEUTRAL, deadline, self.generation):
            self.pause()
            return [self.ack('paused')]
        return [self.ack('ack')]

    def tick(self):
        now = self.clock()
        if self.layout_pending:
            if now >= self.layout_deadline:
                raise ProtocolError('Phone did not acknowledge the layout')
            return []
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
    def __init__(self, output, access, invitation, on_invitation=lambda _: None, profiles=None, wow_roots=(),
                 enable_udp=False, chat=None):
        self.output, self.access, self.invitation = output, access, invitation
        self.on_invitation = on_invitation
        self.peer = None
        self.clients = 0
        self.profiles = profiles if profiles is not None else ProfileStore(access.directory / 'profiles')
        self.sync = ConsolePortSync(self.profiles, wow_roots)
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix='thumble-profiles')
        self.active = None
        self.session = None
        self.profile_error = ''
        self.enable_udp, self.chat = enable_udp, chat
        self.chat_worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix='thumble-chat')
        self.pairing_image = PairingImage(self.profiles.directory)
        self.current_invitation = ''
        self.on_status = lambda _: None
        self.closing = False

    async def chat_request(self, socket, session, message):
        request = message.get('id')
        if not isinstance(request, str) or not 0 < len(request.encode()) <= 80:
            return
        if request in session.chat_results:
            await self.send(socket, [session.chat_results[request]])
            return
        result = dict(type='chat-result', id=request)
        try:
            if self.chat is None:
                raise ChatError('WoW chat is unavailable on this desktop. Check the receiver setup instructions.')
            validate_chat(message.get('text'), message.get('channel'))
            lease = message.get('lease')
            if session.chat_busy:
                raise ChatError('Another chat message is being delivered. Please wait.')
            if not session.enabled or not self.access.running or (
                    not self.access.pro and session.clock() >= self.access.deadline):
                raise ChatError('Start or resume the demo, or restore Pro, before sending chat.')
            if (session.layout_pending or type(message.get('revision')) is not int
                    or message['revision'] != session.revision or not isinstance(lease, str)
                    or session.clock() > session.leases.get(lease, float('-inf'))):
                raise ChatError('Connection changed. Review your message and try again.')
            if len(session.chat_results) >= 1000:
                raise ChatError('Reconnect the phone to continue chatting.')
        except (ChatError, UnicodeError) as error:
            result['error'] = str(error)
            await self.send(socket, [result])
            return
        session.pause()
        session.chat_busy = True
        session.chat_cancel = threading.Event()
        session.chat_results[request] = dict(type='chat-result', id=request,
            error='This message was already submitted. Check WoW before trying again.')
        try:
            await self.send(socket, [session.ack('paused')])
            await asyncio.get_running_loop().run_in_executor(self.chat_worker, self.chat.send,
                message['text'], message['channel'], session.chat_cancel)
        except (ChatError, OSError, RuntimeError) as error:
            result['error'] = str(error) if isinstance(error, ChatError) else 'Delivery could not be confirmed. Check WoW before retrying.'
        finally:
            session.chat_busy = False
            session.chat_cancel.set()
        session.chat_results[request] = result
        if self.peer is socket:
            session.pause(revoke=False)
            await self.send(socket, [result] + ([] if session.layout_pending else [session.ack('paused')]))

    async def work(self, function, *args):
        return await asyncio.get_running_loop().run_in_executor(self.worker, function, *args)

    def catalog(self):
        data = self.profiles.read()
        summary = self.profiles.summary(data)
        summary['consolePortBridge'] = dict(enabled=bool(self.sync.roots), detail=self.sync.detail)
        return summary, data.get('active')

    async def profile_request(self, socket, session, message):
        request, kind = message.get('id'), message.get('type')
        if not isinstance(request, str) or not 0 < len(request.encode()) <= 80:
            return
        result = dict(type='profiles-result', id=request)
        if session.profile_busy:
            result['error'] = 'Another profile request is in progress.'
            await self.send(socket, [result])
            return
        session.profile_busy = True
        did_pause = False
        try:
            if kind == 'profiles-list':
                catalog, active = await self.work(self.catalog)
            else:
                lease = message.get('lease')
                if (session.layout_pending or session.chat_busy or not isinstance(lease, str)
                        or session.clock() > session.leases.get(lease, float('-inf'))):
                    raise ProfileError('Connection changed. Refresh and try again.')
                # Disk locks, validation, and atomic writes never retain held input.
                session.enabled = False
                session.pause()
                did_pause = True
                await self.send(socket, [self.access.snapshot(False), session.ack('paused')])
                if kind == 'profile-select':
                    catalog, active = await self.work(self.profiles.select, message.get('profileId'),
                                                       message.get('profileRevision'), message.get('expectedActivationRevision'))
                else:
                    catalog, active = await self.work(self.profiles.adopt, message.get('profile'),
                                                       message.get('source'), message.get('expectedActivationRevision'))
            if self.peer is not socket:
                return
            self.active = active if not self.active or (active and active['revision'] > self.active['revision']) else self.active
            replies = session.activate(self.active)
            result['catalog'] = catalog
            await self.send(socket, replies + [result])
        except (ValueError, OSError, TypeError, KeyError) as error:
            self.profile_error = str(error)
            result['error'] = 'Profile request failed. Check the profile, refresh the list, and try again.'
            if self.peer is socket:
                await self.send(socket, [result] + ([session.ack('paused')] if did_pause and not session.layout_pending else []))
        finally:
            session.profile_busy = False

    def renew(self):
        if self.closing:
            return
        self.current_invitation = self.invitation.renew()
        self.on_invitation(self.current_invitation)

    async def reset_pairing(self):
        if self.session:
            self.session.pause()
        if self.peer:
            await self.peer.close(code=1000)
        else:
            self.renew()

    async def configure_sync(self, roots):
        def configure():
            self.sync.roots = list(roots)
            self.sync.pending = None
            self.sync.stamps = {}
            self.sync.detail = 'ConsolePort: waiting for /reload' if roots else 'ConsolePort sync off'
            self.sync.poll(baseline=True)
        await self.work(configure)

    async def send(self, socket, values):
        for value in values:
            # A stalled client must not retain a session indefinitely.
            await asyncio.wait_for(socket.send(json.dumps(value, ensure_ascii=False, allow_nan=False,
                                                         separators=(',', ':'))), timeout=0.2)

    async def handler(self, socket):
        if self.clients >= 4 or socket.request.path != '/controller':
            await socket.close(code=1008)
            return
        self.clients += 1
        ticker = None
        session = None
        datagram = None
        profile_tasks = set()
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
            self.current_invitation = ''
            self.on_invitation('')
            self.output.release()
            await self.work(self.pairing_image.clear)
            self.access.pair(phone_id, hello.get('demoUsed', 0))
            session = Session(self.output, self.access, chat_available=self.chat is not None)
            self.session = session
            await self.send(socket, [session.ack('ready'), self.access.snapshot(False)] + session.activate(self.active))
            if self.enable_udp and type(hello.get('datagram')) is int and hello['datagram'] == 1:
                def datagram_failed():
                    if self.peer is socket:
                        with contextlib.suppress(OSError, RuntimeError):
                            session.pause()
                        asyncio.create_task(socket.close(code=1008))
                try:
                    host = socket.local_address[0]
                    datagram = await DatagramInput.create(host, session, datagram_failed)
                    await self.send(socket, [dict(type='udp-offer', port=datagram.port,
                                                 key=base64.b64encode(datagram.key).decode())])
                except OSError:
                    pass  # WSS remains fully functional if UDP cannot bind.

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
                message = decode(text, adoption=True)
                if message.get('type') in ('profiles-list', 'profile-select', 'profile-adopt', 'chat'):
                    operation = self.chat_request if message.get('type') == 'chat' else self.profile_request
                    task = asyncio.create_task(operation(socket, session, message))
                    profile_tasks.add(task)
                    # Bound work even when a peer ignores the single-request protocol.
                    if len(profile_tasks) >= 4:
                        await asyncio.gather(*profile_tasks)
                        profile_tasks.clear()
                else:
                    await self.send(socket, session.handle(message))
                # Retrieve errors from completed tasks rather than accumulating them.
                completed = {task for task in profile_tasks if task.done()}
                if completed:
                    await asyncio.gather(*completed)
                    profile_tasks -= completed
        except (ValueError, TypeError, KeyError, OSError, RuntimeError, TimeoutError, ConnectionClosed):
            if session:
                session.pause()
            await socket.close(code=1008)
        finally:
            if session and session.chat_cancel:
                session.chat_cancel.set()
            if datagram:
                datagram.close()
            # A transaction already dispatched to the worker may finish after a peer
            # disconnects, but its callback may never activate a replacement session.
            for task in profile_tasks:
                task.cancel()
            if profile_tasks:
                await asyncio.gather(*profile_tasks, return_exceptions=True)
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
                    self.session = None
                    self.renew()
            self.clients -= 1

    async def run(self, host, port, context, stop):
        try:
            await self._run(host, port, context, stop)
        finally:
            self.closing = True
            self.current_invitation = ''
            self.on_invitation('')
            with contextlib.suppress(OSError):
                await self.work(self.pairing_image.clear)
            with contextlib.suppress(OSError, ValueError):
                await self.work(self.profiles.write_status, dict(updatedAt=time.time() * 1000,
                                connected=False, ready=False, revision=self.active['revision'] if self.active else 0,
                                pro=False, receiverId=self.access.receiver_id))
            self.worker.shutdown(wait=True, cancel_futures=True)
            self.chat_worker.shutdown(wait=True, cancel_futures=True)

    async def _run(self, host, port, context, stop):
        _, self.active = await self.work(self.catalog)
        await self.work(self.sync.poll, True)
        async with serve(self.handler, host, port, ssl=context, max_size=65536,
                         max_queue=4, compression=None, open_timeout=5,
                         close_timeout=1, ping_interval=20, ping_timeout=5) as server:
            self.invitation.port = server.sockets[0].getsockname()[1]
            self.renew()

            async def refresh():
                count = 0
                while True:
                    await asyncio.sleep(0.25)
                    if self.peer is None and time.time() > self.invitation.expires:
                        self.renew()
                    count += 1
                    try:
                        if count % 8 == 0 and self.sync.roots:
                            await self.work(self.sync.poll)
                        _, active = await self.work(self.catalog)
                        if active and (not self.active or active['revision'] > self.active['revision']):
                            self.active = active
                            if self.peer and self.session:
                                await self.send(self.peer, self.session.activate(active))
                        status = self.session.status() if self.session else dict(
                            updatedAt=time.time() * 1000, connected=False, ready=False,
                            revision=self.active['revision'] if self.active else 0,
                            pro=False, receiverId=self.access.receiver_id)
                        await self.work(self.profiles.write_status, status)
                        self.on_status({**status, 'sync': self.sync.detail})
                        if count % 4 == 0:
                            await self.work(self.pairing_image.publish, self.current_invitation, self.invitation.expires)
                    except (OSError, ValueError, TypeError, KeyError) as error:
                        self.profile_error = str(error)
                    except (ConnectionClosed, TimeoutError):
                        pass

            refresh_task = asyncio.create_task(refresh())
            try:
                await stop.wait()
            finally:
                self.closing = True
                refresh_task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await refresh_task
