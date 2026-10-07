#!/usr/bin/env python3
"""Model-free tests for the release cask pinning step."""

import hashlib
from pathlib import Path
import plistlib
import re
import tempfile
import unittest
import zipfile

import update_homebrew as homebrew


class HomebrewReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.cask = self.root / "tuff.rb"
        self.original = (homebrew.ROOT / "Casks/tuff.rb").read_text()
        self.cask.write_text(self.original)
        self.archive = self.root / "TUFF-v8.0.0-macos-arm64.zip"

    def package(self, short="8.0.0", build="8.0.0"):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("TUFF.app/Contents/Info.plist", plistlib.dumps({
                "CFBundleShortVersionString": short, "CFBundleVersion": build}))

    def test_repository_cask_has_a_real_pin_and_current_version(self):
        self.assertRegex(self.original, r'(?m)^  sha256 "[0-9a-f]{64}"$')
        source = (homebrew.ROOT / "Sources/TUFFModelCatalog/TUFFVersion.swift").read_text()
        version = re.search(r'static let current\s*=\s*"([^"]+)"', source)[1]
        self.assertIn(f'  version "{version}"', self.original)
        self.assertIn("/TUFF/releases/download/v#{version}/TUFF-v#{version}-macos-arm64.zip", self.original)

    def test_pins_exact_archive_digest_and_preserves_install_artifacts(self):
        self.package()
        homebrew.update("8.0.0", self.archive, self.cask)
        result = self.cask.read_text()
        checksum = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.assertIn(f'  sha256 "{checksum}"', result)
        self.assertEqual(result, homebrew.cask_for_release(self.original, "8.0.0", checksum))
        self.assertIn('binary "#{appdir}/TUFF.app/Contents/Resources/bin/tuff"', result)
        self.assertNotIn("zap ", result)
        homebrew.update("8.0.0", self.archive, self.cask, check=True)

    def test_check_detects_stale_cask_without_mutation(self):
        self.package()
        self.cask.write_text(self.original.replace('  sha256 "', '  sha256 "stale'))
        before = self.cask.read_text()
        with self.assertRaisesRegex(ValueError, "does not match"):
            homebrew.update("8.0.0", self.archive, self.cask, check=True)
        self.assertEqual(self.cask.read_text(), before)

    def test_rejects_short_or_build_version_mismatch_before_mutation(self):
        for short, build in [("7.3.1", "8.0.0"), ("8.0.0", "7.3.1")]:
            with self.subTest(short=short, build=build):
                self.package(short, build)
                with self.assertRaisesRegex(ValueError, "version does not match"):
                    homebrew.update("8.0.0", self.archive, self.cask)
                self.assertEqual(self.cask.read_text(), self.original)

    def test_rejects_wrong_archive_filename(self):
        self.package()
        with self.assertRaisesRegex(ValueError, "must be named"):
            homebrew.archive_checksum("8.0.1", self.archive)

    def test_rejects_invalid_or_incomplete_package(self):
        self.archive.write_text("not a zip")
        with self.assertRaises(zipfile.BadZipFile):
            homebrew.update("8.0.0", self.archive, self.cask)
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("README.txt", "no app here")
        with self.assertRaises(KeyError):
            homebrew.update("8.0.0", self.archive, self.cask)
        self.assertEqual(self.cask.read_text(), self.original)

    def test_rejects_ambiguous_template_and_invalid_inputs(self):
        checksum = "a" * 64
        for template in [self.original + '\n  version "8.0.0"\n',
                         self.original.replace('  sha256 "', '  digest "')]:
            with self.assertRaisesRegex(ValueError, "exactly one"):
                homebrew.cask_for_release(template, "8.0.0", checksum)
        for version, digest in [("8.0.0-rc1", checksum), ("8.0.0", "no_check")]:
            with self.assertRaises(ValueError):
                homebrew.cask_for_release(self.original, version, digest)


if __name__ == "__main__":
    unittest.main()
