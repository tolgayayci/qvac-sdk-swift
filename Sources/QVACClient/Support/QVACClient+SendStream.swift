import Foundation

/// Real `send` / `streamResponse` helpers consumed by the codegen-emitted
/// methods in `Sources/QVACClient/Generated/Client+Methods.swift`.
///
/// Both methods route through the actor's owned `RPCBridge` (created in
/// `QVACClient.connect()`). The QVAC worker dispatches by the JSON
/// envelope's `type` field, not by the numeric `command` slot on
/// bare-rpc's REQUEST frame, so the bare-rpc `command` here is a stable
/// `1` — bare-rpc uses its own internal request-id to match reply to
/// request and the `command` doesn't need to be unique per call.
///
/// YK-200 (M2-CANCEL) will add a worker-side `cancel` round-trip on top
/// of these; for now `Task.cancel()` on a `streamResponse` consumer
/// rolls down to `IncomingStream.destroy()` via `RPCBridge`.
extension QVACClient {
  /// Bare-rpc REQUEST frame `command` slot. QVAC's worker ignores this
  /// value for routing (it dispatches on JSON `request.type`); bare-rpc
  /// uses its own internal request-id for reply matching. Stable `1`
  /// matches the M1 integration tests' usage and is a free choice.
  fileprivate static var bareRpcCommand: UInt { 1 }

  /// One-shot reply: encode `request` as JSON, send over the active
  /// `RPCBridge`, decode the response as `Res`. The `command: QVACCommand`
  /// argument is the wire-level `request.type` discriminator — generated
  /// methods bind it; manual callers usually go through the per-method
  /// generated extension instead of calling this directly.
  internal func send<Req: Encodable, Res: Decodable>(
    command: QVACCommand,
    _ request: Req
  ) async throws -> Res {
    let bridge = try requireBridge()
    return try await bridge.send(command: Self.bareRpcCommand, request)
  }

  /// Server-streamed response: caller iterates the returned stream;
  /// abandoning the consumer triggers `IncomingStream.destroy()` so the
  /// worker stops producing.
  ///
  /// `nonisolated` so the returned `AsyncThrowingStream` can be handed
  /// to the caller synchronously — the actor work happens inside the
  /// stream's continuation closure.
  internal nonisolated func streamResponse<Req: Encodable, Chunk: Decodable>(
    command: QVACCommand,
    _ request: Req
  ) -> AsyncThrowingStream<Chunk, Error> {
    AsyncThrowingStream<Chunk, Error> { continuation in
      let task = Task { [weak self] in
        guard let self else {
          continuation.finish(throwing: QVACError.transport(.transportClosed))
          return
        }
        do {
          let bridge = try await self.requireBridge()
          let inner: AsyncThrowingStream<Chunk, Error> = bridge.streamResponse(
            command: Self.bareRpcCommand, request)
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
}
