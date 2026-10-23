import json
import contextlib
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import check_ios_tls_runtime as runner


class OrchestrationTests(unittest.TestCase):
    def execute(self, launch_error=None, cleanup_errors=(), sidecar_error=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / 'apps/mobile/tests/ios'
            config.mkdir(parents=True)
            (config / 'AppProbeConfig.json').write_text('{"port":27183}')
            (config / 'Simulator.entitlements').write_bytes(runner.plistlib.dumps({}))
            fixture = root / 'packages/fixtures/controller-layout-v1.json'
            fixture.parent.mkdir(parents=True)
            fixture.write_text('{}')
            container = root / 'container'
            (container / 'Documents').mkdir(parents=True)
            (container / 'Documents/result.json').write_text(json.dumps(dict(version=1, scope='explicit-map-ios-runtime', passed=True, phase='finish', generation='2', elapsedMs=75000, publications=4500, maximumPublicationGapMs=18, tlsRuntimeOutcome='ready', controlFailureStage='none')))
            report = root / 'result.json'
            calls = []
            def command(*args):
                if 'list' in args:
                    return json.dumps({'runtimes':[{'isAvailable':True,'identifier':'.iOS-26','version':'26'}]})
                if 'create' in args: return 'owned-synthetic-device'
                if 'get_app_container' in args: return str(container)
                return '/synthetic-sdk'
            def run(args, **kwargs):
                calls.append((args, kwargs))
                if 'launch' in args:
                    if kwargs.get('timeout') != 60: raise AssertionError('launch_not_bounded')
                    if launch_error: raise launch_error
                for index, stage in enumerate(('shutdown', 'delete')):
                    if stage in args:
                        if kwargs.get('timeout') != 15: raise AssertionError('cleanup_not_bounded')
                        if index < len(cleanup_errors) and cleanup_errors[index]: raise cleanup_errors[index]
                return subprocess.CompletedProcess(args, 0)
            error = None
            sidecar = patch.object(runner, 'write_orchestration_report', side_effect=sidecar_error) if sidecar_error else contextlib.nullcontext()
            with sidecar, patch.object(runner, 'ROOT', root), patch.object(runner, 'command', command), patch.object(runner.subprocess, 'run', run), patch('sys.argv', ['runner','--report',str(report)]):
                try: runner.main()
                except Exception as caught: error = caught
            return error, calls, json.loads(report.read_text()), json.loads(report.with_name('result-orchestration.json').read_text()) if report.with_name('result-orchestration.json').exists() else None

    def test_sidecar_failure_cannot_replace_primary(self):
        failure = subprocess.TimeoutExpired('private', 60)
        error, calls, report, outcome = self.execute(failure, sidecar_error=OSError('private-write'))
        self.assertIs(error, failure)
        self.assertEqual(report['phase'], 'runner-launching')
        self.assertIsNone(outcome)
        self.assertEqual(sum('delete' in args for args, _ in calls), 1)

    def test_sidecar_failure_fails_otherwise_successful_runner(self):
        error, _, report, outcome = self.execute(sidecar_error=OSError('private-write'))
        self.assertEqual(str(error), 'ios_runtime_orchestration_report_failed')
        self.assertTrue(report['passed'])
        self.assertIsNone(outcome)

    def test_cleanup_timeout_still_attempts_delete_with_independent_budget(self):
        from ios_runtime_stages import IOSRuntimeStages
        with tempfile.TemporaryDirectory() as temporary:
            journal = IOSRuntimeStages(Path(temporary) / 'stages.json')
            failure = subprocess.TimeoutExpired('not-reflected', 15)
            with patch.object(runner.subprocess, 'run', side_effect=[failure, subprocess.CompletedProcess([], 0)]) as run:
                self.assertTrue(runner.cleanup_runtime('owned-synthetic-device', journal))
            self.assertEqual([call.args[0][2] for call in run.call_args_list], ['shutdown', 'delete'])
            self.assertEqual([call.kwargs['timeout'] for call in run.call_args_list], [15, 15])
            events = json.loads((Path(temporary) / 'stages.json').read_text())['events']
            self.assertNotIn({'stage':'shutdown','event':'completed','elapsedMs':0}, events)
            self.assertEqual([(e['stage'], e['event']) for e in events], [('shutdown','started'), ('delete','started'), ('delete','completed')])

    def test_blocked_launch_persists_phase_and_preserves_primary_through_both_cleanup_failures(self):
        failure = subprocess.TimeoutExpired('private-not-reflected', 60)
        error, calls, report, outcome = self.execute(failure, (subprocess.TimeoutExpired('shutdown',15), OSError('private-delete-error')))
        self.assertIs(error, failure)
        self.assertEqual([args[2] for args, _ in calls if len(args)>2 and args[2] in ('shutdown','delete')], ['shutdown','delete'])
        self.assertFalse(report['passed'])
        self.assertEqual(report['phase'], 'runner-launching')
        self.assertEqual(outcome, {'version':1,'scope':'ios-runtime-orchestration','launchTimedOut':True,'cleanupFailed':True})
        self.assertNotIn('private', json.dumps(report)+json.dumps(outcome))

    def test_successful_runtime_with_cleanup_failure_fails_overall_without_rewriting_runtime(self):
        error, _, report, outcome = self.execute(cleanup_errors=(OSError('private'), None))
        self.assertEqual(str(error), 'ios_runtime_cleanup_failed')
        self.assertTrue(report['passed'])
        self.assertTrue(outcome['cleanupFailed'])
        self.assertFalse(outcome['launchTimedOut'])

    def test_success_preserves_result_and_fixed_clean_outcome(self):
        error, _, report, outcome = self.execute()
        self.assertIsNone(error)
        self.assertTrue(report['passed'])
        self.assertEqual(outcome, {'version':1,'scope':'ios-runtime-orchestration','launchTimedOut':False,'cleanupFailed':False})

    def test_non_timeout_primary_is_not_reclassified_or_replaced(self):
        failure = subprocess.CalledProcessError(1, 'private')
        error, _, report, outcome = self.execute(failure)
        self.assertIs(error, failure)
        self.assertEqual(report['phase'], 'runner-launching')
        self.assertFalse(outcome['launchTimedOut'])
        self.assertFalse(outcome['cleanupFailed'])


if __name__ == '__main__': unittest.main()
