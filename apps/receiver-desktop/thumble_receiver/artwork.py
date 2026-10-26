"""Bounded, best-effort icon-name lookup against the Mac receiver's endpoint."""
import time

from .http import request_json
from .profiles import matches
from .state import integer


class IconLookup:
    def __init__(self, request=request_json, clock=time.monotonic):
        self.request, self.clock, self.cache = request, clock, {}
        self.deadline, self.attempts = 0, 0

    def begin(self):
        self.deadline, self.attempts = self.clock() + 2, 0

    def __call__(self, kind, identifier):
        if kind not in ('spell', 'item') or not integer(identifier, 1, 2147483647):
            return None
        if kind == 'spell' and identifier == 6603:
            return 'ability_meleedamage'
        key = kind, identifier
        cached = self.cache.get(key)
        if cached and (cached[0] is not None or self.clock() - cached[1] < 300):
            return cached[0]
        if self.clock() >= self.deadline or self.attempts >= 6:
            return None
        self.attempts += 1
        value = None
        try:
            data = self.request(f'https://nether.wowhead.com/classic/tooltip/{kind}/{identifier}',
                                timeout=min(0.35, max(0.01, self.deadline - self.clock())), limit=100000)
            icon = data.get('icon')
            if isinstance(icon, str) and matches(icon.lower(), r'[a-z0-9_]{1,128}'):
                value = icon.lower()
        except Exception:
            pass
        if len(self.cache) >= 2048:
            self.cache.pop(next(iter(self.cache)))
        self.cache[key] = value, self.clock()
        return value
