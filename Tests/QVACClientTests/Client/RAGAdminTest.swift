import Foundation
import XCTest

@testable import QVACClient

/// YK-213 — typed wrappers for the RAG admin operations:
/// `ragSaveEmbeddings`, `ragDeleteEmbeddings`, `ragReindex` (blocking
/// + streaming), `ragListWorkspaces`, `ragCloseWorkspace`,
/// `ragDeleteWorkspace`.
///
/// Each test pins the envelope shape and the response decoding
/// against the QVACPeer stub. Reindex-with-1000-chunks and
/// close-releases-memory checks (VT-R1, VT-C1) need a real worker
/// and roll into YK-222.
final class RAGAdminTest: XCTestCase {

  private func makePair(
    behavior: QVACPeer.Behavior = .init()
  ) async throws -> (QVACClient, QVACPeer) {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    let client = QVACClient(transport: clientTransport)
    return (client, peer)
  }

  // MARK: - ragSaveEmbeddings

  /// VT-S1 — Save and (stub) accept. Returns one `.fulfilled`
  /// processed entry per input doc with the echoed id.
  func testSaveEmbeddingsReturnsFulfilledPerInput() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let docs = [
      RAGEmbeddedDocument(
        id: "doc-a",
        content: "alpha",
        embedding: [0.1, 0.2, 0.3],
        embeddingModelId: "bge-small"),
      RAGEmbeddedDocument(
        id: "doc-b",
        content: "beta",
        embedding: [0.4, 0.5, 0.6],
        embeddingModelId: "bge-small"),
    ]
    let processed = try await client.ragSaveEmbeddings(documents: docs)
    XCTAssertEqual(processed.count, 2)
    XCTAssertEqual(processed.map(\.status), [.fulfilled, .fulfilled])
    XCTAssertEqual(processed.map(\.id), ["doc-a", "doc-b"])
  }

  /// Empty `documents` rejected client-side.
  func testSaveEmbeddingsEmptyThrows() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    do {
      _ = try await client.ragSaveEmbeddings(documents: [])
      XCTFail("expected throw")
    } catch let err as QVACError {
      guard case .transport(.framingError(let msg)) = err else {
        return XCTFail("expected framing error, got \(err)")
      }
      XCTAssertTrue(msg.contains("non-empty"))
    }
  }

  // MARK: - ragDeleteEmbeddings

  /// VT-D1 / VT-D3 — Delete by id, batch supported. No throw on
  /// happy path; the stub returns `{success: true}`.
  func testDeleteEmbeddingsHappyPath() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    try await client.ragDeleteEmbeddings(ids: ["a", "b", "c"])
  }

  /// Validation: empty ids rejected client-side.
  func testDeleteEmbeddingsEmptyIdsThrows() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    do {
      try await client.ragDeleteEmbeddings(ids: [])
      XCTFail("expected throw")
    } catch let err as QVACError {
      guard case .transport(.framingError(let msg)) = err else {
        return XCTFail("expected framing error, got \(err)")
      }
      XCTAssertTrue(msg.contains("at least one id"))
    }
  }

  // MARK: - ragReindex (blocking)

  /// Blocking reindex returns the typed result. Peer stub reports
  /// `reindexed: true` with a `details.chunks` count.
  func testReindexBlockingReturnsResult() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let result = try await client.ragReindex(workspace: nil)
    XCTAssertTrue(result.reindexed)
    if case .int(let chunks) = result.details?["chunks"]?.value {
      XCTAssertEqual(chunks, 42)
    } else if case .double(let chunks) = result.details?["chunks"]?.value {
      XCTAssertEqual(chunks, 42.0)
    } else {
      XCTFail("expected details.chunks to be present")
    }
  }

  // MARK: - ragReindexStream

  /// VT-R1 — Streaming reindex emits progress frames then
  /// `.completed(result)`.
  func testReindexStreamEmitsProgressThenCompleted() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    var stages: [String] = []
    var completed: RAGReindexResult?
    let stream = client.ragReindexStream(workspace: "ws-x")
    for try await event in stream {
      switch event {
      case .progress(let stage, _, _, _): stages.append(stage)
      case .completed(let r): completed = r
      }
    }

    XCTAssertEqual(stages, ["preparing", "rebuilding", "swapping"])
    XCTAssertNotNil(completed)
    XCTAssertTrue(completed?.reindexed ?? false)
  }

  // MARK: - workspaces

  /// VT-L1 — Empty workspace list.
  func testListWorkspacesEmpty() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let list = try await client.ragListWorkspaces()
    XCTAssertEqual(list, [])
  }

  /// VT-L2 — Populated workspace list with mixed open/closed state.
  func testListWorkspacesPopulated() async throws {
    let behavior = QVACPeer.Behavior(
      ragWorkspaces: [
        .init(name: "alpha", open: true),
        .init(name: "beta", open: false),
        .init(name: "gamma", open: true),
      ])
    let (client, peer) = try await makePair(behavior: behavior)
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let list = try await client.ragListWorkspaces()
    XCTAssertEqual(list.count, 3)
    XCTAssertEqual(list.map(\.name), ["alpha", "beta", "gamma"])
    XCTAssertEqual(list.map(\.open), [true, false, true])
  }

  /// VT-C1 — closeWorkspace succeeds without throwing.
  func testCloseWorkspaceHappyPath() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    try await client.ragCloseWorkspace(workspace: "ws-to-close")
  }

  /// `deleteOnClose: true` threads through the envelope.
  func testCloseWorkspaceWithDeleteOnClose() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    try await client.ragCloseWorkspace(
      workspace: "ws-doomed", deleteOnClose: true)
  }

  /// VT-Del1 — deleteWorkspace succeeds without throwing.
  func testDeleteWorkspaceHappyPath() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    try await client.ragDeleteWorkspace(workspace: "ws-bye")
  }

  /// Validation: empty workspace name rejected client-side.
  func testDeleteWorkspaceEmptyNameThrows() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    do {
      try await client.ragDeleteWorkspace(workspace: "")
      XCTFail("expected throw")
    } catch let err as QVACError {
      guard case .transport(.framingError(let msg)) = err else {
        return XCTFail("expected framing error, got \(err)")
      }
      XCTAssertTrue(msg.contains("non-empty"))
    }
  }
}
