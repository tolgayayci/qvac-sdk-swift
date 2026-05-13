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

  /// `BareKit` is pinned in `Package.swift` but not yet a build-time
  /// dependency of `QVACClient` (see YK-206 for the in-process worklet
  /// transport that will consume it). Until then, only the pin itself
  /// is verified — through `Package.resolved`, not at the swift-test
  /// layer.
  func testBareKitDeferredToYK206() {
    // Intentional no-op; documents the M1 vs M2 split.
    XCTAssertTrue(true)
  }
}
