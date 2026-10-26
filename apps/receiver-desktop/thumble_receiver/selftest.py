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
            finally:
                stop.set()
                await asyncio.wait_for(task, 5)
    finally:
        output.close()
    print('PASS: packaged TLS, certificate pin, pairing, demo, input, acknowledgement, watchdog')
