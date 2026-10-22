"""Run bundled phone tests against an owned recording-only TLS/IPC host.

Only the QA test bundles know this side channel. Product code uses its normal
native invitation field, credential provider, pinned TLS and native touch owner.
"""
import argparse
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

class Probe:
    def __init__(self):
        self.process = None
        self.lines = queue.Queue(maxsize=32)
        self.lock = threading.Lock()
        self.completed = False
        self.failure_codes = []
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
                threading.Thread(target=read, daemon=True).start()
                def read_failures():
                    for line in iter(lambda: self.process.stderr.readline(4096), b""):
                        match = re.fullmatch(r'Error: "((?:probe|native_input)_[a-z_]{1,96})"', line.decode("utf-8", errors="replace").strip())
                        if match:
                            self.failure_codes.append(match.group(1))
                            del self.failure_codes[:-8]
                threading.Thread(target=read_failures, daemon=True).start()
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

    def close(self):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)


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
        def do_GET(self):
            try:
                value = probe.request(self.path)
                if args.platform == "android" and self.path == "/begin":
                    tls_port = value["port"]
                    subprocess.run(reverse[:4] + [f"tcp:{tls_port}", f"tcp:{tls_port}"], check=True, stdout=subprocess.DEVNULL)
                    reverse_ports.add(tls_port)
                payload = json.dumps(value, separators=(",", ":")).encode()
                self.send_response(200)
                if self.path != "/begin":
                    print("app_probe_phase_pass " + self.path, flush=True)
            except Exception as error:
                print("app_probe_phase_failed " + self.path + " " + type(error).__name__ + " probeFailure=" + (probe.failure_codes[-1] if probe.failure_codes else "none"), flush=True)
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
    threading.Thread(target=server.serve_forever, daemon=True).start()
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
        result = subprocess.call(command)
        assert result == 0, "app_test_command_failed"
        assert probe.completed, "native app pairing/reconnect witness did not finish"
        print("Verified app native pairing/reconnect against recording-only receiver: " + json.dumps(probe.counts), flush=True)
    finally:
        probe.close()
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
