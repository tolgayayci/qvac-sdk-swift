import XCTest

@testable import QVACClient

final class SmokeTests: XCTestCase {
  func testInit() async {
    _ = QVACClient()
    XCTAssertTrue(true, "QVACClient initializer is reachable")
  }
}
