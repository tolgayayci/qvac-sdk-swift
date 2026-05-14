#if canImport(Network) && !os(iOS)
  import Foundation
  import XCTest

  @testable import QVACClient

  /// YK-208 — integration tests for the real `@qvac/sdk` worker
  /// fixture. Verifies the production topology (Swift = UDS server,
  /// worker = IPC client) works end-to-end with the actual SDK
  /// dispatch — `__init_config` handshake, heartbeat round-trip.
  ///
  /// Model-loading / inference VTs (VT-3, VT-4 from the issue) live
  /// in YK-209's integration test suite — they need real model
  /// weights to be downloaded.
  final class QVACWorkerHarnessTest: XCTestCase {

    // MARK: - VT-1: worker boots + heartbeat round-trips

    /// End-to-end: harness opens UDS server, spawns worker, worker
    /// connects, Swift sends `__init_config` (via `connect()`), then
    /// a heartbeat — proves the production topology + real SDK
    /// dispatch all work.
    func testWorkerBootsAndAnswersHeartbeat() async throws {
      let harness: QVACWorkerHarness
      do {
        harness = try await QVACWorkerHarness()
      } catch QVACWorkerHarness.HarnessError.fixtureNotInstalled(let path, let remedy) {
        // CI without `npm install` run shouldn't crash; skip with
        // a clear message.
        throw XCTSkip(
          "qvac-worker fixture not installed at \(path). \(remedy)")
      }
      defer { Task { await harness.stop() } }

      guard let transport = harness.transport else {
        return XCTFail("harness reported ready but transport is nil")
      }

      let client = QVACClient(transport: transport)
      try await client.connect()
      let state = await client.state
      XCTAssertEqual(state, .connected, "client should reach .connected after init_config")

      let response = try await client.heartbeat()
      XCTAssertEqual(response.type, "heartbeat")
      XCTAssertGreaterThan(response.number, 0)
    }

    // MARK: - VT-5: clean shutdown

    /// SIGTERM the worker via the harness; verify it exits cleanly
    /// without leaving the socket file behind.
    func testHarnessStopRemovesSocket() async throws {
      let harness: QVACWorkerHarness
      do {
        harness = try await QVACWorkerHarness()
      } catch QVACWorkerHarness.HarnessError.fixtureNotInstalled(let path, let remedy) {
        throw XCTSkip(
          "qvac-worker fixture not installed at \(path). \(remedy)")
      }

      let socketPath = harness.socketPath
      XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

      await harness.stop()
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: socketPath),
        "socket file should be removed after stop()")
    }

    // MARK: - VT-7: isolation

    /// Two harness instances in parallel — distinct socket paths,
    /// no collisions. Just verifies the basic isolation invariant;
    /// concurrent-RPC stress lives in YK-209.
    func testTwoHarnessesCoexist() async throws {
      let a: QVACWorkerHarness
      let b: QVACWorkerHarness
      do {
        a = try await QVACWorkerHarness()
        b = try await QVACWorkerHarness()
      } catch QVACWorkerHarness.HarnessError.fixtureNotInstalled(let path, let remedy) {
        throw XCTSkip(
          "qvac-worker fixture not installed at \(path). \(remedy)")
      }
      defer {
        Task {
          await a.stop()
          await b.stop()
        }
      }

      XCTAssertNotEqual(a.socketPath, b.socketPath)

      let clientA = QVACClient(transport: a.transport!)
      let clientB = QVACClient(transport: b.transport!)
      try await clientA.connect()
      try await clientB.connect()

      let respA = try await clientA.heartbeat()
      let respB = try await clientB.heartbeat()
      XCTAssertEqual(respA.type, "heartbeat")
      XCTAssertEqual(respB.type, "heartbeat")
    }
  }
#endif
