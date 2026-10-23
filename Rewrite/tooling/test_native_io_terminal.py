import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from native_io_terminal import NativeIOTerminals, NAMES, U64_MAX, decode_native_io_terminal


def value(role='broker', **fields):
    return {'version': 1, 'role': role, 'context': 'native-client' if role == 'broker' else 'native-server-wait', 'op': 3, 'code': 'native_input_timeout', 'metrics': [{'metric': name, 'count': 1, 'totalUs': 250000, 'maximumUs': 250000, 'activeCount': 0, 'oldestActiveUs': 0} for name in NAMES], **fields}


def line(v):
    return 'native_io_terminal ' + json.dumps(v, separators=(',', ':'))


class NativeIOTerminalTests(unittest.TestCase):
    def test_primary_operation_and_later_cleanup_remain_separate_with_explicit_roles(self):
        collector = NativeIOTerminals()
        for v in [value(context='native-read', ioKind='would-block', osCode=35), value(), value('receiver'), value(op=4, code='native_input_transport_failed')]:
            if 'ioKind' in v:
                del v['op'], v['code']
            collector.observe(line(v))
        rows = collector.snapshot()
        self.assertEqual([row['role'] for row in rows], ['broker', 'broker', 'receiver', 'broker'])
        self.assertEqual(rows[1]['op'], 3)
        self.assertEqual(rows[3]['op'], 4)
        self.assertEqual(rows[2]['metrics'][10]['metric'], 'nativeServerQueue')
        rows[0]['metrics'][0]['count'] = 999
        self.assertEqual(collector.snapshot()[0]['metrics'][0]['count'], 1)

    def test_static_exact_schema_rejects_unknown_nested_fields_roles_and_names(self):
        base = value()
        bad = [value(secret='must_not_escape'), value(role='unknown'), value(context='secret'), value(op=True), value(op=12), value(code='arbitrary_error'), value('receiver', context='native-client'), value(context='native-server-send'), value(metrics=[]), value(version=True)]
        for field, replacement in [('metric', 'secret'), ('count', True), ('count', -1), ('count', U64_MAX + 1), ('totalUs', 1.0), ('activeCount', 17), ('maximumUs', {}), ('oldestActiveUs', None)]:
            v = copy.deepcopy(base)
            v['metrics'][0][field] = replacement
            bad.append(v)
        v = copy.deepcopy(base)
        v['metrics'][0]['secret'] = 'payload'
        bad.append(v)
        v = copy.deepcopy(base)
        v['metrics'][1]['metric'] = NAMES[0]
        bad.append(v)
        for v in bad:
            with self.subTest(value=v):
                self.assertIsNone(decode_native_io_terminal(line(v)))

    def test_duplicate_noncanonical_float_non_ascii_and_oversized_text_rejected(self):
        valid = line(value())
        for text in [valid.replace('"version":1', '"version":1,"version":1'), valid.replace('"count":1', '"count":1,"count":1', 1), valid.replace('"count":1', '"count":1e0', 1), valid.replace('"count":1', '"count":NaN', 1), valid.replace('"count":1', '"count":-0', 1), valid + '\ntrailer', valid + 'é', 'x' * 4097, None]:
            with self.subTest(text=text):
                self.assertIsNone(decode_native_io_terminal(text))

    def test_known_control_and_sample_auth_errors_keep_metrics_without_widening_native_codes(self):
        for context in ['phone-control', 'sample']:
            self.assertIsNotNone(decode_native_io_terminal(line(value(context=context, code='phone_trust_reservation_expired'))))
            self.assertIsNotNone(decode_native_io_terminal(line(value(context=context, code='phone_authentication_rejected'))))
            self.assertIsNone(decode_native_io_terminal(line(value(context=context, code='private_unknown_error'))))
        self.assertIsNone(decode_native_io_terminal(line(value(code='phone_trust_reservation_expired'))))

    def test_receiver_exit_has_aggregates_even_when_socket_error_is_only_eof(self):
        v = value('receiver', context='native-server-exit', exit='read-failure', owned=1)
        del v['op'], v['code']
        self.assertEqual(decode_native_io_terminal(line(v))['owned'], 1)
        for field, replacement in [('role', 'broker'), ('exit', 'private text'), ('owned', True), ('owned', 3)]:
            self.assertIsNone(decode_native_io_terminal(line({**v, field: replacement})))

    def test_integer_boundaries_and_all_metrics_remain_corroboration_not_a_verdict(self):
        v = value()
        for row in v['metrics']:
            for field in ['count', 'totalUs', 'maximumUs', 'oldestActiveUs']:
                row[field] = U64_MAX
            row['activeCount'] = 16
        self.assertIsNotNone(decode_native_io_terminal(line(v)))
        self.assertNotIn('passed', decode_native_io_terminal(line(v)))
        v = value(context='native-read', ioKind='connection-reset', osCode=-2147483648)
        del v['op'], v['code']
        self.assertIsNotNone(decode_native_io_terminal(line(v)))
        v['osCode'] = -2147483649
        self.assertIsNone(decode_native_io_terminal(line(v)))

    def test_four_per_role_eight_total_and_atomic_private_report(self):
        collector = NativeIOTerminals()
        for _ in range(100):
            collector.observe(line(value()))
        for _ in range(100):
            collector.observe(line(value('receiver')))
        self.assertEqual(len(collector.snapshot()), 8)
        with tempfile.TemporaryDirectory() as d:
            target = Path(d) / 'report.json'
            self.assertTrue(collector.write_report(target))
            self.assertLessEqual(target.stat().st_size, 32768)
            self.assertEqual(target.stat().st_mode & 0o777, 0o600)
            before = target.read_bytes()
            with patch('native_io_terminal.os.replace', side_effect=OSError('private secret')):
                self.assertFalse(collector.write_report(target))
            self.assertEqual(target.read_bytes(), before)
            self.assertEqual(sorted(os.listdir(d)), ['report.json'])
            with patch('native_io_terminal.REPORT_BYTES', 1):
                self.assertFalse(collector.write_report(target))
            self.assertEqual(target.read_bytes(), before)
        with patch('native_io_terminal.REPORT_BYTES', 1):
            bounded = NativeIOTerminals()
            bounded.observe(line(value()))
            self.assertEqual(bounded.snapshot(), [])

    def test_diagnostic_exceptions_cannot_replace_primary_probe_failure(self):
        from run_mobile_app_probe import Probe
        probe = Probe(input_io_probe=True)
        with patch.object(probe.native_io_terminals, 'observe', side_effect=RuntimeError('private diagnostics')):
            with self.assertRaisesRegex(RuntimeError, '^original_probe_failure$'):
                try:
                    raise RuntimeError('original_probe_failure')
                finally:
                    probe.observe_native_io(line(value()))
        with patch.object(probe.native_io_terminals, 'write_report', side_effect=RuntimeError('private diagnostics')):
            self.assertFalse(probe.write_native_io_report('unused'))

    def test_only_opted_in_owned_host_child_receives_io_probe_environment(self):
        from run_mobile_app_probe import Probe
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            helper = root / 'native/receiver/target/debug/examples/phone_input_probe'
            helper.parent.mkdir(parents=True)
            helper.touch()
            for enabled in [False, True]:
                captured = []
                def stop_before_start(*args, **kwargs):
                    captured.append(kwargs['env'])
                    raise RuntimeError('original_start_failure')
                with patch('run_mobile_app_probe.ROOT', root), patch.dict(os.environ, {}, clear=True), patch('run_mobile_app_probe.subprocess.Popen', side_effect=stop_before_start):
                    with self.assertRaisesRegex(RuntimeError, '^original_start_failure$'):
                        Probe(input_io_probe=enabled).request('/begin')
                self.assertEqual(captured[0].get('THUMBLE_REWRITE_INPUT_IO_PROBE'), '1' if enabled else None)
                self.assertEqual(captured[0].get('THUMBLE_REWRITE_INPUT_ERROR_PROBE'), '1' if enabled else None)

    def test_io_enablement_is_scoped_to_explicit_owned_ios_runtime(self):
        from run_mobile_app_probe import Probe, ROOT
        with self.assertRaisesRegex(AssertionError, 'app_probe_io_scope_invalid'):
            Probe('corner', input_io_probe=True)
        for args in [['--platform', 'android'], ['--platform', 'ios', '--saved-controller', 'corner']]:
            result = subprocess.run([sys.executable, str(ROOT / 'tooling/run_mobile_app_probe.py'), *args, '--native-io-report', 'unused', '--', 'unused'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertIn('native_io_probe_requires_owned_ios_runtime', result.stderr)


if __name__ == '__main__':
    unittest.main()
