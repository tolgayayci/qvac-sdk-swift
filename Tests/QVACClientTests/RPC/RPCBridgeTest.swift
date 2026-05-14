import BareRPC
import Foundation
import XCTest

@testable import QVACClient

final class RPCBridgeTest: XCTestCase {
  // MARK: - one-shot

  func testOneShotEchoRoundTrip() async throws {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = EchoPeer(transport: peerTransport)
    try await peer.start()
    defer { Task { await peer.close() } }

    let bridge = RPCBridge(transport: clientTransport)
    try await bridge.start()
    defer { Task { await bridge.close() } }

    let request = EchoRequest(type: "echo", payload: "hello world")
    let response: EchoResponse = try await bridge.send(command: 1, request)

    XCTAssertEqual(response.type, "echo")
    XCTAssertEqual(response.payload, "hello world")
  }

  func testOneShotReturnsServerErrorAsQVACError() async throws {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = EchoPeer(transport: peerTransport)
    try await peer.start()
    defer { Task { await peer.close() } }

    let bridge = RPCBridge(transport: clientTransport)
    try await bridge.start()
    defer { Task { await bridge.close() } }

    do {
      let _: EchoResponse = try await bridge.send(
        command: 1, EchoRequest(type: "error-sdk", payload: ""))
      XCTFail("expected QVACError from SDK error frame")
    } catch let err as QVACError {
      // EchoPeer maps "error-sdk" to a wire SDK error response with code 52002.
      guard case .server(let code, let message) = err else {
        return XCTFail("expected .server(code, message), got \(err)")
      }
      XCTAssertEqual(code, .modelNotFound)
      XCTAssertEqual(message, "synthetic model-not-found")
    }
  }

  func testOneShotPropagatesBareRpcRemoteError() async throws {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = EchoPeer(transport: peerTransport)
    try await peer.start()
    defer { Task { await peer.close() } }

    let bridge = RPCBridge(transport: clientTransport)
    try await bridge.start()
    defer { Task { await bridge.close() } }

    do {
      let _: EchoResponse = try await bridge.send(
        command: 1, EchoRequest(type: "error-bare", payload: ""))
      XCTFail("expected QVACError from bare-rpc remote error")
    } catch let err as QVACError {
      guard case .transport(.framingError(let message)) = err else {
        return XCTFail("expected .transport(.framingError), got \(err)")
      }
      XCTAssertTrue(message.contains("E_PEER_REJECTED"), "actual message: \(message)")
    }
  }

  func testOneShotDecodingFailureSurfacedAsTransport() async throws {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = EchoPeer(transport: peerTransport)
    try await peer.start()
    defer { Task { await peer.close() } }

    let bridge = RPCBridge(transport: clientTransport)
    try await bridge.start()
    defer { Task { await bridge.close() } }

    do {
      // EchoPeer replies with `{"type":"echo","payload":"X"}` — DifferentShape
      // doesn't match, so JSONDecoder throws.
      let _: DifferentShape = try await bridge.send(
        command: 1, EchoRequest(type: "echo", payload: "X"))
      XCTFail("expected decoding failure")
    } catch let err as QVACError {
      guard case .transport(.decodingFailed) = err else {
        return XCTFail("expected .transport(.decodingFailed), got \(err)")
      }
    }
  }

  // MARK: - streaming

  func testStreamResponseDeliversChunks() async throws {
    let (clientTransport, peerTransport) = await LoopbackTransport.makePair()
    let peer = EchoPeer(transport: peerTransport)
    try await peer.start()
    defer { Task { await peer.close() } }

    let bridge = RPCBridge(transport: clientTransport)
    try await bridge.start()
    defer { Task { await bridge.close() } }

    let stream: AsyncThrowingStream<StreamChunk, Error> = bridge.streamResponse(
      command: 2, EchoRequest(type: "stream", payload: "5"))

    var collected: [Int] = []
    for try await chunk in stream {
      collected.append(chunk.index)
    }
    XCTAssertEqual(collected, [0, 1, 2, 3, 4])
  }

  // MARK: - lifecycle

  func testSecondStartThrows() async throws {
    let transport = MockTransport()
    let bridge = RPCBridge(transport: transport)
    try await bridge.start()
    defer { Task { await bridge.close() } }

    do {
      try await bridge.start()
      XCTFail("expected throw on double start")
    } catch let err as QVACError {
      guard case .transport(.framingError) = err else {
        return XCTFail("expected .transport(.framingError), got \(err)")
      }
    }
  }

  func testCloseFailsLaterSends() async throws {
    let transport = MockTransport()
    let bridge = RPCBridge(transport: transport)
    try await bridge.start()
    await bridge.close()

    do {
      let _: EchoResponse = try await bridge.send(command: 1, EchoRequest(type: "x", payload: ""))
      XCTFail("expected throw after close")
    } catch let err as QVACError {
      guard case .transport(.transportClosed) = err else {
        return XCTFail("expected .transport(.transportClosed), got \(err)")
      }
    }
  }
}

