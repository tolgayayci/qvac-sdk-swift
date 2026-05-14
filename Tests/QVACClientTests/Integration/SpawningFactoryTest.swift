#if canImport(Network) && !os(iOS)
  import Foundation
  import XCTest

  @testable import QVACClient

  /// YK-207 — `QVACClient.spawning(...)` factory. Exercises the
  /// full convenience path against the real `@qvac/sdk` worker
  /// fixture from YK-208: open `UDSServer`, spawn `bare worker.mjs`,
  /// accept, connect (runs `__init_config`), return ready client.
  final class SpawningFactoryTest: XCTestCase {

    private static var fixtureDirectory: URL {
      let here = URL(fileURLWithPath: #filePath)
      return here
        .deletingLastPathComponent()  // Integration/
        .deletingLastPathComponent()  // QVACClientTests/
        .deletingLastPathComponent()  // Tests/
        .appendingPathComponent("Fixtures/qvac-worker")
    }

    private static var bareBinary: URL {
      fixtureDirectory.appendingPathComponent("node_modules/.bin/bare")
    }

    private static var workerScript: URL {
      fixtureDirectory.appendingPathComponent("worker.mjs")
    }

    private func skipIfFixtureMissing() throws {
      guard FileManager.default.isExecutableFile(atPath: Self.bareBinary.path),
        FileManager.default.fileExists(atPath: Self.workerScript.path)
      else {
        throw XCTSkip(
          "qvac-worker fixture not installed at \(Self.fixtureDirectory.path). " +
          "Run `npm install` there.")
      }
    }

    // MARK: - VT-1: one-liner success

    func testSpawningReturnsConnectedClient() async throws {
      try skipIfFixtureMissing()

      let spawned = try await QVACClient.spawning(
        bareBinary: Self.bareBinary,
        workerScript: Self.workerScript)
      defer { Task { await spawned.close() } }

      let state = await spawned.client.state
      XCTAssertEqual(state, .connected)

      // Sanity round-trip against the real SDK dispatch.
      let resp = try await spawned.client.heartbeat()
      XCTAssertEqual(resp.type, "heartbeat")
      XCTAssertGreaterThan(resp.number, 0)
    }

    // MARK: - lifecycle

    func testSpawnedClientCloseTearsDownAll() async throws {
      try skipIfFixtureMissing()

      let spawned = try await QVACClient.spawning(
        bareBinary: Self.bareBinary,
        workerScript: Self.workerScript)
      _ = try await spawned.client.heartbeat()
      await spawned.close()

      // Close is idempotent.
      await spawned.close()
    }

    // MARK: - embedded() stub

    /// `QVACClient.embedded()` body throws until the second-half of
    /// YK-207 (the `qvac-worker.bundle` SPM resource produced by
    /// `bare-pack`). The BareKit transport itself is wired (YK-206
    /// → `BareKitIPCTransport`); the missing piece is the bundled
    /// QVAC worker JS the transport hosts.
    func testEmbeddedFactoryThrowsUntilBundleShips() async {
      do {
        _ = try await QVACClient.embedded()
        XCTFail("expected embedded() to throw until qvac-worker.bundle ships")
      } catch let err as QVACError {
        guard case .transport(.framingError(let msg)) = err else {
          return XCTFail("expected .transport(.framingError), got \(err)")
        }
        XCTAssertTrue(
          msg.contains("YK-207"),
          "error message should reference YK-207 v2 (bundle pipeline): \(msg)")
      } catch {
        XCTFail("unexpected non-QVACError: \(error)")
      }
    }
  }
#endif
