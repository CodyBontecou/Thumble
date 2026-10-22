"""Strict admission for the native synthetic hold witness's one fixed diagnostic."""
import re

REASONS = frozenset({"sample_changed", "input_expired", "lease_expired", "native_input_released", "packet_source_barrier", "activation_barrier", "output_failed", "explicit_release", "shutdown", "other"})
PATTERN = re.compile(r"probe_hold_diagnostic reason=([a-z_]+) elapsed_ms=(0|[1-9][0-9]{0,6}) samples=(0|[1-9][0-9]{0,6}) report_matches=(true|false)")


def decode_native_hold_diagnostic(line):
    if type(line) is not str or len(line) > 256 or not line.isascii(): return None
    value = line[:-1] if line.endswith("\n") else line
    match = PATTERN.fullmatch(value)
    if not match or match[1] not in REASONS: return None
    elapsed, samples = int(match[2]), int(match[3])
    if elapsed > 180000 or samples > 1000000: return None
    return {"reason": match[1], "elapsedMs": elapsed, "samples": samples, "reportMatches": match[4] == "true"}
