# QVACClient

**Native Swift client for Tether's [QVAC](https://github.com/tetherto/qvac) on-device AI runtime — stream completions, embed text, transcribe audio, generate images, run RAG, and invoke plugins from Swift, with no React Native or JS bridge.**

<!-- Badges activate once the repo is pushed under its final
     org / name (YK-227 application / YK-229 submit). -->
[![ci](https://img.shields.io/github/actions/workflow/status/tolgayayci/qvac-sdk-swift/ci.yml?branch=main&label=ci)](https://github.com/tolgayayci/qvac-sdk-swift/actions/workflows/ci.yml)
[![docc](https://img.shields.io/github/actions/workflow/status/tolgayayci/qvac-sdk-swift/docc.yml?branch=main&label=docc)](https://github.com/tolgayayci/qvac-sdk-swift/actions/workflows/docc.yml)
[![swift 5.10](https://img.shields.io/badge/swift-5.10%2B-orange)](https://swift.org)
[![platforms](https://img.shields.io/badge/platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-blue)]()
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](./LICENSE)

```swift
import QVACClient

let spawned = try await QVACClient.spawning(
  bareBinary: bareURL, workerScript: workerURL)
defer { Task { await spawned.close() } }

let modelId = try await spawned.client.loadModel(
  modelId: "llamacpp:Llama-3.2-1B-Inst-Q4_0",
  modelType: "llm",
  modelSrc: "https://example.com/Llama-3.2-1B-Instruct-Q4_0.gguf")

for try await chunk in spawned.client.completion(
  modelId: modelId,
  history: [.user("Hello, who are you?")]
) {
  if case .token(let token) = chunk { print(token, terminator: "") }
}
```

## Status

| Milestone | State | What landed |
| --- | --- | --- |
| **M1** | ✅ Complete | Codegen pipeline, IPC transport, real `@qvac/sdk` ping fixture, lifecycle methods. 17 issues. |
| **M2** | ✅ Complete | All 14 method wrappers, `__init_config`, backpressure, BareKit transport, iOS CI lane, real BGE embeddings E2E. 16 issues. |
| **M3** | 🟢 In progress | RAG (9 ops), plugins, DocC catalog + tutorials + Pages workflow, example app, perf benchmark, SPI listing, v0.1.0 tag. 13 issues — methods + docs done; example app + perf + final-integration in flight. |

Full milestone-close evidence in [`docs/m1-summary.md`](./docs/m1-summary.md) and [`docs/m2-summary.md`](./docs/m2-summary.md).

## Why QVACClient

Run Tether's QVAC AI **on-device**, from Swift, on Apple platforms:

- **No cloud round-trip.** Models live with the app; inference is local.
- **No JS bridge.** Native Swift `async`/`await` + `AsyncSequence`, no React Native shim.
- **Two transports.** Subprocess (`bare worker.mjs` over UDS) for macOS / Linux CLI + servers; in-process worklet (`BareKit.xcframework`) for iOS apps and sandboxed macOS apps.
- **Full QVAC surface.** Every method from the JS SDK — completion, embed, transcribe, TTS, translate, OCR, diffusion, RAG, plugins — typed and discoverable in autocomplete.

## Architecture

```
   ┌────────────────────────────────────────────┐
   │  Your Swift app (CLI / SwiftUI / server)   │
   └──────────────────────┬─────────────────────┘
                          │ import QVACClient
   ┌──────────────────────▼─────────────────────┐
   │  QVACClient                                │
   │  – 14 typed methods (loadModel, completion │
   │    streaming, embed, transcribe, …)        │
   │  – QVACError mapping 116 wire codes        │
   │  – CancellationToken + AsyncThrowingStream │
   └──────────────────────┬─────────────────────┘
                          │ bare-rpc framing
   ┌──────────────────────▼─────────────────────┐
   │  Transport — pick one:                     │
   │  • UDSTransport / UDSServer  (macOS CLI)   │
   │  • BareKitIPCTransport       (iOS apps)    │
   └──────────────────────┬─────────────────────┘
                          │ Unix sockets / BareKit pipe
   ┌──────────────────────▼─────────────────────┐
   │  Bare worker hosting @qvac/sdk 0.10.2      │
   │  Dispatches to native engines via N-API    │
   └──────────────────────┬─────────────────────┘
                          │
   ┌──────────────────────▼─────────────────────┐
   │  Native: llama.cpp, whisper.cpp, sdcpp,    │
   │  parakeet, bergamot, hyperdb (RAG store)   │
   └────────────────────────────────────────────┘
```

The Swift side stays small and Apple-platform-friendly; the Bare worker does all the heavy native work. See [Transports](./Sources/QVACClient/QVACClient.docc/Transports.md) for when to pick which.

## Installation

### Swift Package Manager

In your `Package.swift`:

```swift
dependencies: [
  .package(
    url: "https://github.com/tolgayayci/qvac-sdk-swift.git",
    from: "0.1.0"
  )
]
```

Then add `"QVACClient"` to the dependencies of any target.

### Xcode

File → Add Package Dependencies → paste `https://github.com/tolgayayci/qvac-sdk-swift.git` → choose version → add to target.

### One-time setup

QVACClient needs `BareKit.xcframework` (~20MB) staged locally before `swift build`:

```bash
./scripts/download-barekit.sh
```

The script is idempotent. On CI it runs as a workflow step (see [`.github/workflows/ci.yml`](./.github/workflows/ci.yml)).

## Platform support

| Platform | Version | Transport | Status |
| --- | --- | --- | --- |
| **macOS** | 14+ (arm64) | `UDSTransport` via `spawning(...)` factory | ✅ |
| **iOS** | 17+ (arm64) | `BareKitIPCTransport` via `embedded(...)` factory | 🟢 transport wired; bundle pipeline = YK-207 v2 |
| **Linux** | x86_64 (Ubuntu 22.04+) | `UDSTransport` | ✅ codec + framing tested; subprocess spawn untested in CI |
| **iPadOS / visionOS / Catalyst** | — | same as iOS | Untested; build-only |

CI: macOS 14 (arm64) + iOS 17 Simulator on every PR.

## Public API

All methods are `async throws`. Streaming methods return `AsyncThrowingStream`.

| Surface | Methods |
| --- | --- |
| **Lifecycle** | `loadModel`, `unloadModel`, `heartbeat`, `close`, `cancel` |
| **Completion** | `completion` (blocking + streaming) |
| **Embeddings** | `embed` (single + batch) |
| **Speech** | `transcribe`, `transcribeStream`, `textToSpeech` |
| **Vision** | `translate`, `diffusion`, `ocr`, `downloadAsset` |
| **RAG** | `ragChunk`, `ragIngest`, `ragIngestStream`, `ragSearch`, `ragSaveEmbeddings`, `ragDeleteEmbeddings`, `ragReindex`, `ragReindexStream`, `ragListWorkspaces`, `ragCloseWorkspace`, `ragDeleteWorkspace` |
| **Plugins** | `invokePlugin<Params, Result>`, `invokePluginStream<Params, Chunk>`, fluent `client.plugin(modelId:)` wrapper |
| **Errors** | `QVACError.{client, server, transport, unknown}` (116 codegen'd codes) |

Full reference in DocC (link below). API surface mirrors [`@qvac/sdk`](https://docs.qvac.tether.io/sdk/api/) 0.10.2.

## Choosing a transport

| Pick | When |
| --- | --- |
| `QVACClient.spawning(bareBinary:workerScript:)` | macOS / Linux CLI apps, servers, dev — anywhere you can spawn a subprocess. Most production callers want this. |
| `QVACClient.embedded()` | iOS apps, sandboxed macOS apps. Hosts the worker in-process via `BareKit.xcframework`. Lands fully when the bundle pipeline ships (YK-207 v2); transport itself is wired today. |

Both factories run the `__init_config` handshake before returning. See [`docs/embedding.md`](./docs/embedding.md) and [`docs/test-worker.md`](./docs/test-worker.md).

## Performance

The bounty's headline target is *"streaming completion latency overhead Swift vs JS client on same machine < 5%"*. The benchmark suite ([YK-221](https://linear.app/yk-labs/issue/YK-221), in flight) runs Llama-3.2-1B side-by-side via the Swift client and the upstream JS SDK and reports tokens-per-second + TTFT deltas.

Suite status, last run, and methodology will live under [`docs/perf/`](./docs/perf/) once the benchmark suite lands.

## Compared to

| | QVACClient | [Llama.rn](https://github.com/mybigday/llama.rn) | [Cactus](https://github.com/cactus-compute/cactus) | [react-native-executorch](https://github.com/software-mansion/react-native-executorch) |
| --- | --- | --- | --- | --- |
| **Language** | Swift | JS via RN bridge | JS via RN bridge | JS via RN bridge |
| **Inference engine** | llama.cpp / whisper / sdcpp / parakeet / bergamot (via QVAC) | llama.cpp only | llama.cpp + diffusion | ExecuTorch |
| **Modalities** | Text, audio, image, video, RAG | Text only | Text + image | Text + image |
| **RAG built-in** | ✅ (`ragIngest`/`ragSearch`/…) | ❌ | ❌ | ❌ |
| **Plugin system** | ✅ (`@qvac/sdk` plugin manifest) | ❌ | ❌ | ❌ |
| **iOS support** | ✅ (via BareKit, no JS bridge) | ✅ (RN bridge) | ✅ (RN bridge) | ✅ (RN bridge) |
| **macOS support** | ✅ (subprocess) | Limited | Limited | Limited |
| **Native API surface** | Swift `async/await` + `AsyncSequence` | JS promises through RN | JS promises through RN | JS promises through RN |

Positioning matches Tether's framing in the QVAC docs.

## Examples

- **`Examples/QVACChat/`** — SwiftUI chat app exercising load → stream → cancel → unload (YK-218).
- **DocC tutorials** — Quickstart + Streaming Chat, paste-ready in 10 / 25 minutes.

## Documentation

- **DocC site** (post-YK-229): `https://tolgayayci.github.io/qvac-sdk-swift/documentation/qvacclient/`
- **Local preview** — `xcodebuild docbuild -scheme QVACClient -derivedDataPath build/docbuild`, then open `QVACClient.doccarchive` in Xcode.
- **Architecture deep-dive** — [`docs/qvac-sdk-internals.md`](./docs/qvac-sdk-internals.md), [`docs/bare-rpc-wire-protocol.md`](./docs/bare-rpc-wire-protocol.md), [`docs/barekit.md`](./docs/barekit.md).
- **Milestone summaries** — [`docs/m1-summary.md`](./docs/m1-summary.md), [`docs/m2-summary.md`](./docs/m2-summary.md).
- **Per-feature** — [embedding](./docs/embedding.md), [codec](./docs/codec.md), [cancellation](./docs/cancellation.md), [backpressure](./docs/backpressure.md), [DocC hosting](./docs/docc-hosting.md).

## Contributing

This repo is the Tether bounty submission ([proposal](https://docs.tether.io/qvac/bounties/swift)). Before final acceptance the canonical work happens here; after acceptance it moves to whatever org Tether designates.

Day-to-day:

```bash
# Run the codegen (regenerates Sources/QVACClient/Generated/).
pnpm -C scripts/codegen run run

# Full suite (macOS).
swift test --enable-code-coverage

# iOS Simulator suite.
xcodebuild -scheme QVACClient \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath $TMPDIR/dd-ios test

# DocC archive (Xcode docc-build).
xcodebuild docbuild -scheme QVACClient \
  -destination 'generic/platform=macOS' \
  -derivedDataPath build/docbuild
```

[Linear board](https://linear.app/yk-labs/project/qvac-sdk-swift-tether-bounty-38afaf444ef8) tracks every issue (`YK-174` → `YK-229`).

## License

Apache-2.0. Matches QVAC and Holepunch upstream. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE) for full attribution.

## Acknowledgments

- **[Tether](https://tether.io)** for the QVAC SDK, the bounty, and the on-device AI direction.
- **[Holepunch](https://holepunch.to)** for `bare-rpc-swift`, `bare-kit`, and the entire Bare-runtime ecosystem this project sits on.
- **Anthropic Claude (Opus 4.7)** for paired development.
