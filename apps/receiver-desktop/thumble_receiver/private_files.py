"""Owner-only ephemeral capability files, including an explicit Windows DACL."""
import csv
from functools import lru_cache
import io
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


@lru_cache(maxsize=1)
def windows_sid():
    command = Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/whoami.exe'
    result = subprocess.run([str(command), '/user', '/fo', 'csv', '/nh'], capture_output=True,
                            timeout=5, check=True, creationflags=0x08000000)
    # The SID is ASCII even if the account name is printed in an OEM code page.
    rows = list(csv.reader(io.StringIO(result.stdout.decode('ascii', errors='ignore').strip())))
    if len(rows) != 1 or len(rows[0]) != 2 or not re.fullmatch(r'S-1-[0-9-]+', rows[0][1]):
        raise OSError('Could not identify the Windows account for private pairing files')
    return rows[0][1]


def protect(path):
    if os.name == 'nt':
        import ctypes
        from ctypes import wintypes
        security = ctypes.WinDLL('advapi32', use_last_error=True)
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        security.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = (
            wintypes.LPCWSTR, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p), ctypes.c_void_p)
        security.SetFileSecurityW.argtypes = (wintypes.LPCWSTR, wintypes.DWORD, ctypes.c_void_p)
        kernel.LocalFree.argtypes = (ctypes.c_void_p,)
        kernel.LocalFree.restype = ctypes.c_void_p
        descriptor = ctypes.c_void_p()
        # Replace the entire DACL: /grant:r only replaces entries for the named
        # trustees and can leave existing explicit grants on temporary files.
        sddl = f'D:P(A;;FA;;;{windows_sid()})(A;;FA;;;SY)'
        if not security.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, 1, ctypes.byref(descriptor), None):
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            if not security.SetFileSecurityW(str(path), 0x80000004, descriptor):
                raise ctypes.WinError(ctypes.get_last_error())
        finally:
            kernel.LocalFree(descriptor)
    else:
        os.chmod(path, 0o600)


def private_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor, temporary = tempfile.mkstemp(prefix='private-', suffix='.tmp', dir=path.parent)
    try:
        os.close(descriptor)
        # Set permissions while empty, before writing any temporary credential.
        protect(temporary)
        with open(temporary, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, allow_nan=False, separators=(',', ':'))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)
