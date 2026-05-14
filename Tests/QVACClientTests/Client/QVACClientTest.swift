import BareRPC
import Foundation
import XCTest

@testable import QVACClient

/// Exercises the `QVACClient` actor + the wired `send` / `streamResponse`
/// helpers from YK-197. Uses `LoopbackTransport` + an in-process
/// `QVACPeer` that speaks the same JSON envelope the real worker does
/// (dispatch by `request.type`). Real-Bare-worker E2E coverage lives in
/// `PingIntegrationTests` and (M2/YK-209) the future worker fixture.
final class QVACClientTest: XCTestCase {

  // MARK: - Helper

  private func makeClientPair(
    behavior: QVACPeer.Behavior = .init()
  ) async throws -> (QVACClient, QVACPeer) {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = QVACPeer(transport: peerTransport, behavior: behavior)
    try await peer.start()
    let client = QVACClient(transport: clientTransport)
    return (client, peer)
  }

  // MARK: - VT-1 — Connect / send / close lifecycle

  func testLifecycleConnectSendClose() async throws {
    let (client, peer) = try await makeClientPair()
    defer { Task { await peer.close() } }

    var observed = await client.state
    XCTAssertEqual(observed, .disconnected)
    try await client.connect()
    observed = await client.state
    XCTAssertEqual(observed, .connected)

    let resp = try await client.heartbeat()
    XCTAssertEqual(resp.type, "heartbeat")
    XCTAssertGreaterThan(resp.number, 0)

    await client.close()
    observed = await client.state
    XCTAssertEqual(observed, .closed)
  }

  // MARK: - VT-2 — Concurrent requests

  func testHundredConcurrentRequests() async throws {
    let (client, peer) = try await makeClientPair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    try await withThrowingTaskGroup(of: HeartbeatResponse.self) { group in
      for _ in 0..<100 {
        group.addTask {
          try await client.heartbeat()
        }
      }
      var count = 0
      for try await response in group {
        XCTAssertEqual(response.type, "heartbeat")
        count += 1
      }
      XCTAssertEqual(count, 100, "expected 100 round-trips to complete")
    }
  }

  // MARK: - VT-3 — Streaming delivers all chunks

  /// Exercises `streamResponse` end-to-end: client → bridge →
  /// AsyncThrowingStream → newline-delimited JSON decode. The peer
  /// dispatches by the JSON envelope's `type` field, so the caller has
  /// to provide one in the request. Generated stream methods that take
  /// an `AnyCodable = .null` default need an explicit envelope — the
  /// architectural fix (auto-inject `type` based on `QVACCommand`) is
  /// scoped to YK-198/M2 and tracked in `docs/application/open-questions.md` §2.4.
  ///
  /// Consumer-side cancel-mid-stream is intentionally NOT tested here —
  /// `bare-rpc-swift` destroy/cancel propagation to a peer mid-write is
  /// not currently reliable (see open-questions §2.3, §3.2). That
  /// coverage lives in `RPCBridgeTest.testStreamResponseDeliversChunks`
  /// via in-process `EchoPeer` and gets re-exercised in YK-200
  /// (M2-CANCEL) once the worker-side cancel command lands.
  func testStreamingDeliversAllChunks() async throws {
    let behavior = QVACPeer.Behavior(streamCount: 8, streamIntervalMs: 0)
    let (client, peer) = try await makeClientPair(behavior: behavior)
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    let envelope = AnyCodable(
      .object(["type": .string("loggingStream")]))
    var collected: [Int] = []
    for try await chunk in client.loggingStream(envelope) {
      if case .object(let dict) = chunk.value,
        case .int(let i) = dict["index"]
      {
        collected.append(i)
      }
    }
    XCTAssertEqual(collected, Array(0..<8))
  }

  // MARK: - VT-4 — Double close is idempotent

  func testDoubleCloseIsIdempotent() async throws {
    let (client, peer) = try await makeClientPair()
    defer { Task { await peer.close() } }
    try await client.connect()

    await client.close()
    var observed = await client.state
    XCTAssertEqual(observed, .closed)
    await client.close()  // must not crash
    observed = await client.state
    XCTAssertEqual(observed, .closed)
  }

  // MARK: - VT-5 — Connect after close throws (single-use design)

  func testConnectAfterCloseThrows() async throws {
    let (client, peer) = try await makeClientPair()
    defer { Task { await peer.close() } }
    try await client.connect()
    await client.close()

    do {
      try await client.connect()
      XCTFail("expected throw on connect-after-close")
    } catch let err as QVACError {
      guard case .transport(.transportClosed) = err else {
        return XCTFail("expected .transport(.transportClosed), got \(err)")
      }
    }
  }

  // MARK: - VT-6 — deferred to upstream bare-rpc work
  //
  // The issue body asks for "in-flight request settles within 100ms of
  // close()." Two routes were tried and dropped:
  //
  // 1. Closing the bridge with a hang request in flight — `bare-rpc-swift`
  //    has no public hook to fail pending continuations; injecting the
  //    same `0xFFFFFFFF` frame the read loop uses on transport teardown
  //    interferes with subsequent integration tests.
  // 2. `Task.cancel()` on the pending send — `bare-rpc-swift`'s
  //    `rpc.request` does not observe `Task` cancellation; the
  //    continuation hangs until the worker replies (which never happens
  //    against a `__hang__` peer).
  //
  // The supported in-M1 path — transport dies, the read loop's existing
  // force-fail injection wakes pending continuations — is already
  // covered by `PingIntegrationTests.testKillingServerMidFlightFailsFast`
  // against a real Bare worker. Adding a unit-level equivalent here
  // requires either a real `BareRPC.RPC.fail(_:)` API upstream or an
  // intrusive bridge change; flagged as **open question §2.3** in
  // `docs/application/open-questions.md` and tracked for the M2 gate
  // (YK-211).

  // MARK: - VT-7 — Send before connect throws

  func testSendBeforeConnectThrows() async throws {
    let client = QVACClient(transport: MockTransport())

    do {
      _ = try await client.heartbeat()
      XCTFail("expected throw — connect() not called")
    } catch let err as QVACError {
      guard case .transport(.framingError) = err else {
        return XCTFail("expected .transport(.framingError), got \(err)")
      }
    }
  }

  // MARK: - VT-8 — Reentrancy under actor isolation

  /// Calling another actor-isolated method from inside an awaited
  /// continuation must not deadlock. Here: `heartbeat()` awaits a
  /// response from the peer, and the same actor also reads `state`
  /// from another task. Both must complete.
  func testReentrancyDoesNotDeadlock() async throws {
    let (client, peer) = try await makeClientPair()
    defer { Task { await peer.close() } }
    try await client.connect()
    defer { Task { await client.close() } }

    async let beat = client.heartbeat()
    async let observedState = client.state

    let response = try await beat
    let state = await observedState
    XCTAssertEqual(response.type, "heartbeat")
    XCTAssertEqual(state, .connected)
  }
}

