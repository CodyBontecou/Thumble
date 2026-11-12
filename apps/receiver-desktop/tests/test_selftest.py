import contextlib
import io
import time
import unittest
from unittest.mock import patch
from thumble_receiver.access import Access
from thumble_receiver.selftest import selftest

class SmokeRecoveryTests(unittest.IsolatedAsyncioTestCase):
    async def test_slow_first_access_start_recovers_only_with_fresh_neutral(self):
        original=Access.start
        delayed=[]
        def slow_first(access):
            if not delayed:
                delayed.append(True)
                time.sleep(.35)  # Longer than the unchanged 300 ms input deadline.
            return original(access)
        printed=io.StringIO()
        with patch.object(Access,'start',slow_first), contextlib.redirect_stdout(printed):
            await selftest()
        self.assertTrue(delayed)
        self.assertIn('plan grant', printed.getvalue())
