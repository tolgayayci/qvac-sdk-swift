#if canImport(Network)
  import Foundation
  import Network

  /// `Transport` that connects to a Unix Domain Socket where a Bare worker
  /// is listening. Used by macOS apps that spawn the worker as a child
  /// process, and by command-line tools on macOS (and Linux, once
  /// `Network.framework` is available there — currently Apple-only).
  ///
  /// **iOS note**: the App Sandbox prohibits child processes and arbitrary
  /// socket paths, so this transport is not used on iOS in practice. iOS apps
  /// use `BareKitIPCTransport` (YK-206).
  public final class UDSTransport: Transport, @unchecked Sendable {
    private let socketPath: String
    private let queue: DispatchQueue
    private let inner: UDSTransportActor

    public let incoming: AsyncThrowingStream<Data, Error>

    public init(socketPath: String) {
      self.socketPath = socketPath
      self.queue = DispatchQueue(
        label: "qvac.uds.transport.\(UUID().uuidString.prefix(8))",
        qos: .userInitiated)
      let (stream, continuation) = AsyncThrowingStream<Data, Error>
        .makeStream(bufferingPolicy: .unbounded)
      self.incoming = stream
      self.inner = UDSTransportActor(
        socketPath: socketPath, queue: queue, inboundContinuation: continuation)
    }

    public func open() async throws {
      try await inner.open()
    }

    public func close() async {
      await inner.close()
    }

    public func send(_ data: Data) async throws {
      try await inner.send(data)
    }

    public var state: TransportState {
      get async { await inner.currentState }
    }
  }

  /// One-shot atomic flag — supports `tryFire()` returning `true` exactly
  /// once across concurrent callers. Used to guard against double-resuming
  /// a `CheckedContinuation` when both `.ready` and `.failed` arrive.
  private final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func tryFire() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      if fired { return false }
      fired = true
      return true
    }
  }

  private actor UDSTransportActor {
    private let socketPath: String
    private let queue: DispatchQueue
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation

    private(set) var currentState: TransportState = .idle
    private var connection: NWConnection?

    init(
      socketPath: String, queue: DispatchQueue,
      inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    ) {
      self.socketPath = socketPath
      self.queue = queue
      self.inboundContinuation = inboundContinuation
    }

    func open() async throws {
      switch currentState {
      case .connecting, .open:
        throw TransportError.alreadyOpen
      case .closing, .closed, .failed:
        throw TransportError.notOpen  // disallow reopen on the same instance
      case .idle:
        break
      }
      currentState = .connecting

      let endpoint = NWEndpoint.unix(path: socketPath)
      let connection = NWConnection(to: endpoint, using: .tcp)
      self.connection = connection

      // Bridge NWConnection's state callback into the actor.
      let actor = self
      let queue = self.queue
      let resumeGuard = OneShot()
      try await withCheckedThrowingContinuation { (cc: CheckedContinuation<Void, Error>) in
        connection.stateUpdateHandler = { state in
          Task {
            await actor.handleConnectionState(state) { error in
              guard resumeGuard.tryFire() else { return }
              if let error {
                cc.resume(throwing: error)
              } else {
                cc.resume()
              }
            }
          }
        }
        connection.start(queue: queue)
      }
    }

    private func handleConnectionState(
      _ state: NWConnection.State, resumeOpen: @escaping (Error?) -> Void
    ) {
      switch state {
      case .ready:
        currentState = .open
        startReading()
        resumeOpen(nil)
      case .failed(let error):
        currentState = .failed(error)
        inboundContinuation.finish(throwing: TransportError.writeFailed(underlying: error))
        resumeOpen(TransportError.writeFailed(underlying: error))
      case .waiting(let error):
        // `.waiting` is NW's way of saying "I can't connect yet" — for a UDS
        // pointing at a non-existent path, this is a permanent failure for
        // our purposes. Surface it as the open failure.
        currentState = .failed(error)
        inboundContinuation.finish(throwing: TransportError.writeFailed(underlying: error))
        resumeOpen(TransportError.writeFailed(underlying: error))
        connection?.cancel()
      case .cancelled:
        if case .closing = currentState {
          currentState = .closed
        } else if case .closed = currentState {
          // already closed
        } else {
          currentState = .closed
        }
        inboundContinuation.finish()
      case .setup, .preparing:
        break
      @unknown default:
        break
      }
    }

    func send(_ data: Data) async throws {
      guard case .open = currentState, let connection else {
        throw TransportError.notOpen
      }
      try await withCheckedThrowingContinuation {
        (cc: CheckedContinuation<Void, Error>) in
        connection.send(
          content: data,
          completion: .contentProcessed { error in
            if let error {
              cc.resume(throwing: TransportError.writeFailed(underlying: error))
            } else {
              cc.resume()
            }
          })
      }
    }

    func close() async {
      switch currentState {
      case .closed, .closing:
        return
      default:
        currentState = .closing
        connection?.cancel()
        // `.cancelled` arrives async via stateUpdateHandler; force a
        // best-effort terminal write on incoming so consumers unblock
        // promptly even if the cancellation callback is delayed.
        inboundContinuation.finish()
        currentState = .closed
      }
    }

    private func startReading() {
      guard let connection else { return }
      let actor = self
      connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
        data, _, isComplete, error in
        Task { await actor.handleRead(data: data, isComplete: isComplete, error: error) }
      }
    }

    private func handleRead(data: Data?, isComplete: Bool, error: NWError?) {
      if let data, !data.isEmpty {
        inboundContinuation.yield(data)
      }
      if let error {
        inboundContinuation.finish(throwing: TransportError.readFailed(underlying: error))
        return
      }
      if isComplete {
        inboundContinuation.finish()
        return
      }
      if case .open = currentState {
        startReading()
      }
    }
  }
#endif
