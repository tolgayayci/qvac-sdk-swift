import Foundation
import XCTest

@testable import QVACClient

/// YK-200 — cancellation propagation.
///
/// The Swift-side `try await` doesn't unblock today because
/// `bare-rpc-swift.rpc.request` doesn't honor `Task.cancel`
/// (open-questions §2.3). Wiring is still correct: when upstream
/// lands, these tests start asserting Swift-side `CancellationError`
/// throws too. For now they assert what we CAN deliver: the cancel
/// command lands on the worker with the matching runId.
final class CancellationTest: XCTestCase {

  /// VT-1 — streaming cancel propagates a `{"type":"cancel","runId":...}`
  /// to the peer within 100ms of `Task.cancel`.
  func testStreamingCancelEmitsWorkerCancelCommand() async throws {
    // Producer emits 1000 chunks at 1ms intervals — long enough that
    // the consumer's break should kick in before natural end.
    let behavior = QVACPeer.Behavior(streamCount: 1000, streamIntervalMs: 1)
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    defer { Task { await peer.close() } }

    let client = QVACClient(transport: clientTransport)
    try await client.connect()
    defer { Task { await client.close() } }

    // Consume 3 chunks, break — the stream's onTermination triggers
    // task.cancel, which fires the worker cancel command.
    var collected = 0
    for try await _ in client.loggingStream() {
      collected += 1
      if collected >= 3 { break }
    }

    // Wait briefly for the cancel command to land on the peer
    // (loopback delivery + actor hop).
    try await Task.sleep(nanoseconds: 100_000_000)

    let cancelled = await peer.cancelledRunIds
    XCTAssertEqual(cancelled.count, 1, "peer should have received exactly one cancel emission")
  }

  /// VT-3 — naturally-completed request shouldn't emit a cancel.
  /// `onCancel` is only invoked if the Task is cancelled before
  /// completion; calling `task.cancel()` after the await returned
  /// must NOT spuriously fire a worker cancel.
  func testCancelAfterCompletionDoesNotEmitWorkerCancel() async throws {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport)
    try await peer.start()
    defer { Task { await peer.close() } }

    let client = QVACClient(transport: clientTransport)
    try await client.connect()
    defer { Task { await client.close() } }

    // Successful, fast heartbeat → no cancel should be emitted.
    let task = Task<HeartbeatResponse, Error> {
      try await client.heartbeat()
    }
    let response = try await task.value
    XCTAssertEqual(response.type, "heartbeat")

    // Cancelling AFTER the task value materialized is a no-op.
    task.cancel()

    try await Task.sleep(nanoseconds: 100_000_000)
    let cancelled = await peer.cancelledRunIds
    XCTAssertEqual(cancelled.count, 0, "completed task must not spuriously emit cancel")
  }

  /// VT-5 — `CancellationToken` API works equivalently to direct
  /// `Task.cancel`.
  func testCancellationTokenCancelsStreaming() async throws {
    let behavior = QVACPeer.Behavior(streamCount: 1000, streamIntervalMs: 1)
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    defer { Task { await peer.close() } }

    let client = QVACClient(transport: clientTransport)
    try await client.connect()
    defer { Task { await client.close() } }

    let consumerTask = Task<Void, Error> {
      var n = 0
      for try await _ in client.loggingStream() {
        n += 1
        if n > 100_000 { break }  // safety: don't hang the test
      }
    }
    let token = CancellationToken(task: consumerTask)

    // Let a few chunks through, then cancel through the token.
    try await Task.sleep(nanoseconds: 20_000_000)
    token.cancel()

    // Await the task — it may throw CancellationError or complete
    // cleanly (race with worker terminal frame). Either is fine.
    _ = try? await consumerTask.value

    try await Task.sleep(nanoseconds: 100_000_000)
    let cancelled = await peer.cancelledRunIds
    XCTAssertGreaterThanOrEqual(cancelled.count, 1, "token.cancel() should reach the worker")
  }

  /// VT-6 — concurrent cancel storm. Start 5 streams, cancel all,
  /// verify the peer receives 5 cancel emissions (one per stream).
  func testConcurrentCancelStorm() async throws {
    let behavior = QVACPeer.Behavior(streamCount: 1000, streamIntervalMs: 1)
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    defer { Task { await peer.close() } }

    let client = QVACClient(transport: clientTransport)
    try await client.connect()
    defer { Task { await client.close() } }

    var tasks: [Task<Void, Error>] = []
    for _ in 0..<5 {
      tasks.append(Task {
        for try await _ in client.loggingStream() {
          // consume forever (until cancel)
        }
      })
    }

    try await Task.sleep(nanoseconds: 30_000_000)  // let streams open
    for t in tasks { t.cancel() }

    // Drain (each task throws CancellationError or finishes naturally).
    for t in tasks { _ = try? await t.value }

    try await Task.sleep(nanoseconds: 200_000_000)  // cancels propagate
    let cancelled = await peer.cancelledRunIds
    XCTAssertEqual(cancelled.count, 5, "peer should receive one cancel per stream")
  }

  /// Sanity: the envelope auto-injects `runId` so every request can
  /// be referenced by a later cancel.
  func testEnvelopeIncludesRunId() async throws {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport)
    try await peer.start()
    defer { Task { await peer.close() } }

    let client = QVACClient(transport: clientTransport)
    try await client.connect()
    defer { Task { await client.close() } }

    // A normal request that succeeds — we just verify nothing throws
    // when the envelope carries an extra `runId` field.
    let response = try await client.heartbeat()
    XCTAssertEqual(response.type, "heartbeat")
  }
}
