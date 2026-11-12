"""Shared keyboard/mouse state reconciliation, under the native input watchdog lock."""
import ctypes
from importlib.resources import files
import json
import sys

KEYS = {'key:' + key['code']: key for key in json.loads(files('thumble_receiver').joinpath('DesktopKeys.json').read_bytes())}
MODIFIERS = {key for key in KEYS if any(name in key for name in ('Control', 'Shift', 'Alt', 'Meta'))}


def validate(value):
    if not isinstance(value, dict) or set(value) != {'keys', 'buttons', 'x', 'y', 'scrollX', 'scrollY'}:
        raise ValueError('Invalid keyboard/mouse state')
    from .state import integer, number
    keys = value['keys']
    if not isinstance(keys, list) or len(keys) > 128 or any(not isinstance(k, str) or k not in KEYS for k in keys) or len(set(keys)) != len(keys):
        raise ValueError('Invalid keyboard keys')
    if not integer(value['buttons'], 0, 7) or not all(number(value[k]) and abs(value[k]) <= 1e9 for k in ('x','y','scrollX','scrollY')):
        raise ValueError('Invalid pointer state')
    return {**value, 'keys': list(keys)}


def matches_profile(value, profile):
    if value is None: return True
    outputs = {output for mapping in (profile or {}).get('mappings', []) for output in mapping['outputs']}
    mask = sum(1 << i for i, key in enumerate(('mouse:left','mouse:right','mouse:middle')) if key in outputs)
    return (set(value['keys']) <= outputs and value['buttons'] & ~mask == 0
            and ('pointer' in outputs or not any(value[k] for k in ('x','y','scrollX','scrollY'))))


class DesktopOutput:
    def __init__(self, target):
        self.target = target
        self.keys, self.buttons, self.position = set(), 0, [0]*4

    def write(self, state):
        value = state.desktop or dict(keys=[], buttons=0, x=0, y=0, scrollX=0, scrollY=0)
        keys = set(value['keys'])
        # Ordinary keys release before modifiers; modifiers press before ordinary keys.
        for key in sorted(self.keys - keys, key=lambda k: (k in MODIFIERS, k)):
            self.target.key(KEYS[key], False); self.keys.remove(key)
        for key in sorted(keys - self.keys, key=lambda k: (k not in MODIFIERS, k)):
            self.keys.add(key); self.target.key(KEYS[key], True)
        for index in range(3):
            bit = 1 << index
            if bool(self.buttons & bit) != bool(value['buttons'] & bit):
                self.buttons = (self.buttons | bit) if value['buttons'] & bit else (self.buttons & ~bit)
                self.target.button(index, bool(value['buttons'] & bit))
        position = [round(value[k]) for k in ('x','y','scrollX','scrollY')]
        # An absent desktop state is a release/reset, never a reverse pointer motion.
        if state.desktop:
            delta = [a-b for a,b in zip(position, self.position)]
            if any(abs(n) > 10000 for n in delta):
                raise ValueError('Pointer jump exceeds the input bound')
            if any(delta): self.target.move(*delta, self.buttons)
        self.position = position

    def close(self):
        failure = None
        # A failed native report must not prevent releases for the other keys.
        for key in sorted(self.keys, key=lambda k: (k in MODIFIERS, k)):
            try: self.target.key(KEYS[key], False)
            except Exception as error: failure = failure or error
        for index in range(3):
            if self.buttons & (1 << index):
                try: self.target.button(index, False)
                except Exception as error: failure = failure or error
        self.keys.clear(); self.buttons = 0; self.position = [0]*4
        try: self.target.close()
        finally:
            if failure: raise failure


class CombinedOutput:
    def __init__(self, gamepad, factory):
        self.gamepad, self.factory, self.desktop = gamepad, factory, None

    def write(self, state):
        self.gamepad.write(state)
        if state.desktop is not None and self.desktop is None:
            self.desktop = DesktopOutput(self.factory())
        if self.desktop: self.desktop.write(state)

    def close(self):
        try:
            if self.desktop: self.desktop.close()
        finally: self.gamepad.close()


