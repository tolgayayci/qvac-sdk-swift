#if canImport(Network)
  import XCTest

  @testable import QVACClient

  final class UDSTransportTest: XCTestCase {
    private var fixture: UDSEchoFixture?

    override func setUp() async throws {
      fixture = try UDSEchoFixture()
    }

    override func tearDown() async throws {
      fixture?.stop()
      fixture = nil
    }

    func testEchoRoundTrip() async throws {
      guard let fixture else { return XCTFail("fixture missing") }
      let transport = UDSTransport(socketPath: fixture.socketPath)
      try await transport.open()
      defer { Task { await transport.close() } }

      try await transport.send(Data("ping".utf8))

      // Read until we've collected "ping" — NWConnection may chunk it.
      var collected = Data()
      var iterator = transport.incoming.makeAsyncIterator()
      let deadline = Date().addingTimeInterval(5.0)
      while collected.count < 4 && Date() < deadline {
        if let chunk = try await iterator.next() {
          collected.append(chunk)
        } else {
          break
        }
      }
      XCTAssertEqual(collected, Data("ping".utf8))
    }

    func testEchoRoundTripWithLargePayload() async throws {
      guard let fixture else { return XCTFail("fixture missing") }
      let transport = UDSTransport(socketPath: fixture.socketPath)
      try await transport.open()
      defer { Task { await transport.close() } }

      let payload = Data(repeating: 0x42, count: 128 * 1024)  // 128 KB, > one receive window
      try await transport.send(payload)

      var collected = Data()
      var iterator = transport.incoming.makeAsyncIterator()
      let deadline = Date().addingTimeInterval(10.0)
      while collected.count < payload.count && Date() < deadline {
        if let chunk = try await iterator.next() {
          collected.append(chunk)
        } else {
          break
        }
      }
      XCTAssertEqual(collected, payload, "large payload should round-trip byte-exact")
    }

    func testConnectToMissingSocketThrows() async {
      let bogusPath = "/tmp/qvac-test-nonexistent-\(UUID().uuidString.prefix(8)).sock"
      let transport = UDSTransport(socketPath: bogusPath)
      do {
        try await transport.open()
        XCTFail("expected open() to throw against missing socket")
      } catch {
        // expected — NWConnection .unix returns .waiting/.failed for missing paths
      }
    }

    func testDoubleOpenThrowsAlreadyOpen() async throws {
      guard let fixture else { return XCTFail("fixture missing") }
      let transport = UDSTransport(socketPath: fixture.socketPath)
      try await transport.open()
      defer { Task { await transport.close() } }

      do {
        try await transport.open()
        XCTFail("expected TransportError.alreadyOpen")
      } catch TransportError.alreadyOpen {
        // expected
      } catch {
        XCTFail("expected .alreadyOpen, got \(error)")
      }
    }

    func testStateTransitionsAreObservable() async throws {
      guard let fixture else { return XCTFail("fixture missing") }
      let transport = UDSTransport(socketPath: fixture.socketPath)
      let initial = await transport.state
      XCTAssertEqual(initial, .idle)

      try await transport.open()
      let opened = await transport.state
      XCTAssertEqual(opened, .open)

      await transport.close()
      let closed = await transport.state
      XCTAssertEqual(closed, .closed)
    }

    func testCloseTerminatesIncoming() async throws {
      guard let fixture else { return XCTFail("fixture missing") }
      let transport = UDSTransport(socketPath: fixture.socketPath)
      try await transport.open()

      // Drain in parallel; close from this task should finish the stream.
      let drainTask = Task<Bool, Error> {
        var sawFinish = false
        for try await _ in transport.incoming {
          // discard
        }
        sawFinish = true
        return sawFinish
      }
      // Give the consumer a moment to start, then close.
      try await Task.sleep(nanoseconds: 100_000_000)
      await transport.close()

      let finished = try await drainTask.value
      XCTAssertTrue(finished, "incoming stream must finish after close()")
    }

    func testSendAfterCloseThrowsNotOpen() async throws {
      guard let fixture else { return XCTFail("fixture missing") }
      let transport = UDSTransport(socketPath: fixture.socketPath)
      try await transport.open()
      await transport.close()

      do {
        try await transport.send(Data([0x99]))
        XCTFail("expected TransportError.notOpen")
      } catch TransportError.notOpen {
        // expected
      } catch {
        XCTFail("expected .notOpen, got \(error)")
      }
    }
  }
#endif
