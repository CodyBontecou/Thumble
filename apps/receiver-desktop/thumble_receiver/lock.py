"""One process per receiver data directory (receiver record, plan grant and pairing), on both supported operating systems."""
import os
from pathlib import Path


class DirectoryLock:
    def __init__(self, directory):
        Path(directory).mkdir(parents=True, exist_ok=True, mode=0o700)
        self.stream = open(Path(directory) / 'receiver.lock', 'a+b')
        try:
            if os.name == 'nt':
                import msvcrt
                self.stream.seek(0, 2)
                if self.stream.tell() == 0:
                    self.stream.write(b'\0')
                    self.stream.flush()
                self.stream.seek(0)
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self.stream.close()
            raise RuntimeError('Another receiver is already using this data directory') from error

    def close(self):
        self.stream.close()
