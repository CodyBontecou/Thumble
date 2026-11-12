"""Packaged-runtime smoke test with real TLS and memory-only output."""
import asyncio
import base64
import hashlib
import json
import ssl
import tempfile
import time
import uuid

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from .access import Access
from .output import GuardedOutput, MemoryOutput, native_output
from .pairing import Invitation, identity
from .server import ReceiverServer
from .state import NEUTRAL, State


def plan_grant(key, access, phone_id):
    """A plan grant signed by the self-test's own throwaway key, for its own temporary receiver."""
    now = time.time()
    payload = json.dumps(dict(v=1, productId='thumble_pro_lifetime', receiverId=access['receiverId'],
                              phoneId=phone_id, nonce=access['nonce'], pro=True,
                              issuedAt=now, expiresAt=now + 600)).encode()
    return dict(payload=base64.b64encode(payload).decode(), signature=base64.b64encode(key.sign(payload)).decode())


async def selftest(native=False):
    context, fingerprint = identity()
    # Output requires a plan grant. The self-test verifies grants against a key pair it
    # creates here, used only by the temporary receiver below; the production key and
    # the user's receiver are never involved.
    grant_key = Ed25519PrivateKey.generate()
    public_key = base64.b64encode(grant_key.public_key().public_bytes_raw()).decode()
    backend = native_output() if native else MemoryOutput()
    output = GuardedOutput(backend)
    native_probe = None
    async def verify(state):
        if native_probe:
            from .native_probe import wait_for
            await asyncio.to_thread(wait_for, native_probe, state)
        elif output.backend.state != state:
            raise RuntimeError('Output state did not match the authenticated input')
    try:
        if native:
            from .native_probe import probe
            native_probe = probe(backend)
        with tempfile.TemporaryDirectory(prefix='thumble-selftest-') as directory:
            ready = asyncio.Event()
            invitation = Invitation('127.0.0.1', 0, fingerprint)
            server = ReceiverServer(output, Access(directory, public_key), invitation, lambda _: ready.set())
            stop = asyncio.Event()
            task = asyncio.create_task(server.run('127.0.0.1', 0, context, stop))
            try:
                await asyncio.wait_for(ready.wait(), 5)
                client_context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
                client_context.check_hostname = False
                client_context.verify_mode = ssl.CERT_NONE
                async with connect(f'wss://127.0.0.1:{invitation.port}/controller',
                                   ssl=client_context, proxy=None) as socket:
                    certificate = socket.transport.get_extra_info('ssl_object').getpeercert(binary_form=True)
                    if hashlib.sha256(certificate).hexdigest() != fingerprint:
                        raise RuntimeError('Certificate pin mismatch')

                    async def receive(kind):
                        while True:
                            try:
                                value = json.loads(await asyncio.wait_for(socket.recv(), 3))
                            except ConnectionClosed as error:
                                # CI must distinguish a native driver failure from
                                # a wire assertion, without logging pairing data.
                                native_error = str(output.error) if output.error else 'none recorded'
                                raise RuntimeError(f'Receiver closed while waiting for {kind}; native output error: {native_error}; transport: {server.peer_error}') from error
                            if value.get('type') == 'profiles-result' and value.get('error'):
                                raise RuntimeError('Profile operation failed: ' + str(value['error']))
                            if value['type'] == kind:
                                return value

                    sequence = -1
                    async def neutral(revision, lease):
                        # Match the phone's recovery handshake: a stalled receiver step
                        # may legitimately invalidate a neutral report's deadline.
                        # Only neutral is retried; never replay an old held press.
                        nonlocal sequence
                        deadline = asyncio.get_running_loop().time() + 3
                        while True:
                            sequence += 1
                            await socket.send(json.dumps(dict(type='input',seq=sequence,revision=revision,lease=lease,state=NEUTRAL.__dict__)))
                            while True:
                                remaining = deadline - asyncio.get_running_loop().time()
                                if remaining <= 0: raise RuntimeError('Neutral input could not recover within 3 seconds')
                                value = json.loads(await asyncio.wait_for(socket.recv(), remaining))
                                if value['type'] == 'ack' and value['seq'] == sequence: return value
                                if value['type'] == 'paused':
                                    lease = value['lease']; break

                    phone_id = str(uuid.uuid4())
                    await socket.send(json.dumps(dict(type='hello', v=3, token=invitation.token,
                                                       phoneId=phone_id, demoUsed=0)))
                    await receive('ready')
                    access = await receive('access')
                    if access['pro'] or access['remaining'] != 0:
                        raise RuntimeError('Receiver offered output without a plan')
                    await socket.send(json.dumps(dict(type='access-grant', grant=plan_grant(grant_key, access, phone_id))))
                    while not access['pro']:
                        access = await receive('access')
                        if access['error']:
                            raise RuntimeError('Plan grant was rejected: ' + access['error'])
                    await socket.send(json.dumps(dict(type='access-resume')))
                    paused = await receive('paused')
                    ack = await neutral(0, paused['lease'])
                    held = State(buttons=1, lx=-0.25, ly=0.5, rx=0.75, ry=-1, lt=0.25, rt=0.75)
                    sequence += 1
                    await socket.send(json.dumps(dict(type='input',seq=sequence,revision=0,lease=ack['lease'],state=held.__dict__)))
                    await receive('ack')
                    await verify(held)
                    await receive('paused')
                    await verify(NEUTRAL)
                    paused = await receive('paused')
                    fresh = await neutral(0, paused['lease'])
                    await socket.send(json.dumps(dict(type='profile-select', id='select',
                        profileId='consoleport-standard', profileRevision=1, expectedActivationRevision=0,
                        lease=fresh['lease'])))
                    layout = await receive('layout')
                    result = await receive('profiles-result')
                    if result.get('catalog', {}).get('activationRevision') != layout['revision']:
                        raise RuntimeError('Profile selection was not confirmed')
                    await socket.send(json.dumps(dict(type='layout-ready', revision=layout['revision'])))
                    paused = await receive('paused')
                    ack = await neutral(layout['revision'], paused['lease'])
                    profile = {**layout['profile'], 'id': 'selftest-cloud', 'name': 'Self-test cloud profile'}
                    source = dict(service='https://thumble.example/v1', accountId='a' * 64,
                                  profileId=profile['id'], revision=1)
                    await socket.send(json.dumps(dict(type='profile-adopt', id='adopt', profile=profile,
                        source=source, expectedActivationRevision=layout['revision'], lease=ack['lease'])))
                    adopted = await receive('layout')
                    receipt = await receive('profiles-result')
                    if receipt.get('catalog', {}).get('adoption', {}).get('profileId') != adopted['profile']['id']:
                        raise RuntimeError('Cloud adoption was not confirmed')
                    await socket.send(json.dumps(dict(type='layout-ready', revision=adopted['revision'])))
                    paused = await receive('paused')
                    await neutral(adopted['revision'], paused['lease'])
            finally:
                stop.set()
                await asyncio.wait_for(task, 5)
    finally:
        output.close()
    print('PASS: ' + ('native OS gamepad, ' if native else '') + 'TLS, certificate pin, pairing, plan grant, input, watchdog, profile selection, cloud adoption, layout acknowledgement')
