"""Durable receiver trust, protected by a user-only Windows DACL or POSIX mode."""
import json
from pathlib import Path
import re
import secrets
import uuid

from .private_files import private_json, protect


class PairingStore:
    def __init__(self, directory):
        self.path = Path(directory) / 'pairing-identity.json'
        self.value = dict(v=1, port=0, phone=None, tls=None)
        if self.path.is_symlink():
            raise ValueError('Receiver identity must not be a symbolic link')
        if self.path.exists():
            protect(self.path)
            try:
                value = json.loads(self.path.read_text(encoding='utf-8'))
                if (value['v'] != 1 or type(value['port']) is not int
                        or not 0 <= value['port'] <= 65535
                        or not (value['tls'] is None or isinstance(value['tls'], dict))):
                    raise ValueError()
                if value['phone'] is not None:
                    uuid.UUID(value['phone']['id'])
                    if not re.fullmatch(r'[0-9a-f]{64}', value['phone']['token']):
                        raise ValueError()
                self.value = value
            except (ValueError, TypeError, KeyError, AttributeError) as error:
                raise ValueError('Saved receiver identity is invalid; refusing to replace it') from error

    def update(self, **changes):
        value = {**self.value, **changes}
        private_json(self.path, value)
        self.value = value

    def remember(self, phone):
        token = secrets.token_hex(32)
        self.update(phone=dict(id=phone, token=token))
        return token

    def accepts(self, phone, token):
        remembered = self.value['phone']
        return bool(remembered and remembered['id'] == phone and isinstance(token, str)
                    and token.isascii() and secrets.compare_digest(remembered['token'], token))

    def forget(self):
        self.update(phone=None)
