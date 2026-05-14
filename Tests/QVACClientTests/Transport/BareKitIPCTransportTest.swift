#if canImport(BareKitWrapper)
  import Foundation
  import XCTest

  @testable import QVACClient

  /// YK-206 — `BareKitIPCTransport` infrastructure check. The
  /// transport TYPE compiles and conforms to `Transport` (verified
  /// by `swift build` + the build-time conformance check below).
  /// End-to-end runtime validation against a real worklet waits on
  /// the `bare-pack`-bundled qvac-worker.bundle (YK-207 v2) — the
  /// JavaScriptCore variant of BareKit can't `require('bare-ipc')`
  /// from a raw `.mjs` source; the worklet entry needs to be a
  /// pre-bundled `.bundle` file with all `require()`s resolved.
  ///
  /// What's still proven today:
  /// - `BareKit.xcframework` downloads + links correctly
  ///   (`swift build` succeeds; build complete in 0.6s)
  /// - `BareKitWrapper` (the inlined Worklet+IPC wrappers) compiles
  /// - `BareKitIPCTransport` conforms to `Transport`
  /// - Public init signature lands so M3 callers + DocC tutorials
  ///   can target it
  ///
  /// What's deferred:
  /// - Runtime echo round-trip — needs `bare-pack` bundle (YK-207 v2)
  /// - iOS Simulator smoke (xcodebuild path, YK-210)
  /// - VT-3..VT-10 — all gated on the bundle existing
  final class BareKitIPCTransportTest: XCTestCase {

    /// Compile-time check that `BareKitIPCTransport` conforms to
    /// the `Transport` protocol. If the protocol or its
    /// requirements ever drift, this stops compiling — the goal
    /// is making future contributors notice the type is meant to
    /// stay protocol-conformant even while runtime validation is
    /// deferred.
    func testTransportProtocolConformance() {
      func asTransport<T: Transport>(_: T.Type) {}
      asTransport(BareKitIPCTransport.self)
    }

    func testRuntimeEchoIsDeferredUntilBundlePipeline() throws {
      throw XCTSkip(
        "Runtime echo round-trip requires a bare-pack-bundled worklet. " +
        "The JS-Core flavored BareKit.framework can't resolve `require('bare-ipc')` " +
        "from raw .mjs source — bare-pack inlines all requires into a single .bundle. " +
        "Tracked as YK-207 v2 (qvac-worker.bundle SPM resource); when that lands, " +
        "this test wires the full end-to-end flow."
      )
    }
  }
#endif
