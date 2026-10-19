#!/usr/bin/env python3
"""Disposable Windows acceptance session; never install this as a receiver service.

An HTTPS tunnel reaches only a loopback guard with a random 256-bit path token.
The connection descriptor is RSA-OAEP encrypted for the test operator before upload.
Only actual iOS input is used; this harness never sends protocol input or OS keys.
"""
import argparse
import asyncio
import base64
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import time
import urllib.request


def accepted(evidence):
    events = evidence.get("events", [])
    def has(kind, code, value):
        return any(e.get("kind") == kind and e.get("code") == code and e.get("value") == value for e in events)
    return ("as" in evidence.get("text", "")
            and all(has("key", code, value) for code in (65, 83) for value in (0, 1))
            and all(has("button", 1, value) for value in (0, 1))
            and len({(e["x"], e["y"]) for e in events if e["kind"] == "move"}) >= 3)


async def session(args):
    root = Path(__file__).resolve().parents[2]
    directory = Path(args.directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    evidence_dir = directory / "evidence"
    evidence_dir.mkdir(exist_ok=True)
    receiver = root / "Host/target/release/thumble-receiver.exe"
    state = directory / "receiver-state"
    command = [str(receiver), "--state-dir", str(state)]
    config = json.loads((root / "scripts/receiver-qa/linux-acceptance-configuration.json").read_text())
    config["profiles"][0]["name"] = "Windows VM Acceptance"
    configuration = directory / "configuration.json"
    configuration.write_text(json.dumps(config))
    subprocess.run(command + ["import-configuration", str(configuration)], check=True, stdout=subprocess.DEVNULL)
    token = secrets.token_hex(32)
    print(f"::add-mask::{token}", flush=True)
    processes = []
    logs = []
    finished = asyncio.Event()

    def spawn(argv, name):
        log = (directory / (name + ".log")).open("wb")
        logs.append(log)
        process = subprocess.Popen(argv, stdout=log, stderr=subprocess.STDOUT)
        processes.append(process)
        (directory / "pids.json").write_text(json.dumps([os.getpid()] + [p.pid for p in processes]))
        return process

    def control(action):
        return subprocess.check_output(command + [action], timeout=5)

    def evidence():
        try:
            return json.loads((evidence_dir / "desktop-events.json").read_text())
        except (OSError, ValueError):
            return {}

    async def proxy(reader, writer):
        upstream = None
        try:
            header = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
            line, rest = header.split(b"\r\n", 1)
            method, path, version = line.decode("ascii").split(" ")
            parts = path.split("/")
            if method != "GET" or len(parts) != 3 or not hmac.compare_digest(parts[1], token):
                writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                await writer.drain()
                return
            route = parts[2]
            payload = None
            content_type = b"application/json"
            if route == "pairing-code":
                payload = await asyncio.to_thread(control, "pairing-code")
            elif route == "status":
                payload = await asyncio.to_thread(control, "status")
            elif route == "evidence":
                payload = json.dumps(evidence()).encode()
            elif route == "screenshot":
                payload = (evidence_dir / "desktop.png").read_bytes()
                content_type = b"image/png"
            elif route == "finish":
                passed = accepted(evidence())
                payload = json.dumps({"accepted": passed}).encode()
                if passed:
                    finished.set()
            elif route == "ws" and b"upgrade: websocket" in rest.lower():
                remote_reader, upstream = await asyncio.open_connection("127.0.0.1", 18865)
                upstream.write(b"GET / HTTP/1.1\r\n" + rest)
                await upstream.drain()
                async def copy(source, target):
                    while data := await source.read(65536):
                        target.write(data)
                        await target.drain()
                tasks = [asyncio.create_task(copy(reader, upstream)), asyncio.create_task(copy(remote_reader, writer))]
                _, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in pending:
                    task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
                return
            else:
                payload = b'{}'
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: " + content_type + b"\r\nCache-Control: no-store\r\nContent-Length: " + str(len(payload)).encode() + b"\r\nConnection: close\r\n\r\n" + payload)
            await writer.drain()
        except (OSError, ValueError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            pass
        finally:
            if upstream:
                upstream.close()
            writer.close()

    try:
        spawn(command + ["run", "--port", "18865", "--no-bonjour"], "receiver")
        for _ in range(100):
            try:
                await asyncio.to_thread(control, "status")
                break
            except (OSError, subprocess.SubprocessError):
                await asyncio.sleep(.2)
        else:
            raise RuntimeError("Receiver did not start")
        binary = directory / "cloudflared.exe"
        urllib.request.urlretrieve("https://github.com/cloudflare/cloudflared/releases/download/2026.10.1/cloudflared-windows-amd64.exe", binary)
        if hashlib.sha256(binary.read_bytes()).hexdigest() != "4d2490e74082c5d48dbfedaf92576fa5bd1702379ab88eb7faa0cfbe8dc891b6":
            raise RuntimeError("Tunnel binary checksum mismatch")
        server = await asyncio.start_server(proxy, "127.0.0.1", 18867, limit=16384)
        tunnel = spawn([str(binary), "tunnel", "--protocol", "http2", "--url", "http://127.0.0.1:18867", "--no-autoupdate"], "tunnel")
        hostname = None
        for _ in range(120):
            found = re.search(r"https://[a-z0-9-]+\.trycloudflare\.com", (directory / "tunnel.log").read_text(errors="replace"))
            if found and "Registered tunnel connection" in (directory / "tunnel.log").read_text(errors="replace"):
                hostname = found.group(0)
                break
            if tunnel.poll() is not None:
                raise RuntimeError("Tunnel exited before connecting")
            await asyncio.sleep(.5)
        if not hostname:
            raise RuntimeError("Tunnel did not become ready")
        spawn(["powershell.exe", "-NoProfile", "-STA", "-ExecutionPolicy", "Bypass", "-File", str(root / "scripts/receiver-qa/windows-desktop-probe.ps1"), "-EvidenceDirectory", str(evidence_dir)], "desktop")
        for _ in range(100):
            if (evidence_dir / "desktop-ready").exists():
                break
            await asyncio.sleep(.2)
        else:
            raise RuntimeError("Desktop witness did not start")
        descriptor = directory / "connection.json"
        descriptor.write_text(json.dumps({"baseURL": hostname + "/" + token}))
        public = directory / "operator-public.der"
        public.write_bytes(base64.b64decode(args.public_key, validate=True))
        openssl = shutil.which("openssl") or r"C:\Program Files\Git\usr\bin\openssl.exe"
        subprocess.run([openssl, "pkeyutl", "-encrypt", "-pubin", "-keyform", "DER", "-inkey", str(public), "-in", str(descriptor), "-out", str(directory / "connection.bin"), "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256"], check=True)
        descriptor.unlink()
        print("Temporary Windows desktop and protected tunnel ready; encrypted descriptor available.", flush=True)
        try:
            await asyncio.wait_for(finished.wait(), timeout=15 * 60)
        except asyncio.TimeoutError:
            raise RuntimeError("Actual iOS input acceptance was not completed within 15 minutes")
        await asyncio.sleep(1)
        result = {"accepted": accepted(evidence()), "client": "actual iOS app (operator-driven)", "nativeDelivery": True, "transport": "iOS WSS via temporary token-guarded tunnel to Windows receiver"}
        (evidence_dir / "result.json").write_text(json.dumps(result, indent=2))
        print("Actual iOS desktop acceptance completed.", flush=True)
        server.close()
        await server.wait_closed()
    finally:
        try:
            await asyncio.to_thread(control, "stop")
        except (OSError, subprocess.SubprocessError):
            pass
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
        for log in logs:
            log.close()
        (directory / "complete").write_text("complete")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", required=True)
    parser.add_argument("--public-key", required=True)
    asyncio.run(session(parser.parse_args()))
