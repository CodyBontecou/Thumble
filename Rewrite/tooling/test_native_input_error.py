import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from native_input_error import NativeInputErrors, decode_native_input_error


def event(**fields):
    return 'native_input_error ' + json.dumps({'version': 1, 'role': 'broker', **fields}, separators=(',', ':'))


class NativeInputErrorTests(unittest.TestCase):
    def test_first_operation_is_retained_before_later_cleanup(self):
        values = NativeInputErrors()
        for value in [event(context='native-read', ioKind='would-block', osCode=35), event(context='native-client', op=3, code='native_input_timeout'), event(role='receiver', context='native-server-exit', exit='read-failure', owned=1), event(context='native-client', op=4, code='native_input_transport_failed')]:
            values.observe(value)
        result = values.snapshot()
        self.assertEqual(result[0]['ioKind'], 'would-block')
        self.assertEqual(result[1]['code'], 'native_input_timeout')
        self.assertEqual(result[2]['exit'], 'read-failure')
        self.assertEqual(result[3]['op'], 4)
        result[0]['ioKind'] = 'secret'
        self.assertEqual(values.snapshot()[0]['ioKind'], 'would-block')

    def test_exact_schema_rejects_untrusted_extra_and_unknown_fields(self):
        for value in [event(context='native-read', ioKind='secret', osCode=35), event(role='secret', context='native-read', ioKind='would-block', osCode=35), event(context='native-client', op=12, code='native_input_timeout'), event(context='native-client', op=True, code='native_input_timeout'), event(context='native-client', op=3, code='unknown_secret'), event(context='native-read', ioKind='would-block', osCode=2147483648), event(context='native-read', ioKind='would-block', osCode=True), event(context='native-read', ioKind='would-block', osCode=35, secret='credentials'), event(context='native-server-exit', exit='read-failure', owned=1), event(role='receiver', context='native-server-exit', exit='read-failure', owned=3), event(context='native-read', exit='zero-write'), 'native_input_error ' + 'x' * 385]:
            with self.subTest(value=value):
                self.assertIsNone(decode_native_input_error(value))

    def test_duplicate_nested_noncanonical_and_non_ascii_inputs_are_rejected(self):
        valid = event(context='native-read', ioKind='would-block', osCode=35)
        for value in [valid.replace('"version":1', '"version":1,"version":1'), valid.replace(':35', ':35.0'), valid.replace(':35', ':3.5e1'), valid.replace(':35', ':NaN'), valid.replace(':35', ':-0'), valid.replace(':35', ':12345678901234567890'), valid.replace('"would-block"', '{}'), valid + '\ntrailer', valid + 'é']:
            self.assertIsNone(decode_native_input_error(value))

    def test_legal_eof_and_signed_os_codes(self):
        for value in [event(context='native-read', exit='eof'), event(context='native-write', exit='zero-write'), event(context='native-write', ioKind='timed-out', osCode=None), event(context='native-read-options', ioKind='other', osCode=-2147483648), event(role='receiver', context='native-server-exit', exit='stopped', owned=0)]:
            self.assertIsNotNone(decode_native_input_error(value + '\n'))

    def test_first32_and_atomic0600_report_are_bounded(self):
        values = NativeInputErrors()
        for _ in range(100):
            values.observe(event(context='native-client', op=3, code='native_input_timeout'))
        self.assertEqual(len(values.snapshot()), 32)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'report.json'
            self.assertTrue(values.write_report(path))
            self.assertLessEqual(path.stat().st_size, 8192)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(len(json.loads(path.read_text())['events']), 32)
            before = path.read_bytes()
            with patch('native_input_error.os.replace', side_effect=OSError('private path must not escape')):
                self.assertFalse(values.write_report(path))
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(sorted(os.listdir(directory)), ['report.json'])
            self.assertFalse(values.write_report(Path(directory) / 'absent' / 'report.json'))


if __name__ == '__main__':
    unittest.main()
