import Foundation
import XCTest

@testable import QVACClient

/// YK-200 — Task cancellation propagation.
///
/// **Revision note (post-YK-209).** The original YK-200 design
/// auto-injected `runId: UUID` into every envelope and fired a
/// `{type:"cancel", runId:...}` on Task.cancel. That broke @qvac/sdk's
/// `.strict()` Zod schemas (verified during YK-209 real-worker
/// testing — every handler rejected `runId` as an unknown field).
///
/// The QVAC SDK's actual cancel surface (per
/// `@qvac/sdk/dist/schemas/cancel.js`) is:
///
///     {type:"cancel", operation:"inference"|"downloadAsset"|"rag",
///      modelId|downloadKey|workspace:"..."}
///
/// Keyed by the resource being cancelled, not by a per-call runId.
/// Proper cancellation requires per-method context (caller knows
/// the modelId for inference, the downloadKey for downloads) that
/// the envelope helper doesn't have.
///
/// The YK-200 wiring is now reverted to "envelope injects only
/// `type`"; `client.cancel(...)` becomes a M3 follow-on (YK-200 v2)
/// that exposes the typed cancel API.
///
/// Today's tests cover the surfaces that still work:
/// - `CancellationToken` value type wraps a Task correctly
/// - Task.cancel on a consumer of an AsyncThrowingStream breaks the
///   iteration cleanly
final class CancellationTest: XCTestCase {

  func testCancellationTokenWrapsTaskCancel() async {
    let task = Task<Int, Never> {
      for i in 0..<100 {
        if Task.isCancelled { return i }
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
      return 100
    }
    let token = CancellationToken(neverThrowingTask: task)

    try? await Task.sleep(nanoseconds: 30_000_000)
    token.cancel()

    let result = await task.value
    XCTAssertLessThan(result, 100, "task should have been cancelled before completing")
  }

  func testStreamConsumerCancelBreaksIteration() async throws {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(
      transport: peerTransport,
      behavior: .init(streamCount: 1000, streamIntervalMs: 1))
    try await peer.start()
    defer { Task { await peer.close() } }

    let client = QVACClient(transport: clientTransport)
    try await client.connect()
    defer { Task { await client.close() } }

    var collected = 0
    for try await _ in client.loggingStream() {
      collected += 1
      if collected >= 3 { break }
    }
    XCTAssertEqual(collected, 3, "consumer break should stop iteration cleanly")
  }
}
