# Real-model integration tests (`RealModelIntegrationTest`)

YK-209's "no mocks" deliverable: tests that load a real GGUF model
into a real `@qvac/sdk` worker (via the YK-208 fixture) and run real
inference, asserting on the real outputs.

## How tests are gated

Real-model tests are opt-in via a flag + cached model file. They
`XCTSkip` when not enabled, so a default `swift test` doesn't pay
the download/inference cost:

```
guard ProcessInfo.processInfo.environment["RUN_REAL_MODEL_TESTS"] == "1" else { XCTSkip(...) }
guard FileManager.default.fileExists(atPath: bgeModel.path) else { XCTSkip(...) }
guard FileManager.default.isExecutableFile(atPath: bareBinary.path) else { XCTSkip(...) }
```

## Local setup

```bash
# 1. Install the worker fixture (~50s one-time)
cd Tests/Fixtures/qvac-worker && npm install && cd -

# 2. Download the test model (~24MB, one-time)
./scripts/download-test-models.sh

# 3. Run real-model tests
RUN_REAL_MODEL_TESTS=1 swift test --filter RealModelIntegrationTest
```

Today's test run takes ~6.8s the first time (loads the model fresh)
and ~0.5-1.5s per test thereafter (model stays loaded between
tests in the same harness instance).

## CI

`.github/workflows/ci.yml` doesn't auto-enable real-model tests
(would require committing model weights or building a cache
restore). Once we have a stable CI cache key for the model file
(YK-211 / M2-GATE work), the macOS-14 job adds:

```yaml
- name: Restore model cache
  uses: actions/cache@v4
  with:
    path: ~/Library/Caches/qvac-tests/models
    key: qvac-test-models-bge-small-v1.5

- name: Real-model integration tests
  env:
    RUN_REAL_MODEL_TESTS: "1"
  run: swift test --filter RealModelIntegrationTest
```

## Model cache layout

| OS | Path |
| --- | --- |
| macOS | `~/Library/Caches/qvac-tests/models/` |
| Linux | `~/.cache/qvac-tests/models/` |

| File | Source | Size | Use |
| --- | --- | --- | --- |
| `bge-small-en-v1.5.Q4_K_M.gguf` | [HuggingFace CompendiumLabs/bge-small-en-v1.5-gguf](https://huggingface.co/CompendiumLabs/bge-small-en-v1.5-gguf) | ~24MB | Real BGE-Small-EN-v1.5 embeddings via `@qvac/embed-llamacpp` |

## Tests currently exercised

`Tests/QVACClientTests/Integration/RealModelIntegrationTest.swift`:

| Test | Asserts |
| --- | --- |
| `testRealBGEEmbedRoundTrip` | Spawn worker → `loadModel` (real BGE) → `embed("hello world")` returns 384-dim vector → not all-zero, no NaN/Inf → `unloadModel` |
| `testRealBGESemanticSimilarity` | Same model → `embed("dog")`, `embed("puppy")`, `embed("airplane")` → cos(dog, puppy) > cos(dog, airplane) |

## What was learned from this real-worker test

Three nontrivial findings the JS reference papered over (worth flagging in `docs/application/open-questions.md` if the upstream contract isn't pinned):

1. **`@qvac/sdk` uses `.strict()` Zod schemas everywhere.** Auto-injecting any envelope field other than `type` causes "unknown field" rejection. YK-200's `runId` design didn't survive — see `docs/cancellation.md` "post-YK-209 revision."
2. **`modelType` must be canonical, not alias.** The JS SDK has an `embeddings` → `llamacpp-embedding` alias table in client code, but the *server-side* strict schemas only accept canonical names. `QVACClient.loadModel` now resolves aliases client-side via `canonicalizeModelType(_:)` in `Lifecycle.swift`.
3. **`modelConfig: {}` is required.** The key must be present (any empty config is fine since every sub-field has a default), but omitting the key fails the strict schema. The `loadModel` wrapper injects an empty object.

## Adding more real-model tests

The same pattern applies to other modalities:

| Modality | Smallest viable model | Approximate size | Plugin |
| --- | --- | --- | --- |
| Embedding | BGE-Small-EN-v1.5 Q4_K_M | ~24MB | `@qvac/embed-llamacpp` (canonical: `llamacpp-embedding`) |
| Completion | TinyLlama-1.1B-Chat-v1.0 Q4_K_M | ~640MB | `@qvac/llm-llamacpp` (canonical: `llamacpp-completion`) |
| Transcription | Whisper-tiny Q5_0 | ~75MB | `@qvac/transcription-whispercpp` (canonical: `whispercpp-transcription`) |
| TTS | Kokoro Q4 | ~80MB | `@qvac/tts-onnx` (canonical: `onnx-tts`) |
| Translation | Bergamot en-fr | ~14MB | `@qvac/translation-nmtcpp` (canonical: `nmtcpp-translation`) |

Adding a new modality: extend `scripts/download-test-models.sh` with the curl URL + new SHA pin, then write a test mirroring `testRealBGEEmbedRoundTrip`'s shape (cache check → spawn worker → loadModel → method call → assert real-output property → unloadModel).
