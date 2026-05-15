# ``QVACClient``

A Swift client for the Tether QVAC on-device AI runtime — load
models, stream completions, embed text, transcribe audio, generate
images, run RAG, and invoke plugins from native Swift.

## Overview

QVACClient connects a Swift app to a Bare-runtime worker hosting
the `@qvac/sdk` JavaScript SDK. The worker runs the actual model
inference; the client exposes typed Swift APIs over a bare-rpc
IPC duplex.

```swift
import QVACClient

let client = try await QVACClient.spawning(
  bareBinary: bareURL,
  workerScript: workerURL)
defer { Task { await client.close() } }

let modelId = try await client.client.loadModel(
  modelId: "llamacpp:Llama-3.2-1B-Inst-Q4_0",
  modelType: "llm",
  modelSrc: "https://example.com/Llama-3.2-1B-Inst-Q4_0.gguf")

let stream = client.client.completion(
  modelId: modelId,
  history: [.init(role: .user, content: "Hello!")])

for try await chunk in stream {
  if let token = chunk.token { print(token, terminator: "") }
}
```

### Two transports, one client

The same `QVACClient` actor supports two transports:

- **`UDSTransport`** — talks to a Bare worker running as a child
  process over a Unix domain socket. The right choice for macOS /
  Linux CLI apps and servers that can spawn processes.
- **`BareKitIPCTransport`** — hosts the Bare worker *in-process*
  via `BareKit.xcframework`. The only choice on iOS (where
  spawning is forbidden) and in sandboxed macOS apps.

`QVACClient.spawning(...)` and `QVACClient.embedded(...)` are
convenience factories that pick the right transport for the
platform and run the `__init_config` handshake.

> Note: `embedded()` requires the `qvac-worker.bundle` SPM resource
> produced by YK-207 v2's `bare-pack` pipeline. The transport itself
> is wired today; until the bundle ships, embedded apps can supply
> their own bundle via
> ``BareKitIPCTransport/init(filename:bundleSource:arguments:)``.

### What runs where

| Layer | Lives in | Built with |
| --- | --- | --- |
| **Swift API surface** | this package | Swift 5.10 |
| **bare-rpc framing** | `bare-rpc-swift` (pinned `3983622`) | Swift |
| **Transport** | `UDSTransport` / `BareKitIPCTransport` | Swift / BareKit ObjC |
| **Worker dispatcher** | `@qvac/sdk` 0.10.2 | Bare JS |
| **Inference engines** | llamacpp, whisper.cpp, sdcpp, parakeet, etc. | C/C++ via N-API |

The Swift client never loads native model code directly — that's the
worker's job. The Swift side stays small and Apple-platform-friendly.

## Topics

### Tutorials

- <doc:Tutorial-Quickstart>
- <doc:Tutorial-StreamingChat>

### Getting started

- ``QVACClient/spawning(bareBinary:workerScript:initConfig:runtimeContext:acceptTimeout:)``
- ``QVACClient/embedded(initConfig:runtimeContext:)``
- <doc:Transports>

### Model lifecycle

- ``QVACClient/loadModel(modelId:modelType:modelSrc:isDelegated:device:initialContext:modelConfig:)``
- ``QVACClient/unloadModel(_:clearStorage:)``
- ``QVACClient/heartbeat()``
- ``QVACClient/close()``

### Inference

- ``QVACClient/completion(modelId:history:options:bufferSize:)``
- ``QVACClient/embed(modelId:input:)-9k5d4``
- ``QVACClient/transcribe(modelId:audio:options:)``
- ``QVACClient/transcribeStream(modelId:audio:options:bufferSize:)``
- ``QVACClient/textToSpeech(modelId:text:options:bufferSize:)``
- ``QVACClient/translate(modelId:text:source:target:options:)``
- ``QVACClient/diffusion(modelId:prompt:options:bufferSize:)``
- ``QVACClient/ocr(modelId:image:options:bufferSize:)``
- ``QVACClient/downloadAsset(src:options:bufferSize:)``

### RAG

- <doc:RAG>
- ``QVACClient/ragIngest(modelId:workspace:documents:chunk:chunkOpts:)``
- ``QVACClient/ragIngestStream(modelId:workspace:documents:chunk:chunkOpts:progressInterval:bufferSize:)``
- ``QVACClient/ragSearch(modelId:workspace:query:topK:candidates:)``
- ``QVACClient/ragChunk(documents:options:)``

### Plugins

- <doc:PluginAuthoring>
- ``QVACClient/invokePlugin(modelId:handler:params:)``
- ``QVACClient/invokePluginStream(modelId:handler:params:bufferSize:)``
- ``PluginClient``

### Error handling

- <doc:ErrorHandling>
- ``QVACError``
- ``QVACClientErrorCode``
- ``QVACServerErrorCode``
- ``QVACTransportError``

### Streaming

- <doc:Streaming>
- ``CompletionChunk``
- ``TranscriptDelta``
- ``DiffusionStep``
- ``DownloadProgress``
- ``RAGIngestEvent``
- ``RAGReindexEvent``
