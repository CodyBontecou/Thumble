import unittest
from pathlib import Path
import tempfile
from unittest.mock import patch

from thumble_receiver.install import desktop_entry, desktop_exec
from thumble_receiver.install import install_user


class InstallTests(unittest.TestCase):
    def test_linux_upgrade_updates_existing_autostart_to_new_installed_binary(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            source = home / 'download'
            source.mkdir()
            (source / 'thumble-receiver').touch()
            startup = home / 'config/autostart/io.thumble.receiver.desktop'
            startup.parent.mkdir(parents=True)
            startup.write_text(desktop_entry([str(home / 'data/thumble/receiver/0.1.0/thumble-receiver')], background=True))
            with patch('sys.platform', 'linux'), patch('sys.frozen', True, create=True), \
                    patch('sys.executable', str(source / 'thumble-receiver')), \
                    patch('pathlib.Path.home', return_value=home), \
                    patch.dict('os.environ', {'XDG_DATA_HOME': str(home / 'data'), 'XDG_CONFIG_HOME': str(home / 'config')}), \
                    patch('thumble_receiver.install.register_protocol'):
                install_user()
            self.assertIn(desktop_exec([str(home / 'data/thumble/receiver/0.1.1/thumble-receiver')]), startup.read_text())
            self.assertIn('--background', startup.read_text())

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
