"""Release before/after desktop suspend, in addition to the elapsed-clock guard."""
import ctypes
from ctypes import wintypes
import sys

from PySide6.QtCore import QAbstractNativeEventFilter, QCoreApplication, QObject, SLOT, Slot


class WindowsEvents(QAbstractNativeEventFilter):
    def __init__(self, release):
        super().__init__()
        self.release = release

    def nativeEventFilter(self, event_type, message):
        kind = event_type.encode() if isinstance(event_type, str) else bytes(event_type)
        if kind in (b'windows_generic_MSG', b'windows_dispatcher_MSG') and int(message):
            event = ctypes.cast(int(message), ctypes.POINTER(wintypes.MSG)).contents
            # PBT_APMSUSPEND, PBT_APMRESUMESUSPEND, PBT_APMRESUMEAUTOMATIC.
            if event.message == 0x218 and event.wParam in (4, 7, 18):
                self.release()
        return False, 0


class PowerMonitor(QObject):
    def __init__(self, release, parent=None):
        super().__init__(parent)
        self.release, self.filter, self.bus = release, None, None
        if sys.platform == 'win32':
            self.filter = WindowsEvents(release)
            QCoreApplication.instance().installNativeEventFilter(self.filter)
        elif sys.platform == 'linux':
            from PySide6.QtDBus import QDBusConnection
            self.bus = QDBusConnection.systemBus()
            self.bus.connect('org.freedesktop.login1', '/org/freedesktop/login1',
                             'org.freedesktop.login1.Manager', 'PrepareForSleep',
                             self, SLOT('sleep_changed(bool)'))

    @Slot(bool)
    def sleep_changed(self, sleeping):
        # Both edges revoke the current generation; a resumed connection must
        # never consume old buffered held input before a new neutral handshake.
        self.release()

    def close(self):
        if self.filter and QCoreApplication.instance():
            QCoreApplication.instance().removeNativeEventFilter(self.filter)
            self.filter = None
