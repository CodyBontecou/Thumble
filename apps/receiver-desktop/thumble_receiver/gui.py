"""Native Qt pairing/settings window and system tray, with input on its own loop."""
import asyncio
from copy import copy
from importlib.resources import files
from pathlib import Path
import threading
import sys

from PySide6.QtCore import QObject, QTimer, Qt, Signal, QUrl
from PySide6.QtGui import QAction, QIcon, QPixmap, QDesktopServices
from PySide6.QtWidgets import (QApplication, QCheckBox, QComboBox, QFileDialog, QHBoxLayout,
                              QLabel, QMainWindow, QMenu, QPushButton, QSystemTrayIcon,
                              QVBoxLayout, QWidget)
from PySide6.QtNetwork import QNetworkInterface

from .access import atomic_json
from .pairing import Invitation, private_ipv4
from .pairing_image import pairing_png
from .install import autostart_enabled, set_autostart


class Signals(QObject):
    invitation = Signal(str)
    status = Signal(object)
    cloud = Signal(str)
    error = Signal(str)
    finished = Signal()


class Runtime:
    def __init__(self, args):
        self.args, self.events = args, Signals()
        self.thread = self.loop = self.server = self.stop_event = self.cloud = None
        self.stop_requested = False

    def start(self):
        if self.thread and self.thread.is_alive():
            return
        self.stop_requested = False
        self.thread = threading.Thread(target=self._run, name='thumble-network')
        self.thread.start()

    def _run(self):
        from .__main__ import run
        try:
            asyncio.run(run(copy(self.args), self))
        except Exception as error:
            self.events.error.emit(str(error))
        finally:
            self.loop = self.server = self.stop_event = self.cloud = None
            self.events.finished.emit()

    def attach(self, loop, server, stop, cloud):
        self.loop, self.server, self.stop_event, self.cloud = loop, server, stop, cloud
        if self.stop_requested:
            stop.set()

    def command(self, operation):
        if self.loop and self.server:
            def schedule():
                async def execute():
                    try:
                        await operation()
                    except Exception:
                        self.events.error.emit('The receiver action failed. Check setup and try again.')
                asyncio.create_task(execute())
            self.loop.call_soon_threadsafe(schedule)

    def disconnect(self):
        self.command(lambda: self.server.reset_pairing())

    def share(self):
        self.command(lambda: self.cloud.start())

    def unshare(self):
        self.command(lambda: self.cloud.stop())

    def sync(self, roots):
        self.command(lambda: self.server.configure_sync(roots))

    def stop(self):
        self.stop_requested = True
        if self.loop and self.stop_event:
            self.loop.call_soon_threadsafe(self.stop_event.set)


