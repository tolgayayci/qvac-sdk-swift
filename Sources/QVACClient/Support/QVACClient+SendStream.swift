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

  /// One-shot reply: wrap `request` in the `{type, ...}` envelope,
  /// send over the active `RPCBridge`, decode the response as `Res`.
  ///
  /// **Cancellation note** (YK-200 / corrected after YK-209): the
  /// `@qvac/sdk` worker uses `.strict()` Zod schemas that reject
  /// unknown envelope fields. The original YK-200 design injected a
  /// `runId: UUID` field to key worker-side cancellation, but that
  /// breaks every typed handler. QVAC's actual cancel API is
  /// `{type: "cancel", operation: "inference"|"downloadAsset"|"rag",
  ///   modelId or downloadKey or workspace}` — keyed by the resource
  /// being cancelled, not by a per-call runId (see
  /// `@qvac/sdk/dist/schemas/cancel.js`).
  ///
  /// Proper per-method cancellation (cancel-inference on the
  /// in-flight model, cancel-download on the active key) requires
  /// per-call context the envelope helper doesn't have. Tracked in
  /// `docs/cancellation.md` under "post-YK-209 revision"; for now
  /// cancellation has to be initiated by the caller via
  /// `client.cancel(operation:modelId:)` (M3 — YK-200 v2).
  internal func send<Req: Encodable, Res: Decodable>(
    command: QVACCommand,
    _ request: Req
  ) async throws -> Res {
    let bridge = try requireBridge()
    let envelope = try buildEnvelope(type: command.rawValue, request: request)
    return try await bridge.send(command: Self.bareRpcCommand, envelope)
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

    return AsyncThrowingStream<Chunk, Error>(bufferingPolicy: policy) { continuation in
      let task = Task { [weak self] in
        guard let self else {
          continuation.finish(throwing: QVACError.transport(.transportClosed))
          return
        }
        do {
          let inner: AsyncThrowingStream<Chunk, Error> =
            try await self.openStream(
              command: command, request: request, bufferSize: bufferSize)
          for try await chunk in inner {
            continuation.yield(chunk)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
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
    bufferSize: Int?
  ) async throws -> AsyncThrowingStream<Chunk, Error> {
    let bridge = try requireBridge()
    let envelope = try buildEnvelope(type: command.rawValue, request: request)
    return bridge.streamResponse(
      command: Self.bareRpcCommand, envelope, bufferSize: bufferSize)
  }

  /// Re-frame the user's request as a `[String: AnyCodable]` and
  /// inject `type = <command.rawValue>` (override caller's `type`).
  /// The `@qvac/sdk` worker uses `.strict()` Zod schemas that reject
  /// unknown envelope fields, so we deliberately inject ONLY `type`
  /// — extra envelope wrapping is the caller's responsibility per
  /// the SDK's per-handler schema.
  ///
  /// Returns `[String: AnyCodable]` (itself `Encodable`) so the
  /// `RPCBridge` call site doesn't need a special path.
  internal func buildEnvelope<Req: Encodable>(
    type: String,
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
    return dict
  }
}