class LinuxDesktop:
    def __init__(self):
        from evdev import UInput, ecodes as e
        self.e = e
        self.device = UInput({e.EV_KEY: sorted({k['linux'] for k in KEYS.values()} | {e.BTN_LEFT,e.BTN_RIGHT,e.BTN_MIDDLE}), e.EV_REL: [e.REL_X,e.REL_Y,e.REL_WHEEL,e.REL_HWHEEL]}, name='Thumble Keyboard and Pointer', bustype=e.BUS_USB)

    def key(self, key, down):
        self.device.write(self.e.EV_KEY, key['linux'], int(down)); self.device.syn()

    def button(self, index, down):
        self.device.write(self.e.EV_KEY, [self.e.BTN_LEFT,self.e.BTN_RIGHT,self.e.BTN_MIDDLE][index], int(down)); self.device.syn()

    def move(self, x, y, sx, sy, buttons):
        for code, value in zip([self.e.REL_X,self.e.REL_Y,self.e.REL_HWHEEL,self.e.REL_WHEEL], [x,y,sx,-sy]):
            if value: self.device.write(self.e.EV_REL,code,value)
        self.device.syn()

    def close(self): self.device.close()


class WindowsDesktop:
    def __init__(self):
        from ctypes import wintypes as w
        class Mouse(ctypes.Structure):
            _fields_ = [('dx',w.LONG),('dy',w.LONG),('data',w.DWORD),('flags',w.DWORD),('time',w.DWORD),('extra',ctypes.c_size_t)]
        class Keyboard(ctypes.Structure):
            _fields_ = [('vk',w.WORD),('scan',w.WORD),('flags',w.DWORD),('time',w.DWORD),('extra',ctypes.c_size_t)]
        class Hardware(ctypes.Structure):
            _fields_ = [('msg',w.DWORD),('low',w.WORD),('high',w.WORD)]
        class Payload(ctypes.Union):
            _fields_ = [('mouse',Mouse),('keyboard',Keyboard),('hardware',Hardware)]
        class Input(ctypes.Structure):
            _anonymous_ = ('payload',)
            _fields_ = [('type',w.DWORD),('payload',Payload)]
        self.Input,self.Mouse,self.Keyboard = Input,Mouse,Keyboard
        self.user = ctypes.WinDLL('user32', use_last_error=True)
        self.user.SendInput.argtypes = [w.UINT, ctypes.POINTER(Input), ctypes.c_int]
        self.user.SendInput.restype = w.UINT

    def send(self, event):
        if self.user.SendInput(1, ctypes.byref(event), ctypes.sizeof(self.Input)) != 1:
            raise RuntimeError('Windows blocked keyboard/mouse input. Run the game and Thumble at the same privilege level.')

    def key(self, key, down):
        event=self.Input(); event.type=1
        event.keyboard=self.Keyboard(key.get('vk',0),key['scan'],(0 if key.get('vk') else 8) | (1 if key['extended'] else 0) | (0 if down else 2),0,0)
        self.send(event)

    def mouse(self, flags, x=0, y=0, data=0):
        event=self.Input(); event.type=0; event.mouse=self.Mouse(x,y,data & 0xffffffff,flags,0,0); self.send(event)

    def button(self,index,down): self.mouse([[2,4],[8,16],[32,64]][index][0 if down else 1])
    def move(self,x,y,sx,sy,buttons):
        if x or y: self.mouse(1,x,y)
        if sy: self.mouse(0x800,data=-sy*120)
        if sx: self.mouse(0x1000,data=sx*120)
    def close(self): pass


def native_desktop():
    if sys.platform == 'win32': return WindowsDesktop()
    if sys.platform == 'linux': return LinuxDesktop()
    raise RuntimeError('Use the native Mac receiver for keyboard/mouse input.')
