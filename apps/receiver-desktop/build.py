"""Build a replaceable-library desktop bundle and a platform install package."""
from importlib.metadata import distribution
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'apps/receiver-desktop'
VERSION = '0.1.0'


def main():
    import PyInstaller.__main__
    arguments = ['--noconfirm', '--clean', '--onedir', '--name', 'thumble-receiver',
                 '--collect-data', 'thumble_receiver', '--hidden-import', 'qrcode.image.pure',
                 '--additional-hooks-dir', str(APP / 'hooks'),
                 '--exclude-module', 'PySide6.QtQml', '--exclude-module', 'PySide6.QtQuick']
    if sys.platform == 'win32':
        from PySide6.QtGui import QImage
        icon = ROOT / 'build/desktop/Icon.ico'
        icon.parent.mkdir(parents=True, exist_ok=True)
        if not QImage(str(APP / 'thumble_receiver/Icon.png')).save(str(icon)):
            raise RuntimeError('Could not convert the existing app icon for Windows')
        arguments += ['--windowed', '--icon', str(icon), '--exclude-module', 'vgamepad.lin']
    elif sys.platform == 'linux':
        arguments += ['--collect-all', 'evdev']
    else:
        raise RuntimeError('Build this package on Windows or Linux')
    arguments.append(str(APP / 'launcher.py'))
    os.chdir(ROOT)
    PyInstaller.__main__.run(arguments)
    folder = ROOT / 'dist/thumble-receiver'
    shutil.copy2(APP / 'README.md', folder / 'README.md')
    shutil.copy2(APP / 'THIRD_PARTY_NOTICES.md', folder / 'THIRD_PARTY_NOTICES.md')
    shutil.copy2(APP / 'thumble_receiver/Icon.png', folder / 'Icon.png')
    licenses = folder / 'ThirdParty'
    licenses.mkdir(exist_ok=True)
    packages = ['PySide6-Essentials', 'shiboken6', 'cryptography', 'qrcode', 'pypng', 'websockets']
    packages.append('vgamepad' if sys.platform == 'win32' else 'evdev')
    for package in packages:
        metadata = distribution(package)
        for file in metadata.files or []:
            if any(part.lower().startswith(('license', 'copying')) for part in file.parts):
                path = Path(metadata.locate_file(file))
                if path.is_file():
                    shutil.copy2(path, licenses / (package + '-' + path.name))
    for path in (APP / 'licenses').glob('*'):
        shutil.copy2(path, licenses / path.name)
    release = ROOT / 'dist/desktop-releases'
    release.mkdir(exist_ok=True)
    if sys.platform == 'win32':
        compiler = shutil.which('ISCC') or str(Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)')) / 'Inno Setup 6/ISCC.exe')
        subprocess.run([compiler, '/O' + str(release), str(APP / 'packaging/windows.iss')], check=True,
                       env={**os.environ, 'THUMBLE_DESKTOP_DIST': str(folder)})
    else:
        path = release / f'Thumble-Receiver-{VERSION}-linux-x64.tar.gz'
        with tarfile.open(path, 'w:gz') as archive:
            archive.add(folder, arcname='thumble-receiver')
    artifacts = [path for path in release.iterdir() if path.suffix in ('.exe', '.gz')]
    (release / 'SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name + '\n'
                                             for path in sorted(artifacts)), encoding='utf-8')


if __name__ == '__main__':
    main()
