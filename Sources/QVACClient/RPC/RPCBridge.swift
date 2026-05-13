import BareRPC
import Foundation

/// Wires a `Transport` to a `BareRPC.RPC` actor and exposes a small set of
/// async primitives that the higher-level client API (M2's `QVACClient`)
/// will call. Scope of YK-185 is intentionally narrow:
///
/// - `start()` / `close()`
/// - `send<Req, Res>(command:_:)` for one-shot request→reply
/// - `streamResponse<Req, Chunk>(command:_:)` for server-streamed response
///
/// Streaming-request, duplex, cork/uncork backpressure tuning, and the
/// QVAC-specific `{type: "cancel"}` cancellation request all live above
/// this layer (M2 issues YK-199 / YK-200). `RPCBridge` already plumbs the
/// `Task.cancel` → `IncomingStream.destroy()` path so abandoning a
/// `streamResponse` consumer cleans up correctly.
///
/// Wire conventions (per `docs/qvac-sdk-internals.md` §8 + `docs/bare-rpc-wire-protocol.md` §8):
/// - Request `data` is UTF-8 JSON.
/// - Streaming response chunks are newline-delimited JSON; the bridge buffers
///   across `bare-rpc` `STREAM|DATA` frames and splits on `\n` before decoding.
public actor RPCBridge {
  private let transport: any Transport
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder
  private var rpc: BareRPC.RPC?
  private var delegate: TransportDelegate?
  private var readTask: Task<Void, Never>?
  private var commandCounter: UInt = 0
  private(set) var isStarted = false
  private(set) var isClosed = false

  public init(transport: any Transport) {
    self.transport = transport
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
  }

  /// Opens the transport, constructs the `BareRPC.RPC` actor, and starts the
  /// background read loop that forwards inbound transport bytes into `rpc.receive(_:)`.
  ///
  /// Idempotent in the sense that a second `start()` throws — re-use requires
  /// a fresh `RPCBridge` instance.
  public func start() async throws {
    guard !isStarted else {
      throw QVACError.transport(.framingError("RPCBridge.start() called twice"))
    }
    guard !isClosed else {
      throw QVACError.transport(.transportClosed)
    }
    try await transport.open()
    isStarted = true

    let delegate = TransportDelegate(transport: transport)
    let rpc = BareRPC.RPC(delegate: delegate)
    self.delegate = delegate
    self.rpc = rpc

    let transportRef = transport
    let rpcRef = rpc
    readTask = Task {
      do {
        for try await chunk in transportRef.incoming {
          if Task.isCancelled { break }
          await rpcRef.receive(chunk)
        }
      } catch {
        // Transport errored — `rpc` will surface this to any in-flight
        // continuations via its own failure path on next op.
      }
    }
  }

  /// Tears the bridge down. Safe to call multiple times; further `send` /
  /// `streamResponse` invocations after `close()` fail with `.transportClosed`.
  public func close() async {
    guard !isClosed else { return }
    isClosed = true
    readTask?.cancel()
    readTask = nil
    rpc = nil
    delegate = nil
    await transport.close()
  }

  // MARK: - Outgoing primitives

  /// One-shot: encode `req` as UTF-8 JSON, send it as a bare-rpc REQUEST,
  /// await the single RESPONSE, decode it as `Res`.
  public func send<Req: Encodable, Res: Decodable>(
    command: UInt,
    _ req: Req
  ) async throws -> Res {
    let rpc = try requireOpen()
    let payload = try encoder.encode(req)
    let cmd = nextCommand()
    let raw: Data?
    do {
      raw = try await rpc.request(cmd, data: payload)
    } catch let remote as BareRPC.RPCRemoteError {
      throw mapRemoteError(remote)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw QVACError.transport(.framingError(String(describing: error)))
    }
    guard let data = raw, !data.isEmpty else {
      throw QVACError.transport(.decodingFailed("empty response payload"))
    }
    return try decodeResponseOrThrow(data, as: Res.self)
  }

  /// Server-streamed response: send the request as JSON, get back a sequence
  /// of newline-delimited JSON chunks each decoded as `Chunk`. The returned
  /// `AsyncThrowingStream` terminates when the worker sends `END`/`CLOSE`;
  /// abandoning the consumer (e.g. `break`-ing out of `for try await`)
  /// triggers `IncomingStream.destroy()` so the worker stops producing.
  public nonisolated func streamResponse<Req: Encodable, Chunk: Decodable>(
    command: UInt,
    _ req: Req
  ) -> AsyncThrowingStream<Chunk, Error> {
    AsyncThrowingStream<Chunk, Error> { continuation in
      let task = Task { [weak self] in
        guard let self else {
          continuation.finish(throwing: QVACError.transport(.transportClosed))
          return
        }
        do {
          try await self.consumeStreamResponse(
            command: command, req: req, continuation: continuation)
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { @Sendable _ in
        task.cancel()
      }
    }
  }

  private func consumeStreamResponse<Req: Encodable, Chunk: Decodable>(
    command: UInt,
    req: Req,
    continuation: AsyncThrowingStream<Chunk, Error>.Continuation
  ) async throws {
    let rpc = try requireOpen()
    let payload = try encoder.encode(req)
    let cmd = nextCommand()

    let stream: BareRPC.IncomingStream
    do {
      stream = try await rpc.requestWithResponseStream(command: cmd, data: payload)
    } catch let remote as BareRPC.RPCRemoteError {
      throw mapRemoteError(remote)
    }

    var buffer = ""
    do {
      for try await chunk in stream {
        if Task.isCancelled {
          await stream.destroy()
          break
        }
        guard let piece = String(data: chunk, encoding: .utf8) else {
          continuation.finish(
            throwing: QVACError.transport(.decodingFailed("non-UTF-8 stream chunk")))
          await stream.destroy()
          return
        }
        buffer += piece
        let parts = buffer.split(
          separator: "\n", maxSplits: Int.max, omittingEmptySubsequences: false)
        if let tail = parts.last {
          buffer = String(tail)
        } else {
          buffer = ""
        }
        for rawLine in parts.dropLast() {
          let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
          guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
          do {
            let decoded = try decoder.decode(Chunk.self, from: lineData)
            continuation.yield(decoded)
          } catch {
            let q = QVACError.transport(.decodingFailed(String(describing: error)))
            continuation.finish(throwing: q)
            await stream.destroy()
            return
          }
        }
      }
    } catch let remote as BareRPC.RPCRemoteError {
      continuation.finish(throwing: mapRemoteError(remote))
      return
    } catch {
      continuation.finish(throwing: error)
      return
    }

    let leftover = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !leftover.isEmpty, let lineData = leftover.data(using: .utf8) {
      if let final = try? decoder.decode(Chunk.self, from: lineData) {
        continuation.yield(final)
      }
    }
    continuation.finish()
  }

  // MARK: - Internals

  private func requireOpen() throws -> BareRPC.RPC {
    if isClosed { throw QVACError.transport(.transportClosed) }
    guard let rpc, isStarted else {
      throw QVACError.transport(.framingError("RPCBridge.start() not called"))
    }
    return rpc
  }

  private func nextCommand() -> UInt {
    commandCounter = (commandCounter % 0xFFFF_FFFE) + 1
    return commandCounter
  }

  private func decodeResponseOrThrow<R: Decodable>(_ data: Data, as type: R.Type) throws -> R {
    if let errorFrame = try? decoder.decode(WireErrorFrame.self, from: data),
      errorFrame.type == "error"
    {
      throw QVACError(
        wireCode: errorFrame.code,
        name: errorFrame.name,
        message: errorFrame.message)
    }
    do {
      return try decoder.decode(R.self, from: data)
    } catch {
      throw QVACError.transport(.decodingFailed(String(describing: error)))
    }
  }

  private func mapRemoteError(_ error: BareRPC.RPCRemoteError) -> QVACError {
    // bare-rpc-swift error frames carry {message, code, errno}; QVAC's wire
    // error frames carry {code:Int, name, message, ...}. The bare-rpc code
    // is a string ("ERROR", "ERR_UNKNOWN_COMMAND", etc), not the SDK numeric
    // code, so we route these as transport-level until the SDK error payload
    // is parsed at the QVAC envelope layer.
    return QVACError.transport(.framingError("\(error.code): \(error.message)"))
  }
}

/// Wire shape of the SDK's `{type: "error", ...}` response (per
/// `packages/sdk/schemas/error.ts:4-12`). Used to detect error responses
/// that come back through the regular reply path (not the bare-rpc error
/// channel — those are mapped via `mapRemoteError`).
private struct WireErrorFrame: Decodable {
  let type: String
  let message: String
  let code: Int?
  let name: String?
}

/// Bridges `BareRPC.RPCDelegate` (sync send callback) onto an async `Transport`.
/// Send failures from the transport are dropped here — the RPC actor will
/// observe them as pending-continuation failures on next read.
private final class TransportDelegate: BareRPC.RPCDelegate, @unchecked Sendable {
  let transport: any Transport

  init(transport: any Transport) {
    self.transport = transport
  }

  func rpc(_ rpc: BareRPC.RPC, send data: Data) {
    Task { [transport] in
      try? await transport.send(data)
    }
  }

  func rpc(
    _ rpc: BareRPC.RPC, didReceiveRequest request: BareRPC.IncomingRequest
  ) async throws {
    // Client-side: we don't expect server-initiated requests.
    await request.reject(
      "client does not handle inbound requests",
      code: "ERR_UNEXPECTED_REQUEST",
      errno: 0)
  }

  func rpc(_ rpc: BareRPC.RPC, didReceiveEvent event: BareRPC.IncomingEvent) async {
    // No-op for now — QVAC's wire layer doesn't currently use events.
  }

  func rpc(_ rpc: BareRPC.RPC, didFailWith error: Error) {
    // Best-effort: in-flight continuations will pick this up via RPC's internal
    // failure path on their next op.
  }
}
