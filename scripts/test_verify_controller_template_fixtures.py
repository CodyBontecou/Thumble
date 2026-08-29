#!/usr/bin/env python3
"""Regression tests for atomic controller-template fixture updates."""

from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("verify-controller-template-fixtures.py")
SPEC = importlib.util.spec_from_file_location("controller_template_fixtures", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixtures)


class AtomicFixtureUpdateTests(unittest.TestCase):
    def test_atomic_exchange_removes_stale_destination_files(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            destination = parent / "v1"
            staged = parent / ".v1.update"
            destination.mkdir()
            staged.mkdir()
            (destination / "canonical.json").write_text("old", encoding="utf-8")
            (destination / "stale.txt").write_text("stale", encoding="utf-8")
            (staged / "canonical.json").write_text("new", encoding="utf-8")

            def verify(path: Path) -> None:
                self.assertEqual({item.name for item in path.iterdir()}, {"canonical.json"})
                self.assertEqual((path / "canonical.json").read_text(encoding="utf-8"), "new")

            fixtures.atomic_replace_directory(destination, staged, verify)
            verify(destination)
            self.assertFalse(staged.exists())

    def test_interruption_before_exchange_leaves_old_canonical_directory_intact(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            destination = parent / "v1"
            staged = parent / ".v1.update"
            destination.mkdir()
            staged.mkdir()
            (destination / "canonical.json").write_text("old", encoding="utf-8")
            (staged / "canonical.json").write_text("new", encoding="utf-8")

            def interrupted(_left: Path, _right: Path) -> None:
                raise RuntimeError("simulated interruption")

            with self.assertRaisesRegex(RuntimeError, "simulated interruption"):
                fixtures.atomic_replace_directory(destination, staged, lambda _path: None, exchange=interrupted)
            self.assertEqual((destination / "canonical.json").read_text(encoding="utf-8"), "old")
            self.assertEqual((staged / "canonical.json").read_text(encoding="utf-8"), "new")

    def test_failed_post_exchange_verification_rolls_back_old_set(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            destination = parent / "v1"
            staged = parent / ".v1.update"
            destination.mkdir()
            staged.mkdir()
            (destination / "canonical.json").write_text("old", encoding="utf-8")
            (staged / "canonical.json").write_text("new", encoding="utf-8")

            with self.assertRaisesRegex(RuntimeError, "verification failed"):
                fixtures.atomic_replace_directory(
                    destination,
                    staged,
                    lambda _path: (_ for _ in ()).throw(RuntimeError("verification failed")),
                )
            self.assertEqual((destination / "canonical.json").read_text(encoding="utf-8"), "old")
            self.assertEqual((staged / "canonical.json").read_text(encoding="utf-8"), "new")


class CatalogValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.catalog = json.loads(fixtures.CATALOG_PATH.read_text(encoding="utf-8"))

    def test_current_catalog_has_exact_schema_fields_and_order(self) -> None:
        entries = fixtures.validate_catalog(copy.deepcopy(self.catalog))
        self.assertEqual(tuple(entry["id"] for entry in entries), fixtures.EXPECTED_TEMPLATE_IDS)

    def test_stale_or_unsafe_catalog_shapes_are_rejected(self) -> None:
        stale = copy.deepcopy(self.catalog)
        stale["templates"] = list(reversed(stale["templates"]))
        with self.assertRaises(RuntimeError):
            fixtures.validate_catalog(stale)

        unsafe = copy.deepcopy(self.catalog)
        unsafe["templates"][0]["id"] = "../productivityStarter"
        with self.assertRaises(RuntimeError):
            fixtures.validate_catalog(unsafe)

        extra = copy.deepcopy(self.catalog)
        extra["templates"][0]["unexpected"] = True
        with self.assertRaises(RuntimeError):
            fixtures.validate_catalog(extra)


if __name__ == "__main__":
    unittest.main()
