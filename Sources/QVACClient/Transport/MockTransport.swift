import Foundation

/// In-memory `Transport` for unit tests. **Not for production use** — the
/// real SDK integration tests (YK-191, YK-192) spawn a real Bare worker.
/// `MockTransport` exists purely to exercise the `Transport` protocol's
/// own contract (state transitions, ordering, close semantics) and to
/// drive the RPC bridge from canned byte sequences in unit tests.
///
/// Usage:
/// ```swift
/// let transport = MockTransport()
/// try await transport.open()
/// try await transport.send(Data([0x01, 0x02]))   // captured in `sent`
/// transport.injectInbound(Data([0x10]))          // appears on `incoming`
/// await transport.close()
/// ```
public final class MockTransport: Transport, @unchecked Sendable {
  private let inner: MockTransportActor

  /// Constructs a fresh transport in the `.idle` state.
  public init() {
    let (stream, continuation) = AsyncThrowingStream<Data, Error>
      .makeStream(bufferingPolicy: .unbounded)
    self.incoming = stream
    self.inner = MockTransportActor(continuation: continuation)
  }

  // MARK: - Transport

  public func open() async throws {
    try await inner.open()
  }

  public func close() async {
    await inner.close()
  }

  public func send(_ data: Data) async throws {
    try await inner.send(data)
  }

  public let incoming: AsyncThrowingStream<Data, Error>

  public var state: TransportState {
    get async { await inner.currentState }
  }

  // MARK: - Test helpers

  /// Bytes the unit under test sent via `send(_:)`, in order.
  public var sent: [Data] {
    get async { await inner.sentBytes }
  }

  /// Push a chunk onto `incoming`, as if it had arrived from the wire.
  /// Safe to call from any task.
  public func injectInbound(_ data: Data) {
    Task { await inner.injectInbound(data) }
  }

  /// Synchronous variant for tests that need ordering guarantees.
  public func injectInbound(_ data: Data) async {
    await inner.injectInbound(data)
  }

  /// Fail the transport with `error`; `state` becomes `.failed(error)` and
  /// `incoming` terminates with the error.
  public func injectFailure(_ error: any Error) async {
    await inner.injectFailure(error)
  }
}

private actor MockTransportActor {
  private(set) var currentState: TransportState = .idle
  private(set) var sentBytes: [Data] = []
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation

  init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
    self.continuation = continuation
  }

  func open() async throws {
    switch currentState {
    case .open, .connecting:
      throw TransportError.alreadyOpen
    case .closed, .closing, .failed:
      throw TransportError.notOpen  // disallow reopen on the same instance
    case .idle:
      currentState = .connecting
      currentState = .open
    }
  }

  func close() async {
    switch currentState {
    case .closed, .closing:
      return
    default:
      currentState = .closing
      continuation.finish()
      currentState = .closed
    }
  }

  func send(_ data: Data) async throws {
    guard case .open = currentState else {
      throw TransportError.notOpen
    }
    sentBytes.append(data)
  }

  func injectInbound(_ data: Data) {
    guard case .open = currentState else { return }
    continuation.yield(data)
  }

  func injectFailure(_ error: any Error) {
    currentState = .failed(error)
    continuation.finish(throwing: error)
  }
}
