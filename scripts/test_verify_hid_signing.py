"""Synthetic signing fixtures only; never uses real profiles or signing accounts."""
import copy
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "verify_hid_signing", Path(__file__).with_name("verify-hid-signing.py")
)
hid = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(hid)

TEAM = "67KC823C9A"
BUNDLE = "com.codybontecou.ThumbleHost"
NOW = datetime(2026, 6, 1, tzinfo=timezone.utc)
CERT = b"synthetic signer certificate, not DER"


def profile_fixture():
    return {
        "TeamIdentifier": [TEAM],
        "ApplicationIdentifierPrefix": [TEAM],
        "Platform": ["OSX"],
        "CreationDate": NOW - timedelta(days=1),
        "ExpirationDate": NOW + timedelta(days=1),
        "ProvisionsAllDevices": True,
        "DeveloperCertificates": [CERT],
        "Entitlements": {
            "com.apple.application-identifier": f"{TEAM}.{BUNDLE}",
            "com.apple.developer.team-identifier": TEAM,
            "com.apple.developer.hid.virtual.device": True,
            "get-task-allow": False,
        },
    }


def signature_fixture():
    return {
        "identifier": BUNDLE,
        "team": TEAM,
        "adhoc": False,
        "authorities": ["Developer ID Application: Synthetic Signer"],
        "certificate": CERT,
        "entitlements": {
            "com.apple.application-identifier": f"{TEAM}.{BUNDLE}",
            "com.apple.developer.team-identifier": TEAM,
            "com.apple.developer.hid.virtual.device": True,
        },
    }


class ValidationTests(unittest.TestCase):
    def setUp(self):
        self.profile = profile_fixture()
        self.signature = signature_fixture()

    def validate(self, distribution="developer-id"):
        return hid.validate_hid(
            self.signature, self.profile, bundle_id=BUNDLE, team_id=TEAM,
            distribution=distribution, now=NOW,
        )

    def test_valid_developer_id_and_gui_identifier(self):
        self.validate()
        gui = "com.codybontecou.PocketPadMac"
        self.signature["identifier"] = gui
        for obj in (self.profile, self.signature):
            obj["entitlements" if obj is self.signature else "Entitlements"][
                "com.apple.application-identifier"
            ] = f"{TEAM}.{gui}"
        hid.validate_hid(self.signature, self.profile, bundle_id=gui, team_id=TEAM, now=NOW)

    def test_missing_profile_or_hid_claim(self):
        with self.assertRaises(hid.ValidationError):
            hid.validate_hid(self.signature, None, bundle_id=BUNDLE, team_id=TEAM, now=NOW)
        del self.signature["entitlements"][hid.HID_KEY]
        with self.assertRaises(hid.ValidationError):
            self.validate()

    def test_hid_must_be_boolean_true_in_both_places(self):
        for value in (False, 1, "true", None, [True]):
            for where in ("profile", "signature"):
                with self.subTest(value=value, where=where):
                    self.setUp()
                    target = self.profile["Entitlements"] if where == "profile" else self.signature["entitlements"]
                    target[hid.HID_KEY] = value
                    with self.assertRaises(hid.ValidationError):
                        self.validate()

    def test_identifier_team_and_prefix_mismatches(self):
        mutations = [
            ("signature", "identifier", "com.example.Wrong"),
            ("signature", "team", "WRONGTEAM"),
            ("profile", "TeamIdentifier", ["WRONGTEAM"]),
            ("profile", "ApplicationIdentifierPrefix", ["WRONGTEAM"]),
            ("profile", "Entitlements", {**self.profile["Entitlements"], "com.apple.application-identifier": f"{TEAM}.*"}),
            ("signature", "entitlements", {**self.signature["entitlements"], "com.apple.application-identifier": f"{TEAM}.com.example.Wrong"}),
            ("profile", "Entitlements", {**self.profile["Entitlements"], "com.apple.developer.team-identifier": "WRONGTEAM"}),
            ("signature", "entitlements", {**self.signature["entitlements"], "com.apple.developer.team-identifier": "WRONGTEAM"}),
        ]
        for where, key, value in mutations:
            with self.subTest(where=where, key=key):
                self.setUp()
                getattr(self, where)[key] = value
                with self.assertRaises(hid.ValidationError):
                    self.validate()

    def test_alternate_app_identifier_key_and_conflicting_alias(self):
        for obj in (self.profile["Entitlements"], self.signature["entitlements"]):
            obj["application-identifier"] = obj.pop("com.apple.application-identifier")
        self.validate()
        self.signature["entitlements"]["com.apple.application-identifier"] = "conflict"
        with self.assertRaises(hid.ValidationError):
            self.validate()

    def test_expiration_future_creation_and_naive_plist_dates(self):
        for expiry in (NOW, NOW - timedelta(seconds=1), None, "tomorrow"):
            self.profile["ExpirationDate"] = expiry
            with self.assertRaises(hid.ValidationError):
                self.validate()
        self.setUp()
        self.profile["CreationDate"] = NOW + timedelta(seconds=1)
        with self.assertRaises(hid.ValidationError):
            self.validate()
        self.setUp()
        for key in ("CreationDate", "ExpirationDate"):
            self.profile[key] = self.profile[key].replace(tzinfo=None)
        self.validate()

    def test_developer_id_scope_is_not_development_or_store(self):
        for key, value in (
            ("ProvisionsAllDevices", False), ("ProvisionsAllDevices", 1),
            ("ProvisionedDevices", ["synthetic-device"]), ("Platform", ["iOS"]),
        ):
            self.setUp()
            self.profile[key] = value
            with self.assertRaises(hid.ValidationError):
                self.validate()
        for where, key in (("profile", "Entitlements"), ("signature", "entitlements")):
            for task_key in ("get-task-allow", "com.apple.security.get-task-allow"):
                self.setUp()
                getattr(self, where)[key][task_key] = True
                with self.assertRaises(hid.ValidationError):
                    self.validate()
        self.setUp()
        self.signature["authorities"] = ["Apple Development: Synthetic"]
        with self.assertRaises(hid.ValidationError):
            self.validate()

    def test_development_is_explicit_and_still_requires_authorization(self):
        self.profile.pop("ProvisionsAllDevices")
        self.profile["ProvisionedDevices"] = ["synthetic-device"]
        self.profile["Entitlements"]["get-task-allow"] = True
        self.signature["authorities"] = ["Apple Development: Synthetic"]
        self.validate(distribution="development")
        self.signature["certificate"] = b"not authorized"
        with self.assertRaises(hid.ValidationError):
            self.validate(distribution="development")

    def test_signer_certificate_authorization_is_required(self):
        for cert in (None, b"not authorized"):
            self.signature["certificate"] = cert
            with self.assertRaises(hid.ValidationError):
                self.validate()
        self.setUp()
        self.profile["DeveloperCertificates"] = []
        with self.assertRaises(hid.ValidationError):
            self.validate()

    def test_adhoc_is_not_hid_validation(self):
        self.signature["adhoc"] = True
        with self.assertRaises(hid.ValidationError):
            self.validate()
        self.signature["entitlements"] = {}
        hid.validate_ad_hoc(self.signature)
        self.signature["entitlements"][hid.HID_KEY] = True
        with self.assertRaises(hid.ValidationError):
            hid.validate_ad_hoc(self.signature)
        self.signature["entitlements"] = {"com.apple.application-identifier": f"{TEAM}.{BUNDLE}"}
        with self.assertRaises(hid.ValidationError):
            hid.validate_ad_hoc(self.signature)
        self.signature["entitlements"] = {}
        self.signature["adhoc"] = False
        with self.assertRaises(hid.ValidationError):
            hid.validate_ad_hoc(self.signature)

    def test_missing_identity_claims_fail_closed(self):
        for obj, key in ((self.signature["entitlements"], "com.apple.application-identifier"),
                         (self.profile["Entitlements"], "com.apple.developer.team-identifier")):
            previous = obj.pop(key)
            with self.assertRaises(hid.ValidationError):
                self.validate()
            obj[key] = previous


