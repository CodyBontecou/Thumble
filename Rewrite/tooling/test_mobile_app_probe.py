"""Diagnostic side-channel regression checks: arbitrary data must not reach logs."""
import contextlib
import io
import http.client
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
import unittest
from run_mobile_app_probe import Probe, decode_checkpoint
import run_mobile_app_probe


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

    def test_enrollment_phase_is_an_allowlisted_label_without_error_or_peer_data(self):
        for phase in ("idle", "connecting", "negotiating", "credential", "storing", "acknowledging", "confirming", "complete"):
            self.assertEqual(decode_checkpoint({**self.value(), "connectionPhase": "enrollment-" + phase})["connectionPhase"], "enrollment-" + phase)
        for phase in ("enrollment-private-error", "enrollment-storing-token", "enrollment-", "enrollment-complete\n"):
            with self.assertRaisesRegex(ValueError, "app_checkpoint_invalid"):
                decode_checkpoint({**self.value(), "connectionPhase": phase})

    def test_tls_connect_outcome_is_optional_bounded_metadata_without_peer_errors(self):
        for outcome in ("idle", "connecting", "deadline", "network-failed", "cancelled", "tls-version-rejected", "alpn-rejected", "ready"):
            self.assertEqual(decode_checkpoint({**self.value(), "tlsConnectOutcome": outcome})["tlsConnectOutcome"], outcome)
        for value in (True, 1, None, "network-failed:private-error", "ready\n"):
            with self.assertRaisesRegex(ValueError, "app_checkpoint_invalid"):
                decode_checkpoint({**self.value(), "tlsConnectOutcome": value})

    def test_runtime_outcomes_are_optional_fixed_labels(self):
        for key, values in (("controlFailureStage", ("none", "checkpoint", "progress", "renewal", "status", "offering")),
                            ("tlsRuntimeOutcome", ("idle", "ready", "closed", "cancelled", "read-deadline", "write-deadline", "read-failed", "write-failed", "invalid-frame", "queue-overflow", "network-failed"))):
            for value in values:
                self.assertEqual(decode_checkpoint({**self.value(), key: value})[key], value)
            for value in (True, 1, None, "private-error", "ready\n"):
                with self.assertRaisesRegex(ValueError, "app_checkpoint_invalid"):
                    decode_checkpoint({**self.value(), key: value})
        combined = {**self.value(), "tlsConnectOutcome": "ready", "controlFailureStage": "progress", "tlsRuntimeOutcome": "read-deadline"}
        self.assertEqual(decode_checkpoint(combined), combined)
        with self.assertRaisesRegex(ValueError, "app_checkpoint_invalid"):
            decode_checkpoint({**combined, "error": "private"})

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


class HttpLivenessTests(unittest.TestCase):
    def test_health_route_does_not_start_native_input_or_take_its_lock(self):
        probe = Probe()
        with probe.lock:
            for _ in range(130):
                self.assertEqual(probe.request("/health"), {"ok": True})
        self.assertIsNone(probe.process)
        self.assertEqual(probe.health_requests, 128)
        self.assertEqual(probe.begin_requests, 0)

    def test_failed_app_command_preserves_host_liveness_without_reflecting_unknown_paths(self):
        with tempfile.TemporaryDirectory(prefix="thumble-http-witness-") as temporary:
            root = Path(temporary)
            (root / "apps/mobile/tests/ios").mkdir(parents=True)
            output = io.StringIO()
            def run_command(_):
                port = json.loads((root / "apps/mobile/tests/ios/AppProbeConfig.json").read_text())["port"]
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
                try:
                    connection.request("GET", "/unknown?credential=must-not-be-recorded")
                    response = connection.getresponse()
                    self.assertEqual(response.status, 500)
                    self.assertEqual(response.read(), b'{"error":"app_probe_failed"}')
                finally:
                    connection.close()
                return 1
            with patch("sys.argv", ["run_mobile_app_probe.py", "--platform", "ios", "--", "synthetic-command"]), \
                 patch.object(run_mobile_app_probe, "ROOT", root), \
                 patch.object(run_mobile_app_probe.subprocess, "call", side_effect=run_command), \
                 contextlib.redirect_stdout(output):
                with self.assertRaisesRegex(AssertionError, "app_test_command_failed"):
                    run_mobile_app_probe.main()
            self.assertNotIn("must-not-be-recorded", output.getvalue())
            final = json.loads(output.getvalue().split("[DEBUG-renewal-app] final ", 1)[1])
            self.assertEqual(final["httpDiagnostics"]["beginRequests"], 0)
            self.assertEqual(final["httpDiagnostics"]["healthRequests"], 1)
            self.assertTrue(final["httpDiagnostics"]["serverThreadAlive"])
            self.assertEqual(final["httpDiagnostics"]["healthMonitor"], {"attempts": 1, "passed": 1, "failed": 0})
            self.assertIsNone(final["nativeExitBeforeCleanup"])


