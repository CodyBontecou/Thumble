import threading
import unittest
from unittest.mock import MagicMock, patch

from thumble_receiver.chat import ChatDelivery, ChatError, WindowsTarget, X11Target, validate


class ChatTests(unittest.TestCase):
    def test_only_literal_single_line_channel_messages_are_allowed(self):
        self.assertEqual(validate('/quit', 'say'), '/s /quit')
        self.assertEqual(validate('  hello 😀  ', 'party'), '/p hello 😀')
        for text, channel in (('', 'say'), (' ', 'say'), ('hello', 'exec'), ('a\nb', 'say'),
                              ('a\0b', 'say'), ('x\u2028y', 'say'), ('x\u2029y', 'say'),
                              ('😀' * 61, 'say'), ('\ud800', 'say'), (None, 'say')):
            with self.subTest(text=repr(text), channel=channel), self.assertRaises(ChatError):
                validate(text, channel)

    def test_delivery_targets_same_window_and_never_executes_transcript_commands(self):
        target = MagicMock()
        target.capture.return_value = ('window', 'pid')
        target.focused.return_value = True
        ChatDelivery(target).send('/logout; $(echo bad)', 'guild', threading.Event())
        self.assertEqual(target.key.call_args_list[0].args, (('window', 'pid'), 'Escape'))
        self.assertEqual([call.args[1] for call in target.key.call_args_list], ['Escape', 'Return', 'Return'])
        self.assertEqual(''.join(call.args[1] for call in target.type.call_args_list), '/g /logout; $(echo bad)')

    def test_focus_loss_or_cancellation_never_submits(self):
        for mode in ('focus', 'cancel'):
            target, cancelled = MagicMock(), threading.Event()
            target.capture.return_value = ('window', 'pid')
            if mode == 'focus':
                target.focused.side_effect = [True, False]
            else:
                cancelled.set()
            with self.assertRaises(ChatError):
                ChatDelivery(target).send('hello', 'say', cancelled)
            self.assertFalse(target.type.called)
            self.assertFalse(any(call.args[-1] == 'Return' for call in target.key.call_args_list))

    def test_windows_unicode_events_stay_on_the_captured_window(self):
        target = object.__new__(WindowsTarget)
        target.user = MagicMock()
        target.user.MapVirtualKeyW.return_value = 28
        target.focused = lambda _: True
        target.message = MagicMock()
        window = (12345, 678)
        target.type(window, 'A😀')
        self.assertEqual([call.args[2] for call in target.message.call_args_list], [65, 0xd83d, 0xde00])
        self.assertTrue(all(call.args[0] == window for call in target.message.call_args_list))
        target.key(window, 'Return')
        self.assertEqual(target.message.call_args_list[-2].args[1], 0x100)
        self.assertEqual(target.message.call_args_list[-1].args[1], 0x101)

    def test_x11_types_over_stdin_with_an_explicit_window_and_no_shell(self):
        target = object.__new__(X11Target)
        target.executable = '/usr/bin/xdotool'
        target.focused = lambda _: True
        with patch('thumble_receiver.chat.subprocess.run') as run:
            run.return_value.stdout = ''
            target.type(('123', '456'), '/s literal; $(bad)')
            args, kwargs = run.call_args
            self.assertEqual(args[0], ['/usr/bin/xdotool', 'type', '--window', '123', '--delay', '0', '--file', '-'])
            self.assertEqual(kwargs['input'], '/s literal; $(bad)')
            self.assertNotIn('shell', kwargs)


if __name__ == '__main__':
    unittest.main()
