"""Real OS text delivery into an isolated QA widget; never a game or human chat."""
import os
import sys
import time
import unittest
from concurrent.futures import ThreadPoolExecutor


@unittest.skipUnless(os.environ.get('THUMBLE_NATIVE_DESKTOP_QA') == '1', 'Native desktop QA runs in its own isolated CI display')
class NativeChatTests(unittest.TestCase):
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
            self.assertEqual(selected.text(), message)
            self.assertEqual(other.text(), '')
        finally:
            selected.close()
            other.close()