if __name__ == "__main__":
    unittest.main()


class SavedAppModeTests(unittest.TestCase):
    def test_corner_requires_exact_saved_witness_counts_and_preserves_default_counts(self):
        probe = Probe("corner")
        probe.process = type("Process", (), {"wait": lambda self, timeout: 0})()
        replies = {"c": {"freshNeutral": True, "firstSampleNeutral": True}, "q": {"watching": True, "inputTtlMs": 350}, "j": {"catalogHeld": True, "durationMs": 1500, "neutralPulses": 0, "inputTtlMs": 350, "inputEnabled": False}, "h": {"held": True, "inputEnabled": False}, "n": {"neutral": True, "reason": "native_input_released", "inputEnabled": False}, "f": {"completed": True, "inputEnabled": False}}
        probe.command = lambda command: replies[command]
        for path in ("/fresh", "/saved-start", "/saved-held", "/held", "/neutral", "/finish"):
            self.assertEqual(probe.request(path), {"ok": True})
        self.assertTrue(probe.completed)
        original = Probe()
        with self.assertRaisesRegex(AssertionError, "mode_invalid"):
            original.request("/saved-start")
        self.assertEqual(original.counts, {"held": 0, "fresh": 0, "neutral": 0, "renewalStarts": 0, "renewalVerified": 0})

    def test_unsupported_mode_cannot_finish_after_input_witness_or_skip_corner_hold(self):
        for mode in ("unsupported", "corner"):
            probe = Probe(mode)
            probe.process = type("Process", (), {"wait": lambda self, timeout: 0})()
            probe.command = lambda command: {"completed": True, "inputEnabled": False}
            if mode == "unsupported": probe.counts["held"] = 1
            with self.assertRaisesRegex(AssertionError, "missing native app receiver witnesses"):
                probe.request("/finish")
        with self.assertRaisesRegex(AssertionError, "mode_invalid"):
            Probe("private-arbitrary-mode")


class SavedAppWatchdogTests(unittest.TestCase):
    def test_saved_runner_launch_timeout_is_bounded_without_relaxing_test_result(self):
        with tempfile.TemporaryDirectory(prefix="thumble-saved-command-") as directory:
            root = Path(directory)
            (root / "apps/mobile/tests/ios").mkdir(parents=True)
            with contextlib.redirect_stdout(io.StringIO()), patch.object(run_mobile_app_probe, "ROOT", root), patch.object(run_mobile_app_probe.sys, "argv", ["probe", "--platform", "ios", "--saved-controller", "corner", "--", "synthetic-app"]), patch.object(run_mobile_app_probe.subprocess, "call", side_effect=run_mobile_app_probe.subprocess.TimeoutExpired("synthetic-app", 300)) as command:
                with self.assertRaisesRegex(AssertionError, "app_saved_command_timeout"):
                    run_mobile_app_probe.main()
                command.assert_called_once_with(["synthetic-app"], timeout=300)
