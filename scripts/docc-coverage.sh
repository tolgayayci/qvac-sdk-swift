#!/usr/bin/env bash
# YK-215 — Public-symbol docstring coverage audit.
#
# Walks Sources/QVACClient/**/*.swift (excluding Generated/),
# counts `public` declarations, and reports how many are missing
# a preceding `///` doc comment. Exits 0 when ≥95% covered.
#
# Run from the repo root: `./scripts/docc-coverage.sh`

set -euo pipefail

cd "$(dirname "$0")/.."

threshold="${1:-95}"
total=0
documented=0
missing=()

# We audit the "shape" public surface — types, top-level methods,
# typealiases, protocols. We skip:
#   * `public let` (stored properties — covered by type doc).
#   * `public var <name>: <Type>` (simple stored properties — same).
#   * `public init` (constructors — covered by type doc + labels).
#   * `public static func name(...)` factories that create the
#     enclosing type (one-line builder pattern; type doc covers).
#   * `public static func ==` (Equatable operator boilerplate).
#   * Methods that satisfy the Transport protocol's requirements
#     (open/close/send + state/incoming properties).
#
# Kept under check: type declarations (struct/class/enum/actor/
# protocol/extension), top-level funcs, typealiases, computed
# `public var foo: Bar { ... }`, and subscripts.
declarations='^[[:space:]]*public[[:space:]]+(static[[:space:]]+|nonisolated[[:space:]]+|final[[:space:]]+|class[[:space:]]+|struct[[:space:]]+|enum[[:space:]]+|actor[[:space:]]+|extension[[:space:]]+|protocol[[:space:]]+|func[[:space:]]+|var[[:space:]]+|typealias[[:space:]]+|subscript[[:space:]]*\()'

# Lines matching this pattern are excluded.
# 1. Equatable / Hashable / Comparable operator implementations.
# 2. Transport protocol requirement implementations.
# 3. Simple stored `var` properties (Type or Type?) — i.e. no body.
# 4. One-line static factories returning the enclosing type
#    (ChatMessage.system/user/assistant style).
exclude_pattern='public[[:space:]]+(static[[:space:]]+func[[:space:]]+(==|<|<=|>|>=|!=|hash\()|func[[:space:]]+(open|close|send)\(|var[[:space:]]+(state|incoming)[[:space:]]*[:{]|var[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*[[:space:]]*:[[:space:]]*[^{=]+\??$|static[[:space:]]+func[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*\(_?[[:space:]]*[a-zA-Z_]*:[[:space:]]*[a-zA-Z]+\)[[:space:]]*->)'

while IFS= read -r -d '' file; do
  # Skip generated code — codegen owns those docstrings.
  if [[ "$file" == *"/Generated/"* ]]; then continue; fi

  # Iterate lines with grep -n to keep line numbers.
  while IFS= read -r match; do
    lineno="${match%%:*}"
    line="${match#*:}"

    # Apply the exclude pattern.
    if [[ "$line" =~ $exclude_pattern ]]; then continue; fi

    # Look at the line above for a `///` comment.
    prev=$((lineno - 1))
    if [[ "$prev" -gt 0 ]]; then
      prev_line=$(sed -n "${prev}p" "$file")
    else
      prev_line=""
    fi

    total=$((total + 1))
    if [[ "$prev_line" =~ ^[[:space:]]*/// ]]; then
      documented=$((documented + 1))
    else
      missing+=("$file:$lineno → $line")
    fi
  done < <(grep -nE "$declarations" "$file" || true)
done < <(find Sources/QVACClient -name '*.swift' -print0)

pct=$(( documented * 100 / total ))
echo ""
echo "Public symbol coverage: $documented / $total = ${pct}%"
echo "Threshold: ${threshold}%"

if [[ "${#missing[@]}" -gt 0 ]]; then
  echo ""
  echo "Undocumented declarations:"
  printf '  %s\n' "${missing[@]}" | head -30
  if [[ "${#missing[@]}" -gt 30 ]]; then
    echo "  ... and $(( ${#missing[@]} - 30 )) more"
  fi
fi

if [[ "$pct" -lt "$threshold" ]]; then
  echo ""
  echo "FAIL: coverage ${pct}% is below threshold ${threshold}%"
  exit 1
fi

echo ""
echo "PASS: coverage ${pct}% meets threshold ${threshold}%"
