"""Run bundled phone tests against an owned recording-only TLS/IPC host.

Only the QA test bundles know this side channel. Product code uses its normal
native invitation field, credential provider, pinned TLS and native touch owner.
"""
import argparse
import http.client
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parent.parent

CHECKPOINT_FIELDS = {"phase", "connectionPhase", "anchorKeyWindow", "generation", "elapsedMs", "maximumPublicationGapMs", "connected", "held", "releaseReason", "publications", "appState", "idleDisabled"}
CHECKPOINT_REASONS = {"none", "touchCancelled", "background", "screenLock", "rotation", "profileReplacement", "disconnected", "disposed", "practice", "invalidTouch", "transportFailure", "sequenceExhausted"}


def decode_checkpoint(value):
    """Only bounded, synthetic test state may enter diagnostic artifacts."""
    if type(value) is not dict or not CHECKPOINT_FIELDS <= set(value) or set(value) - CHECKPOINT_FIELDS - {"tlsConnectOutcome", "controlFailureStage", "tlsRuntimeOutcome"}:
        raise ValueError("app_checkpoint_invalid")
    if type(value["phase"]) is not str or value["phase"] not in {"connected", "holding", "ended", "admission-failed"}:
        raise ValueError("app_checkpoint_invalid")
    if type(value["connectionPhase"]) is not str or value["connectionPhase"] not in {"idle", "pair-requested", "enrolling", "enrollment-idle", "enrollment-connecting", "enrollment-negotiating", "enrollment-credential", "enrollment-storing", "enrollment-acknowledging", "enrollment-confirming", "enrollment-complete", "endpoint-saved", "control-requested", "authenticating", "configuration", "input", "installing", "connected"}:
        raise ValueError("app_checkpoint_invalid")
    if type(value["generation"]) is not str or value["generation"] not in {"1", "2"}:
        raise ValueError("app_checkpoint_invalid")
    if type(value["releaseReason"]) is not str or value["releaseReason"] not in CHECKPOINT_REASONS:
        raise ValueError("app_checkpoint_invalid")
    for key in ("connected", "held", "idleDisabled", "anchorKeyWindow"):
        if type(value[key]) is not bool:
            raise ValueError("app_checkpoint_invalid")
    for key, maximum in (("elapsedMs", 180000), ("maximumPublicationGapMs", 180000), ("publications", 1000000), ("appState", 2)):
        if type(value[key]) is not int or not 0 <= value[key] <= maximum:
            raise ValueError("app_checkpoint_invalid")
    if "tlsConnectOutcome" in value and (type(value["tlsConnectOutcome"]) is not str or value["tlsConnectOutcome"] not in {"idle", "connecting", "deadline", "network-failed", "cancelled", "tls-version-rejected", "alpn-rejected", "ready"}):
        raise ValueError("app_checkpoint_invalid")
    for key, allowed in (("controlFailureStage", {"none", "checkpoint", "progress", "renewal", "status", "offering"}),
                         ("tlsRuntimeOutcome", {"idle", "ready", "closed", "cancelled", "read-deadline", "write-deadline", "read-failed", "write-failed", "invalid-frame", "queue-overflow", "network-failed"})):
        if key in value and (type(value[key]) is not str or value[key] not in allowed):
            raise ValueError("app_checkpoint_invalid")
    return {key: value[key] for key in sorted(value)}


GET_PHASES = frozenset({"/health", "/begin", "/held", "/renewal-start", "/renewal-verified", "/fresh", "/neutral", "/next", "/finish"})


def check_probe_health(port):
    """Direct host loopback check; no proxy, invitation or native receiver involved."""
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request("GET", "/health")
        response = connection.getresponse()
        return response.status == 200 and response.read(129) == b'{"ok":true}'
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()


