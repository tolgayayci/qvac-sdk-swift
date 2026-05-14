import Foundation

/// `send` / `streamResponse` helpers consumed by the codegen-emitted
/// methods in `Sources/QVACClient/Generated/Client+Methods.swift`.
///
/// Each call:
///
/// 1. **Generates a runId (UUID)** — YK-200 — used both as the
///    `"runId"` envelope field on the request and as the argument to
///    the cancel command if the caller's Task gets cancelled.
/// 2. **Wraps the request in the QVAC JSON envelope** — YK-198 —
///    `{"type": "<command>", "runId": "<uuid>", ...inner fields}`.
///    The worker's `handle-request.ts` dispatches on `type`; the
///    `runId` lets a later `cancel` command target this specific call.
/// 3. **Hooks Task cancellation** — YK-200 — when the awaiting Task
///    is cancelled, fires `{"type": "cancel", "runId": <captured>}`
///    fire-and-forget on the bridge so the worker stops its work.
///
/// The bare-rpc REQUEST frame `command` slot is a stable `1`. QVAC's
/// worker ignores it for routing (it dispatches on JSON `type`);
/// bare-rpc uses its own internal request-id for reply matching, so
/// command-slot uniqueness isn't required per-call.
///
/// **Cancellation caveat** (open-questions §2.3): bare-rpc-swift's
/// `rpc.request` doesn't currently propagate `Task.cancel` down to
/// its CheckedContinuation. So today the worker stops on cancel (we
/// emit the command), but the Swift `try await client.send(...)`
/// only completes once the worker's terminal frame arrives. When the
/// upstream bare-rpc fix lands, the Swift-side `CancellationError`
/// arrives synchronously with `Task.cancel()` and the existing
/// `withTaskCancellationHandler` wrap re-throws cleanly.
extension QVACClient {
  /// bare-rpc REQUEST frame command slot — see file-doc comment above.
  fileprivate static var bareRpcCommand: UInt { 1 }

  /// One-shot reply: wrap `request` in the `{type, runId, ...}`
  /// envelope, send over the active `RPCBridge`, decode the response
  /// as `Res`. Task cancellation propagates to the worker via the
  /// `cancel` command keyed on `runId`.
  internal func send<Req: Encodable, Res: Decodable>(
    command: QVACCommand,
    _ request: Req
  ) async throws -> Res {
    let bridge = try requireBridge()
    let runId = UUID().uuidString
    let envelope = try buildEnvelope(
      type: command.rawValue, runId: runId, request: request)

    return try await withTaskCancellationHandler(
      operation: {
        try await bridge.send(command: Self.bareRpcCommand, envelope)
      },
      onCancel: { [weak self] in
        Task { [weak self] in
          await self?.sendCancelFireAndForget(runId: runId)
        }
      })
  }

  /// Server-streamed response: caller iterates the returned stream;
  /// abandoning the consumer (`break` out of `for try await`, or
  /// `Task.cancel()` on the consuming task) fires the cancel command
  /// to the worker, then the stream finishes when the worker's
  /// terminal frame arrives.
  ///
  /// `bufferSize` controls back-of-the-actor buffering (YK-199): `nil`
  /// is unbounded (default; matches JS SDK), a positive `Int` switches
  /// to `.bufferingNewest(N)`. See `docs/backpressure.md`.
  ///
  /// `nonisolated` so the returned `AsyncThrowingStream` can be handed
  /// to the caller synchronously — the actor work happens inside the
  /// stream's continuation closure.
  internal nonisolated func streamResponse<Req: Encodable, Chunk: Decodable>(
    command: QVACCommand,
    _ request: Req,
    bufferSize: Int? = nil
  ) -> AsyncThrowingStream<Chunk, Error> {
    let policy: AsyncThrowingStream<Chunk, Error>.Continuation.BufferingPolicy =
      bufferSize.map { .bufferingNewest($0) } ?? .unbounded
    let runId = UUID().uuidString

    return AsyncThrowingStream<Chunk, Error>(bufferingPolicy: policy) { continuation in
      let task = Task { [weak self] in
        guard let self else {
          continuation.finish(throwing: QVACError.transport(.transportClosed))
          return
        }
        // `withTaskCancellationHandler` is the only way to observe
        // `task.cancel()` while suspended in `for try await chunk in
        // inner`. Checking `Task.isCancelled` inside the loop body
        // misses the common case where the iterator yields `nil` on
        // cancel (the body never runs again).
        await withTaskCancellationHandler(
          operation: {
            do {
              let inner: AsyncThrowingStream<Chunk, Error> =
                try await self.openStream(
                  command: command,
                  request: request,
                  runId: runId,
                  bufferSize: bufferSize)
              for try await chunk in inner {
                continuation.yield(chunk)
              }
              continuation.finish()
            } catch {
              continuation.finish(throwing: error)
            }
          },
          onCancel: { [weak self] in
            Task { [weak self] in
              await self?.sendCancelFireAndForget(runId: runId)
            }
          })
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  /// Actor-isolated step for `streamResponse`: requires the bridge,
  /// builds the envelope, opens the underlying stream.
  private func openStream<Req: Encodable, Chunk: Decodable>(
    command: QVACCommand,
    request: Req,
    runId: String,
    bufferSize: Int?
  ) async throws -> AsyncThrowingStream<Chunk, Error> {
    let bridge = try requireBridge()
    let envelope = try buildEnvelope(
      type: command.rawValue, runId: runId, request: request)
    return bridge.streamResponse(
      command: Self.bareRpcCommand, envelope, bufferSize: bufferSize)
  }

  /// Re-frame the user's request as a `[String: AnyCodable]` and
  /// inject `type = <command.rawValue>` and `runId = <uuid>`. Both
  /// fields override any caller-supplied values — `QVACCommand` and
  /// the per-call UUID are the sources of truth.
  ///
  /// Returns `[String: AnyCodable]` (itself `Encodable`) so the
  /// `RPCBridge` call site doesn't need a special path.
  internal func buildEnvelope<Req: Encodable>(
    type: String,
    runId: String? = nil,
    request: Req
  ) throws -> [String: AnyCodable] {
    let raw = try codec.encode(request)
    var dict: [String: AnyCodable]
    if let parsed = try? codec.decode([String: AnyCodable].self, from: raw) {
      dict = parsed
    } else {
      // Not a JSON object — null, primitive, or array.
      dict = [:]
    }
    dict["type"] = AnyCodable(.string(type))
    if let runId {
      dict["runId"] = AnyCodable(.string(runId))
    }
    return dict
  }

  /// Fires the QVAC `{"type": "cancel", "runId": <id>}` request and
  /// discards the reply. Used from cancellation handlers — we don't
  /// await the cancel-ack because cascading cancellation would let
  /// the original request hang on a separate failure mode.
  ///
  /// Best-effort: if the bridge is already torn down (race with
  /// `client.close()`), this silently no-ops. If the worker doesn't
  /// recognize the runId (already completed), it replies with an
  /// error that we also discard.
  private func sendCancelFireAndForget(runId: String) async {
    guard let bridge = try? requireBridge() else { return }
    let envelope: [String: AnyCodable] = [
      "type": AnyCodable(.string("cancel")),
      "runId": AnyCodable(.string(runId)),
    ]
    let _: CancelResponse? = try? await bridge.send(
      command: Self.bareRpcCommand, envelope)
  }
}
