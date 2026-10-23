#!/usr/bin/env python3
"""Verify the simulator product signature and embedded runtime Keychain entitlements."""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import sys

app, report = map(Path, sys.argv[1:])
bundle = "com.codybontecou.thumble.rewrite"
identity = "THUMBLECI1." + bundle
info = plistlib.loads((app / "Info.plist").read_bytes())
assert info["CFBundleIdentifier"] == bundle
executable = app / info["CFBundleExecutable"]
subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
report.parent.mkdir(parents=True, exist_ok=True)
thin = report.parent / ".editor-product-arm64-inspection"
try:
    subprocess.run(["xcrun", "lipo", str(executable), "-thin", "arm64", "-output", str(thin)], check=True)
    data = thin.read_bytes()
    assert struct.unpack_from("<I", data)[0] == 0xFEEDFACF
    commands = struct.unpack_from("<I", data, 16)[0]
    offset = 32
    entitlements = None
    for _ in range(commands):
        command, size = struct.unpack_from("<II", data, offset)
        assert size >= 8 and offset + size <= len(data)
        if command == 0x19:
            sections = struct.unpack_from("<I", data, offset + 64)[0]
            for index in range(sections):
                section = offset + 72 + index * 80
                assert section + 80 <= offset + size
                name = data[section:section + 16].split(b"\0")[0]
                if name == b"__entitlements":
                    length = struct.unpack_from("<Q", data, section + 40)[0]
                    start = struct.unpack_from("<I", data, section + 48)[0]
                    entitlements = plistlib.loads(data[start:start + length])
        offset += size
    assert entitlements is not None
    assert entitlements["application-identifier"] == identity
    assert entitlements["keychain-access-groups"] == [identity]
    assert entitlements["com.apple.developer.team-identifier"] == "THUMBLECI1"
    assert entitlements["get-task-allow"] is True
    report.write_text(json.dumps({
        "adHocSignatureVerified": True,
        "embeddedSimulatorEntitlementsVerified": True,
        "applicationIdentifierMatchesProduct": True,
        "defaultKeychainAccessGroupMatchesProduct": True,
        "simulatorOnly": True,
        "mainBundleSha256": hashlib.sha256((app / "main.jsbundle").read_bytes()).hexdigest(),
        "appExecutableSha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
    }, indent=2) + "\n")
finally:
    thin.unlink(missing_ok=True)
