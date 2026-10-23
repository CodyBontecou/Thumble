"""Durable fixed-stage diagnostics for the owned synthetic iOS runtime runner."""
import contextlib
import json
import math
import os
from pathlib import Path
import tempfile
import time

STAGES = frozenset({'sdk', 'compile', 'sign', 'verify-signature', 'list-runtimes',
                    'create', 'boot', 'bootstatus', 'install', 'container', 'launch',
                    'runtime-wait', 'report', 'failure-report', 'shutdown', 'delete'})


class IOSRuntimeStages:
    def __init__(self, path, now=time.monotonic):
        self._path = Path(path)
        self._now = now
        self._start = now()
        self._last = self._start
        self._events = []
        if not math.isfinite(self._start) or self._start < 0:
            raise ValueError('ios_runtime_stage_clock_invalid')

    def _record(self, stage, event):
        if stage not in STAGES or event not in ('started', 'completed'):
            raise ValueError('ios_runtime_stage_invalid')
        now = self._now()
        if not math.isfinite(now) or now < self._last or now - self._start > 3600:
            raise ValueError('ios_runtime_stage_clock_invalid')
        if len(self._events) >= 64:
            raise ValueError('ios_runtime_stage_capacity')
        value = {'stage': stage, 'event': event, 'elapsedMs': int((now - self._start) * 1000)}
        events = self._events + [value]
        encoded = (json.dumps({'version': 1, 'scope': 'ios-runtime-runner-stages', 'events': events}, sort_keys=True) + '\n').encode('ascii')
        if len(encoded) > 8192:
            raise ValueError('ios_runtime_stage_capacity')
        self._path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary = tempfile.mkstemp(prefix='.ios-runtime-stages-', dir=self._path.parent)
        try:
            with os.fdopen(fd, 'wb') as output:
                output.write(encoded)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self._path)
            directory = os.open(str(self._path.parent), os.O_RDONLY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        self._events = events
        self._last = now

    @contextlib.contextmanager
    def step(self, stage):
        self._record(stage, 'started')
        yield
        self._record(stage, 'completed')

    @contextlib.contextmanager
    def cleanup_step(self, stage):
        """Diagnostic write failures must never prevent owned external cleanup."""
        if stage not in ('shutdown', 'delete'):
            raise ValueError('ios_runtime_cleanup_stage_invalid')
        try:
            self._record(stage, 'started')
        except Exception:
            pass
        yield
        # Preserve command exceptions and never forge a completed failed call.
        try:
            self._record(stage, 'completed')
        except Exception:
            pass
