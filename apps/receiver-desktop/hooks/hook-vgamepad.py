"""Package the client without importing vgamepad or bundling driver installers.

Importing vgamepad connects to ViGEmBus immediately, which is unavailable on a
hosted runner. Locate the top-level package spec without executing it instead.
"""
from importlib.util import find_spec
from pathlib import Path

from PyInstaller.utils.hooks import copy_metadata

root = Path(find_spec('vgamepad').origin).parent
hiddenimports = ['vgamepad.win.virtual_gamepad', 'vgamepad.win.vigem_client',
                 'vgamepad.win.vigem_commons']
binaries = [(str(path), str(Path('vgamepad') / path.parent.relative_to(root)))
            for path in root.glob('win/vigem/client/*/*.dll')]
datas = copy_metadata('vgamepad')