class Probe:
    def __init__(self):
        self.process = None
        self.begin_requests = 0
        self.health_requests = 0
        self.lines = queue.Queue(maxsize=32)
        self.lock = threading.Lock()
        self.completed = False
        self.failure_codes = []
        self.checkpoints = []
        self.readers = []
        self.counts = {"held": 0, "fresh": 0, "neutral": 0, "renewalStarts": 0, "renewalVerified": 0}

    def line(self):
        text = self.lines.get(timeout=5)
        if not text:
            raise RuntimeError("app_probe_closed")
        return json.loads(text)

    def command(self, command):
        assert self.process is not None and self.process.poll() is None, "app_probe_not_live"
        self.process.stdin.write(command.encode("ascii"))
        self.process.stdin.flush()
        return self.line()

    def request(self, path):
        if path == "/health":
            self.health_requests = min(128, self.health_requests + 1)
            return {"ok": True}
        if path == "/begin":
            self.begin_requests = min(128, self.begin_requests + 1)
        with self.lock:
            if path == "/begin":
                assert self.process is None, "app_probe_already_started"
                executable = ROOT / "native/receiver/target/debug/examples/phone_input_probe"
                assert executable.is_file(), "build native phone_input_probe before app tests"
                self.process = subprocess.Popen([str(executable), "--renewal-watch"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                def read():
                    for line in self.process.stdout:
                        self.lines.put(line)
                    self.lines.put(b"")
                reader = threading.Thread(target=read, daemon=True)
                self.readers.append(reader)
                reader.start()
                def read_failures():
                    for line in iter(lambda: self.process.stderr.readline(4096), b""):
                        match = re.fullmatch(r'Error: "((?:probe|native_input)_[a-z_]{1,96})"', line.decode("utf-8", errors="replace").strip())
                        if match:
                            self.failure_codes.append(match.group(1))
                            del self.failure_codes[:-8]
                failure_reader = threading.Thread(target=read_failures, daemon=True)
                self.readers.append(failure_reader)
                failure_reader.start()
                offer = self.line()
                assert offer.pop("scope") == "synthetic-loopback-recording-only"
                assert self.command("a")["active"] is True
                return {"host": "127.0.0.1", "port": offer["port"], "certificatePin": offer["pin"],
                        "authorityInstanceId": offer["authorityInstanceId"], "windowId": offer["windowId"],
                        "secret": offer["secret"], "expiresAt": offer["expiresAt"]}
            if path == "/held":
                result = self.command("h")
                assert result["held"] is True and result["inputEnabled"] is False
                self.counts["held"] += 1
            elif path == "/renewal-start":
                result = self.command("b")
                assert result["watching"] is True and result["inputTtlMs"] == 350
                self.counts["renewalStarts"] += 1
            elif path == "/renewal-verified":
                result = self.command("v")
                assert result["continuousHeld"] is True and result["durationMs"] >= 75000
                assert result["rotations"] >= 2 and result["neutralPulses"] == 0 and result["inputTtlMs"] == 350
                self.counts["renewalVerified"] += 1
                print("app_native_renewal_verified " + json.dumps(result), flush=True)
            elif path == "/fresh":
                result = self.command("c")
                assert result["freshNeutral"] is True and result["firstSampleNeutral"] is True
                self.counts["fresh"] += 1
            elif path == "/neutral":
                result = self.command("n")
                assert result["neutral"] is True and result["reason"] == "native_input_released" and result["inputEnabled"] is False
                self.counts["neutral"] += 1
            elif path == "/next":
                result = self.command("a")
                assert result["generation"] == "2"
            elif path == "/finish":
                result = self.command("f")
                assert result["completed"] is True and result["inputEnabled"] is False
                assert self.process.wait(timeout=5) == 0
                assert self.counts == {"held": 2, "fresh": 2, "neutral": 2, "renewalStarts": 1, "renewalVerified": 1}, "missing native app receiver witnesses"
                self.completed = True
            else:
                raise ValueError("app_probe_unknown_command")
            return {"ok": True}

    def checkpoint(self, value):
        value = decode_checkpoint(value)
        with self.lock:
            if self.process is None or self.completed or len(self.checkpoints) >= 64:
                raise ValueError("app_checkpoint_unavailable")
            self.checkpoints.append(value)
        print("[DEBUG-renewal-app] checkpoint " + json.dumps(value, sort_keys=True), flush=True)
        return {"ok": True}

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        for reader in self.readers:
            reader.join(timeout=0.2)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", choices=["ios", "android"], required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    assert command, "missing app test command"
    probe = Probe()
    reverse_ports = set()
    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            # This route belongs only to the synthetic QA app. Never reflect
            # request paths, arbitrary error descriptions, credentials or packets.
            try:
                self.connection.settimeout(2)
                raw_length = self.headers.get("Content-Length", "")
                if self.path != "/diagnostic" or not re.fullmatch(r"[1-9][0-9]{0,3}", raw_length):
                    raise ValueError("app_checkpoint_invalid")
                length = int(raw_length)
                if length > 1024:
                    raise ValueError("app_checkpoint_invalid")
                def unique(pairs):
                    result = {}
                    for key, value in pairs:
                        if key in result:
                            raise ValueError("app_checkpoint_invalid")
                        result[key] = value
                    return result
                value = probe.checkpoint(json.loads(self.rfile.read(length), object_pairs_hook=unique))
                payload = json.dumps(value).encode()
                self.send_response(200)
            except Exception:
                payload = b'{"error":"app_checkpoint_invalid"}'
                self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def do_GET(self):
            try:
                value = probe.request(self.path)
                if args.platform == "android" and self.path == "/begin":
                    tls_port = value["port"]
                    subprocess.run(reverse[:4] + [f"tcp:{tls_port}", f"tcp:{tls_port}"], check=True, stdout=subprocess.DEVNULL)
                    reverse_ports.add(tls_port)
                payload = json.dumps(value, separators=(",", ":")).encode()
                self.send_response(200)
                if self.path not in {"/begin", "/health"}:
                    print("app_probe_phase_pass " + self.path, flush=True)
            except Exception as error:
                phase = self.path if self.path in GET_PHASES else "unknown"
                print("app_probe_phase_failed " + phase + " " + type(error).__name__ + " probeFailure=" + (probe.failure_codes[-1] if probe.failure_codes else "none"), flush=True)
                payload = b'{"error":"app_probe_failed"}'
                self.send_response(500)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        def log_message(self, *_):
            pass  # Never log invitations or network payloads.
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_port
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    health_stop = threading.Event()
    health = {"attempts": 0, "passed": 0, "failed": 0}
    def monitor_health():
        while not health_stop.wait(10):
            healthy = check_probe_health(port)
            health["attempts"] = min(128, health["attempts"] + 1)
            field = "passed" if healthy else "failed"
            health[field] = min(128, health[field] + 1)
    health_thread = threading.Thread(target=monitor_health, daemon=True)
    health_thread.start()
    adb = Path(os.environ.get("ANDROID_HOME", "")) / "platform-tools/adb"
    reverse = []
    if args.platform == "android":
        assert os.environ.get("ANDROID_SERIAL"), "select the owned QA emulator explicitly"
        reverse_ports.add(port)
        reverse = [str(adb), "-s", os.environ["ANDROID_SERIAL"], "reverse", f"tcp:{port}"]
        subprocess.run(reverse + [f"tcp:{port}"], check=True, stdout=subprocess.DEVNULL)
        command.append(f"-Pandroid.testInstrumentationRunnerArguments.thumbleProbePort={port}")
    else:
        (ROOT / "apps/mobile/tests/ios/AppProbeConfig.json").write_text(json.dumps({"port": port}))
    try:
        healthy = check_probe_health(port)
        health.update({"attempts": 1, "passed": int(healthy), "failed": int(not healthy)})
        assert healthy, "app_probe_http_server_not_ready"
        result = subprocess.call(command)
        assert result == 0, "app_test_command_failed"
        assert probe.completed, "native app pairing/reconnect witness did not finish"
        print("Verified app native pairing/reconnect against recording-only receiver: " + json.dumps(probe.counts), flush=True)
    finally:
        native_exit_before_cleanup = probe.process.poll() if probe.process is not None else None
        health_stop.set()
        health_thread.join(timeout=3)
        probe.close()
        print("[DEBUG-renewal-app] final " + json.dumps({"completed": probe.completed, "counts": probe.counts, "httpDiagnostics": {"beginRequests": probe.begin_requests, "healthRequests": probe.health_requests, "serverThreadAlive": server_thread.is_alive(), "healthMonitor": health}, "nativeExitBeforeCleanup": native_exit_before_cleanup, "nativeFailureCodes": probe.failure_codes, "lastCheckpoint": probe.checkpoints[-1] if probe.checkpoints else None}, sort_keys=True), flush=True)
        server.shutdown()
        server.server_close()
        if reverse:
            primary_failure = sys.exc_info()[0] is not None
            for owned_port in reverse_ports:
                removed = subprocess.run(reverse[:4] + ["--remove", f"tcp:{owned_port}"], capture_output=True)
                if removed.returncode:
                    current = subprocess.run(reverse[:4] + ["--list"], capture_output=True, text=True)
                    absent = current.returncode == 0 and not any(
                        f"tcp:{owned_port}" in line.split() for line in current.stdout.splitlines())
                    if not absent:
                        if primary_failure:
                            print("app_probe_owned_forward_cleanup_failed", file=sys.stderr)
                        else:
                            raise RuntimeError("app_probe_owned_forward_cleanup_failed")

if __name__ == "__main__":
    main()
