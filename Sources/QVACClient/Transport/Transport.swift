import Foundation

/// A bidirectional byte stream that carries `bare-rpc` frames between the
/// Swift client and the Bare worker.
///
/// Conformers MUST be safe to use from multiple `Task`s — typically an actor
/// or serial dispatch queue serializes writes and read delivery. The contract:
///
/// - `open()` is **idempotent** when already open: calling it twice produces
///   `TransportError.alreadyOpen` on the second call. Implementations should
///   not silently re-open.
/// - `close()` is idempotent everywhere: re-closing a closed transport is a
///   no-op. It must terminate `incoming` so awaiters drain promptly.
/// - `send(_:)` returns when bytes have been handed off to the kernel /
///   transport buffer. It does NOT wait for a network ACK or remote read.
/// - `incoming` yields whatever the underlying transport delivered. Chunks
///   may be partial bare-rpc frames; the RPC layer re-assembles them.
/// - Order of writes is preserved: two `await transport.send(...)` calls from
///   the same task produce bytes on the wire in the same order.
///
/// A `Transport` is intentionally agnostic about framing — it pushes opaque
/// bytes both ways. Framing is `bare-rpc-swift`'s job. The two M1 production
/// implementations are `UDSTransport` (YK-184, desktop) and `BareKitIPCTransport`
/// (YK-206, in-process iOS).
public protocol Transport: Sendable {
  /// Brings the transport up. Throws `TransportError.alreadyOpen` if called
  /// while the transport is already `.open` or `.connecting`. Use `close()`
  /// first to re-open after a failure.
  func open() async throws

  /// Tears down the transport gracefully. Terminates `incoming` so consumer
  /// `for try await` loops complete. Safe to call from any state — re-closing
  /// a closed transport is a no-op.
  func close() async

  /// Hands `data` off to the underlying byte sink. Implementations write
  /// the entire `data` in order before returning. Partial writes are not
  /// observable to callers.
  ///
  /// Throws:
  /// - `TransportError.notOpen` if called before `open()` or after `close()`.
  /// - `TransportError.writeFailed(_:)` if the underlying write fails.
  func send(_ data: Data) async throws

  /// Stream of inbound chunks. Yields whenever the transport receives bytes;
  /// finishes when the transport is closed (either side); throws when the
  /// underlying connection fails.
  ///
  /// The stream is single-consumer per transport instance — multiple
  /// concurrent iterators are not supported.
  var incoming: AsyncThrowingStream<Data, Error> { get }

  /// Observable lifecycle state. Reads are cheap; this is intended for
  /// debugging, logging, and metric collection — not for synchronization.
  /// Use the throwing methods to detect open/closed boundaries reliably.
  var state: TransportState { get async }
}

/// Lifecycle state of a `Transport`. Transitions happen in this order:
///
///     .idle ──► .connecting ──► .open ──► .closing ──► .closed
///                                  └──► .failed
///                                          └──► .closed (after close())
public enum TransportState: Sendable, Equatable {
  /// Constructed but `open()` has not been called yet.
  case idle
  /// `open()` is in flight.
  case connecting
  /// Connection is live; reads + writes are allowed.
  case open
  /// `close()` has been called but cleanup is still running.
  case closing
  /// Fully torn down. Terminal unless the type explicitly supports reopening
  /// via a new instance.
  case closed
  /// An underlying error tore the transport down. The associated error is
  /// the proximate cause. Treated as terminal — call `close()` to fully tear
  /// resources down before discarding.
  case failed(any Error)

  public static func == (lhs: TransportState, rhs: TransportState) -> Bool {
    switch (lhs, rhs) {
    case (.idle, .idle), (.connecting, .connecting), (.open, .open),
      (.closing, .closing), (.closed, .closed):
      return true
    case (.failed(let l), .failed(let r)):
      // Errors aren't `Equatable` in general, so compare by description.
      return String(describing: l) == String(describing: r)
    default:
      return false
    }
  }
}

/// Errors raised by a `Transport`. Wire-level / framing failures use
/// `QVACTransportError` (from the generated `ErrorCodes.swift`); this enum
/// represents the byte-stream layer below that.
public enum TransportError: Error, Sendable {
  /// Operation attempted before `open()` or after `close()`.
  case notOpen
  /// Remote side closed the connection.
  case closedByPeer
  /// `open()` called on an already-open transport.
  case alreadyOpen
  /// Send couldn't complete; the underlying error is preserved for context.
  case writeFailed(underlying: any Error)
  /// Read from the underlying source failed.
  case readFailed(underlying: any Error)
}