class Window(QMainWindow):
    def __init__(self, runtime, args, settings):
        super().__init__()
        self.runtime, self.args, self.settings = runtime, args, settings
        self.invitation, self.quitting, self.restarting = '', False, False
        self.setWindowTitle('Thumble Receiver')
        self.resize(520, 720)
        icon = QPixmap()
        icon.loadFromData(files('thumble_receiver').joinpath('Icon.png').read_bytes())
        self.setWindowIcon(QIcon(icon))
        container = QWidget()
        layout = QVBoxLayout(container)
        layout.setContentsMargins(24, 24, 24, 24)
        layout.setSpacing(12)
        title = QLabel('Pair your phone')
        font = title.font(); font.setPointSize(22); font.setBold(True); title.setFont(font)
        layout.addWidget(title)
        instructions = QLabel('Open Thumble on your phone and scan this code.\nKeep both devices on the same Wi-Fi.')
        instructions.setWordWrap(True)
        layout.addWidget(instructions)
        self.status = QLabel('Starting receiver…')
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        setup = QPushButton('Gamepad driver setup…')
        setup.clicked.connect(self.setup_driver)
        layout.addWidget(setup)
        self.qr = QLabel('Waiting for a local Wi-Fi connection')
        self.qr.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.qr.setMinimumSize(300, 300)
        layout.addWidget(self.qr, 1)
        row = QHBoxLayout()
        self.copy = QPushButton('Copy pairing link')
        self.copy.setEnabled(False)
        self.copy.clicked.connect(lambda: QApplication.clipboard().setText(self.invitation))
        row.addWidget(self.copy)
        reset = QPushButton('Disconnect and pair again')
        reset.clicked.connect(runtime.disconnect)
        row.addWidget(reset)
        layout.addLayout(row)
        self.cloud_status = QLabel('ChatGPT pairing is off')
        self.cloud_status.setWordWrap(True)
        layout.addWidget(self.cloud_status)
        row = QHBoxLayout()
        self.share = QPushButton('Pair through ChatGPT…')
        self.share.clicked.connect(runtime.share)
        row.addWidget(self.share)
        stop_share = QPushButton('Stop sharing')
        stop_share.clicked.connect(runtime.unshare)
        row.addWidget(stop_share)
        layout.addLayout(row)
        self.sync_label = QLabel('ConsolePort: waiting for setup')
        self.sync_label.setWordWrap(True)
        layout.addWidget(self.sync_label)
        row = QHBoxLayout()
        self.sync_enabled = QCheckBox('Sync ConsolePort after /reload')
        self.sync_enabled.setChecked(not args.no_consoleport_sync)
        self.sync_enabled.toggled.connect(self.change_sync)
        row.addWidget(self.sync_enabled)
        folder = QPushButton('Choose WoW folder…')
        folder.clicked.connect(self.choose_folder)
        row.addWidget(folder)
        layout.addLayout(row)
        row = QHBoxLayout()
        row.addWidget(QLabel('Wi-Fi address'))
        self.address = QComboBox()
        self.address.setEditable(True)
        addresses = []
        for address in QNetworkInterface.allAddresses():
            try:
                value = private_ipv4(address.toString())
                if value not in addresses:
                    addresses.append(value)
            except ValueError:
                pass
        self.address.addItems(addresses)
        if args.address:
            self.address.setCurrentText(args.address)
        row.addWidget(self.address, 1)
        restart = QPushButton('Restart here')
        restart.clicked.connect(self.restart)
        row.addWidget(restart)
        layout.addLayout(row)
        startup = QCheckBox('Start when I sign in')
        startup.setChecked(autostart_enabled())
        startup.toggled.connect(self.change_startup)
        layout.addWidget(startup)
        self.setCentralWidget(container)
        self.tray = QSystemTrayIcon(self.windowIcon(), self)
        self.tray.setToolTip('Thumble Receiver')
        menu = QMenu(self)
        for label, action in (('Pair phone…', self.show_pairing), ('Pair through ChatGPT…', runtime.share),
                              ('Stop ChatGPT sharing', runtime.unshare),
                              ('Disconnect and pair again', runtime.disconnect), ('Quit Thumble Receiver', self.quit)):
            item = QAction(label, self)
            item.triggered.connect(action)
            menu.addAction(item)
        self.tray.setContextMenu(menu)
        self.tray.activated.connect(lambda reason: self.show_pairing() if reason == QSystemTrayIcon.ActivationReason.Trigger else None)
        if QSystemTrayIcon.isSystemTrayAvailable():
            self.tray.show()
        runtime.events.invitation.connect(self.set_invitation)
        runtime.events.status.connect(self.set_status)
        runtime.events.cloud.connect(self.cloud_status.setText)
        runtime.events.error.connect(lambda message: self.status.setText('Receiver unavailable: ' + message))
        runtime.events.finished.connect(self.finished)

    def set_invitation(self, invitation):
        self.invitation = invitation
        self.copy.setEnabled(bool(invitation))
        self.share.setEnabled(bool(invitation))
        if invitation:
            image = QPixmap()
            image.loadFromData(pairing_png(invitation))
            self.qr.setPixmap(image.scaled(320, 320, Qt.AspectRatioMode.KeepAspectRatio,
                                          Qt.TransformationMode.FastTransformation))
        else:
            self.qr.clear()
            self.qr.setText('Phone connected · pairing code cleared')

    def set_status(self, status):
        if status['connected']:
            self.status.setText('Phone connected · controller ready' if status['ready'] else 'Phone connected · controls paused')
        else:
            self.status.setText('Ready to pair · code expires in two minutes')
        self.sync_label.setText(status.get('sync', 'ConsolePort sync off'))

    def save_settings(self):
        self.settings.update(wowDirs=[str(root) for root in self.args.wow_dir],
                             syncEnabled=self.sync_enabled.isChecked(), address=self.address.currentText())
        try:
            path = Path(self.args.data_dir) / 'settings.json'
            path.parent.mkdir(parents=True, exist_ok=True)
            atomic_json(path, self.settings)
        except OSError:
            self.status.setText('Settings could not be saved. Check data-folder permissions.')

    def change_sync(self, enabled):
        self.args.no_consoleport_sync = not enabled
        self.runtime.sync(self.args.wow_dir if enabled else [])
        self.save_settings()

    def change_startup(self, enabled):
        try:
            set_autostart(enabled)
        except (OSError, RuntimeError):
            self.status.setText('Could not change start-at-sign-in. Check installation permissions.')

    def setup_driver(self):
        if sys.platform == 'win32':
            QDesktopServices.openUrl(QUrl('https://github.com/nefarius/ViGEmBus/releases/tag/v1.22.0'))
        else:
            path = Path(sys.executable).parent / 'README.md' if getattr(sys, 'frozen', False) else Path(__file__).resolve().parents[1] / 'README.md'
            QDesktopServices.openUrl(QUrl.fromLocalFile(str(path)))

    def choose_folder(self):
        folder = QFileDialog.getExistingDirectory(self, 'Choose your World of Warcraft folder')
        if folder:
            self.args.wow_dir = [Path(folder)]
            self.runtime.sync(self.args.wow_dir if self.sync_enabled.isChecked() else [])
            self.save_settings()

    def restart(self):
        try:
            self.args.address = private_ipv4(self.address.currentText())
        except ValueError:
            self.status.setText('Choose a private IPv4 address on the phone Wi-Fi network.')
            return
        self.save_settings()
        self.restarting = True
        self.status.setText('Releasing controls and restarting the receiver…')
        if self.runtime.thread and self.runtime.thread.is_alive():
            self.runtime.stop()
        else:
            self.finished()

    def finished(self):
        if self.quitting:
            QApplication.instance().quit()
        elif self.restarting:
            self.restarting = False
            QTimer.singleShot(100, self.runtime.start)

    def show_pairing(self):
        self.showNormal()
        self.raise_()
        self.activateWindow()

    def quit(self):
        self.quitting = True
        self.status.setText('Releasing controls…')
        if self.runtime.thread and self.runtime.thread.is_alive():
            self.runtime.stop()
        else:
            QApplication.instance().quit()

    def closeEvent(self, event):
        event.ignore()
        if self.tray.isVisible() and not self.quitting:
            self.hide()
        else:
            self.quit()


def run_gui(args, settings=None):
    application = QApplication.instance() or QApplication([])
    application.setApplicationName('Thumble Receiver')
    application.setOrganizationName('Thumble')
    application.setDesktopFileName('io.thumble.receiver')
    application.setQuitOnLastWindowClosed(False)
    runtime = Runtime(args)
    window = Window(runtime, args, settings or {})
    if not args.background or not window.tray.isVisible():
        window.show()
    runtime.start()
    result = application.exec()
    runtime.stop()
    if runtime.thread:
        runtime.thread.join(timeout=15)
    return result


def smoke(args, path):
    application = QApplication.instance() or QApplication([])
    runtime = Runtime(args)
    window = Window(runtime, args, {})
    window.set_invitation(Invitation('192.168.1.2', 8765, '0' * 64).renew())
    window.status.setText('UI test · synthetic pairing code')
    window.show()

    def capture():
        destination = Path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not window.grab().save(str(destination)):
            raise RuntimeError('Could not save desktop UI screenshot')
        application.quit()

    QTimer.singleShot(150, capture)
    application.exec()
    print('PASS: desktop pairing window and QR rendering')
