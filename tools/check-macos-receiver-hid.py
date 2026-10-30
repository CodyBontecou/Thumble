#!/usr/bin/env python3
"""Check the signed app through Launch Services, without terminal-inherited access."""
import pathlib
import subprocess
import sys
import tempfile
import time

app = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory(prefix="thumble-hid-check-") as directory:
    output = pathlib.Path(directory) / "result.log"
    output.touch(mode=0o600)
    subprocess.run(
        ["open", "-n", "-g", "--stdout", str(output), "--stderr", str(output),
         str(app), "--args", "--self-test-hid"],
        check=True, timeout=20,
    )
    deadline = time.monotonic() + 10
    while True:
        result = output.read_text()
        if "HID self-test " in result or time.monotonic() >= deadline:
            break
        time.sleep(0.05)
    print(result, end="")
    if "HID self-test passed: virtual gamepad created and neutral report accepted." not in result:
        sys.exit("Signed app HID check failed. Complete controller access setup in the app before packaging.")
