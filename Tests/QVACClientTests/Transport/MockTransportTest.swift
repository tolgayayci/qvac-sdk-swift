import XCTest

@testable import QVACClient

final class MockTransportTest: XCTestCase {
  func testInitialStateIsIdle() async {
    let transport = MockTransport()
    let state = await transport.state
    XCTAssertEqual(state, .idle)
  }

  func testOpenTransitionsToOpen() async throws {
    let transport = MockTransport()
    try await transport.open()
    let state = await transport.state
    XCTAssertEqual(state, .open)
  }

  func testDoubleOpenThrowsAlreadyOpen() async throws {
    let transport = MockTransport()
    try await transport.open()
    do {
      try await transport.open()
      XCTFail("expected TransportError.alreadyOpen")
    } catch TransportError.alreadyOpen {
      // expected
    } catch {
      XCTFail("expected TransportError.alreadyOpen, got \(error)")
    }
  }

  func testSendBeforeOpenThrowsNotOpen() async {
    let transport = MockTransport()
    do {
      try await transport.send(Data([0x01]))
      XCTFail("expected TransportError.notOpen")
    } catch TransportError.notOpen {
      // expected
    } catch {
      XCTFail("expected TransportError.notOpen, got \(error)")
    }
  }

  func testSendCollectsInOrder() async throws {
    let transport = MockTransport()
    try await transport.open()
    try await transport.send(Data([0x01, 0x02]))
    try await transport.send(Data([0x03]))
    try await transport.send(Data([0x04, 0x05, 0x06]))
    let sent = await transport.sent
    XCTAssertEqual(sent, [Data([0x01, 0x02]), Data([0x03]), Data([0x04, 0x05, 0x06])])
  }

  func testInjectInboundDelivers() async throws {
    let transport = MockTransport()
    try await transport.open()
    await transport.injectInbound(Data([0x10, 0x20]))
    var iterator = transport.incoming.makeAsyncIterator()
    let first = try await iterator.next()
    XCTAssertEqual(first, Data([0x10, 0x20]))
  }

  func testCloseTerminatesIncoming() async throws {
    let transport = MockTransport()
    try await transport.open()
    await transport.close()
    var iterator = transport.incoming.makeAsyncIterator()
    let next = try await iterator.next()
    XCTAssertNil(next, "incoming stream must finish on close()")
  }

  func testCloseTransitionsToClosed() async throws {
    let transport = MockTransport()
    try await transport.open()
    await transport.close()
    let state = await transport.state
    XCTAssertEqual(state, .closed)
  }

  func testDoubleCloseIsIdempotent() async throws {
    let transport = MockTransport()
    try await transport.open()
    await transport.close()
    await transport.close()
    let state = await transport.state
    XCTAssertEqual(state, .closed)
  }

  func testSendAfterCloseThrowsNotOpen() async throws {
    let transport = MockTransport()
    try await transport.open()
    await transport.close()
    do {
      try await transport.send(Data([0x99]))
      XCTFail("expected TransportError.notOpen")
    } catch TransportError.notOpen {
      // expected
    } catch {
      XCTFail("expected TransportError.notOpen, got \(error)")
    }
  }

  func testInjectFailurePropagatesToIncoming() async throws {
    struct FixtureError: Error, Equatable {}
    let transport = MockTransport()
    try await transport.open()
    await transport.injectFailure(FixtureError())

    var iterator = transport.incoming.makeAsyncIterator()
    do {
      _ = try await iterator.next()
      XCTFail("expected FixtureError thrown from incoming")
    } catch is FixtureError {
      // expected
    }

    let state = await transport.state
    if case .failed = state {
      // expected
    } else {
      XCTFail("expected .failed state, got \(state)")
    }
  }

  func testStateTransitionsAreObservable() async throws {
    let transport = MockTransport()
    let initial = await transport.state
    XCTAssertEqual(initial, .idle)
    try await transport.open()
    let opened = await transport.state
    XCTAssertEqual(opened, .open)
    await transport.close()
    let closed = await transport.state
    XCTAssertEqual(closed, .closed)
  }
}
