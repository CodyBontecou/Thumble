import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from argparse import Namespace
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock

from thumble_receiver.gui import Signals, Window, Runtime
from thumble_receiver.power import WindowsEvents
from thumble_receiver.pairing import Invitation
from PySide6.QtWidgets import QApplication


class GuiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.application = QApplication.instance() or QApplication([])

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.args = Namespace(data_dir=Path(self.directory.name), address='192.168.1.2',
                              wow_dir=[], no_consoleport_sync=False)
        self.runtime = MagicMock()
        self.runtime.events = Signals()
        self.window = Window(self.runtime, self.args, {})

    def tearDown(self):
        self.window.hide()
        self.window.tray.hide()
        self.window.deleteLater()
        self.application.processEvents()
        self.directory.cleanup()

    def test_current_qr_is_removed_immediately_when_phone_pairs(self):
        self.window.set_invitation(Invitation('192.168.1.2', 1234, '0' * 64).renew())
        self.assertTrue(self.window.copy.isEnabled())
        self.assertFalse(self.window.qr.pixmap().isNull())
        self.window.set_invitation('')
        self.assertFalse(self.window.copy.isEnabled())
        self.assertEqual(self.window.invitation, '')
        self.assertIn('code cleared', self.window.qr.text())

    def test_sync_preference_is_saved_and_dispatched_without_restarting_input(self):
        self.window.sync_enabled.setChecked(False)
        self.runtime.sync.assert_called_with([])
        self.assertTrue(self.args.no_consoleport_sync)
        self.assertTrue((self.args.data_dir / 'settings.json').exists())

    def test_ready_status_and_wrong_interface_restart_validation(self):
        self.window.set_status(dict(connected=True, ready=True, sync='Hero synced'))
        self.assertIn('controller ready', self.window.status.text())
        self.window.address.setCurrentText('8.8.8.8')
        self.window.restart()
        self.assertIn('private IPv4', self.window.status.text())
        self.runtime.stop.assert_not_called()

    def test_suspend_and_resume_hooks_release_before_async_cleanup(self):
        self.window.power.sleep_changed(True)
        self.window.power.sleep_changed(False)
        self.assertEqual(self.runtime.pause_for_sleep.call_count, 2)
        runtime = Runtime(self.args)
        runtime.server = MagicMock()
        runtime.command = MagicMock()
        runtime.pause_for_sleep()
        runtime.server.output.release.assert_called_once()
        runtime.server.session.chat_cancel.set.assert_called_once()
        runtime.command.assert_called_once()

    def test_windows_power_broadcast_revokes_input_on_both_edges(self):
        import ctypes
        from ctypes import wintypes
        release = MagicMock()
        event_filter = WindowsEvents(release)
        for parameter in (4, 7, 18):
            event = wintypes.MSG()
            event.message, event.wParam = 0x218, parameter
            self.assertEqual(event_filter.nativeEventFilter(b'windows_generic_MSG', ctypes.addressof(event)), (False, 0))
        self.assertEqual(release.call_count, 3)
