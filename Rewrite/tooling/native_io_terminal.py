"""Bounded corroborating aggregates from the owned debug iOS runtime probe only."""
import copy
import json
import os
from pathlib import Path
import re
import tempfile
import threading
from native_input_error import CODES, SERVE_CODES, KINDS, EXITS, _unique, _reject

PREFIX = 'native_io_terminal '
NAMES = ('trustAuthorize', 'trustAuthenticate', 'inputWait', 'inputHeld', 'controlWait', 'controlHeld', 'sampleCycle', 'sampleGap', 'nativeClientSend', 'nativeClientReceive', 'nativeServerQueue', 'nativeServerApply', 'nativeServerReply', 'nativeOutput')
METRIC_FIELDS = frozenset({'metric', 'count', 'totalUs', 'maximumUs', 'activeCount', 'oldestActiveUs'})
COMMON = frozenset({'version', 'role', 'context', 'metrics'})
PER_ROLE = 4
REPORT_BYTES = 32768
U64_MAX = 18446744073709551615


def _integer(value):
    if re.fullmatch(r'0|-?[1-9][0-9]{0,19}', value) is None:
        raise ValueError('native_io_terminal_invalid')
    return int(value)


def decode_native_io_terminal(line):
    if type(line) is not str or len(line) > 4096 or not line.isascii():
        return None
    text = line[:-1] if line.endswith('\n') else line
    if not text.startswith(PREFIX):
        return None
    try:
        value = json.loads(text[len(PREFIX):], object_pairs_hook=_unique, parse_int=_integer, parse_float=_reject, parse_constant=_reject)
        if type(value) is not dict or not COMMON <= set(value) or type(value['version']) is not int or value['version'] != 1:
            return None
        role, context = value['role'], value['context']
        if type(role) is not str or role not in {'broker', 'receiver'} or type(context) is not str:
            return None
        fields = set(value) - COMMON
        if fields == {'op', 'code'}:
            if context not in {'native-client', 'native-server-wait', 'native-server-send', 'phone-control', 'sample'} or type(value['op']) is not int or not 0 <= value['op'] <= 11 or type(value['code']) is not str or value['code'] not in (SERVE_CODES if context in {'phone-control', 'sample'} else CODES):
                return None
            if (context.startswith('native-server-') and role != 'receiver') or (context in {'native-client', 'phone-control', 'sample'} and role != 'broker'):
                return None
        elif fields == {'exit', 'owned'}:
            if role != 'receiver' or context != 'native-server-exit' or type(value['exit']) is not str or value['exit'] not in EXITS or type(value['owned']) is not int or not 0 <= value['owned'] <= 2:
                return None
        elif fields == {'ioKind', 'osCode'}:
            if context != 'native-read' or type(value['ioKind']) is not str or value['ioKind'] not in KINDS:
                return None
            if value['osCode'] is not None and (type(value['osCode']) is not int or not -2147483648 <= value['osCode'] <= 2147483647):
                return None
        else:
            return None
        rows = value['metrics']
        if type(rows) is not list or len(rows) != len(NAMES):
            return None
        for row, name in zip(rows, NAMES):
            if type(row) is not dict or set(row) != METRIC_FIELDS or type(row['metric']) is not str or row['metric'] != name:
                return None
            for key in METRIC_FIELDS - {'metric'}:
                maximum = 16 if key == 'activeCount' else U64_MAX
                if type(row[key]) is not int or not 0 <= row[key] <= maximum:
                    return None
        return value
    except (ValueError, TypeError, RecursionError):
        return None


class NativeIOTerminals:
    """First four records per role, at most eight total and32KiB. No raw stderr."""
    def __init__(self):
        self._values = []
        self._lock = threading.Lock()

    def observe(self, line):
        with self._lock:
            if len(self._values) >= 2 * PER_ROLE:
                return
            value = decode_native_io_terminal(line)
            if value is None or sum(row['role'] == value['role'] for row in self._values) >= PER_ROLE:
                return
            candidate = self._values + [value]
            if len(self._encode(candidate)) <= REPORT_BYTES:
                self._values.append(value)

    @staticmethod
    def _encode(values):
        return (json.dumps({'version': 1, 'scope': 'native-io-terminal-aggregates', 'events': values}, sort_keys=True, separators=(',', ':')) + '\n').encode('ascii')

    def snapshot(self):
        with self._lock:
            return copy.deepcopy(self._values)

    def write_report(self, destination):
        temporary = None
        try:
            path = Path(destination)
            payload = self._encode(self.snapshot())
            if len(payload) > REPORT_BYTES:
                return False
            descriptor, temporary = tempfile.mkstemp(prefix='.native-io-terminal-', dir=path.parent)
            with os.fdopen(descriptor, 'wb') as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            temporary = None
            return True
        except (OSError, TypeError, ValueError):
            return False
        finally:
            if temporary is not None:
                try:
                    os.unlink(temporary)
                except OSError:
                    pass
