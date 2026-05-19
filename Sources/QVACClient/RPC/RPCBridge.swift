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
/// Wire conventions (per `docs/qvac-sdk-internals.md` §8 + `docs/bare-rpc-wire.md` §8):
/// - Request `data` is UTF-8 JSON.
/// - Streaming response chunks are newline-delimited JSON; the bridge buffers
///   across `bare-rpc` `STREAM|DATA` frames and splits on `\n` before decoding.
public actor RPCBridge {
  private let transport: any Transport
  private let codec: any Codec
  private var rpc: BareRPC.RPC?
  private var delegate: TransportDelegate?
  private var readTask: Task<Void, Never>?
  private(set) var isStarted = false
  private(set) var isClosed = false

  /// `codec` defaults to `JSONCodec()` — the production QVAC wire format.
  /// Tests swap in alternative codecs (e.g. a logging one) by passing them
  /// here; the rest of the actor never touches `JSONEncoder` /
  /// `JSONDecoder` directly.
  public init(transport: any Transport, codec: any Codec = JSONCodec()) {
    self.transport = transport
    self.codec = codec
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
    let bridgeRef = self
    readTask = Task {
      do {
        for try await chunk in transportRef.incoming {
          if Task.isCancelled { break }
          await rpcRef.receive(chunk)
        }
      } catch {
        // Transport read failed.
      }
      // Either path (throw or natural finish) means the transport is gone.
      // bare-rpc-swift has no public way to surface a transport failure to
      // its in-flight continuations, so we inject a force-fail frame: a
      // 4-byte length prefix (0xFFFFFFFF) that exceeds the default
      // maxFrameSize, triggering `RPC.fail(.frameTooLarge)`, which resumes
      // every pending continuation with that error.
      //
      // We only do this if the bridge wasn't explicitly closed — otherwise
      // close() already tore down references.
      let stillOpen = await bridgeRef.bridgeNeedsForceFail()
      if stillOpen {
        let forceFail = Data([0xFF, 0xFF, 0xFF, 0xFF])
        await rpcRef.receive(forceFail)
      }
    }
  }

  /// Read-loop callback: returns `true` when the loop has exited but the
  /// bridge hasn't been explicitly closed (so pending continuations need
  /// the force-fail injection above).
  fileprivate func bridgeNeedsForceFail() -> Bool {
    return isStarted && !isClosed
  }

  /// Tears the bridge down. Safe to call multiple times; further `send` /
  /// `streamResponse` invocations after `close()` fail with `.transportClosed`.
  ///
  /// **Pending in-flight requests** at the moment `close()` is called are
  /// NOT directly woken by this call. bare-rpc-swift has no public hook
  /// to fail pending continuations, and adding one via the same
  /// `0xFFFFFFFF` injection the read loop uses on transport teardown
  /// was observed to interact poorly with concurrent integration paths.
  /// Callers that need to interrupt an in-flight request should cancel
  /// the awaiting `Task` — `rpc.request` propagates `CancellationError`
  /// down through the structured-concurrency tree.
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
    let payload = try codec.encode(req)
    let raw: Data?
    do {
      // Pass the caller-supplied `command` straight through to bare-rpc.
      // It travels on the wire as the REQUEST frame's `command` field.
      // QVAC's worker ignores this field for routing (it routes by JSON
      // `data.type`); any other bare-rpc peer is free to dispatch on it.
      raw = try await rpc.request(command, data: payload)
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
  ///
  /// `bufferSize` controls the AsyncStream's buffering policy (YK-199):
  ///
  /// - `nil` (default): **unbounded** buffer. Matches JS SDK behavior.
  ///   Pending chunks accumulate in memory if the consumer is slow —
  ///   risk of OOM on long streams against a fast producer. Suitable
  ///   for short streams or fast consumers.
  /// - positive `Int`: **bounded** buffer via `.bufferingNewest(N)`.
  ///   Caps memory at N chunks; if the producer outpaces the consumer
  ///   sustainably, the OLDEST chunks are dropped (lossy). Suitable
  ///   for telemetry / log streams where freshness matters more than
  ///   completeness.
  ///
  /// True consumer-driven PAUSE/RESUME (the producer slows down rather
  /// than the buffer dropping chunks) needs an upstream
  /// `BareRPC.IncomingStream.cork() / uncork()` API which doesn't
  /// exist yet — tracked in `docs/application/open-questions.md` §3.3
  /// and `docs/backpressure.md`.
  public nonisolated func streamResponse<Req: Encodable, Chunk: Decodable>(
    command: UInt,
    _ req: Req,
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
    let payload = try codec.encode(req)

    let stream: BareRPC.IncomingStream
    do {
      stream = try await rpc.requestWithResponseStream(command: command, data: payload)
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
            let decoded = try codec.decode(Chunk.self, from: lineData)
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
      if let final = try? codec.decode(Chunk.self, from: lineData) {
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

  private func decodeResponseOrThrow<R: Decodable>(_ data: Data, as type: R.Type) throws -> R {
    if let errorFrame = try? codec.decode(WireErrorFrame.self, from: data),
      errorFrame.type == "error"
    {
      throw QVACError(
        wireCode: errorFrame.code,
        name: errorFrame.name,
        message: errorFrame.message)
    }
    do {
      return try codec.decode(R.self, from: data)
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
///
/// Send failures from the transport are dropped here — the RPC actor will
/// observe them as pending-continuation failures on next read.
///
/// The naive implementation (`Task { try? await transport.send(data) }`)
/// spawns a new Task per call. Tasks aren't FIFO-ordered relative to their
/// spawn site, so two writes initiated back-to-back from the actor can
/// reach the transport out of order — which in practice manifests as a
/// stream's final DATA frame arriving *after* its END frame, dropping the
/// last chunk. Fix: queue outgoing bytes onto an `AsyncStream` drained by
/// a single dedicated Task so order is guaranteed.
private final class TransportDelegate: BareRPC.RPCDelegate, @unchecked Sendable {
  let transport: any Transport

  private let outboxContinuation: AsyncStream<Data>.Continuation
  private let outboxTask: Task<Void, Never>

  init(transport: any Transport) {
    self.transport = transport
    let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
    self.outboxContinuation = continuation
    self.outboxTask = Task { [transport] in
      for await data in stream {
        try? await transport.send(data)
      }
    }
  }

  deinit {
    outboxContinuation.finish()
    outboxTask.cancel()
  }

  func rpc(_ rpc: BareRPC.RPC, send data: Data) {
    outboxContinuation.yield(data)
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
