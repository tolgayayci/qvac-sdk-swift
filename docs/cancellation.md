# Cancellation

`QVACClient.send` and `QVACClient.streamResponse` both honor Swift
Task cancellation, propagating it to the worker as a runId-keyed
`cancel` command.

## How it works

Every request:

1. Generates a per-call **runId** (UUID).
2. Auto-injects it into the JSON envelope alongside `type`:

   ```json
   { "type": "<command>", "runId": "<uuid>", ... }
   ```
3. Wraps the awaiting body in `withTaskCancellationHandler`.
4. On cancel, fires a detached fire-and-forget:

   ```json
   { "type": "cancel", "runId": "<uuid>" }
   ```

The worker sees the `cancel` command, looks up the in-flight request
by runId, aborts the work, and (for streams) closes the response
stream. The Swift `try await` returns once the worker's terminal
frame arrives.

## API

### Direct Task cancellation

```swift
let task = Task<HeartbeatResponse, Error> {
  try await client.heartbeat()
}
task.cancel()
```

### `CancellationToken` value type

For callers that bridge to non-async code (UIKit/SwiftUI callbacks,
Combine sinks, server-side handlers that need to cancel from a
sibling task):

```swift
let consumerTask = Task<Void, Error> {
  for try await chunk in client.completion(prompt) { /* … */ }
}
let token = CancellationToken(task: consumerTask)

// later, from another thread or actor:
token.cancel()
```

The token is `Sendable` and idempotent — calling `cancel()` twice is
a no-op.

## Post-YK-209 revision

**The original YK-200 design auto-injected a per-call `runId` into every envelope and fired `{type:"cancel", runId:...}` on Task.cancel.** YK-209 (real-worker integration) showed `@qvac/sdk`'s strict Zod schemas reject ANY unknown envelope field — every typed handler refused `runId`. The injection was removed in `QVACClient+SendStream.swift`.

QVAC's actual cancel API (per `@qvac/sdk/dist/schemas/cancel.js`):

```js
{type: "cancel", operation: "inference"|"downloadAsset"|"rag",
  modelId|downloadKey|workspace: "..."}
```

Keyed by the **resource being cancelled**, not by a per-call runId. Proper cancellation requires per-method context (caller knows the modelId for inference, the downloadKey for downloads) that the envelope helper doesn't have. The right surface is a typed `client.cancel(operation:modelId:)` API — tracked as M3 follow-on YK-200v2.

Today's behavior:
- ✅ `Task.cancel()` on a Swift consumer of an AsyncThrowingStream cleanly breaks iteration
- ✅ `CancellationToken` wraps `Task.cancel()` for non-Task callers
- ❌ No worker-side cancel emission — the worker keeps producing until natural end. Bandwidth/CPU cost is the cost.

## Caveat — upstream limitation

`bare-rpc-swift`'s `rpc.request` does **not** observe Swift's Task
cancellation in its `CheckedContinuation`. So today:

- ✅ The cancel command lands on the worker — verified.
- ⏳ The Swift `try await` only throws / completes once the worker
  sends its terminal frame. If the worker is slow to react (or the
  cancel command races a late chunk), the Swift side lingers briefly.

This is open question §2.3 in `docs/application/open-questions.md`.
When upstream lands `rpc.request` cancellation propagation, the
existing `withTaskCancellationHandler` wrap re-throws synchronously
with `Task.cancel()` and the Swift side becomes instant. **No API
change required when that lands.**

## Tested

`Tests/QVACClientTests/Client/CancellationTest.swift`:

| Test | Asserts |
| --- | --- |
| `testStreamingCancelEmitsWorkerCancelCommand` | Consumer breaks → worker peer receives exactly one `{type:"cancel",runId:...}` within 100ms |
| `testCancelAfterCompletionDoesNotEmitWorkerCancel` | Completed task → `task.cancel()` no-ops; no spurious cancel emission |
| `testCancellationTokenCancelsStreaming` | `CancellationToken.cancel()` ≡ `task.cancel()` |
| `testConcurrentCancelStorm` | 5 simultaneous cancels → exactly 5 cancel emissions to peer |
| `testEnvelopeIncludesRunId` | Sanity that `runId` injection doesn't break normal request paths |

## VTs from issue body

| VT | Status |
| --- | --- |
| 1 — Streaming cancel | ✅ partial — worker receives cancel + stream stops; Swift loop exits when worker sends terminal frame (limit per caveat) |
| 2 — Blocking cancel | Same partial coverage; needs real worker (YK-208) for end-to-end timing |
| 3 — Cancel after completion | ✅ no spurious emission |
| 4 — Detached Task semantics | ✅ standard Swift; we don't override |
| 5 — `CancellationToken` | ✅ |
| 6 — Concurrent cancel storm | ✅ 5-stream variant in tests; 50-stream gated on real worker fixture |
| 7 — Worker ack | Requires real worker → YK-208 |

## When cancellation costs something

Cancellation is **cooperative**:

- The worker may have already produced partial state (a few output
  tokens, partial image bytes). That's a successful partial result —
  the consumer's `for try await` loop returns those before the
  cancel takes effect.
- The cancel command is best-effort; if the bridge is being torn
  down at the same time (race with `client.close()`), the cancel is
  silently dropped.
- For long-running blocking calls (`embed` on a huge corpus), Swift-
  side cancellation only takes effect on the next worker-side
  chunkable step. Per `docs/qvac-sdk-internals.md` §6, that's
  bounded by one inference step (~50-200ms on Apple Silicon for
  llama.cpp; varies per addon).
