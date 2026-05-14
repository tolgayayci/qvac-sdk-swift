# Streaming backpressure

`QVACClient`'s streaming methods (`client.completion(...)`,
`client.transcribe(...)`, `client.loggingStream(...)`, etc.) return
`AsyncThrowingStream<Chunk, Error>`. YK-199 adds a `bufferSize:`
parameter to all of them so callers can cap memory under flood. Real
PAUSE/RESUME backpressure (the producer slows down rather than the
buffer dropping chunks) waits on an upstream change to
`bare-rpc-swift` — see "Upstream gap" below.

## API

```swift
// Default — unbounded buffer. Matches JS SDK behavior.
for try await chunk in client.loggingStream() {
  // ...consume as fast or as slow as you want; nothing is dropped,
  // but memory grows if you can't keep up with the producer.
}

// Bounded — caps the AsyncStream buffer at 32 chunks.
for try await chunk in client.loggingStream(bufferSize: 32) {
  // ...if the producer outpaces you sustainably, the OLDEST chunks
  // are silently dropped (via `.bufferingNewest(32)`).
}
```

The same `bufferSize:` argument is on every generated stream and
duplex method in `Sources/QVACClient/Generated/Client+Methods.swift`.

## Buffering policy mapping

| `bufferSize` argument | `AsyncStream.Continuation.BufferingPolicy` | Behavior under flood |
| --- | --- | --- |
| `nil` *(default)* | `.unbounded` | All chunks delivered; memory grows; risk of OOM on long, fast streams |
| `N > 0` | `.bufferingNewest(N)` | At most `N` chunks pending; oldest dropped first; consumer always sees the most recent chunks |

`.bufferingOldest(N)` (drop newest under flood) isn't currently
exposed — it's almost never useful for AI streaming (token streams
care about completeness or freshness, not "the first 32 tokens").
File a request if you have a use case.

## When to set a bufferSize

| Use case | Recommendation |
| --- | --- |
| Token-completion stream you'll consume in a TextField | `nil` (unbounded) — typical LLM throughput is well below what a UI can render; OOM risk is negligible |
| Logs / telemetry stream feeding a SwiftUI list | `bufferSize: 256` — caps memory; the UI usually only shows the last few hundred lines anyway |
| Long-running transcription with a slow consumer | `bufferSize: 64` — the worker will keep producing audio frames even if you're behind, but you cap the lag |
| Diffusion image-byte stream where every byte matters | `nil` and consume on a dedicated Task — no flood-dropping; let the consumer drive the pace |

## How chunks are reframed

The bridge reads bare-rpc `STREAM|DATA` frames, accumulates bytes into
a UTF-8 buffer, splits on `\n` (QVAC streams are newline-delimited
JSON), and decodes each complete line into `Chunk` via the codec.
Yields land on the `AsyncThrowingStream` continuation; that's where
the bufferingPolicy applies.

```
  worker producer ──▶ bare-rpc DATA frames ──▶ bridge buffer (String)
                                                    │
                                          split on `\n`, decode
                                                    │
                                                    ▼
                                  AsyncThrowingStream.continuation.yield
                                          │
                              bufferingPolicy applied here
                                          │
                                          ▼
                                  for-await consumer
```

`buffer` (the bridge's UTF-8 String accumulator) is bounded only by
the chunk size since it's drained on each iteration. The
AsyncStream's continuation buffer is where `bufferSize` lives.

## Upstream gap — full PAUSE/RESUME

`bare-rpc-swift` ships `cork() / uncork()` on `OutgoingStream` (the
**producer** side) but not on `IncomingStream`. So the consumer-side
SDK has no public hook to send PAUSE / RESUME to the peer:

```bash
$ grep -rn "func cork\|func uncork" .build/checkouts/bare-rpc-swift/Sources/
.build/checkouts/bare-rpc-swift/Sources/BareRPC/OutgoingStream.swift:51:  func cork() {
.build/checkouts/bare-rpc-swift/Sources/BareRPC/OutgoingStream.swift:55:  func uncork() {
```

The bare-rpc wire protocol supports bidirectional PAUSE/RESUME flags
(PR #13 work), but the Swift API only exposes them on the OutgoingStream.
This means our consumer-side buffering is necessarily lossy under
sustained flood — we can't tell the producer to slow down, only stop
listening.

**Tracking**: `docs/application/open-questions.md` §3.3 asks Tether
about the upstream priority. When `IncomingStream.cork() / uncork()`
lands, `RPCBridge.streamResponse` grows a real flow-controller actor
that cork()'s the underlying stream when the AsyncStream buffer
fills (high watermark) and uncork()'s when it drains (low
watermark) — the design sketched in the YK-199 issue body.

Until then: `bufferSize: nil` matches JS behavior (no consumer-driven
backpressure); `bufferSize: N` is the partial-fix knob.

## VTs

`Tests/QVACClientTests/Client/BackpressureTest.swift`:

| VT (issue body) | Method | Status |
| --- | --- | --- |
| 1 — Slow consumer triggers PAUSE | — | **Deferred** — needs upstream `IncomingStream.cork()` |
| 2 — Resume on drain | — | **Deferred** — same |
| 3 — No OOM under flood | `testBoundedBufferDropsOldestUnderFlood` | ✅ — `bufferSize: 4` caps buffer |
| 4 — Tear-down mid-flood | covered by `QVACClientTest.testStreamingDeliversAllChunks` consumer-cancel path (the stream task is cancelled when consumer breaks; transport stays alive) | already tested |
| 5 — Concurrent streams | — | Could add; gated on real worker (YK-208) for a meaningful test |
| 6 — Hysteresis | — | **Deferred** — needs PAUSE/RESUME |
| 7 — Throughput parity | — | **YK-221 (M3)** owns this |

Three tests:

- `testUnboundedBufferKeepsAllChunks` — `bufferSize: nil` delivers all 20 chunks (no loss)
- `testBoundedBufferDropsOldestUnderFlood` — `bufferSize: 4` against a 50-chunk flood + 5ms-per-chunk consumer; assertions: subset of 50 received, FIFO order preserved
- `testTinyBufferDoesNotCrash` — `bufferSize: 1` against 100-chunk flood; sanity that the tightest buffer is well-defined

## Why not a flow-controller actor today?

The issue body sketches an actor that tracks `pendingChunks`, calls
`cork()` past a high watermark, `uncork()` below a low watermark.
That's the right design — but it requires `IncomingStream.cork() /
uncork()`, which doesn't exist. Implementing the actor without the
underlying hooks would be misleading: the assertions in tests would
claim "PAUSE delivered" when no PAUSE frame actually went on the
wire. Better to leave the design slot empty in code and obvious in
the doc, then fill in the real implementation once upstream lands.
