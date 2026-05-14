import Foundation
import XCTest

@testable import QVACClient

/// Direct exercise of the `Codec` protocol + `JSONCodec` impl from YK-196.
/// Round-trip tests use representative generated DTOs from
/// `Sources/QVACClient/Generated/Models/`; the forward-compat tests use
/// inline structs so they don't depend on the codegen output staying stable.
final class CodecTest: XCTestCase {
  private let codec = JSONCodec()

  // MARK: - Round-trip for generated DTOs (VT-1)

  func testRoundTripHeartbeatResponse() throws {
    let original = HeartbeatResponse(type: "heartbeat", number: 42)
    let data = try codec.encode(original)
    let decoded = try codec.decode(HeartbeatResponse.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  func testRoundTripEmbedRequest() throws {
    let original = EmbedRequest(
      modelId: "model-abc",
      text: AnyCodable(.string("hello world")),
      type: "embed")
    let data = try codec.encode(original)
    let decoded = try codec.decode(EmbedRequest.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  func testRoundTripEmbedResponseWithArrayPayload() throws {
    let original = EmbedResponse(
      type: "embed",
      success: true,
      embedding: AnyCodable(.array([
        .double(0.1), .double(-0.2), .double(0.3), .double(-0.4), .double(0.5),
      ])),
      stats: AnyCodable(.object([
        "totalTime": .double(0.42),
        "totalTokens": .int(17),
      ])),
      error: nil)
    let data = try codec.encode(original)
    let decoded = try codec.decode(EmbedResponse.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  func testRoundTripUnloadModelRequest() throws {
    let original = UnloadModelRequest(
      modelId: "model-xyz", clearStorage: false, type: "unloadModel")
    let data = try codec.encode(original)
    let decoded = try codec.decode(UnloadModelRequest.self, from: data)
    XCTAssertEqual(decoded, original)
  }

  func testRoundTripStringEnum() throws {
    // LifecycleState is a `String`-raw-value enum; encode → "active" etc.
    for state in LifecycleState.allCases {
      let data = try codec.encode(state)
      let decoded = try codec.decode(LifecycleState.self, from: data)
      XCTAssertEqual(decoded, state)
    }
  }

  // MARK: - Wire-format guarantees

  func testKeysArePreservedVerbatim() throws {
    // EmbedRequest carries `modelId` (camelCase) on the Swift side and
    // expects `modelId` on the wire. `.useDefaultKeys` (the JSONCodec
    // configuration) must NOT rewrite that to model_id or modelid.
    let req = EmbedRequest(
      modelId: "m1", text: AnyCodable(.string("x")), type: "embed")
    let data = try codec.encode(req)
    guard let json = String(data: data, encoding: .utf8) else {
      return XCTFail("encoded bytes are not UTF-8")
    }
    XCTAssertTrue(
      json.contains("\"modelId\":\"m1\""),
      "expected `modelId` key verbatim, got: \(json)")
  }

  func testTypeFieldEncodedAsType() throws {
    // The generated DTOs route the Swift `type` property through a
    // CodingKey override to the wire name `type` (verbatim). The codec
    // must not mangle it.
    let resp = HeartbeatResponse(type: "heartbeat", number: 1)
    let data = try codec.encode(resp)
    guard let json = String(data: data, encoding: .utf8) else {
      return XCTFail("encoded bytes are not UTF-8")
    }
    XCTAssertTrue(json.contains("\"type\":\"heartbeat\""), "got: \(json)")
  }

  func testEncoderProducesCompactOutput() throws {
    // JSONCodec uses `outputFormatting = []` → no whitespace.
    let resp = HeartbeatResponse(type: "h", number: 1)
    let data = try codec.encode(resp)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(json.contains("\n"), "compact output should not contain newlines")
    XCTAssertFalse(json.contains(" : "), "compact output should not have padded colons")
  }

  // MARK: - Forward-compat (VT-4)

  /// A response the JS server might send with an extra field the Swift
  /// DTO doesn't know about yet. `JSONDecoder`'s default ignores unknown
  /// keys, so this MUST decode cleanly — guarantees older Swift clients
  /// keep working against newer workers.
  func testUnknownFieldsAreSilentlyIgnored() throws {
    let json = """
      {
        "type": "heartbeat",
        "number": 7,
        "extraField": "added by a newer worker",
        "anotherExtra": [1, 2, 3]
      }
      """
    let data = json.data(using: .utf8)!
    let decoded = try codec.decode(HeartbeatResponse.self, from: data)
    XCTAssertEqual(decoded, HeartbeatResponse(type: "heartbeat", number: 7))
  }

  /// Inverse property: a required key missing on the wire SHOULD throw.
  /// `RPCBridge` maps the throw to `QVACError.transport(.decodingFailed)`.
  func testMissingRequiredFieldThrows() {
    let json = """
      { "type": "heartbeat" }
      """
    let data = json.data(using: .utf8)!
    XCTAssertThrowsError(try codec.decode(HeartbeatResponse.self, from: data)) { error in
      // Expect a DecodingError (keyNotFound for `number`) — not a fatalError.
      XCTAssertTrue(error is DecodingError, "got \(type(of: error)): \(error)")
    }
  }

  /// Type-mismatch on a required field — wire says `number` is a string,
  /// Swift expects `Double`.
  func testTypeMismatchThrows() {
    let json = """
      { "type": "heartbeat", "number": "not-a-double" }
      """
    let data = json.data(using: .utf8)!
    XCTAssertThrowsError(try codec.decode(HeartbeatResponse.self, from: data))
  }

  // MARK: - Edge cases

  func testEmptyJSONObjectThrowsOnRequiredFields() throws {
    // CancelResponse requires `type` and `success`. An empty object must
    // throw rather than silently producing a zombie struct. Guards
    // against accidental "default to false/empty" behavior at the codec
    // layer.
    let empty = "{}".data(using: .utf8)!
    XCTAssertThrowsError(try codec.decode(CancelResponse.self, from: empty))
  }

  func testCustomCodecCanBeInjected() throws {
    // The whole point of the protocol: callers can pass alternative
    // implementations. The `TraceCodec` below proves the seam works.
    let trace = TraceCodec(wrapping: JSONCodec())
    let req = UnloadModelRequest(
      modelId: "m1", clearStorage: false, type: "unloadModel")
    let data = try trace.encode(req)
    let decoded: UnloadModelRequest = try trace.decode(UnloadModelRequest.self, from: data)
    XCTAssertEqual(decoded, req)
    XCTAssertEqual(trace.encodeCount, 1)
    XCTAssertEqual(trace.decodeCount, 1)
  }
}

/// Test-only codec that delegates to another `Codec` while counting
/// encode/decode calls. Demonstrates the injection seam from
/// `RPCBridge.init(transport:codec:)`.
private final class TraceCodec: Codec, @unchecked Sendable {
  private let inner: any Codec
  private(set) var encodeCount = 0
  private(set) var decodeCount = 0

  init(wrapping inner: any Codec) {
    self.inner = inner
  }

  func encode<T: Encodable>(_ value: T) throws -> Data {
    encodeCount += 1
    return try inner.encode(value)
  }

  func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    decodeCount += 1
    return try inner.decode(type, from: data)
  }
}
