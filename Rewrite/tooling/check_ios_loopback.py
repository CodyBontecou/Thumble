"""Temporary cold-simulator HTTP diagnostic; no product code or credentials.

Compares Foundation shared and ephemeral clients over three process launches.
It does not replace the native TLS, enrollment or bundled-app acceptance tests.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent
BUNDLE = "com.codybontecou.thumble.rewrite.loopback-probe"


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def validate_results(value):
    if type(value) is not list or len(value) != 2:
        raise ValueError("loopback_result_invalid")
    for row, name in zip(value, ("shared", "ephemeral")):
        if type(row) is not dict or set(row) != {"client", "ok", "errorCode"}:
            raise ValueError("loopback_result_invalid")
        if row["client"] != name or type(row["ok"]) is not bool or type(row["errorCode"]) is not int or not -100000 <= row["errorCode"] <= 100000:
            raise ValueError("loopback_result_invalid")
    return value


class LoopbackProgress:
    """Persist only fixed phase labels and bounded synthetic state, including failures."""
    PHASES = frozenset({"preparing", "compiling", "signing", "finding-runtime", "creating-device", "booting", "installing", "launching", "waiting-client", "complete"})

    def __init__(self, path):
        self.path = path
        self.started = self.phase_started = time.monotonic()
        self.phase = "preparing"
        self.durations = {}
        self.runtime = None
        self.launch_index = 0
        self.launches = []
        self.failed = False

    def set_phase(self, phase):
        if phase not in self.PHASES:
            raise ValueError("loopback_phase_invalid")
        now = time.monotonic()
        self.durations[self.phase] = min(600000, self.durations.get(self.phase, 0) + max(0, int((now - self.phase_started) * 1000)))
        self.phase, self.phase_started = phase, now

    def write(self, requests, server_alive):
        if self.phase not in self.PHASES or type(self.failed) is not bool or not set(self.durations) <= self.PHASES:
            raise ValueError("loopback_progress_invalid")
        if any(type(value) is not int or not 0 <= value <= 600000 for value in self.durations.values()):
            raise ValueError("loopback_progress_invalid")
        if type(requests) is not int or not 0 <= requests <= 7 or type(server_alive) is not bool:
            raise ValueError("loopback_progress_invalid")
        if self.runtime is not None and (type(self.runtime) is not str or re.fullmatch(r"[0-9]{1,3}(?:\.[0-9]{1,3}){0,2}", self.runtime) is None):
            raise ValueError("loopback_progress_invalid")
        if type(self.launch_index) is not int or not 0 <= self.launch_index <= 3 or len(self.launches) > 3:
            raise ValueError("loopback_progress_invalid")
        for index, launch in enumerate(self.launches):
            if set(launch) != {"launch", "clients"} or launch["launch"] != index + 1:
                raise ValueError("loopback_progress_invalid")
            validate_results(launch["clients"])
        durations = dict(self.durations)
        durations[self.phase] = min(600000, durations.get(self.phase, 0) + max(0, int((time.monotonic() - self.phase_started) * 1000)))
        report = {"version": 1, "scope": "synthetic-loopback-only", "phase": self.phase, "completed": self.phase == "complete", "failed": self.failed, "elapsedMs": min(600000, max(0, int((time.monotonic() - self.started) * 1000))), "phaseDurationsMs": durations, "runtime": self.runtime, "launchIndex": self.launch_index, "httpRequests": requests, "serverThreadAlive": server_alive, "launches": self.launches}
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n")
        temporary.replace(self.path)
        print("[DEBUG-ios-loopback] " + json.dumps(report), flush=True)
        return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    requests = []
    progress = LoopbackProgress(args.report)
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/health":
                self.send_error(404)
                return
            if len(requests) < 7:
                requests.append(True)
            body = b'{"ok":true}'
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def log_message(self, *_):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    device = None
    def phase(name):
        progress.set_phase(name)
        progress.write(len(requests), server_thread.is_alive())
    progress.write(0, server_thread.is_alive())
    try:
        with tempfile.TemporaryDirectory(prefix="thumble-loopback-") as temporary:
            folder = Path(temporary)
            app = folder / "LoopbackProbe.app"
            app.mkdir()
            metadata = {"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "LoopbackProbe", "CFBundleName": "LoopbackProbe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0", "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1], "UILaunchScreen": {}, "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
            (app / "Info.plist").write_bytes(plistlib.dumps(metadata))
            phase("compiling")
            sdk = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
            subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "6", "-parse-as-library", "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator", str(ROOT / "ios-loopback/Probe.swift"), "-o", str(app / "LoopbackProbe")], check=True)
            phase("signing")
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, stdout=subprocess.DEVNULL)
            phase("finding-runtime")
            available = json.loads(command("xcrun", "simctl", "list", "runtimes", "available", "-j"))["runtimes"]
            runtime = max((r for r in available if r.get("isAvailable") and ".iOS-" in r["identifier"]), key=lambda r: tuple(map(int, r["version"].split("."))))
            progress.runtime = runtime["version"]
            phase("creating-device")
            device = command("xcrun", "simctl", "create", "Thumble Loopback Probe", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime["identifier"])
            phase("booting")
            subprocess.run(["xcrun", "simctl", "boot", device], check=True)
            subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True, stdout=subprocess.DEVNULL)
            phase("installing")
            subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True)
            container = Path(command("xcrun", "simctl", "get_app_container", device, BUNDLE, "data"))
            result_file = container / "Documents/result.json"
            for launch in range(3):
                progress.launch_index = launch + 1
                phase("launching")
                result_file.unlink(missing_ok=True)
                subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE, str(server.server_port)], check=True, stdout=subprocess.DEVNULL)
                phase("waiting-client")
                deadline = time.monotonic() + 20
                while not result_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.1)
                if not result_file.is_file() or result_file.stat().st_size > 1024:
                    raise RuntimeError("loopback_result_missing")
                progress.launches.append({"launch": launch + 1, "clients": validate_results(json.loads(result_file.read_text()))})
                progress.write(len(requests), server_thread.is_alive())
            assert len(requests) == 6 and all(row["ok"] for run in progress.launches for row in run["clients"]), "loopback_client_failed"
            phase("complete")
    except Exception:
        progress.failed = True
        progress.write(len(requests), server_thread.is_alive())
        raise
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2)
        if device is not None:
            subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["xcrun", "simctl", "delete", device], check=True)


if __name__ == "__main__":
    main()
