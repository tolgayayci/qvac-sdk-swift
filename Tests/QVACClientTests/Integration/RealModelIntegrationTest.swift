#if canImport(Network) && !os(iOS)
  import Foundation
  import XCTest

  @testable import QVACClient

  /// YK-209 — end-to-end **real model** integration tests against the
  /// YK-208 worker fixture. No mocks: spawns the real `@qvac/sdk`
  /// worker, loads a real GGUF embedding model, runs real inference,
  /// asserts on the real output.
  ///
  /// Cache: `~/Library/Caches/qvac-tests/models/`. Tests `XCTSkip`
  /// when models aren't present, with the download command in the
  /// skip message. Set up locally:
  ///
  ///     ./scripts/download-test-models.sh
  ///     RUN_REAL_MODEL_TESTS=1 swift test --filter RealModelIntegrationTest
  ///
  /// CI: set `RUN_REAL_MODEL_TESTS=1` and prime the cache via a
  /// keyed step before running tests. Today's run takes ~5s.
  final class RealModelIntegrationTest: XCTestCase {

    // MARK: - cache / fixture lookup

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
          "Run: RUN_REAL_MODEL_TESTS=1 swift test --filter RealModelIntegrationTest")
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

    // MARK: - VT-E2E: real load → embed → unload

    /// The full cycle. Proves end-to-end with NO mocks:
    /// 1. Spawn real `@qvac/sdk` worker via `QVACClient.spawning(...)`
    /// 2. `loadModel` against the real BGE GGUF file
    /// 3. `embed` runs real BGE inference, returns a real 384-dim vector
    /// 4. `unloadModel` releases the model
    /// 5. `close()` tears down everything cleanly
    func testRealBGEEmbedRoundTrip() async throws {
      try skipIfDisabled()

      let spawned = try await QVACClient.spawning(
        bareBinary: Self.bareBinary,
        workerScript: Self.workerScript,
        acceptTimeout: 30.0)
      defer { Task { await spawned.close() } }

      // Sanity: connected after spawn() returns (init_config has run).
      let preLoadState = await spawned.client.state
      XCTAssertEqual(preLoadState, .connected)

      // Real model load. `modelType: "embeddings"` is the JS
      // SDK's alias for "llamacpp-embedding" (see
      // schemas/model-types.js). `modelSrc` is the file path.
      let modelId = try await spawned.client.loadModel(
        modelSrc: Self.bgeModel.path,
        modelType: "embeddings")
      XCTAssertFalse(modelId.isEmpty, "loadModel should return a non-empty modelId")

      // Real embedding. BGE-Small-EN-v1.5 has 384 dims.
      let vector = try await spawned.client.embed(
        modelId: modelId, input: "hello world")

      XCTAssertEqual(
        vector.count, 384,
        "BGE-Small-EN-v1.5 returns 384-dim vectors; got \(vector.count)")

      // Vector should be finite + not all zeros (real inference
      // produces real values; a zero-vector means the model didn't
      // actually run).
      let allZero = vector.allSatisfy { $0 == 0 }
      XCTAssertFalse(allZero, "embedding is all-zero — model likely didn't run")
      let hasNaN = vector.contains { $0.isNaN || $0.isInfinite }
      XCTAssertFalse(hasNaN, "embedding contains NaN/Inf")

      // Unload to release the model handle.
      try await spawned.client.unloadModel(modelId)
    }

    // MARK: - VT-E2E: semantic similarity sanity

    /// Same model, two related inputs vs one unrelated. Cosine
    /// similarity should rank related > unrelated. Proves the
    /// embedding is actually meaningful, not just well-shaped.
    func testRealBGESemanticSimilarity() async throws {
      try skipIfDisabled()

      let spawned = try await QVACClient.spawning(
        bareBinary: Self.bareBinary,
        workerScript: Self.workerScript)
      defer { Task { await spawned.close() } }

      let modelId = try await spawned.client.loadModel(
        modelSrc: Self.bgeModel.path,
        modelType: "embeddings")

      let vDog = try await spawned.client.embed(modelId: modelId, input: "dog")
      let vPuppy = try await spawned.client.embed(modelId: modelId, input: "puppy")
      let vAirplane = try await spawned.client.embed(
        modelId: modelId, input: "airplane")

      let dogPuppy = cosineSimilarity(vDog, vPuppy)
      let dogAirplane = cosineSimilarity(vDog, vAirplane)

      XCTAssertGreaterThan(
        dogPuppy, dogAirplane,
        "cos(dog, puppy)=\(dogPuppy) should be > cos(dog, airplane)=\(dogAirplane)")

      try await spawned.client.unloadModel(modelId)
    }

    // MARK: - helpers

    private func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
      precondition(a.count == b.count, "vector dim mismatch")
      var dot = 0.0
      var normA = 0.0
      var normB = 0.0
      for i in 0..<a.count {
        dot += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
      }
      return dot / (normA.squareRoot() * normB.squareRoot())
    }
  }
#endif
