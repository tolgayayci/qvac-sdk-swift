import XCTest

@testable import QVACClient

/// Verifies that the YK-179 generated DTOs are real Codable structs that
/// round-trip cleanly through `JSONEncoder` / `JSONDecoder`. One test per
/// representative shape (struct + enum + boolean + Double + optional +
/// nested AnyCodable + reserved-word field name) so a regression in any
/// generator path fails fast.
final class GeneratedTypesRoundTripTest: XCTestCase {

  // MARK: - simple structs

  func testHeartbeatRequestRoundTrip() throws {
    let original = HeartbeatRequest(`type`: "heartbeat", delegate: nil)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(HeartbeatRequest.self, from: data)
    XCTAssertEqual(decoded, original)
    XCTAssertEqual(decoded.`type`, "heartbeat")
    XCTAssertNil(decoded.delegate)
  }

  func testHeartbeatResponseDecodesWireJson() throws {
    let wire = #"{"type":"heartbeat","number":7}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(HeartbeatResponse.self, from: wire)
    XCTAssertEqual(decoded.`type`, "heartbeat")
    XCTAssertEqual(decoded.number, 7)
  }

  // MARK: - optional fields

  func testEmbedStatsAllOptional() throws {
    let allNil = EmbedStats(
      totalTime: nil, tokensPerSecond: nil, totalTokens: nil, backendDevice: nil)
    let json = try JSONEncoder().encode(allNil)
    let decoded = try JSONDecoder().decode(EmbedStats.self, from: json)
    XCTAssertEqual(decoded, allNil)

    let some = EmbedStats(
      totalTime: 123.4, tokensPerSecond: 99.5, totalTokens: 42, backendDevice: nil)
    let json2 = try JSONEncoder().encode(some)
    let decoded2 = try JSONDecoder().decode(EmbedStats.self, from: json2)
    XCTAssertEqual(decoded2, some)
  }

  // MARK: - string enums (CaseIterable)

  func testLifecycleStateCases() throws {
    XCTAssertEqual(LifecycleState.allCases.count, 4)
    let active = LifecycleState.active
    let json = try JSONEncoder().encode(active)
    XCTAssertEqual(String(data: json, encoding: .utf8), "\"active\"")
    let decoded = try JSONDecoder().decode(LifecycleState.self, from: json)
    XCTAssertEqual(decoded, .active)
  }

  func testStateResponseRoundTrip() throws {
    // `state` is an inline union of string literals — surfaces as String;
    // values still need to match the LifecycleState enum's raw values.
    let response = StateResponse(`type`: "state", state: LifecycleState.suspended.rawValue)
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(StateResponse.self, from: data)
    XCTAssertEqual(decoded, response)
    XCTAssertEqual(decoded.state, "suspended")
    XCTAssertEqual(LifecycleState(rawValue: decoded.state), .suspended)
  }

  func testTtsLanguageDecodesFromWireString() throws {
    let wire = #""it""#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(TtsLanguage.self, from: wire)
    XCTAssertEqual(decoded, .it)
  }

  // MARK: - reserved-word field names

  func testReservedFieldNameTypeRoundTrips() throws {
    // `type` is a Swift reserved word; backtick-escaped on the Swift side
    // but the wire field is plain "type" — covered by the CodingKeys
    // override in the generated code.
    let suspendReq = SuspendRequest(`type`: "suspend")
    let json = try JSONEncoder().encode(suspendReq)
    let str = String(data: json, encoding: .utf8) ?? ""
    XCTAssertTrue(str.contains("\"type\":\"suspend\""), "actual JSON: \(str)")
    let decoded = try JSONDecoder().decode(SuspendRequest.self, from: json)
    XCTAssertEqual(decoded, suspendReq)
  }

  // MARK: - bool + payload

  func testEmbedResponseRoundTrip() throws {
    let response = EmbedResponse(
      `type`: "embed",
      success: true,
      embedding: AnyCodable(.array([.double(0.1), .double(0.2), .double(0.3)])),
      stats: nil,
      error: nil)
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
    XCTAssertEqual(decoded.`type`, "embed")
    XCTAssertEqual(decoded.success, true)
    XCTAssertEqual(decoded.embedding, response.embedding)
  }

  // MARK: - nested anonymous object

  func testProvideRequestWithFirewallRoundTrip() throws {
    // `ProvideRequest.firewall` resolves to an anonymous object on the wire
    // (Zod `z.infer<>` flattens the named FirewallConfig out). Codegen
    // surfaces it as `AnyCodable?`. Reuses the standalone FirewallConfig
    // type — round-tripped via JSON so the AnyCodable boundary is exercised.
    let firewall = FirewallConfig(mode: "allow", publicKeys: ["aa", "bb"])
    let firewallJson = try JSONEncoder().encode(firewall)
    let firewallAny = try JSONDecoder().decode(AnyCodable.self, from: firewallJson)
    let request = ProvideRequest(`type`: "provide", firewall: firewallAny)
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(ProvideRequest.self, from: data)
    XCTAssertEqual(decoded, request)
    XCTAssertNotNil(decoded.firewall)
  }

  func testUnloadModelResponseFields() throws {
    let r = UnloadModelResponse(
      `type`: "unloadModel",
      success: true,
      error: nil,
      hasActiveModels: false,
      hasActiveProviders: nil)
    let data = try JSONEncoder().encode(r)
    let decoded = try JSONDecoder().decode(UnloadModelResponse.self, from: data)
    XCTAssertEqual(decoded, r)
  }
}
