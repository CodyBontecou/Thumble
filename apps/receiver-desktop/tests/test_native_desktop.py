"""OS delivery proof on isolated CI hosts; never enabled on a developer's desktop."""
import os
import sys
import time
import unittest
from thumble_receiver.desktop_input import DesktopOutput, LinuxDesktop, WindowsDesktop
from thumble_receiver.state import NEUTRAL, State

ENABLED = os.environ.get('THUMBLE_NATIVE_DESKTOP_QA') == '1'
def state(keys=(), buttons=0, x=0, y=0, sy=0):
    return State(desktop=dict(keys=list(keys),buttons=buttons,x=x,y=y,scrollX=0,scrollY=sy))

class NativeDesktopTests(unittest.TestCase):
    @unittest.skipUnless(ENABLED and sys.platform == 'linux', 'Requires isolated Linux uinput host')
    def test_linux_kernel_receives_keys_pointer_scroll_and_releases(self):
        import select
        from evdev import InputDevice, ecodes as e
        target=LinuxDesktop(); output=DesktopOutput(target)
        device=InputDevice(target.device.device.path)
        events=[]
        try:
            output.write(state(['key:ControlLeft','key:KeyA'],1,12,8,2))
            output.write(NEUTRAL)
            deadline=time.monotonic()+2
            while time.monotonic()<deadline:
                if not select.select([device.fd],[],[],.05)[0]: continue
                events.extend((event.type,event.code,event.value) for event in device.read())
                if (e.EV_KEY,e.KEY_LEFTCTRL,0) in events: break
            for event in [(e.EV_KEY,e.KEY_A,1),(e.EV_KEY,e.KEY_A,0),(e.EV_KEY,e.KEY_LEFTCTRL,1),(e.EV_KEY,e.KEY_LEFTCTRL,0),(e.EV_KEY,e.BTN_LEFT,1),(e.EV_KEY,e.BTN_LEFT,0),(e.EV_REL,e.REL_X,12),(e.EV_REL,e.REL_Y,8),(e.EV_REL,e.REL_WHEEL,-2)]:
                self.assertIn(event,events)
        finally:
            output.close();device.close()

    @unittest.skipUnless(ENABLED and sys.platform == 'win32', 'Requires isolated Windows desktop host')
    def test_windows_foreground_widget_receives_key_mouse_and_scroll(self):
        import ctypes
        from PySide6.QtWidgets import QApplication,QWidget
        from PySide6.QtCore import Qt
        app=QApplication.instance() or QApplication([])
        received=[]
        class Probe(QWidget):
            def keyPressEvent(self,event): received.append(('down',event.key()))
            def keyReleaseEvent(self,event): received.append(('up',event.key()))
            def mousePressEvent(self,event): received.append(('mouse-down',event.button()))
            def mouseReleaseEvent(self,event): received.append(('mouse-up',event.button()))
            def mouseMoveEvent(self,event): received.append(('move',0))
            def wheelEvent(self,event): received.append(('wheel',event.angleDelta().y()))
        window=Probe();window.resize(500,400);window.setMouseTracking(True);window.show();window.raise_();window.activateWindow();window.setFocus()
        for _ in range(20): app.processEvents();time.sleep(.02)
        user=ctypes.WinDLL('user32',use_last_error=True)
        user.SetForegroundWindow(int(window.winId()))
        point=window.mapToGlobal(window.rect().center());user.SetCursorPos(point.x(),point.y())
        target=WindowsDesktop();output=DesktopOutput(target)
        try:
            output.write(state(['key:ControlLeft','key:KeyA'],1,12,8,1))
            output.write(NEUTRAL)
            deadline=time.monotonic()+3
            while time.monotonic()<deadline:
                app.processEvents();time.sleep(.01)
                if ('up',int(Qt.Key.Key_A)) in received and ('mouse-up',Qt.MouseButton.LeftButton) in received: break
            self.assertIn(('down',int(Qt.Key.Key_A)),received)
            self.assertIn(('up',int(Qt.Key.Key_A)),received)
            self.assertIn(('mouse-down',Qt.MouseButton.LeftButton),received)
            self.assertIn(('mouse-up',Qt.MouseButton.LeftButton),received)
            self.assertIn(('move',0),received)
            self.assertIn(('wheel',-120),received)
        finally: output.close();window.close()
