import BareKitWrapper
import Foundation

/// YK-206 — in-process Bare worklet transport. The third `Transport`
/// implementation in the surface (after `UDSTransport` for desktop
/// client-mode and `UDSServer`/`UDSAcceptedTransport` for desktop
/// server-mode).
///
/// **Why a third transport.** iOS apps can't spawn subprocesses;
/// macOS apps in the App Sandbox can't either. The QVAC worker
/// instead runs **in-process** as a Bare worklet hosted by the
/// `BareKit.xcframework` (Apple JavaScriptCore-flavored slice,
/// ~20MB; full V8 variant available but bigger). Communication is
/// the same `bare-rpc` framing as the UDS transports — only the
/// underlying byte transport differs.
///
/// **Wiring.**
/// 1. Worklet starts with a `bare-pack`-produced `.bundle` (single
///    JS file with all `@qvac/sdk` plugins inlined; produced by
///    the second-half of YK-207 — `embedded()` factory will resolve
///    it as an SPM resource once that ships).
/// 2. `BareIPC` (from `BareKit.framework`) gives a duplex
///    `read()` / `write()` API over the worklet's main thread.
/// 3. This transport wraps `IPC.read()` into the
///    `AsyncThrowingStream<Data, Error>` that `RPCBridge` expects.
/// 4. `IPC.write(_:)` becomes the `Transport.send(_:)` implementation.
///
/// **Lifecycle.** `open()` is idempotent. `close()` terminates the
/// worklet (irreversible — build a new transport for a new
/// connection, matches the single-use design of `QVACClient`).
/// `Worklet.suspend()` / `.resume()` are *not* exposed today;
/// they're an iOS-only optimization for app-background recovery
/// and land in YK-211 / M3 once the example app needs them.
public final class BareKitIPCTransport: Transport, @unchecked Sendable {
  private let inner: BareKitActor
  public let incoming: AsyncThrowingStream<Data, Error>

  /// Construct from a `bare-pack`-produced bundle file. The
  /// `filename` is the symbolic name the worklet sees as `Bare.argv[1]`;
  /// most callers pass `"qvac"` or similar.
  ///
  /// Arguments are forwarded to the worklet's `Bare.argv[2..]`. The
  /// `__init_config` handshake (YK-198) lives at the QVAC layer
  /// above, but if the bundle entry point reads RPC config from
  /// argv (the SDK's worker.js does), pass it here as JSON.
  public init(
    filename: String = "qvac",
    bundleSource: Data,
    arguments: [String] = []
  ) {
    let (stream, continuation) = AsyncThrowingStream<Data, Error>
      .makeStream(bufferingPolicy: .unbounded)
    self.incoming = stream

    let worklet = Worklet()
    worklet.start(filename: filename, source: bundleSource, arguments: arguments)
    let ipc = IPC(worklet: worklet)
    self.inner = BareKitActor(worklet: worklet, ipc: ipc, continuation: continuation)
    Task { await self.inner.startReadLoop() }
  }

  public func open() async throws { try await inner.markOpen() }
  public func send(_ data: Data) async throws { try await inner.send(data) }
  public func close() async { await inner.close() }
  public var state: TransportState { get async { await inner.currentState } }
}

private actor BareKitActor {
  private let worklet: Worklet
  private let ipc: IPC
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  private(set) var currentState: TransportState = .open
  private var didOpen = false
  private var didClose = false

  init(
    worklet: Worklet, ipc: IPC,
    continuation: AsyncThrowingStream<Data, Error>.Continuation
  ) {
    self.worklet = worklet
    self.ipc = ipc
    self.continuation = continuation
  }

  func markOpen() async throws {
    guard !didOpen else { throw TransportError.alreadyOpen }
    didOpen = true
  }

  func startReadLoop() {
    Task {
      do {
        while !didClose {
          guard let data = try await ipc.read() else {
            // nil means worklet's IPC pipe ended cleanly
            continuation.finish()
            currentState = .closed
            return
          }
          continuation.yield(data)
        }
      } catch {
        continuation.finish(throwing: TransportError.readFailed(underlying: error))
        currentState = .failed(error)
      }
    }
  }

  func send(_ data: Data) async throws {
    guard case .open = currentState else { throw TransportError.notOpen }
    do {
      try await ipc.write(data: data)
    } catch {
      throw TransportError.writeFailed(underlying: error)
    }
  }

  func close() {
    guard !didClose else { return }
    didClose = true
    currentState = .closing
    ipc.close()
    worklet.terminate()
    currentState = .closed
    continuation.finish()
  }
}
