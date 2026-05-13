import XCTest

@testable import QVACClient

final class ErrorCodesTest: XCTestCase {
  /// Pinned counts. If `@qvac/sdk` bumps add/remove codes, this number
  /// changes — that's exactly the signal we want, so the Swift consumer
  /// notices an upstream change at test time.
  private static let expectedClientCount = 28
  private static let expectedServerCount = 88

  func testClientCodeCountMatchesUpstream() {
    XCTAssertEqual(
      QVACClientErrorCode.allCases.count,
      Self.expectedClientCount,
      "Client error code count drifted from @qvac/sdk@0.10.2; refresh expected count + regenerate.")
  }

  func testServerCodeCountMatchesUpstream() {
    XCTAssertEqual(
      QVACServerErrorCode.allCases.count,
      Self.expectedServerCount,
      "Server error code count drifted from @qvac/sdk@0.10.2; refresh expected count + regenerate.")
  }

  /// Known codes from `docs/qvac-sdk-internals.md` §8.2 must round-trip.
  func testKnownClientCodes() {
    XCTAssertEqual(QVACClientErrorCode.invalidResponseType.rawValue, 50001)
    XCTAssertEqual(QVACClientErrorCode.rpcNoHandler.rawValue, 50200)
    XCTAssertEqual(QVACClientErrorCode.profilerInvalidCapacity.rawValue, 50800)
    XCTAssertEqual(QVACClientErrorCode.invalidResponseType.wireName, "INVALID_RESPONSE_TYPE")
  }

  func testKnownServerCodes() {
    XCTAssertEqual(QVACServerErrorCode.modelNotFound.rawValue, 52002)
    XCTAssertEqual(QVACServerErrorCode.embedFailed.rawValue, 52401)
    XCTAssertEqual(QVACServerErrorCode.modelNotFound.wireName, "MODEL_NOT_FOUND")
  }

  func testWireDecodingMapsClient() {
    let err = QVACError(wireCode: 50001, name: "INVALID_RESPONSE_TYPE", message: "bad type")
    guard case .client(let code, let message) = err else {
      return XCTFail("expected .client, got \(err)")
    }
    XCTAssertEqual(code, .invalidResponseType)
    XCTAssertEqual(message, "bad type")
    XCTAssertEqual(err.category, .client)
    XCTAssertEqual(err.wireCode, 50001)
    XCTAssertEqual(err.wireName, "INVALID_RESPONSE_TYPE")
  }

  func testWireDecodingMapsServer() {
    let err = QVACError(wireCode: 52002, name: "MODEL_NOT_FOUND", message: "no such id")
    guard case .server(let code, _) = err else {
      return XCTFail("expected .server, got \(err)")
    }
    XCTAssertEqual(code, .modelNotFound)
    XCTAssertEqual(err.category, .server)
  }

  func testWireDecodingFallsThroughToUnknown() {
    let err = QVACError(wireCode: 99_999, name: "FUTURE_THING", message: "tomorrow")
    guard case .unknown(let code, let name, let message) = err else {
      return XCTFail("expected .unknown, got \(err)")
    }
    XCTAssertEqual(code, 99_999)
    XCTAssertEqual(name, "FUTURE_THING")
    XCTAssertEqual(message, "tomorrow")
  }

  func testNilCodeFallsThroughToUnknown() {
    let err = QVACError(wireCode: nil, name: nil, message: "ambiguous")
    guard case .unknown(let code, let name, _) = err else {
      return XCTFail("expected .unknown, got \(err)")
    }
    XCTAssertNil(code)
    XCTAssertNil(name)
  }

  func testErrorDescriptionIncludesCodeAndName() {
    let err = QVACError(wireCode: 52002, name: "MODEL_NOT_FOUND", message: "X not found")
    let description = err.errorDescription ?? ""
    XCTAssertTrue(
      description.contains("52002"), "errorDescription missing code: \(description)")
    XCTAssertTrue(
      description.contains("MODEL_NOT_FOUND"),
      "errorDescription missing name: \(description)")
    XCTAssertTrue(
      description.contains("X not found"),
      "errorDescription missing message: \(description)")
  }

  func testTransportErrorAccessors() {
    let err = QVACError.transport(.framingError("bad uint"))
    XCTAssertEqual(err.category, .transport)
    XCTAssertNil(err.wireCode)
    XCTAssertEqual(err.wireName, "FRAMING_ERROR")
    XCTAssertEqual(err.message, "Frame decoding failed: bad uint")
  }

  /// All client cases must round-trip through their rawValue. Catches
  /// a drift between generated codes and the enum's CaseIterable view.
  func testAllClientCodesRoundTrip() {
    for code in QVACClientErrorCode.allCases {
      XCTAssertEqual(QVACClientErrorCode(rawValue: code.rawValue), code)
      XCTAssertFalse(code.wireName.isEmpty)
    }
  }

  func testAllServerCodesRoundTrip() {
    for code in QVACServerErrorCode.allCases {
      XCTAssertEqual(QVACServerErrorCode(rawValue: code.rawValue), code)
      XCTAssertFalse(code.wireName.isEmpty)
    }
  }
}
