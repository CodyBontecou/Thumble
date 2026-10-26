import json
import struct
import unittest

from cryptography.exceptions import InvalidTag

from thumble_receiver.datagram import DatagramCipher, DatagramInput
from thumble_receiver.profiles import encoded


class DatagramTests(unittest.TestCase):
    def test_directional_roundtrip_limits_and_replay(self):
        server, phone = DatagramCipher(bytes(32)), DatagramCipher(bytes(32), server=False)
        packet = phone.seal(b'hello')
        self.assertEqual(packet[:12], struct.pack('>IQ', 1, 1))
        self.assertEqual(server.open(packet), b'hello')
        self.assertEqual(phone.open(server.seal(b'ack')), b'ack')
        with self.assertRaises(ValueError):
            server.open(packet)
        with self.assertRaises(ValueError):
            phone.open(phone.seal(b'wrong direction'))
        for data in (bytes(27), bytes(1129)):
            with self.assertRaises(ValueError):
                server.open(data)
        with self.assertRaises(ValueError):
            server.seal(bytes(1101))
        server.sent = 2 ** 64 - 1
        with self.assertRaises(ValueError):
            server.seal(b'counter exhausted')

    def test_forged_counter_cannot_advance_the_replay_window(self):
        server, phone = DatagramCipher(bytes(32)), DatagramCipher(bytes(32), False)
        packet = phone.seal(b'authentic')
        forged = struct.pack('>IQ', 1, 999) + packet[12:]
        with self.assertRaises(InvalidTag):
            server.open(forged)
        self.assertEqual(server.received, 0)
        self.assertEqual(server.open(packet), b'authentic')

    def test_endpoint_binding_requires_authenticated_probe_and_is_sticky(self):
        replies = []

        class Transport:
            def sendto(self, packet, endpoint):
                replies.append((packet, endpoint))
            def close(self):
                pass

        class Session:
            def handle(self, message, udp=False):
                return [dict(type='ack', seq=message['seq'])]

        receiver = DatagramInput(Session(), lambda: self.fail('UDP failed unexpectedly'))
        receiver.transport = Transport()
        phone = DatagramCipher(receiver.key, False)
        one, two = ('127.0.0.1', 1), ('127.0.0.1', 2)
        receiver.datagram_received(b'not authenticated', one)
        receiver.datagram_received(phone.seal(encoded(dict(type='input', seq=1))), one)
        self.assertIsNone(receiver.endpoint)
        receiver.datagram_received(phone.seal(encoded(dict(type='probe'))), one)
        self.assertEqual(receiver.endpoint, one)
        self.assertEqual(json.loads(phone.open(replies.pop()[0]))['type'], 'udp-ready')
        receiver.datagram_received(phone.seal(encoded(dict(type='probe'))), two)
        self.assertFalse(replies)
        receiver.datagram_received(phone.seal(encoded(dict(type='input', seq=2))), one)
        self.assertEqual(json.loads(phone.open(replies.pop()[0]))['seq'], 2)
        receiver.close()


if __name__ == '__main__':
    unittest.main()
