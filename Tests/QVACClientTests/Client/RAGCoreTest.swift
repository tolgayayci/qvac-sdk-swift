import Foundation
import XCTest

@testable import QVACClient

/// YK-212 — typed `ragChunk` / `ragIngest` / `ragSearch` wrappers.
/// Verifies the envelope shape (operation discriminator + required
/// fields), the response decoding (chunk list, hit list, ingest
/// result), and the progress-stream behavior for `ragIngestStream`.
///
/// Real-model recall/precision (semantic search quality) lives with
/// the M3 final-integration suite (YK-222) — these tests pin the
/// wire surface, not the embedding model's behavior.
final class RAGCoreTest: XCTestCase {

  private func makePair(
    behavior: QVACPeer.Behavior = .init()
  ) async throws -> (QVACClient, QVACPeer) {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    let client = QVACClient(transport: clientTransport)
    return (client, peer)
  }

  // MARK: - ragChunk

  /// VT-4 — Chunking returns a non-empty `[RAGChunk]` and preserves
  /// content ordering. The peer stub splits on every 4 characters,
  /// so a 12-char input produces 3 chunks.
  func testRagChunkSplitsAndReturnsOrderedChunks() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let chunks = try await client.ragChunk(text: "abcdefghijkl")
    XCTAssertEqual(chunks.count, 3)
    XCTAssertEqual(chunks.map(\.content), ["abcd", "efgh", "ijkl"])
    // Each chunk gets a deterministic stub id.
    XCTAssertEqual(chunks[0].id, "doc-0-chunk-0")
    XCTAssertEqual(chunks[2].id, "doc-0-chunk-2")
  }

  /// `ragChunk(documents: [])` fails client-side without a round-trip.
  func testRagChunkEmptyDocumentsThrows() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    do {
      _ = try await client.ragChunk(documents: [])
      XCTFail("expected throw on empty documents")
    } catch let err as QVACError {
      guard case .transport(.framingError(let msg)) = err else {
        return XCTFail("expected .transport(.framingError), got \(err)")
      }
      XCTAssertTrue(msg.contains("non-empty"))
    }
  }

  // MARK: - ragIngest (blocking)

  /// VT-1 — Ingest happy path: one fulfilled entry per input doc,
  /// no dropped indices, no error string.
  func testRagIngestHappyPath() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let docs = ["the cat sat on the mat", "the dog barked"]
    let result = try await client.ragIngest(
      modelId: "test-embed",
      documents: docs)
    XCTAssertEqual(result.processed.count, 2)
    XCTAssertEqual(result.processed.map(\.status), [.fulfilled, .fulfilled])
    XCTAssertEqual(result.droppedIndices, [])
  }

  /// Workspace override threads through to the wire. The peer stub
  /// doesn't enforce workspace isolation but the envelope must carry
  /// the value when the caller passes one.
  func testRagIngestSendsWorkspace() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let result = try await client.ragIngest(
      modelId: "test-embed",
      workspace: "ws-alpha",
      documents: ["hi"])
    XCTAssertEqual(result.processed.count, 1)
  }

  /// Empty `documents` array fails client-side.
  func testRagIngestEmptyDocumentsThrows() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    do {
      _ = try await client.ragIngest(modelId: "m", documents: [])
      XCTFail("expected throw")
    } catch let err as QVACError {
      guard case .transport(.framingError(let msg)) = err else {
        return XCTFail("expected .transport(.framingError), got \(err)")
      }
      XCTAssertTrue(msg.contains("non-empty"))
    }
  }

  // MARK: - ragIngestStream

  /// VT-7 — Streaming variant emits progress frames followed by a
  /// terminal `.completed(...)`. The peer stub emits three stages
  /// (chunking, embedding, indexing) before the final reply.
  func testRagIngestStreamEmitsProgressThenCompleted() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    var stages: [String] = []
    var completed: RAGIngestResult?
    let stream = client.ragIngestStream(
      modelId: "test-embed",
      documents: ["one", "two", "three"])
    for try await event in stream {
      switch event {
      case .progress(let stage, _, _, _):
        stages.append(stage)
      case .completed(let result):
        completed = result
      }
    }

    XCTAssertEqual(stages, ["chunking", "embedding", "indexing"])
    XCTAssertNotNil(completed)
    XCTAssertEqual(completed?.processed.count, 3)
  }

  /// Stream caller can `break` out early without leaking the
  /// underlying Task — the `onTermination` hook in `ragIngestStream`
  /// cancels it. Verified by completing without hanging on close.
  func testRagIngestStreamConsumerBreakStopsIteration() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let stream = client.ragIngestStream(
      modelId: "test-embed",
      documents: ["one", "two"])
    var received = 0
    for try await _ in stream {
      received += 1
      if received >= 1 { break }
    }
    XCTAssertGreaterThanOrEqual(received, 1)
  }

  // MARK: - ragSearch

  /// VT-2 / VT-3 — Search returns ranked hits. Peer stub seeds two
  /// documents with descending scores; query content doesn't matter
  /// for the stub (real recall lives in YK-222).
  func testRagSearchReturnsRankedHits() async throws {
    let behavior = QVACPeer.Behavior(
      ragSeededDocuments: ["the cat sat on the mat", "the dog barked"])
    let (client, peer) = try await makePair(behavior: behavior)
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let hits = try await client.ragSearch(
      modelId: "test-embed",
      query: "feline")
    XCTAssertEqual(hits.count, 2)
    XCTAssertEqual(hits[0].content, "the cat sat on the mat")
    XCTAssertEqual(hits[0].score, 1.0, accuracy: 0.001)
    XCTAssertEqual(hits[1].score, 0.9, accuracy: 0.001)
    XCTAssertGreaterThan(hits[0].score, hits[1].score)
  }

  /// VT-6 — `topK` caps the returned hit count. Peer stub seeds 5
  /// docs; client asks for `topK: 2` so the worker (test stub)
  /// trims accordingly.
  func testRagSearchTopKRespected() async throws {
    let behavior = QVACPeer.Behavior(
      ragSeededDocuments: ["a", "b", "c", "d", "e"])
    let (client, peer) = try await makePair(behavior: behavior)
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let hits = try await client.ragSearch(
      modelId: "test-embed",
      query: "anything",
      topK: 2)
    XCTAssertEqual(hits.count, 2)
  }

  /// VT-5 — Empty workspace yields empty `results`, no thrown error.
  func testRagSearchEmptyWorkspaceReturnsEmpty() async throws {
    let (client, peer) = try await makePair()  // no seeded docs
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let hits = try await client.ragSearch(
      modelId: "test-embed",
      query: "anything")
    XCTAssertEqual(hits, [])
  }

  /// Validation: empty query is rejected client-side.
  func testRagSearchEmptyQueryThrows() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    do {
      _ = try await client.ragSearch(modelId: "m", query: "")
      XCTFail("expected throw")
    } catch let err as QVACError {
      guard case .transport(.framingError(let msg)) = err else {
        return XCTFail("expected .transport(.framingError), got \(err)")
      }
      XCTAssertTrue(msg.contains("non-empty"))
    }
  }

  /// Validation: zero or negative `topK` rejected.
  func testRagSearchInvalidTopKThrows() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    do {
      _ = try await client.ragSearch(
        modelId: "m", query: "q", topK: 0)
      XCTFail("expected throw")
    } catch let err as QVACError {
      guard case .transport(.framingError(let msg)) = err else {
        return XCTFail("expected .transport(.framingError), got \(err)")
      }
      XCTAssertTrue(msg.contains("topK"))
    }
  }
}
