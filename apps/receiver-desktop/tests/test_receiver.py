import asyncio
import base64
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import shutil
import ssl
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from thumble_receiver.access import Access, PUBLIC_KEY
from thumble_receiver.lock import DirectoryLock
from thumble_receiver.output import GuardedOutput, MemoryOutput
from thumble_receiver.pairing import Invitation, identity, private_ipv4
from thumble_receiver.server import ReceiverServer, Session, ProtocolError, decode
from thumble_receiver.state import NEUTRAL, State


class Clock:
    value = 100.0

    def __call__(self):
        return self.value


class StateTests(unittest.TestCase):
    def test_report_matches_mac_contract(self):
        self.assertEqual(NEUTRAL.report(), bytes([0, 20] + [0] * 18))
        for index, bit in enumerate((12, 13, 14, 15, 8, 9, 5, 4, 6, 7, 0, 1, 2, 3, 10)):
            state = State(buttons=1 << index)
            self.assertEqual(int.from_bytes(state.report()[2:4], 'little'), 1 << bit)
        state = State(buttons=32767, lx=-1, ly=1, rx=-0.5, ry=0.5, lt=0.5, rt=1)
        self.assertEqual(state.report().hex(), '0014f0f780ff0080ff7f00c00040000000000000')
        self.assertEqual(State(buttons=(1 << 10) | (1 << 11)).mask, 0)
        self.assertEqual(State(buttons=(1 << 12) | (1 << 13)).mask, 0)

    def test_invalid_states(self):
        neutral = dict(NEUTRAL.__dict__)
        for key, value in [('buttons', True), ('buttons', 1.0), ('buttons', 32768),
                           ('lx', float('nan')), ('ry', float('inf')), ('lt', -0.1),
                           ('rt', 1.01), ('lx', '0'), ('ly', False), ('lx', 10 ** 400)]:
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                State.parse({**neutral, key: value})
        for value in ({}, {**neutral, 'extra': 1}, [], None):
            with self.assertRaises(ValueError):
                State.parse(value)

    def test_transport_bounds(self):
        for value in (b'{}', '[]', '{"x":NaN}', '{"x":Infinity}', ' ' * 4097):
            with self.assertRaises(ValueError):
                decode(value)


class AccessTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.clock = Clock()
        self.key = Ed25519PrivateKey.generate()
        public = base64.b64encode(self.key.public_key().public_bytes(
            serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
        self.access = Access(self.directory.name, public, self.clock, self.clock)
        self.access.pair(str(uuid.uuid4()), 0)

    def grant(self, **overrides):
        payload = dict(v=1, receiverId=self.access.receiver_id, phoneId=self.access.phone_id,
                       nonce=self.access.nonce, productId='thumble_pro_lifetime', pro=True,
                       issuedAt=100, expiresAt=200)
        payload.update(overrides)
        data = json.dumps(payload).encode()
        return dict(payload=base64.b64encode(data).decode(),
                    signature=base64.b64encode(self.key.sign(data)).decode())

    def test_crash_predebit_and_pause_refund(self):
        self.access.start()
        self.assertEqual(Access(self.directory.name).used, 5)
        self.clock.value += 2
        self.access.pause()
        reloaded = Access(self.directory.name)
        self.assertEqual(reloaded.used, 2)
        self.assertEqual(reloaded.receiver_id, self.access.receiver_id)
        self.access.pair(str(uuid.uuid4()), 500)
        self.assertEqual(self.access.used, 500)

    def test_matches_production_purchase_key(self):
        config = Path(__file__).resolve().parents[3] / 'config/monetization.json'
        self.assertEqual(PUBLIC_KEY, json.loads(config.read_text())['entitlementPublicKey'])

    def test_directory_lock_blocks_concurrent_ledgers_and_releases(self):
        first = DirectoryLock(self.directory.name)
        try:
            with self.assertRaises(RuntimeError):
                DirectoryLock(self.directory.name)
        finally:
            first.close()
        DirectoryLock(self.directory.name).close()

    def test_corrupt_ledger_and_failed_write_exhaust_demo(self):
        Path(self.directory.name, 'demo.json').write_text('{}')
        self.assertEqual(Access(self.directory.name).used, 1800)
        self.access.directory = Path(self.directory.name) / 'missing'
        self.access.start()
        self.assertFalse(self.access.running)
        self.assertEqual(self.access.used, 1800)

    def test_refill_and_exhaustion(self):
        self.access.used = 1794
        self.access.start()
        self.clock.value = 104.5
        self.access.tick()
        self.assertEqual(self.access.deadline, 106)
        self.clock.value = 106
        self.access.tick()
        self.assertFalse(self.access.running)
        self.assertEqual(self.access.snapshot(True)['remaining'], 0)

    def test_signed_grant_binding_expiry_and_cache(self):
        grant = self.grant()
        self.access.submit(grant)
        self.assertTrue(self.access.pro)
        self.access.pair(self.access.phone_id, 0)
        self.assertTrue(self.access.pro)
        self.access.start()
        self.clock.value = 200
        self.access.tick()
        self.assertFalse(self.access.pro)
        self.assertFalse(self.access.running)

    def test_reject_forged_wrong_phone_nonce_and_product(self):
        for values in (dict(phoneId=str(uuid.uuid4())), dict(nonce=str(uuid.uuid4())),
                       dict(productId='other'), dict(expiresAt=100), dict(issuedAt=161),
                       dict(expiresAt=100 + 8 * 86400), dict(pro=1), dict(v=True)):
            self.access.submit(self.grant(**values))
            self.assertFalse(self.access.pro, values)
        grant = self.grant()
        grant['signature'] = base64.b64encode(bytes(64)).decode()
        self.access.submit(grant)
        self.assertFalse(self.access.pro)


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.clock = Clock()
        self.output = GuardedOutput(MemoryOutput(), self.clock)
        self.addCleanup(self.output.close)
        self.access = Access(self.directory.name, clock=self.clock)
        self.session = Session(self.output, self.access, self.clock)
        self.lease = self.session.ack('ready')['lease']

    def frame(self, state=NEUTRAL, seq=0, lease=None):
        return dict(type='input', revision=0, state=state.__dict__, seq=seq,
                    lease=self.lease if lease is None else lease)

    def test_access_resume_neutral_then_held_and_pause(self):
        replies = self.session.handle(dict(type='access-resume'))
        self.lease = replies[-1]['lease']
        self.assertEqual(self.session.handle(self.frame(State(buttons=1))), [])
        ack = self.session.handle(self.frame())[0]
        self.assertEqual(ack['type'], 'ack')
        self.session.handle(self.frame(State(buttons=1), seq=1, lease=ack['lease']))
        self.assertEqual(self.output.backend.state.buttons, 1)
        self.session.handle(dict(type='access-pause'))
        self.assertEqual(self.output.backend.state, NEUTRAL)

    def test_replay_invalid_state_and_unknown_lease(self):
        self.assertEqual(self.session.handle(self.frame(lease='unknown')), [])
        self.session.handle(self.frame())
        with self.assertRaises(ProtocolError):
            self.session.handle(self.frame())
        with self.assertRaises(ValueError):
            self.session.handle({**self.frame(seq=1), 'state': dict(buttons=1)})

    def test_watchdog_revokes_leases_and_requires_neutral(self):
        self.session.handle(self.frame())
        self.clock.value += 0.301
        paused = self.session.tick()[0]
        self.assertEqual(paused['type'], 'paused')
        self.assertEqual(self.session.handle(self.frame(seq=1)), [])
        self.assertEqual(self.session.handle(self.frame(State(buttons=1), 1, paused['lease'])), [])
        self.assertEqual(self.session.handle(self.frame(seq=2, lease=paused['lease']))[0]['type'], 'ack')
        self.clock.value += 2.01
        with self.assertRaises(ProtocolError):
            self.session.tick()

    def test_independent_watchdog_invalidates_parsed_input(self):
        generation = self.output.generation
        self.output.apply(State(buttons=1), self.clock() + 0.01, generation)
        self.clock.value += 0.02
        self.output.expire()
        self.assertEqual(self.output.backend.state, NEUTRAL)
        self.assertFalse(self.output.apply(State(buttons=1), self.clock() + 1, generation))
        self.assertEqual(self.session.handle(self.frame())[0]['type'], 'paused')

    def test_real_watchdog_runs_without_asyncio(self):
        backend = MemoryOutput()
        output = GuardedOutput(backend)
        try:
            output.apply(State(buttons=1), output.clock() + 0.03, output.generation)
            deadline = time.monotonic() + 1
            while backend.state != NEUTRAL and time.monotonic() < deadline:
                threading.Event().wait(0.01)
            self.assertEqual(backend.state, NEUTRAL)
        finally:
            output.close()

    def test_layout_commit_needs_current_revision_fresh_neutral_and_resume(self):
        self.session.enabled = True
        self.output.apply(State(buttons=1), self.clock() + 0.3, self.output.generation)
        replies = self.session.activate(dict(revision=1, profile={'id': 'first'}))
        self.assertEqual(replies[-1]['type'], 'layout')
        self.assertEqual(self.output.backend.state, NEUTRAL)
        self.assertFalse(self.session.enabled)
        self.session.activate(dict(revision=2, profile={'id': 'second'}))
        self.assertEqual(self.session.handle(dict(type='layout-ready', revision=1)), [])
        self.assertEqual(self.session.handle(self.frame()), [])
        with self.assertRaises(ProtocolError):
            self.session.handle(dict(type='layout-ready', revision=3))
        paused = self.session.handle(dict(type='layout-ready', revision=2))[0]
        frame = {**self.frame(State(buttons=1), lease=paused['lease']), 'revision': 2}
        self.assertEqual(self.session.handle(frame), [])
        self.assertEqual(self.session.handle({**frame, 'state': NEUTRAL.__dict__})[0]['type'], 'ack')
        self.assertFalse(self.session.enabled)
        self.assertEqual(self.session.handle(self.frame(seq=1)), [])

    def test_layout_timeout_is_five_seconds_and_does_not_refresh_on_old_input(self):
        self.session.activate(dict(revision=1, profile={'id': 'first'}))
        self.clock.value += 4
        self.assertEqual(self.session.tick(), [])
        self.assertEqual(self.session.handle(self.frame()), [])
        self.clock.value += 1
        with self.assertRaises(ProtocolError):
            self.session.tick()


class PairingTests(unittest.TestCase):
    def test_private_addresses_and_single_use_expiry(self):
        for address in ('192.168.1.2', '10.0.0.2', '172.31.255.1'):
            self.assertEqual(private_ipv4(address), address)
        for address in ('127.0.0.1', '8.8.8.8', '169.254.1.1', '172.32.0.1', '::1'):
            with self.assertRaises(ValueError):
                private_ipv4(address)
        clock = Clock()
        invitation = Invitation('192.168.1.2', 1234, 'a' * 64, clock)
        link = invitation.renew()
        payload = json.loads(base64.urlsafe_b64decode(link.split('=')[1] + '==='))
        self.assertEqual(payload['url'], 'wss://192.168.1.2:1234/controller')
        self.assertFalse(invitation.redeem('é'))
        self.assertTrue(invitation.redeem(payload['token']))
        self.assertFalse(invitation.redeem(payload['token']))
        invitation.renew()
        clock.value += 121
        self.assertFalse(invitation.redeem(invitation.token))


class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.output = GuardedOutput(MemoryOutput())
        self.context, self.fingerprint = identity()
        self.invitation = Invitation('127.0.0.1', 0, self.fingerprint)
        self.ready = asyncio.Queue()
        self.server = ReceiverServer(self.output, Access(self.directory.name), self.invitation,
                                     lambda value: self.ready.put_nowait(value) if value else None)
        self.stop = asyncio.Event()
        self.task = asyncio.create_task(self.server.run('127.0.0.1', 0, self.context, self.stop))
        await asyncio.wait_for(self.ready.get(), 5)
        self.client_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        self.client_context.check_hostname = False
        self.client_context.verify_mode = ssl.CERT_NONE
        self.url = f'wss://127.0.0.1:{self.invitation.port}/controller'

    async def asyncTearDown(self):
        self.stop.set()
        await asyncio.wait_for(self.task, 5)
        self.output.close()
        self.directory.cleanup()

    async def hello(self, socket, token=None):
        der = socket.transport.get_extra_info('ssl_object').getpeercert(binary_form=True)
        self.assertEqual(hashlib.sha256(der).hexdigest(), self.fingerprint)
        await socket.send(json.dumps(dict(type='hello', v=3, phoneId=str(uuid.uuid4()),
                                          token=token if token is not None else self.invitation.token)))

    async def receive(self, socket, kind):
        while True:
            value = json.loads(await asyncio.wait_for(socket.recv(), 3))
            if value['type'] == kind:
                return value

    async def test_tls_pair_input_ack_and_release_on_disconnect(self):
        async with connect(self.url, ssl=self.client_context, proxy=None) as socket:
            await self.hello(socket)
            ready = await self.receive(socket, 'ready')
            self.assertEqual(ready['access'], 1)
            self.assertNotIn('chat', ready)
            self.assertEqual(ready['profiles'], 1)
            await self.receive(socket, 'access')
            await socket.send(json.dumps(dict(type='access-resume')))
            paused = await self.receive(socket, 'paused')
            frame = dict(type='input', seq=0, revision=0, lease=paused['lease'], state=NEUTRAL.__dict__)
            await socket.send(json.dumps(frame))
            ack = await self.receive(socket, 'ack')
            await socket.send(json.dumps({**frame, 'seq': 1, 'lease': ack['lease'],
                                          'state': State(buttons=1).__dict__}))
            await self.receive(socket, 'ack')
            self.assertEqual(self.output.backend.state.buttons, 1)
        await asyncio.wait_for(self.ready.get(), 3)
        self.assertEqual(self.output.backend.state, NEUTRAL)

    async def test_wrong_token_binary_and_path_rejected(self):
        for mode in ('token', 'binary', 'path'):
            async with connect(self.url if mode != 'path' else self.url + '/bad',
                               ssl=self.client_context, proxy=None) as socket:
                if mode == 'token':
                    await self.hello(socket, token='wrong')
                elif mode == 'binary':
                    await socket.send(b'{}')
                with self.assertRaises(ConnectionClosed):
                    await asyncio.wait_for(socket.recv(), 2)

    async def test_second_peer_cannot_steal_session(self):
        token = self.invitation.token
        async with connect(self.url, ssl=self.client_context, proxy=None) as first:
            await self.hello(first)
            await self.receive(first, 'ready')
            async with connect(self.url, ssl=self.client_context, proxy=None) as second:
                await self.hello(second, token)
                with self.assertRaises(ConnectionClosed):
                    await second.recv()
            self.assertIsNotNone(self.server.peer)

    async def test_watchdog_pauses_then_closes_idle_peer(self):
        async with connect(self.url, ssl=self.client_context, proxy=None) as socket:
            await self.hello(socket)
            await self.receive(socket, 'ready')
            await self.receive(socket, 'paused')
            with self.assertRaises(ConnectionClosed):
                while True:
                    await asyncio.wait_for(socket.recv(), 3)

    async def test_phone_profile_selection_and_persisted_reconnect(self):
        async with connect(self.url, ssl=self.client_context, proxy=None) as socket:
            await self.hello(socket)
            ready = await self.receive(socket, 'ready')
            await socket.send(json.dumps(dict(type='profiles-list', id='list')))
            catalog = (await self.receive(socket, 'profiles-result'))['catalog']
            self.assertEqual(catalog['activationRevision'], 0)
            await socket.send(json.dumps(dict(type='profile-select', id='select', profileId='consoleport-standard',
                                               profileRevision=1, expectedActivationRevision=0, lease=ready['lease'])))
            layout = await self.receive(socket, 'layout')
            result = await self.receive(socket, 'profiles-result')
            self.assertEqual(result['catalog']['activationRevision'], layout['revision'])
            await socket.send(json.dumps(dict(type='layout-ready', revision=layout['revision'])))
            paused = await self.receive(socket, 'paused')
            await socket.send(json.dumps(dict(type='input', revision=layout['revision'], seq=0,
                                               lease=paused['lease'], state=NEUTRAL.__dict__)))
            await self.receive(socket, 'ack')
            self.assertFalse(self.server.session.enabled)
            await asyncio.sleep(0.3)
            status = json.loads((self.server.profiles.directory / 'receiver-status.json').read_bytes())
            self.assertTrue(status['ready'])
            self.assertEqual(status['revision'], 1)
        await asyncio.wait_for(self.ready.get(), 3)
        async with connect(self.url, ssl=self.client_context, proxy=None) as socket:
            await self.hello(socket)
            await self.receive(socket, 'ready')
            layout = await self.receive(socket, 'layout')
            self.assertEqual(layout['profile']['id'], 'consoleport-standard')
            self.assertEqual(layout['revision'], 1)

    async def test_agent_file_activation_reaches_phone_and_supersedes_old_render(self):
        async with connect(self.url, ssl=self.client_context, proxy=None) as socket:
            await self.hello(socket)
            await self.receive(socket, 'ready')
            await asyncio.to_thread(self.server.profiles.select, 'consoleport-standard', 1, 0)
            first = await self.receive(socket, 'layout')
            await asyncio.to_thread(self.server.profiles.select, 'xbox-standard', 1, 1)
            second = await self.receive(socket, 'layout')
            self.assertGreater(second['revision'], first['revision'])
            await socket.send(json.dumps(dict(type='layout-ready', revision=first['revision'])))
            await asyncio.sleep(0.03)
            self.assertTrue(self.server.session.layout_pending)
            await socket.send(json.dumps(dict(type='layout-ready', revision=second['revision'])))
            await self.receive(socket, 'paused')
            self.assertFalse(self.server.session.layout_pending)

    async def test_large_frames_require_authenticated_adoption(self):
        async with connect(self.url, ssl=self.client_context, proxy=None) as socket:
            await self.hello(socket)
            ready = await self.receive(socket, 'ready')
            profile = deepcopy(self.server.profiles.builtins[1])
            for control in profile['controls']:
                control['label'] = 'Long label ' * 7
            self.assertGreater(len(json.dumps(profile)), 4096)
            source = dict(service='https://thumble.example/v1', accountId='a' * 64,
                           profileId=profile['id'], revision=1)
            await socket.send(json.dumps(dict(type='profile-adopt', id='adopt', profile=profile, source=source,
                                               expectedActivationRevision=0, lease=ready['lease'])))
            layout = await self.receive(socket, 'layout')
            result = await self.receive(socket, 'profiles-result')
            self.assertEqual(layout['profile']['id'], result['catalog']['adoption']['profileId'])
            await socket.send(json.dumps(dict(type='profiles-list', id='x' * 5000)))
            with self.assertRaises(ConnectionClosed):
                while True:
                    await socket.recv()

    async def test_real_phone_connection_selects_and_adopts_with_layout_receipts(self):
        await self.run_phone_client()

    async def run_phone_client(self, udp=False, chat=False):
        if not shutil.which('node'):
            self.skipTest('Node is required for the real phone connection test')
        self.invitation.address = '192.168.1.2'
        link = self.invitation.renew()
        process = await asyncio.create_subprocess_exec('node', str(Path(__file__).with_name('phone-client.mjs')),
                    stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(json.dumps(
                dict(invitation=link, expectUdp=udp, expectChat=chat)).encode()), 12)
            self.assertEqual(process.returncode, 0, stderr.decode() + '\nReceiver: ' + self.server.profile_error)
            self.assertIn('PASS real phone connection', stdout.decode())
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()

    async def test_real_phone_uses_encrypted_udp_and_chat_control_over_tls(self):
        calls = []

        class Chat:
            def send(self, text, channel, cancelled):
                calls.append((text, channel))

        self.server.enable_udp = True
        self.server.chat = Chat()
        await self.run_phone_client(udp=True, chat=True)
        self.assertEqual(calls, [('literal hello 😀', 'say')])

    async def test_chat_replay_cannot_type_twice_and_pause_cancels_delivery(self):
        calls, started = [], threading.Event()

        class Chat:
            def send(self, text, channel, cancelled):
                calls.append((text, channel))
                started.set()
                if cancelled.wait(2):
                    from thumble_receiver.chat import ChatError
                    raise ChatError('Delivery cancelled.')

        self.server.chat = Chat()
        async with connect(self.url, ssl=self.client_context, proxy=None) as socket:
            await self.hello(socket)
            ready = await self.receive(socket, 'ready')
            self.assertEqual(ready['chat'], 1)
            await socket.send(json.dumps(dict(type='access-resume')))
            paused = await self.receive(socket, 'paused')
            frame = dict(type='input', revision=0, seq=0, lease=paused['lease'], state=NEUTRAL.__dict__)
            await socket.send(json.dumps(frame))
            ack = await self.receive(socket, 'ack')
            request = dict(type='chat', id='one-chat', revision=0, lease=ack['lease'], text='hello', channel='say')
            await socket.send(json.dumps(request))
            await self.receive(socket, 'paused')
            deadline = time.monotonic() + 1
            while not started.is_set() and time.monotonic() < deadline:
                await asyncio.sleep(0.005)
            self.assertTrue(started.is_set())
            await socket.send(json.dumps(request))
            result = await self.receive(socket, 'chat-result')
            self.assertIn('already submitted', result['error'])
            await socket.send(json.dumps(dict(type='access-pause')))
            result = await self.receive(socket, 'chat-result')
            self.assertIn('cancelled', result['error'])
            self.assertEqual(calls, [('hello', 'say')])

    async def test_slow_profile_disk_work_releases_controls_without_blocking_input(self):
        gate = threading.Event()
        original = self.server.profiles.select

        def delayed(*args):
            gate.wait(2)
            return original(*args)

        async with connect(self.url, ssl=self.client_context, proxy=None) as socket:
            await self.hello(socket)
            await self.receive(socket, 'ready')
            await socket.send(json.dumps(dict(type='access-resume')))
            paused = await self.receive(socket, 'paused')
            frame = dict(type='input', revision=0, seq=0, lease=paused['lease'], state=NEUTRAL.__dict__)
            await socket.send(json.dumps(frame))
            ack = await self.receive(socket, 'ack')
            await socket.send(json.dumps({**frame, 'seq': 1, 'lease': ack['lease'], 'state': State(buttons=1).__dict__}))
            ack = await self.receive(socket, 'ack')
            self.assertEqual(self.output.backend.state.buttons, 1)
            with patch.object(self.server.profiles, 'select', side_effect=delayed):
                try:
                    await socket.send(json.dumps(dict(type='profile-select', id='slow', profileId='consoleport-standard',
                        profileRevision=1, expectedActivationRevision=0, lease=ack['lease'])))
                    paused = await self.receive(socket, 'paused')
                    self.assertEqual(self.output.backend.state, NEUTRAL)
                    await socket.send(json.dumps({**frame, 'seq': 2, 'lease': paused['lease']}))
                    ack = await asyncio.wait_for(self.receive(socket, 'ack'), 0.5)
                    self.assertEqual(ack['seq'], 2)
                finally:
                    gate.set()
                await self.receive(socket, 'layout')
                result = await self.receive(socket, 'profiles-result')
                self.assertEqual(result['catalog']['activationRevision'], 1)


if __name__ == '__main__':
    unittest.main()
