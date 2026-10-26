"""The phone's v3 state and the Mac receiver's Xbox report contract."""
from dataclasses import dataclass
import math
import struct


def integer(value, minimum=0, maximum=9_007_199_254_740_991):
    return type(value) is int and minimum <= value <= maximum


def number(value):
    try:
        return type(value) in (int, float) and math.isfinite(value)
    except OverflowError:
        return False


def rounded(value):
    # Swift's rounded() uses ties away from zero, unlike Python's round().
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)


@dataclass(frozen=True)
class State:
    buttons: int = 0
    lx: float = 0
    ly: float = 0
    rx: float = 0
    ry: float = 0
    lt: float = 0
    rt: float = 0

    @classmethod
    def parse(cls, value):
        if not isinstance(value, dict) or set(value) != set(cls.__dataclass_fields__):
            raise ValueError("Expected exactly seven state fields")
        if not integer(value['buttons'], maximum=32767):
            raise ValueError("Invalid buttons")
        for key in ('lx', 'ly', 'rx', 'ry', 'lt', 'rt'):
            if not number(value[key]) or not (-1 if key[1] != 't' else 0) <= value[key] <= 1:
                raise ValueError("Invalid axis")
        return cls(**value)

    @property
    def mask(self):
        mask = sum(1 << bit for index, bit in enumerate((12, 13, 14, 15, 8, 9, 5, 4, 6, 7, 0, 1, 2, 3, 10))
                   if self.buttons & (1 << index))
        if mask & 3 == 3:
            mask &= ~3
        if mask & 12 == 12:
            mask &= ~12
        return mask

    @property
    def axes(self):
        return tuple(rounded(value * (32768 if value < 0 else 32767))
                     for value in (self.lx, self.ly, self.rx, self.ry))

    def report(self):
        return struct.pack('<BBHBBhhhh6x', 0, 20, self.mask, rounded(self.lt * 255),
                           rounded(self.rt * 255), *self.axes)


NEUTRAL = State()
