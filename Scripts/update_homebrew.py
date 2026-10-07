#!/usr/bin/env python3
"""Pin the Homebrew cask to a packaged release, without publishing anything."""

import argparse
import hashlib
from pathlib import Path
import plistlib
import re
import zipfile


ROOT = Path(__file__).resolve().parent.parent


def archive_checksum(version: str, archive: Path) -> str:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("version must be MAJOR.MINOR.PATCH")
    expected_name = f"TUFF-v{version}-macos-arm64.zip"
    if archive.name != expected_name:
        raise ValueError(f"archive must be named {expected_name}")
    with zipfile.ZipFile(archive) as package:
        info = plistlib.loads(package.read("TUFF.app/Contents/Info.plist"))
    if info.get("CFBundleShortVersionString") != version or info.get("CFBundleVersion") != version:
        raise ValueError("packaged app version does not match the requested cask version")
    checksum = hashlib.sha256()
    with archive.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def cask_for_release(source: str, version: str, checksum: str) -> str:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("version must be MAJOR.MINOR.PATCH")
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("checksum must be a SHA-256 digest")
    source, versions = re.subn(r'^  version "[^"\n]+"$', f'  version "{version}"', source, flags=re.M)
    source, checksums = re.subn(r'^  sha256 "[^"\n]+"$', f'  sha256 "{checksum}"', source, flags=re.M)
    if versions != 1 or checksums != 1:
        raise ValueError("cask must contain exactly one version and one checksum")
    return source


def update(version: str, archive: Path, cask: Path, check: bool = False) -> None:
    checksum = archive_checksum(version, archive)
    source = cask.read_text(encoding="utf-8")
    updated = cask_for_release(source, version, checksum)
    if check:
        if source != updated:
            raise ValueError("Homebrew cask does not match the packaged release")
    else:
        cask.write_text(updated, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("archive", type=Path)
    parser.add_argument("--check", action="store_true", help="verify without changing the cask")
    args = parser.parse_args()
    try:
        update(args.version, args.archive, ROOT / "Casks/tuff.rb", args.check)
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Homebrew cask: {error}\n")
    print(f"Homebrew cask {'verified' if args.check else 'updated'} for {args.version}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
