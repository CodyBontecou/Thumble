"""Exercise the platform adapters without requiring privileged kernel drivers."""
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import MagicMock, patch

from thumble_receiver.output import LinuxOutput, WindowsOutput, native_output
from thumble_receiver.state import NEUTRAL, State


class OutputTests(unittest.TestCase):
    def test_windows_report_uses_xinput_axes_and_releases_buttons(self):
        pad = MagicMock()
        module = SimpleNamespace(VX360Gamepad=MagicMock(return_value=pad))
        with patch.dict(sys.modules, vgamepad=module):
            output = WindowsOutput()
            output.write(State(buttons=1, lx=-1, ly=1, rx=1, ry=-1, lt=0.5, rt=1))
            pad.press_button.assert_called_once_with(button=0x1000)
            pad.left_joystick.assert_called_with(x_value=-32768, y_value=32767)
            pad.right_joystick.assert_called_with(x_value=32767, y_value=-32768)
            pad.left_trigger.assert_called_with(value=128)
            pad.right_trigger.assert_called_with(value=255)
            output.write(NEUTRAL)
            self.assertEqual(pad.reset.call_count, 2)
            self.assertEqual(pad.update.call_count, 2)
            output.close()
            self.assertIsNone(output.pad)

    def test_linux_capabilities_axis_inversion_hats_and_release(self):
        names = ('BTN_SOUTH BTN_EAST BTN_NORTH BTN_WEST BTN_TL BTN_TR BTN_SELECT BTN_START '
                 'BTN_THUMBL BTN_THUMBR BTN_MODE ABS_X ABS_Y ABS_RX ABS_RY ABS_Z ABS_RZ '
                 'ABS_HAT0X ABS_HAT0Y EV_KEY EV_ABS BUS_USB').split()
        e = SimpleNamespace(**{name: index for index, name in enumerate(names)})
        device = MagicMock()
        module = SimpleNamespace(UInput=MagicMock(return_value=device), AbsInfo=lambda *args: args, ecodes=e)
        with patch.dict(sys.modules, evdev=module):
            output = LinuxOutput()
            capabilities = module.UInput.call_args.args[0]
            self.assertIn(e.BTN_SOUTH, capabilities[e.EV_KEY])
            self.assertEqual(dict(capabilities[e.EV_ABS])[e.ABS_Y], (0, -32768, 32767, 0, 0, 0))
            output.write(State(buttons=(1 << 12) | (1 << 10) | (1 << 2), ly=1, ry=-1, lt=1))
            device.write.assert_any_call(e.EV_ABS, e.ABS_Y, -32768)
            device.write.assert_any_call(e.EV_ABS, e.ABS_RY, 32767)
            device.write.assert_any_call(e.EV_ABS, e.ABS_HAT0X, -1)
            device.write.assert_any_call(e.EV_ABS, e.ABS_HAT0Y, -1)
            device.write.assert_any_call(e.EV_KEY, e.BTN_WEST, 1)
            output.write(NEUTRAL)
            for code in capabilities[e.EV_KEY]:
                device.write.assert_any_call(e.EV_KEY, code, 0)
            self.assertEqual(device.syn.call_count, 2)
            output.close()
            device.close.assert_called_once()

    def test_native_errors_do_not_fall_back_to_memory(self):
        with patch('thumble_receiver.output.sys.platform', 'win32'), patch(
                'thumble_receiver.output.WindowsOutput', side_effect=OSError('missing driver')):
            with self.assertRaises(RuntimeError):
                native_output()


if __name__ == '__main__':
    unittest.main()
