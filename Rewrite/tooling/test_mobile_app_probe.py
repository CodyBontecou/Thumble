"""Diagnostic side-channel regression checks: arbitrary data must not reach logs."""
import contextlib
import io
import unittest
from run_mobile_app_probe import Probe, decode_checkpoint


class CheckpointTests(unittest.TestCase):
    def value(self):
        return {"phase": "holding", "connectionPhase": "connected", "anchorKeyWindow": True, "generation": "1", "elapsedMs": 35000,
                "maximumPublicationGapMs": 25, "connected": True, "held": True, "releaseReason": "profileReplacement",
                "publications": 2000, "appState": 0, "idleDisabled": True}

    def test_accepts_only_bounded_native_state(self):
        source = self.value()
        result = decode_checkpoint(source)
        source["connected"] = False
        self.assertTrue(result["connected"])
        for field, value in [("secret", "must-not-be-logged"), ("phase", "arbitrary"),
                             ("generation", "999"), ("connectionPhase", "private-phase"), ("anchorKeyWindow", 1), ("releaseReason", "private"),
                             ("elapsedMs", 180001), ("maximumPublicationGapMs", 180001), ("publications", -1), ("appState", 3),
                             ("connected", 1), ("elapsedMs", True), ("elapsedMs", 1.5)]:
            with self.subTest(field=field, value=value):
                with self.assertRaisesRegex(ValueError, "app_checkpoint_invalid"):
                    decode_checkpoint({**self.value(), field: value})

    def test_invalid_checkpoint_cannot_be_logged_and_memory_is_bounded(self):
        probe = Probe()
        probe.process = object()  # Only synthetic ownership admission is needed here.
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            with self.assertRaises(ValueError):
                probe.checkpoint({**self.value(), "secret": "must-not-be-logged"})
            for _ in range(64):
                self.assertEqual(probe.checkpoint(self.value()), {"ok": True})
            with self.assertRaisesRegex(ValueError, "app_checkpoint_unavailable"):
                probe.checkpoint(self.value())
        self.assertNotIn("must-not-be-logged", output.getvalue())
        self.assertEqual(len(probe.checkpoints), 64)
        self.assertEqual(len(output.getvalue().splitlines()), 64)


if __name__ == "__main__":
    unittest.main()
