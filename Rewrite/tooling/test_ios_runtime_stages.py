import json
import pathlib
import tempfile
import threading
import unittest
from unittest import mock
import subprocess
from check_ios_tls_runtime import cleanup_runtime
from ios_runtime_stages import IOSRuntimeStages


class StageJournalTests(unittest.TestCase):
    def test_atomic_record_survives_blocked_external_call_and_identifies_last_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'mobile-ios-tls-runtime-stages.json'
            journal = IOSRuntimeStages(path, now=lambda: 1.0)
            with journal.step('boot'):
                pass
            entered, release = threading.Event(), threading.Event()
            def call():
                with journal.step('bootstatus'):
                    entered.set()
                    self.assertTrue(release.wait(2))
            worker = threading.Thread(target=call)
            worker.start()
            self.assertTrue(entered.wait(2))
            value = json.loads(path.read_text())
            self.assertEqual(value['events'][-1], {'stage': 'bootstatus', 'event': 'started', 'elapsedMs': 0})
            self.assertEqual([e['stage'] for e in value['events'] if e['event'] == 'completed'], ['boot'])
            release.set()
            worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertEqual(json.loads(path.read_text())['events'][-1]['event'], 'completed')

    def test_failed_call_keeps_started_stage_without_forging_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'mobile-stage.json'
            journal = IOSRuntimeStages(path, now=lambda: 0)
            with self.assertRaises(RuntimeError):
                with journal.step('install'):
                    raise RuntimeError('private command data')
            raw = path.read_text()
            self.assertNotIn('private', raw)
            self.assertEqual(json.loads(raw)['events'], [{'stage': 'install', 'event': 'started', 'elapsedMs': 0}])

    def test_unknown_stage_and_invalid_time_do_not_replace_last_durable_record(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'mobile-stage.json'
            clock = [1.0]
            journal = IOSRuntimeStages(path, now=lambda: clock[0])
            with journal.step('compile'):
                pass
            original = path.read_bytes()
            for stage in ['host:1234', 'private/path', 'BOOT', '', 'compile\nsecret']:
                with self.assertRaises(ValueError):
                    with journal.step(stage):
                        self.fail('invalid stage reached call')
                self.assertEqual(path.read_bytes(), original)
            for time in [0.5, float('inf'), float('nan'), 4000]:
                clock[0] = time
                with self.assertRaises(ValueError):
                    with journal.step('boot'):
                        self.fail('invalid time reached call')
                self.assertEqual(path.read_bytes(), original)

    def test_bounded64_events_size_and_no_temporary_file_after_atomic_replace(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'mobile-stage.json'
            journal = IOSRuntimeStages(path, now=lambda: 0)
            for _ in range(32):
                with journal.step('runtime-wait'):
                    pass
            self.assertEqual(len(json.loads(path.read_text())['events']), 64)
            self.assertLessEqual(path.stat().st_size, 8192)
            with self.assertRaises(ValueError):
                with journal.step('delete'):
                    self.fail('exhausted journal reached call')
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_diagnostic_start_or_completion_failure_never_skips_owned_cleanup(self):
        for failed_event in ('started', 'completed', 'all'):
            with self.subTest(event=failed_event), tempfile.TemporaryDirectory() as directory:
                journal = IOSRuntimeStages(pathlib.Path(directory) / 'stage.json', now=lambda: 0)
                original = journal._record
                def record(stage, event):
                    if failed_event == 'all' or event == failed_event:
                        raise OSError('private diagnostic write failure')
                    original(stage, event)
                with mock.patch.object(journal, '_record', side_effect=record), mock.patch('check_ios_tls_runtime.subprocess.run') as run:
                    cleanup_runtime('owned-synthetic-device', journal)
                self.assertEqual(run.call_args_list, [
                    mock.call(['xcrun', 'simctl', 'shutdown', 'owned-synthetic-device'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL),
                    mock.call(['xcrun', 'simctl', 'delete', 'owned-synthetic-device'], check=True),
                ])

    def test_cleanup_preserves_external_command_failure_and_no_false_completion(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / 'stage.json'
            journal = IOSRuntimeStages(path, now=lambda: 0)
            failure = subprocess.CalledProcessError(1, ['synthetic-delete'])
            with mock.patch('check_ios_tls_runtime.subprocess.run', side_effect=[None, failure]) as run:
                with self.assertRaises(subprocess.CalledProcessError) as caught:
                    cleanup_runtime('owned-synthetic-device', journal)
            self.assertIs(caught.exception, failure)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(json.loads(path.read_text())['events'][-1], {'stage': 'delete', 'event': 'started', 'elapsedMs': 0})
            with mock.patch('check_ios_tls_runtime.subprocess.run') as absent:
                cleanup_runtime(None, journal)
            absent.assert_not_called()


if __name__ == '__main__':
    unittest.main()
