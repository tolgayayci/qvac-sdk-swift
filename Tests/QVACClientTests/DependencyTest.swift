import BareRPC
import XCTest

@testable import QVACClient

final class DependencyTest: XCTestCase {
  /// Sanity check that `BareRPC` is importable and its public types
  /// resolve. Build-time failure → missing or moved dependency.
  func testBareRPCImportable() {
    let probe: BareRPC.RPC.Type = BareRPC.RPC.self
    XCTAssertNotNil(probe)
  }

  /// `bare-kit-swift` is intentionally NOT listed in `Package.swift` for
  /// M1. Its native `BareKit` framework is not delivered via SPM, and
  /// adding the package as a pin-only dep generates an "unused dependency"
  /// SPM warning. The intended pin (`ef26bbd`) is documented in
  /// `docs/dependencies.md` and added to `Package.swift` at YK-206
  /// alongside `BareKitIPCTransport`.
  func testBareKitDeferredToYK206() {
    // Intentional no-op; documents the M1 vs M2 split.
    XCTAssertTrue(true)
  }
}
