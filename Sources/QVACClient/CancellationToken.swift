import Foundation

/// Value-type handle for cancelling a `QVACClient` request from outside
/// the awaiting Task. Wraps a Swift `Task<_, Error>` produced by the
/// caller; calling `cancel()` triggers the same cancellation path as
/// `task.cancel()`.
///
/// Cancellation semantics — see `Support/QVACClient+SendStream.swift`:
///
/// - **Worker-side**: emits `{"type": "cancel", "runId": <id>}` to the
///   worker so it stops the inference. This is fire-and-forget; we
///   don't await the cancel-ack.
/// - **Swift-side**: today the awaiting `try await` only completes
///   when the worker sends its terminal frame (upstream `bare-rpc-swift`
///   doesn't propagate `Task.cancel` to `rpc.request` — open-questions
///   §2.3). Once that upstream fix lands, the Swift call throws
///   `CancellationError` synchronously with `cancel()`.
///
/// Typical use:
///
/// ```swift
/// let token = client.token(for: client.completion(...))   // wrap
/// // later, from another thread / actor / Combine pipeline:
/// token.cancel()
/// ```
///
/// For callers that *can* hold a `Task` directly (most async code),
/// just call `task.cancel()` — `CancellationToken` is for callback-
/// based bridges and SwiftUI views that prefer value types.
public struct CancellationToken: Sendable {
  private let _cancel: @Sendable () -> Void

  /// Wraps an arbitrary cancellation closure. Tests and adapters use
  /// this; normal callers go through `QVACClient.token(for:)`.
  public init(_ cancel: @escaping @Sendable () -> Void) {
    self._cancel = cancel
  }

  /// Wraps a `Task` so `cancel()` propagates to it.
  public init<S: Sendable>(task: Task<S, Error>) {
    self._cancel = { task.cancel() }
  }

  /// Wraps a non-throwing `Task`.
  public init<S: Sendable>(neverThrowingTask task: Task<S, Never>) {
    self._cancel = { task.cancel() }
  }

  /// Trigger cancellation. Idempotent: calling twice is a no-op the
  /// second time.
  public func cancel() {
    _cancel()
  }
}
