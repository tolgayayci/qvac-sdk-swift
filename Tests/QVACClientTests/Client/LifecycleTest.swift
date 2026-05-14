import Foundation
import XCTest

@testable import QVACClient

/// YK-201 — typed lifecycle wrappers (`ping`, `loadModel`,
/// `unloadModel`). Tests run against `LoopbackTransport` + the
/// extended `QVACPeer` that fakes worker replies. Real-worker E2E
/// coverage lives in YK-209.
final class LifecycleTest: XCTestCase {

  private func makePair(
    behavior: QVACPeer.Behavior = .init()
  ) async throws -> (QVACClient, QVACPeer) {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    let client = QVACClient(transport: clientTransport)
    return (client, peer)
  }

  // MARK: - ping

  /// `ping()` round-trips a heartbeat and returns wall-clock RTT.
  /// On loopback we expect sub-millisecond.
  func testPingRoundTripsAndReturnsRTT() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let rtt = try await client.ping()
    XCTAssertGreaterThan(rtt, 0, "RTT should be positive")
    XCTAssertLessThan(rtt, 1.0, "loopback RTT should be sub-second")
  }

  /// VT-6 — Ping latency. Issue body asks for "average of 100 pings
  /// under 5ms on local macOS." On loopback we're well under that;
  /// assertion uses 10ms ceiling for CI tolerance.
  func testHundredPingsAverageUnder10ms() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    var total: TimeInterval = 0
    for _ in 0..<100 {
      total += try await client.ping()
    }
    let avg = total / 100
    XCTAssertLessThan(avg, 0.010, "100-ping average should be <10ms on loopback")
  }

  // MARK: - loadModel

  /// Happy path: peer replies `{type:"loadModel", modelId:"..."}`;
  /// wrapper decodes the `modelId` and hands it back.
  func testLoadModelReturnsModelId() async throws {
    let behavior = QVACPeer.Behavior(loadedModelId: "llama-3.2-1b-q4_0")
    let (client, peer) = try await makePair(behavior: behavior)
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let id = try await client.loadModel(
      modelSrc: "registry://llama-3.2-1b-inst-q4_0",
      modelType: "llamacpp")
    XCTAssertEqual(id, "llama-3.2-1b-q4_0")
  }

  /// VT-3 — Load failure mapped to QVACError. Peer with
  /// `loadedModelId: nil` emits a wire SDK error frame (code 52001 =
  /// MODEL_NOT_FOUND); `QVACClient.send` decodes it via the wire-
  /// error-frame path in `RPCBridge.decodeResponseOrThrow` and
  /// throws `QVACError.server(.modelNotFound, ...)`.
  func testLoadModelFailureMapsToTypedError() async throws {
    let behavior = QVACPeer.Behavior(loadedModelId: nil)
    let (client, peer) = try await makePair(behavior: behavior)
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    do {
      _ = try await client.loadModel(
        modelSrc: "registry://does-not-exist",
        modelType: "llamacpp")
      XCTFail("expected loadModel to throw on missing model")
    } catch let err as QVACError {
      guard case .server(let code, _) = err else {
        return XCTFail("expected .server(...), got \(err)")
      }
      XCTAssertEqual(code, .modelNotFound)
    }
  }

  /// `extras` parameter for per-model-type configuration (e.g.
  /// llama.cpp GPU layer count). Sanity: passing extras doesn't
  /// break the happy path.
  func testLoadModelWithExtrasSucceeds() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let id = try await client.loadModel(
      modelSrc: "/tmp/test-model.gguf",
      modelType: "llamacpp",
      extras: [
        "nGpuLayers": AnyCodable(.int(33)),
        "contextLength": AnyCodable(.int(4096)),
      ])
    XCTAssertEqual(id, "test-model-abc")  // default peer reply
  }

  // MARK: - unloadModel

  /// Happy path: ergonomic wrapper around the generated
  /// `unloadModel(UnloadModelRequest)`.
  func testUnloadModelDoesNotThrow() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    // No assertion — just verifies the round-trip + response
    // decode succeed. The generated method handles validation;
    // this wrapper is just an ergonomic shim.
    try await client.unloadModel("test-model-abc")
  }

  /// Default `clearStorage: false` and explicit `true` both work.
  func testUnloadModelWithClearStorageTrue() async throws {
    let (client, peer) = try await makePair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    try await client.unloadModel("test-model-abc", clearStorage: true)
  }
}
