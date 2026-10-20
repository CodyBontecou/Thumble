#!/usr/bin/env python3
"""Exercise capability coverage using temporary copies of the real contracts."""

import contextlib
import importlib.util
import io
import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("parity", Path(__file__).with_name("verify-mcp-cli-parity.py"))
parity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(parity)


class CapabilityCoverageTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        paths = {"ROOT": root}
        for name in ("CLI", "LEDGER", "OPERATION_SCHEMA", "DEVICE_CATALOG"):
            original = getattr(parity, name)
            destination = root / original.relative_to(parity.ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original, destination)
            paths[name] = destination
        replacement = patch.multiple(parity, **paths)
        replacement.start()
        self.addCleanup(replacement.stop)

    def edit_ledger(self, edit):
        ledger = json.loads(parity.LEDGER.read_text())
        edit(ledger)
        parity.LEDGER.write_text(json.dumps(ledger))

    def assert_rejected(self, message):
        errors = io.StringIO()
        with contextlib.redirect_stderr(errors), self.assertRaises(SystemExit) as caught:
            parity.main()
        self.assertEqual(caught.exception.code, 1)
        self.assertIn(message, errors.getvalue())

    def test_checked_in_contracts_pass(self):
        with contextlib.redirect_stdout(io.StringIO()):
            parity.main()

    def test_missing_shared_build_family_fails(self):
        self.edit_ledger(lambda ledger: ledger.update(families=[
            family for family in ledger["families"] if family["id"] != "shared-build"
        ]))
        self.assert_rejected("unmapped root CLI commands: shared-build")

    def test_missing_shared_build_cancel_fails(self):
        def remove(ledger):
            family = next(item for item in ledger["families"] if item["id"] == "shared-build")
            family["operations"] = [item for item in family["operations"] if item["id"] != "shared-build.cancel"]
        self.edit_ledger(remove)
        self.assert_rejected("unmapped canonical CLI subcommands: shared-build cancel")

    def test_new_guarded_command_requires_mapping(self):
        source = parity.CLI.read_text()
        updated = source.replace('["adopt", "status", "cancel"]', '["adopt", "status", "cancel", "inspect"]', 1)
        self.assertNotEqual(source, updated)
        parity.CLI.write_text(updated)
        self.assert_rejected("unmapped canonical CLI subcommands: shared-build inspect")

    def test_missing_editor_view_fails(self):
        def remove(ledger):
            family = next(item for item in ledger["families"] if item["id"] == "app")
            family["operations"] = [item for item in family["operations"] if item["id"] != "app.editor-view"]
        self.edit_ledger(remove)
        self.assert_rejected("unmapped canonical CLI subcommands: app editor-view")


if __name__ == "__main__":
    unittest.main()
