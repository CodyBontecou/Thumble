"""Explicit ten-minute QR sharing through the same OAuth client as the Mac."""
import asyncio
import base64
import hashlib
import json
from pathlib import Path
import secrets
import socket
import time
from urllib.parse import parse_qs, urlencode, urlsplit
from urllib.request import Request, build_opener
from urllib.error import HTTPError
import uuid
import webbrowser

from .http import NoRedirect, request_json
from .pairing_image import pairing_png
from .private_files import private_json

SERVICE = 'https://thumble.io'
ISSUER = SERVICE + '/api/auth'
REDIRECT = 'thumble-receiver://cloud-auth/callback'


def random_text():
    return secrets.token_urlsafe(32)


def authorization_url(audience, verifier, state):
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    return SERVICE + '/api/auth/oauth2/authorize?' + urlencode(dict(response_type='code',
        client_id='thumble-receiver', redirect_uri=REDIRECT, scope='openid pairing:manage',
        resource=audience, state=state, code_challenge_method='S256', code_challenge=challenge))


def callback_values(url, state):
    if not isinstance(url, str) or len(url) > 8192:
        raise ValueError('Invalid OAuth callback')
    parts = urlsplit(url)
    if (parts.scheme != 'thumble-receiver' or parts.netloc != 'cloud-auth' or parts.path != '/callback'
            or parts.fragment or '#' in url):
        raise ValueError('Invalid OAuth callback')
    values = parse_qs(parts.query, keep_blank_values=True)
    if values.get('state') != [state] or values.get('iss') != [ISSUER]:
        raise ValueError('OAuth state, issuer, or code mismatch')
    return values


def callback_code(url, state):
    values = callback_values(url, state)
    if ('error' in values or len(values.get('code', [])) != 1 or not 0 < len(values['code'][0]) <= 4096):
        raise ValueError('OAuth authorization was denied or the code is invalid')
    return values['code'][0]


class CallbackBroker:
    """A custom URI-handler process forwards only to this loopback listener.

    The rendezvous file contains only port/PID. OAuth state is kept in memory and
    validated before a callback is accepted; codes are never saved or logged.
    """
    def __init__(self, directory):
        self.path = Path(directory) / 'oauth-callback.json'
        self.server, self.pending = None, None

    async def start(self):
        self.server = await asyncio.start_server(self.handle, '127.0.0.1', 0, limit=16384)
        import os
        await asyncio.to_thread(private_json, self.path,
            dict(version=1, port=self.server.sockets[0].getsockname()[1], pid=os.getpid()))

    async def authorize(self, url, state, open_browser=webbrowser.open):
        if self.pending:
            raise RuntimeError('Authorization is already in progress')
        future = asyncio.get_running_loop().create_future()
        self.pending = (state, future)
        try:
            if not await asyncio.to_thread(open_browser, url):
                raise RuntimeError('Could not open the browser')
            return await asyncio.wait_for(future, 180)
        finally:
            self.pending = None

    async def handle(self, reader, writer):
        status = '400 Bad Request'
        try:
            header = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 2)
            if len(header) > 8192:
                raise ValueError('Header too large')
            lines = header.decode('ascii').split('\r\n')
            if lines[0] != 'POST /oauth/callback HTTP/1.1':
                raise ValueError('Wrong callback endpoint')
            headers = {}
            for line in lines[1:]:
                if line:
                    key, value = line.split(':', 1)
                    if key.lower() in headers:
                        raise ValueError('Duplicate header')
                    headers[key.lower()] = value.strip()
            if headers.get('origin') or 'transfer-encoding' in headers:
                raise ValueError('Browser requests and streaming bodies are not accepted')
            length = int(headers.get('content-length', '0'))
            if not 0 < length <= 12288:
                raise ValueError('Invalid callback size')
            body = json.loads(await asyncio.wait_for(reader.readexactly(length), 2))
            if not self.pending:
                raise ValueError('No authorization in progress')
            state, future = self.pending
            values = callback_values(body.get('callback'), state)
            if future.done():
                raise ValueError('Callback already consumed')
            if 'error' in values:
                if len(values['error']) != 1:
                    raise ValueError('Duplicate authorization error')
                future.set_exception(ValueError('Authorization was cancelled or denied'))
            else:
                callback_code(body.get('callback'), state)
                future.set_result(body['callback'])
            status = '200 OK'
        except (ValueError, TypeError, AttributeError, asyncio.IncompleteReadError,
                asyncio.LimitOverrunError, TimeoutError, UnicodeError):
            pass
        finally:
            writer.write(('HTTP/1.1 ' + status + '\r\nContent-Length: 0\r\nConnection: close\r\n\r\n').encode())
            try:
                await writer.drain()
            except ConnectionError:
                pass
            writer.close()
            await writer.wait_closed()

    async def close(self):
        if self.pending and not self.pending[1].done():
            self.pending[1].cancel()
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        self.path.unlink(missing_ok=True)


