"""Per-user protocol registration, Linux installation, and optional auto-start."""
import os
from pathlib import Path
import shutil
import subprocess
import sys


def launch_command():
    return [sys.executable] if getattr(sys, 'frozen', False) else [sys.executable, '-m', 'thumble_receiver']


def desktop_exec(arguments):
    # Freedesktop Exec quoted-argument rules, not shell quoting.
    def quote(value):
        if any(character in value for character in ('\n', '\r', '\0')):
            raise ValueError('Invalid desktop-entry path')
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('`', '\\`').replace('$', '\\$').replace('%', '%%') + '"'
    return ' '.join(quote(str(argument)) for argument in arguments)


def data_home():
    return Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))


def desktop_entry(command, icon=None, background=False):
    return ('[Desktop Entry]\nType=Application\nName=Thumble Receiver\nComment=Use your phone as a gamepad\n'
            + 'Exec=' + desktop_exec(command + (['--background'] if background else [])) + ('' if background else ' %u')
            + '\nTerminal=false\nCategories=Game;Utility;\nMimeType=x-scheme-handler/thumble-receiver;\n'
            + ('Icon=' + str(icon) + '\n' if icon else ''))


def register_protocol(command=None):
    command = command or launch_command()
    if sys.platform == 'win32':
        import winreg
        root = r'Software\Classes\thumble-receiver'
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, root) as key:
            winreg.SetValueEx(key, '', 0, winreg.REG_SZ, 'URL:Thumble Receiver')
            winreg.SetValueEx(key, 'URL Protocol', 0, winreg.REG_SZ, '')
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, root + r'\shell\open\command') as key:
            # Quote the custom URI independently; no shell is used by the handler.
            value = subprocess.list2cmdline(command) + ' --oauth-callback "%1"'
            winreg.SetValueEx(key, '', 0, winreg.REG_SZ, value)
    elif sys.platform == 'linux':
        folder = data_home() / 'applications'
        folder.mkdir(parents=True, exist_ok=True)
        entry = folder / 'io.thumble.receiver.desktop'
        icon = Path(command[0]).parent / 'Icon.png'
        entry.write_text(desktop_entry(command, icon if icon.exists() else None), encoding='utf-8')
        tool = shutil.which('xdg-mime')
        if not tool:
            raise RuntimeError('Install xdg-utils to register browser sign-in callbacks')
        subprocess.run([tool, 'default', entry.name, 'x-scheme-handler/thumble-receiver'], check=True, timeout=10)
    else:
        raise RuntimeError('Use the signed Mac receiver for macOS protocol registration')


def install_user():
    if sys.platform != 'linux' or not getattr(sys, 'frozen', False):
        raise RuntimeError('Use the packaged Linux receiver with --install-user, or the Windows setup executable')
    source = Path(sys.executable).resolve().parent
    target = data_home() / 'thumble/receiver/0.1.1'
    if source != target:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(source, target, dirs_exist_ok=True)
    register_protocol([str(target / 'thumble-receiver')])
    startup = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'autostart/io.thumble.receiver.desktop'
    if startup.exists() and str(target.parent) in startup.read_text(encoding='utf-8'):
        startup.write_text(desktop_entry([str(target / 'thumble-receiver')], background=True), encoding='utf-8')
    binaries = Path.home() / '.local/bin'
    binaries.mkdir(parents=True, exist_ok=True)
    link = binaries / 'thumble-receiver'
    if link.is_symlink() and link.resolve().is_relative_to(target.parent):
        link.unlink()
    if not link.exists():
        link.symlink_to(target / 'thumble-receiver')
    print('Installed Thumble Receiver for this user. Open it from your applications menu.')


def uninstall_user():
    if sys.platform != 'linux' or not getattr(sys, 'frozen', False):
        raise RuntimeError('Use the installed Linux receiver with --uninstall-user, or Windows Apps settings')
    source = Path(sys.executable).resolve().parent
    root = data_home() / 'thumble/receiver'
    if not source.is_relative_to(root) or source == root:
        raise RuntimeError('This executable is not in the per-user Thumble installation directory')
    entry = data_home() / 'applications/io.thumble.receiver.desktop'
    if entry.exists() and str(source) in entry.read_text(encoding='utf-8'):
        entry.unlink()
    link = Path.home() / '.local/bin/thumble-receiver'
    if link.is_symlink() and link.resolve().is_relative_to(root):
        link.unlink()
    startup = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'autostart/io.thumble.receiver.desktop'
    if startup.exists() and str(root) in startup.read_text(encoding='utf-8'):
        startup.unlink()
    shutil.rmtree(source)
    print('Removed the application. Your demo, Pro grant, and profiles have been retained.')


def autostart_enabled():
    if sys.platform == 'win32':
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Run') as key:
                return bool(winreg.QueryValueEx(key, 'ThumbleReceiver')[0])
        except OSError:
            return False
    return (Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'autostart/io.thumble.receiver.desktop').exists()


def set_autostart(enabled):
    if sys.platform == 'win32':
        import winreg
        with winreg.CreateKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Run') as key:
            if enabled:
                winreg.SetValueEx(key, 'ThumbleReceiver', 0, winreg.REG_SZ, subprocess.list2cmdline(launch_command() + ['--background']))
            else:
                try:
                    winreg.DeleteValue(key, 'ThumbleReceiver')
                except FileNotFoundError:
                    pass
    elif sys.platform == 'linux':
        path = Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'autostart/io.thumble.receiver.desktop'
        if enabled:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(desktop_entry(launch_command(), background=True), encoding='utf-8')
        else:
            path.unlink(missing_ok=True)
    else:
        raise RuntimeError('Auto-start is supported by the Windows/Linux receiver')
