#!/usr/bin/env bash
# Build family-scoped helpers and authenticated archives locally. No upload.
set -euo pipefail
cd "$(dirname "$0")/.."
output="${1:-dist/local-engines}"
key="${2:-dist/private-engine-publisher/signing-key}"
version="${3:-1.0.0}"
mkdir -p "$output" "dist/engine-build-inputs"
output="$(cd "$output" && pwd)"
input="$(cd dist/engine-build-inputs && pwd)"
for family in gemma-affine qwen-hybrid-affine gpt-oss-mxfp4 minimax-affine; do
  TUFF_ENGINE_FAMILY="$family" swift build -c release --product TUFFInferenceEngine
  binary="$(TUFF_ENGINE_FAMILY="$family" swift build -c release --show-bin-path)"
  mkdir -p "$input/$family"
  for product in TUFFInferenceEngine TUFF_TUFFEngine.bundle TUFF_TUFFAppCore.bundle swift-transformers_Hub.bundle swift-crypto_Crypto.bundle swift-nio_NIOPosix.bundle; do
    rm -rf "$input/$family/$product"
    ditto "$binary/$product" "$input/$family/$product"
  done
  echo "built $family"
done
# Restore the normal host configuration, whose metadata registry includes every
# supported model. The package builder contains no inference code.
swift build -c release --product TUFFEnginePackage
binary="$(swift build -c release --show-bin-path)"
package_arguments=("$input" "$output" "$key" "$version")
if [[ -n "${4:-}" ]]; then package_arguments+=("$4"); fi
"$binary/TUFFEnginePackage" "${package_arguments[@]}"
