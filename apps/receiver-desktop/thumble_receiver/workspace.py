"""Shared offline workspace in a restricted native WebEngine window."""
from concurrent.futures import ThreadPoolExecutor
from copy import deepcopy
from importlib.resources import files
import json
from pathlib import Path
import sys

from PySide6.QtCore import QObject, Signal, Slot, QUrl
from PySide6.QtWidgets import QMainWindow, QFileDialog, QApplication, QMessageBox
from PySide6.QtWebChannel import QWebChannel
from PySide6.QtWebEngineCore import QWebEnginePage, QWebEngineSettings
from PySide6.QtWebEngineWidgets import QWebEngineView

from .profiles import ProfileStore, encoded, load_json, validate_profile
from .workspace_profiles import WorkspaceProfiles
from .install import autostart_enabled


class LocalPage(QWebEnginePage):
    def __init__(self, entry, parent):
        super().__init__(parent)
        self.entry = entry.resolve()

    def acceptNavigationRequest(self, url, navigation_type, is_main_frame):
        return url.isLocalFile() and Path(url.toLocalFile()).resolve() == self.entry

    def createWindow(self, kind):
        return None


class Bridge(QObject):
    response = Signal(str)
    completed = Signal(str, object, object)

    def __init__(self, owner, parent):
        super().__init__(parent)
        self.owner = owner
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='thumble-workspace')
        self.profiles = WorkspaceProfiles(ProfileStore(getattr(owner.args, 'profile_dir', None) or Path(owner.args.data_dir) / 'profiles'))
        self.status = dict(connected=False, ready=False)
        self.detail = 'Starting receiver…'
        owner.runtime.events.status.connect(self.update_status)
        owner.runtime.events.error.connect(self.update_error)
        self.completed.connect(self.finish)

    def update_status(self, value):
        self.status = deepcopy(value)
        self.detail = ('Phone acknowledged the controller · controls paused until resumed on phone'
                       if value.get('connected') and value.get('ready') else
                       'Waiting for phone layout acknowledgement' if value.get('connected') else 'Ready to pair')

    def update_error(self, message):
        self.detail = str(message)
        self.status = dict(connected=False, ready=False, running=False, layoutAcknowledged=False)

    @Slot(str)
    def request(self, raw):
        request_id = None
        try:
            if len(raw.encode()) > 100000:
                raise ValueError('Workspace request exceeds size limit.')
            message = load_json(raw)
            request_id = message.get('id')
            if not isinstance(request_id, str) or len(request_id) > 80:
                raise ValueError('Invalid workspace request.')
            operation, payload = message.get('operation'), message.get('payload')
            if not isinstance(payload, dict):
                raise ValueError('Invalid workspace payload.')
            owner = self.owner
            if operation in ('save', 'activate', 'delete'):
                def mutate():
                    if operation == 'save':
                        self.profiles.save(payload.get('profile'), payload.get('expectedProfileRevision'), payload.get('viewport'))
                    elif operation == 'activate':
                        self.profiles.activate(payload.get('profileId'), payload.get('profileRevision'), payload.get('expectedActivationRevision'), payload.get('viewport'))
                    else:
                        self.profiles.delete(payload.get('profileId'), payload.get('expectedProfileRevision'), payload.get('expectedActivationRevision'))
                # The normal receiver poll observes activation and releases input
                # before sending layout-commit, exactly as for agent changes.
                action = mutate
            elif operation == 'snapshot':
                action = lambda: None
            else:
                if operation == 'disconnect':
                    owner.runtime.command(lambda: owner.runtime.server.disconnect_peer())
                elif operation == 'forget':
                    owner.runtime.disconnect()
                elif operation == 'retry':
                    owner.restart()
                elif operation == 'setup-driver':
                    owner.setup_driver()
                elif operation == 'copy-pairing':
                    if owner.invitation:
                        QApplication.clipboard().setText(owner.invitation)
                elif operation == 'choose-wow-folder':
                    owner.choose_folder()
                elif operation == 'settings':
                    if set(payload) - {'syncEnabled', 'startAtLogin'} or any(type(v) is not bool for v in payload.values()):
                        raise ValueError('Invalid receiver settings.')
                    if 'syncEnabled' in payload:
                        owner.sync_enabled.setChecked(payload['syncEnabled'])
                    if 'startAtLogin' in payload:
                        from .install import set_autostart
                        set_autostart(payload['startAtLogin'])
                elif operation == 'export':
                    profile = validate_profile(payload.get('profile'))
                    path, _ = QFileDialog.getSaveFileName(owner.studio, 'Export controller', 'controller.json', 'Controller JSON (*.json)')
                    if path:
                        Path(path).write_bytes(encoded(profile))
                    self.finish(request_id, dict(exported=bool(path)), None)
                    return
                else:
                    raise ValueError('Unknown workspace operation.')
                action = lambda: None
            # Only bounded snapshots cross the bridge. No pairing secret URLs,
            # arbitrary paths, commands, or profile-supplied URLs are executed.
            state = dict(platform='Windows' if sys.platform == 'win32' else 'Linux',
                         receiver={**self.status, 'running': owner.runtime.server is not None and self.status.get('running', False), 'detail': self.detail},
                         sync=dict(detail=owner.sync_label.text()),
                         settings=dict(syncEnabled=owner.sync_enabled.isChecked(), startAtLogin=autostart_enabled(),
                                       wowPaths=[str(p) for p in owner.args.wow_dir]))
            from .pairing_image import pairing_png
            import base64
            state['pairing'] = dict(png=base64.b64encode(pairing_png(owner.invitation)).decode()) if owner.invitation else None
            def execute():
                action()
                result = {**self.profiles.snapshot(), **state}
                if result['receiver'].get('revision') != result['activationRevision']:
                    result['receiver']['ready'] = False
                    result['receiver']['layoutAcknowledged'] = False
                if not result['receiver']['running']:
                    result['receiver'].update(connected=False, ready=False, layoutAcknowledged=False)
                return result
            future = self.executor.submit(execute)
            def done(result):
                try: self.completed.emit(request_id, result.result(), None)
                except Exception as error: self.completed.emit(request_id, None, str(error))
            future.add_done_callback(done)
        except Exception as error:
            self.finish(request_id, None, str(error))

    @Slot(str, object, object)
    def finish(self, request_id, result, error):
        self.response.emit(json.dumps(dict(id=request_id, result=result, error=error), allow_nan=False, separators=(',', ':')))


