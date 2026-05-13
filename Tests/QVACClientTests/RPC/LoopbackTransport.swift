import Foundation

@testable import QVACClient

/// In-process Transport that's paired with another `LoopbackTransport`: every
/// byte sent on side A appears on side B's `incoming`, and vice versa.
/// Used to wire two `BareRPC.RPC`-bearing peers together inside a unit test
/// without any sockets, subprocesses, or framing intermediaries — the entire
/// `bare-rpc` framing layer runs end-to-end in-memory.
///
/// Construct with `LoopbackTransport.makePair()` so both halves are linked
/// before either is used.
final class LoopbackTransport: Transport, @unchecked Sendable {
  private let inner: LoopbackActor

  let incoming: AsyncThrowingStream<Data, Error>

  fileprivate init() {
    let (stream, continuation) = AsyncThrowingStream<Data, Error>
      .makeStream(bufferingPolicy: .unbounded)
    self.incoming = stream
    self.inner = LoopbackActor(continuation: continuation)
  }

  /// Returns two transports whose `send` outputs cross-feed each other's
  /// `incoming` streams.
  static func makePair() async -> (LoopbackTransport, LoopbackTransport) {
    let a = LoopbackTransport()
    let b = LoopbackTransport()
    await a.inner.setPeer(b.inner)
    await b.inner.setPeer(a.inner)
    return (a, b)
  }

  func open() async throws { try await inner.open() }
  func close() async { await inner.close() }
  func send(_ data: Data) async throws { try await inner.send(data) }
  var state: TransportState { get async { await inner.currentState } }
}

private actor LoopbackActor {
  private(set) var currentState: TransportState = .idle
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private weak var peer: LoopbackActor?

  init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
    self.continuation = continuation
  }

  func setPeer(_ p: LoopbackActor) { peer = p }

  func open() async throws {
    switch currentState {
    case .open, .connecting:
      throw TransportError.alreadyOpen
    case .closed, .closing, .failed:
      throw TransportError.notOpen
    case .idle:
      currentState = .open
    }
  }

  func close() async {
    switch currentState {
    case .closed, .closing:
      return
    default:
      currentState = .closed
      continuation.finish()
    }
  }

  func send(_ data: Data) async throws {
    guard case .open = currentState else { throw TransportError.notOpen }
    await peer?.deliver(data)
  }

  func deliver(_ data: Data) {
    guard case .open = currentState else { return }
    continuation.yield(data)
  }
}
