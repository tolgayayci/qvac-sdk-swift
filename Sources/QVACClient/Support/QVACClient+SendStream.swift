import Foundation

/// `send` / `streamResponse` helpers consumed by the codegen-emitted
/// methods in `Sources/QVACClient/Generated/Client+Methods.swift`.
///
/// Both methods auto-wrap the caller's request in the QVAC JSON envelope
/// — `{"type": "<command>", ...inner fields}` — before handing it to the
/// `RPCBridge`. The worker's `handle-request.ts` dispatches on the
/// envelope's `type` field, so any request missing it would be silently
/// dropped; this layer makes the contract impossible to violate from
/// generated code or hand-written callers.
///
/// The bare-rpc REQUEST frame `command` slot is a stable `1`. QVAC's
/// worker ignores it for routing (it dispatches on JSON `type`);
/// bare-rpc uses its own internal request-id for reply matching, so
/// command-slot uniqueness isn't required per-call.
///
/// YK-200 (M2-CANCEL) will layer a worker-side `cancel` round-trip on
/// top of these primitives.
extension QVACClient {
  /// bare-rpc REQUEST frame command slot — see file-doc comment above.
  fileprivate static var bareRpcCommand: UInt { 1 }

  /// One-shot reply: wrap `request` in the `{type, ...}` envelope, send
  /// over the active `RPCBridge`, decode the response as `Res`.
  internal func send<Req: Encodable, Res: Decodable>(
    command: QVACCommand,
    _ request: Req
  ) async throws -> Res {
    let bridge = try requireBridge()
    let envelope = try buildEnvelope(type: command.rawValue, request: request)
    return try await bridge.send(command: Self.bareRpcCommand, envelope)
  }

  /// Server-streamed response: caller iterates the returned stream;
  /// abandoning the consumer triggers `IncomingStream.destroy()` so the
  /// worker stops producing.
  ///
  /// `bufferSize` controls back-of-the-actor buffering (YK-199): `nil`
  /// is unbounded (default; matches JS SDK), a positive `Int` switches
  /// to `.bufferingNewest(N)` which caps memory but drops oldest
  /// chunks under sustained flood. See `docs/backpressure.md` for the
  /// trade-off and the upstream-gap note.
  ///
  /// `nonisolated` so the returned `AsyncThrowingStream` can be handed
  /// to the caller synchronously — the actor work (envelope build +
  /// bridge call) happens inside the stream's continuation closure.
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
            if Task.isCancelled { break }
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
  /// builds the envelope, opens the underlying stream. The returned
  /// `AsyncThrowingStream` from `RPCBridge` is iterated by the caller
  /// from the streamResponse Task (post-actor-hop).
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

  /// Re-frame the user's request as a `[String: AnyCodable]` and inject
  /// `type = <command.rawValue>`. The QVAC envelope contract:
  ///
  /// - **Object-shaped request** (typed DTOs, `[:]` literals): the
  ///   envelope's other keys are the request's own fields. Any
  ///   caller-supplied `type` is overridden — the `QVACCommand`
  ///   argument is the source of truth for routing.
  /// - **Null / primitive / array request**: starts from empty `[:]`,
  ///   sets only `type`. The common case for `AnyCodable(.null)`
  ///   defaults on methods whose request shape isn't yet in the
  ///   codegen allowlist.
  ///
  /// Returns `[String: AnyCodable]` (itself `Encodable`) so the
  /// `RPCBridge` call site doesn't need a special path — it just
  /// hands the dict to `codec.encode` like any other request.
  internal func buildEnvelope<Req: Encodable>(
    type: String,
    request: Req
  ) throws -> [String: AnyCodable] {
    let raw = try codec.encode(request)
    var dict: [String: AnyCodable]
    if let parsed = try? codec.decode([String: AnyCodable].self, from: raw) {
      dict = parsed
    } else {
      // Not a JSON object — null, primitive, or array. The QVAC
      // envelope only carries object-shaped payloads; the worker's
      // handler validates the rest against its own schema.
      dict = [:]
    }
    dict["type"] = AnyCodable(.string(type))
    return dict
  }
}
