#!/usr/bin/env python3
"""Read-only final-bundle HID authorization gate (not a controller compatibility test).

No accounts, keychains, signing, or input injection are changed. Profile-only
preflight cannot authorize a signer; require-HID checks the final certificate too.
Ad-hoc diagnosis is deliberately separate and never reports HID authorization.
"""
import argparse
from datetime import datetime, timezone
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from xml.parsers.expat import ExpatError

HID_KEY = "com.apple.developer.hid.virtual.device"
TEAM_ID = "67KC823C9A"
APP_ID_KEYS = ("com.apple.application-identifier", "application-identifier")
TASK_ALLOW_KEYS = ("get-task-allow", "com.apple.security.get-task-allow")


class ValidationError(Exception):
    """Safe, bounded diagnostic; never contains certificates or command output."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def utc_date(value, label):
    require(isinstance(value, datetime), f"{label} must be a date")
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def validate_identity(entitlements, bundle_id, team_id, label):
    require(isinstance(entitlements, dict), f"{label} entitlements missing")
    ids = [entitlements[key] for key in APP_ID_KEYS if key in entitlements]
    require(bool(ids) and all(value == f"{team_id}.{bundle_id}" for value in ids),
            f"{label} App ID missing, wildcard, or mismatched")
    require(entitlements.get("com.apple.developer.team-identifier") == team_id,
            f"{label} entitlement team mismatched")
    require(entitlements.get(HID_KEY) is True, f"{label} requires Boolean HID authorization")


def validate_profile(profile, *, bundle_id, team_id=TEAM_ID, distribution="developer-id", now=None):
    """Pure preflight seam. Expects the decoded CMS plist, not a profile filename."""
    require(distribution in ("developer-id", "development"), "unsupported distribution scope")
    require(isinstance(profile, dict), "embedded provisioning profile missing")
    require(profile.get("TeamIdentifier") == [team_id], "profile team mismatched")
    require(profile.get("ApplicationIdentifierPrefix") == [team_id], "profile App ID prefix mismatched")
    platforms = profile.get("Platform")
    require(isinstance(platforms, list) and platforms == ["OSX"], "profile must authorize macOS only")
    now = utc_date(now or datetime.now(timezone.utc), "validation time")
    require(utc_date(profile.get("ExpirationDate"), "profile expiration") > now, "profile expired")
    require(utc_date(profile.get("CreationDate"), "profile creation") <= now, "profile not yet valid")
    entitlements = profile.get("Entitlements")
    validate_identity(entitlements, bundle_id, team_id, "profile")
    certificates = profile.get("DeveloperCertificates")
    require(isinstance(certificates, list) and bool(certificates)
            and all(isinstance(cert, bytes) and bool(cert) for cert in certificates),
            "profile signer certificates missing or malformed")
    if distribution == "developer-id":
        # Fail closed on device-limited development or App Store scope. A managed
        # HID grant's eligibility is evidenced by this decoded distribution profile,
        # not inferred from a certificate name or notarization success.
        require(profile.get("ProvisionsAllDevices") is True and "ProvisionedDevices" not in profile,
                "profile is not unrestricted Developer ID distribution scope")
        for key in TASK_ALLOW_KEYS:
            require(key not in entitlements or entitlements[key] is False,
                    "distribution profile allows debugging or has malformed get-task-allow")
    else:
        devices = profile.get("ProvisionedDevices")
        require(isinstance(devices, list) and bool(devices)
                and all(isinstance(device, str) and device for device in devices)
                and profile.get("ProvisionsAllDevices", False) is False,
                "profile is not device-limited development scope")


def validate_hid(signature, profile, *, bundle_id, team_id=TEAM_ID, distribution="developer-id", now=None):
    """Pure signature/profile contract, shared by artifact inspection and fixtures."""
    validate_profile(profile, bundle_id=bundle_id, team_id=team_id, distribution=distribution, now=now)
    require(isinstance(signature, dict), "signature claims missing")
    require(signature.get("adhoc") is False, "ad-hoc signature cannot authorize managed HID")
    require(signature.get("identifier") == bundle_id, "signature identifier mismatched")
    require(signature.get("team") == team_id, "signature team mismatched")
    entitlements = signature.get("entitlements")
    validate_identity(entitlements, bundle_id, team_id, "signature")
    certificate = signature.get("certificate")
    require(isinstance(certificate, bytes) and bool(certificate)
            and certificate in profile["DeveloperCertificates"], "signer certificate not authorized by profile")
    if distribution == "developer-id":
        authorities = signature.get("authorities", [])
        require(bool(authorities) and isinstance(authorities[0], str)
                and authorities[0].startswith("Developer ID Application:"),
                "signature is not Developer ID Application distribution")
        for key in TASK_ALLOW_KEYS:
            require(key not in entitlements or entitlements[key] is False,
                    "distribution signature allows debugging or has malformed get-task-allow")


def validate_ad_hoc(signature):
    """Only confirms a restricted-entitlement-free diagnostic signature."""
    require(isinstance(signature, dict) and signature.get("adhoc") is True,
            "ad-hoc diagnosis requires an ad-hoc signature")
    entitlements = signature.get("entitlements")
    require(isinstance(entitlements, dict), "signature entitlement dictionary missing")
    restricted = [key for key in entitlements if key == HID_KEY or key in APP_ID_KEYS
                  or key == "keychain-access-groups" or key.startswith("com.apple.developer.")]
    require(not restricted, "ad-hoc diagnostic artifact claims restricted entitlements")


def run_command(argv, *, stderr_output=False):
    """Never forward raw subprocess output (which may contain profile/cert data)."""
    try:
        result = subprocess.run([str(arg) for arg in argv], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=False)
    except OSError:
        raise ValidationError(f"unable to execute {Path(argv[0]).name}") from None
    require(result.returncode == 0, f"{Path(argv[0]).name} inspection/verification failed")
    return result.stderr if stderr_output else result.stdout


def parse_plist(payload, label):
    # codesign may prefix XML with a display line; never print that line.
    if not payload.startswith(b"bplist"):
        start = payload.find(b"<?xml")
        if start < 0:
            start = payload.find(b"<plist")
        if start >= 0:
            payload = payload[start:]
    try:
        result = plistlib.loads(payload)
    except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError):
        raise ValidationError(f"{label} plist cannot be decoded") from None
    require(isinstance(result, dict), f"{label} plist must be a dictionary")
    return result


def decode_profile(path):
    return parse_plist(run_command(["security", "cms", "-D", "-i", str(path)]), "profile")


def inspect_entitlements(executable, *, arch):
    payload = run_command(["codesign", "--display", "--arch", arch, "--entitlements", ":-", str(executable)])
    return parse_plist(payload, "signature entitlements") if payload.strip() else {}


def inspect_signature(executable, *, arch):
    """Inspect the calling Mach-O, including the actual leaf signing certificate."""
    display = run_command(["codesign", "--display", "--verbose=4", "--arch", arch, str(executable)],
                          stderr_output=True).decode("utf-8", errors="replace")
    fields = {}
    authorities = []
    for line in display.splitlines():
        key, separator, value = line.partition("=")
        if separator:
            if key == "Authority":
                authorities.append(value)
            else:
                fields[key] = value
    require("Identifier" in fields, "codesign identifier missing")
    adhoc = fields.get("Signature") == "adhoc"
    entitlements = inspect_entitlements(executable, arch=arch)
    certificate = None
    if not adhoc:
        with tempfile.TemporaryDirectory(prefix="thumble-signing-check-") as directory:
            prefix = Path(directory) / "signer"
            run_command(["codesign", "--display", "--arch", arch, "--extract-certificates", str(prefix), str(executable)])
            leaf = Path(str(prefix) + "0")
            require(leaf.is_file(), "codesign leaf certificate missing")
            certificate = leaf.read_bytes()
    return {"identifier": fields["Identifier"], "team": fields.get("TeamIdentifier"),
            "adhoc": adhoc, "authorities": authorities,
            "entitlements": entitlements, "certificate": certificate}


def executable_arches(executable):
    arches = run_command(["lipo", "-archs", str(executable)]).decode("ascii", errors="replace").split()
    require(bool(arches) and all(arch in ("arm64", "x86_64") for arch in arches),
            "unsupported or missing executable architectures")
    return arches


def verify_nested_code(contents, main_executable, *, diagnose_ad_hoc):
    # Look at Mach-O magic, not names/extensions: the CLI, MCP and bridges are
    # extensionless, while frameworks can contain additional native executables.
    magic = {bytes.fromhex(value) for value in (
        "feedface", "cefaedfe", "feedfacf", "cffaedfe",
        "cafebabe", "bebafeca", "cafebabf", "bfbafeca",
    )}
    seen = {main_executable.resolve()}
    for candidate in contents.rglob("*"):
        if not candidate.is_file() or candidate.resolve() in seen:
            continue
        with candidate.open("rb") as stream:
            is_macho = stream.read(4) in magic
        if not is_macho:
            continue
        require(candidate.resolve().is_relative_to(contents.resolve()), "nested executable resolves outside bundle")
        seen.add(candidate.resolve())
        for arch in executable_arches(candidate):
            if diagnose_ad_hoc:
                validate_ad_hoc(inspect_signature(candidate, arch=arch))
            else:
                require(HID_KEY not in inspect_entitlements(candidate, arch=arch),
                        "nested helper must not claim HID privileges")


def signer_requirement(bundle_id, team_id, distribution):
    # These are codesign requirement literals, not shell interpolation. Escape
    # caller-provided expected IDs so they cannot inject another requirement.
    def literal(value):
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    requirement = (f"anchor apple generic and identifier {literal(bundle_id)} "
                   f"and certificate leaf[subject.OU] = {literal(team_id)}")
    if distribution == "developer-id":
        requirement += " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    return requirement


def verify_artifact(app, *, bundle_id, team_id=TEAM_ID, distribution="developer-id", now=None, diagnose_ad_hoc=False):
    """Verify final app integrity and each slice's calling-process authorization."""
    app = Path(app)
    contents = app / "Contents"
    require(app.is_dir(), "final app bundle missing")
    try:
        info = parse_plist((contents / "Info.plist").read_bytes(), "bundle Info")
    except OSError:
        raise ValidationError("bundle Info.plist missing or unreadable") from None
    require(info.get("CFBundleIdentifier") == bundle_id, "bundle identifier mismatched")
    name = info.get("CFBundleExecutable")
    require(isinstance(name, str) and bool(name) and name not in (".", "..")
            and Path(name).name == name, "bundle executable name malformed")
    executable = contents / "MacOS" / name
    require(executable.is_file(), "main executable missing")
    require(executable.resolve().is_relative_to(contents.resolve()), "main executable resolves outside bundle")
    profile_path = contents / "embedded.provisionprofile"
    if diagnose_ad_hoc:
        require(not profile_path.exists(), "ad-hoc diagnostic artifact must not embed a provisioning profile")
        profile = None
    else:
        require(profile_path.is_file(), "embedded provisioning profile missing")
        profile = decode_profile(profile_path)
        validate_profile(profile, bundle_id=bundle_id, team_id=team_id, distribution=distribution, now=now)
    # --deep is verification ONLY. Signing must remain explicit and inside-out.
    run_command(["codesign", "--verify", "--deep", "--strict", "--all-architectures", str(app)])
    for arch in executable_arches(executable):
        signature = inspect_signature(executable, arch=arch)
        if diagnose_ad_hoc:
            validate_ad_hoc(signature)
        else:
            validate_hid(signature, profile, bundle_id=bundle_id, team_id=team_id,
                         distribution=distribution, now=now)
    if not diagnose_ad_hoc:
        # Displayed certificate names are diagnostics, not trust evidence. Test
        # Apple's anchor and real certificate OU/OID on the main executable only.
        run_command(["codesign", "--verify", "--strict", "--all-architectures", "--test-requirement",
                     signer_requirement(bundle_id, team_id, distribution), str(executable)])
    verify_nested_code(contents, executable, diagnose_ad_hoc=diagnose_ad_hoc)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path, help="final app bundle (not a loose executable)")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--require-hid", action="store_true", help="fail unless final artifact authorizes HID")
    mode.add_argument("--diagnose-ad-hoc", action="store_true", help="restricted-entitlement-free; controller-unverified")
    mode.add_argument("--profile-only", type=Path, help="CMS profile preflight; does NOT authorize a final signer")
    parser.add_argument("--bundle-id", required=True)
    parser.add_argument("--team-id", default=TEAM_ID)
    parser.add_argument("--distribution", choices=("developer-id", "development"), default="developer-id")
    args = parser.parse_args(argv)
    if args.profile_only and args.app:
        parser.error("--profile-only does not accept an app")
    if not args.profile_only and not args.app:
        parser.error("an app bundle is required")
    try:
        if args.profile_only:
            require(args.profile_only.is_file(), "provisioning profile missing")
            validate_profile(decode_profile(args.profile_only), bundle_id=args.bundle_id,
                             team_id=args.team_id, distribution=args.distribution)
            print("Profile preflight passed; final signer/artifact still unverified.")
        else:
            verify_artifact(args.app, bundle_id=args.bundle_id, team_id=args.team_id,
                            distribution=args.distribution, diagnose_ad_hoc=args.diagnose_ad_hoc)
            print("Ad-hoc diagnostic passed; controller-unverified." if args.diagnose_ad_hoc
                  else "Final artifact HID signing/profile authorization verified; consumer compatibility unverified.")
    except ValidationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    except OSError:
        # Paths may reveal local account information; keep these generic.
        print("error: artifact inspection failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
