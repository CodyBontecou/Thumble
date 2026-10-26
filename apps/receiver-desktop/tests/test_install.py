import unittest

from thumble_receiver.install import desktop_entry, desktop_exec


class InstallTests(unittest.TestCase):
    def test_desktop_entry_treats_paths_as_data_and_keeps_uri_placeholder_separate(self):
        command = ['/home/player/My Games/Thumble % wow/thumble-receiver']
        entry = desktop_entry(command)
        self.assertIn('Thumble %% wow/thumble-receiver" %u\n', entry)
        self.assertIn('MimeType=x-scheme-handler/thumble-receiver;', entry)
        self.assertNotIn('%u', desktop_entry(command, background=True))
        self.assertIn('--background', desktop_entry(command, background=True))
        for value in ('/path\nInjected=bad', '/path\0bad'):
            with self.assertRaises(ValueError):
                desktop_exec([value])
