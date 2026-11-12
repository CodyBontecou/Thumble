"""Observe virtual-device state through OS consumer APIs, not adapter doubles."""
import ctypes
import sys
import time

from .state import rounded


class WindowsProbe:
    class Gamepad(ctypes.Structure):
        _fields_ = [('buttons', ctypes.c_uint16), ('lt', ctypes.c_uint8), ('rt', ctypes.c_uint8),
                    ('lx', ctypes.c_int16), ('ly', ctypes.c_int16), ('rx', ctypes.c_int16), ('ry', ctypes.c_int16)]

    def __init__(self, backend):
        class InputState(ctypes.Structure):
            _fields_ = [('packet', ctypes.c_uint32), ('pad', WindowsProbe.Gamepad)]
        self.InputState = InputState
        self.library = ctypes.WinDLL('xinput1_4')
        self.library.XInputGetState.argtypes = (ctypes.c_uint32, ctypes.POINTER(InputState))
        self.library.XInputGetState.restype = ctypes.c_uint32
        self.slot = None

    def matches(self, expected):
        for slot in range(4) if self.slot is None else [self.slot]:
            value = self.InputState()
            if self.library.XInputGetState(slot, ctypes.byref(value)) != 0:
                continue
            pad = value.pad
            if ((pad.buttons, pad.lt, pad.rt) == (expected.mask, rounded(expected.lt * 255), rounded(expected.rt * 255))
                    and (pad.lx, pad.ly, pad.rx, pad.ry) == expected.axes):
                self.slot = slot
                return True
        return False


class LinuxProbe:
    def __init__(self, backend):
        self.backend = backend
        self.device = backend.device.device
        if self.device is None:
            raise RuntimeError('The uinput gamepad did not enumerate as an evdev input device')

    def matches(self, expected):
        e = self.backend.e
        bits = (12, 13, 15, 14, 8, 9, 5, 4, 6, 7, 10)
        keys = {key for key, bit in zip(self.backend.buttons, bits) if expected.mask & (1 << bit)}
        if set(self.device.active_keys()) != keys:
            return False
        lx, _, rx, _ = expected.axes
        ly = rounded(-expected.ly * (32768 if expected.ly > 0 else 32767))
        ry = rounded(-expected.ry * (32768 if expected.ry > 0 else 32767))
        values = (lx, ly, rx, ry, rounded(expected.lt * 255), rounded(expected.rt * 255),
                  int(bool(expected.mask & 8)) - int(bool(expected.mask & 4)),
                  int(bool(expected.mask & 2)) - int(bool(expected.mask & 1)))
        codes = (e.ABS_X, e.ABS_Y, e.ABS_RX, e.ABS_RY, e.ABS_Z, e.ABS_RZ, e.ABS_HAT0X, e.ABS_HAT0Y)
        return all(self.device.absinfo(code).value == value for code, value in zip(codes, values))


def probe(backend):
    # The combined adapter owns keyboard/pointer output alongside this gamepad.
    # Observe the actual gamepad device, not its lifecycle wrapper.
    from .desktop_input import CombinedOutput
    if isinstance(backend, CombinedOutput):
        backend = backend.gamepad
    return WindowsProbe(backend) if sys.platform == 'win32' else LinuxProbe(backend)


def wait_for(probe, state):
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        if probe.matches(state):
            return
        time.sleep(0.005)
    raise RuntimeError('OS gamepad state did not match the authenticated phone input')
