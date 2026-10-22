"""Copy only the bounded, known QA HTTP attachment from an exact-test xcresult export.

All other attachments and manifest metadata remain in RUNNER_TEMP. Never copy
screenshots, arbitrary filenames, request URLs, peer state or error descriptions.
"""
import argparse
import json
import os
from pathlib import Path
import re
import stat

TEST = "NativePortalTests/testNativePairingVaultBindingAndReconnectReachRecordingReceiver()"
NAME = "qa-loopback-admission-failure"
NAME_PATTERN = re.compile(re.escape(NAME) + r"(?:_[0-9]{1,3}_[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})?(?:\.json)?")
FIELDS = {"phase", "originalErrorIsURL", "originalErrorCode", "ephemeralHealthSucceeded", "ephemeralHealthErrorCode"}


def invalid():
    raise ValueError("ios_http_diagnostic_invalid")


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            invalid()
        result[key] = value
    return result


def read_json(path, maximum):
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    expected = path.lstat()
    if not stat.S_ISREG(expected.st_mode) or expected.st_nlink != 1:
        invalid()
    fd = os.open(path, flags)
    try:
        before = os.fstat(fd)
        if (before.st_dev, before.st_ino) != (expected.st_dev, expected.st_ino):
            invalid()
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > maximum:
            invalid()
        with os.fdopen(fd, "rb", closefd=False) as source:
            data = source.read(maximum + 1)
        after = os.fstat(fd)
        if len(data) > maximum or (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
            invalid()
        return json.loads(data.decode("utf-8"), object_pairs_hook=unique, parse_constant=lambda _: invalid())
    finally:
        os.close(fd)


def validate_diagnostic(value):
    if type(value) is not dict or set(value) != FIELDS or value["phase"] != "begin-http-failed":
        invalid()
    for field in ("originalErrorIsURL", "ephemeralHealthSucceeded"):
        if type(value[field]) is not bool:
            invalid()
    for field in ("originalErrorCode", "ephemeralHealthErrorCode"):
        if type(value[field]) is not int or not -100000 <= value[field] <= 100000:
            invalid()
    if value["ephemeralHealthSucceeded"] and value["ephemeralHealthErrorCode"] != 0:
        invalid()
    return value


def collect(export, output):
    # A previous invocation can never leave a stale artifact looking current.
    output.unlink(missing_ok=True)
    manifest = read_json(export / "manifest.json", 262144)
    if type(manifest) is not list or len(manifest) > 128:
        invalid()
    found = []
    attachments = 0
    for test in manifest:
        if type(test) is not dict or type(test.get("attachments")) is not list:
            invalid()
        attachments += len(test["attachments"])
        if attachments > 512:
            invalid()
        if test.get("testIdentifier") != TEST:
            continue
        failed_test = any(type(row) is dict and row.get("isAssociatedWithFailure") is True for row in test["attachments"])
        for attachment in test["attachments"]:
            if type(attachment) is not dict:
                invalid()
            name = attachment.get("suggestedHumanReadableName")
            if type(name) is not str or NAME_PATTERN.fullmatch(name) is None:
                continue
            # XCTest labels an explicitly added keepAlways attachment false, even
            # when its test fails. Require separate same-test failure metadata.
            if type(attachment.get("isAssociatedWithFailure")) is not bool or not failed_test:
                invalid()
            filename = attachment.get("exportedFileName")
            if type(filename) is not str or re.fullmatch(r"[A-Za-z0-9_.-]{1,250}\.json", filename) is None:
                invalid()
            found.append(validate_diagnostic(read_json(export / filename, 1024)))
    if len(found) > 1:
        invalid()
    if not found:
        return False
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("x", encoding="utf-8") as target:
        target.write(json.dumps(found[0], sort_keys=True, separators=(",", ":")) + "\n")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--export", dest="export", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        present = collect(args.export, args.output)
    except (OSError, ValueError, UnicodeError, RecursionError):
        raise SystemExit("ios_http_diagnostic_invalid") from None
    print("ios_http_diagnostic_collected" if present else "ios_http_diagnostic_absent")


if __name__ == "__main__":
    main()
