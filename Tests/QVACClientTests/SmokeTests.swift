import XCTest

@testable import QVACClient

final class SmokeTests: XCTestCase {
  /// Trivial sanity: `QVACClient` can be constructed with a `MockTransport`
  /// (no I/O happens until `connect()`) and the actor is reachable. Real
  /// lifecycle coverage lives in `QVACClientTest`.
  func testInit() async {
    let client = QVACClient(transport: MockTransport())
    let state = await client.state
    XCTAssertEqual(state, .disconnected)
  }
}
