# QVACClient

Native Swift client for Tether's [QVAC](https://github.com/tetherto/qvac) on-device AI runtime. Run completions, embeddings, transcription, TTS, translation, OCR, diffusion, RAG, and plugins from Swift — no JS bridge.

[![swift 5.10](https://img.shields.io/badge/swift-5.10%2B-orange)](https://swift.org)
[![platforms](https://img.shields.io/badge/platforms-macOS%2014%2B%20%7C%20iOS%2017%2B-blue)]()
[![license](https://img.shields.io/badge/license-Apache--2.0-blue)](./LICENSE)

## Install

```swift
.package(
  url: "https://github.com/tolgayayci/qvac-sdk-swift.git",
  from: "0.1.0"
)
```

Then add `"QVACClient"` to your target's dependencies. One-time native deps stage:

```bash
./scripts/download-barekit.sh    # ~20MB BareKit.xcframework, gitignored
```

## Hello, streaming completion

```swift
import QVACClient

let spawned = try await QVACClient.spawning(
  bareBinary: bareURL, workerScript: workerURL)
defer { Task { await spawned.close() } }

let modelId = try await spawned.client.loadModel(
  modelSrc: "https://huggingface.co/.../Llama-3.2-1B-Instruct-Q4_0.gguf",
  modelType: "llm")

let stream: AsyncThrowingStream<CompletionChunk, Error> =
  spawned.client.completion(
    modelId: modelId,
    history: [.user("Hello!")],
    bufferSize: nil)

for try await chunk in stream {
  if case .token(let token) = chunk { print(token, terminator: "") }
}
```

## What's in the box

| Surface | Methods |
| --- | --- |
| **Lifecycle** | `loadModel` · `unloadModel` · `heartbeat` · `close` · `cancel` |
| **Completion** | `completion` (blocking + streaming) |
| **Embeddings** | `embed` (single + batch) |
| **Speech** | `transcribe` · `transcribeStream` · `textToSpeech` |
| **Vision** | `translate` · `diffusion` · `ocr` · `downloadAsset` |
| **RAG** | `ragChunk` · `ragIngest` · `ragIngestStream` · `ragSearch` · `ragSaveEmbeddings` · `ragDeleteEmbeddings` · `ragReindex` · `ragListWorkspaces` · `ragCloseWorkspace` · `ragDeleteWorkspace` |
| **Plugins** | `invokePlugin<P, R>` · `invokePluginStream<P, C>` · fluent `client.plugin(modelId:)` |
| **Errors** | `QVACError.{client, server, transport, unknown}` (116 codegen'd codes) |

Every method is `async throws`. Streaming methods return `AsyncThrowingStream` (which conforms to `AsyncSequence`). API surface mirrors [`@qvac/sdk`](https://docs.qvac.tether.io/sdk/api/) 0.10.2.

## Transports

| Factory | Use when |
| --- | --- |
| `QVACClient.spawning(bareBinary:workerScript:)` | macOS / Linux CLI apps, servers, dev — anywhere you can spawn a subprocess. |
| `QVACClient.embedded()` | iOS apps + sandboxed macOS apps. Hosts the worker in-process via `BareKit.xcframework`. |

Both factories run `__init_config` for you and return a ready client. See [`docs/embedding.md`](./docs/embedding.md) for the deeper dive.

## Streaming + cancellation

```swift
let task = Task {
  for try await chunk in stream {
    if case .token(let t) = chunk { print(t, terminator: "") }
  }
}

// later — consumer-side cancel tears down the RPC stream:
task.cancel()
```

For tighter memory bounds, pass `bufferSize:` to switch from unbounded to `.bufferingNewest(N)`. Wire-level worker cancel via `client.cancel(operation:modelId:)` — see [`docs/cancellation.md`](./docs/cancellation.md).

## Errors

```swift
do {
  let id = try await client.loadModel(modelSrc: url, modelType: "llm")
} catch let err as QVACError {
  switch err {
  case .client(let code, let msg): print("Bad request: \(code.wireName) \(msg)")
  case .server(let code, let msg): print("Inference failed: \(code.wireName) \(msg)")
  case .transport(.transportClosed): print("Worker disconnected.")
  case .transport(let t):            print("Transport: \(t.message)")
  case .unknown(_, let name, let msg): print("Unknown: \(name ?? "?") \(msg)")
  }
}
```

## Examples

- **[`Examples/QVACChat`](./Examples/QVACChat)** — SwiftUI chat app with streaming + cancel + error banner. `cd Examples/QVACChat && swift run QVACChat`.
- **DocC tutorials** — Quickstart (10 min) + Streaming Chat (25 min). Open the archive in Xcode after `xcodebuild docbuild -scheme QVACClient`.

## Documentation

- **API reference (DocC)** — `xcodebuild docbuild -scheme QVACClient -derivedDataPath build/docbuild` then open `QVACClient.doccarchive` in Xcode. Hosted: `https://tolgayayci.github.io/qvac-sdk-swift/documentation/qvacclient/`.
- **Deep dives** — [architecture](./docs/qvac-sdk-internals.md) · [wire protocol](./docs/bare-rpc-wire.md) · [BareKit](./docs/barekit.md) · [streaming](./Sources/QVACClient/QVACClient.docc/Streaming.md) · [RAG](./Sources/QVACClient/QVACClient.docc/RAG.md) · [plugins](./Sources/QVACClient/QVACClient.docc/PluginAuthoring.md).

## Platform support

macOS 14+ (arm64) and iOS 17+ (arm64), both CI-tested. Linux x86_64 builds cleanly (codec + framing tested; subprocess spawn untested in CI).

## Compared to

| | QVACClient | [Llama.rn](https://github.com/mybigday/llama.rn) | [Cactus](https://github.com/cactus-compute/cactus) | [react-native-executorch](https://github.com/software-mansion/react-native-executorch) |
| --- | --- | --- | --- | --- |
| Language | Swift | JS via RN bridge | JS via RN bridge | JS via RN bridge |
| Engines | llama.cpp · whisper · sdcpp · parakeet · bergamot (via QVAC) | llama.cpp | llama.cpp + diffusion | ExecuTorch |
| Modalities | Text · audio · image · video · RAG | Text | Text + image | Text + image |
| RAG built-in | ✅ | ❌ | ❌ | ❌ |
| Plugin system | ✅ | ❌ | ❌ | ❌ |
| Native API | `async/await` + `AsyncSequence` | JS promises | JS promises | JS promises |

## Contributing

```bash
# Codegen (regenerates Sources/QVACClient/Generated/).
pnpm -C scripts/codegen run run

# Tests — macOS.
swift test

# Tests — iOS Simulator.
xcodebuild -scheme QVACClient \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath $TMPDIR/dd-ios test
```

## License

Apache-2.0 — matches QVAC and Holepunch upstream. See [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

Built on [`bare-rpc-swift`](https://github.com/holepunchto/bare-rpc-swift) and [`BareKit`](https://github.com/holepunchto/bare-kit) by Holepunch.
