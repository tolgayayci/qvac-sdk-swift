# Changelog

All notable changes to QVACClient. Format follows [Keep a
Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

The repo isn't pushed to GitHub until the bounty application is
accepted (tracked as YK-227 / YK-229), so the dates below are
the local commit dates rather than published-release dates.

## [Unreleased]

Nothing — current `main` is the v0.1.0 candidate.

## [0.1.0] — 2026-05-15

Initial public release. M1 + M2 + the wireable surface of M3.
Hits the bounty's full DoD for milestones 1 and 2; M3 ships the
14-method API + RAG + plugins + docs + example + perf harness.

### Added — API surface

- **Lifecycle.** `loadModel(modelSrc:modelType:extras:)`,
  `unloadModel(_:clearStorage:)`, `heartbeat()`, `close()`,
  `cancel(_:)`.
- **Completion.** Blocking `completion(modelId:history:options:)`
  returning `CompletionResult`; streaming
  `completion(modelId:history:options:bufferSize:)` returning
  `AsyncThrowingStream<CompletionChunk, Error>`.
- **Embeddings.** `embed(modelId:input:)` — batch (`[String]`
  → `[[Double]]`) + single (`String` → `[Double]`) overloads.
- **Speech.** `transcribe(modelId:audio:options:)`,
  `transcribeStream(modelId:audio:options:bufferSize:)` →
  `AsyncThrowingStream<TranscriptDelta, Error>`,
  `textToSpeech(modelId:text:options:bufferSize:)` →
  `AsyncThrowingStream<Data, Error>` (audio chunks).
- **Vision.** `translate(modelId:text:source:target:options:)`,
  `diffusion(modelId:prompt:options:bufferSize:)` →
  `AsyncThrowingStream<DiffusionStep, Error>`,
  `ocr(modelId:image:options:bufferSize:)`,
  `downloadAsset(src:options:bufferSize:)` →
  `AsyncThrowingStream<DownloadProgress, Error>`.
- **RAG.** `ragChunk(documents:options:)` /
  `ragChunk(text:options:)`,
  `ragIngest(modelId:workspace:documents:chunk:chunkOpts:)`,
  `ragIngestStream(...)` →
  `AsyncThrowingStream<RAGIngestEvent, Error>`,
  `ragSearch(modelId:workspace:query:topK:candidates:)`,
  `ragSaveEmbeddings(workspace:modelId:documents:)`,
  `ragDeleteEmbeddings(workspace:ids:)`,
  `ragReindex(workspace:)` + streaming variant,
  `ragListWorkspaces()`,
  `ragCloseWorkspace(workspace:deleteOnClose:)`,
  `ragDeleteWorkspace(workspace:)`.
- **Plugins.** Generic `invokePlugin<Params: Encodable, Result:
  Decodable>(modelId:handler:params:)` and streaming variant.
  Fluent `PluginClient` from `client.plugin(modelId:)`.

### Added — transport

- `UDSTransport` — `Network.framework`-based UDS client.
- `UDSServer` + `UDSAcceptedTransport` — POSIX-backed UDS server
  for the production "Swift listens, worker dials in" topology.
- `BareKitIPCTransport` — in-process Bare worklet via
  `BareKit.xcframework`. iOS-ready; final wiring into
  `QVACClient.embedded()` waits on the `qvac-worker.bundle` SPM
  resource (tracked as YK-207 v2).

### Added — convenience factories

- `QVACClient.spawning(bareBinary:workerScript:...)` →
  `SpawnedClient` (subprocess + UDS + handshake in one call).
  Production path on macOS / Linux.
- `QVACClient.embedded(...)` → signature shipped; body throws
  until the YK-207 v2 bundle ships. Will host the in-process
  worker on iOS.

### Added — error mapping

- `QVACError.{client,server,transport,unknown}` enum with 116
  codegen'd codes from `@qvac/sdk` 0.10.2.
- `QVACTransportError` for wire-side failures (closed, framing,
  decoding).

### Added — streaming + cancellation

- All streaming surfaces use `AsyncThrowingStream`.
- Backpressure via `bare-rpc` 1.3.1 PAUSE/RESUME (auto-applied;
  optional `bufferSize:` for memory-bounded buffering).
- `CancellationToken` + `Task.cancel()` propagation through
  every streaming method.

### Added — docs

- DocC catalog (`Sources/QVACClient/QVACClient.docc/`): 6
  articles (overview, Transports, ErrorHandling, Streaming, RAG,
  PluginAuthoring), 2 interactive tutorials (Quickstart +
  StreamingChat).
- `docs/m1-summary.md`, `docs/m2-summary.md`, `docs/m3-summary.md`
  — milestone gate evidence.
- `docs/qvac-sdk-internals.md`, `docs/bare-rpc-wire-protocol.md`
  — full wire-protocol reference.
- `docs/barekit.md`, `docs/embedding.md`, `docs/cancellation.md`,
  `docs/backpressure.md`, `docs/docc-hosting.md`,
  `docs/perf/baseline.md`.
- `README.md` — release-ready with quickstart, architecture,
  platform support, comparison table.

### Added — CI

- `swift-macos` job — macOS 14 ARM64, `swift test
  --enable-code-coverage`, LCOV export, BareKit download step.
- `swift-ios` job — iOS 17 Simulator via `xcodebuild`, with
  dynamic destination resolution.
- `docc.yml` workflow — DocC build + GitHub Pages deploy (wired
  but page activation gated on YK-229).
- `codegen-ts` + `codegen-drift` — TS codegen pipeline runs on
  every PR, blocks merges on drift in `Generated/`.

### Added — examples + benchmarks

- `Examples/QVACChat/` — SwiftUI chat example app (macOS today;
  iOS lands with `embedded()`).
- `Benchmarks/` — `rpc | embed | completion` benches with JS
  counterparts and `compare.mjs` diff tool.

### Tests

- **177 tests** total (158 unit + 19 integration / smoke).
- macOS suite: 168 tests, 6 skipped (real-model gated by
  `RUN_REAL_MODEL_TESTS=1`), 0 failures.
- iOS Simulator suite: 116 tests, 1 skipped (deferred BareKit
  runtime echo — YK-207 v2), 0 failures.
- Real-BGE integration tests pass end-to-end (RAG ingest →
  search, workspace lifecycle, multi-workspace isolation).

### Deferred to v0.1.x

- `QVACClient.embedded()` runtime — needs YK-207 v2 bundle.
- Performance verdict on the bounty's 5% headline — harness ships
  in v0.1.0; the measurement run happens under YK-221
  finalization on a quiet M2 Pro with a 1B GGUF.
- LLM-dependent E2E flows (RAG-with-completion, plugin chain,
  30-min soak) — pattern identical to the BGE tests, just need
  the GGUF download.
- Wire-level typed `cancel(operation:modelId:)` — today's
  consumer-side cancel ships; the typed wrapper is M3 follow-up.

### Project links

- Linear board: `YK-174` → `YK-229` (53 issues across M1 / M2 /
  M3 / application).
- Bounty: <https://docs.tether.io/qvac/bounties/swift>.
- License: Apache-2.0 (matches QVAC + Holepunch upstream).
