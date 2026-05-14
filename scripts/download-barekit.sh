#!/usr/bin/env bash
# Downloads the JavaScriptCore-flavored BareKit.xcframework into
# Vendor/BareKit.xcframework so SPM's .binaryTarget(path:) can pick
# it up. The framework is required by `BareKitIPCTransport`
# (YK-206) for in-process Bare worklet hosting on iOS/macOS apps.
#
# Why JavaScriptCore variant: uses Apple's built-in JS engine instead
# of bundling V8 → ~20MB instead of ~353MB for the macOS slice. Same
# JS surface; suitable for iOS apps where the V8 binary would exceed
# the binary-size budget.
#
# Run before `swift build` if the local Vendor/BareKit.xcframework
# is missing. Gitignored; never committed.

set -euo pipefail

BAREKIT_VERSION="v2.1.0"
PREBUILDS_URL="https://github.com/holepunchto/bare-kit/releases/download/${BAREKIT_VERSION}/prebuilds.zip"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="${REPO_ROOT}/Vendor"
FRAMEWORK_PATH="${VENDOR_DIR}/BareKit.xcframework"

if [[ -d "$FRAMEWORK_PATH" ]]; then
  echo "✓ BareKit.xcframework already at $FRAMEWORK_PATH"
  exit 0
fi

echo "→ Downloading $PREBUILDS_URL …"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL -o "$TMP_DIR/prebuilds.zip" "$PREBUILDS_URL"
unzip -q "$TMP_DIR/prebuilds.zip" -d "$TMP_DIR"

mkdir -p "$VENDOR_DIR"
cp -R "$TMP_DIR/apple-javascriptcore/BareKit.xcframework" "$FRAMEWORK_PATH"

echo "✓ Installed BareKit.xcframework → $FRAMEWORK_PATH"
du -sh "$FRAMEWORK_PATH"