class WorkspaceWindow(QMainWindow):
    def __init__(self, owner):
        super().__init__()
        self.owner = owner
        self.setWindowTitle('Thumble Studio')
        self.setWindowIcon(owner.windowIcon())
        self.resize(1360, 860); self.setMinimumSize(960, 650)
        entry = Path(str(files('thumble_receiver').joinpath('workspace/index.html')))
        self.view = QWebEngineView(self)
        self.page = LocalPage(entry, self.view)
        self.view.setPage(self.page)
        self.page.settings().setAttribute(QWebEngineSettings.WebAttribute.LocalContentCanAccessRemoteUrls, False)
        self.page.settings().setAttribute(QWebEngineSettings.WebAttribute.JavascriptCanOpenWindows, False)
        self.channel = QWebChannel(self.page)
        self.bridge = Bridge(owner, self)
        self.channel.registerObject('workspace', self.bridge)
        self.page.setWebChannel(self.channel)
        self.setCentralWidget(self.view)
        self.view.load(QUrl.fromLocalFile(str(entry)))

    def closeEvent(self, event):
        if self.owner.quitting:
            event.accept()
            return
        event.ignore()
        # Closing to tray preserves the page and its draft. Actual Quit checks
        # unsaved changes before terminating the receiver.
        if self.owner.tray.isVisible():
            self.hide()
        else:
            self.owner.quit()

    def dispose(self):
        self.bridge.executor.shutdown(wait=True, cancel_futures=True)

    def confirm_quit(self, completion):
        def received(dirty):
            if dirty:
                result = QMessageBox.question(self, 'Discard unsaved changes?', 'Your controller has unsaved changes. Quit without saving?',
                    QMessageBox.StandardButton.Discard | QMessageBox.StandardButton.Cancel, QMessageBox.StandardButton.Cancel)
                completion(result == QMessageBox.StandardButton.Discard)
            else:
                completion(True)
        self.page.runJavaScript('Boolean(window.thumbleHasUnsavedChanges?.())', received)
