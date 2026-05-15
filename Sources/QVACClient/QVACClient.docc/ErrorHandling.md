# Error handling

Every error QVACClient surfaces is a ``QVACError``. Cases distinguish
*where* the error originated — client-side dispatcher, worker-side
plugin, transport, or codec — so callers can branch correctly
without inspecting messages.

## Overview

```swift
public enum QVACError: Error {
  case client(QVACClientErrorCode, message: String)
  case server(QVACServerErrorCode, message: String)
  case transport(QVACTransportError)
  case unknown(code: Int?, name: String?, message: String)
}
```

- ``QVACError/client(_:message:)`` — emitted by the worker's
  dispatcher when the request itself is malformed: missing model
  id, schema validation failure, etc. Codes live in the
  ``QVACClientErrorCode`` enum (50000-series).
- ``QVACError/server(_:message:)`` — emitted by a worker-side
  plugin when inference fails: model not loaded, generation
  cancelled, embedding dimension mismatch, etc. Codes live in
  ``QVACServerErrorCode`` (40000- and 52000-series).
- ``QVACError/transport(_:)`` — emitted by the Swift side when the
  wire itself fails: bridge closed, framing decode failed, init
  config rejected. See ``QVACTransportError``.
- ``QVACError/unknown(code:name:message:)`` — a code the codegen
  hasn't seen yet. The string fields carry whatever the worker
  emitted; treat this as a soft "report and move on" path rather
  than a fatal error.

## Codegen'd error codes

The 116 codes in ``QVACClientErrorCode`` and ``QVACServerErrorCode``
are **generated** from `@qvac/sdk`'s `SDK_CLIENT_ERROR_CODES` and
`SDK_SERVER_ERROR_CODES` arrays via `scripts/codegen`. The CI lane
runs the codegen on every PR and fails on any non-empty git diff
against `Sources/QVACClient/Generated/`. To regenerate locally:

```bash
pnpm -C scripts/codegen run run
```

When the upstream SDK adds a new code, that diff is what surfaces
it; recover by re-running codegen and committing the updated
`ErrorCodes.swift`.

## Handling patterns

```swift
do {
  let modelId = try await client.loadModel(
    modelId: "bge-small-en-v1.5",
    modelType: "embeddings",
    modelSrc: "https://example.com/bge.gguf")
  // … use modelId
} catch let err as QVACError {
  switch err {
  case .client(let code, let msg):
    print("Worker rejected request: \(code) \(msg)")
  case .server(let code, let msg):
    print("Inference failed: \(code) \(msg)")
  case .transport(.transportClosed):
    print("Worker disconnected; reconnect needed")
  case .transport(let t):
    print("Transport error: \(t)")
  case .unknown(let code, let name, let msg):
    print("Unknown SDK error \(name ?? "?") (\(code.map(String.init) ?? "?")): \(msg)")
  }
}
```

The cases follow the bounty's "errors carry worker-side message +
code" requirement — every `.client(...)` / `.server(...)` value
preserves the exact `error.message` field the worker emitted.

## Streaming error semantics

Errors that surface *during* a stream (mid-`completion`,
mid-`ragIngestStream`, etc.) terminate the `AsyncThrowingStream`
with a thrown `QVACError`. Consumers see:

```swift
do {
  for try await chunk in stream {
    handle(chunk)
  }
} catch let err as QVACError {
  // …
}
```

Cancellation from the consumer side (`break` out of the loop or
`Task.cancel()` on the consuming task) is not an error: the stream
finishes normally and the underlying RPC is torn down via the
`onTermination` hook. See <doc:Streaming> for the full lifecycle.

## What's not yet typed

The bounty's wishlist included case-specific errors for
`workspaceClosed`, `pluginNotFound`, `embeddingDimMismatch`, etc.
Today these surface as ``QVACError/server(_:message:)`` cases with
the `@qvac/sdk` worker's stringly-typed `error.message`. Refining
those into dedicated cases is M3-followup work — once the worker
side commits to a stable code for each, the codegen can pick them
up automatically.
