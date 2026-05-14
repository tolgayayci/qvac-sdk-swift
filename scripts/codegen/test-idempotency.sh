#!/usr/bin/env bash
# End-to-end idempotency check for the QVAC Swift codegen.
#
# Runs `pnpm run run` twice into separate tmp directories and asserts the
# outputs are byte-identical via `diff -r`. Catches:
#   - non-deterministic Map/Set iteration order
#   - JSON property re-ordering across runs
#   - timestamp / hostname / absolute-path leaks in generated banners
#   - line-ending or BOM regressions
#
# Used both by:
#   - local devs before commit
#   - CI `codegen-drift` job (.github/workflows/ci.yml) as a second gate
#     after the `git diff --exit-code` check against committed Generated/
#
# Exit code 0 on identical outputs, 1 otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

TMP1="$(mktemp -d -t qvac-codegen-1-XXXXXX)"
TMP2="$(mktemp -d -t qvac-codegen-2-XXXXXX)"
trap 'rm -rf "$TMP1" "$TMP2"' EXIT

echo "==> Run 1 (out: $TMP1)"
pnpm -s exec tsx src/index.ts --out-dir "$TMP1" > /dev/null

echo "==> Run 2 (out: $TMP2)"
pnpm -s exec tsx src/index.ts --out-dir "$TMP2" > /dev/null

echo "==> Diffing"
if diff -r "$TMP1" "$TMP2"; then
  count=$(find "$TMP1" -type f | wc -l | tr -d ' ')
  echo "✓ Idempotent — $count files identical across runs."
  exit 0
else
  echo "✗ Codegen output is NOT idempotent. Diff above." >&2
  exit 1
fi
