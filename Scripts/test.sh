#!/usr/bin/env bash
# Serial test runner. Shared Metal state makes in-process parallel tests
# unreliable. Pass any extra arguments through, for example --filter.
# `--build-only` compiles the package and its tests with the same flags and
# runs nothing, so a later `Scripts/test.sh` reuses the build.

set -e

if [[ "${1:-}" == "--package-path" ]]; then
  shift 2
fi
build_only=false
if [[ "${1:-}" == "--build-only" ]]; then
  build_only=true
  shift
fi

script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_directory/.."

ruby Scripts/check_brand_assets.rb

# SwiftPM does not add the developer Frameworks directory to the compiler's
# import search paths when the active toolchain is Command Line Tools. Tests
# use the system Testing framework, so supply the path for both compilation
# and linking without hard-coding a particular Xcode installation.
developer_directory="$(xcode-select -p)"
frameworks_directory="$developer_directory/Library/Developer/Frameworks"
developer_library_directory="$developer_directory/Library/Developer/usr/lib"
testing_flags=()
if [[ -d "$frameworks_directory/Testing.framework" ]]; then
  testing_flags=(
    -Xswiftc -F -Xswiftc "$frameworks_directory"
    -Xlinker -F -Xlinker "$frameworks_directory"
    -Xlinker -framework -Xlinker Testing
    -Xlinker -rpath -Xlinker "$frameworks_directory"
    -Xlinker -rpath -Xlinker "$developer_library_directory"
  )
fi

#Preview macros are an Xcode design-time feature. Command Line Tools ships the
# SwiftUI declaration but not the PreviewsMacros plugin, while `swift test`
# still builds the Mac executable in DEBUG. Keep previews available to app
# builds and omit only their DEBUG declarations for package tests.
preview_flags=(-Xswiftc -D -Xswiftc TUFF_NO_PREVIEWS)

# Tests that exercise the default app catalog are Gemma regression fixtures.
# A developer's saved GUI selection must not silently turn those into Qwen
# fixtures and change image budgets, model paths, or prompt behavior. Explicit
# test invocations can still override this when they intentionally cover Qwen.
export TUFF_MODEL="${TUFF_MODEL:-gemma4}"

# Model loads in tests hash every time instead of leaving verified-file
# records in the user's Caches folder. VerifiedFileMemoTests use their own.
export TUFF_VERIFIED_FILE_MEMO="${TUFF_VERIFIED_FILE_MEMO:-off}"

# Link against the current SDK so local test builds are stamped like the
# packaged app. Without this, SwiftPM stamps the deployment target (15.0) and
# macOS shows the legacy appearance. See Scripts/package_app.sh.
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
sdk_flags=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk_path")

if [[ "$build_only" == true ]]; then
  exec swift build --build-tests "${testing_flags[@]}" "${preview_flags[@]}" "${sdk_flags[@]}" "$@"
fi
exec swift test --no-parallel "${testing_flags[@]}" "${preview_flags[@]}" "${sdk_flags[@]}" "$@"