class ResourceTests(unittest.TestCase):
    def test_only_receiver_plists_claim_boolean_hid(self):
        root = Path(__file__).resolve().parent.parent
        for resource in ("Mac/ThumbleMac.entitlements", "Host/ThumbleHost.entitlements"):
            with self.subTest(resource=resource):
                claims = plistlib.loads((root / "Resources" / resource).read_bytes())
                self.assertIs(claims[hid.HID_KEY], True)
        host = plistlib.loads((root / "Resources/Host/ThumbleHost.entitlements").read_bytes())
        self.assertEqual(host["com.apple.application-identifier"], f"{TEAM}.{BUNDLE}")
        self.assertEqual(host["com.apple.developer.team-identifier"], TEAM)


class ArtifactTests(unittest.TestCase):
    def make_app(self, directory):
        app = Path(directory) / "Synthetic.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        (app / "Contents" / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": BUNDLE, "CFBundleExecutable": "receiver",
        }))
        (app / "Contents" / "MacOS" / "receiver").write_bytes(b"synthetic executable")
        return app

    def test_missing_profile_fails_before_any_external_inspection(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(hid, "run_command") as run:
            app = self.make_app(directory)
            with self.assertRaises(hid.ValidationError):
                hid.verify_artifact(app, bundle_id=BUNDLE, team_id=TEAM, now=NOW)
            run.assert_not_called()

    def test_all_architectures_and_nested_verification_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(directory)
            (app / "Contents" / "embedded.provisionprofile").write_bytes(b"synthetic CMS")
            with patch.object(hid, "decode_profile", return_value=profile_fixture()), \
                 patch.object(hid, "run_command", return_value=b"arm64 x86_64\n") as run, \
                 patch.object(hid, "inspect_signature", return_value=signature_fixture()) as inspect:
                hid.verify_artifact(app, bundle_id=BUNDLE, team_id=TEAM, now=NOW)
                self.assertEqual([call.kwargs["arch"] for call in inspect.call_args_list], ["arm64", "x86_64"])
                self.assertTrue(any("--verify" in call.args[0] and "--deep" in call.args[0] for call in run.call_args_list))
                trust_checks = [call.args[0] for call in run.call_args_list if "--test-requirement" in call.args[0]]
                self.assertEqual(len(trust_checks), 1)
                requirement = trust_checks[0][trust_checks[0].index("--test-requirement") + 1]
                self.assertIn("anchor apple generic", requirement)
                self.assertIn("1.2.840.113635.100.6.1.13", requirement)
                self.assertIn(TEAM, requirement)
                self.assertNotIn("--deep", trust_checks[0])
                broken = copy.deepcopy(signature_fixture())
                broken["entitlements"][hid.HID_KEY] = False
                inspect.side_effect = [signature_fixture(), broken]
                with self.assertRaises(hid.ValidationError):
                    hid.verify_artifact(app, bundle_id=BUNDLE, team_id=TEAM, now=NOW)

    def test_command_failure_does_not_log_external_output(self):
        import subprocess
        secret = b"synthetic sensitive certificate or token"
        with patch.object(hid.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, secret, secret)):
            with self.assertRaises(hid.ValidationError) as error:
                hid.run_command(["codesign", "--verify", "Synthetic.app"])
            self.assertNotIn(secret.decode(), str(error.exception))

    def test_nested_helper_must_not_claim_hid(self):
        with tempfile.TemporaryDirectory() as directory:
            app = self.make_app(directory)
            (app / "Contents" / "embedded.provisionprofile").write_bytes(b"synthetic CMS")
            helper = app / "Contents" / "MacOS" / "client"
            helper.write_bytes(b"\xcf\xfa\xed\xfe" + b"synthetic Mach-O")
            with patch.object(hid, "decode_profile", return_value=profile_fixture()), \
                 patch.object(hid, "run_command", return_value=b"arm64\n"), \
                 patch.object(hid, "inspect_signature", return_value=signature_fixture()), \
                 patch.object(hid, "inspect_entitlements", return_value={hid.HID_KEY: True}):
                with self.assertRaises(hid.ValidationError):
                    hid.verify_artifact(app, bundle_id=BUNDLE, team_id=TEAM, now=NOW)
            with patch.object(hid, "decode_profile", return_value=profile_fixture()), \
                 patch.object(hid, "run_command", return_value=b"arm64\n"), \
                 patch.object(hid, "inspect_signature", return_value=signature_fixture()), \
                 patch.object(hid, "inspect_entitlements", return_value={}):
                hid.verify_artifact(app, bundle_id=BUNDLE, team_id=TEAM, now=NOW)

    def test_inspector_reads_actual_leaf_and_entitlements(self):
        display = (f"Identifier={BUNDLE}\nTeamIdentifier={TEAM}\n"
                   "Authority=Developer ID Application: Synthetic Signer\n").encode()
        claims = signature_fixture()["entitlements"]

        def fake_command(argv, **kwargs):
            if "--extract-certificates" in argv:
                prefix = argv[argv.index("--extract-certificates") + 1]
                Path(str(prefix) + "0").write_bytes(CERT)
                return b""
            if "--entitlements" in argv:
                return plistlib.dumps(claims)
            return display

        with patch.object(hid, "run_command", side_effect=fake_command):
            signature = hid.inspect_signature(Path("synthetic-receiver"), arch="arm64")
            self.assertEqual(signature, signature_fixture())

    def test_adhoc_inspection_has_no_certificate_extraction(self):
        with patch.object(hid, "run_command", side_effect=[
            f"Identifier={BUNDLE}\nSignature=adhoc\n".encode(), b"",
        ]) as run:
            signature = hid.inspect_signature(Path("synthetic-receiver"), arch="arm64")
            hid.validate_ad_hoc(signature)
            self.assertEqual(run.call_count, 2)

    def test_bad_plist_is_a_safe_validation_error(self):
        for payload in (b"not a plist", b"<?xml bad profile", plistlib.dumps(["not a dictionary"])):
            with self.subTest(payload=payload), self.assertRaises(hid.ValidationError):
                hid.parse_plist(payload, "fixture")

    def test_adhoc_artifact_rejects_embedded_profile(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(hid, "run_command") as run:
            app = self.make_app(directory)
            (app / "Contents" / "embedded.provisionprofile").write_bytes(b"synthetic CMS")
            with self.assertRaises(hid.ValidationError):
                hid.verify_artifact(app, bundle_id=BUNDLE, diagnose_ad_hoc=True)
            run.assert_not_called()

    def test_decode_profile_uses_security_cms(self):
        profile = profile_fixture()
        # plistlib serializes UTC-naive dates, as Apple's CMS payload does.
        for key in ("CreationDate", "ExpirationDate"):
            profile[key] = profile[key].replace(tzinfo=None)
        with patch.object(hid, "run_command", return_value=plistlib.dumps(profile)) as run:
            result = hid.decode_profile(Path("synthetic.provisionprofile"))
            self.assertIs(result["Entitlements"][hid.HID_KEY], True)
            self.assertEqual(run.call_args.args[0][:4], ["security", "cms", "-D", "-i"])


if __name__ == "__main__":
    unittest.main()
