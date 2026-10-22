"""Temporary cold-simulator HTTP diagnostic; no product code or credentials.

Compares Foundation shared and ephemeral clients over three process launches.
It does not replace the native TLS, enrollment or bundled-app acceptance tests.
"""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    requests = []
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/health":
                self.send_error(404)
                return
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
    try:
        with tempfile.TemporaryDirectory(prefix="thumble-loopback-") as temporary:
            folder = Path(temporary)
            app = folder / "LoopbackProbe.app"
            app.mkdir()
            metadata = {"CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "LoopbackProbe", "CFBundleName": "LoopbackProbe", "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0", "MinimumOSVersion": "17.0", "LSRequiresIPhoneOS": True, "UIDeviceFamily": [1], "UILaunchScreen": {}, "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True}}
            (app / "Info.plist").write_bytes(plistlib.dumps(metadata))
            sdk = command("xcrun", "--sdk", "iphonesimulator", "--show-sdk-path")
            subprocess.run(["xcrun", "--sdk", "iphonesimulator", "swiftc", "-swift-version", "6", "-parse-as-library", "-sdk", sdk, "-target", "arm64-apple-ios17.0-simulator", str(ROOT / "ios-loopback/Probe.swift"), "-o", str(app / "LoopbackProbe")], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, stdout=subprocess.DEVNULL)
            available = json.loads(command("xcrun", "simctl", "list", "runtimes", "available", "-j"))["runtimes"]
            runtime = max((r for r in available if r.get("isAvailable") and ".iOS-" in r["identifier"]), key=lambda r: tuple(map(int, r["version"].split("."))))
            device = command("xcrun", "simctl", "create", "Thumble Loopback Probe", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime["identifier"])
            subprocess.run(["xcrun", "simctl", "boot", device], check=True)
            subprocess.run(["xcrun", "simctl", "bootstatus", device, "-b"], check=True, stdout=subprocess.DEVNULL)
            subprocess.run(["xcrun", "simctl", "install", device, str(app)], check=True)
            container = Path(command("xcrun", "simctl", "get_app_container", device, BUNDLE, "data"))
            result_file = container / "Documents/result.json"
            launches = []
            for launch in range(3):
                result_file.unlink(missing_ok=True)
                subprocess.run(["xcrun", "simctl", "launch", "--terminate-running-process", device, BUNDLE, str(server.server_port)], check=True, stdout=subprocess.DEVNULL)
                deadline = time.monotonic() + 20
                while not result_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.1)
                if not result_file.is_file() or result_file.stat().st_size > 1024:
                    raise RuntimeError("loopback_result_missing")
                launches.append({"launch": launch + 1, "clients": validate_results(json.loads(result_file.read_text()))})
            report = {"version": 1, "runtime": runtime["version"], "scope": "synthetic-loopback-only", "httpRequests": len(requests), "serverThreadAlive": server_thread.is_alive(), "launches": launches}
            args.report.parent.mkdir(parents=True, exist_ok=True)
            args.report.write_text(json.dumps(report, indent=2) + "\n")
            print(json.dumps(report), flush=True)
            assert len(requests) == 6 and all(row["ok"] for run in launches for row in run["clients"]), "loopback_client_failed"
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2)
        if device is not None:
            subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["xcrun", "simctl", "delete", device], check=True)


if __name__ == "__main__":
    main()
