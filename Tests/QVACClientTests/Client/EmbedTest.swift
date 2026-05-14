import Foundation
import XCTest

@testable import QVACClient

/// YK-203 — typed `embed` wrapper. Tests verify the request-shape
/// + the batch/single-vector response decoding. Real model
/// validation (vector dimensions, semantic similarity) → YK-209.
final class EmbedTest: XCTestCase {

  private func makePair() async throws -> (QVACClient, QVACPeer) {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport)
    try await peer.start()
    let client = QVACClient(transport: clientTransport)
    return (client, peer)
  }

  // MARK: - Batch

  /// VT-1 / VT-2 — Batch input returns N vectors in order.
  func testBatchEmbedReturnsVectorsInOrder() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let inputs = ["apple", "banana", "cherry"]
    let vectors = try await client.embed(modelId: "test-embed", input: inputs)

    XCTAssertEqual(vectors.count, 3)
    // Peer stubs vector[i][0] == i; sanity-check order preserved.
    for (i, vec) in vectors.enumerated() {
      XCTAssertEqual(vec.first, Double(i))
    }
  }

  // MARK: - Single

  /// Single-input convenience overload returns a flat `[Double]`.
  func testSingleInputReturnsFlatVector() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let vec: [Double] = try await client.embed(modelId: "test-embed", input: "hello")
    XCTAssertEqual(vec, [0.0, 0.0, 0.0])  // peer stubs first-input vector
  }

  // MARK: - Validation

  /// VT-4 — Empty input rejected client-side, no RPC sent.
  func testEmptyInputThrows() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    do {
      _ = try await client.embed(modelId: "test", input: [])
      XCTFail("expected throw on empty input")
    } catch let err as QVACError {
      guard case .transport(.framingError(let msg)) = err else {
        return XCTFail("expected .transport(.framingError), got \(err)")
      }
      XCTAssertTrue(msg.contains("non-empty"))
    }
  }
}
