import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')

from argparse import Namespace
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock

from thumble_receiver.gui import Signals, Window
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
