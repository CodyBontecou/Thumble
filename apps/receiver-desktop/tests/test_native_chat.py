"""Real OS text delivery into an isolated QA widget; never a game or human chat."""
import os
import sys
import time
import unittest
from concurrent.futures import ThreadPoolExecutor


@unittest.skipUnless(os.environ.get('THUMBLE_NATIVE_DESKTOP_QA') == '1', 'Native desktop QA runs in its own isolated CI display')
class NativeChatTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'win32', 'Windows power-message dispatcher')
    def test_native_power_message_reaches_release_hook_without_suspending_the_runner(self):
        import ctypes
        from ctypes import wintypes
        from PySide6.QtWidgets import QApplication, QLineEdit
        from thumble_receiver.power import WindowsEvents
        application = QApplication.instance() or QApplication([])
        calls = []
        event_filter = WindowsEvents(lambda: calls.append('release'))
        application.installNativeEventFilter(event_filter)
        widget = QLineEdit()
        widget.show()
        application.processEvents()
        user = ctypes.WinDLL('user32', use_last_error=True)
        user.PostMessageW.argtypes = (wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)
        try:
            self.assertTrue(user.PostMessageW(int(widget.winId()), 0x218, 4, 0))
            deadline = time.monotonic() + 2
            while not calls and time.monotonic() < deadline:
                application.processEvents()
                time.sleep(0.005)
            self.assertTrue(calls)
        finally:
            application.removeNativeEventFilter(event_filter)
            widget.close()

    def test_os_window_messages_reach_only_the_selected_qa_widget(self):
        from PySide6.QtWidgets import QApplication, QLineEdit
        from thumble_receiver.chat import WindowsTarget, X11Target
        application = QApplication.instance() or QApplication([])
        selected, other = QLineEdit(), QLineEdit()
        selected.setWindowTitle('Thumble isolated chat QA')
        other.setWindowTitle('Thumble untouched QA')
        selected.show()
        other.show()
        application.processEvents()
        native = WindowsTarget() if sys.platform == 'win32' else X11Target()
        handle = int(selected.winId())
        if sys.platform == 'win32':
            import ctypes
            from ctypes import wintypes
            user = ctypes.WinDLL('user32', use_last_error=True)
            user.CreateWindowExW.argtypes = (wintypes.DWORD, wintypes.LPCWSTR, wintypes.LPCWSTR,
                wintypes.DWORD, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                wintypes.HWND, wintypes.HMENU, wintypes.HINSTANCE, ctypes.c_void_p)
            user.CreateWindowExW.restype = wintypes.HWND
            user.GetWindowTextW.argtypes = (wintypes.HWND, wintypes.LPWSTR, ctypes.c_int)
            user.DestroyWindow.argtypes = (wintypes.HWND,)
            # A real Unicode Win32 EDIT recipient. Qt's WM_CHAR path converts
            # each surrogate into a separate key event, unlike Win32 text input.
            handle = user.CreateWindowExW(0, 'EDIT', '', 0x50000000,
                0, 0, 250, 40, handle, None, None, None)
            self.assertTrue(handle)
        target = (handle, native.pid(handle)) if sys.platform == 'win32' else (str(handle), str(os.getpid()))
        # This fixture owns its recipient. Production capture/focus rejection is
        # tested separately; no WoW process or account is involved in OS QA.
        native.focused = lambda _: True
        message = 'Native hello' if sys.platform != 'win32' else 'Native hello 😀'
        try:
            with ThreadPoolExecutor(max_workers=1) as pool:
                future = pool.submit(native.type, target, message)
                deadline = time.monotonic() + 5
                while not future.done() and time.monotonic() < deadline:
                    application.processEvents()
                    time.sleep(0.005)
                future.result(timeout=1)
            for _ in range(20):
                application.processEvents()
                time.sleep(0.005)
            if sys.platform == 'win32':
                value = ctypes.create_unicode_buffer(1024)
                user.GetWindowTextW(handle, value, len(value))
                self.assertEqual(value.value, message)
            else:
                self.assertEqual(selected.text(), message)
            self.assertEqual(other.text(), '')
        finally:
            if sys.platform == 'win32':
                user.DestroyWindow(handle)
            selected.close()
            other.close()
