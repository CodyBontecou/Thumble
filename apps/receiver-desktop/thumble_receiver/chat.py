"""Literal chat delivery to an identified WoW window, never an arbitrary app."""
import ctypes
from ctypes import wintypes
import os
from pathlib import Path, PureWindowsPath
import shutil
import subprocess
import sys
import time
import unicodedata

CHANNELS = dict(say='/s ', party='/p ', raid='/raid ', guild='/g ', instance='/i ')
WOW_IMAGES = {'wow.exe', 'wowclassic.exe', 'wowclassict.exe', 'wowclassic_t.exe',
              'wowclassicera.exe', 'wowb.exe', 'wowt.exe', 'wow-64.exe'}


class ChatError(ValueError):
    pass


def validate(text, channel):
    if (not isinstance(text, str) or not isinstance(channel, str) or channel not in CHANNELS
            or not text.strip() or any(unicodedata.category(c) in ('Cc', 'Cs', 'Zl', 'Zp') for c in text)
            or len(text.encode('utf-8')) > 240):
        raise ChatError('Use one message of up to 240 UTF-8 bytes and choose a chat channel.')
    return CHANNELS[channel] + text.strip()


class ChatDelivery:
    def __init__(self, target):
        self.target = target

    def send(self, text, channel, cancelled):
        content = validate(text, channel)
        deadline = time.monotonic() + 3.5
        target = self.target.capture()

        def check():
            if time.monotonic() > deadline:
                raise ChatError('Chat delivery timed out. Check WoW before trying again.')
            if cancelled.is_set():
                raise ChatError('Delivery cancelled. Check WoW before trying again.')
            if not self.target.focused(target):
                raise ChatError('WoW lost focus. Check its chat box before trying again.')

        check()
        self.target.key(target, 'Escape')
        if cancelled.wait(0.08):
            check()
        check()
        self.target.key(target, 'Return')
        if cancelled.wait(0.12):
            check()
        check()
        # Keep chunks on Unicode scalar boundaries, with a focus check per chunk.
        for offset in range(0, len(content), 8):
            check()
            self.target.type(target, content[offset:offset + 8])
        cancelled.wait(0.10)
        check()
        self.target.key(target, 'Return')
        # Confirms only OS delivery, as on the Mac; the game has no receipt API.


class WindowsTarget:
    def __init__(self):
        self.user = ctypes.WinDLL('user32', use_last_error=True)
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.user.GetForegroundWindow.restype = wintypes.HWND
        self.user.GetWindowThreadProcessId.argtypes = (wintypes.HWND, ctypes.POINTER(wintypes.DWORD))
        self.user.IsWindowUnicode.argtypes = (wintypes.HWND,)
        self.user.IsWindowUnicode.restype = wintypes.BOOL
        self.user.SendMessageTimeoutW.argtypes = (wintypes.HWND, wintypes.UINT, wintypes.WPARAM,
                                                  wintypes.LPARAM, wintypes.UINT, wintypes.UINT,
                                                  ctypes.POINTER(ctypes.c_size_t))
        self.user.SendMessageTimeoutW.restype = ctypes.c_ssize_t
        self.user.MapVirtualKeyW.argtypes = (wintypes.UINT, wintypes.UINT)
        self.kernel.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.QueryFullProcessImageNameW.argtypes = (wintypes.HANDLE, wintypes.DWORD,
                                                          wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD))
        self.kernel.CloseHandle.argtypes = (wintypes.HANDLE,)

    def pid(self, window):
        pid = wintypes.DWORD()
        self.user.GetWindowThreadProcessId(window, ctypes.byref(pid))
        return pid.value

    def capture(self):
        window = self.user.GetForegroundWindow()
        pid = self.pid(window)
        process = self.kernel.OpenProcess(0x1000, False, pid)
        if not process:
            raise ChatError('Bring World of Warcraft to the front and try again.')
        try:
            size = wintypes.DWORD(32768)
            name = ctypes.create_unicode_buffer(size.value)
            if (not self.kernel.QueryFullProcessImageNameW(process, 0, name, ctypes.byref(size))
                    or PureWindowsPath(name.value).name.lower() not in WOW_IMAGES
                    or not self.user.IsWindowUnicode(window)):
                raise ChatError('Bring World of Warcraft to the front and try again.')
        finally:
            self.kernel.CloseHandle(process)
        return window, pid

    def focused(self, target):
        window, pid = target
        return bool(window and self.user.GetForegroundWindow() == window and self.pid(window) == pid)

    def message(self, target, kind, value, flags=1):
        if not self.focused(target):
            raise ChatError('WoW lost focus. Check its chat box before trying again.')
        result = ctypes.c_size_t()
        if not self.user.SendMessageTimeoutW(target[0], kind, value, flags, 0x3, 250, ctypes.byref(result)):
            raise ChatError('WoW did not accept window input. Check its chat box before retrying.')

    def key(self, target, key):
        code = {'Escape': 0x1b, 'Return': 0x0d}[key]
        flags = 1 | (self.user.MapVirtualKeyW(code, 0) << 16)
        self.message(target, 0x100, code, flags)
        self.message(target, 0x101, code, flags | 0xc0000000)

    def type(self, target, text):
        units = text.encode('utf-16-le')
        for index in range(0, len(units), 2):
            self.message(target, 0x102, int.from_bytes(units[index:index + 2], 'little'))


class X11Target:
    def __init__(self, executable=None):
        self.executable = executable or shutil.which('xdotool')
        if not self.executable or not os.environ.get('DISPLAY'):
            raise ChatError('WoW chat on Linux requires X11/XWayland, DISPLAY, and xdotool.')

    def command(self, *args, content=None):
        try:
            result = subprocess.run([self.executable, *args], input=content, capture_output=True,
                                    text=True, encoding='utf-8', timeout=0.25, check=True)
            return result.stdout.strip()
        except (OSError, subprocess.SubprocessError) as error:
            raise ChatError('WoW window input failed. Check its chat box before retrying.') from error

    def capture(self):
        window = self.command('getactivewindow')
        pid = self.command('getwindowpid', window)
        if not window.isdecimal() or not pid.isdecimal():
            raise ChatError('Bring World of Warcraft to the front and try again.')
        try:
            command = (Path('/proc') / pid / 'cmdline').read_bytes().split(b'\0')
        except OSError as error:
            raise ChatError('Could not verify the focused WoW process.') from error
        # Wine may expose the Windows image as argv[0] or a following argument.
        if not any(PureWindowsPath(os.fsdecode(part)).name.lower() in WOW_IMAGES for part in command[:8]):
            raise ChatError('Bring World of Warcraft to the front and try again.')
        return window, pid

    def focused(self, target):
        return self.command('getactivewindow') == target[0] and self.command('getwindowpid', target[0]) == target[1]

    def key(self, target, key):
        if not self.focused(target):
            raise ChatError('WoW lost focus. Check its chat box before trying again.')
        self.command('key', '--window', target[0], key)

    def type(self, target, text):
        if not self.focused(target):
            raise ChatError('WoW lost focus. Check its chat box before trying again.')
        self.command('type', '--window', target[0], '--delay', '0', '--file', '-', content=text)


def native_chat():
    if sys.platform == 'win32':
        return ChatDelivery(WindowsTarget())
    if sys.platform == 'linux' and shutil.which('xdotool') and os.environ.get('DISPLAY'):
        return ChatDelivery(X11Target())
    return None
