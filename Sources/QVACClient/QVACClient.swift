import Foundation

/// Native Swift entry point for talking to a QVAC Bare worker.
///
/// `QVACClient` is an `actor` — every public method serializes through the
/// actor's executor so mutable state (connection lifecycle, bridge handle,
/// in-flight requests) can never race. The generated method surface in
/// `Generated/Client+Methods.swift` routes through the `internal` `send`
/// and `streamResponse` helpers declared in
/// `Support/QVACClient+SendStream.swift`, which delegate to the
/// `RPCBridge` owned here.
///
/// **Lifecycle.** Two-step on purpose:
///
/// 1. `init(transport:codec:)` — no network I/O. Just wires the actor to
///    its dependencies. Safe to call from anywhere; produces a client in
///    `.disconnected` state.
/// 2. `connect()` — opens the transport, starts the `RPCBridge`. After
///    this returns, `send` / `streamResponse` may be called.
/// 3. `close()` — tears the bridge down and transitions to `.closed`.
///    Idempotent. Once closed, the client is single-use: build a new one
///    for a new connection. (Rationale: re-opening would have to re-run
///    `__init_config` and any other handshake state from YK-198, which
///    cleanly belongs to a fresh instance.)
///
/// `__init_config` handshake itself is owned by **YK-198** and slots into
/// `connect()` as a post-bridge-start step.
public actor QVACClient {
  // MARK: State machine

  /// The 5 lifecycle states.
  ///
  /// Transitions:
  ///
  ///   .disconnected ──connect()──▶ .connecting ──ok──▶ .connected
  ///                                              └──fail──▶ .disconnected
  ///   .connected    ──close()────▶ .closing    ──────▶ .closed
  ///   .closed       ──connect()──▶ throws .transport(.transportClosed)
  ///
  /// `close()` from any state is idempotent; only `.connected` triggers a
  /// real teardown, the rest no-op into `.closed`.
  public enum State: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case closing
    case closed
  }

  // MARK: Dependencies

  private let transport: any Transport
  private let codec: any Codec

  // MARK: Mutable state

  private var bridge: RPCBridge?
  private var _state: State = .disconnected

  // MARK: Init / inspection

  /// Builds a client wired to `transport`. No network I/O happens here —
  /// the transport remains closed until `connect()` is called.
  public init(transport: any Transport, codec: any Codec = JSONCodec()) {
    self.transport = transport
    self.codec = codec
  }

  /// Current lifecycle state. Surfaced for tests and for callers that want
  /// to inspect connection status without trying a no-op `send`.
  public var state: State { _state }

  // MARK: Connect / close

  /// Open the transport and start the underlying `RPCBridge`. Idempotent
  /// on `.connected`. Throws on any other re-entry attempt
  /// (`.connecting` = race, `.closing`/`.closed` = single-use).
  public func connect() async throws {
    switch _state {
    case .connected:
      return
    case .connecting:
      throw QVACError.transport(.framingError("QVACClient.connect() already in progress"))
    case .closing, .closed:
      throw QVACError.transport(.transportClosed)
    case .disconnected:
      break
    }

    _state = .connecting
    let bridge = RPCBridge(transport: transport, codec: codec)
    do {
      try await bridge.start()
    } catch {
      // Roll back so the caller can build a fresh transport and try again.
      _state = .disconnected
      throw error
    }
    self.bridge = bridge
    _state = .connected

    // YK-198 (M2-INIT-CONFIG) will send the `__init_config` request here
    // before declaring `.connected`. Left as a single insertion point so
    // the handshake lands without restructuring the state machine.
  }

  /// Tear the bridge down and transition to `.closed`. Safe to call from
  /// any state; only `.connected` performs a real teardown. After
  /// `close()`, every `send` / `streamResponse` throws
  /// `.transport(.transportClosed)`.
  public func close() async {
    switch _state {
    case .closed, .disconnected:
      _state = .closed
      return
    case .closing:
      return
    case .connecting:
      // Connect is in flight on a different task; flip the flag so it
      // observes the close on completion. We can't await it from inside
      // the same actor without deadlocking, so the in-flight connect
      // either succeeds (then sees `.closing` and drops to `.closed` on
      // its next state check) or fails (already rolls back).
      _state = .closing
      return
    case .connected:
      _state = .closing
      await bridge?.close()
      bridge = nil
      _state = .closed
    }
  }

  // MARK: Internal — used by send / streamResponse extension

  /// Returns the live bridge or throws the right `QVACError`. Centralized
  /// so the two send paths agree on what "not ready" looks like.
  internal func requireBridge() throws -> RPCBridge {
    switch _state {
    case .disconnected, .connecting:
      throw QVACError.transport(
        .framingError("QVACClient.connect() not called or in progress"))
    case .closing, .closed:
      throw QVACError.transport(.transportClosed)
    case .connected:
      guard let bridge else {
        // Defensive: should be impossible — `.connected` is only set
        // after `bridge` is assigned. Treat as a transport failure.
        throw QVACError.transport(.framingError("bridge missing in .connected state"))
      }
      return bridge
    }
  }
}
