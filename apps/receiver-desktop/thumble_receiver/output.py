"""Native output, serialized with a watchdog independent of the asyncio loop."""
import sys
import threading

from .state import NEUTRAL, rounded
from .clock import monotonic


class MemoryOutput:
    """Explicit dry-run output; never selected as fallback after driver failure."""
    def __init__(self):
        self.state = NEUTRAL

    def write(self, state):
        self.state = state

    def close(self):
        self.write(NEUTRAL)


class WindowsOutput:
    def __init__(self):
        import vgamepad
        self.pad = vgamepad.VX360Gamepad()

    def write(self, state):
        # Rebuild every report so released buttons cannot remain latched.
        self.pad.reset()
        if state.mask:
            self.pad.press_button(button=state.mask)
        lx, ly, rx, ry = state.axes
        self.pad.left_joystick(x_value=lx, y_value=ly)
        self.pad.right_joystick(x_value=rx, y_value=ry)
        self.pad.left_trigger(value=rounded(state.lt * 255))
        self.pad.right_trigger(value=rounded(state.rt * 255))
        self.pad.update()

    def close(self):
        if self.pad is not None:
            try:
                self.write(NEUTRAL)
            finally:
                # Detach even if the driver refuses the final neutral report.
                self.pad = None


class LinuxOutput:
    def __init__(self):
        from evdev import UInput, AbsInfo, ecodes as e
        self.e = e
        self.buttons = (e.BTN_SOUTH, e.BTN_EAST, e.BTN_NORTH, e.BTN_WEST,
                        e.BTN_TL, e.BTN_TR, e.BTN_SELECT, e.BTN_START,
                        e.BTN_THUMBL, e.BTN_THUMBR, e.BTN_MODE)
        axes = [(code, AbsInfo(0, -32768, 32767, 0, 0, 0))
                for code in (e.ABS_X, e.ABS_Y, e.ABS_RX, e.ABS_RY)]
        axes += [(code, AbsInfo(0, 0, 255, 0, 0, 0)) for code in (e.ABS_Z, e.ABS_RZ)]
        axes += [(code, AbsInfo(0, -1, 1, 0, 0, 0)) for code in (e.ABS_HAT0X, e.ABS_HAT0Y)]
        self.device = UInput({e.EV_KEY: list(self.buttons), e.EV_ABS: axes},
                             name='Thumble Xbox Controller', vendor=0x045e,
                             product=0x028e, version=0x0110, bustype=e.BUS_USB)

    def write(self, state):
        e = self.e
        # Linux Y axes increase downwards; the wire/XInput axes increase upwards.
        lx, _, rx, _ = state.axes
        ly = rounded(-state.ly * (32768 if state.ly > 0 else 32767))
        ry = rounded(-state.ry * (32768 if state.ry > 0 else 32767))
        bits = (12, 13, 15, 14, 8, 9, 5, 4, 6, 7, 10)
        for code, bit in zip(self.buttons, bits):
            self.device.write(e.EV_KEY, code, int(bool(state.mask & (1 << bit))))
        values = (lx, ly, rx, ry, rounded(state.lt * 255), rounded(state.rt * 255),
                  int(bool(state.mask & 8)) - int(bool(state.mask & 4)),
                  int(bool(state.mask & 2)) - int(bool(state.mask & 1)))
        for code, value in zip((e.ABS_X, e.ABS_Y, e.ABS_RX, e.ABS_RY,
                                e.ABS_Z, e.ABS_RZ, e.ABS_HAT0X, e.ABS_HAT0Y), values):
            self.device.write(e.EV_ABS, code, value)
        self.device.syn()

    def close(self):
        try:
            self.write(NEUTRAL)
        finally:
            self.device.close()


def native_output():
    try:
        if sys.platform == 'win32':
            return WindowsOutput()
        if sys.platform == 'linux':
            return LinuxOutput()
    except Exception as error:
        raise RuntimeError('Native gamepad unavailable. Check ViGEmBus on Windows or /dev/uinput access on Linux.') from error
    raise RuntimeError('Native output supports Windows and Linux; use --dry-run on macOS')


class GuardedOutput:
    def __init__(self, backend, clock=monotonic):
        self.backend, self.clock = backend, clock
        self.lock = threading.Lock()
        self.deadline = 0
        self.generation = 0
        self.error = None
        self.closed = False
        self.stopped = threading.Event()
        try:
            backend.write(NEUTRAL)
        except Exception:
            try:
                backend.close()
            finally:
                raise
        self.thread = threading.Thread(target=self._watch, name='thumble-watchdog', daemon=True)
        self.thread.start()

    def _write(self, state):
        try:
            self.backend.write(state)
        except Exception as error:
            # Do not retain native exception tracebacks containing a gamepad
            # reference: Windows target removal depends on dropping that object.
            self.error = RuntimeError(str(error))
            self.deadline = 0
            self.generation += 1
            try:
                self.backend.close()
            except Exception:
                pass
            self.closed = True
            raise RuntimeError('Virtual gamepad report failed; the device was closed') from None

    def apply(self, state, deadline, generation):
        with self.lock:
            if self.error:
                raise RuntimeError('Native output failed') from self.error
            # A watchdog release invalidates input already parsed on the event loop.
            if generation != self.generation or self.clock() >= deadline:
                return False
            self._write(state)
            self.deadline = deadline
            return True

    def release(self):
        with self.lock:
            if not self.closed:
                self._write(NEUTRAL)
            self.deadline = 0
            self.generation += 1

    def expire(self):
        with self.lock:
            if self.deadline and self.clock() >= self.deadline:
                self._write(NEUTRAL)
                self.deadline = 0
                self.generation += 1

    def _watch(self):
        while not self.stopped.wait(0.02):
            try:
                self.expire()
            except Exception:
                return

    def close(self):
        self.stopped.set()
        self.thread.join()
        with self.lock:
            if not self.closed:
                try:
                    self.backend.close()
                finally:
                    self.closed = True
