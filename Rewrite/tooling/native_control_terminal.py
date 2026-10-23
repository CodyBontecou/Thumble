"""Bounded static outcomes after synthetic control-owner cleanup; never a first-cause claim."""
import re

CODES = frozenset({
    'authenticated_control_transport_failed', 'authenticated_control_budget_exhausted',
    'authenticated_control_message_invalid', 'input_session_closed',
    'input_packet_invalid', 'input_packet_budget_exhausted', 'input_broker_unavailable',
    'input_protocol_invalid', 'input_renewal_too_early', 'phone_authentication_rejected',
    'phone_trust_owner_unavailable', 'native_input_unavailable',
    'native_input_transport_failed', 'native_input_timeout',
    'native_input_frame_invalid', 'native_input_server_rejected',
    'native_input_rejected', 'native_input_release_unconfirmed', 'pairing_closed', 'other',
})
_PATTERN = re.compile(r'native_control_terminal code=([a-z_]{1,96}) elapsed_us=(0|[1-9][0-9]{0,19})')


def decode_native_control_terminal(line):
    if type(line) is not str or len(line) > 256 or not line.isascii():
        return None
    value = line[:-1] if line.endswith('\n') else line
    match = _PATTERN.fullmatch(value)
    if not match:
        return None
    elapsed = int(match[2])
    if elapsed > 18446744073709551615:
        return None
    return {'code': match[1] if match[1] in CODES else 'other', 'elapsedUs': elapsed}


class NativeControlTerminals:
    """Retain at most the first64 sanitized outcomes from one synthetic process."""
    def __init__(self):
        self._values = []

    def observe(self, line):
        if len(self._values) >= 64:
            return
        value = decode_native_control_terminal(line)
        if value is not None:
            self._values.append(value)

    def snapshot(self):
        return [dict(value) for value in self._values]

    def write_report(self, path):
        """Best-effort atomic diagnostics; failure must never bypass owned cleanup."""
        import json
        import os
        from pathlib import Path
        import tempfile
        staged = None
        try:
            target = Path(path)
            payload = (json.dumps({'version': 1, 'scope': 'native-control-terminal-outcomes',
                                   'events': self.snapshot()}, sort_keys=True) + '\n').encode('ascii')
            if len(payload) > 8192:
                return False
            target.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(dir=target.parent, prefix='.' + target.name + '.', delete=False) as output:
                staged = Path(output.name)
                output.write(payload)
                output.flush()
                os.fsync(output.fileno())
            os.replace(staged, target)
            return True
        except OSError:
            return False
        finally:
            if staged is not None:
                try:
                    staged.unlink(missing_ok=True)
                except OSError:
                    pass
