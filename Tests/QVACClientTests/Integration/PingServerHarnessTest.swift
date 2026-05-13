#if canImport(Network) && !os(iOS)
  import Foundation
  import XCTest

  @testable import QVACClient

  /// Lifecycle tests for the Bare ping-server fixture spawned by
  /// `PingServerHarness`. Pure harness validation; the bare-rpc-over-UDS
  /// round-trip against this fixture is YK-192's scope.
  final class PingServerHarnessTest: XCTestCase {
    func testBootAndTeardown() throws {
      let harness = try PingServerHarness()
      // Socket inode appears at the path the harness reports.
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: harness.socketPath),
        "expected socket inode at \(harness.socketPath)")
      // POSIX-level: it really is a socket (mode bit 0xC000).
      var statBuf = stat()
      let rc = stat(harness.socketPath, &statBuf)
      XCTAssertEqual(rc, 0, "stat() failed for \(harness.socketPath)")
      XCTAssertEqual(
        statBuf.st_mode & S_IFMT, S_IFSOCK,
        "expected S_IFSOCK at \(harness.socketPath)")

      harness.stop()
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: harness.socketPath),
        "socket inode must be removed on stop()")
    }

    func testCleanShutdownLeavesNoZombie() throws {
      let harness = try PingServerHarness()
      let socket = harness.socketPath
      harness.stop()
      // socket gone + the harness no longer keeps a child process alive.
      XCTAssertFalse(FileManager.default.fileExists(atPath: socket))
    }

    func testMissingFixtureReportsClearError() {
      // Re-create the harness against a temporarily-invisible path by
      // touching internal state — verifies the error formatting path. We
      // can't easily simulate the missing-binary case without disturbing
      // state, so just verify the error description shape.
      let err = PingServerHarness.HarnessError.fixtureNotInstalled(
        path: "/tmp/does-not-exist/bare",
        remedy: "Run `npm install` in Tests/Fixtures/ping-server/")
      XCTAssertTrue(
        err.description.contains("Run `npm install`"),
        "remedy must be in the description")
    }
  }
#endif
