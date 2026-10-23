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

    def test_audited_native_ipc_outcomes_remain_distinct(self):
        for code in ('native_input_transport_failed', 'native_input_timeout',
                     'native_input_frame_invalid', 'native_input_server_rejected'):
            with self.subTest(code=code):
                self.assertEqual(decode_native_control_terminal(
                    f'native_control_terminal code={code} elapsed_us=1'),
                    {'code': code, 'elapsedUs': 1})

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


    def test_atomic_report_contains_only_bounded_sanitized_outcomes(self):
        import pathlib
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'reports' / 'terminals.json'
            collector = NativeControlTerminals()
            collector.observe('private-secret host:1234')
            collector.observe('native_control_terminal code=private_label elapsed_us=1')
            for _ in range(100):
                collector.observe('native_control_terminal code=input_session_closed elapsed_us=18446744073709551615')
            self.assertTrue(collector.write_report(path))
            value = json.loads(path.read_text())
            self.assertEqual(set(value), {'version', 'scope', 'events'})
            self.assertEqual(value['version'], 1)
            self.assertEqual(value['scope'], 'native-control-terminal-outcomes')
            self.assertEqual(len(value['events']), 64)
            self.assertEqual(value['events'][0], {'code': 'other', 'elapsedUs': 1})
            self.assertLessEqual(path.stat().st_size, 8192)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(path.parent.iterdir()), [path])
            for private in ['private-secret', 'host:1234', 'private_label']:
                self.assertNotIn(private, path.read_text())

    def test_report_failure_is_nonthrowing_and_preserves_previous_atomic_result(self):
        import pathlib
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'terminals.json'
            collector = NativeControlTerminals()
            self.assertTrue(collector.write_report(path))
            before = path.read_bytes()
            with mock.patch('os.replace', side_effect=OSError('private filesystem failure')):
                self.assertFalse(collector.write_report(path))
            self.assertEqual(path.read_bytes(), before)
            self.assertEqual(list(path.parent.iterdir()), [path])
            with mock.patch('pathlib.Path.mkdir', side_effect=OSError('private failure')):
                self.assertFalse(collector.write_report(path))


if __name__ == '__main__':
    unittest.main()
