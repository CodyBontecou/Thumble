import asyncio
import json
from pathlib import Path
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlencode, urlsplit
import uuid

from thumble_receiver.cloud_pairing import (CallbackBroker, CloudPairing, ISSUER, REDIRECT,
                                           authorization_url, callback_code, forward_callback)
from thumble_receiver.pairing import Invitation


def callback(state='state', code='code'):
    return REDIRECT + '?' + urlencode(dict(state=state, code=code, iss=ISSUER))


class OAuthTests(unittest.TestCase):
    def test_pkce_scope_resource_and_exact_callback(self):
        url = authorization_url('https://thumble.io/mcp', 'verifier', 'state')
        values = parse_qs(urlsplit(url).query)
        self.assertEqual(values['scope'], ['openid pairing:manage'])
        self.assertEqual(values['redirect_uri'], [REDIRECT])
        self.assertEqual(values['code_challenge_method'], ['S256'])
        self.assertNotIn('verifier', url)
        self.assertEqual(callback_code(callback(), 'state'), 'code')
        for value in (callback('wrong'), callback() + '&state=state', callback() + '&error=',
                      callback().replace('https%3A%2F%2Fthumble.io%2Fapi%2Fauth', 'https%3A%2F%2Fother.example'),
                      callback() + '#', callback().replace('cloud-auth/', 'cloud-auth:123/')):
            with self.assertRaises(ValueError):
                callback_code(value, 'state')


class BrokerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.broker = CallbackBroker(self.temporary.name)
        await self.broker.start()

    async def asyncTearDown(self):
        await self.broker.close()
        self.temporary.cleanup()

    async def test_custom_uri_forwarding_is_consumed_only_by_pending_state(self):
        operation = asyncio.create_task(self.broker.authorize('https://thumble.io/test', 'state', lambda _: True))
        await asyncio.sleep(0.02)
        with self.assertRaises(Exception):
            await asyncio.to_thread(forward_callback, self.temporary.name, callback('wrong'))
        self.assertFalse(operation.done())
        await asyncio.to_thread(forward_callback, self.temporary.name, callback())
        self.assertEqual(await operation, callback())
        with self.assertRaises(Exception):
            await asyncio.to_thread(forward_callback, self.temporary.name, callback())
        metadata = json.loads((Path(self.temporary.name) / 'oauth-callback.json').read_bytes())
        self.assertEqual(set(metadata), {'version', 'port', 'pid'})
        self.assertNotIn('code', json.dumps(metadata))

    async def test_browser_origin_requests_and_wrong_endpoints_are_rejected(self):
        port = self.broker.server.sockets[0].getsockname()[1]
        for header in (b'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n',
                       b'POST /oauth/callback HTTP/1.1\r\nOrigin: https://attacker.example\r\nContent-Length: 2\r\n\r\n{}'):
            reader, writer = await asyncio.open_connection('127.0.0.1', port)
            writer.write(header)
            await writer.drain()
            self.assertIn(b'400 Bad Request', await reader.read())
            writer.close()
            await writer.wait_closed()


class CloudTests(unittest.IsolatedAsyncioTestCase):
    async def test_registration_publication_connection_clear_and_revoke(self):
        calls = []
        invitation = [Invitation('192.168.1.2', 1234, '0' * 64).renew()]

        class Broker:
            async def authorize(self, url, state):
                return callback(state)

        receiver_id = str(uuid.uuid4())
        def request(url, **kwargs):
            calls.append((url, kwargs))
            if url.endswith('/v1/config'):
                return dict(auth=dict(issuer=ISSUER, audience='https://thumble.io/mcp'))
            if url.endswith('/oauth2/token'):
                self.assertEqual(kwargs['form']['code'], 'code')
                self.assertNotIn('offline_access', kwargs['form'].values())
                return dict(access_token='account-token', refresh_token='must-not-be-stored')
            if url.endswith('/v1/receiver-pairing'):
                return dict(receiverId=receiver_id, publisherToken='rp_' + 'a' * 64,
                            expiresAt=int(time.time() * 1000) + 590000)
            return dict(accepted=True)

        sharing = CloudPairing(Broker(), lambda: invitation[0], request=request)
        try:
            await sharing.start()
            self.assertEqual(sharing.id, receiver_id)
            upload = calls[-1][1]['body']
            self.assertFalse(upload['connected'])
            self.assertIn('png', upload)
            self.assertLess(upload['expiresAt'], time.time() * 1000 + 121000)
            self.assertNotIn('account-token', repr(sharing.__dict__))
            self.assertNotIn('must-not-be-stored', repr(sharing.__dict__))
            invitation[0] = ''
            await sharing.publish()
            cleared = calls[-1][1]['body']
            self.assertEqual(cleared, dict(sequence=2, connected=True))
        finally:
            await sharing.stop()
        self.assertEqual(calls[-1][1]['method'], 'DELETE')
        self.assertIsNone(sharing.token)

    async def test_untrusted_config_does_not_open_authorization(self):
        class Broker:
            async def authorize(self, *args):
                raise AssertionError('Untrusted config opened a browser')

        sharing = CloudPairing(Broker(), lambda: 'present', request=lambda *_: dict(
            auth=dict(issuer='https://attacker.example', audience='https://thumble.io/mcp')))
        await sharing.start()
        self.assertIsNone(sharing.token)


if __name__ == '__main__':
    unittest.main()
