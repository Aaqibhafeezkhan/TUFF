#!/usr/bin/env bash
# All ordinary gates are model-free. Model qualification is a separate run.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_directory/.."
Scripts/test.sh
python3 Scripts/test_calibrate_runtime.py
python3 Scripts/test_release_harnesses.py
python3 Scripts/test_benchmark_reporting.py
python3 Scripts/test_route_issue.py
python3 Scripts/test_benchmark_discussions.py
python3 Scripts/test_release_recovery.py
python3 Scripts/test_homebrew.py
ruby Scripts/test_benchmark_simple.rb
ruby Scripts/test_benchmark_v2.rb
ruby Scripts/test_github_config.rb
ruby Scripts/check_github_config.rb
ruby Scripts/check_tracked_symlinks.rb
ruby Scripts/check_markdown_links.rb
ruby Scripts/check_app_version.rb

if [[ "${1:-}" != "--source-only" ]]; then
  version="$(ruby -e 'puts File.read("Sources/TUFFModelCatalog/TUFFVersion.swift")[/static let current\s*=\s*"([^"]+)"/, 1]')"
  Scripts/package_app.sh "$version" dist/check
  python3 Scripts/test_packaging.py --app dist/check/TUFF.app
  python3 Scripts/test_updater_fixtures.py --app dist/check/TUFF.app
fi
