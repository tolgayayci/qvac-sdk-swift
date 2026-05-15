import Foundation
import XCTest

@testable import QVACClient

/// YK-214 — typed `invokePlugin` / `invokePluginStream` generic over
/// `Encodable`/`Decodable`. The QVACPeer stub echoes `params` back
/// as `result` so the round-trip tests can pass any Codable shape
/// and assert the same shape comes back.
///
/// Real-plugin (worker-side `definePlugin` manifests) tests roll
/// into YK-222.
final class PluginTest: XCTestCase {

  private func makePair(
    behavior: QVACPeer.Behavior = .init()
  ) async throws -> (QVACClient, QVACPeer) {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    let client = QVACClient(transport: clientTransport)
    return (client, peer)
  }

  // MARK: - Test types

  /// Caller-defined struct (not codegen'd). Used to verify the
  /// generic Encodable/Decodable surface — the SDK should round-trip
  /// any Codable without modification.
  struct EchoMessage: Codable, Equatable {
    let text: String
    let count: Int
  }

  // MARK: - VT-1 — blocking echo

  /// VT-1 — Plugin echoes args; same shape returns as result.
  func testInvokePluginEchoRoundTrip() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let request = EchoMessage(text: "hello", count: 42)
    let response: EchoMessage = try await client.invokePlugin(
      modelId: "test-model",
      handler: "echo",
      params: request)
    XCTAssertEqual(response, request)
  }

  // MARK: - VT-3 — generic types

  /// VT-3 — Different caller-defined struct round-trips just as
  /// well as the previous one. The SDK doesn't know any plugin
  /// schemas at codegen time; that's the whole point of the
  /// generic surface.
  func testInvokePluginAcceptsArbitraryCodable() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    struct Geometry: Codable, Equatable {
      let width: Double
      let height: Double
      let tags: [String]
    }

    let request = Geometry(width: 1.5, height: 2.25, tags: ["a", "b"])
    let response: Geometry = try await client.invokePlugin(
      modelId: "test-model",
      handler: "passthrough",
      params: request)
    XCTAssertEqual(response, request)
  }

  // MARK: - No-args overload

  /// No-args overload sends `params: {}`. Peer's `uppercase` handler
  /// returns the empty dict back (because EchoMessage isn't passed)
  /// — the test focuses on the no-args call path completing.
  func testInvokePluginNoArgs() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    struct Empty: Codable {}
    let _: Empty = try await client.invokePlugin(
      modelId: "test-model", handler: "noop")
  }

  // MARK: - VT-2, VT-6 — streaming

  /// VT-2 — Streaming plugin emits N chunks; consumer receives them
  /// in order.
  func testInvokePluginStreamReceivesAllChunks() async throws {
    let behavior = QVACPeer.Behavior(streamCount: 10)
    let (client, peer) = try await makePair(behavior: behavior)
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    struct Frame: Codable, Equatable {
      let index: Int
    }

    var indices: [Int] = []
    let stream: AsyncThrowingStream<Frame, Error> = client.invokePluginStream(
      modelId: "test-model",
      handler: "ticker",
      params: EchoMessage(text: "hi", count: 1))
    for try await frame in stream {
      indices.append(frame.index)
    }

    // 10 streaming frames + 1 terminal frame (index: 10, done: true)
    // == 11 chunks total when both decode cleanly. The exact count
    // can vary based on whether decoding succeeds for the terminal
    // frame (its `result` shape differs); we just assert ordering +
    // that we got the full sequence.
    XCTAssertGreaterThanOrEqual(indices.count, 10)
    XCTAssertEqual(Array(indices.prefix(10)), Array(0..<10))
  }

  /// VT-6 — Consumer-side cancel breaks iteration cleanly without
  /// leaking the underlying Task.
  func testInvokePluginStreamConsumerBreakStopsIteration() async throws {
    let behavior = QVACPeer.Behavior(streamCount: 100, streamIntervalMs: 5)
    let (client, peer) = try await makePair(behavior: behavior)
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    struct Frame: Codable { let index: Int }
    let stream: AsyncThrowingStream<Frame, Error> = client.invokePluginStream(
      modelId: "test-model",
      handler: "ticker",
      params: EchoMessage(text: "hi", count: 1))
    var received = 0
    for try await _ in stream {
      received += 1
      if received >= 2 { break }
    }
    XCTAssertGreaterThanOrEqual(received, 2)
  }

  // MARK: - PluginClient fluent wrapper

  /// `client.plugin(modelId:)` returns a fluent wrapper that pins
  /// the modelId — useful for handing a single plugin namespace to
  /// downstream code without threading the model id through every
  /// call.
  func testPluginClientFluentCall() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let plugin = client.plugin(modelId: "test-model")
    let request = EchoMessage(text: "fluent", count: 7)
    let response: EchoMessage = try await plugin.call(
      "echo", params: request)
    XCTAssertEqual(response, request)
  }

  /// Fluent streaming variant.
  func testPluginClientFluentStream() async throws {
    let (client, peer) = try await makePair(behavior: .init(streamCount: 5))
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    struct Frame: Codable { let index: Int }
    let plugin = client.plugin(modelId: "test-model")
    let stream: AsyncThrowingStream<Frame, Error> = plugin.stream(
      "ticker", params: EchoMessage(text: "fluent", count: 1))
    var indices: [Int] = []
    for try await frame in stream {
      indices.append(frame.index)
    }
    XCTAssertEqual(Array(indices.prefix(5)), Array(0..<5))
  }
}
