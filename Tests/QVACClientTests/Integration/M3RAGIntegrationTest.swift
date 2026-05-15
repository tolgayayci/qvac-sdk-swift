#if canImport(Network) && !os(iOS)
  import Foundation
  import XCTest

  @testable import QVACClient

  /// YK-222 — end-to-end RAG integration tests against the real
  /// `@qvac/sdk` 0.10.2 worker fixture. Uses the same BGE-Small
  /// embedding model as `RealModelIntegrationTest` (YK-209) so the
  /// only cold-load cost is the worker boot + one model warm-up.
  ///
  /// Gated on `RUN_REAL_MODEL_TESTS=1` + the BGE GGUF being cached
  /// at `~/Library/Caches/qvac-tests/models/`. Same opt-in pattern
  /// as YK-209.
  ///
  /// Coverage:
  /// - VT-1 RAG round-trip (ingest → search → verify recall).
  /// - VT-4 workspace lifecycle (list → close → list).
  /// - VT-6 RAG fork (two workspaces, two parallel ingests, no
  ///   cross-talk).
  ///
  /// Deferred to a per-target follow-up (large model required):
  /// - VT-1 second half (RAG hit → completion).
  /// - VT-2 plugin chain + completion.
  /// - VT-3 concurrent RAG + completion.
  /// - VT-7 30-minute soak.
  final class M3RAGIntegrationTest: XCTestCase {

    // MARK: - cache / fixture lookup (mirrors YK-209)

    private static var modelCacheDir: URL {
      let home = ProcessInfo.processInfo.environment["HOME"] ?? "/tmp"
      #if os(macOS)
        return URL(fileURLWithPath: "\(home)/Library/Caches/qvac-tests/models")
      #else
        return URL(fileURLWithPath: "\(home)/.cache/qvac-tests/models")
      #endif
    }

    private static var bgeModel: URL {
      modelCacheDir.appendingPathComponent("bge-small-en-v1.5.Q4_K_M.gguf")
    }

    private static var fixtureDir: URL {
      URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Integration/
        .deletingLastPathComponent()  // QVACClientTests/
        .deletingLastPathComponent()  // Tests/
        .appendingPathComponent("Fixtures/qvac-worker")
    }

    private static var bareBinary: URL {
      fixtureDir.appendingPathComponent("node_modules/.bin/bare")
    }

    private static var workerScript: URL {
      fixtureDir.appendingPathComponent("worker.mjs")
    }

    private func skipIfDisabled() throws {
      guard ProcessInfo.processInfo.environment["RUN_REAL_MODEL_TESTS"] == "1" else {
        throw XCTSkip(
          "RUN_REAL_MODEL_TESTS not set. Real-model tests are opt-in. " +
          "Run: RUN_REAL_MODEL_TESTS=1 swift test --filter M3RAGIntegrationTest")
      }
      guard FileManager.default.fileExists(atPath: Self.bgeModel.path) else {
        throw XCTSkip(
          "Model not cached at \(Self.bgeModel.path). " +
          "Run: ./scripts/download-test-models.sh")
      }
      guard FileManager.default.isExecutableFile(atPath: Self.bareBinary.path) else {
        throw XCTSkip(
          "qvac-worker fixture not installed at \(Self.bareBinary.path). " +
          "Run `npm install` in Tests/Fixtures/qvac-worker/")
      }
    }

    // MARK: - Shared spawn helper

    /// Spawns a fresh SpawnedClient + loads BGE, returns both
    /// to the caller for use, and registers a `defer`-style
    /// teardown via the returned closure. Pattern matches the
    /// YK-209 tests.
    private func bootBGE() async throws -> (SpawnedClient, String) {
      let spawned = try await QVACClient.spawning(
        bareBinary: Self.bareBinary,
        workerScript: Self.workerScript)

      let modelId = try await spawned.client.loadModel(
        modelSrc: Self.bgeModel.path,
        modelType: "embeddings")
      return (spawned, modelId)
    }

    // MARK: - VT-1 — RAG round-trip with real BGE

    /// Ingest two short documents into a workspace, then search.
    /// With real BGE embeddings, semantically-related queries
    /// should retrieve the correct document at rank 1.
    func testRAGIngestAndSearchRoundTrip() async throws {
      try skipIfDisabled()
      let (spawned, modelId) = try await bootBGE()
      defer { Task { await spawned.close() } }

      let workspace = "yk-222-roundtrip-\(UUID().uuidString.prefix(6))"
      defer {
        Task {
          try? await spawned.client.ragDeleteWorkspace(workspace: workspace)
        }
      }

      let documents = [
        "The cat sat on the mat. Cats are domesticated mammals known for purring.",
        "The dog chased the ball. Dogs are loyal companions and pack animals.",
        "The Eiffel Tower stands in Paris, France. It was built in 1889.",
      ]

      // Ingest.
      let ingestResult = try await spawned.client.ragIngest(
        modelId: modelId,
        workspace: workspace,
        documents: documents)
      XCTAssertGreaterThanOrEqual(
        ingestResult.processed.count, documents.count,
        "expected ≥\(documents.count) processed chunks")
      XCTAssertEqual(
        ingestResult.processed.filter { $0.status == .fulfilled }.count,
        ingestResult.processed.count,
        "all chunks should be fulfilled")

      // Search for a pet query — both cat and dog docs are pet-
      // related and should outrank the Eiffel tower doc.
      // BGE-Small at Q4_K_M doesn't strongly disambiguate "feline"
      // vs "canine" — they share most semantic features (small
      // furry pet, four legs, owned) — so we assert on the
      // pet-vs-landmark boundary rather than cat-vs-dog ordering.
      let petHits = try await spawned.client.ragSearch(
        modelId: modelId,
        workspace: workspace,
        query: "domestic pet animal",
        topK: 3)
      XCTAssertEqual(petHits.count, 3, "expected all 3 docs back at topK=3")
      let topTwoContent = petHits.prefix(2).map { $0.content.lowercased() }
      XCTAssertTrue(
        topTwoContent.allSatisfy { $0.contains("cat") || $0.contains("dog") },
        "top 2 hits for 'domestic pet animal' should both be pet docs, got: \(topTwoContent)")
      XCTAssertTrue(
        petHits[2].content.lowercased().contains("eiffel"),
        "rank-3 hit should be the unrelated Eiffel doc, got: \(petHits[2].content)")

      // Search for a landmark query — should retrieve the Eiffel doc.
      let towerHits = try await spawned.client.ragSearch(
        modelId: modelId,
        workspace: workspace,
        query: "famous European landmark architecture",
        topK: 3)
      XCTAssertFalse(towerHits.isEmpty)
      let topTower = towerHits[0].content
      XCTAssertTrue(
        topTower.lowercased().contains("eiffel") || topTower.lowercased().contains("paris"),
        "top hit for 'famous European landmark' should be the Eiffel doc, got: \(topTower)")
    }

    // MARK: - VT-4 — workspace lifecycle

    /// list → ingest into new workspace → list (should grow) →
    /// close → delete → list (should shrink).
    func testWorkspaceLifecycle() async throws {
      try skipIfDisabled()
      let (spawned, modelId) = try await bootBGE()
      defer { Task { await spawned.close() } }

      let workspace = "yk-222-lifecycle-\(UUID().uuidString.prefix(6))"

      let pre = try await spawned.client.ragListWorkspaces()
      XCTAssertFalse(
        pre.contains { $0.name == workspace },
        "fresh workspace name should not yet exist")

      // Ingest creates the workspace on first write.
      _ = try await spawned.client.ragIngest(
        modelId: modelId,
        workspace: workspace,
        documents: ["sentinel chunk"])

      let mid = try await spawned.client.ragListWorkspaces()
      XCTAssertTrue(
        mid.contains { $0.name == workspace },
        "workspace should appear after ingest")

      // Close it; subsequent list still shows it (closed != deleted).
      try await spawned.client.ragCloseWorkspace(workspace: workspace)

      // Delete and re-list — should be gone.
      try await spawned.client.ragDeleteWorkspace(workspace: workspace)
      let post = try await spawned.client.ragListWorkspaces()
      XCTAssertFalse(
        post.contains { $0.name == workspace },
        "workspace should be gone after deleteWorkspace")
    }

    // MARK: - VT-6 — RAG fork

    /// Two workspaces, two parallel ingests with disjoint document
    /// sets; verify a search in workspace-A doesn't return doc text
    /// from workspace-B.
    func testRAGForkIsolatesWorkspaces() async throws {
      try skipIfDisabled()
      let (spawned, modelId) = try await bootBGE()
      defer { Task { await spawned.close() } }

      let wsA = "yk-222-fork-a-\(UUID().uuidString.prefix(6))"
      let wsB = "yk-222-fork-b-\(UUID().uuidString.prefix(6))"
      defer {
        Task {
          try? await spawned.client.ragDeleteWorkspace(workspace: wsA)
          try? await spawned.client.ragDeleteWorkspace(workspace: wsB)
        }
      }

      // Run the two ingests sequentially (serializing on the client
      // actor's send queue rather than racing the worker's RAG
      // operation manager; concurrent same-workspace writes use a
      // signal-based lock server-side, but cross-workspace
      // sequential is the natural Swift pattern).
      _ = try await spawned.client.ragIngest(
        modelId: modelId,
        workspace: wsA,
        documents: [
          "Apples are a sweet pomaceous fruit.",
          "Bananas are a tropical yellow fruit grown across the equator.",
        ])
      _ = try await spawned.client.ragIngest(
        modelId: modelId,
        workspace: wsB,
        documents: [
          "Helsinki is the capital of Finland.",
          "Tokyo is the capital of Japan.",
        ])

      // Workspace A should not return B's content for a fruit query.
      let hitsA = try await spawned.client.ragSearch(
        modelId: modelId, workspace: wsA, query: "fruit", topK: 2)
      XCTAssertFalse(hitsA.isEmpty)
      for hit in hitsA {
        XCTAssertFalse(
          hit.content.contains("Helsinki") || hit.content.contains("Tokyo"),
          "workspace A leaked content from workspace B: \(hit.content)")
      }

      // And workspace B for a capital query.
      let hitsB = try await spawned.client.ragSearch(
        modelId: modelId, workspace: wsB, query: "capital city", topK: 2)
      XCTAssertFalse(hitsB.isEmpty)
      for hit in hitsB {
        XCTAssertFalse(
          hit.content.contains("apple") || hit.content.contains("banana"),
          "workspace B leaked content from workspace A: \(hit.content)")
      }
    }
  }
#endif
