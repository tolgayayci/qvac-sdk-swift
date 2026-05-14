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
/// 1. `init(transport:codec:initConfig:runtimeContext:)` — no network
///    I/O. Just wires the actor to its dependencies. Safe to call from
///    anywhere; produces a client in `.disconnected` state.
/// 2. `connect()` — opens the transport, starts the `RPCBridge`, runs
///    the `__init_config` handshake. After this returns, `send` /
///    `streamResponse` may be called.
/// 3. `close()` — tears the bridge down and transitions to `.closed`.
///    Idempotent. Once closed, the client is single-use: build a new one
///    for a new connection. (Rationale: re-opening would have to re-run
///    `__init_config` and any other handshake state, which cleanly
///    belongs to a fresh instance.)
public actor QVACClient {
  // MARK: State machine

  /// The 6 lifecycle states.
  ///
  /// Transitions:
  ///
  ///   .disconnected ──connect()──▶ .connecting ──bridge.start──▶ .initializing
  ///                                              └──fail──▶ .disconnected
  ///   .initializing ──init-ack──▶ .connected
  ///                  └──init-fail──▶ .disconnected
  ///   .connected    ──close()────▶ .closing    ──────▶ .closed
  ///   .closed       ──connect()──▶ throws .transport(.transportClosed)
  ///
  /// `close()` from any state is idempotent; only `.connected` or
  /// `.initializing` triggers a real teardown, the rest no-op into
  /// `.closed`.
  public enum State: Sendable, Equatable {
    case disconnected
    case connecting
    case initializing
    case connected
    case closing
    case closed
  }

  // MARK: Dependencies

  private let transport: any Transport
  /// `internal` so the `buildEnvelope` helper in
  /// `Support/QVACClient+SendStream.swift` can re-encode the payload.
  internal let codec: any Codec
  private let initConfig: QVACInitConfig?
  private let runtimeContext: QVACRuntimeContext?

  // MARK: Mutable state

  private var bridge: RPCBridge?
  private var _state: State = .disconnected

  // MARK: Init / inspection

  /// Builds a client wired to `transport`. No network I/O happens here —
  /// the transport remains closed until `connect()` is called.
  ///
  /// - `initConfig`: the `QvacConfig` block sent in the
  ///   `__init_config` handshake. Default `nil` lets the worker use
  ///   its own defaults (`docs/qvac-sdk-internals.md` §4 / §10).
  /// - `runtimeContext`: the per-runtime hint block. Default
  ///   `QVACRuntimeContext()` sends `runtime: "bare"` + auto-detected
  ///   `platform` (`darwin` / `ios` / `linux` / `win32`). Pass `nil`
  ///   to send nothing.
  public init(
    transport: any Transport,
    codec: any Codec = JSONCodec(),
    initConfig: QVACInitConfig? = nil,
    runtimeContext: QVACRuntimeContext? = QVACRuntimeContext()
  ) {
    self.transport = transport
    self.codec = codec
    self.initConfig = initConfig
    self.runtimeContext = runtimeContext
  }

  /// Current lifecycle state. Surfaced for tests and for callers that want
  /// to inspect connection status without trying a no-op `send`.
  public var state: State { _state }

  // MARK: Connect / close

  /// Open the transport, start the underlying `RPCBridge`, and run the
  /// `__init_config` handshake. Idempotent on `.connected`. Throws on
  /// any other re-entry attempt (`.connecting`/`.initializing` = race,
  /// `.closing`/`.closed` = single-use).
  public func connect() async throws {
    switch _state {
    case .connected:
      return
    case .connecting, .initializing:
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

    // `__init_config` handshake (YK-198). The worker dispatches by
    // `type === "__init_config"` and bypasses normal schema validation,
    // so we send the literal envelope rather than routing through the
    // `QVACCommand` enum (which deliberately doesn't include init).
    _state = .initializing
    do {
      try await sendInitConfig(on: bridge)
    } catch {
      // Init failed — tear the bridge back down so a retry on a fresh
      // client starts clean. Roll state back to `.disconnected` so the
      // caller knows they can rebuild.
      await bridge.close()
      self.bridge = nil
      _state = .disconnected
      throw error
    }

    _state = .connected
  }

  /// Send `{type: "__init_config", config, runtimeContext}` and decode
  /// `{success, error?}`. Translates a `success: false` reply into a
  /// typed `QVACError.server(.setConfigFailed, ...)`.
  ///
  /// Bypasses the `buildEnvelope` helper because this message IS the
  /// envelope — the worker's dispatcher detects it pre-routing.
  private func sendInitConfig(on bridge: RPCBridge) async throws {
    let request = InitConfigRequest(
      config: initConfig, runtimeContext: runtimeContext)
    let response: InitConfigResponse = try await bridge.send(
      command: Self.initConfigCommand, request)
    if !response.success {
      throw QVACError.server(
        .setConfigFailed,
        message: response.error ?? "worker rejected __init_config without a message")
    }
  }

  /// bare-rpc REQUEST frame `command` slot for the init handshake.
  /// Hardcoded `1` in the JS SDK (`packages/sdk/client/init-hooks.ts:29-55`);
  /// match exactly so future server-side dispatch tweaks keying off
  /// the command stay compatible.
  private static var initConfigCommand: UInt { 1 }

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
    case .connecting, .initializing:
      // Connect or init is in flight on a different task; flip the
      // flag so it observes the close on completion. We can't await
      // it from inside the same actor without deadlocking, so the
      // in-flight connect either succeeds (then sees `.closing` and
      // drops to `.closed` on its next state check) or fails (already
      // rolls back).
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
    case .disconnected, .connecting, .initializing:
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
