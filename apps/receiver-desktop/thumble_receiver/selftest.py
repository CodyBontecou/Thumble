"""Packaged-runtime smoke test with real TLS and memory-only output."""
import asyncio
import hashlib
import json
import ssl
import tempfile
import uuid

from websockets.asyncio.client import connect

from .access import Access
from .output import GuardedOutput, MemoryOutput
from .pairing import Invitation, identity
from .server import ReceiverServer
from .state import NEUTRAL, State


async def selftest():
    context, fingerprint = identity()
    output = GuardedOutput(MemoryOutput())
    try:
        with tempfile.TemporaryDirectory(prefix='thumble-selftest-') as directory:
            ready = asyncio.Event()
            invitation = Invitation('127.0.0.1', 0, fingerprint)
            server = ReceiverServer(output, Access(directory), invitation, lambda _: ready.set())
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
                            value = json.loads(await asyncio.wait_for(socket.recv(), 3))
                            if value['type'] == kind:
                                return value

                    await socket.send(json.dumps(dict(type='hello', v=3, token=invitation.token,
                                                       phoneId=str(uuid.uuid4()))))
                    await receive('ready')
                    await socket.send(json.dumps(dict(type='access-resume')))
                    paused = await receive('paused')
                    frame = dict(type='input', seq=0, revision=0, lease=paused['lease'], state=NEUTRAL.__dict__)
                    await socket.send(json.dumps(frame))
                    ack = await receive('ack')
                    await socket.send(json.dumps({**frame, 'seq': 1, 'lease': ack['lease'],
                                                  'state': State(buttons=1).__dict__}))
                    await receive('ack')
                    if output.backend.state.buttons != 1:
                        raise RuntimeError('Input did not reach output adapter')
                    await receive('paused')
                    if output.backend.state != NEUTRAL:
                        raise RuntimeError('Watchdog did not release input')
                    paused = await receive('paused')
                    await socket.send(json.dumps(dict(type='profile-select', id='select',
                        profileId='consoleport-standard', profileRevision=1, expectedActivationRevision=0,
                        lease=paused['lease'])))
                    layout = await receive('layout')
                    result = await receive('profiles-result')
                    if result.get('catalog', {}).get('activationRevision') != layout['revision']:
                        raise RuntimeError('Profile selection was not confirmed')
                    await socket.send(json.dumps(dict(type='layout-ready', revision=layout['revision'])))
                    paused = await receive('paused')
                    await socket.send(json.dumps(dict(type='input', seq=2, revision=layout['revision'],
                                                       lease=paused['lease'], state=NEUTRAL.__dict__)))
                    ack = await receive('ack')
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
                    await socket.send(json.dumps(dict(type='input', seq=3, revision=adopted['revision'],
                                                       lease=paused['lease'], state=NEUTRAL.__dict__)))
                    await receive('ack')
            finally:
                stop.set()
                await asyncio.wait_for(task, 5)
    finally:
        output.close()
    print('PASS: packaged TLS, certificate pin, pairing, demo, input, watchdog, profile selection, cloud adoption, layout acknowledgement')
