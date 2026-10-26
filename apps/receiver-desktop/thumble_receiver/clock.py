"""Elapsed clock that includes system suspend where the OS exposes it."""
import time


def monotonic():
    if hasattr(time, 'CLOCK_BOOTTIME'):
        return time.clock_gettime(time.CLOCK_BOOTTIME)
    return time.monotonic()
