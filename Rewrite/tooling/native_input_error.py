"""Strict bounded debug error-path events; never retain raw stderr or infer causality."""
import json
import os
from pathlib import Path
import re
import tempfile
import threading

PREFIX = 'native_input_error '
CODES = frozenset({'native_input_timeout', 'native_input_transport_failed', 'native_input_frame_invalid', 'native_input_rejected', 'native_owner_reply_timeout', 'native_owner_reply_closed', 'native_input_owner_failed', 'input_session_closed', 'input_packet_invalid', 'other'})
OPERATIONS = frozenset({'native-client', 'native-server-wait', 'native-server-send', 'phone-control', 'sample'})
IO_CONTEXTS = frozenset({'native-read', 'native-write', 'native-read-options', 'native-write-options'})
KINDS = frozenset({'would-block', 'timed-out', 'interrupted', 'unexpected-eof', 'broken-pipe', 'connection-reset', 'connection-aborted', 'not-connected', 'invalid-input', 'permission-denied', 'other'})
EXITS = frozenset({'stopped', 'handshake', 'read-deadline', 'read-failure', 'invalid-frame', 'invalid-payload', 'queue-full', 'queue-closed', 'wake-failure', 'send-failure'})
COMMON = frozenset({'version', 'role', 'context'})


def _unique(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError('native_input_error_invalid')
        value[key] = item
    return value


def _integer(value):
    if re.fullmatch(r'0|-?[1-9][0-9]{0,9}', value) is None:
        raise ValueError('native_input_error_invalid')
    return int(value)


def _reject(_):
    raise ValueError('native_input_error_invalid')


def decode_native_input_error(line):
    if type(line) is not str or len(line) > 384 or not line.isascii():
        return None
    text = line[:-1] if line.endswith('\n') else line
    if not text.startswith(PREFIX):
        return None
    try:
        value = json.loads(text[len(PREFIX):], object_pairs_hook=_unique, parse_int=_integer, parse_float=_reject, parse_constant=_reject)
        if type(value) is not dict or not COMMON <= set(value) or type(value['version']) is not int or value['version'] != 1:
            return None
        if type(value['role']) is not str or value['role'] not in {'receiver', 'broker'} or type(value['context']) is not str:
            return None
        fields = set(value) - COMMON
        context = value['context']
        if fields == {'op', 'code'}:
            if context not in OPERATIONS or type(value['op']) is not int or not 0 <= value['op'] <= 11 or type(value['code']) is not str or value['code'] not in CODES:
                return None
        elif fields == {'ioKind', 'osCode'}:
            if context not in IO_CONTEXTS or type(value['ioKind']) is not str or value['ioKind'] not in KINDS:
                return None
            if value['osCode'] is not None and (type(value['osCode']) is not int or not -2147483648 <= value['osCode'] <= 2147483647):
                return None
        elif fields == {'exit', 'owned'}:
            if value['role'] != 'receiver' or context != 'native-server-exit' or type(value['exit']) is not str or value['exit'] not in EXITS or type(value['owned']) is not int or not 0 <= value['owned'] <= 2:
                return None
        elif fields == {'exit'}:
            if type(value['exit']) is not str or (context, value['exit']) not in {('native-read', 'eof'), ('native-write', 'zero-write')}:
                return None
        else:
            return None
        return value
    except (ValueError, TypeError, RecursionError):
        return None


class NativeInputErrors:
    """First32 fixed events across the two owned processes; total artifact <=8KiB."""
    def __init__(self):
        self._values = []
        self._lock = threading.Lock()

    def observe(self, line):
        with self._lock:
            if len(self._values) >= 32:
                return
            value = decode_native_input_error(line)
            if value is None:
                return
            candidate = self._values + [value]
            if len(self._encode(candidate)) <= 8192:
                self._values.append(value)

    @staticmethod
    def _encode(values):
        return (json.dumps({'version': 1, 'scope': 'native-input-error-events', 'events': values}, sort_keys=True, separators=(',', ':')) + '\n').encode('ascii')

    def snapshot(self):
        with self._lock:
            return [dict(value) for value in self._values]

    def write_report(self, destination):
        temporary = None
        try:
            path = Path(destination)
            payload = self._encode(self.snapshot())
            if len(payload) > 8192:
                return False
            descriptor, temporary = tempfile.mkstemp(prefix='.native-input-error-', dir=path.parent)
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
