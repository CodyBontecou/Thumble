"""Exercise the actual installer, installed runtime, and synthetic GUI screenshot."""
import os
import asyncio
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlencode

ROOT = Path(__file__).resolve().parents[3]


def run(binary, *args, env=None):
    subprocess.run([str(binary), *args], env=env, check=True, timeout=120)


async def verify_callback(directory, environment):
    from thumble_receiver.cloud_pairing import CallbackBroker, ISSUER, REDIRECT, random_text
    broker = CallbackBroker(directory)
    await broker.start()
    state = random_text()
    task = asyncio.create_task(broker.authorize('https://thumble.io/not-opened-in-ci', state, lambda _: True))
    url = REDIRECT + '?' + urlencode(dict(state=state, iss=ISSUER, code='isolated-ci-code'))
    try:
        await asyncio.sleep(0.05)
        if sys.platform == 'win32':
            await asyncio.to_thread(os.startfile, url)
        else:
            await asyncio.to_thread(subprocess.run, ['gio', 'open', url], env=environment, check=True, timeout=10)
        if await asyncio.wait_for(task, 10) != url:
            raise RuntimeError('Installed custom URI handler did not reach the running receiver')
    finally:
        task.cancel()
        await broker.close()


def main():
    release = ROOT / 'dist/desktop-releases'
    report = ROOT / 'build/desktop/gui-installed.png'
    environment = {**os.environ, 'QT_QPA_PLATFORM': 'offscreen'}
    with tempfile.TemporaryDirectory(prefix='thumble install ') as temporary:
        folder = Path(temporary)
        if sys.platform == 'win32':
            setup = next(release.glob('*-setup.exe'))
            target = folder / 'Thumble Receiver'
            run(setup, '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/DIR=' + str(target))
            binary = target / 'thumble-receiver.exe'
            try:
                run(binary, '--self-test')
                run(binary, '--gui-smoke', str(report), env=environment)
                import winreg
                with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Classes\thumble-receiver\shell\open\command') as key:
                    command = winreg.QueryValueEx(key, '')[0]
                    if str(binary) not in command or '--oauth-callback "%1"' not in command:
                        raise RuntimeError('Installed OAuth protocol handler does not target this receiver')
                from thumble_receiver.__main__ import data_directory
                asyncio.run(verify_callback(data_directory(), environment))
                run(binary, '--native-self-test')
            finally:
                run(target / 'unins000.exe', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
        else:
            with tarfile.open(next(release.glob('*.tar.gz'))) as archive:
                archive.extractall(folder, filter='data')
            binary = folder / 'thumble-receiver/thumble-receiver'
            environment.update(XDG_DATA_HOME=str(folder / 'user-data'), XDG_CONFIG_HOME=str(folder / 'user-config'),
                               XDG_STATE_HOME=str(folder / 'user-state'))
            run(binary, '--install-user', env=environment)
            installed = folder / 'user-data/thumble/receiver/0.1.0/thumble-receiver'
            run(installed, '--self-test', env=environment)
            run(installed, '--gui-smoke', str(report), env=environment)
            entry = folder / 'user-data/applications/io.thumble.receiver.desktop'
            if not entry.exists() or str(installed) not in entry.read_text():
                raise RuntimeError('Installed desktop/protocol entry is missing')
            asyncio.run(verify_callback(folder / 'user-state/thumble', environment))
            run(installed, '--uninstall-user', env=environment)
            if installed.exists() or entry.exists():
                raise RuntimeError('Per-user uninstallation left installed application files')
    if not report.is_file() or report.read_bytes()[:8] != b'\x89PNG\r\n\x1a\n':
        raise RuntimeError('Installed GUI did not produce its screenshot')
    print('PASS: platform installation, installed TLS/profile runtime, protocol registration, GUI rendering, cleanup')


if __name__ == '__main__':
    main()
