# Streaming

Every QVAC method that produces incremental output uses
`AsyncThrowingStream`. The streams honor backpressure end-to-end
and Swift task cancellation cleanly.

## Overview

Five surfaces are streaming today:

- ``QVACClient/completion(modelId:history:options:bufferSize:)`` →
  ``CompletionChunk`` (one frame per token + a final stats frame).
- ``QVACClient/transcribeStream(modelId:audio:options:bufferSize:)``
  → ``TranscriptDelta`` (partial transcripts + a final).
- ``QVACClient/textToSpeech(modelId:text:options:bufferSize:)`` →
  raw audio `Data` chunks.
- ``QVACClient/diffusion(modelId:prompt:options:bufferSize:)`` →
  ``DiffusionStep`` (progress + a final image).
- ``QVACClient/downloadAsset(src:options:bufferSize:)`` →
  ``DownloadProgress`` (bytes-done updates + a final localPath).
- ``QVACClient/ragIngestStream(modelId:workspace:documents:chunk:chunkOpts:progressInterval:bufferSize:)``
  → ``RAGIngestEvent``.
- ``QVACClient/ragReindexStream(workspace:bufferSize:)`` →
  ``RAGReindexEvent``.
- ``QVACClient/invokePluginStream(modelId:handler:params:bufferSize:)``
  → caller-defined `Chunk`.

All return `AsyncThrowingStream<Chunk, Error>`, which conforms to
`AsyncSequence` — so `for try await` works the same way everywhere.

## Backpressure

`bare-rpc` 1.3.1 (the version pinned in our `bare-rpc-swift`
revision) implements wire-level **PAUSE / RESUME** frames. When the
Swift consumer falls behind, the bare-rpc layer signals PAUSE; the
worker stops emitting until the consumer drains and RESUME goes
back. This works without any caller configuration.

For tighter memory bounds, pass a `bufferSize:` to the streaming
method. It picks a `.bufferingNewest(N)` policy on the
`AsyncThrowingStream` continuation, so excess chunks are dropped
oldest-first rather than accumulating. Default is `.unbounded`
(matches the JS SDK's behavior).

```swift
let stream = client.completion(
  modelId: modelId,
  history: history,
  bufferSize: 16)  // drop oldest when consumer falls behind
```

## Cancellation

Two ways to stop a stream from the consumer side:

1. **`break` out of the loop**:
   ```swift
   for try await chunk in stream {
     handle(chunk)
     if shouldStop { break }
   }
   // stream's onTermination tears down the underlying RPC
   ```

2. **`Task.cancel()` on the consuming task**:
   ```swift
   let task = Task {
     for try await chunk in stream {
       handle(chunk)
     }
   }
   // later
   task.cancel()
   ```

Either path triggers the `onTermination` hook the stream registered
when it was opened, which cancels the inner Task driving the wire
read. The RPC stream closes on the next frame boundary.

### Worker-side cancel (`client.cancel(operation:modelId:)`)

The consumer-side cancel above stops Swift from reading further —
the worker doesn't know to stop emitting unless explicitly told.
For long inferences (multi-second completions, large reindexes),
send the worker-side cancel:

```swift
// In progress: a slow completion stream
let task = Task {
  for try await chunk in stream { handle(chunk) }
}

// User clicks Stop:
task.cancel()
try await client.cancel(  // wire-level cancel — M3 followup
  AnyCodable(.object([
    "operation": .string("inference"),
    "modelId": .string(modelId)
  ])))
```

The typed `client.cancel(operation:modelId:)` overload is M3
follow-on work — see `docs/cancellation.md`. The untyped
`AnyCodable` form ships today.

## Common patterns

### Collecting a stream into an array

```swift
let chunks = try await stream.collect()  // custom Sequence helper
```

There's no Stdlib `collect()`; write your own one-liner:

```swift
extension AsyncSequence {
  func collect() async throws -> [Element] {
    try await reduce(into: []) { $0.append($1) }
  }
}
```

### Mapping mid-stream

```swift
let textStream = client.completion(modelId: m, history: h)
  .compactMap { $0.token }  // CompletionChunk → String?
```

Use `compactMap` rather than `map` so the terminal `finish` frame
(which carries stats, not a token) is filtered out.

### Combining streams (timeout)

```swift
let withTimeout = Task {
  try await withThrowingTaskGroup(of: [CompletionChunk].self) { group in
    group.addTask { try await stream.collect() }
    group.addTask {
      try await Task.sleep(nanoseconds: 30_000_000_000)
      throw QVACError.transport(.framingError("timeout"))
    }
    return try await group.next()!
  }
}
```

Cancel-on-timeout is the standard `withThrowingTaskGroup` pattern;
the SDK doesn't reinvent it.
