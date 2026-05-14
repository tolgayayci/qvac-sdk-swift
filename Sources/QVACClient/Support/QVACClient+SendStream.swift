import Foundation

/// Hand-written internal helpers consumed by the codegen-emitted methods
/// in `Sources/QVACClient/Generated/Client+Methods.swift`. M1 ships them
/// as `fatalError` placeholders — the public surface compiles, callers
/// crash loudly if anyone tries to use a stub at runtime, and M2 (YK-197
/// `QVACClient` actor wiring) replaces both bodies with real
/// `RPCBridge.send` / `RPCBridge.streamResponse` delegations.
///
/// The split between this file and `Generated/Client+Methods.swift`
/// keeps the `pnpm run run` drift check honest: only this file mutates
/// when the runtime contract changes, and only `Generated/` changes
/// when the SDK's method list changes.
extension QVACClient {
  /// One-shot reply: encode `request`, dispatch on `command`, decode response.
  /// **M1 stub** — wires up in YK-197.
  internal func send<Req: Encodable, Res: Decodable>(
    command: QVACCommand,
    _ request: Req
  ) async throws -> Res {
    fatalError("YK-201: QVACClient.send(command:_:) is wired in M2")
  }

  /// Server-streamed response: each chunk decoded as `Chunk`. Caller
  /// abandoning the stream cancels the underlying RPC.
  /// **M1 stub** — wires up in YK-197.
  internal nonisolated func streamResponse<Req: Encodable, Chunk: Decodable>(
    command: QVACCommand,
    _ request: Req
  ) -> AsyncThrowingStream<Chunk, Error> {
    AsyncThrowingStream<Chunk, Error> { continuation in
      continuation.finish(
        throwing: QVACError.transport(
          .framingError("YK-201: QVACClient.streamResponse is wired in M2")))
    }
  }
}
