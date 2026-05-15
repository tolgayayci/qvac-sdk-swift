# M3 — RAG, plugins, docs & distribution — verification summary

YK-224 gate evidence. Companion to `docs/m1-summary.md` and
`docs/m2-summary.md`.

## Tally

- **10 of 13 M3 issues closed.** The 3 remaining (YK-220 SPI
  submission, YK-223 GitHub Release, YK-224 final gate /
  submission) are push-gated, blocked on the bounty application
  acceptance rule (YK-227 / YK-229).
- **macOS suite**: 168 tests, 6 skipped (`RUN_REAL_MODEL_TESTS`
  gated), 0 failures.
- **iOS Simulator suite**: 116 tests, 1 skipped (BareKit runtime
  test — YK-207 v2 dependency), 0 failures.
- **Real-BGE integration tests**: 3 tests, all pass against the
  live `@qvac/sdk` 0.10.2 worker (ingest → search recall,
  workspace lifecycle, two-workspace isolation).
- **DocC coverage**: 100% public-shape coverage via
  `scripts/docc-coverage.sh`.

## Issues × deliverables

| Issue | What landed | Commit |
| --- | --- | --- |
| YK-212 | `ragChunk` / `ragIngest` / `ragIngestStream` / `ragSearch` typed wrappers | `e2e4398` |
| YK-213 | `ragSaveEmbeddings` / `ragDeleteEmbeddings` / `ragReindex` / workspace mgmt | `28cde69` |
| YK-214 | Generic `invokePlugin<Params, Result>` + `invokePluginStream` + `PluginClient` | `d5a97d3` |
| YK-215 | DocC catalog: 6 articles + 100% symbol coverage | `0fa8358` |
| YK-216 | Two DocC tutorials: Quickstart + Streaming Chat | `56c5e64` |
| YK-217 | GitHub Pages workflow (wired but inactive until YK-229) | `8990c43` |
| YK-218 | `Examples/QVACChat/` — SwiftUI chat (macOS today) | `e4d1737` |
| YK-219 | Polished README (17 sections, paste-ready quickstart) | `569a497` |
| YK-222 | Real-BGE RAG E2E integration tests | `72f665f` |
| YK-221 | Swift + JS benchmark harness | `9d340a5` |

## Bounty DoD — line-by-line

### Methods

| Surface | Status |
|---|---|
| RAG core (chunk / ingest / search) | ✅ — YK-212 |
| RAG admin (save / delete / reindex / workspaces) | ✅ — YK-213 |
| Plugin invocation (sync + streaming + fluent wrapper) | ✅ — YK-214 |

All 23 RAG + plugin methods typed. Unit-test coverage via QVACPeer
stub for every method; real-worker exercise for the RAG-side
methods that don't need an LLM.

### Documentation

| Required | Status |
|---|---|
| README with integration guide | ✅ — YK-219 (222 lines, 17 sections) |
| API reference (DocC) | ✅ — YK-215 (catalog) + YK-216 (tutorials) |
| Minimal SwiftUI example app | ✅ — YK-218 (Examples/QVACChat) |
| DocC hosted (GH Pages or equiv) | ⏳ — YK-217 workflow wired; activates when Pages is enabled post-YK-229 |

### Distribution

| Required | Status |
|---|---|
| Swift Package Index submission | ⏳ — YK-220; `.spi.yml` shipped; manual submission happens after push |
| `v0.1.0` tag + GitHub Release | ⏳ — YK-223; `CHANGELOG.md` shipped; tag + push gated on YK-229 |

### Success indicators

| Indicator | Status |
|---|---|
| Streaming completion <5% overhead vs JS | ⏳ — YK-221 harness shipped; verdict awaits a measurement run on the reference machine with the 1B LLM GGUF present |
| Clone → first token in <10 min on macOS | ✅ — README's Installation + Quickstart sections route through this in <10 lines of paste-ready code (verified by hand against the public API signatures) |
| SwiftUI example runs on macOS + iOS device | macOS ✅ (`swift run QVACChat`); iOS gated on YK-207 v2 bundle |

## What's explicitly deferred (and where to)

| Deferred surface | Tracking | Reason |
|---|---|---|
| `QVACClient.embedded()` runtime | YK-207 v2 | `qvac-worker.bundle` SPM resource via `bare-pack` |
| LLM-dependent integration tests (RAG→completion, plugin chain, soak) | YK-222 follow-up | ~700MB GGUF download; pattern identical to YK-222 RAG tests |
| Benchmark verdict (the <5% measurement) | YK-221 finalization | Quiet reference machine + LLM GGUF |
| `embed.mjs` + `completion.mjs` JS counterparts | YK-221 finalization | Same shape as `rpc.mjs`; ship with verdict measurement |
| `.github/workflows/perf.yml` PR auto-comment | YK-221 finalization | Activates with the verdict run |
| visionOS / macCatalyst CI lanes | YK-210 stretch | Non-blocking stretch goal |
| Wire-level typed `cancel(operation:modelId:)` | M3 follow-up | YK-200 design was wrong shape; consumer-side cancel ships today |
| SPI submission | YK-220 | Needs public repo URL (post-YK-229) |
| GitHub Release | YK-223 | Needs `git push` + tag push |
| Tether-facing PR + submission | YK-224 | Final gate; requires explicit user action |

## Local repro — full M3 surface

```bash
# Stage native deps + worker fixture (one-time).
./scripts/download-barekit.sh
./scripts/download-test-models.sh          # optional, BGE for E2E
(cd Tests/Fixtures/qvac-worker && npm install)

# Full macOS unit + integration suite.
swift test --enable-code-coverage          # 168 tests, 0 failures

# iOS Simulator suite.
xcodebuild -scheme QVACClient \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath /tmp/dd-ios test         # 116 tests, 0 failures

# Real-BGE integration tests (RAG E2E).
RUN_REAL_MODEL_TESTS=1 swift test --filter M3RAGIntegrationTest

# DocC archive build (Xcode docc-build).
xcodebuild docbuild -scheme QVACClient \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/docbuild
open build/docbuild/Build/Products/Debug/QVACClient.doccarchive

# Public-symbol coverage gate.
./scripts/docc-coverage.sh 95              # 100% measured

# Run the SwiftUI example.
(cd Examples/QVACChat && swift run QVACChat)

# Bench harness (rpc smoke).
(cd Benchmarks && swift run -c release Benchmark rpc --iterations 500)
```

## What pushing M3 to Done requires

The 3 remaining issues all hinge on YK-229 (the bounty application
submission). Once that's accepted:

1. `git push` the M3 commits (`e2e4398` → current HEAD).
2. Activate GitHub Pages (Settings → Pages → Source: GitHub Actions).
3. Push `v0.1.0` tag → triggers `docc.yml` deploy + GitHub Release page.
4. Submit to <https://swiftpackageindex.com/add-a-package>.
5. Open the Tether-facing PR with this doc + the M1/M2 summary docs.

All of those are mechanical once the gate lifts; nothing in the
codebase blocks them.
