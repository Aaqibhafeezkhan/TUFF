#!/usr/bin/env bash

set -euo pipefail

version="${1:-}"
archive_argument="${2:-}"
if [[ $# -ge 2 ]]; then shift 2; else shift "$#"; fi
signing_options=(--account TUFF)
provenance=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ed-key-file) signing_options=(--ed-key-file "$2"); shift 2 ;;
    --recovery-provenance) provenance="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: Scripts/generate_update_appcast.sh VERSION [ARCHIVE_DIRECTORY]" >&2
  exit 64
fi

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd -- "$script_directory/.." && pwd)"
archive_directory="${archive_argument:-$repository_root/dist}"
archive="TUFF-v${version}-macos-arm64.zip"
generator="$repository_root/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"

if [[ ! -x "$generator" ]]; then
  echo "missing Sparkle appcast generator; run swift package resolve first" >&2
  exit 1
fi
if [[ ! -f "$archive_directory/$archive" ]]; then
  echo "missing packaged update: $archive_directory/$archive" >&2
  exit 1
fi

# Generate from a directory holding only this version's archive. The generator
# writes one entry per archive it finds and gives every one of them the same
# download prefix, so a stale archive left in dist/ would be published with a
# URL under this release that does not exist.
staging="$(mktemp -d "${TMPDIR:-/tmp}/tuff-appcast.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
cp "$archive_directory/$archive" "$staging/$archive"

notes="$repository_root/docs/RELEASE_${version}_NOTES.md"
if [[ ! -f "$notes" ]]; then
  echo "missing release notes: $notes" >&2
  exit 1
fi
cp "$notes" "$staging/${archive%.zip}.md"

"$generator" \
  "${signing_options[@]}" \
  --download-url-prefix \
    "https://github.com/rexmhall09/TUFF/releases/download/v${version}/" \
  --link "https://github.com/rexmhall09/TUFF" \
  --embed-release-notes \
  "$staging"

if [[ -n "$provenance" ]]; then
  python3 "$repository_root/Scripts/stamp_appcast.py" "$staging/appcast.xml" --recovery-provenance "$provenance"
else
  python3 "$repository_root/Scripts/stamp_appcast.py" "$staging/appcast.xml"
fi
# Adding metadata changes the signed XML. Sign the finished feed, then verify
# it with the same key before it can become a release asset.
"$repository_root/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
  "${signing_options[@]}" "$staging/appcast.xml"
"$repository_root/.build/artifacts/sparkle/Sparkle/bin/sign_update" \
  "${signing_options[@]}" --verify "$staging/appcast.xml"
mkdir "$staging/client"
ditto -x -k "$staging/$archive" "$staging/client"
plutil -extract SUPublicEDKey raw -o "$staging/client-public-key" \
  "$staging/client/TUFF.app/Contents/Info.plist"
swift "$repository_root/Scripts/verify_update.swift" \
  "$staging/appcast.xml" "$staging/$archive" "$staging/client-public-key"
cp "$staging/appcast.xml" "$archive_directory/appcast.xml"
if [[ -n "$provenance" ]]; then cp "$provenance" "$archive_directory/recovery-provenance.json"; fi

echo "created $archive_directory/appcast.xml"
