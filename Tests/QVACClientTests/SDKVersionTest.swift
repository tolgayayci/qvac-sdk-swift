#if !os(iOS)
  // The iOS Simulator runs in its own sandbox and cannot reach the host
  // filesystem path that #filePath points at. These tests are docs-presence
  // checks against the repo root — they belong to the macOS/Linux CI lane.
  // The iOS runtime doesn't read these docs files at all.
  import XCTest

  /// Carried over from YK-175. Locks the M1 research deliverable in CI:
  /// `docs/qvac-sdk-internals.md` must keep the version anchor, the request-type
  /// registry section, and the SDK error code enumeration that downstream codegen
  /// reads. This test reads the file relative to the repository root — both
  /// `swift test` (from the package root) and the CI runner satisfy that.
  final class SDKVersionTest: XCTestCase {
    func testSDKInternalsDocCoversBaseline() throws {
      let docURL = SDKVersionTest.repositoryRoot.appendingPathComponent(
        "docs/qvac-sdk-internals.md")
      let contents = try String(contentsOf: docURL, encoding: .utf8)

      XCTAssertTrue(
        contents.contains("Version examined") && contents.contains("0.10.2"),
        "qvac-sdk-internals.md must pin the @qvac/sdk version it was generated against")
      XCTAssertTrue(
        contents.contains("Request Type Registry"),
        "Request Type Registry section must remain — codegen reads the handler list from it")
      XCTAssertTrue(
        contents.contains("SDK_CLIENT_ERROR_CODES"),
        "Client error code enumeration must remain present")
      XCTAssertTrue(
        contents.contains("SDK_SERVER_ERROR_CODES"),
        "Server error code enumeration must remain present")
      XCTAssertTrue(
        contents.contains("__init_config"),
        "Init handshake must remain documented")
    }

    func testBareRpcWireProtocolDocCoversBaseline() throws {
      let docURL = SDKVersionTest.repositoryRoot.appendingPathComponent(
        "docs/bare-rpc-wire-protocol.md")
      let contents = try String(contentsOf: docURL, encoding: .utf8)

      XCTAssertTrue(
        contents.contains("bare-rpc") && contents.contains("1.3.1"),
        "bare-rpc-wire-protocol.md must pin the bare-rpc version examined")
      XCTAssertTrue(
        contents.contains("compact-encoding"),
        "Frame primitive (compact-encoding) reference must remain")
      XCTAssertTrue(
        contents.contains("PAUSE") && contents.contains("RESUME"),
        "Backpressure mechanism must remain documented")
    }

    private static var repositoryRoot: URL {
      // #filePath resolves to .../Tests/QVACClientTests/SDKVersionTest.swift.
      // Walk up three directories to the package root.
      let thisFile = URL(fileURLWithPath: #filePath)
      return thisFile
        .deletingLastPathComponent()  // QVACClientTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // package root
    }
  }
#endif