def forward_callback(directory, callback):
    # This process never opens a gameplay listener or creates a second gamepad.
    value = json.loads((Path(directory) / 'oauth-callback.json').read_bytes())
    port = value.get('port')
    if type(port) is not int or not 1 <= port <= 65535 or not isinstance(callback, str) or len(callback) > 8192:
        raise ValueError('Receiver callback listener is unavailable')
    request = Request(f'http://127.0.0.1:{port}/oauth/callback',
        data=json.dumps(dict(callback=callback)).encode(), headers={'Content-Type': 'application/json'}, method='POST')
    try:
        with build_opener(NoRedirect()).open(request, timeout=3) as response:
            if response.status != 200:
                raise ValueError('Callback was not accepted by the running receiver')
    except HTTPError as error:
        error.close()
        raise ValueError('Callback was not accepted by the running receiver') from None


class CloudPairing:
    def __init__(self, broker, invitation, notify=lambda _: None, request=request_json):
        self.broker, self.invitation, self.notify, self.request = broker, invitation, notify, request
        self.id, self.token, self.expires, self.sequence = None, None, 0, 0
        self.operation, self.heartbeat = None, None
        self.generation = 0

    async def api(self, path, **kwargs):
        return await asyncio.to_thread(self.request, SERVICE + '/' + path, **kwargs)

    async def start(self):
        if self.operation or self.token:
            return
        if not self.invitation():
            self.notify('Receiver unavailable or a phone is already paired.')
            return
        epoch = self.generation
        self.operation = asyncio.current_task()
        registered = None
        try:
            self.notify('Sign in to share pairing with ChatGPT for ten minutes…')
            config = await self.api('v1/config')
            auth = config.get('auth', {})
            audience = auth.get('audience')
            if auth.get('issuer') != ISSUER or audience != SERVICE + '/mcp':
                raise ValueError('Untrusted OAuth configuration')
            verifier, state = random_text(), random_text()
            callback = await self.broker.authorize(authorization_url(audience, verifier, state), state)
            code = callback_code(callback, state)
            tokens = await self.api('api/auth/oauth2/token', method='POST', form=dict(
                grant_type='authorization_code', client_id='thumble-receiver', redirect_uri=REDIRECT,
                code=code, code_verifier=verifier, resource=audience))
            access = tokens.get('access_token')
            if not isinstance(access, str) or not access:
                raise ValueError('Missing access token')
            registered = await self.api('v1/receiver-pairing', method='POST', token=access,
                                        body=dict(name=socket.gethostname()[:100]))
            receiver_id = str(uuid.UUID(registered['receiverId']))
            token, expires = registered.get('publisherToken'), registered.get('expiresAt')
            if (not isinstance(token, str) or not token.startswith('rp_') or type(expires) not in (int, float)
                    or not time.time() * 1000 < expires <= time.time() * 1000 + 600000):
                raise ValueError('Invalid publisher registration')
            if epoch != self.generation:
                await self.api('v1/receiver-pairing/' + receiver_id, method='DELETE', token=token)
                return
            self.id, self.token, self.expires, self.sequence = receiver_id, token, expires, 0
            try:
                await self.publish()
            except Exception:
                self.notify('ChatGPT sharing is temporarily unavailable; retrying.')
            self.heartbeat = asyncio.create_task(self.maintain(epoch))
        except asyncio.CancelledError:
            if registered and isinstance(registered.get('publisherToken'), str):
                try:
                    await self.api('v1/receiver-pairing/' + registered['receiverId'], method='DELETE', token=registered['publisherToken'])
                except Exception:
                    pass
            raise
        except Exception:
            self.notify('ChatGPT pairing could not start. Check sign-in and retry.')
        finally:
            if self.operation is asyncio.current_task():
                self.operation = None

    async def publish(self):
        if not self.token:
            return
        value = self.invitation()
        body = dict(sequence=self.sequence + 1, connected=not bool(value))
        self.sequence += 1
        if value:
            parts = urlsplit(value)
            data = parse_qs(parts.query)['data'][0]
            payload = json.loads(base64.urlsafe_b64decode(data + '=' * (-len(data) % 4)))
            body.update(expiresAt=payload['expires'] * 1000,
                        png=base64.b64encode(await asyncio.to_thread(pairing_png, value)).decode())
        await self.api('v1/receiver-pairing/' + self.id, method='PUT', token=self.token, body=body)
        self.notify('Phone paired · ChatGPT QR cleared' if body['connected'] else 'QR shared · ask ChatGPT for show_pairing_code')

    async def maintain(self, epoch):
        try:
            while epoch == self.generation:
                await asyncio.sleep(10)
                if time.time() * 1000 >= self.expires:
                    await self.stop()
                    return
                try:
                    await self.publish()
                except Exception:
                    self.notify('ChatGPT sharing is temporarily unavailable; retrying.')
        except asyncio.CancelledError:
            pass

    async def stop(self):
        self.generation += 1
        operation, heartbeat = self.operation, self.heartbeat
        self.operation, self.heartbeat = None, None
        for task in (operation, heartbeat):
            if task and task is not asyncio.current_task():
                task.cancel()
        receiver_id, token = self.id, self.token
        self.id, self.token, self.expires = None, None, 0
        if token:
            try:
                await self.api('v1/receiver-pairing/' + receiver_id, method='DELETE', token=token)
            except Exception:
                pass  # Hosted freshness expires after 30 seconds even if offline.
        self.notify('ChatGPT pairing sharing stopped')
