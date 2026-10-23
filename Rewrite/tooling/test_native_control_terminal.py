import json
from unittest import mock
from run_mobile_app_probe import Probe
import unittest
from native_control_terminal import NativeControlTerminals, decode_native_control_terminal


class TerminalDiagnosticTests(unittest.TestCase):
    def test_known_static_code_and_canonical_u64(self):
        self.assertEqual(decode_native_control_terminal('native_control_terminal code=input_session_closed elapsed_us=12\n'), {'code': 'input_session_closed', 'elapsedUs': 12})
        self.assertEqual(decode_native_control_terminal('native_control_terminal code=authenticated_control_transport_failed elapsed_us=0'), {'code': 'authenticated_control_transport_failed', 'elapsedUs': 0})
        self.assertEqual(decode_native_control_terminal('native_control_terminal code=other elapsed_us=18446744073709551615')['elapsedUs'], 18446744073709551615)

    def test_unknown_static_identifier_is_only_other(self):
        self.assertEqual(decode_native_control_terminal('native_control_terminal code=private_label elapsed_us=1'), {'code': 'other', 'elapsedUs': 1})

    def test_hostile_or_noncanonical_lines_are_not_reflected(self):
        for line in [None, b'input_session_closed', '', 'x'*257,
                     'native_control_terminal code=host:1234 elapsed_us=1',
                     'native_control_terminal code=PrivateLabel elapsed_us=1',
                     'native_control_terminal code=input_session_closed elapsed_us=01',
                     'native_control_terminal code=input_session_closed elapsed_us=-1',
                     'native_control_terminal code=input_session_closed elapsed_us=18446744073709551616',
                     'native_control_terminal code=input_session_closed elapsed_us=1 extra=secret',
                     'native_control_terminal code=input_session_closed elapsed_us=1\r\n',
                     'native_control_terminal code=input_session_closed elapsed_us=1\nsecret',
                     'native_control_terminal code=é elapsed_us=1',
                     'native_control_terminal code=' + 'a'*97 + ' elapsed_us=1']:
            with self.subTest(line_type=type(line).__name__):
                self.assertIsNone(decode_native_control_terminal(line))

    def test_first64_only_and_snapshot_cannot_mutate_retained_evidence(self):
        d = NativeControlTerminals()
        for i in range(1000):
            d.observe('native_control_terminal code=input_session_closed elapsed_us=' + str(i))
        values = d.snapshot()
        self.assertEqual(len(values), 64)
        self.assertEqual([v['elapsedUs'] for v in values], list(range(64)))
        values[0]['code'] = 'secret'
        values.append({'code': 'secret'})
        self.assertEqual(d.snapshot()[0]['code'], 'input_session_closed')
        self.assertEqual(len(d.snapshot()), 64)

    def test_owned_probe_composes_only_sanitized_terminal_metadata_without_starting_process(self):
        with mock.patch('run_mobile_app_probe.subprocess.Popen') as launch:
            probe = Probe()
        launch.assert_not_called()
        self.assertIsNone(probe.process)
        for line in [
                '{"host":"private-host","secret":"private-secret"}',
                'native_control_terminal code=input_session_closed elapsed_us=7',
                'native_control_terminal code=private_payload elapsed_us=8',
                'native_control_terminal code=input_session_closed elapsed_us=9 secret=private-secret']:
            probe.native_control_terminals.observe(line)
        encoded = json.dumps({'nativeControlTerminals': probe.native_control_terminals.snapshot()})
        self.assertEqual(json.loads(encoded), {'nativeControlTerminals': [
            {'code': 'input_session_closed', 'elapsedUs': 7}, {'code': 'other', 'elapsedUs': 8}]})
        self.assertLess(len(encoded), 8192)
        for private in ['private-host', 'private-secret', 'private_payload']:
            self.assertNotIn(private, encoded)


if __name__ == '__main__':
    unittest.main()