// MARK: - test fixtures

private struct EchoRequest: Codable, Equatable {
  let type: String
  let payload: String
}

private struct EchoResponse: Codable, Equatable {
  let type: String
  let payload: String
}

private struct DifferentShape: Codable, Equatable {
  let nope: Bool
}

private struct StreamChunk: Codable, Equatable {
  let index: Int
}

/// In-process peer that owns its own `BareRPC.RPC` and answers the
/// `RPCBridge`'s requests. Lives entirely in the test bundle; never touches
/// production code paths beyond the public `BareRPC` and `QVACClient` APIs.
///
/// Supported `EchoRequest.type` values:
/// - `"echo"`: replies with the same `(type, payload)`.
/// - `"error-bare"`: rejects via `IncomingRequest.reject(...)` (bare-rpc remote error).
/// - `"error-sdk"`: replies with a `{type:"error", code:52002, ...}` SDK error frame.
/// - `"stream"`: opens a response stream, writes N newline-delimited
///   `StreamChunk` JSON objects (N from `payload`), and closes it.
private final class EchoPeer: @unchecked Sendable {
  private let transport: any Transport
  private var rpc: BareRPC.RPC?
  private var delegate: PeerDelegate?
  private var readTask: Task<Void, Never>?

  init(transport: any Transport) {
    self.transport = transport
  }

  func start() async throws {
    try await transport.open()
    let delegate = PeerDelegate(transport: transport)
    let rpc = BareRPC.RPC(delegate: delegate)
    self.delegate = delegate
    self.rpc = rpc
    delegate.rpc = rpc

    let transportRef = transport
    readTask = Task {
      do {
        for try await chunk in transportRef.incoming {
          if Task.isCancelled { break }
          await rpc.receive(chunk)
        }
      } catch {
        // transport teardown
      }
    }
  }

  func close() async {
    readTask?.cancel()
    readTask = nil
    rpc = nil
    delegate = nil
    await transport.close()
  }
}

private final class PeerDelegate: BareRPC.RPCDelegate, @unchecked Sendable {
  let transport: any Transport
  weak var rpc: BareRPC.RPC?
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  // See RPCBridge.TransportDelegate for why a serial outbox is needed:
  // `Task { await transport.send(...) }` doesn't preserve spawn order, so
  // a stream's END frame can race ahead of its last DATA frame.
  private let outboxContinuation: AsyncStream<Data>.Continuation
  private let outboxTask: Task<Void, Never>

  init(transport: any Transport) {
    self.transport = transport
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    self.outboxContinuation = continuation
    self.outboxTask = Task { [transport] in
      for await data in stream {
        try? await transport.send(data)
      }
    }
  }

  deinit {
    outboxContinuation.finish()
    outboxTask.cancel()
  }

  func rpc(_ rpc: BareRPC.RPC, send data: Data) {
    outboxContinuation.yield(data)
  }

  func rpc(
    _ rpc: BareRPC.RPC, didReceiveRequest request: BareRPC.IncomingRequest
  ) async throws {
    let req = decodeEchoRequest(request.data)
    switch req?.type {
    case "echo":
      let response = ["type": "echo", "payload": req?.payload ?? ""]
      let data = (try? encoder.encode(response)) ?? Data()
      await request.reply(data)

    case "error-bare":
      await request.reject("peer rejected this request", code: "E_PEER_REJECTED", errno: -1)

    case "error-sdk":
      let body: [String: Any] = [
        "type": "error",
        "code": 52002,
        "name": "MODEL_NOT_FOUND",
        "message": "synthetic model-not-found",
      ]
      let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
      await request.reply(data)

    case "stream":
      let count = Int(req?.payload ?? "0") ?? 0
      guard let stream = await request.createResponseStream() else {
        await request.reject("could not open stream", code: "E_STREAM", errno: -1)
        return
      }
      for i in 0..<count {
        let chunk: [String: Any] = ["index": i]
        let data = (try? JSONSerialization.data(withJSONObject: chunk)) ?? Data()
        var withNewline = data
        withNewline.append(0x0A)  // '\n'
        await stream.write(withNewline)
      }
      await stream.end()

    default:
      await request.reject(
        "unknown command type",
        code: "E_UNKNOWN_TYPE",
        errno: -1)
    }
  }

  func rpc(_ rpc: BareRPC.RPC, didReceiveEvent event: BareRPC.IncomingEvent) async {}

  func rpc(_ rpc: BareRPC.RPC, didFailWith error: Error) {}

  private func decodeEchoRequest(_ data: Data?) -> EchoRequest? {
    guard let data else { return nil }
    return try? decoder.decode(EchoRequest.self, from: data)
  }
}
