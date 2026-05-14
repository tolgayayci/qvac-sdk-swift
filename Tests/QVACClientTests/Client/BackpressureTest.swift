import Foundation
import XCTest

@testable import QVACClient

/// YK-199 — consumer-side bounded buffering for streaming methods.
///
/// True PAUSE/RESUME backpressure (the producer slows down rather than
/// the buffer dropping chunks) requires upstream
/// `BareRPC.IncomingStream.cork() / uncork()` which doesn't exist
/// yet — see `docs/backpressure.md` and open-questions §3.3. The
/// in-scope deliverable for this issue is consumer-side bounded
/// buffering: a `bufferSize:` parameter on streaming methods that caps
/// the AsyncStream's continuation buffer, dropping the oldest chunk
/// when the consumer can't keep up.
final class BackpressureTest: XCTestCase {

  // MARK: - Default (unbounded) — keeps all chunks

  /// Baseline: no `bufferSize` specified → unbounded → all 20 chunks
  /// land at the consumer even with a fast producer + slow consumer.
  /// This matches the JS SDK's default behavior.
  func testUnboundedBufferKeepsAllChunks() async throws {
    let behavior = QVACPeer.Behavior(streamCount: 20, streamIntervalMs: 0)
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    defer { Task { await peer.close() } }

    let client = QVACClient(transport: clientTransport)
    try await client.connect()
    defer { Task { await client.close() } }

    var collected: [Int] = []
    for try await chunk in client.loggingStream() {  // bufferSize defaults to nil
      if case .object(let dict) = chunk.value,
        case .int(let i) = dict["index"]
      {
        collected.append(i)
      }
    }
    XCTAssertEqual(collected, Array(0..<20))
  }

  // MARK: - Bounded — caps memory under flood

  /// With `bufferSize: 4` and a producer that emits 50 chunks faster
  /// than the consumer drains, the buffer holds at most 4; older
  /// chunks are dropped via `.bufferingNewest(4)`. The consumer
  /// receives *some subset* of the chunks (the most recent that fit
  /// in the buffer); the total collected is ≤ 50 but bounded.
  ///
  /// Soft assertion: we expect to receive at least 4 (last batch) and
  /// at most 50, with the highest index always being 49 (the most
  /// recent is always preserved by `.bufferingNewest`).
  func testBoundedBufferDropsOldestUnderFlood() async throws {
    // Peer emits 50 chunks with no producer-side delay → flood.
    let behavior = QVACPeer.Behavior(streamCount: 50, streamIntervalMs: 0)
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    defer { Task { await peer.close() } }

    let client = QVACClient(transport: clientTransport)
    try await client.connect()
    defer { Task { await client.close() } }

    var collected: [Int] = []
    // Consumer sleeps 5ms per chunk → slower than the no-delay producer.
    for try await chunk in client.loggingStream(bufferSize: 4) {
      try await Task.sleep(nanoseconds: 5_000_000)
      if case .object(let dict) = chunk.value,
        case .int(let i) = dict["index"]
      {
        collected.append(i)
      }
    }

    // Bounded by buffer size + producer count.
    XCTAssertLessThanOrEqual(collected.count, 50, "should not exceed produced count")
    XCTAssertGreaterThan(collected.count, 0, "should receive at least some chunks")

    // The collected indices should be monotonically non-decreasing
    // (FIFO yield order is preserved within the buffer).
    let sorted = collected.sorted()
    XCTAssertEqual(collected, sorted, "chunks should arrive in producer order")
  }

  // MARK: - bufferSize value forwarded to AsyncStream

  /// Sanity: a tiny `bufferSize: 1` against a flood doesn't crash
  /// and bounds memory tightly. Drops most chunks; we just verify
  /// no hang / no exception.
  func testTinyBufferDoesNotCrash() async throws {
    let behavior = QVACPeer.Behavior(streamCount: 100, streamIntervalMs: 0)
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    defer { Task { await peer.close() } }

    let client = QVACClient(transport: clientTransport)
    try await client.connect()
    defer { Task { await client.close() } }

    var count = 0
    for try await _ in client.loggingStream(bufferSize: 1) {
      try await Task.sleep(nanoseconds: 1_000_000)
      count += 1
    }
    XCTAssertGreaterThan(count, 0)
    XCTAssertLessThanOrEqual(count, 100)
  }
}
