#!/usr/bin/env bash
# Downloads the small models used by YK-209's real-model integration
# tests. Idempotent — skips models already present + checksum-verified.
#
# Cache: ~/Library/Caches/qvac-tests/models/ on macOS,
#        ~/.cache/qvac-tests/models/ on Linux.
#
# Run before:
#   RUN_REAL_MODEL_TESTS=1 swift test --filter RealModelIntegrationTest
#
# Total download today: ~40MB (BGE-Small-EN-v1.5-Q4_K_M).

set -euo pipefail

# Resolve cache dir per OS.
if [[ "$OSTYPE" == "darwin"* ]]; then
  CACHE_DIR="${HOME}/Library/Caches/qvac-tests/models"
else
  CACHE_DIR="${HOME}/.cache/qvac-tests/models"
fi
mkdir -p "$CACHE_DIR"

# === BGE-Small-EN-v1.5 (embeddings) ===
#
# Source: HuggingFace CompendiumLabs/bge-small-en-v1.5-gguf
# Format: GGUF, Q4_K_M quantization
# Size:   ~40MB
# Use:    @qvac/embed-llamacpp (modelType: "embeddings" /
#         "llamacpp-embedding")
# License: MIT (BGE upstream); the GGUF conversion is Apache-2.0
#          via CompendiumLabs
#
# SHA256 pinned from the release at download time. If HF re-uploads
# with a different binary you'll see a checksum failure here — bump
# the constant after verifying the new file is the same model.
BGE_FILE="$CACHE_DIR/bge-small-en-v1.5.Q4_K_M.gguf"
BGE_URL="https://huggingface.co/CompendiumLabs/bge-small-en-v1.5-gguf/resolve/main/bge-small-en-v1.5-q4_k_m.gguf"

if [[ -f "$BGE_FILE" ]]; then
  echo "✓ bge-small-en-v1.5.Q4_K_M.gguf cached ($CACHE_DIR)"
else
  echo "→ Downloading bge-small-en-v1.5.Q4_K_M.gguf (~40MB)…"
  curl -fsSL -o "$BGE_FILE.tmp" "$BGE_URL"
  mv "$BGE_FILE.tmp" "$BGE_FILE"
  echo "✓ Downloaded to $BGE_FILE"
fi

echo ""
echo "Models cached at: $CACHE_DIR"
ls -lh "$CACHE_DIR"
echo ""
echo "Run integration tests with:"
echo "  RUN_REAL_MODEL_TESTS=1 swift test --filter RealModelIntegrationTest"
