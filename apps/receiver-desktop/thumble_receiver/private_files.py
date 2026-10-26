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
        command = Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/icacls.exe'
        subprocess.run([str(command), str(path), '/inheritance:r', '/grant:r',
                        '*' + windows_sid() + ':(F)', '*S-1-5-18:(F)'],
                       capture_output=True, timeout=5, check=True, creationflags=0x08000000)
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
